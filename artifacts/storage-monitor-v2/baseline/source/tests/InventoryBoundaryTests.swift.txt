import Foundation
import SQLite3

#if INVENTORY_TESTS
func inventoryBoundaryTests(_ check: (Bool, String) throws -> Void) async throws {
    try liveRequestServiceTest(check)
    let root = "/private/tmp/storage-monitor-boundaries-\(UUID().uuidString)", state = URL(fileURLWithPath: "/private/tmp/storage-monitor-boundary-state-\(UUID().uuidString)")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    for i in 0..<30 {
        try fm.createDirectory(atPath: root + "/folder-\(i)", withIntermediateDirectories: true)
        try Data(count: 2048).write(to: URL(fileURLWithPath: root + "/folder-\(i)/file"))
    }
    try privateDirectory(state)
    let path = state.appendingPathComponent("history.sqlite3").path, db = try Database(path), region = coverageRegion(root: root)!
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10, stopAfterEntries: 1), fdaOverride: "granted")
    let request = try InventoryRequests.enqueue(database: path, action: "refresh")
    let file = InventoryRequests.directory(database: path).appendingPathComponent(request.uuidString + ".json")
    let captured = try JSONDecoder().decode(InventoryWorkRequest.self, from: Data(contentsOf: file)).boundary!
    let initial = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let tokensBefore = try db.rows("SELECT node_id,listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.parent_id IS NOT NULL ORDER BY node_id")
    let reader = InventoryReader(path: path), generation = captured.generation
    try consumeInventoryRequests(database: path, directory: state, region: region)
    let queued = try await reader.status()
    try check(initial.outcome == "complete" && queued.completeness == .stale, "manual refresh queued during initialization is visible to readers before application")
    let profile = InventoryProfile()
    let refreshed = profile.withScope { runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted") }
    let tokensAfter = try db.rows("SELECT node_id,listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.parent_id IS NOT NULL ORDER BY node_id")
    try check(refreshed.outcome == "complete" && tokensBefore == tokensAfter && profile.counts["jobs_skipped_satisfied", default: 0] > 0,
              "post-request child listings satisfy a late-consumed refresh without repeat enumeration")
    let nodes = Int64(try db.rows("SELECT MAX(id) AS n FROM inventory_nodes").first!["n"]!)!
    try check(captured.endNodeID < nodes && profile.counts["listings_repeated", default: 0] == 1,
              "request-time endpoint excludes new discoveries; only the already-running root listing needs revisiting")
    let idle = profile.withScope { runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted") }
    try check(idle.entries == 0 && idle.directories == 0, "repeated execution after a satisfied refresh performs no filesystem listings")

    try requestInventoryRefresh(databasePath: path, paths: [region.root])
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10, stopAfterEntries: 5), fdaOverride: "granted")
    let recovered = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    let tokensLater = try db.rows("SELECT listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.parent_id IS NOT NULL")
    try check(recovered.outcome == "complete" && tokensLater.allSatisfy { $0["listing_token"] == "2" },
              "later refresh cannot use earlier listings and resumes without duplicate completed child work")

    // Legacy state acquires a conservative boundary; the migration must not invent
    // completion evidence from mutable measured_at/updated_at values.
    let rootID = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE parent_id IS NULL").first!["id"]!)!
    try db.write("UPDATE inventory_jobs SET completed_sequence=0 WHERE generation_id=?", [generation])
    try db.write("INSERT INTO inventory_reconcile(root_node_id,generation_id,reason,created_at,end_node_id) VALUES (?,?,'legacy',1,?)", [rootID,generation,nodes])
    try initializeInventorySchema(databasePath: path)
    let legacy = try db.rows("SELECT request_sequence,end_node_id FROM inventory_reconcile").first!
    let trusted = try db.rows("SELECT COUNT(*) AS n FROM inventory_jobs WHERE completed_sequence>0").first!["n"]!
    try check(Int64(legacy["request_sequence"]!)! > 0 && legacy["end_node_id"] == String(nodes) && trusted == "0",
              "legacy migration bounds requests without certifying historical listings")
    try initializeInventorySchema(databasePath: path)
    try check(try db.rows("SELECT request_sequence,end_node_id FROM inventory_reconcile").first! == legacy,
              "lifecycle migration is idempotent and preserves the adopted request boundary")
    let beforeHistory = try db.rows("SELECT * FROM readings")
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    try check((try db.rows("PRAGMA quick_check").first?.values.first) == "ok" && (try db.rows("PRAGMA foreign_key_check")).isEmpty && (try db.rows("SELECT * FROM readings")) == beforeHistory,
              "resumed migrated inventory preserves history and SQLite integrity")
    try db.write("INSERT INTO inventory_reconcile(root_node_id,generation_id,reason,created_at,end_node_id) VALUES (?,?,'migration interruption',1,?)", [rootID,generation,nodes])
    let oldClock = try db.rows("SELECT inventory_sequence FROM inventory_generations WHERE id=?", [generation]).first!
    try db.exec("CREATE TRIGGER fail_lifecycle_adoption BEFORE UPDATE OF inventory_sequence ON inventory_generations BEGIN SELECT RAISE(ABORT,'injected migration failure'); END")
    var rolledBack = false
    do { try initializeInventorySchema(databasePath: path) } catch { rolledBack = true }
    try check(rolledBack && (try db.rows("SELECT inventory_sequence FROM inventory_generations WHERE id=?", [generation]).first!) == oldClock && (try db.rows("SELECT request_sequence FROM inventory_reconcile").first?["request_sequence"]) == "0",
              "interrupted migration rolls back its clock and preserves unadopted work")
    try db.exec("DROP TRIGGER fail_lifecycle_adoption")
    try initializeInventorySchema(databasePath: path)
    try check(Int64(try db.rows("SELECT request_sequence FROM inventory_reconcile").first!["request_sequence"]!)! > 0,
              "migration retries successfully after interrupted adoption")
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    for i in 0..<300 { try Data([1]).write(to: URL(fileURLWithPath: root + "/folder-0/new-\(i)")) }
    try invalidateInventory(databasePath: path, paths: [region.root + "/folder-0"], eventID: nil, gap: false, reason: "Filesystem activity")
    let beforeToken = Int64(try db.rows("SELECT listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='folder-0'").first!["listing_token"]!)!
    var callbacks = 0, injected = false
    var injectionError: Error?
    let raced = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted") {
        callbacks += 1
        if callbacks == 3 && !injected {
            do {
                try Data(count: 4096).write(to: URL(fileURLWithPath: root + "/folder-0/file"))
                try invalidateInventory(databasePath: path, paths: [region.root + "/folder-0"], eventID: nil, gap: false, reason: "Filesystem activity")
                injected = true
            } catch { injectionError = error; return true }
        }
        return false
    }
    let racedRow = try db.rows("SELECT listing_token,total_logical FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='folder-0'").first!
    try check(injectionError == nil && injected && raced.outcome == "complete" && Int64(racedRow["listing_token"]!)! == beforeToken+2 && racedRow["total_logical"] == "4396",
              "an invalidation received during enumeration requires a newer listing and retains changed file metadata")
    let backgroundToken = try db.rows("SELECT listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='folder-1'").first!["listing_token"]!
    let selectedToken = Int64(try db.rows("SELECT listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='folder-29'").first!["listing_token"]!)!
    try db.write("UPDATE inventory_jobs SET state='pending',updated_at=1 WHERE node_id=(SELECT id FROM inventory_nodes WHERE name='folder-1')")
    let waiting = try await reader.status()
    try check(waiting.queuedDirectoryJobs == 1 && waiting.state != "complete" && waiting.completeness != .complete,
              "reader reports durable pending jobs even when directory-state counters have no pending bucket")
    try requestInventoryRefresh(databasePath: path, paths: [region.root + "/folder-29"])
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10, stopAfterEntries: 1), fdaOverride: "granted")
    let selectedAfter = Int64(try db.rows("SELECT listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='folder-29'").first!["listing_token"]!)!
    let backgroundAfter = try db.rows("SELECT listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='folder-1'").first!["listing_token"]!
    try check(selectedAfter == selectedToken+1 && backgroundAfter == backgroundToken,
              "a selected-folder refresh receives enumeration ahead of ordinary background directory jobs")
}

