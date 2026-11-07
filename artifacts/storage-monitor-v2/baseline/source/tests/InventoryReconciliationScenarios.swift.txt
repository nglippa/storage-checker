import Foundation
import Darwin

#if INVENTORY_TESTS
// Deterministic reconciliation scenarios on real fixtures with real FSEvents replay. Uses only
// API shared with the pre-correction implementation so the same scenarios measure both.
// A "slice" mirrors `inventory-work`: event replay at its start, then a bounded worker run.
struct ReconciliationFixture {
    let root: String, state: URL, database: String, region: CoverageRegion
    let directories: Int

    static func make(_ name: String, directories: Int) throws -> ReconciliationFixture {
        let root = "/private/tmp/storage-monitor-reconcile-\(name)-\(UUID().uuidString)"
        let state = URL(fileURLWithPath: root + "-state")
        for index in 0..<directories {
            let folder = root + "/g\(index / 500)/d\(index)"
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: URL(fileURLWithPath: folder + "/f"))
        }
        try privateDirectory(state)
        let database = state.appendingPathComponent("history.sqlite3").path
        _ = try Database(database)
        let fixture = ReconciliationFixture(root: root, state: state, database: database, region: coverageRegion(root: root)!, directories: directories)
        let initial = runInventory(databasePath: database, directory: state, region: fixture.region, options: InventoryRunOptions(maxDuration: 120), fdaOverride: "granted")
        guard initial.outcome == "complete" else { throw Failure("fixture initial index: \(initial.outcome) \(initial.reason ?? "")") }
        return fixture
    }
    func remove() { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    func folder(_ index: Int) -> String { root + "/g\(index / 500)/d\(index)" }
    /// One new file per listed directory: one changed directory each.
    func touch(_ indexes: [Int], tag: String) throws {
        for index in indexes { try Data([2]).write(to: URL(fileURLWithPath: folder(index) + "/\(tag)")) }
    }
    /// Lets fseventsd persist the changes into replayable history.
    func settle() { Thread.sleep(forTimeInterval: 3) }
    func rows(_ sql: String, _ values: [Any] = []) throws -> [[String: String]] { try Database(database).rows(sql, values) }
    func scalar(_ sql: String, _ values: [Any] = []) throws -> Int64 { Int64(try rows(sql, values).first?.values.first ?? "0") ?? 0 }
    /// An empty boot session applies the wall-clock rule, so the cursor is expired however long this Mac has been awake.
    func expireCursor() throws { try Database(database).write("UPDATE inventory_event_cursor SET acknowledged_at=0,boot_session=''") }
    func reconcile() throws -> (rows: Int64, frontier: Int64, sequence: Int64) {
        let row = try rows("SELECT COUNT(*) AS n,COALESCE(MAX(last_node_id),0) AS f,COALESCE(MAX(request_sequence),0) AS s FROM inventory_reconcile").first!
        return (Int64(row["n"]!)!, Int64(row["f"]!)!, Int64(row["s"]!)!)
    }
    func idle() throws -> Bool {
        try scalar("SELECT (SELECT COUNT(*) FROM inventory_jobs WHERE state IN ('pending','enumerating'))+(SELECT COUNT(*) FROM inventory_reconcile)+(SELECT COUNT(*) FROM inventory_invalidations)") == 0
    }
    /// Catalog agrees with disk: every file on disk is recorded, nothing extra.
    func catalogMatchesDisk() throws -> Bool {
        var files: Int64 = 0
        let enumerator = fm.enumerator(atPath: root)
        while enumerator?.nextObject() != nil { if enumerator?.fileAttributes?[.type] as? FileAttributeType == .typeRegular { files += 1 } }
        return try scalar("SELECT COUNT(*) FROM inventory_nodes n JOIN inventory_generations g ON g.id=n.generation_id AND g.active=1 WHERE n.kind='file'") == files
    }

    struct Slice { let listings: Int64; let entries: Int; let outcome: String; let resetFrontier: Bool; let startedReconciliation: Bool; let frontier: Int64; let commitSeconds: Double; let transactions: Int64 }
    func slice(entryLimit: Int, replayTimeout: TimeInterval? = nil) throws -> Slice {
        let before = try reconcile()
        let profile = InventoryProfile()
        let result: InventoryRunResult = try profile.withScope {
            if let replayTimeout {
                // Deterministic: a real short budget races a fast replay to HistoryDone.
                inventoryReplaySimulatedTimeout = true; defer { inventoryReplaySimulatedTimeout = false }
                try reconcileInventoryEvents(database: database, directory: state, region: region, timeout: replayTimeout)
            }
            else { try reconcileInventoryEvents(database: database, directory: state, region: region) }
            return runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 120, stopAfterEntries: entryLimit), fdaOverride: "granted")
        }
        let after = try reconcile()
        let started = after.rows > 0 && after.sequence != before.sequence
        let reset = started && before.rows > 0 && after.frontier < before.frontier
        return Slice(listings: profile.counts["listings_completed", default: 0], entries: result.entries, outcome: result.outcome, resetFrontier: reset, startedReconciliation: started,
                     frontier: after.frontier, commitSeconds: Double(profile.nanoseconds["transaction_commit", default: 0]) / 1e9, transactions: profile.counts["transactions_committed", default: 0])
    }
    struct Drain { var slices = 0, listings: Int64 = 0, resets = 0, reconciliationsStarted = 0, idle = false, seconds = 0.0, commitSeconds = 0.0, transactions: Int64 = 0 }
    /// Runs slices until idle (or a cap), optionally changing directories before each of the first `activeSlices`.
    func drain(entryLimit: Int, maxSlices: Int, activity: ((Int) throws -> Void)? = nil, activeSlices: Int = 0) throws -> Drain {
        var drain = Drain(); let began = Date()
        for number in 0..<maxSlices {
            if let activity, number < activeSlices { try activity(number); settle() }
            let slice = try slice(entryLimit: entryLimit)
            drain.slices += 1; drain.listings += slice.listings; drain.commitSeconds += slice.commitSeconds; drain.transactions += slice.transactions
            if slice.resetFrontier { drain.resets += 1 }
            if slice.startedReconciliation { drain.reconciliationsStarted += 1 }
            if number >= activeSlices - 1, try idle() { drain.idle = true; break }
        }
        drain.seconds = Date().timeIntervalSince(began)
        return drain
    }
}

