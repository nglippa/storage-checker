import Foundation
import Darwin

@main enum ExternalRuntimeTests {
    static func main() async throws {
        setbuf(stdout, nil)
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            try required(try value(), name); count += 1; print("PASS \(name)")
        }
        func refuses(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { count += 1; print("PASS \(name)"); return }
            throw Failure("Expected refusal: " + name)
        }
        let base = URL(fileURLWithPath: "/private/tmp/storage-external-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let mount = base.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        var info = stat(); try required(lstat(mount.path, &info) == 0, "fixture stat")
        let uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", backing = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        var descriptor = ExternalVolumeDescriptor(volumeUUID: uuid, name: "Studio", mountPath: mount.path,
            filesystem: "exfat", device: Int64(info.st_dev), backingUUIDs: [backing], isInternal: false, isLocal: true, isPhysical: true)
        let registry = ExternalVolumeRegistry(baseDirectory: base)
        _ = try registry.enroll(descriptor)
        let captured = ExternalMountIdentity(volumeUUID: uuid, device: Int64(info.st_dev), inode: UInt64(info.st_ino),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec), source: "/dev/fixture", mountPath: mount.path)
        descriptor.mountIdentity = captured
        let lease = try ExternalVolumeMountLease(descriptor: descriptor, registry: registry, probe: { _ in captured })
        try lease.validate()
        try check(lease.region.root == mount.path && !lease.region.usesFirmlinks, "external lease uses explicit generic filesystem region")
        _ = try registry.setIndexingPaused(uuid: uuid, paused: true)
        try refuses("pause invalidates an existing indexing lease") { try lease.validate() }
        let capacityLease = try ExternalVolumeMountLease(descriptor: descriptor, registry: registry, indexing: false, probe: { _ in captured })
        try capacityLease.validate()
        _ = try registry.setEnabled(uuid: uuid, enabled: false)
        try refuses("disable invalidates capacity lease too") { try capacityLease.validate() }
        _ = try registry.setEnabled(uuid: uuid, enabled: true)
        _ = try registry.setIndexingPaused(uuid: uuid, paused: false)
        var stale = descriptor; var oldRoot = captured; oldRoot.birthNanoseconds &+= 1; stale.mountIdentity = oldRoot
        try refuses("stale discovery cannot authorize a replacement with reused UUID and device number") {
            _ = try ExternalVolumeMountLease(descriptor: stale, registry: registry, probe: { _ in captured })
        }
        var replaced = captured; replaced.volumeUUID = backing
        try refuses("a reused mount path cannot become an indexing root") {
            _ = try ExternalVolumeMountLease(descriptor: descriptor, registry: registry, probe: { _ in replaced })
        }
        var observation = captured
        let changing = try ExternalVolumeMountLease(descriptor: descriptor, registry: registry, probe: { _ in observation })
        observation.inode &+= 1
        try refuses("root replacement invalidates subsequent batches") { try changing.validate() }
        try refuses("offline mount cannot create a fallback root") {
            _ = try ExternalVolumeMountLease(descriptor: descriptor, registry: registry, probe: { _ in throw InventoryRootValidationError.disconnected })
        }
        try check(!FileManager.default.fileExists(atPath: base.appendingPathComponent("external-volumes/volumes").path), "lease validation does not create a dataset or mount")
        // Reader safety: a symlinked ancestor cannot redirect an internal registry read.
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: registry.directory)
        try refuses("registry reads reject symbolic-link ancestors") {
            _ = try ExternalVolumeStorage.read(ExternalVolumeRegistryDocument.self, from: alias.appendingPathComponent("registry.json"))
        }
        let paths = try ExternalVolumePaths(baseDirectory: base, uuid: uuid, capacityScope: descriptor.capacityScope())
        var notifications = 0
        let send: (String, String) -> String = { _, _ in notifications += 1; return "delivered:fixture" }
        let first = Reading(timestamp: 10_000, container: paths.capacityScope, free: 80 * gb, used: 20 * gb, volumes: "[]")
        let baseline = try ExternalCapacityMonitoring.store(first, paths: paths, label: "Studio", validate: {}, notification: send)
        try check(baseline?.delta == nil, "first external reading establishes a baseline")
        let reconnect = Reading(timestamp: 15_000, container: paths.capacityScope, free: 10 * gb, used: 90 * gb, volumes: "[]")
        let afterGap = try ExternalCapacityMonitoring.store(reconnect, paths: paths, label: "Studio", validate: {}, notification: send)
        try check(afterGap?.delta == nil && afterGap?.growth.isEmpty == true && afterGap?.severity == "critical", "offline gap resets growth baseline and retains low-space alert")
        let followup = Reading(timestamp: 16_800, container: paths.capacityScope, free: 9 * gb, used: 91 * gb, volumes: "[]")
        let afterBaseline = try ExternalCapacityMonitoring.store(followup, paths: paths, label: "Studio", validate: {}, notification: send)
        try check(afterBaseline?.delta == -gb && afterBaseline?.growth.isEmpty == true, "post-reconnect window cannot cross the earlier offline gap")
        _ = try ExternalCapacityMonitoring.store(followup, paths: paths, label: "Studio", validate: {}, notification: send)
        let database = try Database(paths.capacityDatabase)
        try check(try database.rows("SELECT id FROM readings").count == 3 && notifications == 1, "duplicate scope sample cannot duplicate readings or notifications")
        try check(try database.rows("SELECT reading_id FROM external_capacity_sessions").count == 2, "session boundaries are durable for viewer history")
        try refuses("disconnected capacity sample is not recorded as zero free") {
            _ = try ExternalCapacityMonitoring.store(Reading(timestamp: 18_600, container: paths.capacityScope, free: 0, used: 100 * gb, volumes: "[]"),
                paths: paths, label: "Studio", validate: { throw InventoryRootValidationError.disconnected }, notification: send)
        }
        try check(try database.rows("SELECT id FROM readings").count == 3, "failed capacity validation leaves history intact")
        _ = try ExternalCapacityMonitoring.store(Reading(timestamp: 18_600, container: paths.capacityScope, free: 8 * gb, used: 92 * gb, volumes: "[]"),
            paths: paths, label: "Studio", identityFingerprint: "old-backing", validate: {}, notification: send)
        let changedLineage = try ExternalCapacityMonitoring.store(Reading(timestamp: 20_400, container: paths.capacityScope, free: gb, used: 99 * gb, volumes: "[]"),
            paths: paths, label: "Studio", identityFingerprint: "new-backing", validate: {}, notification: send)
        try check(changedLineage?.delta == nil && changedLineage?.growth.isEmpty == true && changedLineage?.severity == "critical", "explicit backing change resets capacity growth while retaining low-space thresholds")
        var sibling = descriptor; sibling.volumeUUID = backing; sibling.name = "Sibling"
        var apfs = descriptor; apfs.filesystem = "apfs"; apfs.containerUUID = uuid
        sibling.filesystem = "apfs"; sibling.containerUUID = uuid
        let groupBase = base.appendingPathComponent("groups")
        let groupRegistry = ExternalVolumeRegistry(baseDirectory: groupBase)
        _ = try groupRegistry.enroll(apfs); _ = try groupRegistry.enroll(sibling)
        _ = try groupRegistry.setIndexingPaused(uuid: backing, paused: true)
        let groups = try ExternalCapacityMonitoring.groups(baseDirectory: groupBase, descriptors: [apfs, sibling])
        try check(groups.count == 1 && groups[0].descriptors.count == 2, "APFS sibling enrollments share one capacity check even when indexing paused")
        let onlyOne = try ExternalCapacityMonitoring.groups(baseDirectory: groupBase, descriptors: [apfs])
        try check(onlyOne.count == 1 && onlyOne[0].label.contains("Sibling") && onlyOne[0].label.contains("shared APFS"), "shared scope labels retain enrolled offline siblings")
        var cloned = sibling; cloned.backingUUIDs = [uuid]
        try refuses("a capacity scope cannot be enrolled against two different known physical backings") { _ = try groupRegistry.enroll(cloned, replaceBacking: true) }
        var corrupt = try groupRegistry.read()
        corrupt.volumes[backing]?.backingUUIDs = [uuid]
        try ExternalVolumeStorage.write(corrupt, to: groupRegistry.registryURL)
        try refuses("conflicting persisted scope backings fail closed before sampling") { _ = try groupRegistry.read() }
        let aliasPaths = try ExternalVolumePaths(baseDirectory: base.appendingPathComponent("alias-data"), uuid: uuid, capacityScope: "filesystem:" + uuid)
        try aliasPaths.prepare()
        let unrelatedPath = base.appendingPathComponent("unrelated.sqlite3").path
        func createUnrelated() throws { _ = try Database(unrelatedPath) }
        try createUnrelated()
        let unrelatedBytes = try Data(contentsOf: URL(fileURLWithPath: unrelatedPath))
        try FileManager.default.createSymbolicLink(atPath: aliasPaths.capacityDatabase, withDestinationPath: unrelatedPath)
        let aliasReading = Reading(timestamp: 20_000, container: aliasPaths.capacityScope, free: 80 * gb, used: 20 * gb, volumes: "[]")
        try refuses("external capacity SQLite writer refuses a symbolic-link leaf") {
            _ = try ExternalCapacityMonitoring.store(aliasReading, paths: aliasPaths, label: "Alias", validate: {}, notification: send)
        }
        try refuses("inventory schema opens also refuse a symbolic-link database") {
            try initializeInventorySchema(databasePath: aliasPaths.capacityDatabase)
        }
        try FileManager.default.removeItem(atPath: aliasPaths.capacityDatabase)
        try FileManager.default.linkItem(atPath: unrelatedPath, toPath: aliasPaths.capacityDatabase)
        try refuses("external capacity SQLite writer refuses a hard-linked leaf") {
            _ = try ExternalCapacityMonitoring.store(aliasReading, paths: aliasPaths, label: "Alias", validate: {}, notification: send)
        }
        try FileManager.default.removeItem(atPath: aliasPaths.capacityDatabase)
        try check(try Data(contentsOf: URL(fileURLWithPath: unrelatedPath)) == unrelatedBytes, "external aliases cannot mutate an unrelated database")
        print("\(count) external runtime tests passed")
    }
}
