import Foundation
import SQLite3

// Bounded legacy-migration evidence for the first-pass milestone. Run ONLY against disposable
// copies: it migrates the schema and evaluates the completion invariant from durable state.
// It never runs the inventory worker, so nothing on the real filesystem is listed.
@main enum CompletionMigrationVerification {
    static func main() async {
        var reports = [[String: Any]]()
        for path in CommandLine.arguments.dropFirst() {
            do { reports.append(try await verify(path)) }
            catch { reports.append(["database": path, "error": String(describing: error)]) }
        }
        let data = try! JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }

    static func counts(_ db: Database) throws -> [String: String] {
        let hasInventory = try db.rows("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='inventory_nodes'").first?["n"] == "1"
        var result = ["readings": try db.rows("SELECT COUNT(*) AS n FROM readings").first!["n"]!]
        guard hasInventory else { return result }
        let row = try db.rows("""
            SELECT (SELECT COUNT(*) FROM inventory_nodes) AS nodes,(SELECT COUNT(*) FROM inventory_jobs) AS jobs,
                   (SELECT COUNT(*) FROM inventory_jobs WHERE state IN ('pending','enumerating')) AS unfinished_jobs,
                   (SELECT TOTAL(listing_token) FROM inventory_jobs) AS listing_tokens,
                   (SELECT COUNT(*) FROM inventory_reconcile) AS reconcile,(SELECT COUNT(*) FROM inventory_prune_jobs) AS prune_jobs,
                   (SELECT COUNT(*) FROM inventory_tombstones) AS tombstones,(SELECT COUNT(*) FROM inventory_generations) AS generations
            """).first!
        for (key, value) in row { result[key] = value }
        return result
    }

    static func verify(_ path: String) async throws -> [String: Any] {
        let db = try Database(path)
        let before = try counts(db)
        let started = Date()
        try initializeInventorySchema(databasePath: path)
        let migrationSeconds = Date().timeIntervalSince(started)
        let generation = try db.rows("SELECT id FROM inventory_generations WHERE active=1").first.flatMap { Int64($0["id"] ?? "") }
        let afterMigration = try db.rows("SELECT initial_completion FROM inventory_generations WHERE active=1").first?["initial_completion"] ?? "none"
        var recorded = false, checkSeconds = 0.0
        if let generation {
            let began = Date()
            recorded = try recordInitialInventoryCompletionForTesting(databasePath: path, generation: generation)
            checkSeconds = Date().timeIntervalSince(began)
        }
        let blocking = generation == nil ? "0" : try db.rows("SELECT COUNT(*) AS n FROM inventory_jobs WHERE generation_id=? AND state IN ('pending','enumerating') AND completed_token=0", [generation!]).first!["n"]!
        let after = try counts(db)
        let status = try await InventoryReader(path: path).status()
        let integrity = try db.rows("PRAGMA integrity_check").first?.values.first ?? "missing"
        let foreignKeys = try db.rows("PRAGMA foreign_key_check").count
        var preserved = before
        preserved["generations"] = nil
        return ["database": path, "before": before, "after": after,
                "inventory_records_preserved": preserved.allSatisfy { after[$0.key] == $0.value },
                "milestone_after_migration": afterMigration, "recorded_complete": recorded,
                "reader_initial_completion": status.initialCompletion.rawValue,
                "first_listing_jobs_blocking": blocking,
                "migration_seconds": migrationSeconds, "completion_check_seconds": checkSeconds,
                "integrity_check": integrity, "foreign_key_violations": foreignKeys]
    }
}
