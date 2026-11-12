import Foundation
import Darwin

/// Read-only APFS metadata. Uses the existing bounded, draining, reaping command runner.
/// No snapshot management command, private APFS ioctl, entitlement, mount or sudo path exists here.
enum SnapshotObserver {
    typealias Runner = (String, [String], Double, Int) throws -> CommandResult
    static let maximumVolumes = 32
    static let outputLimit = 524_288

    static func capture(_ reading: Reading, enrolled: Set<String>? = nil, includeVM: Bool = true,
                        budget: Double = 12, runner: Runner = { try run($0, $1, timeout: $2, cap: $3) },
                        capacityPaths: [String: String]? = nil) -> StorageObservation {
        let start = ProcessInfo.processInfo.systemUptime
        let volumes = ((try? JSONSerialization.jsonObject(with: Data(reading.volumes.utf8))) as? [[String: Any]]) ?? []
        let paths = capacityPaths ?? mountedPaths()
        var inventories = [SnapshotInventory](), capacities = [VolumeCapacityObservation](), seen = Set<String>()
        var totalSnapshots = 0
        func remaining() -> Double { budget - (ProcessInfo.processInfo.systemUptime - start) }
        func command(_ args: [String]) throws -> CommandResult {
            try required(remaining() > 0.05, "Snapshot observation deadline reached")
            return try runner("/usr/sbin/diskutil", args, min(2, remaining()), outputLimit)
        }
        for volume in volumes {
            guard let rawUUID = volume["APFSVolumeUUID"] as? String, let uuid = UUID(uuidString: rawUUID)?.uuidString,
                  enrolled == nil || enrolled!.contains(uuid), seen.insert(uuid).inserted else { continue }
            let name = volume["Name"] as? String ?? uuid
            var status: SnapshotInventoryStatus = .unavailable
            var detail = "Snapshot inventory unavailable; no absence or deletion is inferred."
            var snapshots = [APFSSnapshotRecord]()
            let observedAt = Date().timeIntervalSince1970
            if inventories.count >= maximumVolumes || remaining() <= 0.05 {
                status = .skipped; detail = "Snapshot observation reached its volume or time limit."
            } else if let device = volume["DeviceIdentifier"] as? String,
                      device.range(of: "^disk[0-9]+s[0-9]+$", options: .regularExpression) != nil {
                do {
                    // Device numbers are transient. Verify UUID and unlocked state on both sides.
                    let before = try completePlist(command(["info", "-plist", device]))
                    try verify(before, uuid: uuid)
                    var listingDevice = device
                    var bootDevice: String?, bootUUID: String?
                    // The sealed System volume is usually unmounted: macOS boots from a
                    // 3-part snapshot device. diskutil documents accepting that device for listing.
                    if includeVM, (volume["Roles"] as? [String] ?? []).contains("System"),
                       (before["MountPoint"] as? String ?? "").isEmpty {
                        let boot = try completePlist(command(["info", "-plist", "/"]))
                        if let mounted = boot["DeviceIdentifier"] as? String,
                           mounted.hasPrefix(device + "s"), mounted.range(of: "^disk[0-9]+s[0-9]+s[0-9]+$", options: .regularExpression) != nil,
                           boot["APFSSnapshot"] as? Bool == true,
                           let reference = before["APFSContainerReference"] as? String,
                           boot["APFSContainerReference"] as? String == reference,
                           let id = boot["APFSSnapshotUUID"] as? String, UUID(uuidString: id) != nil {
                            listingDevice = mounted; bootDevice = mounted; bootUUID = id
                        }
                    }
                    let listed = try command(["apfs", "listSnapshots", "-plist", listingDevice])
                    _ = try completePlist(listed)
                    let inventory = try SnapshotInventory.parseDiskutil(listed.data, volumeUUID: uuid, volumeName: name, observedAt: observedAt)
                    let after = try completePlist(command(["info", "-plist", device]))
                    try verify(after, uuid: uuid)
                    try required(before["DeviceIdentifier"] as? String == after["DeviceIdentifier"] as? String,
                                 "Volume identity changed during snapshot observation")
                    if let bootDevice {
                        let boot = try completePlist(command(["info", "-plist", "/"]))
                        try required(boot["DeviceIdentifier"] as? String == bootDevice && boot["APFSSnapshotUUID"] as? String == bootUUID,
                                     "Boot snapshot identity changed during observation")
                    }
                    try required(totalSnapshots + inventory.snapshots.count <= 4096, "Snapshot observation exceeded its record limit")
                    totalSnapshots += inventory.snapshots.count
                    snapshots = inventory.snapshots; status = .complete
                    detail = "diskutil apfs listSnapshots -plist; UUID verified before and after. Creation time and exclusive snapshot bytes are not exposed by this interface."
                    if let path = paths[uuid], remaining() > 0.05 {
                        capacities.append(capacity(uuid: uuid, path: path))
                    }
                } catch {
                    detail = "Snapshot metadata could not be verified (permission, locked/unavailable volume, invalid output or collection limit). \(String(describing: error).prefix(240))"
                }
            }
            if inventories.count < maximumVolumes {
                inventories.append(SnapshotInventory(volumeUUID: uuid, volumeName: name, observedAt: observedAt,
                                                     status: status, detail: detail, snapshots: snapshots))
            }
        }
        // Swap belongs to the startup VM-role volume, never an enrolled external container.
        let hasVM = includeVM && volumes.contains { ($0["Roles"] as? [String] ?? []).contains("VM") }
        let swap = hasVM ? swapObservation() : [:]
        let vm = hasVM ? vmObservation() : [:]
        let counters = vm["status"] as? String == "complete" ? vm.reduce(into: [String: Int64]()) { result, pair in
            if pair.key != "observed_at", let value = number(pair.value) { result[pair.key] = value }
        } : nil
        let swapComplete = swap["status"] as? String == "complete"
        var result = StorageObservation(container: reading.container, observedAt: reading.timestamp,
            finishedAt: Date().timeIntervalSince1970, inventories: inventories, capacities: capacities,
            swapAllocatedBytes: swapComplete ? number(swap["allocated_bytes"]) : nil,
            swapUsedBytes: swapComplete ? number(swap["used_bytes"]) : nil, vmCounters: counters,
            detail: "Read-only observations near the capacity reading, not an atomic filesystem state. Collection took \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - start)) s. \(seen.count) eligible volumes; \(inventories.count) inventory outcomes recorded. Unmounted, locked, unselected or over-limit volumes may be absent. Swap/VM \(hasVM ? (swapComplete ? "observed via sysctl/Mach" : "unavailable") : "not collected for this scope"). Purgeable/reclaimable bytes and exclusive snapshot sizes are unknown. This collector is read-only. Separately authorized snapshot-management activity, if enabled, is recorded in the management ledger.")
        var boot = [CChar](repeating: 0, count: 128), count = 128
        if sysctlbyname("kern.bootsessionuuid", &boot, &count, nil, 0) == 0 { result.bootSession = UUID(uuidString: String(cString: boot))?.uuidString }
        result.uptime = start
        return result
    }

