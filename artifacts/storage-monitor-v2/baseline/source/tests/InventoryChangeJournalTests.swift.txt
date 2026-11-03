import Foundation
import Darwin
import SQLite3

#if INVENTORY_TESTS
// Change journal (incremental viewer foundation). Real filesystem fixtures under /private/tmp and real worker
// runs; changes reach the catalog the way file events do (invalidation, then a worker relist). SQL is used only
// to read results, to prove rollback atomicity, and to build a pre-journal copy for the migration test.
func inventoryChangeJournalTests(_ test: (Bool, String) throws -> Void) async throws {
    let root = "/private/tmp/storage-monitor-journal-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { _ = chmod(root + "/locked", 0o755); try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    for folder in ["a/deep/er/est", "b", "c", "moveme/sub", "locked/inside", "h1", "h2"] { try fm.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true) }
    try Data(count: 8_192).write(to: URL(fileURLWithPath: root + "/a/deep/er/est/grow.bin"))
    try Data(count: 4_096).write(to: URL(fileURLWithPath: root + "/a/top.bin"))
    for index in 0..<20 { try Data(count: 4_096 * (1 + index)).write(to: URL(fileURLWithPath: root + "/c/f\(index)")) }
    try Data(count: 40_000).write(to: URL(fileURLWithPath: root + "/moveme/sub/payload"))
    try Data(count: 10).write(to: URL(fileURLWithPath: root + "/locked/inside/x"))
    try Data(count: 16_384).write(to: URL(fileURLWithPath: root + "/h1/shared.bin"))
    try required(link(root + "/h1/shared.bin", root + "/h2/alias.bin") == 0, "create hard link")
    _ = chmod(root + "/locked", 0o000)
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    let region = coverageRegion(root: root)!
    func run() { _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted") }
    func touch(_ folders: [String], run worker: Bool = true) throws {
        try invalidateInventory(databasePath: database, paths: folders.map { $0.isEmpty ? root : root + "/" + $0 }, eventID: nil, gap: false, reason: "Filesystem activity")
        if worker { run() }
    }
    func rows(_ sql: String, _ values: [Any] = []) throws -> [[String: String]] { try Database(database).rows(sql, values) }
    func int(_ sql: String, _ values: [Any] = []) throws -> Int64 { Int64(try rows(sql, values).first?.values.first ?? "") ?? 0 }
    func id(_ relative: String) throws -> Int64 {
        var current = try int("SELECT id FROM inventory_nodes WHERE parent_id IS NULL")
        for part in relative.split(separator: "/") { current = try int("SELECT id FROM inventory_nodes WHERE parent_id=? AND name=?", [current, String(part)]) }
        return current
    }
    func allocated(_ node: Int64) throws -> Int64 { try int("SELECT total_allocated FROM inventory_nodes WHERE id=?", [node]) }
    let reader = InventoryReader(path: database)
    func changed(since cursor: InventoryChangeCursor) async throws -> (batch: InventoryChangeBatch, ids: Set<Int64>, subtrees: Set<Int64>) {
        let batch = try await reader.changes(since: cursor)
        return (batch, Set(batch.changes.map(\.directoryID)), Set(batch.changes.filter(\.subtree).map(\.directoryID)))
    }
    func unique(_ batch: InventoryChangeBatch) -> Bool { Set(batch.changes.map(\.directoryID)).count == batch.changes.count }

    run()
    // MARK: Installation and first read
    let initial = try rows("SELECT initial_completion FROM inventory_generations WHERE active=1").first?["initial_completion"]
    let first = try await reader.changes(since: nil)
    try test(initial == "complete" && first.available && first.mustResynchronize && first.changes.isEmpty && first.next?.sequence == first.latestSequence && first.latestSequence > 0,
             "a reader without a cursor is told to resynchronize and receives the latest committed sequence (\(first.latestSequence))")
    try test(try int("SELECT COUNT(*) FROM inventory_size_signals WHERE previous_allocated IS NOT NULL") == 0,
             "the first pass emits no growth or reduction signals: nothing had a previous measurement")
    let start = first.next!
    let rootID = try id(""), aID = try id("a"), deepID = try id("a/deep"), estID = try id("a/deep/er/est"), erID = try id("a/deep/er")
    let bID = try id("b"), cID = try id("c"), movemeID = try id("moveme"), subID = try id("moveme/sub"), lockedID = try id("locked")

    // MARK: Raw events are not measurements
    try touch(["c"], run: false)
    let pendingOnly = try await changed(since: start)
    try test(pendingOnly.batch.changes.isEmpty && pendingOnly.batch.generationStale && pendingOnly.batch.latestSequence == start.sequence,
             "a recorded file event alone changes nothing in the feed; the generation is only qualified as stale until the worker commits")
    run()
    let afterNoop = try await changed(since: start)
    try test(afterNoop.batch.complete && !afterNoop.batch.generationStale && afterNoop.ids.isSubset(of: [cID, rootID]),
             "relisting an unchanged folder records only its own stale-to-current transition (\(afterNoop.ids.sorted()))")
    try test(try int("SELECT COUNT(*) FROM inventory_size_signals WHERE node_id=? AND previous_allocated IS NOT NULL AND previous_allocated=allocated", [cID]) == 1,
             "an unchanged remeasurement is recorded as unchanged, never as growth or reduction")
    var cursor = afterNoop.batch.next!

    // MARK: File creation and ancestor propagation
    let deepBefore = try allocated(deepID), rootBefore = try allocated(rootID)
    try Data(count: 65_536).write(to: URL(fileURLWithPath: root + "/a/deep/new.bin"))
    try touch(["a/deep"])
    let created = try await changed(since: cursor)
    let newFile = try int("SELECT total_allocated FROM inventory_nodes WHERE parent_id=? AND name='new.bin'", [deepID])
    try test(created.batch.complete && unique(created.batch) && created.ids.isSuperset(of: [deepID, aID, rootID]) && created.ids.isDisjoint(with: [bID, cID, movemeID, subID, estID, lockedID]),
             "file creation reports its folder and every ancestor, and no unrelated branch (\(created.ids.sorted()))")
    let signals = try await reader.sizeSignals(nodeIDs: [deepID, aID, rootID])
    try test(newFile > 0 && signals[deepID]?.deltaBytes == newFile && signals[deepID]?.trend == .growth && signals[deepID]?.confidence == .complete
             && signals[deepID]?.previousAllocatedBytes == deepBefore && signals[aID]?.deltaBytes == newFile && signals[rootID]?.deltaBytes == newFile
             && signals[rootID]?.previousAllocatedBytes == rootBefore && signals[rootID]?.confidence == .observedLowerBound,
             "creation is measured growth equal to the new file's allocation along the whole ancestor chain; the root, with a protected folder, is an observed lower bound")
    cursor = created.batch.next!

    // MARK: File growth and shrinkage
    let growID = try int("SELECT id FROM inventory_nodes WHERE parent_id=? AND name='grow.bin'", [estID])
    let growBefore = try allocated(growID)
    try Data(count: 1_048_576).write(to: URL(fileURLWithPath: root + "/a/deep/er/est/grow.bin"))
    try touch(["a/deep/er/est"])
    let grown = try await changed(since: cursor)
    let growAfter = try allocated(growID)
    let growSignal = try await reader.sizeSignals(nodeIDs: [growID, estID, erID])
    try test(grown.ids.isSuperset(of: [estID, erID, deepID, aID, rootID]) && growID == (try int("SELECT id FROM inventory_nodes WHERE parent_id=? AND name='grow.bin'", [estID]))
             && growSignal[growID]?.deltaBytes == growAfter - growBefore && growSignal[growID]?.trend == .growth && growSignal[erID]?.deltaBytes == growAfter - growBefore,
             "file growth is a signed allocation delta on the file and each ancestor (+\(growAfter - growBefore) bytes)")
    cursor = grown.batch.next!
    let shrinkSignalsCursor = cursor
    try Data().write(to: URL(fileURLWithPath: root + "/a/deep/er/est/grow.bin"))
    try touch(["a/deep/er/est"])
    let shrunk = try await changed(since: cursor)
    let shrinkSignal = try await reader.sizeSignals(nodeIDs: [growID, estID])
    try test(shrunk.ids.contains(estID) && shrinkSignal[growID]?.trend == .reduction && shrinkSignal[growID]?.deltaBytes == -growAfter && shrinkSignal[growID]?.previousAllocatedBytes == growAfter,
             "file shrinkage is a reduction from the previous measured allocation")
    let signalFeed = try await reader.sizeSignals(since: shrinkSignalsCursor)
    try test(signalFeed.complete && !signalFeed.mustResynchronize && signalFeed.signals.contains { $0.nodeID == growID && $0.trend == .reduction }
             && Set(signalFeed.signals.map(\.nodeID)).count == signalFeed.signals.count,
             "the signal feed returns each changed node once, in sequence order")
    cursor = shrunk.batch.next!

    // MARK: File deletion
    let doomed = try int("SELECT id FROM inventory_nodes WHERE parent_id=? AND name='f3'", [cID])
    try fm.removeItem(atPath: root + "/c/f3")
    try touch(["c"])
    let deleted = try await changed(since: cursor)
    let deletedSignal = try await reader.sizeSignals(nodeIDs: [doomed, cID])
    try test(deleted.ids.contains(cID) && deleted.ids.contains(rootID) && (try int("SELECT COUNT(*) FROM inventory_nodes WHERE id=?", [doomed])) == 0
             && deletedSignal[doomed] == nil && deletedSignal[cID]?.trend == .reduction,
             "a deleted file stays observable through its folder after its row disappears; its own signal is removed and the folder records a reduction")
    cursor = deleted.batch.next!

    // MARK: Directory rename
    try fm.moveItem(atPath: root + "/moveme", toPath: root + "/renamed")
    try touch([""])
    let renamed = try await changed(since: cursor)
    try test((try id("renamed")) == movemeID && renamed.ids.contains(rootID) && renamed.subtrees.contains(movemeID) && renamed.ids.isDisjoint(with: [aID, bID, cID]),
             "a renamed directory keeps its identity; its parent's listing and its own subtree (paths) are reported")
    cursor = renamed.batch.next!

    // MARK: Cross-directory move
    let bBefore = try allocated(bID)
    try fm.moveItem(atPath: root + "/renamed/sub", toPath: root + "/b/sub")
    try touch(["renamed", "b"])
    let moved = try await changed(since: cursor)
    let moveSignals = try await reader.sizeSignals(nodeIDs: [bID, movemeID])
    try test((try id("b/sub")) == subID && moved.ids.isSuperset(of: [movemeID, bID]) && moved.subtrees.contains(subID) && moved.ids.isDisjoint(with: [aID, cID])
             && moveSignals[bID]?.trend == .growth && moveSignals[bID]?.previousAllocatedBytes == bBefore && moveSignals[movemeID]?.trend == .reduction,
             "a cross-directory move invalidates the old and the new parent, keeps the moved identity, and is growth at the destination and reduction at the source")
    cursor = moved.batch.next!

    // MARK: Several changes in one transaction
    try Data(count: 12_288).write(to: URL(fileURLWithPath: root + "/b/one.bin"))
    try Data(count: 12_288).write(to: URL(fileURLWithPath: root + "/c/two.bin"))
    try touch(["b", "c"])
    let together = try await changed(since: cursor)
    try test(together.batch.complete && unique(together.batch) && together.ids.isSuperset(of: [bID, cID, rootID]) && together.ids.isDisjoint(with: [aID, deepID]),
             "changes committed together are all reported once each (\(together.batch.changes.count) directories)")
    cursor = together.batch.next!

    // MARK: Directory deletion
    let payload = try int("SELECT id FROM inventory_nodes WHERE parent_id=? AND name='payload'", [subID])
    try fm.removeItem(atPath: root + "/b/sub")
    try touch(["b"])
    let removed = try await changed(since: cursor)
    let gone = try await reader.node(id: subID)
    try test(gone == nil && removed.ids.isSuperset(of: [bID, subID]) && (try int("SELECT COUNT(*) FROM inventory_nodes WHERE id IN (?,?)", [subID, payload])) == 0,
             "a deleted directory is reported itself and through its parent after its whole subtree is removed")
    cursor = removed.batch.next!

    // MARK: Protected and unmeasured directories
    try touch(["locked"])
    let protected = try await reader.sizeSignals(nodeIDs: [lockedID])
    try test(protected.isEmpty && (try rows("SELECT status FROM inventory_nodes WHERE id=?", [lockedID])).first?["status"] == "unknown"
             && (try int("SELECT COUNT(*) FROM inventory_size_signals WHERE node_id=?", [lockedID])) == 0,
             "a protected folder never receives a size signal: it has no measured value to compare")
    cursor = try await reader.changes(since: cursor).next!

    // MARK: Hard links: no false signals, alias folders follow the shared object
    let h1ID = try id("h1"), h2ID = try id("h2")
    let linkNodes = try rows("SELECT n.id FROM inventory_nodes n WHERE n.parent_id IN (?,?)", [h1ID, h2ID]).compactMap { Int64($0["id"] ?? "") }
    try touch(["h1", "h2"])
    let linkSignals = try await reader.sizeSignals(nodeIDs: linkNodes + [h1ID, h2ID])
    try test(linkNodes.count == 2 && linkSignals.values.allSatisfy { $0.trend == .unchanged },
             "re-listing unchanged hard links records no growth or reduction for either name or folder")
    cursor = try await reader.changes(since: cursor).next!
    let appender = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/h1/shared.bin"))
    try appender.seekToEnd(); try appender.write(contentsOf: Data(count: 65_536)); try appender.close()
    try touch(["h1"])
    let linked = try await changed(since: cursor)
    try test(linked.ids.isSuperset(of: [h1ID, h2ID]),
             "a shared object's change is reported for the folder of every name that shows it, including a hard-link alias")
    cursor = linked.batch.next!

    // MARK: Starting a remeasurement does not republish an earlier comparison
    let comparedCursor = try await reader.changes(since: nil).next!
    try touch(["c"], run: false)
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10, stopAfterEntries: 0), fdaOverride: "granted")
    let midRemeasure = try await reader.sizeSignals(since: comparedCursor)
    let baselinePending = try int("SELECT COUNT(*) FROM inventory_size_signals WHERE node_id=? AND baseline_allocated IS NOT NULL", [cID])
    try test(baselinePending == 1 && !midRemeasure.signals.contains { $0.nodeID == cID },
             "a folder whose remeasurement has started keeps its baseline without re-publishing its last comparison")
    run()
    cursor = try await reader.changes(since: cursor).next!

    // MARK: Atomicity
    var db: OpaquePointer?
    try required(sqlite3_open(database, &db) == SQLITE_OK, "open journal fixture")
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5_000)
    let sequenceBefore = try int("SELECT sequence FROM inventory_change_clock")
    sqlite3_exec(db, "BEGIN IMMEDIATE; UPDATE inventory_nodes SET total_allocated=total_allocated+1 WHERE id=\(cID);", nil, nil, nil)
    var inside: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT sequence FROM inventory_change_clock", -1, &inside, nil)
    sqlite3_step(inside); let sequenceInside = sqlite3_column_int64(inside, 0); sqlite3_finalize(inside)
    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    let rolledBack = try await changed(since: cursor)
    try test(sequenceInside > sequenceBefore && (try int("SELECT sequence FROM inventory_change_clock")) == sequenceBefore && rolledBack.batch.changes.isEmpty,
             "journal rows are written in the catalog's own transaction and disappear with its rollback")

    // MARK: Reconnect after missed updates, bounded pages
    let full = try await reader.changes(since: start, limit: InventoryReader.maximumChangeRead)
    var paged = [InventoryDirectoryChange](), pageCursor = start, pages = 0
    while true {
        let page = try await reader.changes(since: pageCursor, limit: 8)
        paged += page.changes; pages += 1
        pageCursor = page.next!
        if page.complete || pages > 100 { break }
    }
    try test(full.complete && pages > 1 && paged.count == Set(paged.map(\.directoryID)).count && Set(paged.map(\.directoryID)) == Set(full.changes.map(\.directoryID)) && pageCursor.sequence == full.latestSequence,
             "a viewer reconnecting after missed updates catches up in bounded pages with no change lost or repeated (\(pages) pages, \(paged.count) directories)")

    // MARK: Concurrent reader and writer
    final class Flag: @unchecked Sendable { private let lock = NSLock(); private var value = false
        var done: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func finish() { lock.lock(); value = true; lock.unlock() } }
    let finished = Flag(), concurrentStart = try await reader.changes(since: nil).next!
    let writer = Thread {
        for round in 0..<12 {
            try? Data(count: 4_096 * (round + 1)).write(to: URL(fileURLWithPath: root + "/\(round % 2 == 0 ? "b" : "c")/w\(round).bin"))
            try? invalidateInventory(databasePath: database, paths: [root + (round % 2 == 0 ? "/b" : "/c")], eventID: nil, gap: false, reason: "Filesystem activity")
            _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
            usleep(20_000) // leave the reader room to interleave with the commits
        }
        finished.finish()
    }
    writer.start()
    var observed = Set<Int64>(), live = concurrentStart, reads = 0, busy = 0, duplicates = 0, regressions = 0
    while true {
        let done = finished.done
        do {
            let batch = try await reader.changes(since: live)
            reads += 1
            if !unique(batch) { duplicates += 1 }
            if batch.next!.sequence < live.sequence { regressions += 1 }
            observed.formUnion(batch.changes.map(\.directoryID)); live = batch.next!
        } catch { busy += 1 }
        if done { break }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    let oracle = Set(try rows("SELECT directory_id FROM inventory_changed_directories WHERE sequence>?", [concurrentStart.sequence]).compactMap { Int64($0["directory_id"] ?? "") })
    try test(reads > 3 && duplicates == 0 && regressions == 0 && oracle.isSubset(of: observed) && observed.isSuperset(of: [bID, cID]),
             "a reader polling during twelve worker runs never misses or repeats a change and its cursor never moves back (\(reads) reads, \(busy) busy, \(observed.count) directories)")

    // MARK: Explorer: visible branches only, selection, deletion
    run() // settle any listing the concurrent writer left pending
    var explorer = InventoryExplorerState()
    explorer.setRoot(try await reader.root()!)
    explorer.receive(parent: rootID, page: try await reader.explorerChildren(parentID: rootID))
    for folder in [aID, bID, cID] { explorer.expand(folder); explorer.receive(parent: folder, page: try await reader.explorerChildren(parentID: folder)) }
    explorer.expand(deepID); explorer.receive(parent: deepID, page: try await reader.explorerChildren(parentID: deepID))
    let selectedFile = try int("SELECT id FROM inventory_nodes WHERE parent_id=? AND name='f5'", [cID])
    explorer.selection = selectedFile
    var tracker = InventoryChangeTracker()
    tracker = tracker.planned(try await reader.changes(since: tracker.cursor)).tracker
    func refresh() async throws -> (plan: InventoryChangeTracker.Plan, targets: [Int64], result: InventoryVisibleRefreshResult) {
        let (plan, next) = tracker.planned(try await reader.changes(since: tracker.cursor))
        var targets = [(parent: Int64, count: Int)]()
        switch plan {
        case .none: break
        case .everything: explorer.invalidateCollapsed(); targets = explorer.reloadPlan
        case .folders(let listing, let subtrees): explorer.invalidateCollapsed(listing: listing, subtrees: subtrees); targets = explorer.refreshTargets(listing: listing, subtrees: subtrees)
        }
        let selection = explorer.selection
        let result = await InventoryVisibleRefresh.perform(reader: reader, targets: targets, selection: selection, selectionParent: selection.flatMap { explorer.node($0)?.parentID }, previous: explorer.shownEntries(targets.map(\.parent)))
        let superseded = explorer.apply(result)
        tracker = next; tracker.noteFailed(result.failed + superseded, loaded: explorer.loadedFolders)
        return (plan, targets.map(\.parent), result)
    }
    try Data(count: 20_480).write(to: URL(fileURLWithPath: root + "/b/visible.bin"))
    let visibleCursor = tracker.cursor!
    try touch(["b"])
    let visibleFeed = Set(try await reader.changes(since: visibleCursor).changes.map(\.directoryID))
    let visible = try await refresh()
    let bNames = explorer.children[bID]?.items.map(\.name) ?? []
    try test(Set(visible.targets).isSuperset(of: [bID, rootID]) && Set(visible.targets).isSubset(of: visibleFeed) && Set(visible.targets).isDisjoint(with: [aID, deepID]) && bNames.contains("visible.bin") && explorer.selection == selectedFile
             && explorer.isExpanded(aID) && explorer.isExpanded(cID) && explorer.isExpanded(deepID),
             "a change in one expanded branch re-reads only that folder and the root; other expanded branches, expansion and the selection are untouched (\(visible.targets.sorted()))")
    let quiet = try await refresh()
    try test(quiet.plan == .none && quiet.targets.isEmpty, "with no committed change, no folder is re-read")

    try fm.removeItem(atPath: root + "/c/f5")
    try touch(["c"])
    let selectionGone = try await refresh()
    try test(selectionGone.targets.contains(cID) && selectionGone.result.selectionDeleted == selectedFile && explorer.selection == cID && explorer.node(selectedFile) == nil
             && !(explorer.children[cID]?.items.contains { $0.id == selectedFile } ?? true),
             "a deleted selection moves to its folder instead of lingering or vanishing")

    explorer.selection = try int("SELECT id FROM inventory_nodes WHERE parent_id=? AND name='new.bin'", [deepID])
    try fm.removeItem(atPath: root + "/a/deep")
    try touch(["a"])
    let folderGone = try await refresh()
    try test(folderGone.result.deleted.contains(deepID) && !explorer.loadedFolders.contains(deepID) && !explorer.isExpanded(deepID) && explorer.selection == aID
             && !(explorer.children[aID]?.items.contains { $0.id == deepID } ?? true),
             "a deleted expanded folder leaves the outline with everything beneath it; a selection inside it moves to the nearest remaining folder")

    explorer.collapse(cID)
    try Data(count: 4_096).write(to: URL(fileURLWithPath: root + "/b/again.bin"))
    try touch(["b"])
    _ = try await refresh()
    let keptCollapsed = explorer.children[cID] != nil
    try Data(count: 4_096).write(to: URL(fileURLWithPath: root + "/c/again.bin"))
    try touch(["c"])
    _ = try await refresh()
    try test(keptCollapsed && explorer.children[cID] == nil,
             "a collapsed folder keeps its pages until its own branch changes, then reloads when reopened")

    // MARK: Retention overflow
    let latest = try await reader.changes(since: nil).next!
    let pruned = try inventoryPruneChangeJournalForTesting(databasePath: database, retention: InventoryChangeJournalRetention(directories: 3, signals: 3, batch: 2))
    let behind = try await reader.changes(since: start), current = try await reader.changes(since: latest)
    let signalsBehind = try await reader.sizeSignals(since: start)
    let retained = try int("SELECT COUNT(*) FROM inventory_changed_directories")
    let (overflowPlan, _) = InventoryChangeTracker().planned(behind)
    try test(pruned > 0 && retained <= 6 && behind.mustResynchronize && behind.changes.isEmpty && !current.mustResynchronize && signalsBehind.mustResynchronize
             && { if case .everything = overflowPlan { return true } else { return false } }(),
             "after retention overflow a reader behind the floor is told to resynchronize its visible branches; a current reader continues (\(pruned) rows pruned, \(retained) kept)")

    // MARK: Migration of a catalog that predates the journal
    let legacy = state.appendingPathComponent("legacy.sqlite3").path
    try fm.copyItem(atPath: database, toPath: legacy)
    var legacyDB: OpaquePointer?
    try required(sqlite3_open(legacy, &legacyDB) == SQLITE_OK, "open legacy copy")
    let drop = inventoryChangeJournalTriggers.map { "DROP TRIGGER \($0.0);" }.joined() + "DROP TABLE inventory_change_clock; DROP TABLE inventory_changed_directories; DROP TABLE inventory_size_signals; VACUUM;"
    try required(sqlite3_exec(legacyDB, drop, nil, nil, nil) == SQLITE_OK, "remove the journal from the legacy copy")
    sqlite3_close(legacyDB)
    let legacyReader = InventoryReader(path: legacy)
    let unavailable = try await legacyReader.changes(since: latest)
    let (legacyPlan, legacyTracker) = InventoryChangeTracker().planned(unavailable)
    let legacyRows = try Database(legacy).rows("SELECT COUNT(*) AS n,SUM(COALESCE(total_allocated,0)) AS bytes,SUM(seen_token) AS tokens FROM inventory_nodes").first
    let legacyPages = Int64(try Database(legacy).rows("PRAGMA page_count").first?.values.first ?? "") ?? 0
    try initializeInventorySchema(databasePath: legacy)
    let migratedRows = try Database(legacy).rows("SELECT COUNT(*) AS n,SUM(COALESCE(total_allocated,0)) AS bytes,SUM(seen_token) AS tokens FROM inventory_nodes").first
    let migratedPages = Int64(try Database(legacy).rows("PRAGMA page_count").first?.values.first ?? "") ?? 0
    let migratedFirst = try await legacyReader.changes(since: nil)
    try test(!unavailable.available && legacyPlan == .everything("change journal unavailable") && legacyTracker.cursor == nil,
             "a catalog without the journal is reported as such, and a viewer falls back to re-reading what it shows")
    try test(legacyRows?["n"] == migratedRows?["n"] && legacyRows?["bytes"] == migratedRows?["bytes"] && legacyRows?["tokens"] == migratedRows?["tokens"]
             && migratedPages - legacyPages <= 12 && migratedFirst.available && migratedFirst.mustResynchronize && migratedFirst.latestSequence == 0
             && migratedFirst.journalID != latest.journalID,
             "migration adds the journal without rewriting catalog rows (\(migratedPages - legacyPages) new pages) and starts a new journal readers resynchronize with")
    let again = try await legacyReader.changes(since: latest)
    try test(again.mustResynchronize, "a cursor from another journal is never continued")
}

