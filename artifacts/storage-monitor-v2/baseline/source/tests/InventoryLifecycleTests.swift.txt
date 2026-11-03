import Foundation
import SQLite3

#if INVENTORY_TESTS
func inventoryLifecycleTests(_ check: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-lifecycle-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    for index in 0..<20 {
        try Data(repeating: UInt8(index), count: 1024).write(to: URL(fileURLWithPath: root + "/current-\(index)"))
    }
    try privateDirectory(state)
    let path = state.appendingPathComponent("history.sqlite3").path
    let db = try Database(path), region = coverageRegion(root: root)!
    let initial = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    try check(initial.outcome == "complete", "cleanup authority fixture has a completed real directory listing")
    let parent = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE parent_id IS NULL").first!["id"]!)!
    let token = Int64(try db.rows("SELECT listing_token FROM inventory_jobs WHERE node_id=?", [parent]).first!["listing_token"]!)!
    try db.write("INSERT INTO inventory_prune_jobs(parent_node_id,generation_id,seen_token,created_at) SELECT id,generation_id,?,0 FROM inventory_nodes WHERE id=?", [token - 1, parent])
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let remaining = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE parent_id=?", [parent]).first!["n"]!
    try check(remaining == "20", "obsolete root cleanup token cannot delete the 20 currently observed children (retained \(remaining))")

    // A real second connection cannot delete through an uncommitted newer listing.
    let generation = Int64(try db.rows("SELECT generation_id FROM inventory_nodes WHERE id=?", [parent]).first!["generation_id"]!)!
    try db.write("INSERT INTO inventory_prune_jobs(parent_node_id,generation_id,seen_token,created_at) VALUES (?,?,?,0)", [parent,generation,token])
    try db.write("UPDATE inventory_nodes SET seen_token=0 WHERE id=(SELECT MIN(id) FROM inventory_nodes WHERE parent_id=?)", [parent])
    try db.exec("BEGIN IMMEDIATE")
    try db.write("UPDATE inventory_jobs SET listing_token=?,completed_token=? WHERE node_id=?", [token+1,token+1,parent])
    try db.write("UPDATE inventory_nodes SET seen_token=? WHERE parent_id=?", [token+1,parent])
    let outcome = CleanupPeerOutcome(), done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        do { _ = try inventoryMaintenanceStep(databasePath: path, generation: generation, parentNode: parent); outcome.set("completed after the lock") }
        catch { outcome.set(String(describing: error)) }
        done.signal()
    }
    // The worker now waits for a lock (1.0.3, D9) instead of failing after 100 ms: the peer either
    // reports busy or waits until the newer listing commits. It can never delete through the lock.
    let finishedWhileLocked = done.wait(timeout: .now() + 3) == .success
    try db.exec("COMMIT")
    let joined = finishedWhileLocked || done.wait(timeout: .now() + 40) == .success
    let retained = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE parent_id=?", [parent]).first?["n"]
    try check(joined && (outcome.get().contains("busy") || outcome.get() == "completed after the lock") && retained == "20",
              "concurrent newer listing holds authority through its commit; cleanup cannot write through the lock (\(outcome.get()), \(retained ?? "?") of 20 retained)")
    _ = try inventoryMaintenanceStep(databasePath: path, generation: generation, parentNode: parent)
    try check((try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE parent_id=?", [parent]).first?["n"]) == "20",
              "cleanup revalidates the committed newer token after contention and retains current records")

    try cleanupSupersessionTests(check)
    try cleanupMoveAndOverlapTests(check)
    try refreshSequenceTests(check)
    try replacementRepairTests(check)
}

private final class CleanupPeerOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func set(_ value: String) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

private func interruptedListing(_ database: String, state: URL, region: CoverageRegion) -> InventoryRunResult {
    var callbacks = 0
    return runInventory(databasePath: database, directory: state, region: region,
                        options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted") {
        callbacks += 1
        return callbacks >= 3
    }
}

