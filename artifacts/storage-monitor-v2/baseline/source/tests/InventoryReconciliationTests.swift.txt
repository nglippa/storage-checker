import Foundation
import CoreServices
import Darwin

#if INVENTORY_TESTS
// Event-gap classification and steady-state reconciliation (INVENTORY-RECONCILIATION-STEADY-STATE.md).
// Real fixtures and real FSEvents replay; synthetic flags only where macOS cannot be made to drop events.
func inventoryReconciliationTests(_ test: (Bool, String) throws -> Void) throws {
    try lossClassificationTests(test)
    try replayOutcomeTests(test)
    try boundaryAndSpillTests(test)
    try structuralChangeTests(test)
    try steadyStateScenarioTests(test)
    try continuouslyChangingDirectoryTests(test)
    try cleanupAuthorityPlanTests(test)
    try schedulingTests(test)
    try skippedDirectoryTests(test)
    try accountingTests(test)
    try lockContentionTests(test)
    func result(_ outcome: String, _ reason: String?, continues: Bool = false) -> InventoryRunResult {
        var value = InventoryRunResult(outcome: outcome, generation: 1, entries: 0, directories: 0, pending: 0, reason: reason); value.runnableWorkRemains = continues; return value
    }
    try test([result("complete", nil), result("partial", nil), result("interrupted", inventoryDeferredReason), result("interrupted", nil, continues: true),
              result("interrupted", "cancelled"), result("interrupted", inventoryLowSpaceReason), result("busy", "database is locked"), result("failed", "disk I/O error")].map(inventoryRunStatus)
             == ["completed", "completed", "deferred", "continuing", "paused", "paused", "skipped", "failed"],
             "D12: each worker log line states completed, deferred, continuing, paused, skipped or failed; a normal maintenance run is never described as interrupted")
}

/// Holds the history database's write lock from another connection, as the scheduled check does
/// while it records a reading, for `seconds`.
private func holdWriteLock(_ database: String, seconds: Double) -> DispatchSemaphore {
    let released = DispatchSemaphore(value: 0), held = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        do {
            let other = try Database(database)
            try other.exec("BEGIN IMMEDIATE")
            try other.write("INSERT OR REPLACE INTO state VALUES ('lock-holder','check')")
            held.signal()
            Thread.sleep(forTimeInterval: seconds)
            try other.exec("COMMIT")
        } catch { held.signal() }
        released.signal()
    }
    held.wait()
    return released
}

// D9/D10: the worker waits for the check's commits instead of abandoning its slice ("busy") or
// failing at startup ("database is locked", exit 1) when both start together.
private func lockContentionTests(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ReconciliationFixture.make("locks", directories: 40)
    defer { fixture.remove() }
    try requestInventoryRefresh(databasePath: fixture.database, paths: [fixture.root])
    let release = holdWriteLock(fixture.database, seconds: 2.5)
    let started = Date()
    let run = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 60), fdaOverride: "granted")
    release.wait()
    try test(run.outcome == "complete" && Date().timeIntervalSince(started) >= 2 && (try fixture.catalogMatchesDisk()),
             "D9: a worker run that meets the check's 2.5 s write lock waits and completes instead of ending 'busy' (\(run.outcome), \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
    let startup = holdWriteLock(fixture.database, seconds: 2.5)
    var opened = true
    do { _ = try Database(fixture.database, busyTimeout: inventoryWorkerBusyTimeout); try initializeInventorySchema(databasePath: fixture.database) } catch { opened = false }
    startup.wait()
    try test(opened, "D10: worker startup (history open and schema initialization) waits for a concurrent writer instead of failing with 'database is locked'")
}

// Storage accounting (STORAGE-ACCOUNTING-AUDIT.md): the root total is exactly the sum of indexed file
// allocation, hard links count once, protected subtrees are excluded and qualified, clones count
// once per file (st_blocks is not APFS-unique), and partial trees never lose indexed data.
private func accountingTests(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-accounting-\(UUID().uuidString)", state = URL(fileURLWithPath: root + "-state")
    let locked = root + "/locked"
    defer { _ = chmod(locked, 0o755); try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/data/deep/deeper", withIntermediateDirectories: true)
    try Data(repeating: 7, count: 1_000_000).write(to: URL(fileURLWithPath: root + "/data/plain"))
    try Data(repeating: 9, count: 300_000).write(to: URL(fileURLWithPath: root + "/data/deep/deeper/nested"))
    try Data(repeating: 3, count: 500_000).write(to: URL(fileURLWithPath: root + "/data/linked"))
    _ = link(root + "/data/linked", root + "/data/deep/second-name")          // hard link: one object, two names
    let sparse = open(root + "/data/sparse", O_CREAT | O_WRONLY, 0o644)       // 100 MB logical, a few blocks allocated
    _ = lseek(sparse, 100_000_000, SEEK_SET); _ = write(sparse, "x", 1); close(sparse)
    let cloned = clonefile(root + "/data/plain", root + "/data/plain-clone", 0) == 0   // APFS clone: shares blocks
    try fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 3_000_000).write(to: URL(fileURLWithPath: locked + "/hidden"))
    _ = chmod(locked, 0)

    // Independent oracle: unique regular files reachable without the protected folder.
    var oracleLogical: Int64 = 0, oracleAllocated: Int64 = 0, seen = Set<String>()
    for case let path as String in FileManager.default.enumerator(atPath: root + "/data")! {
        var info = stat()
        guard lstat(root + "/data/" + path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, seen.insert("\(info.st_dev):\(info.st_ino)").inserted else { continue }
        oracleLogical += Int64(info.st_size); oracleAllocated += Int64(info.st_blocks) * 512
    }
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    _ = try Database(database)
    let region = coverageRegion(root: root)!
    let db = try Database(database)
    func invariant() throws -> (mismatches: Int, root: Int64, files: Int64) {
        let mismatches = Int(try db.rows("""
            SELECT COUNT(*) AS n FROM inventory_nodes d WHERE d.kind='directory' AND d.status NOT IN ('unknown','inaccessible','excluded')
              AND COALESCE(d.total_allocated,0) <> (SELECT COALESCE(SUM(COALESCE(c.total_allocated,0)),0) FROM inventory_nodes c WHERE c.parent_id=d.id)
            """).first?["n"] ?? "-1") ?? -1
        let rootTotal = Int64(try db.rows("SELECT COALESCE(total_allocated,0) AS n FROM inventory_nodes WHERE parent_id IS NULL").first?["n"] ?? "0") ?? 0
        let files = Int64(try db.rows("SELECT COALESCE(SUM(COALESCE(total_allocated,0)),0) AS n FROM inventory_nodes WHERE kind<>'directory'").first?["n"] ?? "0") ?? 0
        return (mismatches, rootTotal, files)
    }
    // Partial tree: stop mid-pass; every indexed byte is already in the root total.
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, batchSize: 2, stopAfterEntries: 5), fdaOverride: "granted")
    let partial = try invariant()
    try test(partial.mismatches == 0 && partial.root == partial.files && partial.files > 0,
             "accounting: a partially indexed tree's root equals the sum of every indexed file (\(partial.root) bytes); no directory total omits an indexed child")
    let full = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let done = try invariant()
    let rootRow = try db.rows("SELECT total_logical,total_allocated,status FROM inventory_nodes WHERE parent_id IS NULL").first ?? [:]
    let lockedRow = try db.rows("SELECT status,total_allocated FROM inventory_nodes WHERE name='locked'").first ?? [:]
    let names = try db.rows("SELECT n.name,n.direct_allocated,n.total_allocated FROM inventory_nodes n WHERE n.name IN ('linked','second-name')")
    try test(full.outcome == "partial" && done.mismatches == 0 && done.root == done.files && Int64(rootRow["total_allocated"] ?? "") == oracleAllocated && Int64(rootRow["total_logical"] ?? "") == oracleLogical,
             "accounting: the root total equals an independent walk of unique readable files (\(oracleAllocated) allocated, \(oracleLogical) logical bytes)")
    try test(names.count == 2 && names.filter { ($0["total_allocated"] ?? "0") != "0" }.count == 1,
             "accounting: a hard-linked file is counted once, at one of its names")
    try test(lockedRow["status"] == "unknown" && lockedRow["total_allocated"] == nil && rootRow["status"] == "partial",
             "accounting: a protected folder contributes no bytes and marks every ancestor as a lower bound (partial)")
    let sparseRow = try db.rows("SELECT total_logical,total_allocated FROM inventory_nodes WHERE name='sparse'").first ?? [:]
    try test((Int64(sparseRow["total_logical"] ?? "") ?? 0) == 100_000_001 && (Int64(sparseRow["total_allocated"] ?? "") ?? Int64.max) < 1_000_000,
             "accounting: a sparse file reports its logical size (100 MB) separately from its small allocation (\(sparseRow["total_allocated"] ?? "?") bytes)")
    final class Box: @unchecked Sendable { var value: InventoryAccounting? }
    let box = Box(), finished = DispatchSemaphore(value: 0)
    try Database(database).state("inventory_full_disk_access", "not_granted")
    Task { box.value = try? await InventoryReader(path: database).accounting(); finished.signal() }
    finished.wait()
    try test(box.value?.indexedAllocated == oracleAllocated && box.value?.unavailableFolders == 1 && box.value?.protectedFolders == 0 && box.value?.fullDiskAccess == "not_granted" && box.value?.rootStatus == "partial",
             "accounting summary reads the root total, the unavailable folder and the worker's own Full Disk Access state")
    if cloned {
        let clones = try db.rows("SELECT total_allocated FROM inventory_nodes WHERE name IN ('plain','plain-clone')").compactMap { Int64($0["total_allocated"] ?? "") }
        try test(clones.count == 2 && clones[0] == clones[1] && clones[0] >= 1_000_000,
                 "accounting: an APFS clone is counted in full for each file (st_blocks is per file), so indexed allocation can exceed the volume's physical use")
    }
}

