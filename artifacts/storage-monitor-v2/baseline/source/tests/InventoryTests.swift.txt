import Foundation
import Darwin
import SQLite3

// Synthetic inventory tests. The fixture and database live under /private/tmp; no production
// database, launch agent, or user content is read or changed.
func inventorySelfTest(_ test: (Bool, String) throws -> Void) throws {
    let aliasLinks: [Firmlink] = [("/private", "private")]
    try test(dataRelative("/tmp/absent/leaf", links: aliasLinks) == dataRelative("/private/tmp/absent/leaf", links: aliasLinks)
             && dataRelative("/var/absent/leaf", links: aliasLinks) == dataRelative("/private/var/absent/leaf", links: aliasLinks)
             && dataRelative("/tmp-neighbor/absent", links: aliasLinks) == nil && dataRelative("/variety/absent", links: aliasLinks) == nil,
             "inventory invalidation keys normalize missing /tmp and /var entries without matching same-prefix siblings")
    try test(dataRelative("/tmp/fixture/missing", mount: "/private/tmp/fixture", links: []) == "missing"
             && dataRelative("/private/tmp/fixture/missing", mount: "/tmp/fixture", links: []) == "missing",
             "inventory scoped refresh aliases resolve the same missing leaf for either mount spelling")
    let root = monitorSelfTestFixture("inventory").path
    let state = URL(fileURLWithPath: root + "-state")
    defer { finishMonitorSelfTestFixture(URL(fileURLWithPath: root)); finishMonitorSelfTestFixture(state) }
    try FileManager.default.createDirectory(atPath: root + "/a/sub", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/many", withIntermediateDirectories: true)
    // More than one reconciliation page: this catches accidentally re-enqueuing the same
    // completed 256 directory jobs forever after an event-history gap.
    for index in 0..<270 { try FileManager.default.createDirectory(atPath: root + "/wide/d\(index)", withIntermediateDirectories: true) }
    try privateDirectory(state)
    try Data(repeating: 1, count: 32_768).write(to: URL(fileURLWithPath: root + "/a/shared.bin"))
    try required(link(root + "/a/shared.bin", root + "/b/shared-link.bin") == 0, "create hard link")
    try Data(repeating: 2, count: 4_096).write(to: URL(fileURLWithPath: root + "/a/sub/child.bin"))
    try FileManager.default.createSymbolicLink(atPath: root + "/a/link-to-b", withDestinationPath: root + "/b")
    for index in 0..<620 { FileManager.default.createFile(atPath: root + "/many/f\(index)", contents: Data([UInt8(index & 255)])) }
    var rootInfo = stat()
    try required(lstat(root, &rootInfo) == 0, "stat inventory fixture")
    let region = CoverageRegion(mount: root, prefix: "", device: rootInfo.st_dev, deviceIdentifier: "inventory-test")
    let databasePath = state.appendingPathComponent("history.sqlite3").path
    _ = try Database(databasePath)

    let interrupted = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10, batchSize: 7, stopAfterEntries: 11), fdaOverride: "granted")
    let needsAfterInterrupt = inventoryNeedsWork(databasePath: databasePath)
    try test(interrupted.outcome == "interrupted" && interrupted.entries == 11 && needsAfterInterrupt, "entry limit checkpoints a partial listing without pruning (outcome=\(interrupted.outcome), entries=\(interrupted.entries), pending=\(interrupted.pending), needs=\(needsAfterInterrupt))")
    let completed = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, batchSize: 37), fdaOverride: "granted")
    try test(completed.outcome == "complete" && !inventoryNeedsWork(databasePath: databasePath), "resumed inventory reaches a terminal complete generation")

    func rows(_ sql: String, _ values: [Any] = []) throws -> [[String: String]] { try Database(databasePath).rows(sql, values) }
    let kinds = try rows("SELECT name,kind FROM inventory_nodes WHERE name IN ('link-to-b','child.bin')")
    try test(kinds.contains { $0["name"] == "link-to-b" && $0["kind"] == "symlink" } && kinds.contains { $0["name"] == "child.bin" && $0["kind"] == "file" }, "symlink metadata is recorded without following it; nested files keep their true kind")
    let hardlinks = try rows("SELECT n.id,n.name,n.total_allocated,(o.owner_node_id=n.id) AS owner FROM inventory_nodes n JOIN inventory_objects o ON o.id=n.object_id WHERE n.name IN ('shared.bin','shared-link.bin') ORDER BY n.name")
    let countedHardlinks = hardlinks.filter { Int64($0["total_allocated"] ?? "0") ?? 0 > 0 }
    try test(hardlinks.count == 2 && countedHardlinks.count == 1 && hardlinks.filter({ $0["owner"] == "0" }).count == 1, "hard-link aliases remain navigable while allocation is counted globally once")
    let many = try rows("SELECT child_count,status FROM inventory_nodes WHERE name='many'").first
    try test(many?["child_count"] == "620" && many?["status"] == "complete", "large directory streams through bounded batches and resumes without losing siblings")

    // Move with the old parent invalidated first. Tombstones must preserve the subtree until the
    // new parent binds the same directory identity.
    let beforeMove = try rows("SELECT id FROM inventory_nodes WHERE name='sub'").first?["id"]
    let childBefore = try rows("SELECT id FROM inventory_nodes WHERE name='child.bin'").first?["id"]
    try FileManager.default.moveItem(atPath: root + "/a/sub", toPath: root + "/b/sub")
    try invalidateInventory(databasePath: databasePath, paths: [root + "/a", root + "/b"], eventID: 101, gap: false, reason: "test move", deviceIdentifier: "inventory-test")
    let moved = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 20, batchSize: 31), fdaOverride: "granted")
    let afterMove = try rows("SELECT n.id,p.name AS parent FROM inventory_nodes n JOIN inventory_nodes p ON p.id=n.parent_id WHERE n.name='sub'").first
    let childAfter = try rows("SELECT id FROM inventory_nodes WHERE name='child.bin'").first?["id"]
    try test(moved.outcome == "complete" && afterMove?["id"] == beforeMove && afterMove?["parent"] == "b" && childAfter == childBefore, "directory move preserves directory and descendant identity when the old parent is listed first")

    // Remove whichever hard-link name owns the object. The remaining alias must become owner and
    // retain exactly one global allocation contribution.
    let ownerName = hardlinks.first(where: { $0["owner"] == "1" })!["name"]!
    let ownerParent = ownerName == "shared.bin" ? "a" : "b"
    try FileManager.default.removeItem(atPath: root + "/\(ownerParent)/\(ownerName)")
    try invalidateInventory(databasePath: databasePath, paths: [root + "/\(ownerParent)"], eventID: 102, gap: false, reason: "test unlink", deviceIdentifier: "inventory-test")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 20, batchSize: 29), fdaOverride: "granted")
    let remainingHardlink = try rows("SELECT n.total_allocated,(o.owner_node_id=n.id) AS owner FROM inventory_nodes n JOIN inventory_objects o ON o.id=n.object_id WHERE n.name IN ('shared.bin','shared-link.bin')")
    try test(remainingHardlink.count == 1 && remainingHardlink[0]["owner"] == "1" && (Int64(remainingHardlink[0]["total_allocated"] ?? "0") ?? 0) > 0, "deleting a hard-link owner transfers accounting to a remaining alias")

    try invalidateInventory(databasePath: databasePath, paths: [], eventID: 103, gap: true, reason: "synthetic event gap", deviceIdentifier: "inventory-test")
    let reconciled = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, batchSize: 43), fdaOverride: "granted")
    let cursor = try loadInventoryEventCursor(databasePath: databasePath, deviceIdentifier: "inventory-test")
    try test(reconciled.outcome == "complete" && cursor?.eventID == 103 && !inventoryNeedsWork(databasePath: databasePath), "event gap durably invalidates descendants and cursor advances with the invalidation transaction")

    // Schema installation remains additive to pre-existing monitor data.
    let legacy = state.appendingPathComponent("legacy.sqlite3").path
    var raw: OpaquePointer?
    try required(sqlite3_open(legacy, &raw) == SQLITE_OK, "open legacy inventory migration fixture")
    _ = sqlite3_exec(raw, "CREATE TABLE keep_me(value TEXT); INSERT INTO keep_me VALUES('preserved')", nil, nil, nil)
    sqlite3_close(raw)
    try initializeInventorySchema(databasePath: legacy)
    let legacyDatabase = try Database(legacy)
    try test(try legacyDatabase.rows("SELECT value FROM keep_me").first?["value"] == "preserved" && (try legacyDatabase.rows("SELECT name FROM sqlite_master WHERE name='inventory_nodes'").count) == 1, "inventory migration is additive and preserves unrelated production tables")

    try FileManager.default.createDirectory(atPath: root + "/denied", withIntermediateDirectories: true)
    try Data(count: 8_192).write(to: URL(fileURLWithPath: root + "/denied/hidden"))
    _ = chmod(root + "/denied", 0)
    defer { _ = chmod(root + "/denied", 0o700) }
    try invalidateInventory(databasePath: databasePath, paths: [root], eventID: 104, gap: false, reason: "permission fixture")
    let protectedResult = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let protectedRow = try rows("SELECT status,total_logical,total_allocated,reason FROM inventory_nodes WHERE name='denied'").first!
    try test(protectedResult.outcome == "partial" && protectedRow["status"] == "unknown" && protectedRow["total_logical"] == nil && protectedRow["total_allocated"] == nil, "permission-denied directory stays unknown, never a complete zero-byte folder")
    let rootQualification = try rows("SELECT status FROM inventory_nodes WHERE parent_id IS NULL").first?["status"]
    try test(rootQualification == "partial" && !inventoryNeedsWork(databasePath: databasePath), "terminal inaccessible child propagates uncertainty without endless pending work")
    _ = chmod(root + "/denied", 0o700)
    try requestInventoryRefresh(databasePath: databasePath, paths: [root + "/denied"])
    let recovered = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let recoveredRow = try rows("SELECT status,total_logical FROM inventory_nodes WHERE name='denied'").first!
    try test(recovered.outcome == "complete" && recoveredRow["status"] == "complete" && recoveredRow["total_logical"] == "8192", "explicit refresh recovers accessible subtree with exact file-content totals")
}

func inventoryReaderSelfTest(databasePath: String, rootPath: String, _ test: (Bool, String) throws -> Void) async throws {
    let reader = InventoryReader(path: databasePath)
    guard let root = try await reader.root() else { try test(false, "reader exposes the active root"); return }
    let first = try await reader.children(parentID: root.id, offset: 0, limit: 2, sort: .name)
    let second = try await reader.children(parentID: root.id, offset: 2, limit: 2, sort: .name)
    try test(root.path == rootPath && first.items.count == 2 && first.hasMore && Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)), "reader returns absolute paths and stable offset pagination")
    let search = try await reader.search(text: "b/sub/child", under: nil, offset: 0, limit: 10)
    let largest = try await reader.largest(kind: .files, under: nil, offset: 0, limit: 10)
    let status = try await reader.status()
    try test(search.items.contains { $0.name == "child.bin" } && !largest.items.isEmpty && status.completeness == .complete, "reader supports path search, indexed global largest files, and O(1) status counters")
}
