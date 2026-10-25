import Foundation
import Darwin
import SQLite3

// Change-journal benchmark. Run through scripts/benchmark-change-journal.sh, which supplies two APFS clones of
// an existing catalog and a scratch directory under /private/tmp, and removes them afterwards.
// Part 1: the real worker on a synthetic tree, journal off and on (first pass and incremental relists).
// Part 2: worker-shaped SQL write workloads on the large catalog clones (with and without the journal), then
// change-read latency, size-signal reads, retention, visible-branch reloads avoided and viewer memory.

final class Raw {
    var db: OpaquePointer?
    init(_ path: String) { precondition(sqlite3_open(path, &db) == SQLITE_OK); sqlite3_busy_timeout(db, 30_000); exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;") }
    deinit { sqlite3_close(db) }
    func exec(_ sql: String) { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { fatalError("\(sql): \(String(cString: sqlite3_errmsg(db)))") } }
    @discardableResult func run(_ sql: String, _ values: [Int64] = []) -> [[Int64]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { fatalError("\(sql): \(String(cString: sqlite3_errmsg(db)))") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
        var rows = [[Int64]]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { fatalError("\(sql): \(String(cString: sqlite3_errmsg(db)))") }
            rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_int64(statement, $0) })
        }
    }
    func one(_ sql: String, _ values: [Int64] = []) -> Int64 { run(sql, values).first?.first ?? 0 }
    var pages: Int64 { one("PRAGMA page_count") }
}

struct Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}

func footprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}
func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }
func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) { let start = Date(); let value = try body(); return (value, Date().timeIntervalSince(start)) }
func timedAsync<T>(_ body: () async throws -> T) async rethrows -> (T, Double) { let start = Date(); let value = try await body(); return (value, Date().timeIntervalSince(start)) }
func percentiles(_ values: [Double]) -> String {
    let sorted = values.sorted()
    func at(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
    return "p50=\(ms(at(0.5)))ms p95=\(ms(at(0.95)))ms max=\(ms(sorted.last ?? 0))ms n=\(sorted.count)"
}
func report(_ line: String) { print(line); fflush(stdout) }

// MARK: Part 1 — real worker, synthetic tree

func workerBenchmark(scratch: String) {
    let tree = scratch + "/tree"
    for d in 0..<200 {
        let folder = tree + "/d\(d / 20)/e\(d)"
        try! fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for f in 0..<250 { FileManager.default.createFile(atPath: folder + "/f\(f)", contents: f % 10 == 0 ? Data(count: 4_096) : Data()) }
    }
    let region = coverageRegion(root: tree)!
    var results = [String: [Double]]()
    for (round, journal) in [false, true, false, true].enumerated() {
        inventoryChangeJournalDisabledForBenchmark = !journal
        let state = URL(fileURLWithPath: scratch + "/state-\(round)")
        try! privateDirectory(state)
        let database = state.appendingPathComponent("history.sqlite3").path
        _ = try! Database(database)
        let (first, initial) = timed { runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 600), fdaOverride: "granted") }
        let raw = Raw(database)
        let nodes = raw.one("SELECT COUNT(*) FROM inventory_nodes"), pages = raw.pages
        let journalRows = journal ? raw.one("SELECT COUNT(*) FROM inventory_changed_directories") : 0
        let bumps = journal ? raw.one("SELECT sequence FROM inventory_change_clock") : 0
        report("worker initial journal=\(journal) outcome=\(first.outcome) nodes=\(nodes) seconds=\(String(format: "%.2f", initial)) pages=\(pages) journal_rows=\(journalRows) trigger_events=\(bumps)")
        results["initial-\(journal)", default: []].append(initial)
        results["pages-\(journal)", default: []].append(Double(pages))
        var rng = Generator(state: 42)
        var incremental = [Double]()
        let pagesBefore = raw.pages
        for step in 0..<10 {
            var touched = [String]()
            for _ in 0..<5 {
                let d = Int.random(in: 0..<200, using: &rng), folder = tree + "/d\(d / 20)/e\(d)"
                touched.append(folder)
                for f in 0..<3 { try! Data(count: 8_192 * (step + 1)).write(to: URL(fileURLWithPath: folder + "/f\(f * 7)")) }
                for f in 0..<5 { FileManager.default.createFile(atPath: folder + "/new-\(round)-\(step)-\(f)", contents: Data(count: 4_096)) }
                for f in 0..<5 { try? fm.removeItem(atPath: folder + "/new-\(round)-\(step - 1)-\(f)") }
            }
            try! invalidateInventory(databasePath: database, paths: touched, eventID: nil, gap: false, reason: "Filesystem activity")
            let (_, seconds) = timed { runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60), fdaOverride: "granted") }
            incremental.append(seconds)
        }
        var large = [Double]()
        for step in 0..<4 {
            let touched = (0..<50).map { tree + "/d\(($0 * 4 + step) % 200 / 20)/e\(($0 * 4 + step) % 200)" }
            for folder in touched { try! Data(count: 16_384 * (step + 1)).write(to: URL(fileURLWithPath: folder + "/f14")) }
            try! invalidateInventory(databasePath: database, paths: touched, eventID: nil, gap: false, reason: "Filesystem activity")
            large.append(timed { runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60), fdaOverride: "granted") }.1)
        }
        results["large-\(journal)", default: []] += large
        let (_, schema) = timed { for _ in 0..<20 { try! initializeInventorySchema(databasePath: database) } }
        results["schema-\(journal)", default: []].append(schema / 20)
        report("worker large-rounds journal=\(journal) folders_per_round=50 \(percentiles(large)) schema_check=\(ms(schema / 20))ms")
        report("worker incremental journal=\(journal) rounds=10 \(percentiles(incremental)) pages_added=\(raw.pages - pagesBefore) journal_rows=\(journal ? raw.one("SELECT COUNT(*) FROM inventory_changed_directories") : 0) signals=\(journal ? raw.one("SELECT COUNT(*) FROM inventory_size_signals WHERE previous_allocated IS NOT NULL") : 0)")
        results["incremental-\(journal)", default: []] += incremental
        // Undo this round's creations and growth so every round starts from the same tree.
        for d in 0..<200 {
            let folder = tree + "/d\(d / 20)/e\(d)"
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasPrefix("new-") { try? fm.removeItem(atPath: folder + "/" + name) }
            for f in 0..<3 { FileManager.default.createFile(atPath: folder + "/f\(f * 7)", contents: f * 7 % 10 == 0 ? Data(count: 4_096) : Data()) }
        }
    }
    inventoryChangeJournalDisabledForBenchmark = false
    func mean(_ key: String) -> Double { let v = results[key] ?? []; return v.reduce(0, +) / Double(max(1, v.count)) }
    report(String(format: "worker summary large_round_off=%.1fms large_round_on=%.1fms large_overhead=%.1f%% schema_check_off=%.2fms schema_check_on=%.2fms",
                  1000 * mean("large-false"), 1000 * mean("large-true"), 100 * (mean("large-true") / mean("large-false") - 1), 1000 * mean("schema-false"), 1000 * mean("schema-true")))
    report(String(format: "worker summary initial_off=%.2fs initial_on=%.2fs initial_overhead=%.1f%% incremental_mean_off=%.1fms incremental_mean_on=%.1fms incremental_overhead=%.1f%% page_overhead=%.1f%%",
                  mean("initial-false"), mean("initial-true"), 100 * (mean("initial-true") / mean("initial-false") - 1), 1000 * mean("incremental-false"), 1000 * mean("incremental-true"),
                  100 * (mean("incremental-true") / mean("incremental-false") - 1), 100 * (mean("pages-true") / mean("pages-false") - 1)))
}

// MARK: Part 2 — large catalog

