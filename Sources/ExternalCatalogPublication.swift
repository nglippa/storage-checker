import Foundation
import Darwin
import SQLite3

enum ExternalCatalogPublicationError: Error, LocalizedError {
    case unsafeWorkingDatabase
    case lowSpace
    case invalidGeneration
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeWorkingDatabase: return "The external inventory working database is unsafe or unavailable."
        case .lowSpace: return "External catalog publication paused because internal storage is low."
        case .invalidGeneration: return "The external inventory generation is not ready for publication."
        case .backupFailed(let detail): return "External catalog backup failed: \(detail)"
        }
    }
}

private struct ExternalCatalogSourceMetadata {
    let generation: Int64
    let volumeUUID: String
    let state: String
    let measuredAt: Date
    let sequence: Int64
}

private final class ExternalCatalogValidationClock {
    let deadline: Date
    init(seconds: TimeInterval) { deadline = Date().addingTimeInterval(seconds) }
    var expired: Bool { Date() >= deadline }
}

enum ExternalCatalogPublisher {
    private static let backupDeadline: TimeInterval = 15

    static func publish(paths: ExternalVolumePaths, expectedGeneration: Int64, settingsRevision: UInt64,
                        validate: () throws -> Void) throws -> ExternalCatalogSnapshot {
        try validate()
        try paths.prepare()
        try ExternalVolumeStorage.ensureDirectory(paths.catalogsDirectory)
        try withExternalCatalogLock(paths: paths) { removeOrphanedStages(paths: paths) }
        guard !inventoryLowOnSpace(paths.inventoryDirectory) else { throw ExternalCatalogPublicationError.lowSpace }

        var workingInfo = stat()
        guard lstat(paths.inventoryDatabase, &workingInfo) == 0,
              workingInfo.st_mode & S_IFMT == S_IFREG,
              workingInfo.st_uid == getuid() else { throw ExternalCatalogPublicationError.unsafeWorkingDatabase }
        guard let space = inventoryAvailableSpace(paths.inventoryDirectory), workingInfo.st_size >= 0,
              space.available > inventoryLowSpaceThreshold(capacity: space.capacity),
              space.available - inventoryLowSpaceThreshold(capacity: space.capacity) > workingInfo.st_size + 64 * 1_048_576 else {
            throw ExternalCatalogPublicationError.lowSpace
        }

        let snapshotID = UUID()
        let staged = paths.catalogsDirectory.appendingPathComponent(".staging-\(snapshotID.uuidString).sqlite3")
        let final = paths.catalogsDirectory.appendingPathComponent(snapshotID.uuidString + ".sqlite3")
        var installed = false
        var published = false
        defer {
            try? FileManager.default.removeItem(at: staged)
            if installed && !published { try? FileManager.default.removeItem(at: final) }
        }

        let source = try openDatabase(paths.inventoryDatabase, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW)
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 250)
        var openedInfo = stat()
        guard lstat(paths.inventoryDatabase, &openedInfo) == 0, openedInfo.st_dev == workingInfo.st_dev,
              openedInfo.st_ino == workingInfo.st_ino else { throw ExternalCatalogPublicationError.unsafeWorkingDatabase }
        let before = try metadata(source)
        try require(before, paths: paths, expectedGeneration: expectedGeneration)