// D1/D2 (STORAGE-MONITOR-1.0.2-RELEASE.md): readable folders silently left unlisted, and a worker
// relaunched every minute because the closing event replay always left queued work.
private func skippedDirectoryTests(_ test: (Bool, String) throws -> Void) throws {
    // D1a: one entry whose metadata is refused must not hide the rest of a readable folder.
    do {
        let root = "/private/tmp/storage-monitor-unreadable-\(UUID().uuidString)", state = URL(fileURLWithPath: root + "-state")
        let locked = root + "/locked"
        try fm.createDirectory(atPath: locked + "/inner", withIntermediateDirectories: true)
        for name in ["x", "y"] { try Data([1, 2, 3]).write(to: URL(fileURLWithPath: locked + "/" + name)) }
        try fm.createDirectory(atPath: root + "/open", withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: root + "/open/f"))
        _ = chmod(locked, 0o444)   // names are readable; each entry's metadata is refused (EACCES)
        defer { _ = chmod(locked, 0o755); try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
        try privateDirectory(state)
        let database = state.appendingPathComponent("history.sqlite3").path
        _ = try Database(database)
        let run = runInventory(databasePath: database, directory: state, region: coverageRegion(root: root)!, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
        let db = try Database(database)
        let folder = try db.rows("SELECT n.status,n.child_count,j.completed_token FROM inventory_nodes n JOIN inventory_jobs j ON j.node_id=n.id WHERE n.name='locked'").first ?? [:]
        let children = try db.rows("SELECT c.name,c.kind,c.status,c.reason FROM inventory_nodes c JOIN inventory_nodes p ON p.id=c.parent_id WHERE p.name='locked' ORDER BY c.name")
        try test(folder["status"] == "partial" && folder["child_count"] == "3" && (Int(folder["completed_token"] ?? "0") ?? 0) > 0
                 && children.map { $0["name"] ?? "" } == ["inner", "x", "y"] && children.allSatisfy { $0["status"] == "unknown" && $0["reason"] == "metadata:permissions" }
                 && children.first?["kind"] == "directory" && run.outcome == "partial",
                 "D1: a readable folder with entries whose metadata is refused is listed; those entries are recorded as unreadable and the folder is a lower bound (partial), not an inaccessible folder")
    }

    // D1b: continuous activity cannot keep a queued folder from its first listing (bounded postponement).
    do {
        let root = "/private/tmp/storage-monitor-postpone-\(UUID().uuidString)", state = URL(fileURLWithPath: root + "-state")
        defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
        for index in 0..<400 { try fm.createDirectory(atPath: root + "/g/d\(index)/s", withIntermediateDirectories: true); try Data([1]).write(to: URL(fileURLWithPath: root + "/g/d\(index)/s/f")) }
        try privateDirectory(state)
        let database = state.appendingPathComponent("history.sqlite3").path
        _ = try Database(database)
        let region = coverageRegion(root: root)!
        _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60, stopAfterEntries: 300), fdaOverride: "granted")
        let db = try Database(database)
        guard let target = try db.rows("SELECT j.node_id,n.name,j.updated_at FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE j.state='pending' AND j.completed_token=0 AND n.name LIKE 'd%' ORDER BY j.updated_at DESC,j.node_id DESC LIMIT 1").first,
              let node = Int64(target["node_id"] ?? "") else { throw Failure("no queued target") }
        func ahead() throws -> Int64 {
            let at = Double(try db.rows("SELECT updated_at FROM inventory_jobs WHERE node_id=?", [node]).first?["updated_at"] ?? "0") ?? 0
            return Int64(try db.rows("SELECT COUNT(*) AS n FROM inventory_jobs WHERE state IN ('pending','enumerating') AND (updated_at<? OR (updated_at=? AND node_id<?))", [at, at, node]).first?["n"] ?? "0") ?? 0
        }
        var positions = [try ahead()], listed = false, slices = 0
        while !listed && slices < 40 {
            try invalidateInventory(databasePath: database, paths: [root + "/g/" + target["name"]!], eventID: nil, gap: false, reason: "Filesystem activity")
            _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60, stopAfterEntries: 60), fdaOverride: "granted")
            slices += 1
            listed = (Int64(try db.rows("SELECT completed_token FROM inventory_jobs WHERE node_id=?", [node]).first?["completed_token"] ?? "0") ?? 0) > 0
            if !listed { positions.append(try ahead()) }
        }
        let remaining = Int64(try db.rows("SELECT COUNT(*) AS n FROM inventory_jobs WHERE state IN ('pending','enumerating')").first?["n"] ?? "0") ?? 0
        try test(listed && zip(positions, positions.dropFirst()).allSatisfy { $0.1 <= $0.0 } && remaining > 0,
                 "D1: a folder re-queued by filesystem activity before every slice never moves back in the queue and is listed while other work remains (positions \(positions.prefix(6).map(String.init).joined(separator: ",")), listed after \(slices) slices, \(remaining) still queued)")
    }

    // D1c: a folder never opened without consent keeps its honest status under activity; its
    // re-queued job does not look like stale data and does not make the worker relaunch.
    do {
        let fixture = try ReconciliationFixture.make("consent", directories: 4)
        defer { fixture.remove() }
        try fm.createDirectory(atPath: fixture.root + "/Protected/inside", withIntermediateDirectories: true)
        let gate = ConsentGate(exact: ["Protected"], childrenOf: [:])
        try fixture.touch([0], tag: "parent-changed")
        fixture.settle()
        _ = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
        let first = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "not_granted", gatedOverride: gate)
        try invalidateInventory(databasePath: fixture.database, paths: [fixture.root + "/Protected/inside"], eventID: nil, gap: false, reason: "Filesystem activity")
        _ = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 0), fdaOverride: "not_granted", gatedOverride: gate)
        let queued = try fixture.rows("SELECT n.status,n.reason,j.state FROM inventory_nodes n JOIN inventory_jobs j ON j.node_id=n.id WHERE n.name='Protected'").first ?? [:]
        let again = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "not_granted", gatedOverride: gate)
        let settled = try fixture.rows("SELECT n.status,n.reason,j.state FROM inventory_nodes n JOIN inventory_jobs j ON j.node_id=n.id WHERE n.name='Protected'").first ?? [:]
        try test(first.outcome == "partial" && queued["status"] == "unknown" && queued["reason"] == "consent" && queued["state"] == "pending"
                 && settled["state"] == "complete" && settled["reason"] == "consent" && inventoryWorkExitCode(again) == nil,
                 "D1: activity inside a consent-protected folder re-runs its job but keeps it reported as protected, never as previously measured; the run exits 0")
    }

    // Low free space pauses indexing without a relaunch loop and resumes on a later wake; progress
    // samples persist across worker runs for the viewer's rate and estimate.
    do {
        let root = "/private/tmp/storage-monitor-space-\(UUID().uuidString)", state = URL(fileURLWithPath: root + "-state")
        defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state); inventoryAvailableSpaceOverride = nil }
        for index in 0..<50 { try fm.createDirectory(atPath: root + "/d\(index)", withIntermediateDirectories: true); try Data([1]).write(to: URL(fileURLWithPath: root + "/d\(index)/f")) }
        try privateDirectory(state)
        let database = state.appendingPathComponent("history.sqlite3").path
        _ = try Database(database)
        let region = coverageRegion(root: root)!
        try test(inventoryLowSpaceThreshold(capacity: 256_000_000_000) == 2_560_000_000 && inventoryLowSpaceThreshold(capacity: 64_000_000_000) == 2_000_000_000 && inventoryLowSpaceThreshold(capacity: 2_000_000_000_000) == 5_000_000_000,
                 "low-space threshold is 1% of the volume, at least 2 GB and at most 5 GB")
        inventoryAvailableSpaceOverride = (available: 1_500_000_000, capacity: 256_000_000_000)
        let paused = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
        let pausedStatus = try readerStatus(database)
        let generation = try Database(database).rows("SELECT state,reason FROM inventory_generations WHERE active=1").first ?? [:]
        try test(paused.reason == inventoryLowSpaceReason && inventoryWorkExitCode(paused) == nil && generation["state"] == "paused" && pausedStatus.lowSpacePaused
                 && InventoryStatusPresentation(status: pausedStatus).condition == .paused && (Int(try Database(database).rows("SELECT COUNT(*) AS n FROM inventory_nodes").first?["n"] ?? "0") ?? 0) <= 1,
                 "below the free-space threshold indexing pauses before writing the catalog, exits 0 (no relaunch loop) and reports the pause")
        inventoryAvailableSpaceOverride = (available: 40_000_000_000, capacity: 256_000_000_000)
        let resumed = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
        let resumedStatus = try readerStatus(database)
        final class Box: @unchecked Sendable { var samples = [InventoryProgressSample]() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task { box.samples = (try? await InventoryReader(path: database).progressSamples()) ?? []; done.signal() }
        done.wait()
        try test(resumed.outcome == "complete" && !resumedStatus.lowSpacePaused && (try Database(database).rows("SELECT COUNT(*) AS n FROM inventory_nodes").first?["n"]) == "101"
                 && box.samples.count >= 2 && box.samples.last?.nodes == 101 && box.samples.last?.queuedListings == 0,
                 "once space is available the next run resumes and completes; progress samples from both runs persist for the viewer (\(box.samples.count) samples)")
    }

    // D2: the Air sequence. The main run completes, activity arrives, the closing replay queues it and
    // the zero-budget final pass reports it as pending. That queued work must not relaunch the worker.
    do {
        let fixture = try ReconciliationFixture.make("relaunch", directories: 20)
        defer { fixture.remove() }
        func invocation() throws -> (main: InventoryRunResult, final: InventoryRunResult?) {
            _ = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
            let main = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 20), fdaOverride: "granted")
            guard ["complete", "partial"].contains(main.outcome) else { return (main, nil) }
            try fixture.touch([1, 2], tag: "late-\(UUID().uuidString.prefix(4))")
            fixture.settle()
            _ = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
            return (main, runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 0), fdaOverride: "granted"))
        }
        let once = try invocation()
        try test(once.main.outcome == "complete" && once.final?.outcome == "interrupted" && (once.final?.pending ?? 0) > 0 && inventoryWorkExitCode(once.main) == nil,
                 "D2: work queued by the closing replay leaves the final pass 'interrupted' (as on the Air), but the worker exits 0 and waits for its next wake")
        let churn = Churn(fixture.folder(3))
        var relaunches = 0
        for _ in 0..<4 { if inventoryWorkExitCode(try invocation().main) != nil { relaunches += 1 } }
        churn.end()
        for name in ["churn0", "churn1"] { try? fm.removeItem(atPath: fixture.folder(3) + "/" + name) }
        fixture.settle()
        _ = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
        let next = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 20), fdaOverride: "granted")
        try test(relaunches == 0 && next.outcome == "complete" && (try fixture.catalogMatchesDisk()),
                 "D2: four launchd invocations under continuous filesystem activity request no relaunch (\(relaunches)); the next wake applies the queued changes and the catalog matches disk")
    }
}

