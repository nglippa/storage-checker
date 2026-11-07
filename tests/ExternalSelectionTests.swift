import Foundation

@main enum ExternalSelectionTests {
    static func main() throws {
        let base = URL(fileURLWithPath: "/private/tmp/storage-external-selection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let token = ExternalMountIdentity(volumeUUID: uuid, device: 42, inode: 2, birthSeconds: 1, birthNanoseconds: 0, source: "/dev/fixture", mountPath: "/Volumes/Studio")
        var descriptor = ExternalVolumeDescriptor(volumeUUID: uuid, name: "Studio", mountPath: token.mountPath, filesystem: "exfat", device: token.device,
            backingUUIDs: ["BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"], isInternal: false, isLocal: true, isPhysical: true)
        descriptor.mountIdentity = token
        let registry = ExternalVolumeRegistry(baseDirectory: base)
        _ = try registry.enroll(descriptor)
        let observations = ExternalVolumeObservationStore(baseDirectory: base)
        try observations.write(ExternalVolumeObservations(sampledAt: Date(), descriptors: [descriptor], error: nil))
        let connected = try StorageTargetContext.external(baseDirectory: base, uuid: uuid, probe: { _ in token })
        precondition(connected.canRequest && !connected.allowsCleanup, "external requests enabled and cleanup excluded")
        precondition(connected.inventoryDatabase != connected.requestDatabase, "unpublished working catalog is never a viewer read source")
        let offline = try StorageTargetContext.external(baseDirectory: base, uuid: uuid, probe: { _ in throw ExternalVolumeError.invalidIdentity })
        precondition(!offline.canRequest && offline.descriptor == nil, "offline target cannot perform live actions")
        precondition(offline.historyDatabase == connected.historyDatabase && offline.requestDatabase == connected.requestDatabase, "disconnect retains same history and dataset")
        _ = try registry.setEnabled(uuid: uuid, enabled: false)
        let disabled = try StorageTargetContext.external(baseDirectory: base, uuid: uuid, probe: { _ in token })
        precondition(!disabled.canRequest && disabled.historyDatabase == connected.historyDatabase, "disable preserves reviewable history")
        try observations.write(ExternalVolumeObservations(sampledAt: Date(), descriptors: [descriptor, descriptor], error: nil))
        let ambiguous = try StorageTargetContext.external(baseDirectory: base, uuid: uuid, probe: { _ in token })
        precondition(ambiguous.issue != nil && ambiguous.descriptor == nil, "duplicate UUID refuses live identity while retaining selection")
        let startup = StorageTargetContext.startup(database: base.appendingPathComponent("history.sqlite3").path)
        precondition(startup.allowsCleanup && startup.inventoryDatabase == startup.requestDatabase, "startup keeps existing database routing")
        print("7 external selection tests passed")
    }
}
