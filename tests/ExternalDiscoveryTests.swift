import Foundation

#if INVENTORY_TESTS
private let volumeA = "11111111-1111-4111-8111-111111111111"
private let volumeB = "22222222-2222-4222-8222-222222222222"
private let containerID = "33333333-3333-4333-8333-333333333333"
private let storeID = "44444444-4444-4444-8444-444444444444"

private func discoveryThrows(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

private func plist(_ value: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

private final class DiscoveryCommands {
    var values = [String: ExternalDiscoveryCommandResult]()
    var calls = [String]()
    func key(_ executable: String, _ arguments: [String]) -> String { executable + " " + arguments.joined(separator: " ") }
    func add(_ executable: String, _ arguments: [String], _ value: Any) throws {
        values[key(executable, arguments)] = ExternalDiscoveryCommandResult(data: try plist(value), status: 0, timedOut: false, truncated: false)
    }
    func runner(_ executable: String, _ arguments: [String], _ timeout: TimeInterval, _ cap: Int) -> ExternalDiscoveryCommandResult {
        let key = key(executable, arguments); calls.append(key)
        return values[key] ?? ExternalDiscoveryCommandResult(data: Data(), status: 1, timedOut: false, truncated: false)
    }
}

private func mount(_ path: String, uuid: String?, local: Bool = true, internalVolume: Bool = false) -> ExternalMountedVolumeMetadata {
    ExternalMountedVolumeMetadata(url: URL(fileURLWithPath: path), name: URL(fileURLWithPath: path).lastPathComponent,
                                  volumeUUID: uuid, isLocal: local, isInternal: internalVolume, isReadable: true, device: 42)
}

private func baseCommands(_ commands: DiscoveryCommands, volumes: [(String, String)]) throws {
    try commands.add("/usr/sbin/diskutil", ["apfs", "list", "-plist"], ["Containers": [[
        "APFSContainerReference": "disk5", "APFSContainerUUID": containerID,
        "PhysicalStores": [["APFSPhysicalStore": "disk4s2"]],
        "Volumes": volumes.map { ["DeviceIdentifier": $0.0, "APFSVolumeUUID": $0.1, "Roles": []] }
    ]]])
    try commands.add("/usr/bin/tmutil", ["destinationinfo", "-X"], [:])
    try commands.add("/usr/sbin/diskutil", ["info", "-plist", "disk4s2"], [
        "DeviceIdentifier": "disk4s2", "DiskUUID": storeID, "ParentWholeDisk": "disk4",
        "Internal": false, "PartitionMapPartition": true, "WholeDisk": false, "BusProtocol": "PCI-Express"
    ])
    try commands.add("/usr/sbin/diskutil", ["info", "-plist", "disk4"], [
        "DeviceIdentifier": "disk4", "WholeDisk": true, "Internal": false,
        "VirtualOrPhysical": "Physical", "BusProtocol": "PCI-Express"
    ])
}

private func addVolumeInfo(_ commands: DiscoveryCommands, path: String, device: String, uuid: String,
                           extra: [String: Any] = [:]) throws {
    var value: [String: Any] = ["DeviceIdentifier": device, "VolumeUUID": uuid,
                                "APFSContainerReference": "disk5", "FilesystemType": "apfs", "Internal": false]
    for (key, item) in extra { value[key] = item }
    try commands.add("/usr/sbin/diskutil", ["info", "-plist", path], value)
}

private func pcieAndSiblingTest(_ check: (Bool, String) throws -> Void) throws {
    let commands = DiscoveryCommands()
    try baseCommands(commands, volumes: [("disk5s1", volumeA), ("disk5s2", volumeB)])
    try addVolumeInfo(commands, path: "/Volumes/Fast", device: "disk5s1", uuid: volumeA,
                      extra: ["BusProtocol": "PCI-Express", "Removable": false])
    try addVolumeInfo(commands, path: "/Volumes/Fast Two", device: "disk5s2", uuid: volumeB,
                      extra: ["BusProtocol": "PCI-Express", "Removable": false])
    let internalNoise = (0..<40).map { mount("/System/Volumes/Helper-\($0)", uuid: UUID().uuidString, internalVolume: true) }
    let discovery = ExternalVolumeDiscovery(commandRunner: commands.runner,
        mountedVolumes: { internalNoise + [mount("/Volumes/Fast", uuid: volumeA), mount("/Volumes/Fast Two", uuid: volumeB)] })
    let catalog = discovery.sample()
    try check(catalog.error == nil && catalog.descriptors.count == 2, "two verified APFS siblings are emitted")
    try check(catalog.descriptors.allSatisfy { $0.eligibilityReason == nil }, "external non-removable PCIe volumes remain eligible")
    try check(try Set(catalog.descriptors.map { try $0.capacityScope() }) == ["apfs:\(containerID)"], "APFS siblings share their container capacity scope")
    try check(catalog.descriptors.allSatisfy { $0.backingUUIDs == [storeID] }, "physical backing UUID is verified and normalized")
    try check(commands.calls.filter { $0 == "/usr/sbin/diskutil apfs list -plist" }.count == 1, "APFS topology is requested once")
    try check(commands.calls.filter { $0.hasSuffix("info -plist disk4s2") }.count == 1 && commands.calls.filter { $0.hasSuffix("info -plist disk4") }.count == 1,
              "shared physical backing metadata is cached")
    try check(catalog.error == nil, "known internal mounts do not consume the external candidate bound")
}

private func nonAPFSIndependentTest(_ check: (Bool, String) throws -> Void) throws {
    let commands = DiscoveryCommands()
    try commands.add("/usr/bin/tmutil", ["destinationinfo", "-X"], [:])
    try commands.add("/usr/sbin/diskutil", ["info", "-plist", "/Volumes/Portable"], [
        "DeviceIdentifier": "disk8s1", "VolumeUUID": volumeA, "FilesystemType": "exfat", "DiskUUID": storeID,
        "ParentWholeDisk": "disk8", "Internal": false, "VirtualOrPhysical": "Physical"
    ])
    try commands.add("/usr/sbin/diskutil", ["info", "-plist", "disk8"], [
        "DeviceIdentifier": "disk8", "Whole": true, "Internal": false, "VirtualOrPhysical": "Physical"
    ])
    let catalog = ExternalVolumeDiscovery(commandRunner: commands.runner,
        mountedVolumes: { [mount("/Volumes/Portable", uuid: volumeA)] }).sample()
    try check(catalog.error?.contains("apfs_metadata_unavailable") == true, "catalog reports unavailable APFS topology")
    try check(catalog.descriptors.first?.eligibilityReason == nil, "verified exFAT volume is not blocked by unrelated APFS metadata failure")
    try check(try catalog.descriptors.first?.capacityScope() == "filesystem:\(volumeA)", "non-APFS capacity scope uses volume identity")
}

private func rejectionTest(_ check: (Bool, String) throws -> Void) throws {
    let commands = DiscoveryCommands()
    try baseCommands(commands, volumes: [("disk5s1", volumeA)])
    try addVolumeInfo(commands, path: "/Volumes/Network", device: "disk5s1", uuid: volumeA)
    try addVolumeInfo(commands, path: "/Volumes/Image", device: "disk9s1", uuid: volumeB,
                      extra: ["DiskImage": true, "VirtualOrPhysical": "Virtual"])
    try addVolumeInfo(commands, path: "/Volumes/Backup", device: "disk5s1", uuid: volumeA)
    try commands.add("/usr/bin/tmutil", ["destinationinfo", "-X"], ["Destinations": [["Mount Point": "/Volumes/Backup"]]])
    let catalog = ExternalVolumeDiscovery(commandRunner: commands.runner, mountedVolumes: {
        [mount("/Volumes/Network", uuid: volumeA, local: false), mount("/Volumes/Image", uuid: volumeB), mount("/Volumes/Backup", uuid: volumeA)]
    }).sample()
    let byPath = Dictionary(grouping: catalog.descriptors, by: \.mountPath)
    try check(byPath["/Volumes/Network"]?.first?.eligibilityReason?.contains("Network") == true, "network volume is rejected")
    try check(byPath["/Volumes/Image"]?.first?.eligibilityReason?.contains("Disk images") == true, "disk image is rejected")
    try check(byPath["/Volumes/Backup"]?.first?.isBackup == true, "configured Time Machine destination is rejected")
}

private func optionalBackingFingerprintTest(_ check: (Bool, String) throws -> Void) throws {
    let commands = DiscoveryCommands()
    try commands.add("/usr/bin/tmutil", ["destinationinfo", "-X"], [:])
    try commands.add("/usr/sbin/diskutil", ["info", "-plist", "/Volumes/MBR"], [
        "DeviceIdentifier": "disk8s1", "VolumeUUID": volumeA, "FilesystemType": "exfat",
        "ParentWholeDisk": "disk8", "Internal": false, "PartitionMapPartition": true
    ])
    try commands.add("/usr/sbin/diskutil", ["info", "-plist", "disk8"], [
        "DeviceIdentifier": "disk8", "WholeDisk": true, "Internal": false, "VirtualOrPhysical": "Physical"
    ])
    let result = ExternalVolumeDiscovery(commandRunner: commands.runner, mountedVolumes: { [mount("/Volumes/MBR", uuid: volumeA)] }).sample()
    try check(result.descriptors.first?.eligibilityReason == nil, "verified physical exFAT with a volume UUID does not require an unavailable partition UUID")
    try check(result.descriptors.first?.backingUUIDs.isEmpty == true, "missing optional backing fingerprint is represented honestly")
}

private func crossMountIdentityConflicts(_ check: (Bool, String) throws -> Void) throws {
    let commands = DiscoveryCommands()
    try baseCommands(commands, volumes: [("disk5s1", volumeA)])
    try addVolumeInfo(commands, path: "/Volumes/Clone", device: "disk5s1", uuid: volumeA)
    let clone = ExternalVolumeDiscovery(commandRunner: commands.runner, mountedVolumes: {
        [mount("/Volumes/Clone", uuid: volumeA), mount("/System/Volumes/Data", uuid: volumeA, internalVolume: true)]
    }).sample()
    try check(clone.descriptors.first?.eligibilityReason != nil, "an external UUID colliding with a mounted internal volume is refused before enrollment")
    try commands.add("/usr/sbin/diskutil", ["apfs", "list", "-plist"], ["Containers": [
        ["ContainerReference": "disk5", "APFSContainerUUID": containerID, "PhysicalStores": [["DeviceIdentifier": "disk4s2"]], "Volumes": [["APFSVolumeUUID": volumeA, "Roles": []]]],
        ["ContainerReference": "disk9", "APFSContainerUUID": containerID, "PhysicalStores": [["DeviceIdentifier": "disk8s2"]], "Volumes": [["APFSVolumeUUID": volumeB, "Roles": []]]]
    ]])
    let containers = ExternalVolumeDiscovery(commandRunner: commands.runner, mountedVolumes: { [mount("/Volumes/Clone", uuid: volumeA)] }).sample()
    try check(containers.descriptors.first?.eligibilityReason != nil, "two APFS container references cannot share one capacity identity")
}

private func failClosedAndDuplicateTest(_ check: (Bool, String) throws -> Void) throws {
    let commands = DiscoveryCommands()
    try baseCommands(commands, volumes: [("disk5s1", volumeA)])
    try addVolumeInfo(commands, path: "/Volumes/Mismatch", device: "disk5s1", uuid: volumeB)
    try addVolumeInfo(commands, path: "/Volumes/Duplicate A", device: "disk5s1", uuid: volumeA)
    try addVolumeInfo(commands, path: "/Volumes/Duplicate B", device: "disk5s1", uuid: volumeA)
    let catalog = ExternalVolumeDiscovery(commandRunner: commands.runner, mountedVolumes: {
        [mount("/Volumes/Missing", uuid: nil), mount("/Volumes/Mismatch", uuid: volumeA),
         mount("/Volumes/Duplicate A", uuid: volumeA), mount("/Volumes/Duplicate B", uuid: volumeA)]
    }).sample()
    try check(catalog.descriptors.first { $0.mountPath == "/Volumes/Missing" }?.eligibilityReason != nil, "missing volume UUID fails closed")
    try check(catalog.descriptors.first { $0.mountPath == "/Volumes/Mismatch" }?.eligibilityReason != nil, "mismatched diskutil UUID fails closed")
    let duplicates = catalog.descriptors.filter { $0.mountPath.contains("Duplicate") }
    try check(duplicates.count == 2, "duplicate volume identities remain visible for ambiguity detection")
    try check(discoveryThrows { _ = try ExternalVolumeCatalog.resolve(uuid: volumeA, descriptors: duplicates) }, "duplicate identity resolution is blocked")

    commands.values[commands.key("/usr/sbin/diskutil", ["info", "-plist", "disk4s2"])] =
        ExternalDiscoveryCommandResult(data: try plist(["DeviceIdentifier": "disk4s2", "DiskUUID": storeID]), status: 0, timedOut: false, truncated: false)
    let unknown = ExternalVolumeDiscovery(commandRunner: commands.runner, mountedVolumes: { [mount("/Volumes/Duplicate A", uuid: volumeA)] }).sample()
    try check(unknown.descriptors.first?.eligibilityReason != nil, "unknown physical backing metadata fails closed")

    commands.values[commands.key("/usr/bin/tmutil", ["destinationinfo", "-X"])] =
        ExternalDiscoveryCommandResult(data: Data(), status: 1, timedOut: false, truncated: false)
    let noBackupTruth = ExternalVolumeDiscovery(commandRunner: commands.runner, mountedVolumes: { [mount("/Volumes/Duplicate A", uuid: volumeA)] }).sample()
    try check(noBackupTruth.error != nil && noBackupTruth.descriptors.allSatisfy { $0.eligibilityReason != nil }, "unknown backup metadata fails closed")
}

private func observationStoreTest(_ check: (Bool, String) throws -> Void) throws {
    let base = URL(fileURLWithPath: "/private/tmp/storage-monitor-observations-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let descriptor = ExternalVolumeDescriptor(volumeUUID: volumeA, name: "Fast", mountPath: "/Volumes/Fast", filesystem: "apfs", device: 42,
                                              containerUUID: containerID, backingUUIDs: [storeID], isInternal: false, isLocal: true, isPhysical: true)
    let catalog = ExternalVolumeObservationCatalog(sampledAt: Date(timeIntervalSince1970: 123), descriptors: [descriptor], error: nil)
    let store = ExternalVolumeObservationStore(baseDirectory: base)
    try store.write(catalog)
    try check(try store.read() == catalog, "shared observation catalog round-trips through private atomic storage")
    let earlier = ExternalVolumeObservations(sampledAt: Date(timeIntervalSince1970: 100), descriptors: [descriptor], error: nil)
    Thread.sleep(forTimeInterval: 0.002)
    let later = ExternalVolumeObservations(sampledAt: Date(timeIntervalSince1970: 200), descriptors: [], error: nil)
    try store.write(later); try store.write(earlier)
    try check(try store.read() == later, "late completion of an older metadata sample cannot overwrite newer mount observations")
}

@main struct ExternalDiscoveryTestsMain {
    static func main() throws {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) throws {
            assertions += 1
            if !condition { throw Failure("External discovery test failed: \(message)") }
        }
        try pcieAndSiblingTest(check)
        try nonAPFSIndependentTest(check)
        try rejectionTest(check)
        try optionalBackingFingerprintTest(check)
        try crossMountIdentityConflicts(check)
        try failClosedAndDuplicateTest(check)
        try observationStoreTest(check)
        print("External discovery tests passed (\(assertions) assertions)")
    }
}
#endif