/// Reader status from synchronous tests; the reader is an actor.
private func readerStatus(_ database: String) throws -> InventoryStatus {
    final class Box: @unchecked Sendable { var result: Result<InventoryStatus, Error>? }
    let box = Box(), done = DispatchSemaphore(value: 0)
    Task { do { box.result = .success(try await InventoryReader(path: database).status()) } catch { box.result = .failure(error) }; done.signal() }
    done.wait()
    return try box.result!.get()
}

/// Rewrites one changing file until stopped, as a browser cache does while the browser runs.
private final class Churn {
    private let stop = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
    init(_ directory: String) {
        Thread.detachNewThread { [stop, stopped] in
            var index = 0
            while stop.wait(timeout: .now()) == .timedOut {
                let path = directory + "/churn\(index % 2)"
                if index % 4 < 2 { fm.createFile(atPath: path, contents: Data([2])) } else { try? fm.removeItem(atPath: path) }
                index += 1; usleep(100)   // fast enough that no listing of the folder can finish in between
            }
            stopped.signal()
        }
    }
    func end() { stop.signal(); stopped.wait() }
}

// QA 2026-10-23: one cleanup-authority query scanned all 480,000 jobs per tombstone claim;
// a 10 s stack sample of the worker spent every sample there.
private func cleanupAuthorityPlanTests(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ReconciliationFixture.make("authority", directories: 2_000)
    defer { fixture.remove() }
    let plan = try fixture.rows("EXPLAIN QUERY PLAN " + inventoryNewerObservationSQL, [1, 1, 0]).compactMap { $0["detail"] }
    // SQLite before 3.36 prints "SCAN TABLE j"/"SEARCH TABLE j"; accept either wording.
    func step(_ verb: String, _ detail: String) -> Bool { detail.range(of: "^\(verb)( TABLE)? j( |$)", options: .regularExpression) != nil }
    try test(plan.contains { step("SEARCH", $0) && $0.contains("PRIMARY KEY") } && !plan.contains { step("SCAN", $0) },
             "the cleanup-authority check walks the ancestor chain and probes jobs by key, never scanning every job (\(plan.joined(separator: "; ")))")

    // The join order changes; the answer must not. Compare against the original inner join.
    let original = inventoryNewerObservationSQL.replacingOccurrences(of: "FROM chain CROSS JOIN inventory_jobs", with: "FROM chain JOIN inventory_jobs")
    let root = try fixture.scalar("SELECT id FROM inventory_nodes WHERE parent_id IS NULL")
    let sequences = try fixture.rows("SELECT MIN(completed_sequence) AS low,MAX(completed_sequence) AS high FROM inventory_jobs WHERE state='complete'").first!
    let low = Int64(sequences["low"] ?? "0") ?? 0, high = Int64(sequences["high"] ?? "0") ?? 0
    let thresholds = [0, (low + high) / 2, high]
    var compared = 0, nonzero = 0, mismatches = 0
    for row in try fixture.rows("SELECT id FROM inventory_nodes WHERE kind='file' ORDER BY id LIMIT 60") {
        let node = Int64(row["id"]!)!
        for threshold in thresholds {
            let fixed = try fixture.scalar(inventoryNewerObservationSQL, [node, root, threshold]), old = try fixture.scalar(original, [node, root, threshold])
            compared += 1; if fixed > 0 { nonzero += 1 }; if fixed != old { mismatches += 1 }
        }
    }
    try test(original != inventoryNewerObservationSQL && compared == 180 && nonzero > 0 && mismatches == 0,
             "the reordered query returns exactly the original counts (\(compared) comparisons, \(nonzero) non-zero, \(mismatches) mismatches)")
}

