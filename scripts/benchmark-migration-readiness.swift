import Foundation
import Darwin

// Migration Readiness benchmark (headless, read-only toward everything but its own fixture).
//
//   synthetic <work folder>   builds a sparse-file fixture under /private/tmp, indexes it with the real worker, and
//                             times indexing with detection off and on, full and incremental scans, chunk reads,
//                             Inspector rechecks, Migration Review filter activation, and refresh churn.
//   catalog <clone.sqlite3>   times detection over a disposable clone of a real catalog. Prints counts and timings
//                             only; no path or file name is printed.
//
// Default GiB thresholds throughout. Sparse files are made with ftruncate; the fixture's logical size is terabytes but
// it allocates only megabytes. Nothing outside the work folder is written; no app is launched or focused.

#if INVENTORY_TESTS
struct Timings {
    var samples = [Double]()
    mutating func add(_ ms: Double) { samples.append(ms) }
    func percentile(_ p: Double) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))]
    }
    var line: String { String(format: "n=%d p50=%.2f ms p95=%.2f ms max=%.2f ms", samples.count, percentile(0.5), percentile(0.95), samples.max() ?? .nan) }
}

func milliseconds(_ body: () throws -> Void) rethrows -> Double { let s = DispatchTime.now().uptimeNanoseconds; try body(); return Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6 }
func milliseconds(_ body: () async throws -> Void) async rethrows -> Double { let s = DispatchTime.now().uptimeNanoseconds; try await body(); return Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6 }

let benchGiB = SparseStorageThresholds.gibibyte

func buildFixture(_ root: String, folders: Int, filesPerFolder: Int, candidates: Int, bands: Int) throws {
    try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    for f in 0..<folders {
        let folder = "\(root)/tree/g\(f / 50)/f\(f)"
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for i in 0..<filesPerFolder { try Data(count: 512 + i).write(to: URL(fileURLWithPath: "\(folder)/x\(i).dat")) }
    }
    for c in 0..<candidates {
        let folder = "\(root)/images/set\(c / 100)"
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Alternate review-sized (12 GiB) and informational-sized (1.5 GiB) sparse images.
        try makeSparseFile("\(folder)/disk\(c).raw", logical: c % 2 == 0 ? 12 * benchGiB : 3 * benchGiB / 2, written: 4_096)
    }
    let bundle = "\(root)/bundles/Many.sparsebundle"
    try fm.createDirectory(atPath: bundle + "/bands", withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["size": 2_199_023_255_552, "band-size": 8_388_608], format: .xml, options: 0)
    try plist.write(to: URL(fileURLWithPath: bundle + "/Info.plist"))
    for b in 0..<bands { try Data(count: 4_096).write(to: URL(fileURLWithPath: "\(bundle)/bands/\(String(b, radix: 16))")) }
}

func index(_ database: String, _ state: URL, _ region: CoverageRegion) -> InventoryRunResult {
    runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 600), fdaOverride: "granted")
}