private func drainMaintenance(_ database: String, generation: Int64, parent: Int64? = nil, maximum: Int = 512) throws -> Int {
    var steps = 0
    while steps < maximum, try inventoryMaintenanceStep(databasePath: database, generation: generation, parentNode: parent, limit: 8) { steps += 1 }
    return steps
}

private func cleanupSupersessionTests(_ check: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-cleanup-newer-\(UUID().uuidString)"
    let saved = root + "-saved", state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(atPath: saved); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/branch/child", withIntermediateDirectories: true)
    try Data(count: 8192).write(to: URL(fileURLWithPath: root + "/branch/child/file"))
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path, region = coverageRegion(root: root)!
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let db = try Database(database)
    let generation = Int64(try db.rows("SELECT id FROM inventory_generations WHERE active=1").first!["id"]!)!
    let rootNode = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE parent_id IS NULL").first!["id"]!)!
    let branch = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='branch'").first!["id"]!)!
    try fm.moveItem(atPath: root + "/branch", toPath: saved)
    try invalidateInventory(databasePath: database, paths: [root], eventID: nil, gap: false, reason: "branch temporarily absent")
    _ = interruptedListing(database, state: state, region: region)
    try check(try inventoryMaintenanceStep(databasePath: database, generation: generation, parentNode: rootNode, limit: 1),
              "cleanup discovery can be paused after one durable claim page")
    try check(try inventoryMaintenanceStep(databasePath: database, generation: generation, parentNode: rootNode, limit: 1),
              "recursive cleanup expansion can be paused before deletion")
    try fm.moveItem(atPath: saved, toPath: root + "/branch")
    try invalidateInventory(databasePath: database, paths: [root,root + "/branch"], eventID: nil, gap: false, reason: "branch reappeared")
    let refreshed = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    _ = try drainMaintenance(database, generation: generation)
    let preserved = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE id=? OR name IN ('child','file')", [branch]).first!["n"]!
    try check(refreshed.outcome == "complete" && preserved == "3",
              "a newer listing supersedes expanded cleanup claims without deleting the reobserved branch")
    let work = try db.rows("SELECT (SELECT COUNT(*) FROM inventory_prune_jobs)+(SELECT COUNT(*) FROM inventory_tombstone_claims) AS n").first!["n"]!
    try check(work == "0", "superseded recursive cleanup claims retire in bounded maintenance steps")
}