// QA 2026-10-23: a browser cache written every few seconds changed during every 29,673-entry
// listing, and the worker relisted it until each 1,200 s budget expired, indefinitely.
private func continuouslyChangingDirectoryTests(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ReconciliationFixture.make("hot", directories: 10)
    defer { fixture.remove() }
    let hot = fixture.root + "/hot"
    try fm.createDirectory(atPath: hot, withIntermediateDirectories: true)
    for index in 0..<4_000 { try Data([1]).write(to: URL(fileURLWithPath: hot + "/f\(index)")) }
    try fixture.touch([3], tag: "ordinary")
    fixture.settle()
    _ = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
    // Queue both folders even if event delivery lags on a loaded machine; this test is about deferral.
    try requestInventoryRefresh(databasePath: fixture.database, paths: [fixture.root, fixture.folder(3)])

    let stop = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var index = 0
        while stop.wait(timeout: .now()) == .timedOut {
            let path = hot + "/churn\(index % 2)"
            if index % 4 < 2 { fm.createFile(atPath: path, contents: Data([2])) } else { try? fm.removeItem(atPath: path) }
            index += 1; usleep(500)
        }
        stopped.signal()
    }
    let profile = InventoryProfile(), began = Date()
    let busy = profile.withScope { runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 60, batchSize: 64), fdaOverride: "granted") }
    let seconds = Date().timeIntervalSince(began)
    stop.signal(); stopped.wait()
    let job = try fixture.rows("SELECT j.state,n.status FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='hot'").first ?? [:]
    try test(busy.reason == inventoryDeferredReason && profile.counts["listings_retried_changed", default: 0] == Int64(inventoryChangedRetryLimit) && seconds < 30,
             "a directory that changes during every listing is retried \(inventoryChangedRetryLimit) times, then deferred instead of relisted until the budget expires (\(profile.counts["listings_retried_changed", default: 0]) retries, \(String(format: "%.1f", seconds)) s of a 60 s budget, reason \(busy.reason ?? "none"))")
    try test(job["state"] == "pending" && job["status"] == "stale" && busy.outcome == "interrupted",
             "the deferred directory stays durably pending and stale; nothing is reported complete")
    try test(try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name='ordinary'") == 1,
             "a stable directory changed in the same interval is still listed while the unstable one is deferred")
    let deferredStatus = try readerStatus(fixture.database)
    let deferredLine = InventoryStatusPresentation(status: deferredStatus)
    try test(try fixture.rows("SELECT j.reason FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='hot'").first?["reason"] == inventoryDeferredReason
             && deferredStatus.deferredDirectories == 1 && deferredLine.condition == .staleDirectories && deferredLine.affectedDirectories == 1 && deferredLine.activeListings == 0
             && deferredLine.headline == "Up to date except 1 folder that keeps changing" && deferredStatus.completeness == .stale,
             "C: the deferral is durable; the viewer reports 1 changing folder (\(deferredLine.headline)), no active listings, and values stay qualified as stale")
    try test(inventoryWorkExitCode(busy) == nil, "a deferred-only run exits 0, so launchd leaves the worker idle until the next scheduled wake")
    final class ListBox: @unchecked Sendable { var paths = [String]() }
    let listed = ListBox(), listedDone = DispatchSemaphore(value: 0)
    Task { listed.paths = ((try? await InventoryReader(path: fixture.database).deferredDirectories()) ?? []).map(\.path); listedDone.signal() }
    listedDone.wait()
    try test(listed.paths.count == 1 && listed.paths.first?.hasSuffix("/hot") == true, "the viewer's 'Show folder' list names the deferred folder (\(listed.paths))")

    // The next scheduled run retries the deferred folder (still changing here) instead of skipping it.
    let laterChurn = Churn(hot)
    let laterProfile = InventoryProfile()
    let later = laterProfile.withScope { runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 60, batchSize: 64), fdaOverride: "granted") }
    laterChurn.end()
    try test(later.reason == inventoryDeferredReason && laterProfile.counts["listings_retried_changed", default: 0] == Int64(inventoryChangedRetryLimit),
             "a later run retries the deferred folder \(inventoryChangedRetryLimit) more times, then defers it again (\(laterProfile.counts["listings_retried_changed", default: 0]) retries)")

    fixture.settle()
    _ = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
    let quiet = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 60, batchSize: 64), fdaOverride: "granted")
    try test(quiet.outcome == "complete" && (try fixture.idle()) && (try fixture.catalogMatchesDisk()),
             "once the directory is quiet the next run lists it completely and the catalog matches disk (\(quiet.outcome))")
    let settled = try readerStatus(fixture.database)
    try test(settled.deferredDirectories == 0 && InventoryStatusPresentation(status: settled).condition == .current,
             "C to B: once listed, the folder is no longer counted and the inventory reads as current")
}

