import Foundation
import SQLite3

#if INVENTORY_TESTS
// Durable first-pass completion milestone (INVENTORY-COMPLETION-LIFECYCLE.md).
// Real filesystem fixtures and real worker runs; SQL is used only to construct legacy,
// concurrent or interrupted states that a fixture cannot reach deterministically.
private struct CompletionFixture {
    let root: String, state: URL, database: String, region: CoverageRegion, db: Database
    func run(_ options: InventoryRunOptions = InventoryRunOptions(maxDuration: 10), region override: CoverageRegion? = nil) -> InventoryRunResult {
        runInventory(databasePath: database, directory: state, region: override ?? region, options: options, fdaOverride: "granted")
    }
    func milestone() throws -> (state: String, at: String?, generation: Int64) {
        let row = try db.rows("SELECT id,initial_completion,initial_completed_at FROM inventory_generations WHERE active=1").first!
        return (row["initial_completion"]!, row["initial_completed_at"], Int64(row["id"]!)!)
    }
    func status() async throws -> InventoryStatus { try await InventoryReader(path: database).status() }
    func firstListingsPending() throws -> Int {
        Int(try db.rows("SELECT COUNT(*) AS n FROM inventory_jobs WHERE state IN ('pending','enumerating') AND completed_token=0").first!["n"]!)!
    }
    func scalar(_ sql: String, _ values: [Any] = []) throws -> String { try db.rows(sql, values).first?.values.first ?? "" }
}

private func completionFixture(_ name: String, directories: Int = 8, nested: Bool = true) throws -> CompletionFixture {
    let root = "/private/tmp/storage-monitor-completion-\(name)-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    for index in 0..<directories {
        try fm.createDirectory(atPath: root + "/d\(index)" + (nested ? "/inner" : ""), withIntermediateDirectories: true)
        try Data(count: 1_024).write(to: URL(fileURLWithPath: root + "/d\(index)/file"))
        if nested { try Data(count: 512).write(to: URL(fileURLWithPath: root + "/d\(index)/inner/leaf")) }
    }
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    return CompletionFixture(root: root, state: state, database: database, region: coverageRegion(root: root)!, db: try Database(database))
}

private func removeFixture(_ fixture: CompletionFixture) {
    try? fm.removeItem(atPath: fixture.root); try? fm.removeItem(at: fixture.state)
}

/// Rewinds a migrated catalog to an earlier on-disk format (columns absent), as an old worker left it.
private func simulateLegacyFormat(_ db: Database, withoutLifecycleTokens: Bool) throws {
    try db.exec("DROP INDEX IF EXISTS inventory_jobs_first_listing")
    try db.exec("ALTER TABLE inventory_generations DROP COLUMN initial_completed_at")
    try db.exec("ALTER TABLE inventory_generations DROP COLUMN initial_completion")
    if withoutLifecycleTokens { try db.exec("ALTER TABLE inventory_jobs DROP COLUMN completed_token") }
}

func inventoryCompletionTests(_ test: (Bool, String) throws -> Void) async throws {
    try await freshAndInitialTests(test)
    try await completionAndLaterWorkTests(test)
    try invariantClauseTests(test)
    try concurrencyAndInterruptionTests(test)
    try await scopeAndGenerationTests(test)
    try await legacyTests(test)
    try auditRegressionTests(test)
}

