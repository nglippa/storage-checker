import Foundation
import Darwin

enum ExternalCatalogError: Error, LocalizedError {
    case invalidManifest
    case unsafePath
    case missingSnapshot
    case invalidLease

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "The published external catalog metadata is invalid."
        case .unsafePath: return "The published external catalog path is unsafe."
        case .missingSnapshot: return "The published external catalog is unavailable."
        case .invalidLease: return "The external catalog reader lease is invalid."
        }
    }
}

struct ExternalCatalogSnapshot: Codable, Sendable, Equatable {
    let snapshotID: UUID
    let volumeUUID: String
    let generation: Int64
    let measuredAt: Date
    let completeness: String
    let settingsRevision: UInt64
    let inventorySequence: Int64?

    var filename: String { snapshotID.uuidString + ".sqlite3" }

    private enum CodingKeys: String, CodingKey {
        case snapshotID, volumeUUID, generation, measuredAt, completeness, settingsRevision, filename, inventorySequence
    }

    init(snapshotID: UUID, volumeUUID: String, generation: Int64, measuredAt: Date, completeness: String, settingsRevision: UInt64, inventorySequence: Int64? = nil) {
        self.snapshotID = snapshotID
        self.volumeUUID = volumeUUID
        self.generation = generation
        self.measuredAt = measuredAt
        self.completeness = completeness
        self.settingsRevision = settingsRevision
        self.inventorySequence = inventorySequence
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshotID = try values.decode(UUID.self, forKey: .snapshotID)
        volumeUUID = try values.decode(String.self, forKey: .volumeUUID)
        generation = try values.decode(Int64.self, forKey: .generation)
        measuredAt = try values.decode(Date.self, forKey: .measuredAt)
        completeness = try values.decode(String.self, forKey: .completeness)
        settingsRevision = try values.decode(UInt64.self, forKey: .settingsRevision)
        inventorySequence = try values.decodeIfPresent(Int64.self, forKey: .inventorySequence)
        let encodedFilename = try values.decode(String.self, forKey: .filename)
        guard encodedFilename == filename else {
            throw DecodingError.dataCorruptedError(forKey: .filename, in: values, debugDescription: "Catalog filename must match its snapshot UUID")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(snapshotID, forKey: .snapshotID)
        try values.encode(volumeUUID, forKey: .volumeUUID)
        try values.encode(generation, forKey: .generation)
        try values.encode(measuredAt, forKey: .measuredAt)
        try values.encode(completeness, forKey: .completeness)
        try values.encode(settingsRevision, forKey: .settingsRevision)
        try values.encodeIfPresent(inventorySequence, forKey: .inventorySequence)
        try values.encode(filename, forKey: .filename)
    }

    func validated(for paths: ExternalVolumePaths) throws -> ExternalCatalogSnapshot {
        guard (try? ExternalVolumeIdentity(volumeUUID).uuid) == volumeUUID,
              volumeUUID == paths.identity.uuid,
              generation > 0,
              inventorySequence.map({ $0 >= 0 }) ?? true,
              measuredAt.timeIntervalSinceReferenceDate.isFinite,
              ["complete", "partial"].contains(completeness),
              filename == snapshotID.uuidString + ".sqlite3",
              !filename.contains("/") else { throw ExternalCatalogError.invalidManifest }
        return self
    }
}

struct ExternalCatalogLeaseRecord: Codable, Sendable {
    let snapshotID: UUID
    let pid: Int32
    let createdAt: Date
}

func withExternalCatalogLock<T>(paths: ExternalVolumePaths, _ body: () throws -> T) throws -> T {
    try ExternalVolumeStorage.ensureDirectory(paths.catalogsDirectory)
    let lockURL = paths.catalogsDirectory.appendingPathComponent(".catalog.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw ExternalCatalogError.unsafePath }
    defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
          flock(descriptor, LOCK_EX) == 0 else { throw ExternalCatalogError.unsafePath }
    return try body()
}

enum ExternalCatalogAccess {
    static func current(paths: ExternalVolumePaths) throws -> ExternalCatalogSnapshot? {
        var info = stat()
        if lstat(paths.publicationURL.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw ExternalCatalogError.unsafePath
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 65_536 else {
            throw ExternalCatalogError.unsafePath
        }
        do {
            return try ExternalVolumeStorage.read(ExternalCatalogSnapshot.self, from: paths.publicationURL).validated(for: paths)
        } catch let error as ExternalCatalogError { throw error }
        catch { throw ExternalCatalogError.invalidManifest }
    }

    static func database(snapshot: ExternalCatalogSnapshot, paths: ExternalVolumePaths) throws -> String {
        try ExternalVolumeStorage.validateLocation(paths.catalogsDirectory)
        let checked = try snapshot.validated(for: paths)
        let url = paths.catalogsDirectory.appendingPathComponent(checked.filename, isDirectory: false)
        guard url.deletingLastPathComponent().standardizedFileURL == paths.catalogsDirectory.standardizedFileURL else {
            throw ExternalCatalogError.unsafePath
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { throw ExternalCatalogError.missingSnapshot }
            throw ExternalCatalogError.unsafePath
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw ExternalCatalogError.unsafePath }
        return url.path
    }
}

final class ExternalCatalogReaderLease: @unchecked Sendable {
    private let lock = NSLock()
    private var leaseURL: URL?

    init(paths: ExternalVolumePaths, snapshot: ExternalCatalogSnapshot) throws {
        let checked = try snapshot.validated(for: paths)
        leaseURL = try withExternalCatalogLock(paths: paths) {
            let directory = paths.catalogsDirectory.appendingPathComponent(".reader-leases", isDirectory: true)
            try ExternalVolumeStorage.ensureDirectory(directory)
            let url = directory.appendingPathComponent("\(checked.snapshotID.uuidString).\(getpid()).\(UUID().uuidString).json")
            let record = ExternalCatalogLeaseRecord(snapshotID: checked.snapshotID, pid: getpid(), createdAt: Date())
            try ExternalVolumeStorage.write(record, to: url)
            do { _ = try ExternalCatalogAccess.database(snapshot: checked, paths: paths) }
            catch { try? FileManager.default.removeItem(at: url); throw error }
            return url
        }
    }

    func release() {
        lock.lock()
        let url = leaseURL
        leaseURL = nil
        lock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    deinit { release() }
}
