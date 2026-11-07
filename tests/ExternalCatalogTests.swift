import Foundation
import Darwin
import SQLite3

#if INVENTORY_TESTS
private struct CatalogFixture {
    let base: URL
    let paths: ExternalVolumePaths
    let generation: Int64

    init(_ name: String) throws {
        base = URL(fileURLWithPath: "/private/tmp/storage-monitor-catalog-\(name)-\(UUID().uuidString)", isDirectory: true)
        let volume = UUID().uuidString
        paths = try ExternalVolumePaths(baseDirectory: base, uuid: volume, capacityScope: "filesystem:\(volume)")
        try paths.prepare()
        try initializeInventorySchema(databasePath: paths.inventoryDatabase)
        let now = Date().timeIntervalSince1970
        generation = try catalogWrite(paths.inventoryDatabase, "INSERT INTO inventory_generations(root_path,root_device,root_inode,root_birth_ns,state,created_at,updated_at,active,volume_uuid,initial_completion) VALUES ('/fixture',1,2,3,'complete',?,?,1,?,'complete')", [now, now, paths.identity.uuid])
        let object = try catalogWrite(paths.inventoryDatabase, "INSERT INTO inventory_objects(device,inode,birth_ns,kind,logical,allocated,link_count,modified_at,changed_ns,owner_node_id) VALUES (1,2,3,'file',11,12,1,?,4,NULL)", [now])
        _ = try catalogWrite(paths.inventoryDatabase, "INSERT INTO inventory_nodes(generation_id,parent_id,object_id,name,kind,status,total_logical,total_allocated,measured_at) VALUES (?,NULL,?,'fixture','directory','complete',11,12,?)", [generation, object, now])
    }

    func updateObject(logical: Int64, owner: Int64) throws {
        _ = try catalogWrite(paths.inventoryDatabase, "UPDATE inventory_objects SET logical=?,owner_node_id=?", [logical, owner])
        _ = try catalogWrite(paths.inventoryDatabase, "UPDATE inventory_generations SET updated_at=? WHERE id=?", [Date().timeIntervalSince1970, generation])
    }

