import Foundation
import Darwin
import SQLite3

struct ExternalCapacityGroup {
    let paths: ExternalVolumePaths
    let descriptors: [ExternalVolumeDescriptor]
    var enrolledNames: [String] = []
    var label: String {
        let labels = enrolledNames.isEmpty ? descriptors.map(\.name) : enrolledNames
        let names = labels.sorted().joined(separator: ", ")
        return names + (paths.capacityScope.hasPrefix("apfs:") ? (labels.count > 1 ? " (shared APFS container)" : " (APFS container)") : "")
    }
}

enum ExternalCapacityMonitoring {
    static let offlineGap: TimeInterval = 75 * 60

    static func groups(baseDirectory: URL, descriptors: [ExternalVolumeDescriptor]) throws -> [ExternalCapacityGroup] {
        let registry = ExternalVolumeRegistry(baseDirectory: baseDirectory), settings = try registry.read()
        var grouped = [String: [ExternalVolumeDescriptor]]()
        for saved in settings.volumes.values.sorted(by: { $0.volumeUUID < $1.volumeUUID }) where saved.enabled {
            // One invalid or absent target cannot prevent another scope from being measured.
            guard let candidate = try? ExternalVolumeCatalog.resolve(uuid: saved.volumeUUID, descriptors: descriptors) else { continue }
            guard (try? registry.validate(candidate)) != nil else { continue }
            grouped[saved.capacityScope, default: []].append(candidate)
        }
        return try grouped.keys.sorted().compactMap { scope in
            let members = grouped[scope]!
            let knownBackings = try Set(members.map { try $0.normalizedBacking() }.filter { !$0.isEmpty })
            guard knownBackings.count <= 1 else { log(baseDirectory, "external capacity identity conflict: \(scope)"); return nil }
            let names = settings.volumes.values.filter { $0.enabled && $0.capacityScope == scope }.map { saved in
                members.first { (try? $0.identity().uuid) == saved.volumeUUID }?.name ?? saved.name
            }
            return ExternalCapacityGroup(paths: try ExternalVolumePaths(baseDirectory: baseDirectory, uuid: members[0].identity().uuid, capacityScope: scope), descriptors: members, enrolledNames: names)
        }
    }

    static func measure(_ group: ExternalCapacityGroup, lease: ExternalVolumeMountLease, containers: [[String: Any]]?) throws -> Reading {
        try lease.validate()
        let descriptor = lease.descriptor
        let free: Int64, total: Int64, volumes: String
        if descriptor.filesystem.lowercased() == "apfs" {
            guard let container = containers?.first(where: { ($0["APFSContainerUUID"] as? String).flatMap { try? ExternalVolumeIdentity($0).uuid } == descriptor.containerUUID }),
                  let available = number(container["CapacityFree"]), let ceiling = number(container["CapacityCeiling"]),
                  let members = container["Volumes"] as? [[String: Any]],
                  members.contains(where: { ($0["APFSVolumeUUID"] as? String).flatMap { try? ExternalVolumeIdentity($0).uuid } == lease.registration.volumeUUID }) else {
                throw Failure("External APFS container capacity could not be verified")
            }
            free = available; total = ceiling; volumes = json(members)
        } else {
            var value = statfs()
            try required(statfs(descriptor.mountPath, &value) == 0, "External filesystem capacity unavailable")
            let block = Int64(value.f_bsize)
            try required(block > 0 && value.f_bavail <= UInt64(Int64.max / block) && value.f_blocks <= UInt64(Int64.max / block), "Invalid external filesystem counters")
            free = Int64(value.f_bavail) * block; total = Int64(value.f_blocks) * block
            volumes = json([["VolumeUUID": lease.registration.volumeUUID, "Name": descriptor.name, "CapacityInUse": total - free, "Roles": []] as [String: Any]])
        }
        try required(free >= 0 && total > 0 && free <= total, "Invalid external capacity")
        try lease.validate()
        return Reading(timestamp: Date().timeIntervalSince1970, container: group.paths.capacityScope, free: free, used: total - free, volumes: volumes)
    }

