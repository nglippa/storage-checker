import Foundation
import Darwin

@main enum ExternalVolumeTestMain {
    static func main() throws {
        setbuf(stdout, nil)
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw NSError(domain: "ExternalVolumeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            count += 1; print("PASS \(name)")
        }
        func rejects(_ name: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { count += 1; print("PASS \(name)"); return }
            throw NSError(domain: "ExternalVolumeTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected refusal: \(name)"])
        }
        let a = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", b = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let c = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        let identity = try ExternalVolumeIdentity(a.lowercased())
        try check(identity.uuid == a, "UUID identity is canonical across case")
        try rejects("a mount path cannot be a persistent identity") { _ = try ExternalVolumeIdentity("../../Volumes/Other") }
        let first = ExternalVolumeDescriptor(volumeUUID: a, name: "Studio α", mountPath: "/Volumes/Studio", filesystem: "apfs", device: 101,
                                             containerUUID: c, backingUUIDs: [b], isInternal: false, isLocal: true, isPhysical: true)
        let renamed = ExternalVolumeDescriptor(volumeUUID: a.lowercased(), name: "Renamed", mountPath: "/Volumes/Renamed 1", filesystem: "apfs", device: 205,
                                               containerUUID: c, backingUUIDs: [b], isInternal: false, isLocal: true, isPhysical: true)
        let sibling = ExternalVolumeDescriptor(volumeUUID: b, name: "Sibling", mountPath: "/Volumes/Sibling", filesystem: "apfs", device: 102,
                                               containerUUID: c, backingUUIDs: [b], isInternal: false, isLocal: true, isPhysical: true)
        try check(first.eligibilityReason == nil, "an external physical PCIe SSD is eligible without a removable flag")
        try check(try first.capacityScope() == sibling.capacityScope(), "APFS sibling volumes share one capacity scope")
        try check(try first.identity() == renamed.identity(), "rename and device-number changes preserve dataset identity")
        var image = first; image.isDiskImage = true
        var backup = first; backup.isBackup = true
        var network = first; network.isLocal = false
        var internalDisk = first; internalDisk.isInternal = true
        var missing = first; missing.volumeUUID = nil
        try check([image, backup, network, internalDisk, missing].allSatisfy { $0.eligibilityReason != nil }, "images, backups, network, internal and unknown-identity targets are excluded")
        try rejects("duplicate mounted UUIDs never resolve by name") { _ = try ExternalVolumeCatalog.resolve(uuid: a, descriptors: [first, renamed]) }
        try check(try ExternalVolumeCatalog.resolve(uuid: a, descriptors: [first, sibling])?.name == "Studio α", "distinct same-container volumes resolve independently")
        let base = URL(fileURLWithPath: "/private/tmp/storage-external-registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ExternalVolumeRegistry(baseDirectory: base)
        try check(try store.read().volumes.isEmpty, "discovery does not opt any drive in")
        let enrolled = try store.enroll(first)
        try check(enrolled.enabled && !enrolled.indexingPaused, "explicit enrollment enables only the selected drive")
        _ = try store.setIndexingPaused(uuid: a, paused: true)
        try check(try store.read().volumes[a]?.indexingPaused == true && store.read().volumes[a]?.enabled == true, "pause preserves capacity monitoring")
        _ = try store.setEnabled(uuid: a, enabled: false)
        try check(try store.read().volumes[a]?.enabled == false, "disable is durable across registry readers")
        _ = try store.enroll(renamed)
        try check(try store.read().volumes.count == 1 && store.read().volumes[a]?.name == "Renamed", "re-enrollment of a renamed volume reuses its record")
        var changed = renamed; changed.backingUUIDs = [c]
        try rejects("changed known backing identity requires explicit re-enrollment") { try store.validate(changed) }
        try store.validate(renamed)
        var changedScope = renamed; changedScope.containerUUID = a
        try rejects("changed APFS capacity scope requires explicit re-enrollment") { _ = try store.enroll(changedScope) }
        let paths = try ExternalVolumePaths(baseDirectory: base, uuid: a, capacityScope: first.capacityScope())
        try paths.prepare()
        try check(paths.inventoryDatabase != paths.capacityDatabase && paths.inventoryDatabase.hasPrefix(base.path + "/external-volumes/volumes/"), "inventory and capacity use separate internal dataset paths")
        let same = try ExternalVolumePaths(baseDirectory: base, uuid: b, capacityScope: sibling.capacityScope())
        try check(paths.capacityDatabase == same.capacityDatabase && paths.inventoryDatabase != same.inventoryDatabase, "APFS siblings share history but never inventory")
        let beforeConcurrent = try store.read()
        let failures = NSLock()
        var failureCount = 0
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            var volume = first
            volume.volumeUUID = String(format: "00000000-0000-4000-8000-%012d", index + 1)
            do { _ = try store.enroll(volume) }
            catch { failures.lock(); failureCount += 1; failures.unlock() }
        }
        let afterConcurrent = try store.read()
        try check(failureCount == 0 && afterConcurrent.volumes.count == beforeConcurrent.volumes.count + 12 && afterConcurrent.revision == beforeConcurrent.revision + 12,
                  "concurrent registry writers merge all enrollments and preserve monotonic revisions")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.registryURL.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "registry files have private permissions")
        let identityFile = paths.inventoryDirectory.appendingPathComponent("identity.json")
        try JSONEncoder().encode(ExternalVolumeIdentity(b)).write(to: identityFile, options: .atomic)
        try rejects("dataset identity metadata rejects a storage-key collision") { try paths.prepare() }
        let validDocument = try store.read()
        var mismatched = validDocument; mismatched.volumes[a]?.capacityScope = "filesystem:" + b
        try ExternalVolumeStorage.write(mismatched, to: store.registryURL)
        try rejects("a generic capacity scope must match its volume UUID") { _ = try store.read() }
        try ExternalVolumeStorage.write(validDocument, to: store.registryURL)
        try Data("{broken".utf8).write(to: store.registryURL)
        try rejects("corrupt settings cannot enable all drives") { _ = try store.read() }
        try Data("{\"version\":9,\"revision\":0,\"volumes\":{}}".utf8).write(to: store.registryURL)
        try rejects("unknown settings versions stop external work") { _ = try store.read() }
        print("\(count) external volume tests passed")
    }
}
