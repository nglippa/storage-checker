import Foundation
import Darwin

private final class LifecycleFixtureBackend: SnapshotLifecycleBackend {
    var volume: ManagedVolume
    var connected = true
    var snapshots = [LifecycleSnapshot]()
    var createDenied = false
    var deleteInterrupted = false
    var volumeCalls = 0
    var inventoryCalls = 0
    var createCalls = 0
    var deleteCalls = 0
    var deletedSnapshotIDs = [String]()
    var unmountCalls = [String]()
    var free: Int64 = 1_000_000_000
    init(_ volume: ManagedVolume) { self.volume = volume }
    func volumes() throws -> [ManagedVolume] { volumeCalls += 1; return connected ? [volume] : [] }
    func inventory(_ volume: ManagedVolume) throws -> [LifecycleSnapshot] {
        inventoryCalls += 1
        try lifecycleRequire(connected && volume.container == self.volume.container && volume.id == self.volume.id, "Disconnected/replaced fixture volume.")
        return snapshots
    }
    func create(_ volume: ManagedVolume, name: String) throws {
        if createDenied { throw SnapshotLifecycleError.refused("Permission denied") }
        createCalls += 1
        _ = try inventory(volume)
        snapshots.append(.init(id: UUID().uuidString, name: name, xid: UInt64(snapshots.count + 10)))
        free -= 1024
    }
    func delete(_ volume: ManagedVolume, snapshot: LifecycleSnapshot) throws {
        _ = try inventory(volume)
        if deleteInterrupted { throw SnapshotLifecycleError.refused("Interrupted external volume removal") }
        try lifecycleRequire(snapshots.contains(snapshot), "Identity changed before native deletion.")
        deleteCalls += 1; deletedSnapshotIDs.append(snapshot.id); snapshots.removeAll { $0.id == snapshot.id }; free += 4096
    }
    func freeBytes(_ volume: ManagedVolume) throws -> Int64 { _ = try inventory(volume); return free }
    func mount(_ volume: ManagedVolume, snapshot: LifecycleSnapshot, leaseID: String, side: String, owner: UInt32) throws -> String { SnapshotServiceIdentity.mountRoot + "/" + leaseID + "/" + side }
    func unmount(path: String) throws { unmountCalls.append(path) }
}

enum SnapshotLifecycleEngineTests {
    private static func makeDirectory(_ parent: URL, _ name: String) throws -> URL {
        let value = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return value
    }

    private static func makeEngine(at base: URL, volume: ManagedVolume) throws -> (SnapshotLifecycleEngine, LifecycleFixtureBackend) {
        let backend = LifecycleFixtureBackend(volume)
        let ledger = try SnapshotLifecycleLedger(directory: base.appendingPathComponent("Ledger"), owner: getuid())
        return (try SnapshotLifecycleEngine(ledger: ledger, backend: backend), backend)
    }