private func schedulingTests(_ test: (Bool, String) throws -> Void) throws {
    // Worker exit policy as launchd applies it (KeepAlive SuccessfulExit=false: relaunch only after a non-zero exit).
    do {
        let root = "/private/tmp/storage-monitor-budget-\(UUID().uuidString)", state = URL(fileURLWithPath: root + "-state")
        defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
        for index in 0..<300 { try fm.createDirectory(atPath: root + "/d\(index)", withIntermediateDirectories: true); try Data([1]).write(to: URL(fileURLWithPath: root + "/d\(index)/f")) }
        try privateDirectory(state)
        let database = state.appendingPathComponent("history.sqlite3").path
        _ = try Database(database)
        let region = coverageRegion(root: root)!
        let limited = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60, stopAfterEntries: 40), fdaOverride: "granted")
        try test(limited.runnableWorkRemains && inventoryWorkExitCode(limited) == 75,
                 "D2: a first pass stopped at its budget with runnable listings exits 75, so launchd continues it")
        var slices = 1, last = limited
        while last.runnableWorkRemains && slices < 50 { last = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60, stopAfterEntries: 200), fdaOverride: "granted"); slices += 1 }
        try test(last.outcome == "complete" && inventoryWorkExitCode(last) == nil && (try Database(database).rows("SELECT COUNT(*) AS n FROM inventory_nodes").first?["n"]) == "601",
                 "D2: resumed slices finish the first pass (\(slices) slices, all 601 entries), and the finishing run exits 0")
    }

    let fixture = try ReconciliationFixture.make("schedule", directories: 20)
    defer { fixture.remove(); inventoryAwakeClockOverride = nil }

    // No overlapping workers: a second worker for the same data directory refuses to start.
    do {
        let held = FileLock(fixture.state.appendingPathComponent("inventory.lock").path, wait: 0)
        let second = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 5), fdaOverride: "granted")
        let command = FileLock(fixture.state.appendingPathComponent("inventory-command.lock").path, wait: 0)
        let secondCommand = FileLock(fixture.state.appendingPathComponent("inventory-command.lock").path, wait: 0)
        try test(held != nil && second.outcome == "busy" && inventoryWorkExitCode(second) == nil && command != nil && secondCommand == nil,
                 "a second worker reports busy without touching the catalog and exits 0 (the active worker owns the work); a second inventory command cannot take the command lock")
        withExtendedLifetime((held, command)) {}
    }

    // Awake-time cursor age: sleep does not expire the cursor; awake time, a restart or a legacy row use the 6 h rule.
    let real = InventoryAwakeClock.current
    let stored = try fixture.rows("SELECT boot_session,awake_at FROM inventory_event_cursor").first ?? [:]
    try test(!real.bootSession.isEmpty && stored["boot_session"] == real.bootSession && (Double(stored["awake_at"] ?? "") ?? 0) > 0,
             "an acknowledged cursor records this boot session and its sleep-excluding uptime")
    let now = Date().timeIntervalSince1970
    func replay(wallAge: Double, session: String, awakeAge: Double, clockSession: String? = nil) throws -> InventoryEventReplay {
        inventoryAwakeClockOverride = InventoryAwakeClock(bootSession: clockSession ?? real.bootSession, uptime: real.uptime + 100_000)
        try Database(fixture.database).write("UPDATE inventory_event_cursor SET acknowledged_at=?,boot_session=?,awake_at=?", [now - wallAge, session, real.uptime + 100_000 - awakeAge])
        return try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
    }
    func fullVolumeQueued() throws -> Bool {
        try fixture.scalar("SELECT COUNT(*) FROM inventory_invalidations WHERE absolute_path IS NULL AND gap=1") + fixture.reconcile().rows > 0
    }
    let overnight = try replay(wallAge: 9 * 3600, session: real.bootSession, awakeAge: 600)
    try test(overnight.outcome == .applied && !(try fullVolumeQueued()),
             "sleep/wake: 9 h asleep with 10 min awake replays the retained event history; no full-volume reconciliation (\(overnight.outcome.rawValue))")
    let restartedSoon = try replay(wallAge: 3600, session: real.bootSession, awakeAge: 0, clockSession: "after-restart")
    try test(restartedSoon.outcome == .applied && !(try fullVolumeQueued()), "reboot: a cursor from the previous boot within 6 h of wall time is replayed")
    let restartedLate = try replay(wallAge: 9 * 3600, session: real.bootSession, awakeAge: 600, clockSession: "after-restart")
    try test(restartedLate.outcome == .gap && (try fullVolumeQueued()),
             "reboot: a cursor from the previous boot older than 6 h of wall time expires and schedules one safe reconciliation (\(restartedLate.outcome.rawValue))")
    inventoryAwakeClockOverride = nil
    let drained = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 120), fdaOverride: "granted")
    try test(drained.outcome == "complete" && (try fixture.idle()) && (try fixture.catalogMatchesDisk()), "the expiry reconciliation drains and the catalog matches disk")
    let awake = try replay(wallAge: 7 * 3600, session: real.bootSession, awakeAge: 7 * 3600)
    try test(awake.outcome == .gap, "7 h awake without an acknowledgement still expires the cursor")
    let legacy = try replay(wallAge: 9 * 3600, session: "", awakeAge: 600)
    try test(legacy.outcome == .gap, "a cursor written before awake time was stored keeps the wall-clock rule")
    inventoryAwakeClockOverride = nil

    // Drops: FSEvents.h requires a full rescan whatever the drop's ID, so a drop reported after the
    // replay marker is loss too. An ordinary event after the marker belongs to the next interval.
    defer { inventoryReplayInjectedEvents = nil }
    _ = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 120), fdaOverride: "granted")
    inventoryReplayInjectedEvents = { marker in [(fixture.region.prefix + "/g0", UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile), marker + 1_000)] }
    let lateOrdinary = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
    try test(lateOrdinary.outcome == .applied && !(try fullVolumeQueued()), "an ordinary event after the replay marker is left to the next replay, not treated as loss")
    for (flag, name) in [(kFSEventStreamEventFlagUserDropped, "user"), (kFSEventStreamEventFlagKernelDropped, "kernel")] {
        inventoryReplayInjectedEvents = { marker in [(fixture.region.prefix, UInt32(kFSEventStreamEventFlagMustScanSubDirs | flag), marker + 1_000)] }
        let lateDrop = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
        try test(lateDrop.outcome == .gap && (try fullVolumeQueued()), "a \(name) drop reported after the replay marker still schedules reconciliation (\(lateDrop.outcome.rawValue))")
        _ = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 120), fdaOverride: "granted")
    }
    inventoryReplayInjectedEvents = nil

    // A first pass in which one folder changes during every listing still records the milestone (C, not A).
    let root = "/private/tmp/storage-monitor-first-defer-\(UUID().uuidString)", state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    for index in 0..<10 { try fm.createDirectory(atPath: root + "/d\(index)", withIntermediateDirectories: true); try Data([1]).write(to: URL(fileURLWithPath: root + "/d\(index)/f")) }
    let hot = root + "/Cache_Data"
    try fm.createDirectory(atPath: hot, withIntermediateDirectories: true)
    for index in 0..<4_000 { try Data([1]).write(to: URL(fileURLWithPath: hot + "/f\(index)")) }
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    _ = try Database(database)
    let region = coverageRegion(root: root)!
    let churn = Churn(hot)
    let first = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60, batchSize: 64), fdaOverride: "granted")
    churn.end()
    for name in ["churn0", "churn1"] { try? fm.removeItem(atPath: hot + "/" + name) }
    let firstStatus = try readerStatus(database)
    let firstLine = InventoryStatusPresentation(status: firstStatus)
    let hotJob = try Database(database).rows("SELECT j.completed_token,j.reason FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.name='Cache_Data'").first ?? [:]
    try test(first.reason == inventoryDeferredReason && firstStatus.initialCompletion == .complete && hotJob["completed_token"] == "0" && hotJob["reason"] == inventoryDeferredReason,
             "A to C: a first pass whose only unlisted folder keeps changing records the first-pass milestone; the folder stays durably unlisted and deferred (reason \(first.reason ?? "none"), milestone \(firstStatus.initialCompletion.rawValue), token \(hotJob["completed_token"] ?? "?"), job reason \(hotJob["reason"] ?? "none"))")
    try test(!InventoryInitializationPresentation(status: firstStatus).isVisible && firstLine.condition == .staleDirectories && firstLine.affectedDirectories == 1 && !firstStatus.hasInitialDiscoveryWork,
             "one unstable cache does not make the whole inventory look like a first scan; it is reported as 1 affected folder (\(firstLine.headline))")
    let firstQuiet = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60, batchSize: 64), fdaOverride: "granted")
    let firstSettled = try readerStatus(database)
    try test(firstQuiet.outcome == "complete" && firstSettled.deferredDirectories == 0 && InventoryStatusPresentation(status: firstSettled).condition == .current
             && (try Database(database).rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE parent_id=(SELECT id FROM inventory_nodes WHERE name='Cache_Data')").first?["n"]) == "4000",
             "C to B: when the folder stops changing the next run lists all 4,000 entries and the inventory reads as current")
}