    func setState(_ state: String) throws {
        _ = try catalogWrite(paths.inventoryDatabase, "UPDATE inventory_generations SET state=?,updated_at=? WHERE id=?", [state, Date().timeIntervalSince1970, generation])
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private enum CatalogTestFailure: Error { case injected }

private func catalogThrows(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

@discardableResult private func catalogWrite(_ path: String, _ sql: String, _ values: [Any] = []) throws -> Int64 {
    var database: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else { throw Failure("Cannot open catalog test fixture") }
    defer { sqlite3_finalize(statement); sqlite3_close(database) }
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure("Cannot prepare catalog test fixture write") }
    for (index, value) in values.enumerated() {
        let column = Int32(index + 1)
        if let value = value as? Int64 { sqlite3_bind_int64(statement, column, value) }
        else if let value = value as? Double { sqlite3_bind_double(statement, column, value) }
        else if let value = value as? String { sqlite3_bind_text(statement, column, value, -1, transient) }
        else { sqlite3_bind_null(statement, column) }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure("Cannot write catalog test fixture") }
    return sqlite3_last_insert_rowid(database)
}

private func snapshotValues(_ path: String) throws -> (Int64, Int64?) {
    var database: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { throw Failure("Cannot open catalog snapshot") }
    defer { sqlite3_finalize(statement); sqlite3_close(database) }
    guard sqlite3_prepare_v2(database, "SELECT logical,owner_node_id FROM inventory_objects LIMIT 1", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else { throw Failure("Missing snapshot object") }
    let owner = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 1)
    return (sqlite3_column_int64(statement, 0), owner)
}

private func publish(_ fixture: CatalogFixture, revision: UInt64 = 1, validate: () throws -> Void = {}) throws -> ExternalCatalogSnapshot {
    try ExternalCatalogPublisher.publish(paths: fixture.paths, expectedGeneration: fixture.generation, settingsRevision: revision, validate: validate)
}

private func snapshotIsolation(_ check: (Bool, String) throws -> Void) throws {
    let fixture = try CatalogFixture("isolation"); defer { fixture.remove() }
    let snapshot = try publish(fixture)
    let path = try ExternalCatalogAccess.database(snapshot: snapshot, paths: fixture.paths)
    try check(try snapshotValues(path) == (11, nil), "published catalog starts with committed object values")
    try fixture.updateObject(logical: 9001, owner: 71)
    try check(try snapshotValues(path) == (11, nil), "working owner/value mutation cannot change published snapshot")
    try check(try snapshotValues(fixture.paths.inventoryDatabase) == (9001, 71), "fixture proves working database really mutated")
}

private func failuresRetainPublication(_ check: (Bool, String) throws -> Void) throws {
    let fixture = try CatalogFixture("failures"); defer { fixture.remove() }
    let original = try publish(fixture)

    try fixture.setState("building")
    try check(catalogThrows { _ = try publish(fixture, revision: 2) }, "non-terminal generation must be rejected")
    try check(try ExternalCatalogAccess.current(paths: fixture.paths) == original, "non-terminal publication retains prior manifest")
    try fixture.setState("complete")

    var validations = 0
    let staleRejected = catalogThrows {
        _ = try publish(fixture, revision: 2) {
            validations += 1
            if validations == 2 { throw CatalogTestFailure.injected }
        }
    }
    try check(staleRejected, "post-backup stale revision must be rejected")
    try check(validations >= 2, "publisher revalidates after creating the backup")
    try check(try ExternalCatalogAccess.current(paths: fixture.paths) == original, "stale revision retains prior manifest")

    let saved = fixture.paths.inventoryDirectory.appendingPathComponent("working.saved.sqlite3")
    try FileManager.default.moveItem(at: URL(fileURLWithPath: fixture.paths.inventoryDatabase), to: saved)
    try FileManager.default.createDirectory(atPath: fixture.paths.inventoryDatabase, withIntermediateDirectories: false)
    try check(catalogThrows { _ = try publish(fixture, revision: 2) }, "backup source failure must be rejected")
    try FileManager.default.removeItem(atPath: fixture.paths.inventoryDatabase)
    try FileManager.default.moveItem(at: saved, to: URL(fileURLWithPath: fixture.paths.inventoryDatabase))
    try check(try ExternalCatalogAccess.current(paths: fixture.paths) == original, "backup failure retains prior manifest")

    let savedSpace = inventoryAvailableSpaceOverride
    inventoryAvailableSpaceOverride = (available: 1, capacity: 500_000_000_000)
    defer { inventoryAvailableSpaceOverride = savedSpace }
    try check(catalogThrows { _ = try publish(fixture, revision: 2) }, "low-space publication must be rejected")
    try check(try ExternalCatalogAccess.current(paths: fixture.paths) == original, "low-space refusal retains prior manifest")

    inventoryAvailableSpaceOverride = (available: inventoryLowSpaceThreshold(capacity: 500_000_000_000) + 1, capacity: 500_000_000_000)
    try check(catalogThrows { _ = try publish(fixture, revision: 2) }, "publication reserves room for the snapshot above indexing's free-space floor")
    inventoryAvailableSpaceOverride = savedSpace

    var attemptedManifest = false
    externalCatalogManifestWriteOverride = { _, _ in attemptedManifest = true; throw CatalogTestFailure.injected }
    defer { externalCatalogManifestWriteOverride = nil }
    try check(catalogThrows { _ = try publish(fixture, revision: 2) }, "manifest replacement failure must be rejected")
    try check(attemptedManifest, "manifest failure test reaches the atomic write after backup")
    try check(try ExternalCatalogAccess.current(paths: fixture.paths) == original, "manifest replacement failure retains prior manifest")
    externalCatalogValidationBudgetOverride = 0
    defer { externalCatalogValidationBudgetOverride = nil }
    var reachedManifestAfterTimeout = false
    externalCatalogManifestWriteOverride = { _, _ in reachedManifestAfterTimeout = true; throw CatalogTestFailure.injected }
    try check(catalogThrows { _ = try publish(fixture, revision: 2) }, "an exhausted integrity-validation deadline refuses publication")
    try check(!reachedManifestAfterTimeout, "validation timeout cannot reach manifest replacement")
    try check(try ExternalCatalogAccess.current(paths: fixture.paths) == original, "validation timeout retains the last good catalog")
}

private func malformedPublicationIsRejected(_ check: (Bool, String) throws -> Void) throws {
    let fixture = try CatalogFixture("malformed"); defer { fixture.remove() }
    let snapshot = try publish(fixture)
    let valid = try Data(contentsOf: fixture.paths.publicationURL)
    var object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    object["filename"] = "../../startup.sqlite3"
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.paths.publicationURL, options: .atomic)
    try check(catalogThrows { _ = try ExternalCatalogAccess.current(paths: fixture.paths) }, "manifest traversal filename must be rejected")

    object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    object["volumeUUID"] = UUID().uuidString
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.paths.publicationURL, options: .atomic)
    try check(catalogThrows { _ = try ExternalCatalogAccess.current(paths: fixture.paths) }, "manifest identity mismatch must be rejected")

