import Foundation
import Darwin

@main enum ExternalControlTests {
    static func main() throws {
        let base = URL(fileURLWithPath: "/private/tmp/storage-external-controls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let drive = ExternalVolumeDescriptor(volumeUUID: uuid, name: "Portable", mountPath: "/Volumes/Portable", filesystem: "exfat", device: 42,
            backingUUIDs: ["BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"], isInternal: false, isLocal: true, isPhysical: true)
        try ExternalVolumeObservationStore(baseDirectory: base).write(ExternalVolumeObservations(sampledAt: Date(), descriptors: [drive], error: nil))
        let control = ExternalVolumeControl(baseDirectory: base)
        _ = try control.enroll(uuid: uuid)
        let registry = ExternalVolumeRegistry(baseDirectory: base)
        let paths = try ExternalVolumePaths(baseDirectory: base, uuid: uuid, capacityScope: drive.capacityScope())
        try required(try registry.read().volumes[uuid]?.enabled == true, "explicit enrollment durable")
        _ = try control.request(uuid: uuid, action: "pause")
        try required(try registry.read().volumes[uuid]?.enabled == true && registry.read().volumes[uuid]?.indexingPaused == true, "pause retains monitoring")
        try required(FileManager.default.fileExists(atPath: paths.inventoryDirectory.appendingPathComponent("inventory.cancel").path), "pause stops active slice")
        _ = try control.request(uuid: uuid, action: "resume")
        try required(try registry.read().volumes[uuid]?.indexingPaused == false, "resume durable")
        try control.disable(uuid: uuid)
        try required(try registry.read().volumes[uuid]?.enabled == false, "disable stops both without forgetting")
        _ = try control.enroll(uuid: uuid)
        try required(!FileManager.default.fileExists(atPath: paths.inventoryDirectory.appendingPathComponent("inventory.cancel").path), "reenable removes stale disable marker when indexing enabled")
        _ = try control.request(uuid: uuid, action: "refresh")
        try required(try FileManager.default.contentsOfDirectory(atPath: InventoryRequests.directory(database: paths.inventoryDatabase).path).contains { UUID(uuidString: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent) != nil }, "request targets mutable database mailbox")
        let signal = InventoryRequests.directory(database: base.appendingPathComponent("history.sqlite3").path).appendingPathComponent("external-wake.json")
        try required(FileManager.default.fileExists(atPath: signal.path), "target controls wake one canonical dispatcher")
        _ = try observeExternalVolumesForDispatch(directory: base, discovery: {
            try control.signal()
            return ExternalVolumeObservations(sampledAt: Date(), descriptors: [drive], error: nil)
        })
        try required(FileManager.default.fileExists(atPath: signal.path), "a mount wake arriving during discovery remains durable for the next wave")
        try required(!FileManager.default.fileExists(atPath: paths.publicationURL.path), "controls never publish or mutate a read catalog")
        try ExternalVolumeObservationStore(baseDirectory: base).write(ExternalVolumeObservations(sampledAt: Date(), descriptors: [drive, drive], error: nil))
        var rejected = false
        do { _ = try control.enroll(uuid: uuid) } catch { rejected = true }
        try required(rejected, "ambiguous discovery cannot enroll by display name")
        let targets = ["startup", "one", "two", "three"]
        try required(ExternalInventorySchedule.order(targets: targets, after: "one") == ["two", "three", "startup", "one"], "bounded waves resume round-robin after last serviced target")
        try required(ExternalInventorySchedule.order(targets: [], after: "old").isEmpty, "absent targets produce a normal empty wave")
        print("13 external control/schedule checks passed")
    }
}