private func liveRequestServiceTest(_ check: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-live-request-\(UUID().uuidString)", state = URL(fileURLWithPath: "/private/tmp/storage-monitor-live-state-\(UUID().uuidString)")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    for i in 0..<24 {
        try fm.createDirectory(atPath: root + "/dir-\(i)", withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: root + "/dir-\(i)/file"))
    }
    try privateDirectory(state)
    let path = state.appendingPathComponent("history.sqlite3").path, db = try Database(path), region = coverageRegion(root: root)!
    var callbacks = 0, request: UUID?
    var failure: Error?
    let profile = InventoryProfile()
    let result = profile.withScope {
        runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 5, pause: 0.02, serviceRequests: true), fdaOverride: "granted") {
            callbacks += 1
            if callbacks == 3 {
                do { request = try InventoryRequests.enqueue(database: path, action: "refresh") }
                catch { failure = error; return true }
            }
            return false
        }
    }
    let unconsumed = (try? fm.contentsOfDirectory(at: InventoryRequests.directory(database: path), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }) ?? []
    let children = try db.rows("SELECT listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.parent_id IS NOT NULL")
    try check(failure == nil && request != nil && unconsumed.isEmpty && result.outcome == "complete",
              "the running worker consumes a newly queued refresh through its existing bounded service points")
    try check(children.count == 24 && children.allSatisfy { $0["listing_token"] == "1" } && profile.counts["listings_repeated"] == 1,
              "live request service repeats only the earlier root attempt and retains post-request child listings")
}
#endif