    try valid.write(to: fixture.paths.publicationURL, options: .atomic)
    let snapshotURL = URL(fileURLWithPath: try ExternalCatalogAccess.database(snapshot: snapshot, paths: fixture.paths))
    let moved = snapshotURL.appendingPathExtension("real")
    try FileManager.default.moveItem(at: snapshotURL, to: moved)
    try FileManager.default.createSymbolicLink(at: snapshotURL, withDestinationURL: moved)
    try check(catalogThrows { _ = try ExternalCatalogAccess.database(snapshot: snapshot, paths: fixture.paths) }, "snapshot symlink must be rejected")
}

private func leasePreventsPruning(_ check: (Bool, String) throws -> Void) throws {
    let fixture = try CatalogFixture("lease"); defer { fixture.remove() }
    let first = try publish(fixture)
    let firstPath = try ExternalCatalogAccess.database(snapshot: first, paths: fixture.paths)
    let lease = try ExternalCatalogReaderLease(paths: fixture.paths, snapshot: first)
    try fixture.updateObject(logical: 21, owner: 1); let second = try publish(fixture, revision: 2)
    try fixture.updateObject(logical: 31, owner: 2); _ = try publish(fixture, revision: 3)
    try check(FileManager.default.fileExists(atPath: firstPath), "live reader lease preserves snapshot beyond current/previous")
    try check(try snapshotValues(firstPath).0 == 11, "leased snapshot remains readable and immutable")
    lease.release()
    let leases = fixture.paths.catalogsDirectory.appendingPathComponent(".reader-leases", isDirectory: true)
    try Data("corrupt".utf8).write(to: leases.appendingPathComponent("corrupt.json"))
    try fixture.updateObject(logical: 41, owner: 3); _ = try publish(fixture, revision: 4)
    try check(FileManager.default.fileExists(atPath: firstPath), "corrupt lease state conservatively disables pruning")
    try FileManager.default.removeItem(at: leases.appendingPathComponent("corrupt.json"))
    try fixture.updateObject(logical: 51, owner: 4); _ = try publish(fixture, revision: 5)
    try check(!FileManager.default.fileExists(atPath: firstPath), "released old snapshot is pruned after a later publication")
    try check(catalogThrows { _ = try ExternalCatalogReaderLease(paths: fixture.paths, snapshot: second) },
              "a lease acquired after its stale snapshot was pruned fails safely")
}

private func recoverOrphanedStages(_ check: (Bool, String) throws -> Void) throws {
    let fixture = try CatalogFixture("orphan"); defer { fixture.remove() }
    let original = try publish(fixture)
    let stale = fixture.paths.catalogsDirectory.appendingPathComponent(".staging-\(UUID().uuidString).sqlite3")
    let recent = fixture.paths.catalogsDirectory.appendingPathComponent(".staging-\(UUID().uuidString).sqlite3")
    try Data("interrupted copy".utf8).write(to: stale)
    try Data("possibly active copy".utf8).write(to: recent)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stale.path)
    _ = try publish(fixture, revision: 2)
    try check(!FileManager.default.fileExists(atPath: stale.path), "old orphaned staging copies are reclaimed after an interrupted publisher")
    try check(FileManager.default.fileExists(atPath: recent.path), "recent staged copies are not mistaken for crash orphans")
    try check(try snapshotValues(ExternalCatalogAccess.database(snapshot: original, paths: fixture.paths)).0 == 11, "orphan recovery never damages the previous published catalog")
}

@main struct ExternalCatalogTestsMain {
    static func main() throws {
        inventoryAvailableSpaceOverride = (available: 100_000_000_000, capacity: 500_000_000_000)
        defer { inventoryAvailableSpaceOverride = nil }
        var assertions = 0
        func check(_ condition: Bool, _ message: String) throws {
            assertions += 1
            if !condition { throw Failure("External catalog test failed: \(message)") }
        }
        try snapshotIsolation(check)
        try failuresRetainPublication(check)
        try malformedPublicationIsRejected(check)
        try leasePreventsPruning(check)
        try recoverOrphanedStages(check)
        print("External catalog tests passed (\(assertions) assertions)")
    }
}
#endif