private func cleanupMoveAndOverlapTests(_ check: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-cleanup-moves-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/source/outer/inner", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root + "/destination", withIntermediateDirectories: true)
    try Data(count: 4096).write(to: URL(fileURLWithPath: root + "/source/outer/inner/file"))
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path, region = coverageRegion(root: root)!
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let db = try Database(database)
    let generation = Int64(try db.rows("SELECT id FROM inventory_generations WHERE active=1").first!["id"]!)!
    let source = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='source'").first!["id"]!)!
    let outer = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='outer'").first!["id"]!)!
    let inner = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='inner'").first!["id"]!)!
    try fm.moveItem(atPath: root + "/source/outer/inner", toPath: root + "/destination/inner")
    try fm.removeItem(atPath: root + "/source/outer")
    try invalidateInventory(databasePath: database, paths: [root + "/source"], eventID: nil, gap: false, reason: "old branch absent")
    _ = interruptedListing(database, state: state, region: region)
    for _ in 0..<3 { _ = try inventoryMaintenanceStep(databasePath: database, generation: generation, parentNode: source, limit: 1) }
    try invalidateInventory(databasePath: database, paths: [root + "/destination"], eventID: nil, gap: false, reason: "inner moved")
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    _ = try drainMaintenance(database, generation: generation)
    let moved = try db.rows("SELECT n.parent_id,n.total_logical FROM inventory_nodes n WHERE n.id=?", [inner]).first
    let destination = try db.rows("SELECT id FROM inventory_nodes WHERE name='destination'").first!["id"]!
    try check(moved?["parent_id"] == destination && moved?["total_logical"] == "4096" && (try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE id=?", [outer]).first?["n"]) == "0",
              "inner descendant moves survive expanded obsolete-root cleanup while the truly absent root is deleted")

    // Two valid cleanup epochs can overlap: first remove a child under outer2, then
    // remove outer2 itself before the child cleanup drains.
    try fm.createDirectory(atPath: root + "/source/outer2/child", withIntermediateDirectories: true)
    try Data(count: 2048).write(to: URL(fileURLWithPath: root + "/source/outer2/child/file"))
    try invalidateInventory(databasePath: database, paths: [root + "/source"], eventID: nil, gap: false, reason: "discover overlap fixture")
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let outer2 = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='outer2'").first!["id"]!)!
    try fm.removeItem(atPath: root + "/source/outer2/child")
    try invalidateInventory(databasePath: database, paths: [root + "/source/outer2"], eventID: nil, gap: false, reason: "inner cleanup epoch")
    _ = interruptedListing(database, state: state, region: region)
    _ = try inventoryMaintenanceStep(databasePath: database, generation: generation, parentNode: outer2, limit: 1)
    try fm.removeItem(atPath: root + "/source/outer2")
    try invalidateInventory(databasePath: database, paths: [root + "/source"], eventID: nil, gap: false, reason: "outer cleanup epoch")
    _ = interruptedListing(database, state: state, region: region)
    _ = try drainMaintenance(database, generation: generation)
    let overlapWork = try db.rows("SELECT (SELECT COUNT(*) FROM inventory_prune_jobs)+(SELECT COUNT(*) FROM inventory_tombstone_claims) AS n").first!["n"]!
    try check((try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE id=?", [outer2]).first?["n"]) == "0" && overlapWork == "0",
              "overlapping cleanup epochs converge without stranded claims or repeated-step deletion loops")

    try fm.createDirectory(atPath: root + "/source/moved-root/sub", withIntermediateDirectories: true)
    try Data(count: 1024).write(to: URL(fileURLWithPath: root + "/source/moved-root/sub/kept"))
    try invalidateInventory(databasePath: database, paths: [root + "/source"], eventID: nil, gap: false, reason: "discover movable root")
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let movable = try db.rows("SELECT id FROM inventory_nodes WHERE name='moved-root'").first!["id"]!
    try fm.moveItem(atPath: root + "/source/moved-root", toPath: root + "/destination/moved-root")
    try invalidateInventory(databasePath: database, paths: [root + "/source"], eventID: nil, gap: false, reason: "movable root absent")
    _ = interruptedListing(database, state: state, region: region)
    for _ in 0..<3 { _ = try inventoryMaintenanceStep(databasePath: database, generation: generation, parentNode: source, limit: 1) }
    try invalidateInventory(databasePath: database, paths: [root + "/destination"], eventID: nil, gap: false, reason: "observe moved root")
    let relocated = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    try check(relocated.outcome == "complete" && (try db.rows("SELECT id,parent_id,total_logical FROM inventory_nodes WHERE name='moved-root'").first) == ["id":movable,"parent_id":destination,"total_logical":"1024"],
              "moving the obsolete root itself invalidates all expanded descendant deletion claims")
}

private func refreshSequenceTests(_ check: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-refresh-sequence-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
    try Data([1]).write(to: URL(fileURLWithPath: root + "/a/file"))
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path, region = coverageRegion(root: root)!
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let db = try Database(database)
    let end = Int64(try db.rows("SELECT MAX(id) AS n FROM inventory_nodes").first!["n"]!)!
    try invalidateInventory(databasePath: database, paths: [], eventID: nil, gap: true, reason: "newer gap", requiredSequence: 100, endNodeID: end)
    try invalidateInventory(databasePath: database, paths: [], eventID: nil, gap: true, reason: "late older request", requiredSequence: 50, endNodeID: end - 1)
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 0), fdaOverride: "granted")
    let reconcile = try db.rows("SELECT request_sequence,end_node_id,reason FROM inventory_reconcile").first
    let queuedReasons = Set(try db.rows("SELECT reason FROM inventory_jobs WHERE state IN ('pending','enumerating')").compactMap { $0["reason"] })
    let orderingHeld = reconcile.map { $0["request_sequence"] == "100" && $0["end_node_id"] == String(end) && $0["reason"] == "newer gap" } ?? (queuedReasons == ["newer gap"])
    try check(orderingHeld,
              "a delayed older request boundary cannot erase a newer gap sequence, endpoint, or reason")
    let before = Int64(try db.rows("SELECT inventory_sequence FROM inventory_generations WHERE active=1").first!["inventory_sequence"]!)!
    try Data([2]).write(to: URL(fileURLWithPath: root + "/a/after-request"))
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let completed = Int64(try db.rows("SELECT completed_sequence FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='a'").first!["completed_sequence"]!)!
    try check(completed > before && (try db.rows("SELECT COUNT(*) AS n FROM inventory_reconcile").first?["n"]) == "0",
              "directory listings after a durable refresh boundary certify and drain overlapping reconciliation")
}

