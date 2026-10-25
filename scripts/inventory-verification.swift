import Foundation
import Darwin

// Development-only executable: built with INVENTORY_TESTS to suppress the app entry
// point. It never installs services or writes to existing QA/production databases.
@main enum InventoryVerification {
    static func main() async {
        do {
            let args = CommandLine.arguments
            func value(_ key: String) -> String? { args.firstIndex(of: key).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            if let path = value("--snapshot-copy") {
                try snapshot(path)
            } else {
                guard let root = value("--root"), let state = value("--state") else { throw Failure("Specify a bounded --root and fresh --state, or --snapshot-copy") }
                try await benchmark(root: root, state: state)
            }
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }

    static func snapshot(_ path: String) throws {
        let allowed = fm.currentDirectoryPath + "/build/inventory-correction/"
        try required(path.hasPrefix(allowed) && path.hasSuffix("snapshot-copy.sqlite3"), "Snapshot regression accepts only its disposable correction copy")
        let db = try Database(path)
        let tables = ["alerts", "coverage_epochs", "coverage_units", "diagnostics", "interval_evidence", "readings", "state"]
        let history = try tables.map { try db.rows("SELECT * FROM \($0) ORDER BY rowid") }
        let original = try db.rows("SELECT id,seen_token FROM inventory_nodes WHERE parent_id=1 ORDER BY id")
        let unsafe = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes n JOIN inventory_prune_jobs p ON p.parent_node_id=n.parent_id WHERE p.parent_node_id=1 AND n.seen_token<>p.seen_token").first!["n"]!
        let total = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes").first!["n"]!
        let endpoint = try db.rows("SELECT end_node_id FROM inventory_reconcile WHERE root_node_id=1").first!["end_node_id"]!
        let profile = InventoryProfile()
        try profile.withScope {
            try initializeInventorySchema(databasePath: path)
            _ = try inventoryMaintenanceStep(databasePath: path, generation: 1, parentNode: 1)
        }
        try required(original.count == 20 && unsafe == "20", "Preserved root failure is not the expected 20-child case")
        try required(try db.rows("SELECT id,seen_token FROM inventory_nodes WHERE parent_id=1 ORDER BY id") == original, "Current root children were changed by obsolete cleanup")
        try required(try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes").first!["n"] == total, "Obsolete root cleanup removed inventory records")

        let stale = try db.rows("SELECT p.parent_node_id FROM inventory_prune_jobs p JOIN inventory_jobs j ON j.node_id=p.parent_node_id WHERE p.cleanup_epoch=0 AND j.state='complete' AND p.seen_token<>j.listing_token ORDER BY p.parent_node_id LIMIT 256")
        for row in stale {
            _ = try profile.withScope { try inventoryMaintenanceStep(databasePath: path, generation: 1, parentNode: Int64(row["parent_node_id"]!)!) }
        }
        try required(try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes").first!["n"] == total, "Sampled obsolete cleanup removed current records")

        // Select a small authoritative parent from actual preserved evidence.
        let valid = try db.rows("SELECT p.parent_node_id,COUNT(*) AS candidates FROM inventory_prune_jobs p JOIN inventory_jobs j ON j.node_id=p.parent_node_id JOIN inventory_nodes n ON n.parent_id=p.parent_node_id AND n.seen_token<>p.seen_token WHERE j.state='complete' AND j.reason IS NULL AND p.seen_token=j.listing_token GROUP BY p.parent_node_id ORDER BY COUNT(*),p.parent_node_id LIMIT 1").first!
        let parent = Int64(valid["parent_node_id"]!)!
        let current = try db.rows("SELECT n.id FROM inventory_nodes n JOIN inventory_prune_jobs p ON p.parent_node_id=n.parent_id WHERE n.parent_id=? AND n.seen_token=p.seen_token ORDER BY n.id", [parent])
        let seedIDs = try db.rows("SELECT n.id FROM inventory_nodes n JOIN inventory_prune_jobs p ON p.parent_node_id=n.parent_id WHERE n.parent_id=? AND n.seen_token<>p.seen_token", [parent]).map { Int64($0["id"]!)! }
        var steps = 0
        while steps < 256, !(try db.rows("SELECT 1 FROM inventory_prune_jobs WHERE parent_node_id=?", [parent])).isEmpty {
            _ = try profile.withScope { try inventoryMaintenanceStep(databasePath: path, generation: 1, parentNode: parent) }
            steps += 1
        }
        for id in seedIDs { try required(try db.rows("SELECT 1 FROM inventory_nodes WHERE id=?", [id]).isEmpty, "Authoritative cleanup did not remove absent seed") }
        for row in current { try required(try db.rows("SELECT 1 FROM inventory_nodes WHERE id=?", [Int64(row["id"]!)!]).count == 1, "Authoritative cleanup removed an observed child") }
        let refresh = try db.rows("SELECT COUNT(*) AS candidates,SUM(CASE WHEN j.state='complete' AND j.reason IS NULL AND j.completed_sequence>=r.request_sequence AND r.request_sequence>0 THEN 1 ELSE 0 END) AS satisfied FROM inventory_reconcile r JOIN inventory_nodes n ON n.generation_id=r.generation_id AND n.kind='directory' AND n.id>r.last_node_id AND n.id<=r.end_node_id JOIN inventory_jobs j ON j.node_id=n.id WHERE r.root_node_id=1").first!
        try required(try db.rows("SELECT end_node_id FROM inventory_reconcile WHERE root_node_id=1").first!["end_node_id"] == endpoint, "Migration expanded the retained refresh endpoint")
        for (index, table) in tables.enumerated() { try required(try db.rows("SELECT * FROM \(table) ORDER BY rowid") == history[index], "Historical table changed: \(table)") }
        try required(try db.rows("PRAGMA quick_check").first?.values.first == "ok", "Snapshot copy failed integrity check")
        try required(try db.rows("PRAGMA foreign_key_check").isEmpty, "Snapshot copy has foreign key violations")
        print(json(["snapshot_regression": "pass", "unsafe_root_selection_before": unsafe, "current_root_children_retained": original.count,
                    "other_stale_markers_exercised": stale.count, "authoritative_parent": parent, "absent_seed_records_removed": seedIDs.count,
                    "authoritative_cleanup_steps": steps, "remaining_refresh": refresh, "refresh_endpoint_preserved": endpoint,
                    "historical_tables_unchanged": tables, "integrity": "ok", "profile": profile.json]))
    }

    static func benchmark(root: String, state: String) async throws {
        try required(!fm.fileExists(atPath: state), "Benchmark state must be fresh")
        try required(root.hasPrefix("/private/tmp/storage-monitor-benchmark-") && state.hasPrefix("/private/tmp/storage-monitor-benchmark-"), "This harness only accepts bounded synthetic /private/tmp benchmark roots")
        guard let region = coverageRegion(root: root) else { throw Failure("Benchmark is outside startup Data") }
        let folder = URL(fileURLWithPath: state)
        try privateDirectory(folder)
        let path = folder.appendingPathComponent("history.sqlite3").path
        _ = try Database(path)
        let bytesBefore = try fm.attributesOfItem(atPath: path)[.size] as! NSNumber
        let start = Date(), profile = InventoryProfile()
        let result = profile.withScope { runInventory(databasePath: path, directory: folder, region: region, options: InventoryRunOptions(maxDuration: 40), fdaOverride: "granted") }
        let finish = Date(), profileInitial = profile.json, db = try Database(path)
        try required(result.outcome == "complete", "Bounded initial benchmark did not complete: \(result.outcome) \(result.reason ?? "")")
        let kinds = try db.rows("SELECT kind,COUNT(*) AS n FROM inventory_nodes GROUP BY kind")
        let initialTotals = try db.rows("SELECT total_logical,total_allocated FROM inventory_nodes WHERE parent_id IS NULL").first!
        let partialFolder = URL(fileURLWithPath: state + "-partial")
        try privateDirectory(partialFolder)
        let partialPath = partialFolder.appendingPathComponent("history.sqlite3").path
        _ = try Database(partialPath)
        let partial = runInventory(databasePath: partialPath, directory: partialFolder, region: region, options: InventoryRunOptions(maxDuration: 20, stopAfterEntries: 1_000), fdaOverride: "granted")
        let reader = InventoryReader(path: partialPath), partialStatus = try await reader.status()
        let partialRoot = try await reader.root()!
        let partialPage = try await reader.children(parentID: partialRoot.id)
        try required(partialStatus.state != "complete" && !partialPage.items.isEmpty, "Partial inventory is not browsable/truthful")
        try Data(count: 8192).write(to: URL(fileURLWithPath: root + "/folder-000/change"))
        // Real device history replay, not a synthetic event marker. The initial
        // crawl established the cursor; these changes happened afterward.
        try await Task.sleep(for: .milliseconds(300))
        var incrementalPasses = [[String: Any]]()
        for pass in 0..<3 {
            if pass > 0 { try Data(count: 8192 + pass).write(to: URL(fileURLWithPath: root + "/folder-000/change")); try await Task.sleep(for: .milliseconds(200)) }
            let part = InventoryProfile()
            let updated = try part.withScope { () throws -> InventoryRunResult in
                try reconcileInventoryEvents(database: path, directory: folder, region: region)
                return runInventory(databasePath: path, directory: folder, region: region, options: InventoryRunOptions(maxDuration: 20), fdaOverride: "granted")
            }
            incrementalPasses.append(["outcome": updated.outcome, "entries": updated.entries, "profile": part.json])
            try required(updated.outcome == "complete" && updated.entries > 0, "Real event incremental benchmark incomplete or missed update")
        }
        try required(try db.rows("PRAGMA quick_check").first?.values.first == "ok" && db.rows("PRAGMA foreign_key_check").isEmpty, "Benchmark database integrity failed")
        let attributes = try fm.attributesOfItem(atPath: path)
        print(json(["scope": "bounded synthetic, warm filesystem cache; no full-volume benchmark", "start": ISO8601DateFormatter().string(from: start),
                    "finish": ISO8601DateFormatter().string(from: finish), "entries_by_kind": kinds, "initial": profileInitial,
                    "incremental": incrementalPasses, "initial_totals": initialTotals, "peak_memory_bytes": peakMemoryBytes(), "database_bytes": attributes[.size]!, "database_bytes_before": bytesBefore, "database_growth_bytes": (attributes[.size] as! NSNumber).int64Value - bytesBefore.int64Value,
                    "journal_mode": try db.rows("PRAGMA journal_mode"), "wal_bytes": (try? fm.attributesOfItem(atPath: path + "-wal")[.size]) ?? 0,
                    "partial_state": partial.outcome, "partial_browsable_children": partialPage.items.count, "state_directory": state]))
    }
}