    private static func testAutomaticRetention(at parent: URL, volume template: ManagedVolume, now: Date) throws {
        var volume = template; volume.id = UUID().uuidString; volume.container = UUID().uuidString; volume.mountPath = "/Volumes/AutomaticRetention"
        let base = try makeDirectory(parent, "AutomaticRetention")
        let (engine, backend) = try makeEngine(at: base, volume: volume)
        for (owner, age) in [(UInt32(501), 10.0), (501, 9.0), (501, 8.0), (502, 10.0)] {
            _ = try engine.handle(.init(action: .create, volumeUUID: volume.id, label: "owner-\(owner)-\(age)"), owner: owner, now: now.addingTimeInterval(-age * 86400))
        }
        let owner501Before = engine.document.snapshots.filter { $0.owner == 501 && $0.state == .managed }
        let owner502 = engine.document.snapshots.first { $0.owner == 502 && $0.state == .managed }!
        let foreign = LifecycleSnapshot(id: UUID().uuidString, name: "foreign.snapshot", xid: 9_999)
        backend.snapshots.append(foreign)

        var policy = SnapshotPolicy()
        policy.enabled = true; policy.interval = .hourly; policy.maximumCount = 2; policy.maximumAgeDays = 3650; policy.retentionEnabled = true
        _ = try engine.handle(.init(action: .savePolicy, volumeUUID: volume.id, policy: policy), owner: 501, now: now.addingTimeInterval(-7200))
        let createsBeforeTick = backend.createCalls
        try engine.tick(now: now)

        let owner501After = engine.document.snapshots.filter { $0.owner == 501 && $0.state == .managed }
        precondition(backend.createCalls == createsBeforeTick + 1, "due policy must coalesce to one scheduled creation")
        precondition(owner501After.count == 2, "automatic count retention must leave the configured number of owned snapshots")
        precondition(backend.deletedSnapshotIDs == owner501Before.prefix(2).map(\.snapshotUUID), "automatic retention must delete only the oldest eligible owned records")
        precondition(engine.document.snapshots.contains { $0.id == owner502.id && $0.state == .managed }, "one owner cannot retain/delete another owner's records")
        precondition(backend.snapshots.contains(foreign), "foreign native snapshots must never be deleted by automatic retention")
        precondition(!backend.deletedSnapshotIDs.contains(owner502.snapshotUUID) && !backend.deletedSnapshotIDs.contains(foreign.id))
    }

    private static func testPressureRetention(at parent: URL, volume template: ManagedVolume, now: Date) throws {
        var volume = template; volume.id = UUID().uuidString; volume.container = UUID().uuidString; volume.mountPath = "/Volumes/PressureRetention"
        let base = try makeDirectory(parent, "PressureRetention")
        let (engine, backend) = try makeEngine(at: base, volume: volume)
        for age in [4.0, 3.0, 2.0] {
            _ = try engine.handle(.init(action: .create, volumeUUID: volume.id, label: "pressure-\(age)"), owner: 501, now: now.addingTimeInterval(-age * 86400))
        }
        var policy = SnapshotPolicy()
        policy.enabled = true; policy.interval = .hourly; policy.maximumCount = 1; policy.maximumAgeDays = 3650
        policy.minimumFreeBytes = 50_000_000; policy.retentionEnabled = true
        _ = try engine.handle(.init(action: .savePolicy, volumeUUID: volume.id, policy: policy), owner: 501, now: now.addingTimeInterval(-7200))
        let createsBeforeTick = backend.createCalls
        backend.free = 1_000_000
        try engine.tick(now: now)
        precondition(backend.createCalls == createsBeforeTick, "storage pressure must skip scheduled creation")
        precondition(backend.deleteCalls == 2, "explicit retention must still run when pressure skips creation")
        precondition(engine.document.snapshots.filter { $0.owner == 501 && $0.state == .managed }.count == 1)
        precondition(engine.document.activities.contains { $0.action == "schedule" && $0.status == "skipped" })
    }