private func lossClassificationTests(_ test: (Bool, String) throws -> Void) throws {
    let region = coverageRegion(root: "/private/tmp")!
    func activity() -> CoverageActivity {
        let store = CoverageStore(); store.create(path: "", at: 0)
        return CoverageActivity(store: store, region: region, until: 1_000)
    }
    let root = region.prefix
    let dropped = activity(); dropped.handle(root + "/x", UInt32(kFSEventStreamEventFlagKernelDropped), 10)
    let wrapped = activity(); wrapped.handle(root, UInt32(kFSEventStreamEventFlagEventIdsWrapped), 10)
    let rootRescan = activity(); rootRescan.handle(root, UInt32(kFSEventStreamEventFlagMustScanSubDirs), 10)
    let subtreeRescan = activity(); subtreeRescan.handle(root + "/sub", UInt32(kFSEventStreamEventFlagMustScanSubDirs), 10)
    let ordinary = activity(); for index in 0..<10_000 { ordinary.handle(root + "/d\(index)/f", UInt32(kFSEventStreamEventFlagItemCreated), UInt64(index % 1_000) + 1) }
    let lateDrop = activity(); lateDrop.handle(root + "/x", UInt32(kFSEventStreamEventFlagUserDropped), 5_000)
    try test(dropped.lossDetected && wrapped.lossDetected && rootRescan.lossDetected, "dropped events, wrapped IDs and a root-level rescan request are genuine loss of event coverage")
    try test(!subtreeRescan.lossDetected && subtreeRescan.mustScan == ["sub"], "a subtree rescan request is scoped to that subtree, not whole-volume loss")
    try test(!ordinary.lossDetected && !lateDrop.lossDetected, "coverage classification: 10,000 ordinary events, or a drop after the replay window, are not loss (inventory replay treats any drop as loss)")
}