@main enum MigrationReadinessBenchmark {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch arguments.first {
            case "synthetic" where arguments.count == 3: try await synthetic(arguments[1], monitor: arguments[2])
            case "catalog" where arguments.count == 2: try await catalog(arguments[1])
            case "indexing" where arguments.count == 4: try await indexing(arguments[1], monitor: arguments[2], runs: Int(arguments[3]) ?? 20)
            default: print("usage: benchmark synthetic <work folder> <monitor executable> | catalog <clone.sqlite3>"); exit(2)
            }
        } catch { print("ERROR \(error)"); exit(1) }
    }

    /// The worker as production runs it: its own process (the monitor's `inventory-work`). A reader and a writer in one
    /// process share POSIX locks and can make the writer fail with "disk I/O error"; that is not the production topology.
    static func workerProcess(_ monitor: String, root: String, state: URL) throws -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: monitor)
        process.arguments = ["inventory-work", "--root", root, "--data-dir", state.path, "--budget", "600"]
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    static func synthetic(_ work: String, monitor: String) async throws {
        let folders = 400, filesPerFolder = 50, candidates = 2_000, bands = 5_000
        let root = work + "/fixture"
        print("fixture: \(folders) folders × \(filesPerFolder) files, \(candidates) sparse candidates (alternating 12 GiB and 1.5 GiB logical), one sparse bundle with \(bands) band files")
        let built = try milliseconds { try buildFixture(root, folders: folders, filesPerFolder: filesPerFolder, candidates: candidates, bands: bands) }
        print(String(format: "fixture built in %.0f ms", built))
        let region = coverageRegion(root: root)!

        // 1. Indexing with detection disabled vs enabled (a detector looping against the same catalog while it is built).
        var off = Timings(), on = Timings(), concurrentPasses = 0, outcomes = [String]()
        for run in 0..<3 {
            for enabled in [false, true] {
                let state = URL(fileURLWithPath: "\(work)/index-\(run)-\(enabled)")
                try privateDirectory(state)
                let database = state.appendingPathComponent("history.sqlite3").path
                let stop = ManagedAtomicFlag()
                var looper: Task<Int, Never>?
                if enabled {
                    looper = Task.detached {
                        var passes = 0
                        while !stop.value {
                            if fm.fileExists(atPath: database) { _ = try? await SparseStorageDetector(database: database, home: nil).refresh(); passes += 1 }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        return passes
                    }
                }
                var result: (status: Int32, output: String)?
                let ms = try milliseconds { result = try workerProcess(monitor, root: root, state: state) }
                stop.set(); concurrentPasses += await looper?.value ?? 0
                let count = (try? Database(database).rows("SELECT COUNT(*) AS n FROM inventory_nodes").first?["n"]) ?? "?"
                let outcome = result?.output.range(of: "\"outcome\":\"[a-z_ ]*\"", options: .regularExpression).map { String(result!.output[$0]) } ?? "?"
                outcomes.append("run \(run) detection \(enabled ? "on" : "off"): exit \(result?.status ?? -1) \(outcome) nodes=\(count)")
                if enabled { on.add(ms) } else { off.add(ms) }
            }
        }
        outcomes.forEach { print("  " + $0) }
        print("indexing (worker process, includes launch), detection disabled: " + off.line)
        print("indexing (worker process, includes launch), detection enabled (a detector refreshing every 50 ms during indexing, \(concurrentPasses) passes): " + on.line)

        let state = URL(fileURLWithPath: "\(work)/index-0-false"), database = state.appendingPathComponent("history.sqlite3").path
        let nodes = try Database(database).rows("SELECT COUNT(*) AS n, MAX(id) AS m FROM inventory_nodes").first!
        print("catalog: \(nodes["n"]!) nodes (max id \(nodes["m"]!))")

        // 2. Full scans over the large hierarchy (fresh detector each time; live lstat included).
        var full = Timings(), report: SparseStorageReport?
        for _ in 0..<7 {
            let detector = SparseStorageDetector(database: database, home: nil, pauseNanoseconds: 0)
            full.add(try await milliseconds { report = try await detector.refresh() })
        }
        print("full detection pass (\(report!.reviewCount) review, \(report!.informationalCount) informational, \(report!.items.count) listed): " + full.line)
        let paced = SparseStorageDetector(database: database, home: nil)
        let pacedMs = try await milliseconds { _ = try await paced.refresh() }
        print(String(format: "full detection pass with the shipped 2 ms pause between slices: %.0f ms", pacedMs))

        // 3. Individual catalog slices (the longest any one read holds the catalog).
        let reader = InventoryReader(path: database)
        var chunks = Timings(), after: Int64 = 0
        while true {
            var chunk: SparseCandidateChunk?
            chunks.add(try await milliseconds { chunk = try await reader.sparseCandidateChunk(after: after, span: 50_000, thresholds: .standard) })
            guard let chunk, chunk.scannedThrough < chunk.maximumID else { break }
            after = chunk.scannedThrough
        }
        for _ in 0..<20 { chunks.add(try await milliseconds { _ = try await reader.sparseCandidateChunk(after: 0, span: 50_000, thresholds: .standard) }) }
        print("one 50,000-id catalog slice: " + chunks.line)

        // 4. Thousands of candidates: hydration cost alone.
        let ids = try await reader.sparseCandidateChunk(after: 0, span: Int64(nodes["m"]!)!, thresholds: .standard).ids
        var hydrate = Timings()
        for _ in 0..<5 { hydrate.add(try await milliseconds { _ = try await reader.sparseCandidateRecords(ids: ids) }) }
        print("hydrating \(ids.count) candidates (path and ancestry each): " + hydrate.line)

        // 5. Repeated Inspector selection.
        let detector = SparseStorageDetector(database: database, home: nil, pauseNanoseconds: 0)
        let warm = try await detector.refresh()
        let target = warm.headline!.id
        var cached = Timings(), forced = Timings()
        for _ in 0..<200 { cached.add(await milliseconds { _ = await detector.recheck(target) }) }
        for _ in 0..<200 { forced.add(await milliseconds { _ = await detector.recheck(target, maximumAge: 0) }) }
        print("Inspector recheck, within 15 s (cached): " + cached.line)
        print("Inspector recheck, forced lstat: " + forced.line)

        // 6. Migration Review filter activation on a real Living Tree of the fixture root.
        let rootID = try Int64(Database(database).rows("SELECT id FROM inventory_nodes WHERE parent_id IS NULL").first!["id"]!)!
        let tree = try await reader.livingTree(rootID: rootID)
        let layout = StructuredExplorerLayout(model: tree, depth: 4)
        let targets = warm.items.filter { $0.severity != .informational }.map { $0.ancestors + [$0.id] }
        var filterOff = Timings(), filterOn = Timings(), highlighted = 0
        for _ in 0..<50 {
            filterOff.add(milliseconds { _ = StructuredExplorerVisibility(layout: layout, model: tree, filter: .init(), selection: nil, migrationTargets: targets) })
            filterOn.add(milliseconds { highlighted = StructuredExplorerVisibility(layout: layout, model: tree, filter: .init(migrationReview: true), selection: nil, migrationTargets: targets).reviewHighlights.count })
        }
        print("visibility, filter off (\(layout.nodes.count) laid-out nodes): " + filterOff.line)
        print("visibility, Migration Review on (\(targets.count) targets, \(highlighted) highlighted): " + filterOn.line)

        // 7. Refresh and reconciliation churn: 50 candidates change per round, the worker relists, the detector catches up.
        var unchanged = Timings(), incremental = Timings(), passes = [String]()
        for round in 0..<7 {
            unchanged.add(try await milliseconds { _ = try await detector.refresh() })
            var touched = [String]()
            for k in 0..<50 {
                let c = (round * 50 + k) * 2 % candidates
                let path = "\(root)/images/set\(c / 100)/disk\(c).raw"
                try makeSparseFile(path, logical: (round % 2 == 0 ? 14 : 12) * benchGiB, written: 8_192)
                touched.append((path as NSString).deletingLastPathComponent)
            }
            try invalidateInventory(databasePath: database, paths: Array(Set(touched)), eventID: nil, gap: false, reason: "Filesystem activity")
            _ = index(database, state, region)
            var pass: SparseStorageReport.Pass = .full
            incremental.add(try await milliseconds { pass = try await detector.refresh().pass })
            passes.append(pass.rawValue)
        }
        let stats = await detector.statistics
        print("pass with no catalog change: " + unchanged.line)
        print("pass after 50 changed candidates (\(Set(passes).sorted().joined(separator: ","))): " + incremental.line)
        print("detector statistics: full scans \(stats.fullScans), incremental \(stats.incrementalPasses), unchanged \(stats.unchangedPasses), slices \(stats.chunkReads), folder reads \(stats.directoryReads), live checks \(stats.liveChecks), cache hits \(stats.liveCacheHits)")
    }

    /// Controlled indexing sample: the worker as its own process, three conditions in rotated order, one CSV line per run.
    ///   none   no detector
    ///   shipped one detector pass when indexing starts (the controller allows at most one per 30 s, five minutes during a first index)
    ///   stress  a detector pass every 50 ms for the whole run (far more than the shipped cadence)
    static func indexing(_ work: String, monitor: String, runs: Int) async throws {
        let root = work + "/fixture"
        try buildFixture(root, folders: 1_200, filesPerFolder: 60, candidates: 2_000, bands: 500)
        print("csv,run,condition,ms,status,outcome,nodes,detector_passes,load1")
        let conditions = ["none", "shipped", "stress"]
        for run in 0..<runs {
            let rotation = run % 3
            let order = run % 2 == 0 ? Array(conditions[rotation...] + conditions[..<rotation]) : Array((conditions[rotation...] + conditions[..<rotation]).reversed())
            for condition in order {
                let state = URL(fileURLWithPath: "\(work)/idx-\(run)-\(condition)")
                try privateDirectory(state)
                let database = state.appendingPathComponent("history.sqlite3").path
                let stop = ManagedAtomicFlag()
                var looper: Task<Int, Never>?
                if condition != "none" {
                    let once = condition == "shipped"
                    looper = Task.detached {
                        var passes = 0
                        while !stop.value {
                            if fm.fileExists(atPath: database), (try? await SparseStorageDetector(database: database, home: nil).refresh()) != nil { passes += 1; if once { break } }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        return passes
                    }
                }
                var load = [Double](repeating: 0, count: 3); getloadavg(&load, 3)
                var result: (status: Int32, output: String)?
                let ms = try milliseconds { result = try workerProcess(monitor, root: root, state: state) }
                stop.set()
                let passes = await looper?.value ?? 0
                let nodes = (try? Database(database).rows("SELECT COUNT(*) AS n FROM inventory_nodes").first?["n"]) ?? nil
                let outcome = result?.output.range(of: "\"outcome\":\"[a-z_ ]*\"", options: .regularExpression).map { String(result!.output[$0]).replacingOccurrences(of: "\"outcome\":", with: "").replacingOccurrences(of: "\"", with: "") } ?? "?"
                print(String(format: "csv,%d,%@,%.1f,%d,%@,%@,%d,%.2f", run, condition, ms, result?.status ?? -1, outcome, nodes ?? "?", passes, load[0]))
                try? fm.removeItem(at: state)
            }
        }
    }

    static func catalog(_ path: String) async throws {
        var full = Timings(), report: SparseStorageReport?, stats = SparseStorageDetector.Statistics()
        for _ in 0..<3 {
            let detector = SparseStorageDetector(database: path, pauseNanoseconds: 0)
            full.add(try await milliseconds { report = try await detector.refresh() })
            stats = await detector.statistics
        }
        print("real catalog clone: \(stats.idsSpanned) ids in \(stats.chunkReads) slices; slowest slice \(String(format: "%.1f", stats.slowestChunkSeconds * 1000)) ms")
        print("full detection pass: " + full.line)
        let shipped = SparseStorageDetector(database: path)
        var unchanged = Timings()
        let pacedMs = try await milliseconds { _ = try await shipped.refresh() }
        for _ in 0..<5 { unchanged.add(try await milliseconds { _ = try await shipped.refresh() }) }
        print(String(format: "full pass with the shipped 2 ms pause: %.0f ms", pacedMs))
        print("pass with no catalog change: " + unchanged.line)
        let r = report!
        print("result: \(r.reviewCount) review, \(r.unknownCount) unknown, \(r.informationalCount) informational; candidates hydrated \(stats.candidatesHydrated), live checks \(stats.liveChecks)")
        var categories = [String: Int]()
        for item in r.items { categories["\(item.severity.rawValue)/\(item.kind.category.rawValue)/\(item.kind.application ?? "-")", default: 0] += 1 }
        for (key, count) in categories.sorted(by: { $0.key < $1.key }) { print("  \(key): \(count)") }
        print("coverage notes:"); r.coverage.notes.forEach { print("  - \($0)") }
    }
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
#endif
