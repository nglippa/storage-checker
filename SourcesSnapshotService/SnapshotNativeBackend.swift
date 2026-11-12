import Foundation
import Darwin

final class NativeSnapshotBackend: SnapshotLifecycleBackend {
    func volumes() throws -> [ManagedVolume] { try SnapshotPlatformInventory.volumes() }
    func inventory(_ volume: ManagedVolume) throws -> [LifecycleSnapshot] {
        let current = try current(volume)
        let result = try SnapshotPlatformInventory.inventory(current)
        _ = try self.current(current)
        return result
    }
    private func current(_ expected: ManagedVolume) throws -> ManagedVolume {
        let matches = try volumes().filter { $0.id == expected.id }
        try lifecycleRequire(matches.count == 1, "Volume disconnected or identity unavailable.")
        let result = matches[0]
        try lifecycleRequire(result.compatibilityIssue == nil && result.container == expected.container, result.compatibilityIssue ?? "Volume/container identity changed.")
        return result
    }
    private func withVolume<T>(_ expected: ManagedVolume, body: (Int32, ManagedVolume) throws -> T) throws -> T {
        let volume = try current(expected)
        let fd = sm_snapshot_open(volume.mountPath, volume.id, volume.device)
        try lifecycleRequire(fd >= 0, "Native volume identity/capability check failed: \(fd < 0 ? String(cString: strerror(-fd)) : "unknown").")
        defer { close(fd) }
        let checked = try current(volume)
        try lifecycleRequire(checked.device == volume.device && checked.mountPath == volume.mountPath, "Volume mount changed before operation.")
        return try body(fd, checked)
    }
    private func requirePrivilege() throws {
        try lifecycleRequire(geteuid() == 0 && sm_snapshot_has_entitlement() == 1, "Snapshot mutations require the explicitly enabled, properly signed root helper and Apple's accepted com.apple.developer.vfs.snapshot entitlement. This build has not established that capability.")
    }
    private func nativeResult(_ result: Int32) throws {
        try lifecycleRequire(result == 0, "Native snapshot operation failed: \(String(cString: strerror(result))) (\(result)). Permission/entitlement denial is not success.")
    }
    func create(_ volume: ManagedVolume, name: String) throws {
        try requirePrivilege()
        try lifecycleRequire(name.utf8.count <= 200 && !name.contains("/") && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && name.range(of: "^local\\.storage-monitor\\.[a-f0-9-]{36}\\.[a-f0-9-]{36}\\..+$", options: .regularExpression) != nil, "Refusing an unmanaged native snapshot name.")
        try withVolume(volume) { fd, checked in
            try lifecycleRequire(try !SnapshotPlatformInventory.inventory(checked).contains { $0.name == name }, "Native snapshot name collision.")
            try nativeResult(sm_snapshot_create(fd, name))
        }
    }
    func delete(_ volume: ManagedVolume, snapshot: LifecycleSnapshot) throws {
        try requirePrivilege()
        try withVolume(volume) { fd, checked in
            let matches = try SnapshotPlatformInventory.inventory(checked).filter { $0.id == snapshot.id }
            try lifecycleRequire(matches.count == 1 && matches[0] == snapshot && !snapshot.name.hasPrefix("com.apple."), "Snapshot identity changed immediately before deletion.")
            try nativeResult(sm_snapshot_delete(fd, snapshot.name))
        }
    }
    func freeBytes(_ volume: ManagedVolume) throws -> Int64 {
        try withVolume(volume) { fd, _ in
            var fs = statfs(); try lifecycleRequire(fstatfs(fd, &fs) == 0, "Free capacity unavailable.")
            let (bytes, overflow) = Int64(fs.f_bfree).multipliedReportingOverflow(by: Int64(fs.f_bsize))
            try lifecycleRequire(!overflow && bytes >= 0, "Capacity overflow."); return bytes
        }
    }
    private func directory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw SnapshotLifecycleError.refused("Cannot create comparison lease directory.") }
        var info = stat()
        try lifecycleRequire(lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == 0 && (info.st_mode & 0o077) == 0, "Comparison directory is not private and root-owned.")
    }
    func mount(_ volume: ManagedVolume, snapshot: LifecycleSnapshot, leaseID: String, side: String, owner: UInt32) throws -> String {
        try requirePrivilege()
        try lifecycleRequire(UUID(uuidString: leaseID) != nil && ["left", "right"].contains(side) && owner >= 501, "Invalid comparison lease.")
        let root = URL(fileURLWithPath: SnapshotServiceIdentity.stateRoot), mounts = URL(fileURLWithPath: SnapshotServiceIdentity.mountRoot)
        let lease = mounts.appendingPathComponent(leaseID), target = lease.appendingPathComponent(side)
        for path in [root, mounts, lease, target] { try directory(path) }
        for path in [root, mounts, lease] { try nativeResult(sm_snapshot_allow_search(path.path, owner)) }
        try withVolume(volume) { fd, checked in
            let matches = try SnapshotPlatformInventory.inventory(checked).filter { $0.id == snapshot.id }
            try lifecycleRequire(matches.count == 1 && matches[0] == snapshot, "Snapshot identity changed before read-only mount.")
            try nativeResult(sm_snapshot_mount(fd, target.path, snapshot.name))
            var fs = statfs()
            try lifecycleRequire(statfs(target.path, &fs) == 0 && fs.f_flags & UInt32(MNT_RDONLY) != 0, "Snapshot mount did not report read-only status.")
        }
        return target.path
    }
    func unmount(path: String) throws {
        let prefix = SnapshotServiceIdentity.mountRoot + "/"
        try lifecycleRequire(path.hasPrefix(prefix), "Invalid lease cleanup path.")
        let parts = String(path.dropFirst(prefix.count)).split(separator: "/")
        try lifecycleRequire(parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && ["left", "right"].contains(String(parts[1])), "Invalid lease cleanup identifier.")
        var info = stat()
        if lstat(path, &info) != 0 && errno == ENOENT { return }
        var fs = statfs()
        try lifecycleRequire(lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && statfs(path, &fs) == 0, "Lease cleanup path is unavailable or replaced.")
        let mountPoint = withUnsafePointer(to: &fs.f_mntonname) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) } }
        if mountPoint == path {
            try lifecycleRequire(fs.f_flags & UInt32(MNT_RDONLY) != 0, "Refusing cleanup of a writable mount.")
            try nativeResult(sm_snapshot_unmount(path))
        }
        // Only empty, root-owned directories under the fixed namespace. Never recursive deletion.
        var empty = stat()
        try lifecycleRequire(lstat(path, &empty) == 0 && empty.st_uid == 0 && (empty.st_mode & S_IFMT) == S_IFDIR, "Unsafe underlying mount directory.")
        if rmdir(path) != 0 && errno != ENOENT { throw SnapshotLifecycleError.refused("Lease directory is busy; cleanup will retry.") }
        _ = rmdir(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
}