private func replayOutcomeTests(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ReconciliationFixture.make("outcomes", directories: 5_000)
    defer { fixture.remove() }
    let schemaBefore = try fixture.rows("SELECT type,name,sql FROM sqlite_master ORDER BY name")
    let cursor0 = try fixture.scalar("SELECT event_id FROM inventory_event_cursor")
    let completedAt = try fixture.rows("SELECT initial_completed_at FROM inventory_generations WHERE active=1").first?["initial_completed_at"]

    // High event volume without loss, with spilling forced by a small memory limit.
    try fixture.touch(Array(0..<4_500), tag: "volume")
    fixture.settle()
    let volume = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region, pathMemoryLimit: 1_000)
    let queued = try fixture.scalar("SELECT COUNT(DISTINCT absolute_path) FROM inventory_invalidations")
    try test(volume.outcome == .applied && volume.paths >= 4_500 && queued >= 4_500 && (try fixture.reconcile().rows) == 0,
             "4,500 changed folders (over the old 4,096 limit) become targeted relistings, not a full-volume reconciliation (\(volume.outcome.rawValue), \(volume.paths) paths)")
    let cursor1 = try fixture.scalar("SELECT event_id FROM inventory_event_cursor")
    try test(cursor1 > cursor0, "the cursor is acknowledged only after every changed folder is durably queued")
    let profile = InventoryProfile()
    let drained = profile.withScope { runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 120), fdaOverride: "granted") }
    let listings = profile.counts["listings_completed", default: 0]
    try test(drained.outcome == "complete" && (try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name='volume'")) == 4_500 && listings < 5_000 && (try fixture.catalogMatchesDisk()),
             "the high-volume interval relists only the changed folders (\(listings) listings for 4,500 changes in 5,000 folders) and captures every change")

    // Slow replay without loss: retried from the unchanged cursor, nothing invented.
    try fixture.touch(Array(0..<40), tag: "slow")
    fixture.settle()
    let acknowledgedBeforeRetry = try fixture.rows("SELECT acknowledged_at FROM inventory_event_cursor").first?["acknowledged_at"]
    inventoryReplaySimulatedTimeout = true
    let slow = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
    inventoryReplaySimulatedTimeout = false
    try test((try fixture.rows("SELECT acknowledged_at FROM inventory_event_cursor").first?["acknowledged_at"]) == acknowledgedBeforeRetry,
             "a retry leaves the acknowledgement time unchanged, so the next replay budget grows with cursor age")
    try test(slow.outcome == .retry && (try fixture.scalar("SELECT event_id FROM inventory_event_cursor")) == cursor1 && (try fixture.reconcile().rows) == 0,
             "a replay that misses its deadline keeps the cursor and schedules no full reconciliation")
    let resumed = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
    _ = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 60), fdaOverride: "granted")
    try test(resumed.outcome == .applied && (try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name='slow'")) == 40 && (try fixture.idle()),
             "the next replay continues from the same cursor and every change is captured")

    // Genuine loss, overlapping losses coalesce into one durable pass.
    let lost = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region, simulateLoss: true)
    _ = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 60, stopAfterEntries: 1_000), fdaOverride: "granted")
    let frontier = try fixture.reconcile()
    _ = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region, simulateLoss: true)
    _ = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 60, stopAfterEntries: 0), fdaOverride: "granted")
    let overlapped = try fixture.reconcile()
    try test(lost.outcome == .gap && frontier.rows == 1 && overlapped.rows == 1 && overlapped.sequence > frontier.sequence,
             "genuine event loss schedules one reconciliation, and an overlapping loss coalesces into the same durable pass")
    let finished = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 120), fdaOverride: "granted")
    try test(finished.outcome == "complete" && (try fixture.idle()) && (try fixture.catalogMatchesDisk()), "the reconciliation finishes and the inventory returns to idle")
    try test((try fixture.rows("SELECT initial_completed_at FROM inventory_generations WHERE active=1").first?["initial_completed_at"]) == completedAt,
             "high volume, retries and genuine gaps leave the first-pass completion record unchanged")
    let schemaAfter = try fixture.rows("SELECT type,name,sql FROM sqlite_master ORDER BY name")
    let schemaChanged = Set(schemaAfter.map { $0["name"] ?? "" }).symmetricDifference(schemaBefore.map { $0["name"] ?? "" }).sorted()
    try test(schemaAfter == schemaBefore, "the correction adds no schema: existing catalogs need no migration\(schemaChanged.isEmpty ? "" : " (changed: \(schemaChanged))")")

    // Events outside the inventory root are not this inventory's changes.
    let outside = fixture.root + "-outside"
    try fm.createDirectory(atPath: outside + "/x", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: outside) }
    for index in 0..<200 { try Data([3]).write(to: URL(fileURLWithPath: outside + "/x/\(index)")) }
    fixture.settle()
    let ignored = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
    try test(ignored.outcome == .applied && ignored.paths == 0 && (try fixture.scalar("SELECT COUNT(*) FROM inventory_invalidations")) == 0, "events outside the inventory root queue no work")
}

private func boundaryAndSpillTests(_ test: (Bool, String) throws -> Void) throws {
    // A completed replay boundary is proven by HistoryDone followed by a synchronous flush,
    // never by the largest observed event ID (IDs were observed arriving out of order).
    let region = coverageRegion(root: "/private/tmp")!
    func activity() -> CoverageActivity { let store = CoverageStore(); store.create(path: "", at: 0); return CoverageActivity(store: store, region: region, until: 1_000) }
    let maxSeenOnly = activity(); maxSeenOnly.handle(region.prefix + "/a", UInt32(kFSEventStreamEventFlagItemCreated), 1_000)
    let doneUnflushed = activity(); doneUnflushed.historyDone = true
    let complete = activity(); complete.historyDone = true; complete.flushed = true
    let timedOut = activity(); timedOut.historyDone = true; timedOut.flushed = true; timedOut.timedOut = true
    try test(maxSeenOnly.lastId >= 1_000 && !inventoryReplayBoundaryComplete(maxSeenOnly), "observing an event at the marker ID is not proof that earlier events were delivered")
    try test(!inventoryReplayBoundaryComplete(doneUnflushed) && inventoryReplayBoundaryComplete(complete) && !inventoryReplayBoundaryComplete(timedOut),
             "only HistoryDone plus a completed synchronous flush is a replay boundary")
    // The retry budget grows with cursor age, well before the six-hour expiry.
    let budgets = [0.0, 1_800, 3_600, 7_200, 18_000, 21_000].map { inventoryReplayBudget(cursorAge: $0) }
    try test(budgets == [30, 30, 60, 120, 300, 300] && zip(budgets, budgets.dropFirst()).allSatisfy { $0 <= $1 } && maxReplayAge == 21_600,
             "repeated retries get 30 s growing to 300 s by five hours, before the six-hour expiry forces reconciliation")

    // A failed spill acknowledges nothing; the same changes are replayed and applied afterwards.
    let fixture = try ReconciliationFixture.make("spill", directories: 200)
    defer { fixture.remove(); inventoryReplaySpillFault = nil }
    let cursor = try fixture.scalar("SELECT event_id FROM inventory_event_cursor")
    try fixture.touch(Array(0..<120), tag: "spill")
    fixture.settle()
    inventoryReplaySpillFault = Failure("injected spill failure")
    var failed = false
    do { _ = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region, pathMemoryLimit: 25) } catch { failed = "\(error)".contains("injected") }
    inventoryReplaySpillFault = nil
    try test(failed && (try fixture.scalar("SELECT event_id FROM inventory_event_cursor")) == cursor, "a spill failure at the memory limit aborts without advancing the cursor")
    let replayed = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region, pathMemoryLimit: 25)
    _ = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 60), fdaOverride: "granted")
    try test(replayed.outcome == .applied && replayed.paths >= 120 && (try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name='spill'")) == 120 && (try fixture.scalar("SELECT event_id FROM inventory_event_cursor")) > cursor,
             "after the failure the same history is replayed: all 120 changes spilled in batches of 25 are applied, then acknowledged")

    // A replay that keeps delivering is never abandoned by its budget (a retry would redo all of it);
    // only a stall, or the guard ceiling, ends it. Coverage keeps its wall-clock deadline.
    let t0 = Date(timeIntervalSince1970: 1_000)
    let fixed = replayDeadline(started: t0, lastDelivery: t0.addingTimeInterval(500), timeout: 30, whileDelivering: false, ceiling: 1_800)
    let silent = replayDeadline(started: t0, lastDelivery: nil, timeout: 30, whileDelivering: true, ceiling: 1_800)
    let delivering = replayDeadline(started: t0, lastDelivery: t0.addingTimeInterval(500), timeout: 30, whileDelivering: true, ceiling: 1_800)
    let capped = replayDeadline(started: t0, lastDelivery: t0.addingTimeInterval(1_790), timeout: 30, whileDelivering: true, ceiling: 1_800)
    try test(fixed == t0.addingTimeInterval(30) && silent == t0.addingTimeInterval(30) && delivering == t0.addingTimeInterval(530) && capped == t0.addingTimeInterval(1_800) && inventoryReplayCeiling == 1_800,
             "an inventory replay still delivering after its 30 s budget keeps running; a 30 s stall or the 30-minute guard ends it")

    // A quiet interval (no event since the cursor) is a complete boundary: it is acknowledged, so
    // the acknowledgement time advances and an idle volume never ages into the six-hour expiry.
    let quietCursor = try fixture.scalar("SELECT event_id FROM inventory_event_cursor")
    let acknowledgedBefore = Double(try fixture.rows("SELECT acknowledged_at FROM inventory_event_cursor").first?["acknowledged_at"] ?? "") ?? 0
    Thread.sleep(forTimeInterval: 0.05)
    let quiet = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region,
                                             markerOverride: EventMarker(eventId: UInt64(quietCursor), device: currentEventMarker(fixture.region.root).device))
    let acknowledgedAfter = Double(try fixture.rows("SELECT acknowledged_at FROM inventory_event_cursor").first?["acknowledged_at"] ?? "") ?? 0
    try test(quiet.outcome == .applied && acknowledgedAfter > acknowledgedBefore && (try fixture.scalar("SELECT event_id FROM inventory_event_cursor")) == quietCursor && (try fixture.reconcile().rows) == 0,
             "a quiet interval is acknowledged rather than retried, so its cursor never expires into a full reconciliation")
}