func peakResidentBytes() -> Int64 { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Int64(usage.ru_maxrss) }

/// The measured scenarios (also asserted by the regression suite on the corrected code).
func reconciliationScenarios(directories: Int = 12_000) throws -> [String: Any] {
    var report = [String: Any]()
    let fixture = try ReconciliationFixture.make("scenarios", directories: directories)
    defer { fixture.remove() }
    func entry(_ drain: ReconciliationFixture.Drain, _ extra: [String: Any] = [:]) throws -> [String: Any] {
        var value: [String: Any] = ["slices": drain.slices, "directory_listings": drain.listings, "frontier_resets": drain.resets,
                                    "full_reconciliations_started": drain.reconciliationsStarted, "reached_idle": drain.idle,
                                    "seconds": (drain.seconds * 100).rounded() / 100, "commit_seconds": (drain.commitSeconds * 1000).rounded() / 1000,
                                    "transactions": drain.transactions, "catalog_matches_disk": try fixture.catalogMatchesDisk()]
        for (key, item) in extra { value[key] = item }
        return value
    }
    let limit = 6_000

    // 1. High event volume without loss: 4,500 changed directories (> 4,096) in one interval.
    try fixture.touch(Array(stride(from: 0, to: 9_000, by: 2)), tag: "high")
    fixture.settle()
    report["high_volume_4500_changed"] = try entry(try fixture.drain(entryLimit: limit, maxSlices: 20))

    // 2. Slow replay without loss: the replay deadline passes before history is delivered.
    try fixture.touch(Array(0..<50), tag: "slow")
    fixture.settle()
    let slow = try fixture.slice(entryLimit: limit, replayTimeout: 0.000_1)
    var slowDrain = try fixture.drain(entryLimit: limit, maxSlices: 20)
    slowDrain.slices += 1; slowDrain.listings += slow.listings
    report["slow_replay_50_changed"] = try entry(slowDrain, ["timed_out_slice_started_full_reconciliation": slow.startedReconciliation,
                                                            "slow_files_captured": try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name='slow'")])

    // 3. Sustained activity: 4,200 changed directories before each of six slices, then quiet.
    report["sustained_activity_6_slices_x_4200"] = try entry(try fixture.drain(entryLimit: limit, maxSlices: 40, activity: { number in
        try fixture.touch(Array(stride(from: number % 2, to: 8_400, by: 2)), tag: "sustained\(number)")
    }, activeSlices: 6))

    // 4–6. Genuine loss, slice and process interruption, then a second genuine loss mid-pass.
    try fixture.expireCursor()
    let first = try fixture.slice(entryLimit: 4_000)
    let second = try fixture.slice(entryLimit: 4_000)   // a new run: no in-memory state carried over
    try fixture.expireCursor()
    let third = try fixture.slice(entryLimit: 4_000)
    var loss = try fixture.drain(entryLimit: limit, maxSlices: 40)
    loss.slices += 3; loss.listings += first.listings + second.listings + third.listings
    report["genuine_loss_with_interruptions_and_second_gap"] = try entry(loss, [
        "loss_started_full_reconciliation": first.startedReconciliation,
        "frontier_after_slice_1": first.frontier, "frontier_after_slice_2": second.frontier, "frontier_persisted_across_runs": second.frontier > first.frontier,
        "second_gap_reset_frontier": third.resetFrontier])

    // 7–8. Changes behind and ahead of a reconciliation frontier are both captured.
    try fixture.expireCursor()
    let partial = try fixture.slice(entryLimit: 3_000)
    try fixture.touch([10, directories - 10], tag: "frontier")
    fixture.settle()
    var frontierDrain = try fixture.drain(entryLimit: limit, maxSlices: 40)
    frontierDrain.slices += 1; frontierDrain.listings += partial.listings
    report["changes_behind_and_ahead_of_frontier"] = try entry(frontierDrain, ["frontier_when_changed": partial.frontier,
        "changed_files_captured": try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name='frontier'")])

    report["fixture_directories"] = directories
    report["peak_resident_bytes"] = peakResidentBytes()
    return report
}
#endif
