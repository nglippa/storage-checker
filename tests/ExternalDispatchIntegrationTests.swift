import Foundation
import Darwin

@main enum ExternalDispatchIntegrationTests {
    static func main() async throws {
        inventoryAvailableSpaceOverride = (available: 100_000_000_000, capacity: 500_000_000_000)
        defer { inventoryAvailableSpaceOverride = nil }
        let base = URL(fileURLWithPath: "/private/tmp/storage-external-slice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        var mount = base.appendingPathComponent("fixture-drive")
        let state = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: mount.appendingPathComponent("Users/example"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: mount.appendingPathComponent("Users/example/file"))
        let actualUUID = try URL(fileURLWithPath: mount.path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString!
        var info = stat(); precondition(lstat(mount.path, &info) == 0)
        var descriptor = ExternalVolumeDescriptor(volumeUUID: actualUUID, name: "Fixture", mountPath: mount.path, filesystem: "exfat", device: Int64(info.st_dev),
            backingUUIDs: ["BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"], isInternal: false, isLocal: true, isPhysical: true)
        func token() throws -> ExternalMountIdentity {
            var current = stat(); try required(lstat(mount.path, &current) == 0, "fixture mounted")
            return ExternalMountIdentity(volumeUUID: try ExternalVolumeIdentity(actualUUID).uuid, device: Int64(current.st_dev), inode: UInt64(current.st_ino),
                birthSeconds: Int64(current.st_birthtimespec.tv_sec), birthNanoseconds: Int64(current.st_birthtimespec.tv_nsec), source: "/dev/fixture", mountPath: mount.path)
        }
        descriptor.mountIdentity = try token()
        let registry = ExternalVolumeRegistry(baseDirectory: state)
        _ = try registry.enroll(descriptor)
        func slice() async throws -> InventoryRunResult {
            let lease = try ExternalVolumeMountLease(descriptor: descriptor, registry: registry, probe: { _ in try token() })
            return try await runExternalInventorySliceForTesting(baseDirectory: state, lease: lease, budget: 10)
        }
        let firstResult = try await slice()
        try required(["complete", "partial"].contains(firstResult.outcome), "external fixture completes without real volume scans")
        let paths = try ExternalVolumePaths(baseDirectory: state, uuid: actualUUID, capacityScope: descriptor.capacityScope())
        let first = try ExternalCatalogAccess.current(paths: paths)!
        let firstDatabase = try ExternalCatalogAccess.database(snapshot: first, paths: paths)
        let readerLease = try ExternalCatalogReaderLease(paths: paths, snapshot: first)
        defer { readerLease.release() }
        let oldRoot = try await InventoryReader(path: firstDatabase).root()!
        try required(try await InventoryReader(path: firstDatabase).locateDirectory(path: mount.appendingPathComponent("Users/example").path).exact,
                     "external Users folder stays on fixture volume")
        try Data(repeating: 2, count: 65_536).write(to: mount.appendingPathComponent("Users/example/file"))
        _ = try ExternalVolumeControl(baseDirectory: state).request(uuid: actualUUID, action: "refresh")
        _ = try await slice()
        let second = try ExternalCatalogAccess.current(paths: paths)!
        try required(second.snapshotID != first.snapshotID, "real worker publishes changed committed catalog")
        try required(try await InventoryReader(path: firstDatabase).root()?.logicalBytes == oldRoot.logicalBytes, "published offline catalog survives working object updates")
        _ = try await slice()
        try required(try ExternalCatalogAccess.current(paths: paths)?.snapshotID == second.snapshotID, "idle slice cannot pretend the catalog was freshly measured")
        try Data(repeating: 3, count: 131_072).write(to: mount.appendingPathComponent("Users/example/file"))
        _ = try ExternalVolumeControl(baseDirectory: state).request(uuid: actualUUID, action: "refresh")
        externalCatalogManifestWriteOverride = { _, _ in throw Failure("injected manifest failure") }
        do { _ = try await slice() } catch { }
        externalCatalogManifestWriteOverride = nil
        try required(try ExternalCatalogAccess.current(paths: paths)?.snapshotID == second.snapshotID, "failed publication retains previous catalog")
        _ = try await slice()
        let recovered = try ExternalCatalogAccess.current(paths: paths)!
        try required(recovered.snapshotID != second.snapshotID, "later idle wake retries unpublished sequence after failed manifest")
        let newMount = base.appendingPathComponent("renamed-drive")
        try FileManager.default.moveItem(at: mount, to: newMount); mount = newMount
        descriptor.mountPath = mount.path; descriptor.name = "Renamed"; descriptor.mountIdentity = try token()
        let resumed = try await slice()
        try required(["complete", "partial"].contains(resumed.outcome), "renamed reconnect completes")
        let renamed = try ExternalCatalogAccess.current(paths: paths)!
        let renamedDatabase = try ExternalCatalogAccess.database(snapshot: renamed, paths: paths)
        try required(try await InventoryReader(path: renamedDatabase).root()?.path == mount.path, "renamed reconnect publishes current root path in a fresh generation")
        try required(renamed.generation != recovered.generation, "mount rename cannot retain stale generation paths")
        descriptor.backingUUIDs = ["CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"]
        _ = try registry.enroll(descriptor, replaceBacking: true)
        _ = try await slice()
        let reenrolled = try ExternalCatalogAccess.current(paths: paths)!
        try required(reenrolled.generation != renamed.generation, "explicit backing re-enrollment forces a fresh index even when root UUID/device/inode remain identical")
        print("11 external dispatch integration checks passed")
    }
}