private func structuralChangeTests(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ReconciliationFixture.make("structural", directories: 40)
    let image = fixture.root + "-image.dmg", mountpoint = fixture.root + "/mounted"
    var mounted = false
    defer {
        if mounted { _ = try? run("/usr/bin/hdiutil", ["detach", mountpoint, "-force"], timeout: 30) }
        _ = chmod(fixture.folder(3), 0o755); try? fm.removeItem(atPath: image); fixture.remove()
    }
    try fm.removeItem(atPath: fixture.folder(1))                                                    // deleted
    try fm.removeItem(atPath: fixture.folder(2))
    try fm.createDirectory(atPath: fixture.folder(2) + "/new", withIntermediateDirectories: true)     // replaced
    try Data([4]).write(to: URL(fileURLWithPath: fixture.folder(3) + "/before-lock")); _ = chmod(fixture.folder(3), 0o000) // permission failure
    try fm.createDirectory(atPath: mountpoint, withIntermediateDirectories: true)
    let created = try run("/usr/bin/hdiutil", ["create", "-size", "2m", "-fs", "HFS+", "-volname", "SMReconcileTest", "-layout", "NONE", image], timeout: 60)
    if created.status == 0, try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountpoint, image], timeout: 60).status == 0 {
        mounted = true
        for index in 0..<20 { try Data([5]).write(to: URL(fileURLWithPath: mountpoint + "/inside-\(index)")) }
    }
    fixture.settle()
    let replay = try reconcileInventoryEvents(database: fixture.database, directory: fixture.state, region: fixture.region)
    var outcome = ""
    for _ in 0..<3 {
        outcome = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region, options: InventoryRunOptions(maxDuration: 60), fdaOverride: "granted").outcome
        if try fixture.idle() { break }
    }
    try test(replay.outcome == .applied && (try fixture.reconcile().rows) == 0, "deletions, a replacement, a permission change and a new mount are applied without a full reconciliation")
    try test((try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name='d1'")) == 0, "a deleted folder is pruned through generation-safe cleanup")
    try test((try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name='new'")) == 1 && (try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes n JOIN inventory_nodes p ON p.id=n.parent_id WHERE p.name='d2' AND n.name='f'")) == 0,
             "a replaced folder is relisted with its new contents and none of the old")
    try test((try fixture.rows("SELECT status FROM inventory_nodes WHERE name='d3'").first?["status"]) == "unknown" && (try fixture.idle()), "a folder that became unreadable is recorded unavailable and does not loop")
    if mounted {
        try test((try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE name LIKE 'inside-%'")) == 0 && (try fixture.rows("SELECT status FROM inventory_nodes WHERE name='mounted'").first?["status"]) == "excluded",
                 "a volume mounted inside the root stays outside the measured scope; its file events queue no work")
    } else { print("SKIP mount boundary (hdiutil unavailable)") }
    try test(outcome == "partial" || outcome == "complete", "the structural fixture reaches a terminal state (\(outcome))")
}

private func steadyStateScenarioTests(_ test: (Bool, String) throws -> Void) throws {
    let report = try reconciliationScenarios()
    func scenario(_ name: String) -> [String: Any] { report[name] as? [String: Any] ?? [:] }
    let high = scenario("high_volume_4500_changed"), slow = scenario("slow_replay_50_changed"), sustained = scenario("sustained_activity_6_slices_x_4200")
    let loss = scenario("genuine_loss_with_interruptions_and_second_gap"), frontier = scenario("changes_behind_and_ahead_of_frontier")
    try test(high["full_reconciliations_started"] as? Int == 0 && (high["directory_listings"] as? Int64 ?? .max) < 6_000 && high["reached_idle"] as? Bool == true && high["catalog_matches_disk"] as? Bool == true,
             "no full-volume traversal without cause: 4,500 changes in 12,000 folders cost \(high["directory_listings"] ?? "?") listings")
    try test(slow["timed_out_slice_started_full_reconciliation"] as? Bool == false && slow["slow_files_captured"] as? Int64 == 50 && slow["reached_idle"] as? Bool == true,
             "a slow replay starts no full reconciliation and still captures its 50 changes")
    try test(sustained["frontier_resets"] as? Int == 0 && sustained["full_reconciliations_started"] as? Int == 0 && sustained["reached_idle"] as? Bool == true && sustained["catalog_matches_disk"] as? Bool == true,
             "sustained activity (6 × 4,200 changed folders) makes forward progress and reaches idle once activity settles (\(sustained["slices"] ?? "?") slices)")
    try test(loss["loss_started_full_reconciliation"] as? Bool == true && loss["frontier_persisted_across_runs"] as? Bool == true && loss["second_gap_reset_frontier"] as? Bool == true && loss["reached_idle"] as? Bool == true,
             "genuine loss reconciles durably across slice and process boundaries; a second genuine loss restarts the frontier and still finishes")
    try test(frontier["changed_files_captured"] as? Int64 == 2 && frontier["reached_idle"] as? Bool == true && frontier["catalog_matches_disk"] as? Bool == true,
             "changes behind and ahead of the reconciliation frontier are both captured")
}
#endif