        let destination = try openDatabase(staged.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW)
        do {
            try backup(source: source, destination: destination)
            try sqliteExec(destination, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL")
        } catch {
            sqlite3_close(destination)
            throw error
        }
        sqlite3_close(destination)
        guard chmod(staged.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }

        let backed = try openDatabase(staged.path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW)
        let after: ExternalCatalogSourceMetadata
        do {
            after = try metadata(backed)
            try require(after, paths: paths, expectedGeneration: expectedGeneration)
            try integrityCheck(backed)
        } catch {
            sqlite3_close(backed)
            throw error
        }
        sqlite3_close(backed)
        guard before.generation == after.generation,
              before.volumeUUID == after.volumeUUID,
              before.state == after.state,
              before.measuredAt == after.measuredAt else { throw ExternalCatalogPublicationError.invalidGeneration }
        guard before.sequence == after.sequence else { throw ExternalCatalogPublicationError.invalidGeneration }
        return try withExternalCatalogLock(paths: paths) {
            let previous = try ExternalCatalogAccess.current(paths: paths)
            try validate()
            try requireUnchanged(metadata(source), from: after, paths: paths, expectedGeneration: expectedGeneration)
            guard rename(staged.path, final.path) == 0 else {
                throw ExternalCatalogPublicationError.backupFailed(String(cString: strerror(errno)))
            }
            installed = true
            let snapshot = ExternalCatalogSnapshot(snapshotID: snapshotID, volumeUUID: after.volumeUUID,
                                                   generation: after.generation, measuredAt: after.measuredAt,
                                                   completeness: after.state, settingsRevision: settingsRevision, inventorySequence: after.sequence)
            _ = try ExternalCatalogAccess.database(snapshot: snapshot, paths: paths)
            try validate()
            try requireUnchanged(metadata(source), from: after, paths: paths, expectedGeneration: expectedGeneration)
            #if INVENTORY_TESTS
            if let override = externalCatalogManifestWriteOverride { try override(snapshot, paths.publicationURL) }
            else { try ExternalVolumeStorage.write(snapshot, to: paths.publicationURL) }
            #else
            try ExternalVolumeStorage.write(snapshot, to: paths.publicationURL)
            #endif
            published = true
            prune(paths: paths, current: snapshot, previous: previous)
            return snapshot
        }
    }

