import Foundation
import Darwin
import SQLite3

#if INVENTORY_TESTS
// Living Tree against real catalogs: a synthetic folder tree under /private/tmp indexed by the real worker, read
// through InventoryReader.livingTree (one snapshot), with changes reaching the catalog the way file events do
// (invalidation, then a worker relist) and size signals read from the committed change journal.
func livingTreeCatalogTests(_ test: (Bool, String) throws -> Void) async throws {
    let root = "/private/tmp/storage-monitor-tree-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { _ = chmod(root + "/locked", 0o755); try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    for folder in ["media/video", "media/photos", "docs", "deep/a/b/c", "locked/inside", "apps/Tool.app/Contents"] { try fm.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true) }
    func write(_ path: String, _ bytes: Int) throws { try Data(count: bytes).write(to: URL(fileURLWithPath: root + "/" + path)) }
    try write("media/video/v1.bin", 3_000_000); try write("media/video/v2.bin", 2_000_000)
    for i in 0..<30 { try write("media/photos/p\(i).jpg", 64_000 + i * 1_000) }
    for i in 0..<120 { try write("docs/d\(i).txt", 1_000 + i * 20) }
    try write("deep/a/b/c/tiny.txt", 100)
    for i in 0..<30 { try write("deep/a/b/c/filler\(i)", 2_000) }
    try write("apps/Tool.app/Contents/binary", 900_000)
    try write("big.bin", 4_000_000)
    try write("locked/inside/x", 10)
    _ = chmod(root + "/locked", 0o000)
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    let region = coverageRegion(root: root)!
    func run() { _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted") }
    func touch(_ folders: [String]) throws {
        try invalidateInventory(databasePath: database, paths: folders.map { $0.isEmpty ? root : root + "/" + $0 }, eventID: nil, gap: false, reason: "Filesystem activity")
        run()
    }
    func rows(_ sql: String, _ values: [Any] = []) throws -> [[String: String]] { try Database(database).rows(sql, values) }
    func int(_ sql: String, _ values: [Any] = []) throws -> Int64 { Int64(try rows(sql, values).first?.values.first ?? "") ?? 0 }
    func id(_ relative: String) throws -> Int64 {
        var current = try int("SELECT id FROM inventory_nodes WHERE parent_id IS NULL")
        for part in relative.split(separator: "/") { current = try int("SELECT id FROM inventory_nodes WHERE parent_id=? AND name=?", [current, String(part)]) }
        return current
    }
    run()
    let reader = InventoryReader(path: database)
    let rootID = try id(""), videoID = try id("media/video"), mediaID = try id("media"), tinyID = try id("deep/a/b/c/tiny.txt"), lockedID = try id("locked")
    let budget = LivingTreeBudget(elements: 40, perFolder: 5, slack: 2, minimumShare: 0.02)
    let first = try await reader.changes(since: nil)
    let tree = try await reader.livingTree(rootID: rootID, budget: budget)

    // MARK: Snapshot, hierarchy and accounting against SQL
    try test(tree.count <= budget.elements && tree.reads > 0 && !tree.truncated && tree.snapshotSeconds < InventoryReader.livingTreeDeadline
             && tree.journalCursor == first.next,
             "living tree catalog: built from one read snapshot within its budget (\(tree.count) elements, \(tree.reads) folder reads, \(String(format: "%.1f", tree.snapshotSeconds * 1000)) ms), positioned in the change journal at that moment")
    var hierarchy = true
    for key in tree.order {
        guard let node = tree[key]?.node, key != tree.rootKey else { continue }
        let parent = try int("SELECT COALESCE(parent_id,0) FROM inventory_nodes WHERE id=?", [node.id])
        let name = try rows("SELECT name FROM inventory_nodes WHERE id=?", [node.id]).first?["name"]
        hierarchy = hierarchy && tree[key]?.parent == .node(parent) && name == node.name
    }
    try test(hierarchy, "living tree catalog: every drawn entry hangs from its catalog parent under its catalog name")
    let measured = "status IN ('complete','stale','pending','enumerating','partial') AND total_allocated IS NOT NULL"
    var exact = true, folders = 0
    for key in tree.order where tree[key]!.expanded {
        guard let folder = key.nodeID else { continue }
        folders += 1
        let sql = try rows("SELECT COALESCE(SUM(CASE WHEN \(measured) THEN total_allocated END),0) AS bytes, COUNT(*) AS items, COALESCE(SUM(CASE WHEN \(measured) THEN 0 ELSE 1 END),0) AS unmeasured FROM inventory_nodes WHERE parent_id=?", [folder]).first!
        let children = tree[key]!.children.map { tree[$0]! }
        let rest = tree[.rest(folder)]
        let bytes = children.filter { $0.role != .rest }.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) } + (rest?.bytes ?? 0)
        let items = Int64(children.filter { $0.role != .rest }.count) + (rest?.count ?? 0)
        let unmeasured = Int64(children.filter { $0.role == .unmeasured }.count) + (rest?.unmeasured ?? 0)
        exact = exact && String(bytes) == sql["bytes"] && String(items) == sql["items"] && String(unmeasured) == sql["unmeasured"]
    }
    try test(exact && folders >= 2, "living tree catalog: each expanded folder's drawn entries and grouped remainder match the catalog's sums exactly (\(folders) folders)")
    try test(tree[.node(lockedID)].map { $0.role == .unmeasured && $0.bytes == nil } ?? ((tree[.rest(rootID)]?.unmeasured ?? 0) >= 1),
             "living tree catalog: an unreadable folder is shown or counted as having no measured size, never as zero")
    try test(tree[.node(tinyID)] == nil, "living tree catalog: a 100-byte file is grouped, not drawn, in a bounded tree")
    let revealed = try await reader.livingTree(rootID: rootID, budget: budget, reveal: tinyID)
    let cID = try id("deep/a/b/c")
    let cSum = try int("SELECT SUM(total_allocated) FROM inventory_nodes WHERE parent_id=?", [cID])
    let cDrawn = (revealed[.node(cID)]?.children ?? []).reduce(Int64(0)) { $0 + (revealed[$1]?.bytes ?? 0) }
    try test(revealed[.node(tinyID)]?.parent == .node(cID) && revealed.ancestry(of: .node(tinyID)).compactMap(\.nodeID) == [rootID, try id("deep"), try id("deep/a"), try id("deep/a/b"), cID, tinyID] && cDrawn == cSum,
             "living tree catalog: revealing the 100-byte file draws it with its folders, from the same snapshot, and its folder's total stays exact")
    var missing = false
    do { _ = try await reader.livingTree(rootID: 9_999_999, budget: budget) } catch { missing = true }
    try test(missing, "living tree catalog: a folder no longer in the catalog is reported, not drawn empty")

    // MARK: Committed changes and size signals
    var light = LivingTreeIllumination()
    try test(light.receive(try await reader.sizeSignals(since: nil), now: Date()) == .resynchronized && light.glows.isEmpty,
             "living tree catalog: the first signal read only positions the viewer; nothing lights up")
    try write("media/video/v3.bin", 1_500_000)
    try touch(["media/video"])
    let grown = try await reader.changes(since: tree.journalCursor)
    let growth = light.receive(try await reader.sizeSignals(since: light.cursor), now: Date())
    let rootStatus = try rows("SELECT status FROM inventory_nodes WHERE id=?", [rootID]).first?["status"]
    try test(LivingTreeRefresh.needsRebuild(grown, model: tree, ancestors: []) && growth != .unchanged
             && light.glows[videoID]?.trend == .growth && light.glows[videoID]?.confidence == .complete && light.glows[mediaID]?.trend == .growth
             && (light.glows[rootID] == nil || light.glows[rootID]?.confidence == (rootStatus == "complete" ? .complete : .observedLowerBound)),
             "living tree catalog: a file written into a drawn folder rebuilds the tree and lights the folder and its ancestors amber (root: \(rootStatus ?? "?"), compared as \(light.glows[rootID]?.confidence.rawValue ?? "unlit"))")
    try test((light.glows[videoID]?.deltaBytes ?? 0) > 0 && (light.glows[videoID]?.previousBytes ?? 0) > 0,
             "living tree catalog: the light carries the measured previous size and the signed change")
    try fm.removeItem(atPath: root + "/media/video/v1.bin")
    try touch(["media/video"])
    light.receive(try await reader.sizeSignals(since: light.cursor), now: Date())
    try test(light.glows[videoID]?.trend == .reduction && (light.glows[videoID]?.deltaBytes ?? 0) < 0,
             "living tree catalog: deleting a file lights the folder cool blue (a change in indexed allocation)")
    let afterGrowth = try await reader.livingTree(rootID: rootID, budget: budget)
    let quiet = afterGrowth.journalCursor!
    try touch(["deep/a/b/c"])   // relisted without any change
    let noop = try await reader.changes(since: quiet)
    try test(!LivingTreeRefresh.needsRebuild(noop, model: afterGrowth, ancestors: []) && noop.changes.allSatisfy { !afterGrowth.expandedFolders.contains($0.directoryID) },
             "living tree catalog: relisting an unchanged folder outside the drawn branches does not rebuild the tree (\(noop.changes.count) journal rows)")

    // MARK: Resynchronization
    let stale = light.cursor!
    for i in 0..<4 { try write("docs/extra\(i).txt", 5_000); try touch(["docs"]) }
    // Keep one directory row and one comparison: the viewer's cursor is now older than both retention floors.
    _ = try inventoryPruneChangeJournalForTesting(databasePath: database, retention: InventoryChangeJournalRetention(directories: 1, signals: 1, batch: 1))
    let before = light.glows
    let pruned = light.receive(try await reader.sizeSignals(since: stale), now: Date())
    let feed = try await reader.changes(since: stale)
    try test(pruned == .resynchronized && light.glows == before && feed.mustResynchronize && LivingTreeRefresh.needsRebuild(feed, model: afterGrowth, ancestors: []),
             "living tree catalog: after the journal is pruned past the viewer, it resynchronizes: the tree is rebuilt and no growth or reduction is invented")

    // MARK: Generation-wide staleness belongs to the drawn snapshot
    try invalidateInventory(databasePath: database, paths: [root + "/docs"], eventID: nil, gap: false, reason: "Filesystem activity")
    let pending = try await reader.livingTree(rootID: rootID, budget: budget)
    run()
    let settled = try await reader.changes(since: pending.journalCursor)
    try test(pending.generationStale == true && !settled.generationStale && LivingTreeRefresh.needsRebuild(settled, model: pending, ancestors: []),
             "living tree catalog: a tree drawn while file events were pending records that in its snapshot, and is rebuilt once they are applied")
}
#endif