// Lifecycle audit (2026-10-23). Each case runs with the first pass still recorded in progress.
private func auditRegressionTests(_ test: (Bool, String) throws -> Void) throws {
    // A folder replaced at the same name by a new directory object has never been listed.
    // It must block completion like any newly discovered folder; before the fix it kept the
    // replaced object's first-listing token.
    let replaced = try completionFixture("replaced")
    defer { removeFixture(replaced); try? fm.removeItem(atPath: replaced.root + "-old-d0") }
    _ = replaced.run()
    let generation = try replaced.milestone().generation
    try fm.moveItem(atPath: replaced.root + "/d0", toPath: replaced.root + "-old-d0")
    try fm.createDirectory(atPath: replaced.root + "/d0/newchild", withIntermediateDirectories: true)
    try invalidateInventory(databasePath: replaced.database, paths: [replaced.root], eventID: nil, gap: false, reason: "Filesystem activity")
    _ = replaced.run(InventoryRunOptions(maxDuration: 10, stopAfterEntries: 8))   // relists the root only
    // Evaluate the observed state as if the first pass were still in progress.
    try replaced.db.write("UPDATE inventory_generations SET initial_completion='pending',initial_completed_at=NULL WHERE id=?", [generation])
    let job = try replaced.db.rows("SELECT j.state,j.completed_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='d0' AND n.parent_id=(SELECT id FROM inventory_nodes WHERE parent_id IS NULL)").first ?? [:]
    let recordedEarly = try recordInitialInventoryCompletionForTesting(databasePath: replaced.database, generation: generation)
    try test(job["state"] == "pending" && job["completed_token"] == "0" && !recordedEarly && (try replaced.milestone().state) == "pending",
             "a folder replaced by a new directory object needs its own first listing before completion is recorded (job \(job))")
    let resumed = replaced.run()
    try test(resumed.outcome == "complete" && (try replaced.milestone().state) == "complete" && (try replaced.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name='newchild'")) == "1",
             "the replacement is listed, its new contents are discovered, and completion is then recorded")

    // Why unapplied change notices are a transition precondition: applying one can re-queue
    // a folder that was never listed (here, previously unreadable). Once applied and resolved,
    // completion proceeds and the folder stays recorded as unavailable.
    let locked = try completionFixture("requeued-unavailable")
    defer { _ = chmod(locked.root + "/d2", 0o755); removeFixture(locked) }
    _ = chmod(locked.root + "/d2", 0o000)
    _ = locked.run()
    let lockedGeneration = try locked.milestone().generation
    try locked.db.write("UPDATE inventory_generations SET initial_completion='pending',initial_completed_at=NULL WHERE id=?", [lockedGeneration])
    try invalidateInventory(databasePath: locked.database, paths: [locked.root + "/d2"], eventID: nil, gap: false, reason: "Filesystem activity")
    try test(try !recordInitialInventoryCompletionForTesting(databasePath: locked.database, generation: lockedGeneration),
             "an unapplied change notice for an unlisted folder blocks recording until it is applied")
    let drained = locked.run()
    try test(drained.outcome == "partial" && (try locked.milestone().state) == "complete" && (try locked.scalar("SELECT status FROM inventory_nodes WHERE name='d2'")) == "unknown",
             "after the notice is applied and the folder is retried, completion is recorded with the folder still unavailable")
}

private func freshAndInitialTests(_ test: (Bool, String) throws -> Void) async throws {
    // 1. Fresh database before indexing.
    let fresh = try completionFixture("fresh")
    defer { removeFixture(fresh) }
    try initializeInventorySchema(databasePath: fresh.database)
    let none = try await fresh.status()
    try test(none.generation == nil && none.initialCompletion == .notStarted && (try fresh.scalar("SELECT COUNT(*) FROM pragma_table_info('inventory_generations') WHERE name IN ('initial_completion','initial_completed_at')")) == "2",
             "fresh schema has the milestone columns and reports not started before any generation")

    // 2 + 4. Pending first listings, then newly discovered descendants, keep the generation in progress.
    let first = fresh.run(InventoryRunOptions(maxDuration: 10, batchSize: 2, stopAfterEntries: 3))
    let pending = try fresh.milestone(), early = try await fresh.status()
    try test(first.outcome == "interrupted" && pending.state == "pending" && pending.at == nil && early.initialCompletion == .inProgress && early.hasInitialDiscoveryWork,
             "a new generation is recorded in progress while first listings are pending")
    _ = fresh.run(InventoryRunOptions(maxDuration: 10, batchSize: 4, stopAfterEntries: 14))
    let deeper = try fresh.scalar("SELECT COUNT(*) FROM inventory_nodes n JOIN inventory_jobs j ON j.node_id=n.id WHERE n.name='inner' AND j.completed_token=0 AND j.state IN ('pending','enumerating')")
    try test((Int(deeper) ?? 0) > 0 && (try fresh.milestone().state) == "pending", "newly discovered descendant folders awaiting their first listing keep completion unrecorded")

    // 3. A first listing that is running (enumerating with a committed checkpoint).
    let wide = try completionFixture("running", directories: 0)
    defer { removeFixture(wide) }
    try fm.createDirectory(atPath: wide.root + "/wide", withIntermediateDirectories: true)
    for index in 0..<300 { try Data([1]).write(to: URL(fileURLWithPath: wide.root + "/wide/f\(index)")) }
    _ = wide.run(InventoryRunOptions(maxDuration: 10, stopAfterEntries: 1))
    _ = wide.run(InventoryRunOptions(maxDuration: 10, batchSize: 40, stopAfterEntries: 80))
    try test((try wide.scalar("SELECT COUNT(*) FROM inventory_jobs WHERE state='enumerating' AND completed_token=0")) == "1" && (try wide.milestone().state) == "pending",
             "a running first listing with committed partial entries keeps completion unrecorded")

    // 5. Paused first pass.
    let cancel = fresh.state.appendingPathComponent("inventory.cancel").path
    try Data("pause\n".utf8).write(to: URL(fileURLWithPath: cancel))
    let paused = fresh.run(InventoryRunOptions(maxDuration: 10, cancelFile: cancel))
    try test(paused.reason == "cancelled" && (try fresh.milestone().state) == "pending" && (try fresh.firstListingsPending()) > 0, "pausing the first pass never records completion")
    try fm.removeItem(atPath: cancel)

    // 6. Completion after all required initial work.
    let done = fresh.run()
    let complete = try fresh.milestone(), status = try await fresh.status()
    try test(done.outcome == "complete" && complete.state == "complete" && complete.at != nil && status.initialCompletion == .complete && status.initialCompletedAt != nil && (try fresh.firstListingsPending()) == 0,
             "completion is recorded once every first listing has finished")
    let resumedWide = wide.run()
    try test(resumedWide.outcome == "complete" && (try wide.milestone().state) == "complete", "an interrupted running first listing resumes and then records completion")
}

private func completionAndLaterWorkTests(_ test: (Bool, String) throws -> Void) async throws {
    // 7. Inaccessible directories finish as recorded gaps without Full Disk Access semantics.
    let locked = try completionFixture("inaccessible")
    defer { _ = chmod(locked.root + "/d1", 0o755); removeFixture(locked) }
    _ = chmod(locked.root + "/d1", 0o000)
    let lockedRun = locked.run()
    let lockedStatus = try await locked.status()
    try test(lockedRun.outcome == "partial" && (try locked.milestone().state) == "complete" && lockedStatus.unknownDirectories > 0 && lockedStatus.completeness != .complete
             && (try locked.scalar("SELECT status FROM inventory_nodes WHERE name='d1'")) == "unknown",
             "accessible first pass completes while the inaccessible folder stays explicitly unknown")

    // 10–13. Later creation of thousands of directories, viewer launch and restarts.
    let later = try completionFixture("later")
    defer { removeFixture(later) }
    _ = later.run()
    let recorded = try later.milestone()
    try fm.createDirectory(atPath: later.root + "/bulk", withIntermediateDirectories: true)
    for index in 0..<2_000 { try fm.createDirectory(atPath: later.root + "/bulk/n\(index)", withIntermediateDirectories: false) }
    try invalidateInventory(databasePath: later.database, paths: [later.root], eventID: nil, gap: false, reason: "Filesystem activity")
    let partial = later.run(InventoryRunOptions(maxDuration: 10, batchSize: 64, stopAfterEntries: 400))
    let launch = try await later.status()   // a freshly launched viewer reads only durable state
    try test(partial.outcome == "interrupted" && (try later.firstListingsPending()) > 0 && launch.hasInitialDiscoveryWork && launch.initialCompletion == .complete
             && (try later.milestone().at) == recorded.at,
             "thousands of new never-listed folders after completion do not reset the milestone")
    try test(!InventoryInitializationPresentation(status: launch).isVisible && InventoryStatusPresentation(status: launch).phase == .updating,
             "a viewer launched during a large later update shows an ordinary update, not a first pass")
    let restartedViewer = try await InventoryReader(path: later.database).status()
    try test(restartedViewer.initialCompletion == .complete && restartedViewer.initialCompletedAt == launch.initialCompletedAt, "a restarted viewer reads the same recorded completion")
    let restartedWorker = later.run()
    try test(restartedWorker.outcome == "complete" && (try later.milestone().state) == "complete" && (try later.milestone().at) == recorded.at,
             "worker restarts preserve the original completion record (idempotent)")

    // A manual full refresh is a broad pass too, but it is not described as missed events.
    try requestInventoryRefresh(databasePath: later.database, paths: [later.root])
    _ = later.run(InventoryRunOptions(maxDuration: 10, stopAfterEntries: 0))
    let manual = try await later.status()
    try test(manual.hasReconciliationWork && !manual.hasEventGapRecheck && manual.initialCompletion == .complete && manual.refreshIsManual
             && manual.refreshFraction.map { $0 >= 0 && $0 <= 1 } == true && InventoryStatusPresentation(status: manual).headline.hasPrefix("Refreshing the entire inventory"),
             "a manual full refresh reconciles without resetting completion or claiming missed file events, and says it is refreshing (\(InventoryStatusPresentation(status: manual).headline))")
    _ = later.run()

    // 14. Event-history gap after completion.
    try invalidateInventory(databasePath: later.database, paths: [], eventID: nil, gap: true, reason: "event history gap")
    _ = later.run(InventoryRunOptions(maxDuration: 10, stopAfterEntries: 0))
    let gap = try await later.status()
    try test(gap.hasReconciliationWork && gap.hasEventGapRecheck && gap.initialCompletion == .complete && InventoryStatusPresentation(status: gap).headline == "Rechecking after missed file events"
             && !InventoryInitializationPresentation(status: gap).isVisible,
             "an event-history gap queues a broader recheck without resetting completion")
    let drained = later.run()
    try test(drained.outcome == "complete" && (try later.milestone().at) == recorded.at, "the broad recheck drains with the original completion record intact")
}

private func invariantClauseTests(_ test: (Bool, String) throws -> Void) throws {
    // 8–9 and the individual invariant clauses, constructed on a real completed catalog.
    let fixture = try completionFixture("clauses")
    defer { removeFixture(fixture) }
    _ = fixture.run()
    let generation = try fixture.milestone().generation
    let root = try fixture.scalar("SELECT id FROM inventory_nodes WHERE parent_id IS NULL")
    let child = try fixture.scalar("SELECT id FROM inventory_nodes WHERE name='d0'")
    func reset() throws { try fixture.db.write("UPDATE inventory_generations SET initial_completion='pending',initial_completed_at=NULL WHERE id=?", [generation]) }
    func record() throws -> Bool { try recordInitialInventoryCompletionForTesting(databasePath: fixture.database, generation: generation) }

    try reset()
    try fixture.db.write("INSERT INTO inventory_prune_jobs(parent_node_id,generation_id,seen_token,created_at) VALUES (?,?,0,0)", [root, generation])
    try fixture.db.write("INSERT INTO inventory_tombstones(node_id,generation_id,created_at) SELECT id,generation_id,0 FROM inventory_nodes WHERE name='file' LIMIT 1")
    try test(try record() && (try fixture.milestone().state) == "complete", "deferred cleanup (prune jobs and tombstones) does not block completion")

    try reset()
    try fixture.db.write("UPDATE inventory_jobs SET state='pending',reason='Filesystem activity' WHERE node_id=?", [child])
    try fixture.db.write("INSERT INTO inventory_reconcile(root_node_id,generation_id,reason,created_at,end_node_id,request_sequence) VALUES (?,?,'event history gap',0,1,1)", [root, generation])
    try test(try record(), "unrelated incremental relisting and reconciliation work do not block completion")

    try reset()
    try fixture.db.write("UPDATE inventory_jobs SET completed_token=0 WHERE node_id=?", [child])
    try test(try !record() && (try fixture.milestone().state) == "pending", "a folder awaiting its first listing blocks completion")
    try fixture.db.write("UPDATE inventory_jobs SET state='complete',completed_token=1 WHERE node_id=?", [child])

    try fixture.db.write("INSERT INTO inventory_invalidations(generation_id,absolute_path,reason,gap,created_at) VALUES (?,?,'Filesystem activity',0,0)", [generation, fixture.root])
    try test(try !record(), "an unapplied invalidation (in-flight discovery input) blocks completion")
    try fixture.db.write("DELETE FROM inventory_invalidations")

    try fixture.db.write("DELETE FROM inventory_jobs WHERE node_id=(SELECT MIN(id) FROM inventory_nodes WHERE name='inner')")
    try test(try !record(), "a traversable folder with no job to list it blocks completion")
    try fixture.db.write("INSERT INTO inventory_jobs(node_id,generation_id,state,updated_at,completed_token) SELECT MIN(id),?,'complete',0,1 FROM inventory_nodes WHERE name='inner'", [generation])
    try fixture.db.write("UPDATE inventory_nodes SET status='pending' WHERE id=(SELECT MIN(id) FROM inventory_nodes WHERE name='inner')")
    try test(try !record(), "a folder marked pending without unfinished listing work blocks completion")
    try fixture.db.write("UPDATE inventory_nodes SET status='complete' WHERE name='inner'")
    try test(try record(), "with every clause satisfied completion is recorded")
    let first = try fixture.milestone().at
    try fixture.db.write("UPDATE inventory_jobs SET completed_token=0,state='pending' WHERE node_id=?", [child])
    try test(try record() && (try fixture.milestone().at) == first, "recording is idempotent and later never-listed work never clears it")
}

private func concurrencyAndInterruptionTests(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try completionFixture("concurrency")
    defer { removeFixture(fixture) }
    _ = fixture.run()
    let generation = try fixture.milestone().generation
    try fixture.db.write("UPDATE inventory_generations SET initial_completion='pending',initial_completed_at=NULL WHERE id=?", [generation])

    // 15. An interrupted completion transaction leaves no marker.
    try fixture.db.exec("BEGIN IMMEDIATE")
    try fixture.db.write("UPDATE inventory_generations SET initial_completion='complete',initial_completed_at=1 WHERE id=?", [generation])
    try fixture.db.exec("ROLLBACK")
    try test((try fixture.milestone().state) == "pending" && (try fixture.milestone().at) == nil, "a completion write interrupted before commit leaves the generation in progress")

    // 16. Concurrent discovery: a peer holding the writer lock cannot be raced, and the
    // milestone re-verifies first-listing work after the peer commits new discovery.
    let peer = try Database(fixture.database)
    let parent = try fixture.scalar("SELECT id FROM inventory_nodes WHERE name='d0'")
    let object = try fixture.scalar("SELECT object_id FROM inventory_nodes WHERE name='d0'")
    try peer.exec("BEGIN IMMEDIATE")
    try peer.write("INSERT INTO inventory_nodes(generation_id,parent_id,object_id,name,kind,status,measured_at) VALUES (?,?,?,'concurrent','directory','pending',0)", [generation, parent, object])
    try peer.write("INSERT INTO inventory_jobs(node_id,generation_id,state,updated_at) SELECT id,?,'pending',0 FROM inventory_nodes WHERE name='concurrent'", [generation])
    var recordedThroughPeer = false
    do { recordedThroughPeer = try recordInitialInventoryCompletionForTesting(databasePath: fixture.database, generation: generation) } catch { recordedThroughPeer = false }
    try peer.exec("COMMIT")
    try test(!recordedThroughPeer && (try fixture.milestone().state) == "pending", "completion cannot be recorded through another writer's uncommitted discovery")
    try test(try !recordInitialInventoryCompletionForTesting(databasePath: fixture.database, generation: generation) && (try fixture.milestone().state) == "pending",
             "after concurrent discovery commits, its first listing blocks completion")
    try fixture.db.write("DELETE FROM inventory_jobs WHERE node_id IN (SELECT id FROM inventory_nodes WHERE name='concurrent')")
    try fixture.db.write("DELETE FROM inventory_nodes WHERE name='concurrent'")
    try test(try recordInitialInventoryCompletionForTesting(databasePath: fixture.database, generation: generation), "completion is recorded once the concurrent discovery is resolved")
}

private func scopeAndGenerationTests(_ test: (Bool, String) throws -> Void) async throws {
    // 17. Scope change: a different root starts a new generation; the old record stays with its scope.
    let fixture = try completionFixture("scope")
    defer { removeFixture(fixture); try? fm.removeItem(atPath: fixture.root + "-other"); try? fm.removeItem(atPath: fixture.root + "-saved") }
    _ = fixture.run()
    let original = try fixture.milestone()
    try fm.createDirectory(atPath: fixture.root + "-other/x", withIntermediateDirectories: true)
    let other = coverageRegion(root: fixture.root + "-other")!
    _ = fixture.run(InventoryRunOptions(maxDuration: 10, stopAfterEntries: 0), region: other)
    let scoped = try fixture.milestone(), scopedStatus = try await fixture.status()
    let old = try fixture.db.rows("SELECT active,initial_completion FROM inventory_generations WHERE id=?", [original.generation]).first!
    try test(scoped.generation != original.generation && scoped.state == "pending" && scopedStatus.initialCompletion == .inProgress && old["active"] == "0" && old["initial_completion"] == "complete",
             "a scope change begins a new in-progress generation; the superseded scope keeps its own record")

    // 18. A replaced root (new filesystem identity) is a genuinely new generation.
    _ = fixture.run()
    try fm.moveItem(atPath: fixture.root, toPath: fixture.root + "-saved")
    try fm.createDirectory(atPath: fixture.root + "/fresh", withIntermediateDirectories: true)
    _ = fixture.run(InventoryRunOptions(maxDuration: 10, stopAfterEntries: 0))
    let newGeneration = try fixture.milestone()
    try test(newGeneration.generation != original.generation && newGeneration.generation != scoped.generation && newGeneration.state == "pending",
             "a new root identity starts a new generation whose first pass is in progress")
    let finished = fixture.run()
    try test(finished.outcome == "complete" && (try fixture.milestone().state) == "complete", "the new generation records its own completion")
}

private func legacyTests(_ test: (Bool, String) throws -> Void) async throws {
    // 19. Legacy catalog with ambiguous state: an older worker left a refresh backlog whose
    // listing tokens did not exist, so pending jobs cannot prove they were listed before.
    let ambiguous = try completionFixture("legacy-ambiguous")
    defer { removeFixture(ambiguous) }
    _ = ambiguous.run()
    try ambiguous.db.write("UPDATE inventory_jobs SET state='pending',reason='Filesystem activity' WHERE node_id IN (SELECT id FROM inventory_nodes WHERE name IN ('d0','d1'))")
    try simulateLegacyFormat(ambiguous.db, withoutLifecycleTokens: true)
    let unmigrated = try await ambiguous.status()
    try test(unmigrated.initialCompletion == .unsupported && unmigrated.generation != nil, "a viewer reading a catalog without the milestone reports it unsupported, never in progress or complete")
    try initializeInventorySchema(databasePath: ambiguous.database)
    let generation = try ambiguous.milestone().generation
    let migrated = try await ambiguous.status()
    try test((try ambiguous.milestone().state) == "unknown" && migrated.initialCompletion == .unknown, "migration marks an existing generation unknown, not in progress")
    try test(try !recordInitialInventoryCompletionForTesting(databasePath: ambiguous.database, generation: generation) && (try ambiguous.milestone().state) == "unknown",
             "ambiguous legacy pending work cannot establish completion")
    let tokensBefore = try ambiguous.scalar("SELECT SUM(listing_token) FROM inventory_jobs")
    let resolved = ambiguous.run()
    let relisted = Int(try ambiguous.scalar("SELECT SUM(listing_token) FROM inventory_jobs"))! - Int(tokensBefore)!
    try test(resolved.outcome == "complete" && (try ambiguous.milestone().state) == "complete" && relisted == 2,
             "the worker confirms legacy completion after relisting only its two queued folders (relisted \(relisted))")

    // 20 + 22. Legacy catalog whose durable state establishes completion confidently; no crawl.
    let confident = try completionFixture("legacy-confident")
    defer { removeFixture(confident) }
    _ = confident.run()
    try confident.db.write("INSERT INTO readings(id,timestamp,container,free,used,volumes) VALUES (77,1,'keep',2,3,'[]')")
    try simulateLegacyFormat(confident.db, withoutLifecycleTokens: false)
    let snapshot = "SELECT (SELECT COUNT(*) FROM inventory_nodes) AS nodes,(SELECT SUM(listing_token) FROM inventory_jobs) AS tokens,(SELECT GROUP_CONCAT(state||completed_token) FROM inventory_jobs) AS jobs"
    let before = try confident.db.rows(snapshot).first!
    let confirmed = confident.run()
    let after = try confident.db.rows(snapshot).first!
    try test(confirmed.outcome == "complete" && confirmed.entries == 0 && confirmed.directories == 0 && before == after && (try confident.milestone().state) == "complete",
             "a legacy catalog with no outstanding first-listing work is confirmed complete with zero listings")
    try test((try confident.scalar("SELECT container FROM readings WHERE id=77")) == "keep", "milestone migration preserves monitoring history")

    // 21. Migration interruption and recovery.
    let interrupted = try completionFixture("legacy-interrupted")
    defer { removeFixture(interrupted) }
    _ = interrupted.run(InventoryRunOptions(maxDuration: 10, stopAfterEntries: 5))
    try simulateLegacyFormat(interrupted.db, withoutLifecycleTokens: false)
    let nodes = try interrupted.scalar("SELECT COUNT(*) FROM inventory_nodes"), jobs = try interrupted.scalar("SELECT GROUP_CONCAT(node_id||state||completed_token) FROM inventory_jobs")
    try interrupted.db.exec("BEGIN IMMEDIATE")
    try interrupted.db.exec("ALTER TABLE inventory_generations ADD COLUMN initial_completion TEXT NOT NULL DEFAULT 'unknown'")
    try interrupted.db.exec("ROLLBACK")
    try test((try interrupted.scalar("SELECT COUNT(*) FROM pragma_table_info('inventory_generations') WHERE name='initial_completion'")) == "0", "an interrupted milestone migration leaves no partial schema")
    try initializeInventorySchema(databasePath: interrupted.database)
    try initializeInventorySchema(databasePath: interrupted.database)
    try test((try interrupted.scalar("SELECT COUNT(*) FROM pragma_table_info('inventory_generations') WHERE name IN ('initial_completion','initial_completed_at')")) == "2"
             && (try interrupted.scalar("SELECT COUNT(*) FROM inventory_nodes")) == nodes && (try interrupted.scalar("SELECT GROUP_CONCAT(node_id||state||completed_token) FROM inventory_jobs")) == jobs
             && (try interrupted.milestone().state) == "unknown",
             "rerunning the migration recovers idempotently and preserves nodes and job state")
    let finished = interrupted.run()
    try test(finished.outcome == "complete" && (try interrupted.milestone().state) == "complete", "an interrupted legacy first pass is confirmed when its first listings drain")
    try test((try interrupted.scalar("PRAGMA integrity_check")) == "ok" && (try interrupted.db.rows("PRAGMA foreign_key_check")).isEmpty, "migrated fixture passes SQLite integrity and foreign-key checks")
}
#endif