private func replacementRepairTests(_ check: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-replacement-repair-\(UUID().uuidString)", state = URL(fileURLWithPath: "/private/tmp/storage-monitor-replacement-state-\(UUID().uuidString)")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/replaced/child", withIntermediateDirectories: true)
    try Data(count: 8192).write(to: URL(fileURLWithPath: root + "/replaced/child/old"))
    try privateDirectory(state)
    let path = state.appendingPathComponent("history.sqlite3").path, db = try Database(path), region = coverageRegion(root: root)!
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let parent = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE parent_id IS NULL").first!["id"]!)!
    let replaced = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='replaced'").first!["id"]!)!
    let child = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='child'").first!["id"]!)!
    let generation = Int64(try db.rows("SELECT generation_id FROM inventory_nodes WHERE id=?", [parent]).first!["generation_id"]!)!
    try fm.removeItem(atPath: root + "/replaced")
    try Data(count: 4096).write(to: URL(fileURLWithPath: root + "/replaced"))
    try invalidateInventory(databasePath: path, paths: [region.root], eventID: nil, gap: false, reason: "replace directory")
    _ = interruptedListing(path, state: state, region: region)
    let boundary = Int64(try db.rows("SELECT authority_sequence FROM inventory_prune_jobs WHERE parent_node_id=?", [replaced]).first!["authority_sequence"]!)!
    // Pin the SQL interleaving of a later descendant completion. The physical fixture
    // remains a file, so repair must target its containing directory, not a missing job.
    try db.write("UPDATE inventory_jobs SET completed_sequence=? WHERE node_id=?", [boundary+1,child])
    try db.write("UPDATE inventory_generations SET inventory_sequence=MAX(inventory_sequence,?) WHERE id=?", [boundary+1,generation])
    for _ in 0..<5 { _ = try inventoryMaintenanceStep(databasePath: path, generation: generation, parentNode: replaced, limit: 1) }
    try check((try db.rows("SELECT state FROM inventory_jobs WHERE node_id=?", [parent]).first?["state"]) == "pending" && (try db.rows("SELECT status FROM inventory_nodes WHERE id=?", [replaced]).first?["status"]) == "stale",
              "newer descendant evidence during replacement cleanup queues the containing directory and preserves uncertainty")
    let repaired = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    try check(repaired.outcome == "complete" && (try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE parent_id=?", [replaced]).first?["n"]) == "0" && (try db.rows("SELECT total_logical FROM inventory_nodes WHERE id=?", [parent]).first?["total_logical"]) == "4096",
              "replacement repair reacquires object authority, prunes old descendants and restores exact parent totals")
}
#endif
