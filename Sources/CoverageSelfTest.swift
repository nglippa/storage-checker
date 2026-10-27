import Foundation
import CoreServices
import Darwin
import SQLite3

// Comprehensive coverage tests. Everything runs on synthetic fixtures in a fresh folder under
// /private/tmp (FSEvents records it); no real user file is created, changed or removed.
func coverageSelfTest(_ test: (Bool, String) throws -> Void) throws {
    let sandbox = monitorSelfTestFixture("coverage").path
    let dataDir = URL(fileURLWithPath: sandbox + "-state")
    var mounted = false
    defer {
        _ = chmod(sandbox + "/home/locked", 0o700)
        if mounted { _ = try? run("/usr/bin/hdiutil", ["detach", sandbox + "/mnt", "-force"], timeout: 30) }
        finishMonitorSelfTestFixture(URL(fileURLWithPath: sandbox)); finishMonitorSelfTestFixture(dataDir); finishMonitorSelfTestFixture(URL(fileURLWithPath: sandbox + "-image.dmg"))
    }
    func dir(_ path: String) throws { try fm.createDirectory(atPath: sandbox + "/" + path, withIntermediateDirectories: true) }
    func write(_ path: String, _ bytes: Int) throws { try Data(count: bytes).write(to: URL(fileURLWithPath: sandbox + "/" + path)) }
    func append(_ path: String, _ bytes: Int) throws { let h = try FileHandle(forWritingTo: URL(fileURLWithPath: sandbox + "/" + path)); try h.seekToEnd(); try h.write(contentsOf: Data(count: bytes)); try h.close() }

    // 1. Path identity: firmlinks and the Data volume path name the same object.
    let links = parseFirmlinks("/Users\tUsers\n/usr/local\tusr/local\n/System/Library/Caches\tSystem/Library/Caches\n/private\tprivate\n")
    try test(dataRelative("/Users/a/x", links: links) == "Users/a/x" && dataRelative("/System/Volumes/Data/Users/a/x", links: links) == "Users/a/x", "firmlinked and Data-volume spellings map to one key")
    try test(dataRelative("/System/Library/Frameworks", links: links) == nil && dataRelative("/usr/bin", links: links) == nil && dataRelative("/usr/local/bin", links: links) == "usr/local/bin" && dataRelative("/System/Library/Caches/x", links: links) == "System/Library/Caches/x", "sealed system volume paths are outside coverage; nested firmlinks resolve")
    try test(displayPath("Users/a", links: links) == "/Users/a" && displayPath(".Spotlight-V100", links: links) == "/System/Volumes/Data/.Spotlight-V100", "display uses the firmlinked form, else the Data volume path")
    if let real = startupDataRegion(nil).region {
        try test(real.mount == dataVolumeMount && real.prefix.isEmpty && real.relative(fromDevice: "Users/x/y") == "Users/x/y", "startup region is the whole mounted Data volume")
        let foreign = Reading(timestamp: 0, container: "c", free: 1, used: 1, volumes: "[{\"DeviceIdentifier\":\"disk99s9\",\"Roles\":[\"Data\"],\"CapacityInUse\":1}]")
        try test(startupDataRegion(foreign).region == nil && startupDataRegion(foreign).reason?.contains("not the measured container") == true, "a Data volume outside the measured container is refused")
    }

    // Without Full Disk Access, prompting and app-data folders are never opened.
    let homeGate = consentGatedPaths(CoverageRegion(mount: dataVolumeMount, prefix: "", device: 0, deviceIdentifier: "t"), homePath: "/Users/a")
    try test(["Users/a/Documents", "Users/a/Music", "Users/a/Pictures", "Users/a/Library/Mail", "Users/a/Library/Containers", "Users/a/Library/Application Support/Google", "Users/a/Library/Application Support/Claude"].allSatisfy(homeGate.contains), "without Full Disk Access, consent and app-data folders are gated")
    try test(!["Users/a/Library", "Users/a/Library/Caches", "Users/a/Projects", "Users/a/Library/Caches/x"].contains(where: homeGate.contains) && homeGate.contains("Users/a/Library/Application Support"), "caches, developer data and ordinary home folders stay measurable; Application Support is not even listed")
    let provenGate = consentGatedPaths(CoverageRegion(mount: dataVolumeMount, prefix: "", device: 0, deviceIdentifier: "t"), homePath: "/Users/a", provenReadable: ["/Users/a/Library/Application Support/Claude"])
    try test(!provenGate.contains("Users/a/Library/Application Support") && !provenGate.contains("Users/a/Library/Application Support/Claude") && provenGate.contains("Users/a/Library/Application Support/Google"), "only app-data folders this monitor already reads are opened without Full Disk Access")

    // Fixture.
    for path in ["apps/App1", "apps/App2", "repl", "big", "home/Documents", "home/Library/Caches/c1", "home/locked", "home/empty", "loops", "hard", "mnt"] { try dir(path) }
    try write("apps/App1/payload.bin", 3_000_000); try write("apps/App2/lib.bin", 500_000); try write("repl/lib.bin", 500_000)
    for d in 0..<4 { try dir("big/d\(d)"); for f in 0..<20 { try write("big/d\(d)/f\(f)", 10) } }
    for f in 0..<20 { try write("big/top\(f)", 10) }
    try write("home/Documents/secret.bin", 4_000_000)
    try write("home/Library/Caches/c1/x.bin", 1_000_000)
    try write("home/locked/hidden.bin", 2_000_000)
    _ = chmod(sandbox + "/home/locked", 0)
    try fm.createSymbolicLink(atPath: sandbox + "/loops/a", withDestinationPath: "b"); try fm.createSymbolicLink(atPath: sandbox + "/loops/b", withDestinationPath: "a")
    try fm.createSymbolicLink(atPath: sandbox + "/loops/self", withDestinationPath: "."); try fm.createSymbolicLink(atPath: sandbox + "/loops/up", withDestinationPath: "..")
    try fm.createSymbolicLink(atPath: sandbox + "/loops/to-big", withDestinationPath: sandbox + "/big")
    try write("hard/one.bin", 2_000_000); _ = link(sandbox + "/hard/one.bin", sandbox + "/hard/two.bin")
    // A separate filesystem mounted inside the covered tree (a 4 MB disk image).
    let image = try run("/usr/bin/hdiutil", ["create", "-size", "4m", "-fs", "HFS+", "-volname", "SMCoverageTest", "-layout", "NONE", sandbox + "-image.dmg"], timeout: 60)
    if image.status == 0 { mounted = (try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", sandbox + "/mnt", sandbox + "-image.dmg"], timeout: 60)).status == 0 }
    if mounted { try? Data(count: 1_000_000).write(to: URL(fileURLWithPath: sandbox + "/mnt/inside.bin")) }

    guard let region = coverageRegion(root: sandbox) else { throw Failure("FAIL: sandbox is not on the Data volume") }
    try privateDirectory(dataDir)
    let dbPath = dataDir.appendingPathComponent("history.sqlite3").path
    let gated: ConsentGate = ["home/Documents"]
    var options = InitializerOptions(); options.pause = 0; options.coverageSplit = 50
    func initialize(_ o: InitializerOptions? = nil) -> (outcome: String, lifecycle: CoverageLifecycle?) {
        initializeCoverage(dbPath: dbPath, directory: dataDir, region: region, options: o ?? options, fdaOverride: "not_granted", gatedOverride: gated)
    }
    func store() -> CoverageStore { (try? Database(dbPath)).flatMap { try? CoverageStore.load($0) } ?? CoverageStore() }
    func unit(_ path: String) -> CoverageUnit? { let s = store(); return s.byPath[path].flatMap { s[$0] } }
    func check(_ id: Int64, previous: Int64?, gap: Bool = false, budget: TimeInterval = 25, checkEntries: Int64 = coverageCheckEntries, lockWait: TimeInterval = 45) throws -> [String: Any] {
        let db = try Database(dbPath)          // reopened every time, as separate launchd runs do
        Thread.sleep(forTimeInterval: 1.2)     // let fseventsd record the preceding changes
        return collectCoverageEvidence(db: db, readingId: id, readingTime: Date().timeIntervalSince1970, previous: previous.map { (id: $0, time: 0) }, marker: currentEventMarker(sandbox), region: region,
                                       budget: budget, simulateGap: gap, lockPath: dataDir.appendingPathComponent("attribution.lock").path, lockWait: lockWait, fdaOverride: "not_granted", gatedOverride: gated, checkEntries: checkEntries) ?? [:]
    }
    func folders(_ e: [String: Any]) -> [String: Any] { e["folders"] as? [String: Any] ?? [:] }
    func coverage(_ e: [String: Any]) -> [String: Any] { e["coverage"] as? [String: Any] ?? [:] }
    func changes(_ e: [String: Any]) -> [[String: Any]] { folders(e)["changes"] as? [[String: Any]] ?? [] }
    func change(_ e: [String: Any], _ rel: String) -> [String: Any]? { changes(e).first { $0["rel"] as? String == rel } }
    func delta(_ c: [String: Any]?, _ kind: String = "logical") -> Int64 { guard let c else { return 0 }; return int64(c["after_" + kind]) - int64(c["before_" + kind]) }

    // 2. Interrupted, then resumed initialization.
    var interrupt = options; interrupt.stopAfterMeasurements = 3
    let partial = initialize(interrupt)
    try test(partial.outcome == "interrupted" && partial.lifecycle?.state == "initializing" && (partial.lifecycle?.actionable ?? 0) > 0, "interrupted initialization checkpoints progress and stays initializing")
    let measuredBefore = store().units.values.filter { $0.state == "baselined" }.count
    let resumed = initialize()
    try test(resumed.outcome == "terminal" && resumed.lifecycle?.actionable == 0 && resumed.lifecycle?.establishedAt != nil, "resumed initialization reaches a terminal state (\(resumed.lifecycle?.state ?? "?"))")
    try test(measuredBefore >= 1 && (resumed.lifecycle?.initializer?.measurements ?? 0) < store().count + 3, "resume continues from the checkpoint instead of starting over")
    let again = initialize()
    try test(again.outcome == "terminal" && again.lifecycle?.initializer?.measurements == 0, "a finished initialization has no repeat work")

    // 3. Partition, boundaries and holes.
    try test(unit("big")?.kind == "split" && (0..<4).allSatisfy { unit("big/d\($0)")?.state == "baselined" }, "a large subtree is split into subdirectory units")
    let big = unit("big")!
    try test(big.aggFiles == 100 && big.files == 20 && big.aggLogical == 1000, "ancestor aggregate = own files + child units (100 files, 1,000 bytes)")
    let root = unit("")!, members = store().units.values.filter { !$0.isHole }
    try test(root.aggLogical == members.reduce(0) { $0 + $1.logical } && root.aggFiles == members.reduce(0) { $0 + $1.files }, "units are disjoint: the root total is the sum of every unit, nothing counted twice")
    if mounted {
        try test(unit("mnt")?.state == "excluded" && unit("mnt")?.reason?.hasPrefix("filesystem:") == true && root.aggLogical < 20_000_000, "a separate filesystem mounted inside is excluded and never walked")
    } else { print("SKIP mounted filesystem boundary (hdiutil unavailable)") }
    try test(unit("home/locked")?.state == "inaccessible" && unit("home/locked")?.reason == "permissions", "unreadable folder recorded as inaccessible with its reason")
    let emptyWalk = walkUnit(region, "home/empty", isUnit: { _ in false }, gated: [], ownOnly: false, maxEntries: 100, deadline: Date().addingTimeInterval(5))
    let lockedWalk = walkUnit(region, "home/locked", isUnit: { _ in false }, gated: [], ownOnly: false, maxEntries: 100, deadline: Date().addingTimeInterval(5))
    try test(emptyWalk.status == .complete && emptyWalk.entries == 0 && lockedWalk.status == .denied && lockedWalk.error == EACCES && (unit("home")?.aggHoles ?? 0) >= 2, "an empty folder is measured (0 bytes), never confused with an inaccessible one")
    try test(unit("home/Documents")?.state == "inaccessible" && unit("home/Documents")?.reason == "consent" && root.aggLogical < 15_000_000, "consent-gated folder is not opened without Full Disk Access and is reported")
    let hardWalk = walkUnit(region, "hard", isUnit: { _ in false }, gated: [], ownOnly: false, maxEntries: 100, deadline: Date().addingTimeInterval(5))
    try test(hardWalk.status == .complete && hardWalk.logical == 2_000_000 && hardWalk.hardLinks == 1, "a hard-linked file is counted once")
    let loopWalk = walkUnit(region, "loops", isUnit: { _ in false }, gated: [], ownOnly: false, maxEntries: 100, deadline: Date().addingTimeInterval(5))
    try test(loopWalk.status == .complete && loopWalk.entries == 5 && loopWalk.logical == 0, "symlink loops and symlinks to folders are not followed (5 entries, 0 bytes)")
    let lifecycle = decodeCoverageLifecycle(try Database(dbPath))!
    try test(lifecycle.state == "partial" && lifecycle.inaccessible >= 2 && lifecycle.notes.contains { $0.path.hasSuffix("home/locked") && !$0.detail.isEmpty }, "coverage reports partial, never complete, while regions are inaccessible (\(lifecycle.inaccessible) inaccessible)")

    // 4. First scheduled check: a baseline only, no growth from first measurements.
    let first = try check(1, previous: nil)
    try test(folders(first)["status"] as? String == "baseline_only" && changes(first).isEmpty && coverage(first)["scope"] as? String == "comprehensive", "first comprehensive check is a baseline; nothing reported as growth")
    try test((folders(first)["measured"] as? Int ?? 99) <= 2 && (folders(first)["carried"] as? Int ?? 0) >= 8, "initializer values are trusted without re-walking (\(folders(first)["measured"] ?? -1) measured, \(folders(first)["carried"] ?? -1) carried)")
    let epochs = try Database(dbPath).rows("SELECT scope, reading_id FROM coverage_epochs")
    try test(epochs.count == 1 && epochs[0]["scope"] == "comprehensive" && epochs[0]["reading_id"] == "1", "the reading where comprehensive coverage began is recorded")

    // 5. Changes between readings.
    try append("home/Library/Caches/c1/x.bin", 3_000_000)                                   // growth
    try fm.removeItem(atPath: sandbox + "/repl/lib.bin"); try write("repl/lib2.bin", 2_500_000)   // replaced
    try dir("big/created"); try write("big/created/new.bin", 2_000_000)                     // new directory
    try fm.moveItem(atPath: sandbox + "/big/d1", toPath: sandbox + "/big/d1-renamed")          // directory rename
    try fm.moveItem(atPath: sandbox + "/apps/App1/payload.bin", toPath: sandbox + "/big/d3/payload.bin")   // move between units
    // Written through the Data volume path: must land in the same unit as the firmlinked path.
    try Data(count: 1_500_000).write(to: URL(fileURLWithPath: region.mount + "/" + region.deviceRelative("big/d0/via-data-path.bin")))
    let second = try check(2, previous: 1)
    if ProcessInfo.processInfo.environment["COVERAGE_TEST_DEBUG"] != nil { print(json(["folders": folders(second), "activity": second["file_activity"] ?? [:]])) }
    let grewC1 = changes(second).first { ($0["rel"] as? String ?? "").hasPrefix("home") && delta($0) == 3_000_000 }
    try test(grewC1?["kind"] as? String == "grew", "file growth measured exactly (+3,000,000 bytes)")
    try test(change(second, "big/created")?["kind"] as? String == "new" && delta(change(second, "big/created")) == 2_000_000, "directory created during the interval reported as new")
    try test(change(second, "big/d1-renamed").map { $0["kind"] as? String == "moved" && delta($0) == 0 } ?? true, "directory rename keeps its identity: no growth, no loss")
    try test(unit("big/d1") == nil && unit("big/d1-renamed")?.state == "baselined" && !changes(second).contains { $0["kind"] as? String == "removed" && $0["rel"] as? String == "big/d1" }, "renamed unit is re-keyed, not reported as removed")
    let out = changes(second).first { ($0["rel"] as? String ?? "").hasPrefix("apps") && delta($0) <= -3_000_000 }, into = change(second, "big/d3")
    try test(out?["kind"] as? String == "moved_out" && into?["kind"] as? String == "moved_in", "file moved between units is paired as a move, not new storage")
    try test(delta(change(second, "big/d0")) == 1_500_000, "write through /System/Volumes/Data attributed to the same unit as its firmlinked path")
    let bigChanges = changes(second).filter { ($0["rel"] as? String ?? "").hasPrefix("big/") && ["big/created", "big/d3"].contains($0["rel"] as? String ?? "") }
    let growth = concentration(bigChanges, region: region, growth: true)
    try test(bigChanges.count == 2 && growth?["path"] as? String == region.display("big/created") && int64(growth?["total"]) == int64(growth?["allocated"]), "moves are excluded from measured growth and its concentration")
    try test(folders(second)["status"] as? String == "complete" && coverage(second)["level"] as? String == "comprehensive", "continuous history: interval coverage is comprehensive across accessible units")
    try test((folders(second)["measured"] as? Int ?? 99) <= 10 && (folders(second)["carried"] as? Int ?? 0) >= 3, "only changed units are re-measured (\(folders(second)["measured"] ?? -1) measured)")
    try test(delta(change(second, "repl")) == 2_000_000 && change(second, "repl")?["kind"] as? String == "grew", "file deleted and replaced: net change measured (+2,000,000 bytes)")
    try test(json(second).utf8.count < 32_000, "evidence row is bounded (\(json(second).utf8.count) bytes)")

    // 6. Quiet interval.
    let quiet = try check(3, previous: 2)
    try test(changes(quiet).isEmpty && (folders(quiet)["concentration"] as? [String: Any])?["growth"] is NSNull, "no measured change: no attribution is invented")

    // 7. Newly discovered region (became readable): a baseline, never new storage.
    _ = chmod(sandbox + "/home/locked", 0o700)
    let db7 = try Database(dbPath), s7 = try CoverageStore.load(db7)
    if let id = s7.byPath["home/locked"] { s7.modify(id) { $0.lastAttempt = Date().timeIntervalSince1970 - 2 * 86400 } }
    try s7.save(db7)
    _ = initialize()
    let discovered = try check(4, previous: 3)
    try test(unit("home/locked")?.state == "baselined" && change(discovered, "home/locked") == nil && (folders(discovered)["first_measurements"] as? Int ?? 0) >= 1, "a newly readable folder is a first measurement, not growth")

    // 8. Gap in file history: nothing carried, coverage degraded, then reconciled.
    try write("big/d2/during-gap.bin", 2_000_000)
    let gapped = try check(5, previous: 4, gap: true, budget: 0.05)
    try test(folders(gapped)["carried"] as? Int == 0 && folders(gapped)["status"] as? String == "partial" && coverage(gapped)["level"] as? String == "partial", "FSEvents gap: no unit assumed unchanged; interval coverage partial")
    try test(decodeCoverageLifecycle(try Database(dbPath))?.state == "degraded" && store().units.values.contains { $0.state == "reconcile" || $0.state == "pending" }, "gap leaves reconciliation work and reports degraded coverage")
    let repaired = initialize()
    try test(repaired.outcome == "terminal" && repaired.lifecycle?.actionable == 0 && repaired.lifecycle?.state == "partial", "background reconciliation repairs coverage after a gap (\(repaired.lifecycle?.state ?? "?"))")
    try test(unit("big/d2")?.logical == 2_000_200, "change during the gap is captured by re-measurement")

    // 9. Event database replaced (restart with a different FSEvents UUID): nothing trusted.
    let db9 = try Database(dbPath)
    if var l = decodeCoverageLifecycle(db9) { l.eventDevice = "00000000-0000-0000-0000-000000000000"; saveCoverageLifecycle(db9, l) }
    let replaced = try check(6, previous: 5, budget: 0.05)
    try test((replaced["file_activity"] as? [String: Any])?["status"] as? String == "unavailable" && folders(replaced)["carried"] as? Int == 0, "changed event database: history not replayed, nothing carried forward")
    _ = initialize()
    // Restart replay: changes made while no check ran are found from the durable cursor.
    _ = try check(7, previous: 6)
    try write("apps/App1/while-stopped.bin", 2_000_000)
    let afterRestart = try check(8, previous: 7)
    try test(delta(changes(afterRestart).first { ($0["rel"] as? String ?? "").hasPrefix("apps") }) == 2_000_000 && (afterRestart["file_activity"] as? [String: Any])?["status"] as? String == "complete", "event replay after restart finds changes made between runs")

    // 10. Budget enforcement: many changed units, tiny budget.
    for d in [0, 2, 3] { try write("big/d\(d)/burst.bin", 1_100_000) }; try write("apps/App2/burst.bin", 1_100_000); try write("home/Library/Caches/c1/burst.bin", 1_100_000)
    let clock = Date()
    let bounded = try check(9, previous: 8, budget: 0.001)
    let elapsed = Date().timeIntervalSince(clock) - 1.2
    try test(elapsed < 5 && (folders(bounded)["pending"] as? Int ?? 0) >= 3 && folders(bounded)["status"] as? String == "partial", "scheduled check stops at its budget and defers the rest (\(String(format: "%.2f", elapsed)) s, \(folders(bounded)["pending"] ?? -1) pending)")
    try test(coverageNeedsWork(try Database(dbPath)), "deferred work wakes the background job")
    _ = initialize()

    // 11. Partial measurement: a unit that keeps timing out is deferred, never compared.
    var slow = options; slow.perChildBudget = 0
    let db11 = try Database(dbPath), s11 = try CoverageStore.load(db11)
    if let id = s11.byPath["big/d0"] { for _ in 0..<600 { fm.createFile(atPath: sandbox + "/big/d0/n\(UUID().uuidString)", contents: nil) }; s11.modify(id) { $0.state = "pending" } }
    try s11.save(db11)
    for _ in 0..<3 { _ = initialize(slow); let d = try Database(dbPath), st = try CoverageStore.load(d); if let id = st.byPath["big/d0"], st[id]?.state != "deferred" { st.modify(id) { $0.lastAttempt = 0 }; try st.save(d) } }
    try test(unit("big/d0")?.state == "deferred" && unit("big/d0")?.complete == false && unit("big/d0")?.reason == "timed_out", "repeatedly timed-out unit is deferred and never marked complete")
    let withDeferred = try check(10, previous: 9)
    try test(change(withDeferred, "big/d0") == nil && (decodeCoverageLifecycle(try Database(dbPath))?.deferred ?? 0) == 1, "deferred unit is excluded from comparison and counted")

    // 12. A unit that grows past the check's walk cap is divided by the background job.
    try test(unit("repl")?.kind == "tree", "fixture: repl is measured as one recursive unit")
    for f in 0..<150 { try write("repl/many-\(f)", 10) }
    let e11 = try check(11, previous: 10, checkEntries: 100)
    if ProcessInfo.processInfo.environment["COVERAGE_TEST_DEBUG"] != nil { print("DEBUG11", String(describing: unit("repl")), json(folders(e11)["incomparable"] ?? []), folders(e11)["measured"] ?? -1, (e11["file_activity"] as? [String: Any])?["status"] ?? "?") }
    try test(unit("repl")?.needsSplit == true && unit("repl")?.complete == false, "a unit larger than the check's cap is flagged for splitting, not walked endlessly")
    _ = initialize()
    try test(unit("repl")?.kind == "split" && unit("repl")?.needsSplit == false && unit("repl")?.state == "baselined", "the background job splits it")

    // 13. Open-but-deleted files are reported separately.
    try write("apps/App2/held.bin", 3_000_000)
    let holder = Process(); holder.executableURL = URL(fileURLWithPath: "/bin/sh"); holder.arguments = ["-c", "exec 3<'\(sandbox)/apps/App2/held.bin'; exec /bin/sleep 30"]
    try holder.run(); defer { holder.terminate(); holder.waitUntilExit() }
    Thread.sleep(forTimeInterval: 0.5)
    try fm.removeItem(atPath: sandbox + "/apps/App2/held.bin")
    let held = try check(12, previous: 11)
    let deleted = (held["processes"] as? [String: Any])?["open_deleted"] as? [String: Any]
    try test(int64(deleted?["allocated_bytes"]) >= 3_000_000 && (deleted?["files"] as? Int ?? 0) >= 1, "open-but-deleted file found (\(int64(deleted?["allocated_bytes"])) bytes still allocated)")
    holder.terminate(); holder.waitUntilExit()

    // 14. A busy coverage store never blocks the scheduled check.
    let busy = FileLock(dataDir.appendingPathComponent("attribution.lock").path, wait: 0)
    let busyClock = Date()
    let skipped = try check(13, previous: 12, lockWait: 0.3)
    try test(folders(skipped)["status"] as? String == "busy" && Date().timeIntervalSince(busyClock) < 3, "busy coverage store: evidence skipped after a bounded wait")
    _ = busy

    // Watchdog: a walk that never returns marks its unit blocked instead of stopping monitoring.
    let watchdog = WalkWatchdog.shared
    watchdog.exitOnStall = false
    var stalled: String?
    watchdog.onStall = { stalled = $0 }
    if let target = store().byPath["hard"] {
        watchdog.begin(db: dbPath, unit: target, path: "hard", allowed: -61)   // already past its limit
        let wait = Date().addingTimeInterval(12)
        while stalled == nil && Date() < wait { Thread.sleep(forTimeInterval: 0.2) }
        try test(stalled == "hard" && unit("hard")?.state == "pending" && unit("hard")?.kind == "split" && unit("hard")?.reason == "blocked_split", "a recursive walk that does not return is divided, so its subfolders are tried one by one")
        stalled = nil
        watchdog.begin(db: dbPath, unit: target, path: "hard", allowed: -61)
        let wait2 = Date().addingTimeInterval(12)
        while stalled == nil && Date() < wait2 { Thread.sleep(forTimeInterval: 0.2) }
        try test(unit("hard")?.state == "inaccessible" && unit("hard")?.reason == "blocked", "a listing that does not return is marked blocked, never retried immediately")
    }
    watchdog.onStall = nil; watchdog.exitOnStall = true

    // 15. Schema migration: an existing database keeps every row; new tables are added.
    let legacyPath = sandbox + "-state/legacy.sqlite3"
    var raw: OpaquePointer?
    try required(sqlite3_open(legacyPath, &raw) == SQLITE_OK, "open legacy")
    for sql in ["CREATE TABLE readings (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, container TEXT NOT NULL, free INTEGER NOT NULL, used INTEGER NOT NULL, volumes TEXT NOT NULL)",
                "CREATE TABLE alerts (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, severity TEXT NOT NULL, reasons TEXT NOT NULL, free INTEGER NOT NULL, delta INTEGER, notification TEXT NOT NULL)",
                "CREATE TABLE diagnostics (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, snapshot TEXT NOT NULL)", "CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
                "CREATE TABLE interval_evidence (reading_id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, evidence TEXT NOT NULL)",
                "INSERT INTO readings VALUES (7, \(Date().timeIntervalSince1970), 'C', 1, 2, '[]')", "INSERT INTO interval_evidence VALUES (7, 1.0, '{\"folders\":{\"status\":\"complete\"}}')",
                "INSERT INTO state VALUES ('attribution_baseline', '{\"x\":1}')"] { _ = sqlite3_exec(raw, sql, nil, nil, nil) }
    sqlite3_close(raw)
    let migrated = try Database(legacyPath)
    let tables = Set(try migrated.rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] })
    try test(tables.isSuperset(of: ["readings", "interval_evidence", "state", "coverage_units", "coverage_epochs"]) && (try migrated.rows("SELECT evidence FROM interval_evidence WHERE reading_id=7").first?["evidence"]) == "{\"folders\":{\"status\":\"complete\"}}" && (try migrated.state("attribution_baseline")) == "{\"x\":1}", "migration is additive: existing readings, evidence and baselines are untouched")
    try test(decodeCoverageLifecycle(migrated) == nil && (try migrated.rows("SELECT count(*) AS n FROM coverage_epochs").first?["n"]) == "0", "migration does not backfill coverage or claim earlier comprehensive history")

    // 16. Historical transitions: a scope change is recorded once; unchanged scope is not repeated.
    recordCoverageEpoch(migrated, scope: "folders", readingId: 7, at: 1, detail: "test"); recordCoverageEpoch(migrated, scope: "folders", readingId: 8, at: 2, detail: "test")
    recordCoverageEpoch(migrated, scope: "comprehensive", readingId: 9, at: 3, detail: "test")
    try test((try migrated.rows("SELECT scope FROM coverage_epochs ORDER BY id")).compactMap { $0["scope"] } == ["folders", "comprehensive"], "coverage epochs record each transition once")

    // 17. Concentration: the deepest directory holding three quarters of the growth.
    let synthetic: [[String: Any]] = [["rel": "Users/a/Library/Caches/x", "kind": "grew", "before_allocated": Int64(0), "after_allocated": Int64(1_400_000_000)],
                                      ["rel": "Users/a/Library/Caches/y", "kind": "grew", "before_allocated": Int64(0), "after_allocated": Int64(400_000_000)],
                                      ["rel": "private/var/z", "kind": "grew", "before_allocated": Int64(0), "after_allocated": Int64(200_000_000)],
                                      ["rel": "Users/a/moved", "kind": "moved_in", "before_allocated": Int64(0), "after_allocated": Int64(9_000_000_000)]]
    let whole = CoverageRegion(mount: dataVolumeMount, prefix: "", device: 0, deviceIdentifier: "test")
    let c = concentration(synthetic, region: whole, growth: true)
    try test((c?["path"] as? String)?.hasSuffix("Users/a/Library/Caches") == true && int64(c?["allocated"]) == 1_800_000_000 && int64(c?["total"]) == 2_000_000_000, "growth concentration: 1.8 of 2.0 GB under one directory; moves excluded")
    try test(concentration([], region: whole, growth: true) == nil, "no measured growth: no concentration claimed")
    let scattered: [[String: Any]] = [["rel": "Users/a/x", "kind": "grew", "before_allocated": Int64(0), "after_allocated": Int64(500_000_000)], ["rel": "private/var/y", "kind": "grew", "before_allocated": Int64(0), "after_allocated": Int64(500_000_000)]]
    try test(concentration(scattered, region: whole, growth: true) == nil, "growth spread across the volume: no single directory is named")
    var unrelated: [[String: Any]] = [["unit": Int64(1), "kind": "shrank", "path": "a", "before_allocated": Int64(4_469_000), "after_allocated": Int64(0)], ["unit": Int64(2), "kind": "grew", "path": "b", "before_allocated": Int64(0), "after_allocated": Int64(4_469_000)]]
    try test(pairMoves(&unrelated, renamed: [1: ["db.sqlite-wal"], 2: ["notes.md"]]).isEmpty && unrelated[0]["kind"] as? String == "shrank", "similar sizes with unrelated renames are not called a move")
    var related = unrelated
    try test(pairMoves(&related, renamed: [1: ["payload.bin"], 2: ["payload.bin", "x"]]).count == 1 && related[1]["kind"] as? String == "moved_in", "same file renamed out of one area and into another is a move")
}