enum Workload {
    /// Relists folders in transactions of 32, shaped like a grouped listing commit: the folder goes stale, five files
    /// are rewritten larger, then the folder settles and its ancestor chain is re-summed.
    static func relist(_ raw: Raw, directories: ArraySlice<Int64>, now: Int64) {
        var index = directories.startIndex
        while index < directories.endIndex {
            raw.exec("BEGIN IMMEDIATE")
            for directory in directories[index..<min(directories.endIndex, index + 32)] {
                let complete = raw.one("SELECT status='complete' FROM inventory_nodes WHERE id=?", [directory])
                raw.run("UPDATE inventory_nodes SET status='stale' WHERE id=?", [directory])
                let files = raw.run("SELECT id FROM inventory_nodes WHERE parent_id=? AND kind='file' LIMIT 5", [directory]).map { $0[0] }
                for file in files { raw.run("UPDATE inventory_nodes SET total_allocated=COALESCE(total_allocated,0)+4096,measured_at=? WHERE id=?", [now, file]) }
                let delta = Int64(files.count * 4096)
                raw.run("UPDATE inventory_nodes SET total_allocated=COALESCE(total_allocated,0)+?,status=CASE WHEN ? THEN 'complete' ELSE 'partial' END,measured_at=? WHERE id=?", [delta, complete, now, directory])
                var current = raw.one("SELECT COALESCE(parent_id,0) FROM inventory_nodes WHERE id=?", [directory])
                while current != 0 {
                    raw.run("UPDATE inventory_nodes SET total_allocated=COALESCE(total_allocated,0)+?,measured_at=? WHERE id=?", [delta, now, current])
                    current = raw.one("SELECT COALESCE(parent_id,0) FROM inventory_nodes WHERE id=?", [current])
                }
            }
            raw.exec("COMMIT")
            index += 32
        }
    }
    /// Inserts files under the given folders in transactions of 2,048 entries, then deletes them one leaf at a time in
    /// transactions of 256, as the worker's grouped listings and tombstone cleanup do.
    static func churn(_ raw: Raw, folders: [Int64], count: Int, seed: Int64) -> (insert: Double, delete: Double) {
        var created = [Int64]()
        let (_, insert) = timed {
            var i = 0
            while i < count {
                raw.exec("BEGIN IMMEDIATE")
                for j in i..<min(count, i + 2_048) {
                    let object = raw.one("INSERT INTO inventory_objects(device,inode,birth_ns,kind,logical,allocated,link_count,modified_at,changed_ns) VALUES (-7,?,?,'file',4096,4096,1,0,0) RETURNING id", [Int64(j), seed])
                    created.append(raw.one("INSERT INTO inventory_nodes(generation_id,parent_id,object_id,name,kind,status,total_logical,total_allocated,direct_logical,direct_allocated,seen_token,measured_at) VALUES (1,?,?,'bench-'||?||'-'||?,'file','complete',4096,4096,4096,4096,0,0) RETURNING id", [folders[j % folders.count], object, seed, Int64(j)]))
                }
                raw.exec("COMMIT")
                i += 2_048
            }
        }
        let (_, delete) = timed {
            for start in stride(from: 0, to: created.count, by: 256) {
                raw.exec("BEGIN IMMEDIATE")
                for id in created[start..<min(created.count, start + 256)] { raw.run("DELETE FROM inventory_nodes WHERE id=?", [id]) }
                raw.exec("COMMIT")
            }
            raw.exec("DELETE FROM inventory_objects WHERE device=-7")
        }
        return (insert, delete)
    }
}