// Pure change-tracker rules (no database).
func inventoryChangeTrackerTests(_ test: (Bool, String) throws -> Void) throws {
    func batch(_ sequence: Int64, changes: [InventoryDirectoryChange] = [], complete: Bool = true, resync: Bool = false, stale: Bool = false) -> InventoryChangeBatch {
        InventoryChangeBatch(available: true, journalID: "j", latestSequence: sequence, generation: 1, generationStale: stale, changes: changes,
                             next: InventoryChangeCursor(journalID: "j", sequence: complete ? sequence : (changes.last?.sequence ?? 0)), complete: complete, mustResynchronize: resync)
    }
    var tracker = InventoryChangeTracker()
    let (firstPlan, primed) = tracker.planned(batch(10, resync: true))
    tracker = primed
    try test(firstPlan == .everything("first read") && tracker.cursor?.sequence == 10, "the first read resynchronizes and keeps the latest sequence")
    let change = InventoryDirectoryChange(directoryID: 7, sequence: 11, subtree: false), sub = InventoryDirectoryChange(directoryID: 9, sequence: 12, subtree: true)
    let (incremental, advanced) = tracker.planned(batch(12, changes: [change, sub]))
    try test(incremental == .folders(listing: [7], subtrees: [9]) && advanced.cursor?.sequence == 12, "listing and subtree changes are planned separately")
    let (backlog, caughtUp) = advanced.planned(batch(40, changes: [InventoryDirectoryChange(directoryID: 1, sequence: 13, subtree: false)], complete: false))
    try test({ if case .everything = backlog { return true } else { return false } }() && caughtUp.cursor?.sequence == 40, "a backlog beyond one read resynchronizes and continues from the latest sequence")
    let (flip, _) = caughtUp.planned(batch(40, stale: true))
    try test({ if case .everything = flip { return true } else { return false } }(), "a generation-wide staleness change re-reads everything visible")
    var failing = caughtUp
    failing.noteFailed([3, 4, 99], loaded: [3, 4])
    let (retryPlan, retried) = failing.planned(nil)
    try test(retryPlan == .folders(listing: [3, 4], subtrees: []) && retried.cursor == caughtUp.cursor && retried.retry.isEmpty,
             "folders whose read failed are retried, only while still loaded, without moving the cursor when the feed is unreadable")
    var bounded = InventoryChangeTracker()
    bounded.noteFailed(Array(0..<2_000), loaded: Set(0..<2_000))
    try test(bounded.retry.count == InventoryChangeTracker.retryLimit, "the retry set is bounded")
    let rows = [1, 2, 3, 3, 3, 4].map { Int64($0) }
    let cut = InventoryReader.truncated(rows, limit: 4, sequence: \.self)
    try test(cut.kept == [1, 2] && !cut.complete, "a bounded read never splits one sequence across two reads")
    func node(_ id: Int64, parent: Int64?, kind: InventoryNodeKind = .file) -> InventoryNode {
        InventoryNode(id: id, parentID: parent, identity: InventoryIdentity(device: 1, inode: UInt64(id), birthNanoseconds: 0), path: "/x/\(id)", name: "n\(id)", kind: kind,
                      logicalBytes: 1, allocatedBytes: 1, previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil,
                      directLogicalBytes: 0, directAllocatedBytes: 0, childCount: 0, descendantFiles: 0, descendantDirectories: 0, status: .complete, coverageState: "complete",
                      listingState: nil, statusReason: nil, measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
    }
    var explorer = InventoryExplorerState()
    explorer.setRoot(node(1, parent: nil, kind: .directory))
    explorer.receive(parent: 1, page: InventoryChildPage(items: [node(2, parent: 1, kind: .directory), node(3, parent: 1, kind: .directory)], next: nil))
    explorer.expand(2); explorer.receive(parent: 2, page: InventoryChildPage(items: [node(20, parent: 2), node(21, parent: 2)], next: nil))
    var stale = InventoryVisibleRefreshResult()
    stale.folders = [.init(parent: 2, loaded: 1, page: InventoryChildPage(items: [node(20, parent: 2)], next: nil), node: nil)]
    let superseded = explorer.apply(stale)
    try test(superseded == [2] && explorer.children[2]?.items.count == 2, "a refresh does not overwrite a folder whose loaded span changed while it was read; the folder is refreshed again")
    explorer.expand(3); explorer.receive(parent: 3, page: InventoryChildPage(items: (30..<130).map { node(Int64($0), parent: 3) }, next: nil))
    explorer.collapse(3)
    let before = explorer.cachedNodeCount
    explorer.invalidateCollapsed(listing: [3], subtrees: [])
    try test(explorer.children[3] == nil && explorer.cachedNodeCount == before - 100, "dropping a collapsed folder's pages releases their cached rows")
    let signal = InventorySizeSignal(nodeID: 1, generation: 1, sequence: 1, previousAllocatedBytes: 10, allocatedBytes: 4, previousMeasuredAt: nil, measuredAt: nil, previousStatus: "complete", status: "partial")
    try test(signal.deltaBytes == -6 && signal.trend == .reduction && signal.confidence == .observedLowerBound, "a signal is signed and qualified by its least certain measurement")
}
#endif