    private static func testOwnerAndPreviewIdentity(at parent: URL, volume template: ManagedVolume, now: Date) throws {
        var volume = template; volume.id = UUID().uuidString; volume.container = UUID().uuidString; volume.mountPath = "/Volumes/Identity"
        let base = try makeDirectory(parent, "Identity")
        let (engine, backend) = try makeEngine(at: base, volume: volume)
        _ = try engine.handle(.init(action: .create, volumeUUID: volume.id, label: "owner501"), owner: 501, now: now)
        _ = try engine.handle(.init(action: .create, volumeUUID: volume.id, label: "owner502"), owner: 502, now: now)
        let record501 = engine.document.snapshots.first { $0.owner == 501 }!
        let record502 = engine.document.snapshots.first { $0.owner == 502 }!
        let view501 = try engine.handle(.init(action: .inventory), owner: 501)
        let view502 = try engine.handle(.init(action: .inventory), owner: 502)
        precondition(view501.records.map(\.id) == [record501.id] && view502.records.map(\.id) == [record502.id], "responses must isolate persistent ownership by UID")
        do { _ = try engine.handle(.init(action: .previewManual, volumeUUID: volume.id, snapshotIDs: [record501.id]), owner: 502); fatalError("foreign owner record previewed") } catch {}

        let original = backend.snapshots.first { $0.id == record501.snapshotUUID }!
        func expectStaleRejected(_ mutate: (inout LifecycleSnapshot) -> Void, _ message: String) throws {
            guard let index = backend.snapshots.firstIndex(where: { $0.id == record501.snapshotUUID }) else { fatalError("fixture snapshot missing") }
            let preview = try engine.handle(.init(action: .previewManual, volumeUUID: volume.id, snapshotIDs: [record501.id]), owner: 501, session: message).preview!
            mutate(&backend.snapshots[index])
            let calls = backend.deleteCalls
            do { _ = try engine.handle(.init(action: .deletePreview, volumeUUID: volume.id, token: preview.id), owner: 501, session: message); fatalError("stale \(message) preview accepted") } catch {}
            precondition(backend.deleteCalls == calls && engine.document.snapshots.first { $0.id == record501.id }?.state == .managed)
            backend.snapshots[index] = original
        }
        try expectStaleRejected({ $0.xid = ($0.xid ?? 0) + 1 }, "xid")
        try expectStaleRejected({ $0.name += ".renamed" }, "name")
        try expectStaleRejected({ $0.id = UUID().uuidString }, "uuid")
    }

    private static func testCorruptPersistenceFailsBeforeBackend(at parent: URL, volume template: ManagedVolume, now: Date) throws {
        var volume = template; volume.id = UUID().uuidString; volume.container = UUID().uuidString; volume.mountPath = "/Volumes/Corrupt"
        for kind in ["BadLease", "DuplicateOwnership"] {
            let base = try makeDirectory(parent, kind)
            let ledgerURL = base.appendingPathComponent("Ledger")
            var document = SnapshotLedgerDocument()
            let first = ManagedSnapshot(volume: volume, domain: document.domain, name: "first", snapshotUUID: UUID().uuidString, xid: 1, createdAt: now, owner: 501)
            var second = ManagedSnapshot(volume: volume, domain: document.domain, name: "second", snapshotUUID: UUID().uuidString, xid: 2, createdAt: now, owner: 501)
            document.snapshots = [first, second]
            if kind == "BadLease" {
                document.leases = [.init(id: UUID().uuidString, owner: 501, volumeUUID: volume.id, leftSnapshotID: first.id, rightSnapshotID: second.id, leftPath: "/", rightPath: "/private/tmp/not-a-lease", expires: now)]
            } else {
                second.snapshotUUID = first.snapshotUUID
                document.snapshots[1] = second
            }
            var writer: SnapshotLifecycleLedger? = try SnapshotLifecycleLedger(directory: ledgerURL, owner: getuid())
            try writer!.save(document); writer = nil
            let backend = LifecycleFixtureBackend(volume)
            do {
                let reader = try SnapshotLifecycleLedger(directory: ledgerURL, owner: getuid())
                _ = try SnapshotLifecycleEngine(ledger: reader, backend: backend)
                fatalError("\(kind) persistence accepted")
            } catch {}
            precondition(backend.volumeCalls == 0 && backend.inventoryCalls == 0 && backend.createCalls == 0 && backend.deleteCalls == 0 && backend.unmountCalls.isEmpty, "corrupt persistence must fail before backend/native side effects")
        }
    }

