import Foundation

/// Bounded, read-only discovery shared by the viewer fallback and privileged service.
/// No diskutil mutation verbs are accepted here.
enum SnapshotPlatformInventory {
    static func plist(_ arguments: [String]) throws -> [String: Any] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil"); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let lock = NSLock()
        var data = Data(), exceeded = false
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); defer { lock.unlock() }
            if data.count + chunk.count <= 4*1024*1024 { data.append(chunk) } else { exceeded = true }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.05); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); output.fileHandleForReading.readabilityHandler = nil; throw SnapshotLifecycleError.refused("APFS discovery timed out.") }
        process.waitUntilExit(); output.fileHandleForReading.readabilityHandler = nil
        let rest = output.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); data.append(rest); let overflow = exceeded || data.count > 4*1024*1024; lock.unlock()
        try lifecycleRequire(process.terminationStatus == 0 && !overflow, "APFS inventory unavailable (permission, disconnection or output limit).")
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw SnapshotLifecycleError.refused("Invalid APFS inventory response.") }
        return result
    }
    static func volumes() throws -> [ManagedVolume] {
        let list = try plist(["apfs", "list", "-plist"])
        var result = [ManagedVolume]()
        for container in (list["Containers"] as? [[String: Any]] ?? []).prefix(64) {
            guard let rawContainer = container["APFSContainerUUID"] as? String, let containerID = UUID(uuidString: rawContainer)?.uuidString else { continue }
            for volume in (container["Volumes"] as? [[String: Any]] ?? []).prefix(64) {
                guard let raw = volume["APFSVolumeUUID"] as? String, let uuid = UUID(uuidString: raw)?.uuidString,
                      let device = volume["DeviceIdentifier"] as? String, device.range(of: "^disk[0-9]+s[0-9]+$", options: .regularExpression) != nil else { continue }
                // Inspection/management is deliberately restricted to roleless base volumes. Historical
                // intelligence continues to observe System/Data and other APFS roles separately.
                let roles = volume["Roles"] as? [String] ?? ["Unknown"]
                var path = volume["MountPoint"] as? String ?? ""
                var writable = false, local = true
                if roles.isEmpty, let info = try? plist(["info", "-plist", device]) {
                    let infoUUID = ((info["VolumeUUID"] as? String) ?? (info["APFSVolumeUUID"] as? String)).flatMap { UUID(uuidString: $0)?.uuidString }
                    guard infoUUID == uuid, info["FilesystemType"] as? String == "apfs", info["APFSContainerReference"] as? String == container["ContainerReference"] as? String else { continue }
                    path = info["MountPoint"] as? String ?? ""
                    writable = info["Mounted"] as? Bool != false && info["Locked"] as? Bool != true && info["WritableVolume"] as? Bool == true && info["WritableMedia"] as? Bool != false && !path.isEmpty
                    local = !(info["BusProtocol"] as? String == "Network")
                }
                result.append(.init(id: uuid, container: containerID, name: volume["Name"] as? String ?? uuid, mountPath: path, device: device, roles: roles, writable: writable, local: local))
            }
        }
        try lifecycleRequire(Set(result.map(\.id)).count == result.count, "Duplicate APFS volume identities; management disabled.")
        return result
    }
    static func inventory(_ volume: ManagedVolume) throws -> [LifecycleSnapshot] {
        let value = try plist(["apfs", "listSnapshots", "-plist", volume.device])
        guard let rows = value["Snapshots"] as? [[String: Any]] else { throw SnapshotLifecycleError.refused("Snapshot inventory is unavailable; no absence inferred.") }
        try lifecycleRequire(rows.count <= 4096, "Snapshot inventory exceeds its safety limit.")
        let snapshots = try rows.map { row -> LifecycleSnapshot in
            guard let raw = row["SnapshotUUID"] as? String, let uuid = UUID(uuidString: raw)?.uuidString, let name = row["Name"] as? String, name.utf8.count <= 255 else { throw SnapshotLifecycleError.refused("Invalid snapshot identity.") }
            return LifecycleSnapshot(id: uuid, name: name, xid: (row["XID"] as? NSNumber)?.uint64Value, purgeable: row["Purgeable"] as? Bool)
        }
        try lifecycleRequire(Set(snapshots.map(\.id)).count == snapshots.count && Set(snapshots.map(\.name)).count == snapshots.count, "Ambiguous snapshot inventory.")
        return snapshots
    }
}
