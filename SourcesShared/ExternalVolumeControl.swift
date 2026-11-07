import Foundation

struct ExternalDispatcherSignal: Codable, Sendable {
    let volumeUUID: String?
    let settingsRevision: UInt64
    let requestedAt: Date
}

struct ExternalVolumeControl: Sendable {
    let baseDirectory: URL
    private var registry: ExternalVolumeRegistry { ExternalVolumeRegistry(baseDirectory: baseDirectory) }

    @discardableResult func enroll(uuid: String, replaceBacking: Bool = false) throws -> ExternalVolumeRegistration {
        guard NativeQARuntime.active == nil else { try NativeQARuntime.reject("External enrollment is outside the native QA fixture") }
        guard let observations = try ExternalVolumeObservationStore(baseDirectory: baseDirectory).read(),
              let descriptor = try ExternalVolumeCatalog.resolve(uuid: uuid, descriptors: observations.descriptors) else { throw ExternalVolumeError.invalidIdentity }
        let saved = try registry.enroll(descriptor, replaceBacking: replaceBacking)
        let paths = try ExternalVolumePaths(baseDirectory: baseDirectory, uuid: saved.volumeUUID, capacityScope: saved.capacityScope)
        try paths.prepare()
        _ = try InventoryRequests.enqueue(database: paths.inventoryDatabase, action: saved.indexingPaused ? "pause" : "resume")
        try signal(uuid: saved.volumeUUID)
        return saved
    }

    func disable(uuid: String) throws {
        guard NativeQARuntime.active == nil else { try NativeQARuntime.reject("External controls are outside the native QA fixture") }
        let saved = try registry.setEnabled(uuid: uuid, enabled: false)
        let paths = try ExternalVolumePaths(baseDirectory: baseDirectory, uuid: saved.volumeUUID, capacityScope: saved.capacityScope)
        try paths.prepare()
        _ = try InventoryRequests.enqueue(database: paths.inventoryDatabase, action: "pause")
        try signal(uuid: saved.volumeUUID)
    }

    @discardableResult func request(uuid: String, action: String, path: String? = nil) throws -> UUID {
        guard NativeQARuntime.active == nil else { try NativeQARuntime.reject("External requests are outside the native QA fixture") }
        let canonical = try ExternalVolumeIdentity(uuid).uuid
        guard var saved = try registry.read().volumes[canonical], saved.enabled else { throw ExternalVolumeError.unsupported("Monitoring for this drive is disabled.") }
        if action == "pause" || action == "resume" { saved = try registry.setIndexingPaused(uuid: canonical, paused: action == "pause") }
        let paths = try ExternalVolumePaths(baseDirectory: baseDirectory, uuid: canonical, capacityScope: saved.capacityScope)
        try paths.prepare()
        try ExternalVolumeStorage.ensureDirectory(InventoryRequests.directory(database: paths.inventoryDatabase))
        let request = try InventoryRequests.enqueue(database: paths.inventoryDatabase, action: action, path: path)
        try signal(uuid: canonical)
        return request
    }

    func signal(uuid: String? = nil) throws {
        guard NativeQARuntime.active == nil else { try NativeQARuntime.reject("External wake is outside the native QA fixture") }
        let canonical = try uuid.map { try ExternalVolumeIdentity($0).uuid }
        let document = try registry.read()
        let revision = canonical.flatMap { document.volumes[$0]?.revision } ?? document.revision
        let folder = InventoryRequests.directory(database: baseDirectory.appendingPathComponent("history.sqlite3").path)
        try ExternalVolumeStorage.write(ExternalDispatcherSignal(volumeUUID: canonical, settingsRevision: revision, requestedAt: Date()),
                                        to: folder.appendingPathComponent("external-wake.json"))
    }
}

enum ExternalInventorySchedule {
    static func order(targets: [String], after last: String?) -> [String] {
        guard let last, let index = targets.firstIndex(of: last), !targets.isEmpty else { return targets }
        return Array(targets.dropFirst(index + 1)) + Array(targets.prefix(index + 1))
    }
}