    private static func verify(_ info: [String: Any], uuid: String) throws {
        let identity = (info["VolumeUUID"] as? String ?? info["APFSVolumeUUID"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
        try required(identity == uuid && info["Locked"] as? Bool != true &&
                     (info["FilesystemType"] as? String)?.lowercased() == "apfs", "APFS volume identity or unlocked state could not be verified")
    }

    private static func mountedPaths() -> [String: String] {
        var result = [String: String]()
        for path in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [] {
            let url = URL(fileURLWithPath: path.path) // fresh URL; never reuse cached capacity resource values
            if let id = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString,
               let uuid = UUID(uuidString: id)?.uuidString { result[uuid] = url.path }
        }
        return result
    }

    private static func capacity(uuid: String, path: String) -> VolumeCapacityObservation {
        let url = URL(fileURLWithPath: path)
        let time = Date().timeIntervalSince1970
        func identity() -> String? {
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString.flatMap { UUID(uuidString: $0)?.uuidString }
        }
        guard identity() == uuid else {
            return VolumeCapacityObservation(volumeUUID: uuid, path: path, observedAt: time, availableBytes: nil,
                importantAvailableBytes: nil, opportunisticAvailableBytes: nil, detail: "Mount identity unavailable; capacities not measured.")
        }
        let ordinary = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        let important = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        let opportunistic = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey]))?.volumeAvailableCapacityForOpportunisticUsage
        let valid = identity() == uuid
        func bytes(_ value: Int64?) -> Int64? { valid ? value.flatMap { $0 >= 0 ? $0 : nil } : nil }
        return VolumeCapacityObservation(volumeUUID: uuid, path: path, observedAt: time, availableBytes: bytes(ordinary),
            importantAvailableBytes: bytes(important), opportunisticAvailableBytes: bytes(opportunistic),
            detail: "Foundation volumeAvailableCapacity / ForImportantUsage / ForOpportunisticUsage. Policy-dependent, possibly rounded and not atomic with CapacityFree. Differences are not a measurement of purgeable bytes. \(valid ? "Mount UUID verified." : "Mount changed; values discarded.")")
    }
}

func storeStorageObservation(_ observation: StorageObservation, readingID: Int64, reading: Reading, db: Database) throws {
    let encoded = try observation.encoded()
    try required(observation.container == reading.container && abs(observation.observedAt - reading.timestamp) < 0.001 &&
                 StorageObservation.decode(encoded) != nil, "Storage observation does not match its capacity reading or exceeded its limits")
    try db.write("INSERT OR REPLACE INTO storage_observations(reading_id,timestamp,observation) VALUES(?,?,?)", [readingID, reading.timestamp, encoded])
}

/// Optional evidence is isolated from required capacity history. Never call this helper from
/// inside a caller-owned transaction: transaction-ending SQLite failures must not reach backward
/// and discard the capacity reading or its alert/session state.
func storeOptionalStorageObservation(_ observation: StorageObservation, readingID: Int64, reading: Reading,
                                     db: Database, logDirectory: URL) {
    do {
        try required(!db.transactionActive, "Optional storage evidence cannot nest in a transaction")
        try db.exec("BEGIN IMMEDIATE")
        do {
            try storeStorageObservation(observation, readingID: readingID, reading: reading, db: db)
            try db.retainStorageObservations()
            try db.exec("COMMIT")
        } catch {
            if db.transactionActive { try? db.exec("ROLLBACK") }
            throw error
        }
    } catch {
        log(logDirectory, "Snapshot/system evidence unavailable for reading #\(readingID): \(error)")
    }
}