    static func run() throws {
        let base = URL(fileURLWithPath: "/private/tmp/storage-lifecycle-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let volume = ManagedVolume(id: UUID().uuidString, container: UUID().uuidString, name: "Disposable", mountPath: "/Volumes/Fixture", device: "disk99s1", roles: [], writable: true, local: true)
        let backend = LifecycleFixtureBackend(volume)
        let ledger = try SnapshotLifecycleLedger(directory: base.appendingPathComponent("Ledger"), owner: getuid())
        let engine = try SnapshotLifecycleEngine(ledger: ledger, backend: backend)
        do { _ = try SnapshotLifecycleLedger(directory: base.appendingPathComponent("Ledger"), owner: getuid()); fatalError("overlapping process lock accepted") } catch {}
        let now = Date()
        _ = try engine.handle(.init(action: .create, volumeUUID: volume.id, label: "Manual"), owner: 501, now: now)
        let first = engine.document.snapshots[0]
        precondition(first.state == .managed && backend.snapshots.count == 1)
        let persisted = try ledger.load()
        precondition(persisted.snapshots[0] == first, "ownership persists independently of GUI/preferences")
        // A foreign native snapshot with our prefix but no ownership record is never adopted/deleted.
        backend.snapshots.append(.init(id: UUID().uuidString, name: "local.storage-monitor.impostor", xid: 99))
        do { _ = try engine.handle(.init(action: .previewManual, volumeUUID: volume.id, snapshotIDs: [backend.snapshots.last!.id]), owner: 501); fatalError("name-only ownership accepted") } catch {}
        do { _ = try engine.handle(.init(action: .protect, volumeUUID: volume.id, snapshotIDs: [first.id, UUID().uuidString], protected: true), owner: 501); fatalError("partial protection batch accepted") } catch {}
        precondition(!engine.document.snapshots[0].protected, "failed batch must leave in-memory and persistent state untouched")
        let preview = try engine.handle(.init(action: .previewManual, volumeUUID: volume.id, snapshotIDs: [first.id]), owner: 501, session: "one").preview!
        do { _ = try engine.handle(.init(action: .deletePreview, volumeUUID: volume.id, token: preview.id), owner: 501, session: "two"); fatalError("cross-connection preview token accepted") } catch {}
        _ = try engine.handle(.init(action: .protect, volumeUUID: volume.id, snapshotIDs: [first.id], protected: true), owner: 501)
        do { _ = try engine.handle(.init(action: .deletePreview, volumeUUID: volume.id, token: preview.id), owner: 501, session: "one"); fatalError("stale/protected preview accepted") } catch {}
        precondition(backend.deleteCalls == 0)
        _ = try engine.handle(.init(action: .protect, volumeUUID: volume.id, snapshotIDs: [first.id], protected: false), owner: 501)
        let valid = try engine.handle(.init(action: .previewManual, volumeUUID: volume.id, snapshotIDs: [first.id]), owner: 501).preview!
        _ = try engine.handle(.init(action: .deletePreview, volumeUUID: volume.id, token: valid.id), owner: 501)
        precondition(backend.deleteCalls == 1 && backend.snapshots.count == 1 && engine.document.snapshots[0].state == .deleted)
        precondition(engine.document.activities.last?.observedCapacityChange == 4096)
        do { _ = try engine.handle(.init(action: .deletePreview, volumeUUID: volume.id, token: valid.id), owner: 501); fatalError("preview replay accepted") } catch {}
        backend.createDenied = true
        do { _ = try engine.handle(.init(action: .create, volumeUUID: volume.id), owner: 501); fatalError("permission denial treated as success") } catch {}
        precondition(engine.document.snapshots.last?.state == .quarantined && engine.document.activities.last?.status == "failed")
        backend.createDenied = false
        var policy = SnapshotPolicy(); policy.enabled = true; policy.interval = .hourly
        _ = try engine.handle(.init(action: .savePolicy, volumeUUID: volume.id, policy: policy), owner: 501, now: now)
        let before = backend.snapshots.count
        try engine.tick(now: now.addingTimeInterval(36_000))
        precondition(backend.snapshots.count == before + 1, "one catch-up creation, not ten")
        try engine.tick(now: now.addingTimeInterval(36_001))
        precondition(backend.snapshots.count == before + 1, "no overlap or backlog")
        let activeRecords = engine.document.snapshots.filter { $0.state == .managed }
        if activeRecords.count >= 1 {
            _ = try engine.handle(.init(action: .create, volumeUUID: volume.id), owner: 501)
            let pair = engine.document.snapshots.filter { $0.state == .managed }.suffix(2).map(\.id)
            let lease = try engine.handle(.init(action: .beginComparison, volumeUUID: volume.id, snapshotIDs: pair), owner: 501).lease!
            do { _ = try engine.handle(.init(action: .previewManual, volumeUUID: volume.id, snapshotIDs: pair), owner: 501); fatalError("leased snapshots eligible for deletion") } catch {}
            _ = try engine.handle(.init(action: .endComparison, token: lease.id), owner: 501)
        }
        backend.connected = false
        try engine.tick(now: now.addingTimeInterval(40_000))
        precondition(engine.document.activities.last?.status == "failed")
        policy.enabled = false
        _ = try engine.handle(.init(action: .savePolicy, volumeUUID: volume.id, policy: policy), owner: 501)
        precondition(!engine.document.policies[0].policy.enabled, "offline policies can be disabled")
        backend.connected = true
        _ = try engine.handle(.init(action: .create, volumeUUID: volume.id), owner: 501)
        let interruptRecord = engine.document.snapshots.last!
        let interruptPreview = try engine.handle(.init(action: .previewManual, volumeUUID: volume.id, snapshotIDs: [interruptRecord.id]), owner: 501).preview!
        backend.deleteInterrupted = true
        do { _ = try engine.handle(.init(action: .deletePreview, volumeUUID: volume.id, token: interruptPreview.id), owner: 501); fatalError("interrupted deletion succeeded") } catch {}
        precondition(engine.document.snapshots.last?.state == .quarantined)
        backend.deleteInterrupted = false
        _ = try engine.handle(.init(action: .recover, volumeUUID: volume.id, snapshotIDs: [interruptRecord.id]), owner: 501)
        precondition(engine.document.snapshots.last?.state == .managed && engine.document.snapshots.last?.protected == true, "recovered snapshot must be protected")
        // Cold start from a durable pre-mutation intent must not automatically adopt or retry.
        let recovery = base.appendingPathComponent("Recovery")
        do {
            let recoveryLedger = try SnapshotLifecycleLedger(directory: recovery, owner: getuid())
            var document = SnapshotLedgerDocument()
            var ambiguous = ManagedSnapshot(volume: volume, domain: document.domain, name: "crash", snapshotUUID: "", xid: nil, createdAt: now, owner: 501)
            ambiguous.state = .creating; document.snapshots.append(ambiguous)
            document.activities.append(.init(owner: 501, volumeUUID: volume.id, action: "create", status: "pending", detail: "intent"))
            try recoveryLedger.save(document)
        }
        let recovered = try SnapshotLifecycleEngine(ledger: SnapshotLifecycleLedger(directory: recovery, owner: getuid()), backend: backend)
        precondition(recovered.document.snapshots[0].state == .quarantined && recovered.document.activities[0].status == "interrupted")
        try testAutomaticRetention(at: base, volume: volume, now: now)
        try testPressureRetention(at: base, volume: volume, now: now)
        try testOwnerAndPreviewIdentity(at: base, volume: volume, now: now)
        try testCorruptPersistenceFailsBeforeBackend(at: base, volume: volume, now: now)
        let invalidPolicyDirectory = base.appendingPathComponent("InvalidPolicy")
        do {
            let badLedger = try SnapshotLifecycleLedger(directory: invalidPolicyDirectory, owner: getuid())
            var bad = SnapshotLedgerDocument(), policy = SnapshotPolicy()
            policy.enabled = true; policy.maximumCount = 0
            bad.policies.append(.init(volume: volume, owner: 501, policy: policy, nextDue: Date()))
            try badLedger.save(bad)
        }
        do {
            _ = try SnapshotLifecycleEngine(ledger: SnapshotLifecycleLedger(directory: invalidPolicyDirectory, owner: getuid()), backend: backend)
            fatalError("invalid persisted scheduling policy accepted")
        } catch {}
        print("PASS persistent ownership, one-use/session-bound previews, owner isolation, stale tuple rejection, automatic/pressure retention, corruption fail-closed, protection, create/delete, observed capacity, offline scheduling, lock and interruption recovery")
    }
}