func catalogBenchmark(withJournal a: String, withoutJournal b: String) async {
    // Migration of a catalog that predates the journal (and, here, some lifecycle columns).
    for (path, journal) in [(a, true), (b, false)] {
        let before = Raw(path).pages
        inventoryChangeJournalDisabledForBenchmark = !journal
        let (_, seconds) = timed { try! initializeInventorySchema(databasePath: path) }
        report("catalog migration journal=\(journal) seconds=\(String(format: "%.3f", seconds)) pages_before=\(before) pages_after=\(Raw(path).pages)")
    }
    inventoryChangeJournalDisabledForBenchmark = false
    // The clone's first pass predates the completion milestone; mark it complete so size signals are exercised.
    for path in [a, b] { Raw(path).exec("UPDATE inventory_generations SET initial_completion='complete' WHERE active=1") }
    Raw(a).exec(inventorySignalGenerationSyncSQL)
    let rawA = Raw(a), rawB = Raw(b)
    report("catalog nodes=\(rawA.one("SELECT COUNT(*) FROM inventory_nodes")) directories=\(rawA.one("SELECT COUNT(*) FROM inventory_nodes WHERE kind='directory'"))")
    let candidates = rawA.run("SELECT id FROM inventory_nodes INDEXED BY inventory_nodes_kind_id WHERE generation_id=1 AND kind='directory' AND status IN ('complete','partial') AND total_allocated IS NOT NULL AND child_count BETWEEN 5 AND 400").map { $0[0] }
    var rng = Generator(state: 7)
    let chosen = Array(candidates.shuffled(using: &rng).prefix(4_000))
    report("catalog candidate folders=\(candidates.count) chosen=\(chosen.count)")
    let reader = InventoryReader(path: a)
    let startCursor = try! await reader.changes(since: nil).next!

    // Write amplification: identical workloads with and without the journal, alternated.
    var relistTimes = [Bool: Double](), insertTimes = [Bool: Double](), deleteTimes = [Bool: Double](), pageGrowth = [Bool: Int64]()
    for (raw, journal) in [(rawB, false), (rawA, true), (rawB, false), (rawA, true)] {
        let pages = raw.pages
        let (_, relist) = timed { Workload.relist(raw, directories: chosen[0..<2_000], now: 1_800_000_000) }
        let churn = Workload.churn(raw, folders: Array(chosen[2_000..<2_200]), count: 20_000, seed: journal ? 1 : 2)
        relistTimes[journal, default: 0] += relist / 2; insertTimes[journal, default: 0] += churn.insert / 2; deleteTimes[journal, default: 0] += churn.delete / 2
        pageGrowth[journal, default: 0] += raw.pages - pages
    }
    for journal in [false, true] {
        report("catalog writes journal=\(journal) relist_2000_dirs=\(ms(relistTimes[journal]!))ms insert_20000=\(ms(insertTimes[journal]!))ms delete_20000=\(ms(deleteTimes[journal]!))ms pages_added_two_rounds=\(pageGrowth[journal]!)")
    }
    report(String(format: "catalog write overhead relist=%.1f%% insert=%.1f%% delete=%.1f%%", 100 * (relistTimes[true]! / relistTimes[false]! - 1),
                  100 * (insertTimes[true]! / insertTimes[false]! - 1), 100 * (deleteTimes[true]! / deleteTimes[false]! - 1)))
    report("catalog journal rows=\(rawA.one("SELECT COUNT(*) FROM inventory_changed_directories")) signal_rows=\(rawA.one("SELECT COUNT(*) FROM inventory_size_signals")) comparisons=\(rawA.one("SELECT COUNT(*) FROM inventory_size_signals WHERE previous_allocated IS NOT NULL")) trigger_events=\(rawA.one("SELECT sequence FROM inventory_change_clock"))")

    // Change-read latency.
    var latest = [Double](), small = [Double](), backlog = [Double](), lookup = [Double](), signalFeed = [Double]()
    for _ in 0..<200 { let cursor = try! await reader.changes(since: nil).next!; latest.append(try! await timedAsync { try await reader.changes(since: cursor) }.1) }
    var smallCount = 0
    for round in 0..<30 {
        let cursor = try! await reader.changes(since: nil).next!
        Workload.relist(rawA, directories: chosen[(2_200 + round * 10)..<(2_210 + round * 10)], now: 1_800_000_100)
        let (batch, seconds) = try! await timedAsync { try await reader.changes(since: cursor) }
        precondition(batch.complete && !batch.mustResynchronize)
        small.append(seconds); smallCount += batch.changes.count
    }
    for _ in 0..<30 { backlog.append(try! await timedAsync { try await reader.changes(since: startCursor) }.1) }
    let backlogBatch = try! await reader.changes(since: startCursor)
    let signalIDs = rawA.run("SELECT node_id FROM inventory_size_signals WHERE previous_allocated IS NOT NULL LIMIT 512").map { $0[0] }
    for _ in 0..<30 { lookup.append(try! await timedAsync { try await reader.sizeSignals(nodeIDs: signalIDs) }.1) }
    for _ in 0..<30 { signalFeed.append(try! await timedAsync { try await reader.sizeSignals(since: startCursor) }.1) }
    report("catalog read latest-no-change \(percentiles(latest))")
    report("catalog read small-change (10 relisted folders, mean \(smallCount / 30) directories) \(percentiles(small))")
    report("catalog read backlog-page(\(backlogBatch.changes.count) dirs, complete=\(backlogBatch.complete)) \(percentiles(backlog))")
    report("catalog read signals-for-\(signalIDs.count)-nodes \(percentiles(lookup))")
    report("catalog read signal-feed-page \(percentiles(signalFeed))")

    // Visible-branch refresh: the root, its 12 largest folders expanded, and the largest folder inside each.
    var explorer = InventoryExplorerState()
    let root = try! await reader.root()!
    explorer.setRoot(root)
    explorer.receive(parent: root.id, page: try! await reader.explorerChildren(parentID: root.id))
    var deep = [Int64]()
    for folder in (explorer.children[root.id]?.items ?? []).filter({ $0.kind == .directory }).prefix(12) {
        explorer.expand(folder.id); explorer.receive(parent: folder.id, page: try! await reader.explorerChildren(parentID: folder.id))
        if let inner = explorer.children[folder.id]?.items.first(where: { $0.kind == .directory }) {
            explorer.expand(inner.id); explorer.receive(parent: inner.id, page: try! await reader.explorerChildren(parentID: inner.id)); deep.append(inner.id)
        }
    }
    let visible = explorer.reloadPlan
    var tracker = InventoryChangeTracker()
    tracker = tracker.planned(try! await reader.changes(since: nil)).tracker
    var full = [Double]()
    for _ in 0..<3 { full.append(await timedAsync { await InventoryVisibleRefresh.perform(reader: reader, targets: visible, selection: nil, selectionParent: nil, previous: [:]) }.1) }
    var reloaded = 0, avoided = 0, incremental = [Double](), everything = 0, insideVisible = [Int]()
    for round in 0..<40 {
        // Even rounds: activity anywhere in the catalog. Odd rounds: activity in a folder shown in the outline.
        var target = chosen[2_600 + round]
        if round % 2 == 1, let shown = explorer.children[deep[round % deep.count]]?.items.first(where: { $0.kind == .directory && $0.childCount >= 5 })?.id { target = shown }
        Workload.relist(rawA, directories: [target][...], now: 1_800_000_200)
        let (plan, next) = tracker.planned(try! await reader.changes(since: tracker.cursor))
        var targets = [(parent: Int64, count: Int)]()
        switch plan {
        case .none: break
        case .everything: everything += 1; targets = explorer.reloadPlan
        case .folders(let listing, let subtrees): explorer.invalidateCollapsed(listing: listing, subtrees: subtrees); targets = explorer.refreshTargets(listing: listing, subtrees: subtrees)
        }
        let (result, seconds) = await timedAsync { await InventoryVisibleRefresh.perform(reader: reader, targets: targets, selection: nil, selectionParent: nil, previous: [:]) }
        explorer.apply(result)
        tracker = next
        incremental.append(seconds); reloaded += targets.count; avoided += visible.count - targets.count
        if round % 2 == 1 { insideVisible.append(targets.count) }
    }
    report("viewer visible_folders=\(visible.count) full_refresh \(percentiles(full)) rounds=40 folders_reloaded=\(reloaded) folders_avoided=\(avoided) (\(String(format: "%.1f", 100 * Double(avoided) / Double(40 * visible.count)))%) everything_plans=\(everything) reloads_when_change_is_visible=\(insideVisible) incremental_refresh \(percentiles(incremental))")

    // Viewer memory across many polls with small changes: the tracker and explorer state must not grow.
    let memoryBefore = footprint()
    for round in 0..<600 {
        if round % 20 == 0 { Workload.relist(rawA, directories: [chosen[2_700 + round / 20]][...], now: 1_800_000_300) }
        let (plan, next) = tracker.planned(try! await reader.changes(since: tracker.cursor))
        if case .folders(let listing, let subtrees) = plan {
            explorer.apply(await InventoryVisibleRefresh.perform(reader: reader, targets: explorer.refreshTargets(listing: listing, subtrees: subtrees), selection: nil, selectionParent: nil, previous: [:]))
        }
        tracker = next
    }
    let memoryAfter = footprint()
    report("viewer memory polls=600 footprint_before=\(memoryBefore / 1024)KB footprint_after=\(memoryAfter / 1024)KB delta=\((memoryAfter - memoryBefore) / 1024)KB cached_rows=\(explorer.cachedRows) retry=\(tracker.retry.count)")

    // Journal more directories than retention keeps: flip 90,000 distinct folders stale and back in batches of 2,048.
    let many = rawA.run("SELECT id FROM inventory_nodes INDEXED BY inventory_nodes_kind_id WHERE generation_id=1 AND kind='directory' AND status='complete' LIMIT 90000").map { $0[0] }
    let (_, flipSeconds) = timed {
        for start in stride(from: 0, to: many.count, by: 2_048) {
            rawA.exec("BEGIN IMMEDIATE")
            for id in many[start..<min(many.count, start + 2_048)] { rawA.run("UPDATE inventory_nodes SET status='stale' WHERE id=?", [id]); rawA.run("UPDATE inventory_nodes SET status='complete' WHERE id=?", [id]) }
            rawA.exec("COMMIT")
        }
    }
    report("retention workload folders=\(many.count) seconds=\(String(format: "%.2f", flipSeconds))")
    // Retention: prune to the default bound, then confirm an old cursor resynchronizes.
    let beforePrune = rawA.one("SELECT COUNT(*) FROM inventory_changed_directories"), signalsBefore = rawA.one("SELECT COUNT(*) FROM inventory_size_signals")
    let (pruned, pruneSeconds) = timed { try! inventoryPruneChangeJournalForTesting(databasePath: a, retention: InventoryChangeJournalRetention()) }
    let behind = try! await reader.changes(since: startCursor)
    report("retention directories_before=\(beforePrune) signals_before=\(signalsBefore) pruned=\(pruned) seconds=\(String(format: "%.3f", pruneSeconds)) directories_after=\(rawA.one("SELECT COUNT(*) FROM inventory_changed_directories")) signals_after=\(rawA.one("SELECT COUNT(*) FROM inventory_size_signals")) old_cursor_must_resync=\(behind.mustResynchronize)")
}

@main enum ChangeJournalBenchmark {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { fputs("usage: benchmark <scratch> <catalog-with-journal> <catalog-without-journal>\n", stderr); exit(2) }
        if ProcessInfo.processInfo.environment["SKIP_WORKER"] == nil { workerBenchmark(scratch: arguments[1]) }
        if ProcessInfo.processInfo.environment["SKIP_CATALOG"] == nil { await catalogBenchmark(withJournal: arguments[2], withoutJournal: arguments[3]) }
    }
}
