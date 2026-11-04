import Foundation
import CoreServices
import Darwin
import SQLite3

let inventoryLabel = "local.macbook.storage-monitor.inventory"
let inventoryAgentURL = home.appendingPathComponent("Library/LaunchAgents/\(inventoryLabel).plist")

/// Scheduling (STORAGE-MONITOR-INSTALL-READINESS.md): launchd starts the worker at load/login, when the
/// viewer writes a request, and again after a non-zero exit (75: work remains). Exit 0 leaves it idle
/// until the scheduled capacity check kickstarts it (every :00/:30, coalesced after sleep). The slice
/// matches the verified QA configuration; a 20 s slice could end before a changing directory reaches its
/// retry limit, so it would never be deferred and the worker would relaunch every minute.
let inventoryAgentBudget = 1_200
func inventoryAgentPlist(_ executable: String, _ data: String) -> [String: Any] {
    ["Label": inventoryLabel, "ProgramArguments": [executable, "inventory-work", "--budget", String(inventoryAgentBudget), "--data-dir", data],
     "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 60,
     "WatchPaths": [URL(fileURLWithPath: data).appendingPathComponent("inventory-requests").path],
     "ProcessType": "Background", "LowPriorityIO": true, "Nice": 15, "Umask": 63,
     "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
     "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]]
}

// Same FSEvents implementation/history as coverage, with a separately acknowledged cursor:
// inventory may be interrupted for much longer than a capacity check. A monitor cursor cannot
// acknowledge work on inventory's behalf. No filesystem indexing is done in the monitor process.
//
// Steady-state rule (INVENTORY-RECONCILIATION-STEADY-STATE.md): only actual loss of event coverage
// (dropped/wrapped events, root change or root rescan, identity change, expired or regressed
// cursor) schedules a full-volume reconciliation. Many changed directories are applied as targeted
// relistings; a replay that does not finish (or cannot start) is retried from the same cursor.
struct InventoryEventReplay {
    enum Outcome: String { case applied, retry, gap, identity }
    let outcome: Outcome
    let events: Int, paths: Int
    let seconds: Double
    let reason: String
}

/// A replay is a completed boundary only when history finished and the stream was then flushed
/// synchronously. Event IDs arrive out of order, so no observed ID is ever used as proof.
func inventoryReplayBoundaryComplete(_ activity: CoverageActivity) -> Bool {
    activity.historyDone && activity.flushed && !activity.timedOut && !activity.streamUnavailable
}
/// The budget bounds a stall (no event delivered), not the replay: a replay that keeps delivering runs
/// until HistoryDone, up to `inventoryReplayCeiling`. A retry leaves the cursor (and its acknowledgement
/// time) unchanged, so the stall budget grows with cursor age: 30 s, up to 300 s at five hours.
func inventoryReplayBudget(cursorAge: TimeInterval) -> TimeInterval { min(300, max(30, cursorAge / 60)) }
/// Twenty minutes of the QA volume's history took 7-12 s to reach HistoryDone (the old fixed 5 s
/// timeout failed every slice); six hours extrapolates to a few minutes. The ceiling only guards
/// against an event service that never finishes.
let inventoryReplayCeiling = maxReplayAge / 12
#if INVENTORY_TESTS
var inventoryReplaySpillFault: Error?
var inventoryReplaySimulatedTimeout = false   // a replay that did not reach HistoryDone, without racing real FSEvents
/// Synthetic callbacks (device-relative path, flags, ID) delivered before the real replay; given the marker ID.
var inventoryReplayInjectedEvents: ((UInt64) -> [(String, UInt32, UInt64)])?
#endif

@discardableResult
func reconcileInventoryEvents(database: String, directory: URL, region: CoverageRegion, timeout: TimeInterval? = nil, markerOverride: EventMarker? = nil,
                              pathMemoryLimit: Int = 262_144, simulateLoss: Bool = false) throws -> InventoryEventReplay {
    let profile = InventoryProfile.current, began = DispatchTime.now().uptimeNanoseconds, started = Date()
    defer { if let profile { profile.nanoseconds["fsevents_reconciliation", default: 0] += DispatchTime.now().uptimeNanoseconds - began } }
    func result(_ outcome: InventoryEventReplay.Outcome, events: Int = 0, paths: Int = 0, _ reason: String) -> InventoryEventReplay {
        let replay = InventoryEventReplay(outcome: outcome, events: events, paths: paths, seconds: Date().timeIntervalSince(started), reason: reason)
        log(directory, "inventory events {\"outcome\":\"\(outcome.rawValue)\",\"events\":\(events),\"paths\":\(paths),\"seconds\":\(String(format: "%.2f", replay.seconds)),\"reason\":\"\(reason)\"}")
        return replay
    }
    let marker = markerOverride ?? currentEventMarker(region.root)
    guard let uuid = marker.device else {
        try noteInventoryEventIdentityUnavailable(databasePath: database, reason: "File-event history identity unavailable; inventory values remain stale until event identity recovers")
        return result(.identity, "event identity unavailable")
    }
    if try noteInventoryEventIdentityAvailable(databasePath: database, deviceIdentifier: uuid, eventID: marker.eventId,
                                               reason: "File-event history identity recovered; full reconciliation required") { return result(.identity, "event identity recovered") }
    guard let cursor = try loadInventoryEventCursor(databasePath: database, deviceIdentifier: uuid),
          cursor.eventID <= marker.eventId,
          cursor.age() < maxReplayAge else {
        try invalidateInventory(databasePath: database, paths: [], eventID: marker.eventId, gap: true, reason: "File-event history identity changed or cursor expired", deviceIdentifier: uuid)
        return result(.gap, "cursor missing, regressed or older than the replay window")
    }
    let store = CoverageStore()
    store.create(path: "", at: Date().timeIntervalSince1970)
    let activity = CoverageActivity(store: store, region: region, until: marker.eventId)
    activity.countFrom = cursor.eventID
    // Changed directories are collected without a count limit. Memory is bounded by spilling to
    // durable invalidations; IDs arrive out of order, so the cursor only ever moves to the marker.
    var paths = Set<String>(), recursive = Set<String>(), events = 0, spilled = 0
    var spillError: Error?, dropped = false
    let operational = region.relative(fromDevice: dataRelative(directory.path) ?? directory.path)
    // Spilled paths are durable before they leave memory; the cursor is acknowledged only after
    // every write succeeded. Any failure aborts without acknowledgement, so history is replayed again.
    func spill(_ batch: [String], subtree: Bool = false) {
        guard spillError == nil else { return }
        do {
            #if INVENTORY_TESTS
            if let fault = inventoryReplaySpillFault { throw fault }
            #endif
            for start in stride(from: 0, to: batch.count, by: 4_096) {
                try invalidateInventory(databasePath: database, paths: Array(batch[start..<min(batch.count, start + 4_096)]), eventID: nil, gap: subtree,
                                        reason: subtree ? "Subtree file-event gap" : "Filesystem activity", deviceIdentifier: uuid)
            }
            if !subtree { spilled += batch.count }
        } catch { spillError = error }
    }
    activity.onEvent = { path, flags, id in
        // FSEvents.h: a drop means this stream lost events and the client must rescan everything it
        // monitors. The drop's ID does not identify which events were lost, so it is loss at any ID.
        if flags & (UInt32(kFSEventStreamEventFlagUserDropped) | UInt32(kFSEventStreamEventFlagKernelDropped)) != 0 { dropped = true; return }
        guard id > cursor.eventID, id <= marker.eventId,
              flags & UInt32(kFSEventStreamEventFlagHistoryDone) == 0,
              spillError == nil, let relative = region.relative(fromDevice: path) else { return }
        if let operational, relative == operational || relative.hasPrefix(operational + "/") { return }
        events += 1
        let isDirectory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        paths.insert(region.absolute(parentPath(relative)))
        if isDirectory { paths.insert(region.absolute(relative)) }
        if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { recursive.insert(region.absolute(relative)) }
        if paths.count + recursive.count >= pathMemoryLimit {
            spill(Array(paths)); spill(Array(recursive), subtree: true)
            paths.removeAll(keepingCapacity: true); recursive.removeAll(keepingCapacity: true)
        }
    }
    let budget = timeout ?? inventoryReplayBudget(cursorAge: cursor.age())
    #if INVENTORY_TESTS
    for (path, flags, id) in inventoryReplayInjectedEvents?(marker.eventId) ?? [] { activity.handle(path, flags, id) }
    #endif
    replayCoverage(activity, since: cursor.eventID, timeout: budget, whileDelivering: true, ceiling: inventoryReplayCeiling)
    #if INVENTORY_TESTS
    if inventoryReplaySimulatedTimeout { activity.timedOut = true }
    #endif
    if let spillError { throw spillError }
    let changed = spilled + paths.count
    if activity.lossDetected || dropped || simulateLoss {
        try invalidateInventory(databasePath: database, paths: [], eventID: marker.eventId, gap: true,
                                reason: "File-event gap; bounded reconciliation required", deviceIdentifier: uuid)
        return result(.gap, events: events, paths: changed, activity.gaps.first ?? (dropped ? "File events were dropped by macOS" : "simulated event loss"))
    }
    if !inventoryReplayBoundaryComplete(activity) {
        // Not loss: history remains available. Apply what was seen and replay again next time from
        // the unchanged cursor, with a budget that grows with cursor age.
        spill(Array(paths)); spill(Array(recursive), subtree: true)
        if let spillError { throw spillError }
        return result(.retry, events: events, paths: changed, activity.streamUnavailable ? "event stream unavailable" : "replay stalled for \(Int(budget)) s or exceeded \(Int(inventoryReplayCeiling)) s")
    }
    let all = Array(paths)
    for start in stride(from: 0, to: max(all.count, 1), by: 4_096) where start < all.count {
        try invalidateInventory(databasePath: database, paths: Array(all[start..<min(all.count, start + 4_096)]), eventID: nil, gap: false, reason: "Filesystem activity", deviceIdentifier: uuid)
    }
    let subtrees = Array(recursive)
    for start in stride(from: 0, to: subtrees.count, by: 4_096) {
        try invalidateInventory(databasePath: database, paths: Array(subtrees[start..<min(subtrees.count, start + 4_096)]), eventID: nil, gap: true, reason: "Subtree file-event gap", deviceIdentifier: uuid)
    }
    // Acknowledge only after every changed directory is durably queued.
    try invalidateInventory(databasePath: database, paths: [], eventID: marker.eventId, gap: false, reason: "Filesystem activity", deviceIdentifier: uuid)
    return result(.applied, events: events, paths: changed, "replayed")
}

func consumeInventoryRequests(database: String, directory: URL, region: CoverageRegion) throws {
    // Runs on every batch inside one long worker task, which never drains an autorelease pool: each
    // FileManager enumeration left its enumerator, URLs and errors alive for the rest of the run
    // (about 1 MB a minute in the 1.0.3 production worker; `heap` showed one set per call).
    try autoreleasepool { try consumeInventoryRequestsNow(database: database, directory: directory, region: region) }
}

private func consumeInventoryRequestsNow(database: String, directory: URL, region: CoverageRegion) throws {
    let folder = InventoryRequests.directory(database: database)
    guard let entries = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return }
    // Atomically claim the coalesced slot before decoding. A newer navigation can
    // replace focus.json while this claimed file is consumed without being erased.
    let focus = folder.appendingPathComponent("focus.json")
    let claimed = folder.appendingPathComponent("focus-claimed.json")
    if !fm.fileExists(atPath: claimed.path), fm.fileExists(atPath: focus.path) {
        if rename(focus.path, claimed.path) != 0 && errno != ENOENT { throw CocoaError(.fileWriteUnknown) }
    }
    if fm.fileExists(atPath: claimed.path) {
        var info = stat()
        let valid = lstat(claimed.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_size <= 65_536
        var request: InventoryWorkRequest?
        if valid {
            do { request = try JSONDecoder().decode(InventoryWorkRequest.self, from: Data(contentsOf: claimed)) }
            catch is DecodingError { log(directory, "Ignored malformed inventory focus request") }
        } else { log(directory, "Ignored invalid inventory focus request metadata") }
        if let request, request.action == "focus", let path = request.path {
            try NativeQARuntime.active?.validateRequest(path, action: request.action)
            do { try requestInventoryFocus(databasePath: database, path: path, requestedAt: request.requestedAt.timeIntervalSince1970) }
            catch InventoryEngineError.invalidRoot(_) { log(directory, "Ignored out-of-scope inventory focus request") }
            // SQL/I/O failures propagate with the claimed file retained for recovery.
        }
        try fm.removeItem(at: claimed)
    }
    var count = 0
    for case let url as URL in entries {
        guard count < 256 else { break }
        guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 65_536 else { continue }
        let request = try JSONDecoder().decode(InventoryWorkRequest.self, from: Data(contentsOf: url))
        try NativeQARuntime.active?.validateRequest(request.path, action: request.action)
        switch request.action {
        case "pause", "resume": break // enqueue applies current intent immediately; old requests cannot reverse it
        case "refresh":
            var path = request.path ?? region.root
            if let relative = dataRelative(path, mount: region.mount).flatMap({ region.relative(fromDevice: $0) }) { path = region.absolute(relative) }
            try required(path == region.root || path.hasPrefix(region.root + "/"), "Refresh path is outside the inventory root")
            let boundary = request.boundary
            let applicable = try boundary.map { try inventoryRequestBoundaryIsCurrent(databasePath: database, boundary: $0) } ?? false
            try requestInventoryRefresh(databasePath: database, paths: [path], requiredSequence: applicable ? boundary?.sequence : nil, endNodeID: applicable ? boundary?.endNodeID : nil)
        default: throw Failure("Unrecognized inventory request")
        }
        // Only this immutable UUID request is consumed; concurrent requests have different names.
        try fm.removeItem(at: url); count += 1
    }
}

/// Exit status for a worker run, or nil for a successful (idle) exit. With KeepAlive SuccessfulExit=false
/// launchd relaunches 60 s after a non-zero status, so 75 is returned only when the main run stopped at
/// its budget with listings it could still run (a long first pass). Drained, paused, busy and deferred-
/// only runs exit 0; changes queued by the closing replay wait for the next scheduled or request wake.
func inventoryWorkExitCode(_ main: InventoryRunResult) -> Int32? {
    main.runnableWorkRemains ? 75 : nil
}

/// What a worker run did, for its log line (D12). `outcome` keeps the engine's state word for
/// compatibility; a drained run whose closing replay queued new changes is still "completed".
/// Peak physical footprint (what macOS charges this process, as Activity Monitor's Memory shows).
/// Unlike `ru_maxrss` it excludes clean, reclaimable pages; both are logged to attribute peaks.
func peakFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? Int64(info.ledger_phys_footprint_peak) : -1
}

