import Foundation
import Darwin
import SQLite3

// Living Tree benchmark. Run through scripts/benchmark-living-tree.sh, which supplies an APFS clone of an existing
// catalog under /private/tmp and removes it afterwards. Modes:
//   prepare <catalog>  installs the change journal on the clone and enables size signals (as the worker would)
//   measure <catalog>  tree construction, read latency, layout, memory, change updates and rapid updates

final class Raw {
    var db: OpaquePointer?
    init(_ path: String) { precondition(sqlite3_open(path, &db) == SQLITE_OK); sqlite3_busy_timeout(db, 30_000); exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;") }
    deinit { sqlite3_close(db) }
    func exec(_ sql: String) { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { fatalError("\(sql): \(String(cString: sqlite3_errmsg(db))) (extended \(sqlite3_extended_errcode(db)), errno \(sqlite3_system_errno(db)))") } }
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
    guard !values.isEmpty else { return "n=0" }
    let sorted = values.sorted()
    func at(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
    return "p50=\(ms(at(0.5)))ms p95=\(ms(at(0.95)))ms max=\(ms(sorted.last!))ms n=\(sorted.count)"
}
func report(_ line: String) { print(line); fflush(stdout) }

/// A grouped listing commit: the folder goes stale, up to five files are rewritten larger, then the folder settles and
/// its ancestor chain is re-summed (the shape of the worker's relist, as in the change-journal benchmark).
func relist(_ raw: Raw, _ directories: [Int64], now: Int64, bytes: Int64 = 4_096) {
    raw.exec("BEGIN IMMEDIATE")
    for directory in directories {
        let complete = raw.one("SELECT status='complete' FROM inventory_nodes WHERE id=?", [directory])
        raw.run("UPDATE inventory_nodes SET status='stale' WHERE id=?", [directory])
        let files = raw.run("SELECT id FROM inventory_nodes WHERE parent_id=? AND kind='file' LIMIT 5", [directory]).map { $0[0] }
        for file in files { raw.run("UPDATE inventory_nodes SET total_allocated=COALESCE(total_allocated,0)+?,measured_at=? WHERE id=?", [bytes, now, file]) }
        let delta = Int64(files.count) * bytes
        raw.run("UPDATE inventory_nodes SET total_allocated=COALESCE(total_allocated,0)+?,status=CASE WHEN ? THEN 'complete' ELSE 'partial' END,measured_at=? WHERE id=?", [delta, complete, now, directory])
        var current = raw.one("SELECT COALESCE(parent_id,0) FROM inventory_nodes WHERE id=?", [directory])
        while current != 0 {
            raw.run("UPDATE inventory_nodes SET total_allocated=COALESCE(total_allocated,0)+?,measured_at=? WHERE id=?", [delta, now, current])
            current = raw.one("SELECT COALESCE(parent_id,0) FROM inventory_nodes WHERE id=?", [current])
        }
    }
    raw.exec("COMMIT")
}

func positions(_ geometry: LivingTreeGeometry) -> [LivingTreeKey: CGPoint] { Dictionary(uniqueKeysWithValues: geometry.branches.map { ($0.key, $0.end) }) }

func measure(_ path: String) async {
    let raw = Raw(path)
    let generation = raw.one("SELECT id FROM inventory_generations WHERE active=1")
    let rootID = raw.one("SELECT id FROM inventory_nodes WHERE generation_id=? AND parent_id IS NULL", [generation])
    report("catalog nodes=\(raw.one("SELECT COUNT(*) FROM inventory_nodes")) directories=\(raw.one("SELECT COUNT(*) FROM inventory_nodes WHERE kind='directory'")) generation=\(generation)")
    let reader = InventoryReader(path: path)
    let size = CGSize(width: 1400, height: 860)

    // Trunks: the volume, and directories of decreasing size along the largest branches (one read each).
    var roots = [rootID], frontier = [rootID]
    while roots.count < 16, !frontier.isEmpty {
        let parent = frontier.removeFirst()
        let children = raw.run("SELECT id FROM inventory_nodes WHERE parent_id=? AND kind='directory' AND status IN ('complete','partial') AND total_allocated IS NOT NULL AND child_count>0 ORDER BY total_allocated DESC LIMIT 3", [parent]).map { $0[0] }
        roots += children.prefix(16 - roots.count); frontier += children
    }
    report("trunks=\(roots.count)")

    // MARK: Construction, read latency and layout
    var volume = [Double](), snapshots = [Double](), spanMeans = [Double](), slowest = [Double](), arranges = [Double](), layouts = [Double](), indexes = [Double](), counts = [Int](), readCounts = [Int]()
    for round in 0..<4 {
        for trunk in roots {
            let tree = try! await reader.livingTree(rootID: trunk)
            var memory = LivingTreeMemory()
            let (arrangement, arrangeSeconds) = timed { LivingTreeArranger.arrange(tree, memory: &memory) }
            let (geometry, layoutSeconds) = timed { LivingTreeGeometer.layout(tree, arrangement, in: size) }
            let (_, indexSeconds) = timed { LivingTreeHitIndex(geometry) }
            if round == 0 && trunk == rootID {
                report("volume tree elements=\(tree.count) branches_drawn=\(geometry.branches.count) reads=\(tree.reads) truncated=\(tree.truncated) first_snapshot=\(ms(tree.snapshotSeconds))ms reads_total=\(ms(tree.readSeconds))ms slowest_read=\(ms(tree.slowestRead))ms max_depth=\(tree.order.map { tree[$0]!.depth }.max() ?? 0)")
            }
            if round == 0 { continue }   // the first round warms the page cache
            if trunk == rootID { volume.append(tree.snapshotSeconds) }
            snapshots.append(tree.snapshotSeconds); spanMeans.append(tree.readSeconds / Double(max(1, tree.reads))); slowest.append(tree.slowestRead)
            arranges.append(arrangeSeconds); layouts.append(layoutSeconds); indexes.append(indexSeconds); counts.append(tree.count); readCounts.append(tree.reads)
        }
    }
    report("construction volume (warm, \(LivingTreeBudget.standard.elements)-element budget) \(percentiles(volume))")
    report("construction all trunks snapshot \(percentiles(snapshots)) elements min=\(counts.min()!) max=\(counts.max()!) reads min=\(readCounts.min()!) max=\(readCounts.max()!)")
    report("sqlite folder read mean-per-tree \(percentiles(spanMeans)); slowest single folder read \(percentiles(slowest))")
    report("layout arrange \(percentiles(arranges)); geometry(1400x860) \(percentiles(layouts)); hit-index \(percentiles(indexes))")

    // MARK: Memory
    let memoryBefore = footprint()
    var retained: (LivingTreeModel, LivingTreeArrangement, LivingTreeGeometry, LivingTreeHitIndex)?
    var memories = [Int64: LivingTreeMemory]()
    for index in 0..<60 {
        let trunk = roots[index % roots.count]
        var memory = memories[trunk] ?? LivingTreeMemory()
        let tree = try! await reader.livingTree(rootID: trunk, memory: memory)
        let arrangement = LivingTreeArranger.arrange(tree, memory: &memory)
        memories[trunk] = memory
        if memories.count > 6 { memories.removeValue(forKey: memories.keys.first { $0 != trunk }!) }
        let geometry = LivingTreeGeometer.layout(tree, arrangement, in: size)
        retained = (tree, arrangement, geometry, LivingTreeHitIndex(geometry))
    }
    let memoryAfter = footprint()
    report("memory 60 rebuilds across \(roots.count) trunks footprint_before=\(memoryBefore / 1024)KB footprint_after=\(memoryAfter / 1024)KB delta=\((memoryAfter - memoryBefore) / 1024)KB retained_elements=\(retained!.0.count) layout_memory_entries=\(memories.values.map(\.entries).reduce(0, +)) trunks_remembered=\(memories.count)")

    // MARK: Change updates (worker-shaped commits beneath the drawn volume tree)
    var memory = LivingTreeMemory()
    let base = try! await reader.livingTree(rootID: rootID, memory: memory)
    let baseGeometry = LivingTreeGeometer.layout(base, LivingTreeArranger.arrange(base, memory: &memory), in: size)
    var light = LivingTreeIllumination()
    light.receive(try? await reader.sizeSignals(since: nil), now: Date())
    let drawnFolders = base.order.compactMap { key -> Int64? in
        guard let element = base[key], element.role == .branch, element.sizeKnown, let id = key.nodeID else { return nil }
        return id
    }
    var rng = Generator(state: 11)
    let touched = Array(drawnFolders.shuffled(using: &rng).prefix(24))
    let (_, writeSeconds) = timed { relist(Raw(path), touched, now: Int64(Date().timeIntervalSince1970), bytes: 16 * 1_048_576) }
    let (batch, changeSeconds) = await timedAsync { try! await reader.changes(since: base.journalCursor) }
    let (decision, decideSeconds) = timed { LivingTreeRefresh.needsRebuild(batch, model: base, ancestors: []) }
    let (rebuilt, rebuildSeconds) = await timedAsync { try! await reader.livingTree(rootID: rootID, memory: memory) }
    var updated = memory
    let (rearranged, arrangeSeconds) = timed { LivingTreeArranger.arrange(rebuilt, memory: &updated) }
    let (newGeometry, layoutSeconds) = timed { LivingTreeGeometer.layout(rebuilt, rearranged, in: size) }
    let (signals, signalSeconds) = await timedAsync { try? await reader.sizeSignals(since: light.cursor) }
    let (outcome, receiveSeconds) = timed { light.receive(signals, now: Date()) }
    let lit = light.glows.keys.filter { rebuilt[.node($0)] != nil }.count
    let before = positions(baseGeometry), after = positions(newGeometry)
    let shared = before.keys.filter { after[$0] != nil }
    let still = shared.filter { before[$0] == after[$0] }.count
    let moved = shared.filter { before[$0] != after[$0] }.map { hypot(before[$0]!.x - after[$0]!.x, before[$0]!.y - after[$0]!.y) }
    report("change update: 24 folders relisted (+80 MB each, commit \(ms(writeSeconds))ms) changes_read=\(ms(changeSeconds))ms rows=\(batch.changes.count) rebuild_needed=\(decision) decide=\(ms(decideSeconds))ms rebuild=\(ms(rebuildSeconds))ms arrange=\(ms(arrangeSeconds))ms geometry=\(ms(layoutSeconds))ms signals_read=\(ms(signalSeconds))ms (\(signals?.signals.count ?? -1) comparisons) illumination=\(ms(receiveSeconds))ms outcome=\(outcome) lit_drawn=\(lit)")
    let visible = moved.filter { $0 >= 0.5 }.sorted()
    report("change stability: elements_kept=\(shared.count)/\(before.count) tips_unmoved=\(still) (\(String(format: "%.1f", 100 * Double(still) / Double(max(1, shared.count))))%) moved_half_point_or_more=\(visible.count) median_of_those=\(String(format: "%.1f", visible.isEmpty ? 0 : visible[visible.count / 2]))pt max=\(String(format: "%.1f", visible.last ?? 0))pt")
    // A single small change: one file in one drawn folder grows by 4 KB.
    memory = updated
    let quiet = try! await reader.livingTree(rootID: rootID, memory: memory)
    var quietMemory = memory
    let quietGeometry = LivingTreeGeometer.layout(quiet, LivingTreeArranger.arrange(quiet, memory: &quietMemory), in: size)
    relist(Raw(path), [touched[0]], now: Int64(Date().timeIntervalSince1970))
    let small = try! await reader.livingTree(rootID: rootID, memory: quietMemory)
    var smallMemory = quietMemory
    let smallGeometry = LivingTreeGeometer.layout(small, LivingTreeArranger.arrange(small, memory: &smallMemory), in: size)
    let q = positions(quietGeometry), s = positions(smallGeometry)
    let unmoved = q.keys.filter { s[$0] == q[$0] }.count
    report("small change stability: tips_unmoved=\(unmoved)/\(q.count) elements_after=\(s.count)")

    // MARK: Rapid updates
    // A writer commits a relist of four drawn folders every 100 ms for 15 s while a viewer follows the controller's
    // policy: a notification every 250 ms, change reads at most once a second, rebuilds at most every 1.5 s.
    // The writer is a separate process, as the inventory worker is: it relists four drawn folders every 100 ms.
    let folderList = drawnFolders.map(String.init).joined(separator: ",")
    @Sendable func writerRun(seconds: Double, viewer: Bool) async -> [Double] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["write", path, String(seconds), viewer ? "5" : "3", folderList]
        process.standardOutput = pipe
        try! process.run()
        while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { Double($0) }
    }
    let alone = await writerRun(seconds: 5, viewer: false)
    report("rapid baseline writer alone commits=\(alone.count) commit \(percentiles(alone))")
    var viewerMemory = memory, viewerTree = try! await reader.livingTree(rootID: rootID, memory: viewerMemory)
    _ = LivingTreeArranger.arrange(viewerTree, memory: &viewerMemory)
    var cursor = viewerTree.journalCursor, viewerLight = light
    var polls = 0, rebuilds = 0, failed = 0, notifications = 0, litMax = 0
    var rebuildTimes = [Double](), pollTimes = [Double]()
    var lastPoll = Date.distantPast, lastBuild = Date(), busy = 0.0
    let startFootprint = footprint()
    var usageStart = rusage(); getrusage(RUSAGE_SELF, &usageStart)
    async let commits = writerRun(seconds: 15, viewer: true)
    let deadline = Date().addingTimeInterval(15)
    var pendingRebuild = false
    while Date() < deadline {
        notifications += 1
        let started = Date()
        if Date().timeIntervalSince(lastPoll) >= 1 {
            lastPoll = Date(); polls += 1
            let (batch, seconds) = await timedAsync { try? await reader.changes(since: cursor) }
            pollTimes.append(seconds)
            if let batch {
                if LivingTreeRefresh.needsRebuild(batch, model: viewerTree, ancestors: []) { pendingRebuild = true } else { cursor = batch.next }
            } else { failed += 1 }
            if let signals = try? await reader.sizeSignals(since: viewerLight.cursor) { viewerLight.receive(signals, now: Date()); litMax = max(litMax, viewerLight.glows.count) } else { failed += 1 }
        }
        if pendingRebuild && Date().timeIntervalSince(lastBuild) >= 1.5 {
            let (result, seconds) = await timedAsync { try? await reader.livingTree(rootID: rootID, memory: viewerMemory) }
            if let result {
                rebuilds += 1; rebuildTimes.append(seconds); lastBuild = Date(); pendingRebuild = false
                viewerTree = result; cursor = result.journalCursor
                _ = LivingTreeArranger.arrange(viewerTree, memory: &viewerMemory)
            } else { failed += 1 }
        }
        busy += Date().timeIntervalSince(started)
        try? await Task.sleep(for: .milliseconds(250))
    }
    let withViewer = await commits
    var usageEnd = rusage(); getrusage(RUSAGE_SELF, &usageEnd)
    func cpu(_ u: rusage) -> Double { Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6 }
    report("rapid updates 15s: writer commits=\(withViewer.count) commit \(percentiles(withViewer)); viewer notifications=\(notifications) polls=\(polls) poll \(percentiles(pollTimes)) rebuilds=\(rebuilds) rebuild \(percentiles(rebuildTimes)) failed_reads=\(failed) glows_max=\(litMax) elements=\(viewerTree.count)")
    report("rapid updates cost: viewer busy=\(ms(busy))ms (\(String(format: "%.1f", 100 * busy / 15))% of wall time) viewer_process_cpu=\(String(format: "%.2f", cpu(usageEnd) - cpu(usageStart)))s over 15 s footprint_start=\(startFootprint / 1024)KB footprint_end=\(footprint() / 1024)KB")
}

@main enum LivingTreeBenchmark {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 6, arguments[1] == "write" {
            // Writer process for the rapid-update measurement: prints each commit's duration in seconds.
            let writer = Raw(arguments[2]), deadline = Date().addingTimeInterval(Double(arguments[3])!)
            var rng = Generator(state: UInt64(arguments[4])!)
            let folders = arguments[5].split(separator: ",").compactMap { Int64($0) }
            while Date() < deadline {
                let chosen = Array(folders.shuffled(using: &rng).prefix(4))
                let (_, seconds) = timed { relist(writer, chosen, now: Int64(Date().timeIntervalSince1970)) }
                print(seconds); fflush(stdout)
                usleep(100_000)
            }
            return
        }
        guard arguments.count == 3, ["prepare", "measure"].contains(arguments[1]) else { fputs("usage: benchmark prepare|measure <catalog clone>\n", stderr); exit(2) }
        let path = arguments[2]
        if arguments[1] == "prepare" {
            let (_, seconds) = timed { try! initializeInventorySchema(databasePath: path) }
            // The clone's first pass predates the completion milestone; mark it complete so size signals are recorded.
            let raw = Raw(path)
            raw.exec("UPDATE inventory_generations SET initial_completion='complete' WHERE active=1")
            raw.exec(inventorySignalGenerationSyncSQL)
            report("prepare journal_installed=\(raw.one("SELECT COUNT(*) FROM sqlite_master WHERE name='inventory_change_clock'")) seconds=\(String(format: "%.3f", seconds))")
        } else {
            await measure(path)
        }
    }
}