    private static func openDatabase(_ path: String, flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (\(result))"
            sqlite3_close(database)
            throw ExternalCatalogPublicationError.backupFailed(detail)
        }
        return database
    }

    private static func sqliteExec(_ database: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw ExternalCatalogPublicationError.backupFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func metadata(_ database: OpaquePointer) throws -> ExternalCatalogSourceMetadata {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT id,volume_uuid,state,updated_at,inventory_sequence FROM inventory_generations WHERE active=1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let volume = sqlite3_column_text(statement, 1),
              let state = sqlite3_column_text(statement, 2) else { throw ExternalCatalogPublicationError.invalidGeneration }
        let value = ExternalCatalogSourceMetadata(generation: sqlite3_column_int64(statement, 0),
                                                  volumeUUID: String(cString: volume),
                                                  state: String(cString: state),
                                                  measuredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), sequence: sqlite3_column_int64(statement, 4))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ExternalCatalogPublicationError.invalidGeneration }
        return value
    }

    private static func require(_ value: ExternalCatalogSourceMetadata, paths: ExternalVolumePaths, expectedGeneration: Int64) throws {
        guard value.generation == expectedGeneration,
              value.volumeUUID == paths.identity.uuid,
              (try? ExternalVolumeIdentity(value.volumeUUID).uuid) == value.volumeUUID,
              ["complete", "partial"].contains(value.state),
              value.measuredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ExternalCatalogPublicationError.invalidGeneration
        }
    }

    private static func requireUnchanged(_ value: ExternalCatalogSourceMetadata, from snapshot: ExternalCatalogSourceMetadata,
                                         paths: ExternalVolumePaths, expectedGeneration: Int64) throws {
        try require(value, paths: paths, expectedGeneration: expectedGeneration)
        guard value.generation == snapshot.generation,
              value.volumeUUID == snapshot.volumeUUID,
              value.state == snapshot.state,
              value.measuredAt == snapshot.measuredAt, value.sequence == snapshot.sequence else { throw ExternalCatalogPublicationError.invalidGeneration }
    }

    private static func backup(source: OpaquePointer, destination: OpaquePointer) throws {
        guard let handle = sqlite3_backup_init(destination, "main", source, "main") else {
            throw ExternalCatalogPublicationError.backupFailed(String(cString: sqlite3_errmsg(destination)))
        }
        let deadline = Date().addingTimeInterval(backupDeadline)
        var result: Int32 = SQLITE_OK
        repeat {
            guard Date() < deadline else {
                _ = sqlite3_backup_finish(handle)
                throw ExternalCatalogPublicationError.backupFailed("catalog backup exceeded its deadline")
            }
            result = sqlite3_backup_step(handle, 256)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                guard Date() < deadline else {
                    _ = sqlite3_backup_finish(handle)
                    throw ExternalCatalogPublicationError.backupFailed("timed out waiting for the working database")
                }
                sqlite3_sleep(20)
            } else if result != SQLITE_OK && result != SQLITE_DONE {
                let detail = String(cString: sqlite3_errmsg(destination))
                _ = sqlite3_backup_finish(handle)
                throw ExternalCatalogPublicationError.backupFailed(detail)
            }
        } while result != SQLITE_DONE
        let finished = sqlite3_backup_finish(handle)
        guard finished == SQLITE_OK else {
            throw ExternalCatalogPublicationError.backupFailed(String(cString: sqlite3_errmsg(destination)))
        }
    }

    private static func integrityCheck(_ database: OpaquePointer) throws {
        #if INVENTORY_TESTS
        let seconds: TimeInterval = externalCatalogValidationBudgetOverride ?? 15
        #else
        let seconds: TimeInterval = 15
        #endif
        let clock = ExternalCatalogValidationClock(seconds: seconds)
        sqlite3_progress_handler(database, 1000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<ExternalCatalogValidationClock>.fromOpaque(pointer).takeUnretainedValue().expired ? 1 : 0
        }, Unmanaged.passUnretained(clock).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(clock) {} }
        guard !clock.expired else { throw ExternalCatalogPublicationError.backupFailed("snapshot validation exceeded its deadline") }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_text(statement, 0).map({ String(cString: $0) }) == "ok",
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ExternalCatalogPublicationError.backupFailed(clock.expired ? "snapshot validation exceeded its deadline" : "snapshot integrity check failed")
        }
    }

    private static func removeOrphanedStages(paths: ExternalVolumePaths) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.catalogsDirectory.path) else { return }
        let cutoff = Date().addingTimeInterval(-3600).timeIntervalSince1970
        for name in names where name.hasPrefix(".staging-") && name.hasSuffix(".sqlite3") {
            let raw = String(name.dropFirst(".staging-".count).dropLast(".sqlite3".count))
            guard UUID(uuidString: raw)?.uuidString == raw else { continue }
            let url = paths.catalogsDirectory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  Double(info.st_mtimespec.tv_sec) < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func prune(paths: ExternalVolumePaths, current: ExternalCatalogSnapshot, previous: ExternalCatalogSnapshot?) {
        guard let protectedByReaders = liveReaderSnapshots(paths: paths),
              let names = try? FileManager.default.contentsOfDirectory(atPath: paths.catalogsDirectory.path) else { return }
        var keep = protectedByReaders
        keep.insert(current.snapshotID)
        if let previous { keep.insert(previous.snapshotID) }
        for name in names where name.hasSuffix(".sqlite3") {
            let raw = String(name.dropLast(".sqlite3".count))
            guard let identifier = UUID(uuidString: raw), identifier.uuidString + ".sqlite3" == name,
                  !keep.contains(identifier) else { continue }
            let url = paths.catalogsDirectory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Nil means lease state is unavailable or corrupt, so pruning must be skipped entirely.
    private static func liveReaderSnapshots(paths: ExternalVolumePaths) -> Set<UUID>? {
        let directory = paths.catalogsDirectory.appendingPathComponent(".reader-leases", isDirectory: true)
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 { return errno == ENOENT ? [] : nil }
        guard directoryInfo.st_mode & S_IFMT == S_IFDIR, directoryInfo.st_uid == getuid(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var retained = Set<UUID>()
        var dead = [URL]()
        for name in names {
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 16_384,
                  let record = try? ExternalVolumeStorage.read(ExternalCatalogLeaseRecord.self, from: url),
                  record.pid > 0, record.createdAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
            errno = 0
            if kill(record.pid, 0) == 0 || errno == EPERM { retained.insert(record.snapshotID) }
            else if errno == ESRCH { dead.append(url) }
            else { retained.insert(record.snapshotID) }
        }
        for url in dead { try? FileManager.default.removeItem(at: url) }
        return retained
    }
}

#if INVENTORY_TESTS
var externalCatalogManifestWriteOverride: ((ExternalCatalogSnapshot, URL) throws -> Void)?
var externalCatalogValidationBudgetOverride: TimeInterval?
#endif