func inventoryRunStatus(_ main: InventoryRunResult) -> String {
    if main.outcome == "failed" { return "failed" }
    if main.outcome == "busy" { return "skipped" }
    if main.reason == "cancelled" || main.reason == inventoryLowSpaceReason { return "paused" }
    if main.runnableWorkRemains { return "continuing" }
    if main.reason == inventoryDeferredReason { return "deferred" }
    return "completed"
}

func inventoryCommand(_ command: String, args: [String], directory: URL) async throws {
    func value(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.count > i + 1 else { return nil }; return args[i + 1] }
    let database = directory.appendingPathComponent("history.sqlite3").path
    let reader = InventoryReader(path: database)
    func output<T: Encodable>(_ value: T) throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601; print(String(decoding: try encoder.encode(value), as: UTF8.self)) }
    let limit = min(256, max(1, Int(value("--limit") ?? "100") ?? 100))
    let offset = max(0, Int(value("--offset") ?? "0") ?? 0)
    let under = value("--under").flatMap(Int64.init)
    switch command {
    case "inventory-status": try await output(reader.status())
    case "inventory-children":
        var id = args.dropFirst().first.flatMap(Int64.init)
        if id == nil { id = try await reader.root()?.id }
        guard let id else { print("No inventory root"); return }
        try await output(reader.children(parentID: id, offset: offset, limit: limit, sort: InventorySort(rawValue: value("--sort") ?? "name") ?? .name))
    case "inventory-largest": try await output(reader.largest(kind: InventoryLargestKind(rawValue: args.dropFirst().first ?? "files") ?? .files, under: under, offset: offset, limit: limit))
    case "inventory-search": try await output(reader.search(text: args.dropFirst().first ?? "", under: under, offset: offset, limit: limit))
    case "inventory-request":
        let id = try InventoryRequests.enqueue(database: database, action: "refresh", path: value("--path")); print("Queued inventory refresh \(id)")
    case "inventory-cancel": try cancelInventory(directory: directory); print("Inventory pause requested; committed partial results are retained.")
    case "inventory-resume": _ = try InventoryRequests.enqueue(database: database, action: "resume"); print("Inventory resume requested.")
    case "inventory-initialize", "inventory-update", "inventory-work":
        try privateDirectory(directory)
        guard let commandLock = FileLock(directory.appendingPathComponent("inventory-command.lock").path, wait: 0) else { throw Failure("Another inventory command is active") }
        defer { withExtendedLifetime(commandLock) {} }
        let region: CoverageRegion
        if let root = value("--root") {
            try required(directory.standardizedFileURL != defaultData.standardizedFileURL, "A scoped inventory requires an isolated data directory")
            guard let candidate = coverageRegion(root: root) else { throw Failure("Inventory root must be a directory on the startup Data volume") }
            if let runtime = NativeQARuntime.active {
                // The normal Data-volume region uses /System/Volumes/Data spellings. QA keeps
                // the already validated exact fixture spelling as its region boundary instead.
                guard root == runtime.fixtures, directory.path == runtime.support, database == runtime.database else {
                    try NativeQARuntime.reject("worker database/root does not match profile")
                }
                try runtime.validateStorage()
                region = CoverageRegion(mount: runtime.fixtures, prefix: "", device: candidate.device, deviceIdentifier: candidate.deviceIdentifier)
            } else if let scope = LifecycleQAScope.active {
                guard root == scope.fixtures, directory.path == scope.data.path, database == scope.database else { try LifecycleQAScope.refuse("inventory data/root mismatch") }
                try scope.admit(command: command); try scope.validateFixtures()
                region = CoverageRegion(mount: scope.fixtures, prefix: "", device: candidate.device, deviceIdentifier: candidate.deviceIdentifier)
            } else { region = candidate }
        } else {
            if LifecycleQAScope.active != nil { try LifecycleQAScope.refuse("inventory requires the explicit fixture root") }
            guard let candidate = startupDataRegion(try? measure()).region else { throw Failure("Startup Data volume unavailable") }
            region = candidate
        }
        let started = Date()
        let fda = NativeQARuntime.active != nil || LifecycleQAScope.active != nil ? "qa-fixtures-only" : fullDiskAccessState()
        if directory.standardizedFileURL == defaultData.standardizedFileURL,
           fm.fileExists(atPath: database) {
            var source: OpaquePointer?, statement: OpaquePointer?
            defer { sqlite3_finalize(statement); sqlite3_close(source) }
            try required(sqlite3_open_v2(database, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                         "Cannot inspect production history before inventory migration")
            sqlite3_busy_timeout(source, inventoryWorkerBusyTimeout)
            try required(sqlite3_prepare_v2(source, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='inventory_generations'", -1, &statement, nil) == SQLITE_OK,
                         "Cannot inspect inventory migration state")
            let migrationState = sqlite3_step(statement)
            try required(migrationState == SQLITE_ROW || migrationState == SQLITE_DONE,
                         "Cannot read inventory migration state; no production changes made")
            if migrationState == SQLITE_DONE {
                sqlite3_finalize(statement); statement = nil
                sqlite3_close(source); source = nil
                // First production inventory use must preserve a verified pre-migration
                // database even when invoked directly instead of through install().
                guard let backup = try backupDatabase(directory, keep: Int.max) else { throw Failure("Inventory migration requires a verified history backup") }
                log(directory, "Verified pre-inventory history backup: \(backup.lastPathComponent)")
            }
        }
        // This connection only establishes the existing monitor schema in a NEW scratch database;
        // inventory tables are migrated by the separate explicit inventory initializer.
        let legacy = try Database(database, busyTimeout: inventoryWorkerBusyTimeout)
        // Full Disk Access belongs to this process (the helper launchd runs), not to the viewer, so the
        // viewer reads what the worker itself observed.
        try? legacy.state("inventory_full_disk_access", fda)
        let gate: ConsentGate = NativeQARuntime.active != nil || LifecycleQAScope.active != nil ? [] : coverageGate(legacy, region: region, fda: fda)
        try initializeInventorySchema(databasePath: database)
        try consumeInventoryRequests(database: database, directory: directory, region: region)
        if args.contains("--resume") {
            let cancel = directory.appendingPathComponent("inventory.cancel")
            if fm.fileExists(atPath: cancel.path) { try fm.removeItem(at: cancel) }
        }
        if try await reader.root() != nil { try reconcileInventoryEvents(database: database, directory: directory, region: region, timeout: NativeQARuntime.active != nil || LifecycleQAScope.active != nil ? 0.1 : nil) }
        let budget = min(3_600, max(0.01, Double(value("--budget") ?? "20") ?? 20))
        var result = runInventory(databasePath: database, directory: directory, region: region,
                                  options: InventoryRunOptions(maxDuration: budget, batchSize: Int(value("--batch") ?? "256") ?? 256,
                                                               stopAfterEntries: value("--stop-after").flatMap(Int.init), cancelFile: directory.appendingPathComponent("inventory.cancel").path, serviceRequests: true),
                                  fdaOverride: fda, gatedOverride: gate)
        let main = result
        if ["complete", "partial"].contains(result.outcome), result.reason != "cancelled" {
            // A successful final batch must not acknowledge events that arrived while it
            // was walking. Replay once more and persist invalidation before going idle.
            // Do not extend this process into an unbounded catch-up loop on a busy disk.
            try consumeInventoryRequests(database: database, directory: directory, region: region)
            try reconcileInventoryEvents(database: database, directory: directory, region: region, timeout: NativeQARuntime.active != nil || LifecycleQAScope.active != nil ? 0.1 : nil)
            let final = runInventory(databasePath: database, directory: directory, region: region,
                                     options: InventoryRunOptions(maxDuration: 0, cancelFile: directory.appendingPathComponent("inventory.cancel").path),
                                     fdaOverride: fda, gatedOverride: gate)
            result = InventoryRunResult(outcome: final.outcome, generation: final.generation,
                                        entries: result.entries, directories: result.directories,
                                        pending: final.pending, reason: final.reason)
        }
        let summary: [String: Any] = ["outcome": result.outcome, "generation": result.generation as Any, "entries": result.entries, "directories": result.directories,
                                      "pending": result.pending, "reason": result.reason ?? "", "seconds": Date().timeIntervalSince(started), "peak_memory_bytes": peakMemoryBytes(), "full_disk_access": fda,
                                      "continues": main.runnableWorkRemains, "status": inventoryRunStatus(main),
                                      "peak_footprint_bytes": peakFootprintBytes()]
        print(json(summary)); log(directory, "inventory \(json(summary))")
        if result.outcome == "failed" {
            // Logged above. A failing background worker waits for the next scheduled wake instead of
            // being relaunched by launchd every minute.
            if command == "inventory-work", NativeQARuntime.active == nil { exit(0) }
            throw Failure(result.reason ?? "Inventory failed")
        }
        if command == "inventory-work", let code = inventoryWorkExitCode(main) { exit(code) }
    default: throw Failure("Unknown inventory command")
    }
}