    /// Capacity history has no startup attribution or diagnostics. All callers validate the live mount before committing.
    @discardableResult static func store(_ current: Reading, paths: ExternalVolumePaths, label: String,
                                         identityFingerprint: String? = nil,
                                         validate: () throws -> Void,
                                         notification: (String, String) -> String = notify) throws -> Evaluation? {
        try validate()
        try required(current.container == paths.capacityScope && current.timestamp.isFinite && current.free >= 0 && current.used >= 0 &&
                     current.free <= Int64.max - current.used && current.free + current.used > 0, "Invalid external reading identity or capacity")
        try paths.prepare()
        guard let lock = FileLock(paths.capacityDirectory.appendingPathComponent("check.lock").path, wait: 0) else { return nil }
        defer { withExtendedLifetime(lock) {} }
        let db = try Database(paths.capacityDatabase, noFollow: true)
        try db.exec("CREATE TABLE IF NOT EXISTS external_capacity_sessions(reading_id INTEGER PRIMARY KEY)")
        let previous = try db.rows("SELECT * FROM readings WHERE container=? ORDER BY timestamp DESC,id DESC LIMIT 1", [current.container]).first.flatMap(reading)
        if let previous, previous.timestamp >= current.timestamp { return nil }
        let previousFingerprint = try db.state("external_capacity_backing")
        let lineageChanged = identityFingerprint.map { $0 != previousFingerprint } ?? false
        let newSession = lineageChanged || (previous.map { current.timestamp - $0.timestamp > offlineGap } ?? true)
        let sessionTime = try db.rows("SELECT timestamp FROM readings WHERE id IN (SELECT reading_id FROM external_capacity_sessions) ORDER BY timestamp DESC LIMIT 1").first?["timestamp"].flatMap(Double.init) ?? 0
        let window = newSession ? [] : try db.rows("SELECT * FROM readings WHERE container=? AND timestamp>=? AND timestamp<?", [current.container, max(current.timestamp - 7200, sessionTime), current.timestamp]).compactMap(reading)
        let evaluation = evaluate(current, newSession ? nil : previous, window)
        let plan = try AlertPlan(db, current, evaluation)
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.write("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES(?,?,?,?,?)", [current.timestamp, current.container, current.free, current.used, current.volumes])
            let id = sqlite3_last_insert_rowid(db.db)
            if newSession { try db.write("INSERT INTO external_capacity_sessions(reading_id) VALUES(?)", [id]) }
            try plan.persist(db, current)
            if let identityFingerprint { try db.state("external_capacity_backing", identityFingerprint) }
            try validate()
            try db.exec("COMMIT")
        } catch { try? db.exec("ROLLBACK"); throw error }
        var result = "deduplicated"
        if plan.needsNotification {
            // Never post a stale drive alert after its settings or mount changed.
            try validate()
            result = notification(label + " — Storage " + evaluation.severity.uppercased(), "\(size(current.free)) free. \(evaluation.reasons.joined(separator: "; "))")
            try plan.notificationResult(db, current, result)
        }
        if !plan.newReasons.isEmpty || plan.needsNotification {
            try db.write("INSERT INTO alerts(timestamp,severity,reasons,free,delta,notification) VALUES(?,?,?,?,?,?)", [current.timestamp, evaluation.severity, plan.signature, current.free, evaluation.delta as Any, result])
        }
        try db.retain(current.timestamp)
        try db.exec("DELETE FROM external_capacity_sessions WHERE reading_id NOT IN (SELECT id FROM readings)")
        return evaluation
    }

    static func sample(baseDirectory: URL, observations: ExternalVolumeObservations) throws {
        let targets = try groups(baseDirectory: baseDirectory, descriptors: observations.descriptors)
        let topology = targets.contains { $0.paths.capacityScope.hasPrefix("apfs:") } ? (try? plistCommand(["apfs", "list", "-plist"])["Containers"] as? [[String: Any]]) : nil
        for target in targets {
            do {
                let lease = try ExternalVolumeMountLease(descriptor: target.descriptors[0], registry: ExternalVolumeRegistry(baseDirectory: baseDirectory), indexing: false)
                let value = try measure(target, lease: lease, containers: topology)
                _ = try store(value, paths: target.paths, label: target.label,
                    identityFingerprint: "backing:" + lease.registration.backingUUIDs.joined(separator: ","), validate: lease.validate)
            } catch { log(baseDirectory, "external capacity \(target.paths.identity.uuid): \(error)") }
        }
    }
}
