import Foundation

/// One context supplies both viewer sections; the published catalog and mutable request mailbox are deliberately distinct.
struct StorageTargetContext: Sendable {
    let uuid: String?
    let title: String
    let historyDatabase: String
    let inventoryDatabase: String
    let requestDatabase: String
    let registration: ExternalVolumeRegistration?
    let descriptor: ExternalVolumeDescriptor?
    let snapshot: ExternalCatalogSnapshot?
    let issue: String?
    private let readerLease: ExternalCatalogReaderLease?

    var allowsCleanup: Bool { uuid == nil }
    var canRequest: Bool { uuid == nil || registration?.enabled == true && descriptor != nil && issue == nil }
    var key: String { (uuid ?? "startup") + ":" + (snapshot?.snapshotID.uuidString ?? "unpublished") }
    func unavailable(_ reason: String) -> Self {
        Self(uuid: uuid, title: title, historyDatabase: historyDatabase, inventoryDatabase: inventoryDatabase,
             requestDatabase: requestDatabase, registration: registration, descriptor: nil, snapshot: snapshot, issue: reason, readerLease: readerLease)
    }
    var status: String {
        guard let registration else { return "Internal storage" }
        if let issue { return issue }
        if !registration.enabled { return "Drive disabled · saved history and catalog retained" }
        if descriptor == nil { return "Disconnected · showing the last published catalog" }
        return registration.indexingPaused ? "Indexing paused · saved catalog available" : "Connected · ready to index"
    }

    static func startup(database: String) -> Self {
        Self(uuid: nil, title: "Startup Data", historyDatabase: database, inventoryDatabase: database, requestDatabase: database,
             registration: nil, descriptor: nil, snapshot: nil, issue: nil, readerLease: nil)
    }

    static func waiting(baseDirectory: URL, registration: ExternalVolumeRegistration) throws -> Self {
        let paths = try ExternalVolumePaths(baseDirectory: baseDirectory, uuid: registration.volumeUUID, capacityScope: registration.capacityScope)
        return Self(uuid: registration.volumeUUID, title: registration.name, historyDatabase: paths.capacityDatabase,
                    inventoryDatabase: paths.inventoryDirectory.appendingPathComponent("unpublished.sqlite3").path,
                    requestDatabase: paths.inventoryDatabase, registration: registration, descriptor: nil, snapshot: nil,
                    issue: "Verifying drive…", readerLease: nil)
    }

    static func external(baseDirectory: URL, uuid: String,
                         probe: (String) throws -> ExternalMountIdentity = ExternalMountProbe.read) throws -> Self {
        let id = try ExternalVolumeIdentity(uuid).uuid
        let registry = ExternalVolumeRegistry(baseDirectory: baseDirectory)
        guard let saved = try registry.read().volumes[id] else { throw ExternalVolumeError.invalidIdentity }
        let paths = try ExternalVolumePaths(baseDirectory: baseDirectory, uuid: id, capacityScope: saved.capacityScope)
        try ExternalVolumeStorage.validateDatabaseFile(paths.capacityDatabase)
        try ExternalVolumeStorage.validateDatabaseFile(paths.inventoryDatabase)
        let observations = try ExternalVolumeObservationStore(baseDirectory: baseDirectory).read()
        var descriptor: ExternalVolumeDescriptor?, issue: String?
        do {
            descriptor = try ExternalVolumeCatalog.resolve(uuid: id, descriptors: observations?.descriptors ?? [])
            if let current = descriptor {
                try registry.validate(current)
                guard let discovered = current.mountIdentity, try probe(current.mountPath) == discovered else {
                    throw ExternalVolumeError.unsupported("Refresh connected drives to verify this mount.")
                }
            }
        } catch { descriptor = nil; issue = error.localizedDescription }
        var snapshot: ExternalCatalogSnapshot?, lease: ExternalCatalogReaderLease?, database = paths.inventoryDirectory.appendingPathComponent("unpublished.sqlite3").path
        do {
            snapshot = try ExternalCatalogAccess.current(paths: paths)
            if let snapshot {
                lease = try ExternalCatalogReaderLease(paths: paths, snapshot: snapshot)
                database = try ExternalCatalogAccess.database(snapshot: snapshot, paths: paths)
            }
        } catch { issue = "Saved catalog unavailable: " + error.localizedDescription }
        return Self(uuid: id, title: descriptor?.name ?? saved.name, historyDatabase: paths.capacityDatabase,
                    inventoryDatabase: database, requestDatabase: paths.inventoryDatabase, registration: saved,
                    descriptor: descriptor, snapshot: snapshot, issue: issue, readerLease: lease)
    }
}
