import Foundation
import Darwin

protocol SnapshotLifecycleBackend: AnyObject {
    func volumes() throws -> [ManagedVolume]
    func inventory(_ volume: ManagedVolume) throws -> [LifecycleSnapshot]
    func create(_ volume: ManagedVolume, name: String) throws
    func delete(_ volume: ManagedVolume, snapshot: LifecycleSnapshot) throws
    func freeBytes(_ volume: ManagedVolume) throws -> Int64
    func mount(_ volume: ManagedVolume, snapshot: LifecycleSnapshot, leaseID: String, side: String, owner: UInt32) throws -> String
    func unmount(path: String) throws
}

/// One exclusive process lock, a private directory, no symlink state, atomic replacement and fsync.
/// Production uses root ownership; tests use an explicitly supplied disposable directory and current UID.
final class SnapshotLifecycleLedger {
    let directory: URL
    private let uid: uid_t
    private var lockFD: Int32 = -1
    init(directory: URL, owner: uid_t) throws {
        self.directory = directory; uid = owner
        let parent = directory.deletingLastPathComponent()
        var parentInfo = stat()
        try lifecycleRequire(lstat(parent.path, &parentInfo) == 0 && (parentInfo.st_mode & S_IFMT) == S_IFDIR && parentInfo.st_uid == owner && (parentInfo.st_mode & 0o022) == 0, "Ledger parent must be owned by the service account and not writable by others.")
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw SnapshotLifecycleError.refused("Cannot create private ownership ledger: \(errno).") }
        var info = stat()
        try lifecycleRequire(lstat(directory.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == owner && (info.st_mode & 0o077) == 0, "Ownership ledger directory is not private or has been replaced.")
        lockFD = open(directory.appendingPathComponent("service.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw SnapshotLifecycleError.refused("Cannot open management lock.") }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0 && lockInfo.st_uid == owner && (lockInfo.st_mode & S_IFMT) == S_IFREG && lockInfo.st_nlink == 1 && (lockInfo.st_mode & 0o077) == 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); lockFD = -1; throw SnapshotLifecycleError.refused("Another snapshot service is active or its lock is unsafe.")
        }
    }
    deinit { if lockFD >= 0 { close(lockFD) } }
    func load() throws -> SnapshotLedgerDocument {
        let path = directory.appendingPathComponent("ownership.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return SnapshotLedgerDocument() }
        try lifecycleRequire(fd >= 0, "Cannot read ownership ledger.")
        defer { close(fd) }
        var info = stat()
        try lifecycleRequire(fstat(fd, &info) == 0 && info.st_uid == uid && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 && (info.st_mode & 0o077) == 0 && info.st_size <= 32*1024*1024, "Ownership ledger permissions/type/size are unsafe.")
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        let value = try JSONDecoder().decode(SnapshotLedgerDocument.self, from: data)
        try lifecycleRequire(value.schema == 1 && UUID(uuidString: value.domain) != nil && Set(value.snapshots.map(\.id)).count == value.snapshots.count && value.snapshots.allSatisfy { $0.domain == value.domain && UUID(uuidString: $0.volumeUUID) != nil && UUID(uuidString: $0.containerUUID) != nil && UUID(uuidString: $0.id) != nil }, "Ownership ledger is inconsistent; no snapshots may be adopted or deleted.")
        let active = value.snapshots.filter { $0.state != .deleted }
        try lifecycleRequire(Set(active.map { $0.volumeUUID + ":" + $0.name }).count == active.count && Set(active.filter { !$0.snapshotUUID.isEmpty }.map { $0.volumeUUID + ":" + $0.snapshotUUID }).count == active.filter { !$0.snapshotUUID.isEmpty }.count, "Duplicate native snapshot ownership identities.")
        for record in value.snapshots {
            try lifecycleRequire(record.name == ManagedSnapshot.nativeName(domain: value.domain, operation: record.id, label: record.label) && (record.snapshotUUID.isEmpty || UUID(uuidString: record.snapshotUUID) != nil) && (record.state != .managed || (!record.snapshotUUID.isEmpty && record.xid != nil)), "Invalid persisted snapshot ownership tuple.")
        }
        for lease in value.leases {
            let prefix = SnapshotServiceIdentity.mountRoot + "/" + lease.id
            let records = value.snapshots.filter { [$0.id].contains(lease.leftSnapshotID) || [$0.id].contains(lease.rightSnapshotID) }
            try lifecycleRequire(UUID(uuidString: lease.id) != nil && lease.leftSnapshotID != lease.rightSnapshotID && lease.leftPath == prefix + "/left" && lease.rightPath == prefix + "/right" && records.count == 2 && records.allSatisfy { $0.owner == lease.owner && $0.volumeUUID == lease.volumeUUID }, "Invalid persisted comparison lease; refusing cleanup side effects.")
        }
        try lifecycleRequire(Set(value.leases.map(\.id)).count == value.leases.count, "Duplicate persisted leases.")
        try lifecycleRequire(Set(value.policies.map(\.id)).count == value.policies.count && value.policies.count <= 1024, "Duplicate or excessive persisted policies.")
        for saved in value.policies {
            try saved.policy.validate()
            try lifecycleRequire(saved.owner >= 501 && UUID(uuidString: saved.volume.id) != nil && UUID(uuidString: saved.volume.container) != nil && saved.volume.compatibilityIssue == nil && saved.nextDue.timeIntervalSince1970.isFinite, "Invalid persisted schedule ownership/volume/state.")
        }
        return value
    }
    func save(_ document: SnapshotLedgerDocument) throws {
        let data = try JSONEncoder().encode(document)
        try lifecycleRequire(data.count <= 32*1024*1024, "Ownership ledger size limit reached.")
        let temporary = directory.appendingPathComponent(".ledger-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try lifecycleRequire(fd >= 0, "Cannot stage ownership ledger.")
        var installed = false
        defer { close(fd); if !installed { unlink(temporary.path) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                if written < 0 && errno == EINTR { continue }
                try lifecycleRequire(written > 0, "Ownership ledger write failed."); offset += written
            }
        }
        try lifecycleRequire(fsync(fd) == 0, "Ownership ledger fsync failed.")
        try lifecycleRequire(rename(temporary.path, directory.appendingPathComponent("ownership.json").path) == 0, "Ownership ledger commit failed.")
        installed = true
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try lifecycleRequire(dir >= 0, "Cannot open ownership ledger directory for sync.")
        defer { close(dir) }; try lifecycleRequire(fsync(dir) == 0, "Ownership ledger directory sync failed.")
    }
}

/// All calls are serialized by the daemon. Native callbacks must independently verify the open volume
/// and the UUID/name/XID tuple again immediately before the syscall; previews never authorize by name.
final class SnapshotLifecycleEngine {
    private(set) var document: SnapshotLedgerDocument
    private let ledger: SnapshotLifecycleLedger
    private let backend: SnapshotLifecycleBackend
    private var previews = [String: SnapshotDeletionPreview]()
    private var poisoned = false
    private var previewContexts = [String: String]()
    private var leaseSessions = [String: String]()
    init(ledger: SnapshotLifecycleLedger, backend: SnapshotLifecycleBackend) throws {
        self.ledger = ledger; self.backend = backend; document = try ledger.load()
        var changed = false
        for index in document.snapshots.indices where [.creating, .deleting].contains(document.snapshots[index].state) {
            document.snapshots[index].state = .quarantined; changed = true
        }
        for index in document.activities.indices where document.activities[index].status == "pending" {
            document.activities[index].status = "interrupted"; document.activities[index].detail += " Service restarted; uncertain ownership was quarantined. No automatic retry or adoption."; changed = true
        }
        // Lease paths were generated inside the root-owned namespace; backend validates before cleanup.
        for lease in document.leases {
            do { try release(lease) }
            catch { throw SnapshotLifecycleError.refused("Interrupted comparison needs mount cleanup: \(error)") }
        }
        if !document.leases.isEmpty { document.leases = []; changed = true }
        if changed || document.revision == 0 { try commit() }
    }
    private func release(_ lease: SnapshotMountLease) throws {
        let left = Result { try backend.unmount(path: lease.leftPath) }
        let right = Result { try backend.unmount(path: lease.rightPath) }
        try left.get(); try right.get()
    }
    private func isLeased(_ id: String) -> Bool { document.leases.contains { $0.leftSnapshotID == id || $0.rightSnapshotID == id } }
    private func commit() throws {
        document.revision &+= 1
        let tombstones = document.snapshots.filter { $0.state == .deleted }.sorted { $0.createdAt > $1.createdAt }
        let keepDeleted = Set(tombstones.prefix(2000).map(\.id))
        document.snapshots.removeAll { $0.state == .deleted && !keepDeleted.contains($0.id) }
        if document.activities.count > 2000 { document.activities.removeFirst(document.activities.count - 2000) }
        do { try ledger.save(document) } catch { poisoned = true; throw error }
    }
    private func resolve(_ uuid: String) throws -> ManagedVolume {
        try lifecycleRequire(UUID(uuidString: uuid) != nil, "Invalid volume identifier.")
        let matches = try backend.volumes().filter { $0.id == uuid }
        try lifecycleRequire(matches.count == 1, "Volume disconnected, locked or identity is ambiguous.")
        let volume = matches[0]
        try lifecycleRequire(volume.compatibilityIssue == nil, volume.compatibilityIssue ?? "Unsupported volume.")
        return volume
    }
    private func owned(_ id: String, owner: UInt32) throws -> ManagedSnapshot {
        guard let value = document.snapshots.first(where: { $0.id == id && $0.owner == owner }) else { throw SnapshotLifecycleError.refused("Snapshot is not in this user's persistent management ledger.") }
        return value
    }
    private func verified(_ record: ManagedSnapshot, volume: ManagedVolume, owner: UInt32) throws -> LifecycleSnapshot {
        let matches = try backend.inventory(volume).filter { $0.id == record.snapshotUUID }
        try lifecycleRequire(matches.count == 1, "Snapshot no longer exists or its identity is ambiguous.")
        try SnapshotOwnership.verify(record, against: matches[0], volume: volume, domain: document.domain, owner: owner)
        return matches[0]
    }
    private func activity(owner: UInt32, volume: String, id: String? = nil, action: String, status: String, detail: String, before: Int64? = nil, after: Int64? = nil) {
        document.activities.append(.init(owner: owner, volumeUUID: volume, snapshotID: id, action: action, status: status, detail: detail, freeBefore: before, freeAfter: after))
    }
    private func create(volume: ManagedVolume, label: String, owner: UInt32, now: Date) throws {
        try lifecycleRequire(label.utf8.count <= 80 && !label.contains("/") && !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), "Snapshot labels must contain at most 80 UTF-8 bytes and no control characters.")
        try lifecycleRequire(document.snapshots.count < 100_000, "Ownership ledger record limit reached.")
        try lifecycleRequire(document.snapshots.filter { $0.volumeUUID == volume.id && $0.state != .deleted }.count < 4096, "Per-volume management record limit reached. Review existing/quarantined snapshots before creating more.")
        let before = try backend.freeBytes(volume)
        try lifecycleRequire(before >= 16*1024*1024, "Less than 16 MiB physical free space remains; snapshot creation is paused.")
        var record = ManagedSnapshot(volume: volume, domain: document.domain, name: label.isEmpty ? "Snapshot" : label, snapshotUUID: "", xid: nil, createdAt: now, owner: owner)
        record.state = .creating
        document.snapshots.append(record)
        activity(owner: owner, volume: volume.id, id: record.id, action: "create", status: "pending", detail: "Creation intent durably recorded before native mutation.", before: before)
        try commit()
        let activityID = document.activities.last!.id
        do {
            // Confirm no existing native snapshot has this random name before the create call.
            try lifecycleRequire(try !backend.inventory(volume).contains { $0.name == record.name }, "Generated snapshot name already exists; no ownership adoption permitted.")
            try backend.create(volume, name: record.name)
            let currentVolume = try resolve(volume.id)
            try lifecycleRequire(currentVolume.container == volume.container, "Container changed during creation.")
            let matches = try backend.inventory(currentVolume).filter { $0.name == record.name }
            try lifecycleRequire(matches.count == 1 && UUID(uuidString: matches[0].id) != nil && matches[0].xid != nil, "Created snapshot identity could not be confirmed. It is quarantined, never auto-adopted.")
            record.snapshotUUID = matches[0].id; record.xid = matches[0].xid; record.state = .managed
            document.snapshots[document.snapshots.firstIndex { $0.id == record.id }!] = record
            if let index = document.activities.firstIndex(where: { $0.id == activityID }) {
                document.activities[index].status = "success"; document.activities[index].detail = "Created and verified UUID/name/XID. Timestamp is the application's creation request time; exact exclusive bytes are unknown."
                document.activities[index].freeAfter = try? backend.freeBytes(currentVolume)
            }
            try commit()
        } catch {
            if let index = document.snapshots.firstIndex(where: { $0.id == record.id }) { document.snapshots[index].state = .quarantined }
            if let index = document.activities.firstIndex(where: { $0.id == activityID }) { document.activities[index].status = "failed"; document.activities[index].detail = String(describing: error) }
            try commit(); throw error
        }
    }
    private func preview(ids: [String], volume: ManagedVolume, owner: UInt32, now: Date, reason: String, session: String = "automatic") throws -> SnapshotDeletionPreview {
        try lifecycleRequire(ids.count <= 256 && Set(ids).count == ids.count, "Deletion previews are limited to 256 distinct snapshots.")
        let records = try ids.map { try owned($0, owner: owner) }
        for record in records {
            try lifecycleRequire(!isLeased(record.id), "Snapshot is in an active/unresolved comparison lease.")
            try lifecycleRequire(!record.protected, "Protected snapshots must be deliberately unprotected before deletion.")
            _ = try verified(record, volume: volume, owner: owner)
        }
        previews = previews.filter { $0.value.expires > now }; previewContexts = previewContexts.filter { previews[$0.key] != nil }
        try lifecycleRequire(previews.count < 128, "Too many pending deletion previews.")
        let value = SnapshotDeletionPreview(id: UUID().uuidString + UUID().uuidString, volumeUUID: volume.id, records: records, expires: now.addingTimeInterval(120), reason: reason, revision: document.revision)
        previews[value.id] = value; previewContexts[value.id] = "\(owner):\(session)"; return value
    }
    private func execute(_ plan: SnapshotDeletionPreview, owner: UInt32, now: Date) throws {
        try lifecycleRequire(plan.expires > now && plan.revision == document.revision, "Preview expired or management state changed. Preview again.")
        for proposed in plan.records {
            let volume = try resolve(plan.volumeUUID), record = try owned(proposed.id, owner: owner)
            try lifecycleRequire(record == proposed && !record.protected && !isLeased(record.id), "Snapshot state changed since preview.")
            let native = try verified(record, volume: volume, owner: owner)
            let before = try? backend.freeBytes(volume)
            let index = document.snapshots.firstIndex { $0.id == record.id }!
            document.snapshots[index].state = .deleting
            activity(owner: owner, volume: volume.id, id: record.id, action: "delete", status: "pending", detail: plan.reason, before: before)
            try commit()
            let activityID = document.activities.last!.id
            do {
                try backend.delete(volume, snapshot: native)
                let current = try resolve(volume.id)
                try lifecycleRequire(current.container == volume.container && (try !backend.inventory(current).contains { $0.id == native.id }), "Deletion could not be confirmed; no recovered space is claimed.")
                document.snapshots[document.snapshots.firstIndex { $0.id == record.id }!].state = .deleted
                let log = document.activities.firstIndex { $0.id == activityID }!
                document.activities[log].status = "success"
                document.activities[log].detail += " Snapshot is absent. Nearby free-space delta is an observed shared-container change, not exclusive reclaimed bytes; block release can be delayed."
                document.activities[log].freeAfter = try? backend.freeBytes(current)
                try commit()
            } catch {
                document.snapshots[document.snapshots.firstIndex { $0.id == record.id }!].state = .quarantined
                let log = document.activities.firstIndex { $0.id == activityID }!
                document.activities[log].status = "failed"; document.activities[log].detail += " \(error)"
                try commit(); throw error
            }
        }
    }
    func handle(_ request: SnapshotServiceRequest, owner: UInt32, now: Date = Date(), session: String = "tests") throws -> SnapshotServiceResponse {
        try lifecycleRequire(!poisoned, "Ownership persistence failed. Restart and review quarantined operations before continuing.")
        try lifecycleRequire(request.protocolVersion == 1, "Unsupported snapshot service protocol.")
        var result = SnapshotServiceResponse()
        if request.action == .inventory {
            result.volumes = try backend.volumes()
            for volume in result.volumes {
                do { result.inventories[volume.id] = try backend.inventory(volume) }
                catch { result.inventoryErrors[volume.id] = String(describing: error) }
            }
        } else if request.action == .endComparison {
            guard let token = request.token, let index = document.leases.firstIndex(where: { $0.id == token && $0.owner == owner && leaseSessions[$0.id] == session }) else { throw SnapshotLifecycleError.refused("Unknown comparison lease.") }
            let lease = document.leases[index]
            try release(lease)
            document.leases.remove(at: index); try commit(); result.message = "Comparison mounts released."
        } else {
            guard let uuid = request.volumeUUID else { throw SnapshotLifecycleError.refused("Select a volume.") }
            let volume: ManagedVolume
            if request.action == .savePolicy, request.policy?.enabled == false,
               let saved = document.policies.first(where: { $0.owner == owner && $0.volume.id == uuid }) {
                volume = saved.volume
            } else { volume = try resolve(uuid) }
            switch request.action {
            case .create: try create(volume: volume, label: request.label ?? "Snapshot", owner: owner, now: now); result.message = "Snapshot created and ownership verified."
            case .protect:
                try lifecycleRequire(Set(request.snapshotIDs).count == request.snapshotIDs.count, "Duplicate protection identifiers.")
                let records = try request.snapshotIDs.map { try owned($0, owner: owner) }
                for record in records { _ = try verified(record, volume: volume, owner: owner) }
                for record in records {
                    let id = record.id
                    let index = document.snapshots.firstIndex { $0.id == id }!
                    if let protected = request.protected { document.snapshots[index].protected = protected }
                    if let excluded = request.excluded { document.snapshots[index].excludedFromRetention = excluded }
                    activity(owner: owner, volume: uuid, id: id, action: "protection", status: "success", detail: "Protection/exclusion changed by the owning user.")
                }
                try commit()
            case .recover:
                try lifecycleRequire(request.snapshotIDs.count == 1, "Review one uncertain operation at a time.")
                var record = try owned(request.snapshotIDs[0], owner: owner)
                try lifecycleRequire(record.state == .quarantined && record.domain == document.domain && record.volumeUUID == volume.id && record.containerUUID == volume.container && record.name == ManagedSnapshot.nativeName(domain: document.domain, operation: record.id, label: record.label), "Recovery requires a matching durable pre-mutation intent.")
                let matches = try backend.inventory(volume).filter { $0.name == record.name }
                if matches.isEmpty { record.state = .deleted }
                else {
                    try lifecycleRequire(matches.count == 1 && matches[0].xid != nil && (record.snapshotUUID.isEmpty || (record.snapshotUUID == matches[0].id && record.xid == matches[0].xid)), "Uncertain snapshot identity does not match its durable intent; no adoption permitted.")
                    record.snapshotUUID = matches[0].id; record.xid = matches[0].xid; record.state = .managed; record.protected = true
                }
                document.snapshots[document.snapshots.firstIndex { $0.id == record.id }!] = record
                activity(owner: owner, volume: uuid, id: record.id, action: "recovery", status: "success", detail: "Fresh authorized recovery review: \(record.state.rawValue). Existing snapshots are protected until explicitly unprotected.")
                try commit(); result.message = "Recovery intent rechecked; any existing managed snapshot is protected."
            case .previewManual: result.preview = try preview(ids: request.snapshotIDs, volume: volume, owner: owner, now: now, reason: "User-confirmed manual deletion", session: session)
            case .previewRetention:
                let policy = document.policies.first { $0.owner == owner && $0.volume.id == uuid }?.policy ?? SnapshotPolicy()
                let ids = SnapshotRetention.candidates(records: document.snapshots.filter { $0.owner == owner }, volume: volume, policy: policy, now: now).filter { !isLeased($0.id) }.prefix(256).map(\.id)
                result.preview = try preview(ids: ids, volume: volume, owner: owner, now: now, reason: "Age/count retention; protected/excluded snapshots and newest recovery point retained", session: session)
            case .deletePreview:
                guard let token = request.token, previewContexts[token] == "\(owner):\(session)", let plan = previews.removeValue(forKey: token), plan.volumeUUID == uuid else { throw SnapshotLifecycleError.refused("Unknown or already-used deletion preview.") }
                previewContexts.removeValue(forKey: token)
                try execute(plan, owner: owner, now: now); result.message = "Deletion completed. Free-space changes are observations, not guaranteed recovery."
            case .savePolicy:
                guard let policy = request.policy else { throw SnapshotLifecycleError.refused("Policy is missing.") }; try policy.validate()
                document.policies.removeAll { $0.owner == owner && $0.volume.id == uuid }
                document.policies.append(.init(volume: volume, owner: owner, policy: policy, nextDue: now.addingTimeInterval(policy.seconds)))
                activity(owner: owner, volume: uuid, action: "policy", status: "success", detail: "Schedule \(policy.enabled ? "enabled" : "disabled"); automatic retention \(policy.retentionEnabled ? "enabled" : "disabled").")
                try commit(); result.message = "Policy saved. Missed schedules coalesce to one attempt; disconnected volumes are skipped."
            case .beginComparison:
                try lifecycleRequire(request.snapshotIDs.count == 2 && request.snapshotIDs[0] != request.snapshotIDs[1], "Choose two different managed snapshots.")
                try lifecycleRequire(document.leases.count < 8, "Too many active comparison leases.")
                let a = try owned(request.snapshotIDs[0], owner: owner), b = try owned(request.snapshotIDs[1], owner: owner)
                let left = try verified(a, volume: volume, owner: owner), right = try verified(b, volume: volume, owner: owner)
                let id = UUID().uuidString
                // Persist paths before mounting so crash recovery can clean even a single successful mount.
                let prefix = SnapshotServiceIdentity.mountRoot + "/" + id
                let lease = SnapshotMountLease(id: id, owner: owner, volumeUUID: uuid, leftSnapshotID: a.id, rightSnapshotID: b.id, leftPath: prefix + "/left", rightPath: prefix + "/right", expires: now.addingTimeInterval(300))
                document.leases.append(lease); leaseSessions[lease.id] = session; try commit()
                do {
                    let l = try backend.mount(volume, snapshot: left, leaseID: id, side: "left", owner: owner)
                    let r = try backend.mount(volume, snapshot: right, leaseID: id, side: "right", owner: owner)
                    try lifecycleRequire(l == lease.leftPath && r == lease.rightPath, "Unexpected comparison mount destination.")
                    result.lease = lease
                } catch {
                    // Keep the durable lease if cleanup fails; retry on the next tick/startup.
                    if (try? release(lease)) != nil {
                        document.leases.removeAll { $0.id == id }; try commit()
                    }
                    throw error
                }
            case .inventory, .endComparison: break
            }
        }
        result.records = document.snapshots.filter { $0.owner == owner }
        result.policies = document.policies.filter { $0.owner == owner }
        result.activities = Array(document.activities.filter { $0.owner == owner }.suffix(500).reversed())
        return result
    }
    func closeLeases() throws {
        var failure: Error?
        for lease in document.leases {
            do { try release(lease); document.leases.removeAll { $0.id == lease.id }; leaseSessions.removeValue(forKey: lease.id); try commit() }
            catch { failure = error }
        }
        if let failure { throw failure }
    }
    func connectionClosed(session: String) throws {
        for lease in document.leases where leaseSessions[lease.id] == session {
            try release(lease)
            document.leases.removeAll { $0.id == lease.id }; leaseSessions.removeValue(forKey: lease.id); try commit()
        }
        let tokens = previewContexts.filter { $0.value.hasSuffix(":" + session) }.map(\.key)
        for token in tokens { previews.removeValue(forKey: token); previewContexts.removeValue(forKey: token) }
    }
    func tick(now: Date = Date()) throws {
        try lifecycleRequire(!poisoned, "Ownership persistence unavailable.")
        for lease in document.leases where lease.expires <= now {
            do {
                try release(lease)
                document.leases.removeAll { $0.id == lease.id }; try commit()
            } catch { /* Keep lease for retry and never force-unmount a reader. */ }
        }
        let due = document.policies.filter { $0.isDue(now: now) }
        for saved in due {
            guard let index = document.policies.firstIndex(where: { $0.id == saved.id }) else { continue }
            document.policies[index].didAttempt(at: now); try commit()
            do {
                let volume = try resolve(saved.volume.id)
                try lifecycleRequire(volume.container == saved.volume.container, "Scheduled volume container changed.")
                if let minimum = saved.policy.minimumFreeBytes, try backend.freeBytes(volume) < minimum {
                    activity(owner: saved.owner, volume: volume.id, action: "schedule", status: "skipped", detail: "Storage-pressure threshold reached; creation skipped. Only configured age/count retention may run.")
                    try commit()
                } else {
                    do { try create(volume: volume, label: "Scheduled \(saved.policy.interval.rawValue)", owner: saved.owner, now: now) }
                    catch {
                        activity(owner: saved.owner, volume: volume.id, action: "schedule", status: "failed", detail: "Creation failed: \(error). Explicitly enabled retention will still be evaluated against verified existing owned snapshots.")
                        try commit()
                    }
                }
                if saved.policy.retentionEnabled {
                    let ids = SnapshotRetention.candidates(records: document.snapshots.filter { $0.owner == saved.owner }, volume: volume, policy: saved.policy, now: now).filter { !isLeased($0.id) }.prefix(256).map(\.id)
                    let plan = try preview(ids: ids, volume: volume, owner: saved.owner, now: now, reason: "Explicitly enabled automatic age/count retention")
                    previews.removeValue(forKey: plan.id); previewContexts.removeValue(forKey: plan.id); try execute(plan, owner: saved.owner, now: now)
                }
            } catch {
                activity(owner: saved.owner, volume: saved.volume.id, action: "schedule", status: "failed", detail: "\(error). No missed-operation backlog will be replayed."); try commit()
            }
        }
    }
}
