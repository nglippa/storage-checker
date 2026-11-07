import Foundation
import Combine

/// Deterministic presentation regressions; no production state, processes or native windows.
func correctnessPresentationTests(_ test: (Bool, String) throws -> Void) throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let reading = LiveCapacityReading(timestamp: now, free: 20 * decimalGB, total: 100 * decimalGB, dataVolumeUUID: "fixture")
    let failedSameTick = LiveCapacityState(reading: reading, lastAttempt: now, lastError: "failed")
    try test(failedSameTick.freshness(at: now) == .stale, "a failed refresh in the same clock tick never advertises a current live reading")
    let malformed = LaunchdState.parse(list: "unrecognized output\nnot-a-job\n", disabled: "")
    try test(malformed.loaded.isEmpty, "malformed launchctl output never invents a registered job")

    let current = CapacityPresentation(state: .init(reading: reading), recorded: nil, now: now)
    try test(current.status == .current && current.isCurrent && current.free == reading.free && current.used == 80 * decimalGB, "capacity success has one current value and preserves physical accounting")
    let failure = CapacityPresentation(state: failedSameTick, recorded: nil, now: now)
    try test(failure.status == .failed && !failure.isCurrent && failure.free == current.free && failure.total == current.total && failure.timestamp == now, "failed capacity retains and dates the last good value without presenting it as current")
    let firstFailure = CapacityPresentation(state: .init(lastAttempt: now, lastError: "failed"), recorded: nil, now: now)
    try test(firstFailure.status == .failed && firstFailure.free == nil && firstFailure.total == nil && firstFailure.used == nil, "first capacity failure has missing values, never zero or perpetual loading")
    let empty = CapacityPresentation(state: .init(), recorded: nil, now: now)
    try test(empty.status == .unavailable && empty.source == .none && empty.free == nil, "no capacity attempt is unavailable, not fabricated capacity")
    let refreshing = CapacityPresentation(state: .init(reading: reading, isRefreshing: true), recorded: nil, now: now)
    try test(refreshing.status == .refreshing && !refreshing.isCurrent && refreshing.free == reading.free, "in-flight capacity refresh is explicit and retains the previous success")
    let firstRefresh = CapacityPresentation(state: .init(isRefreshing: true), recorded: nil, now: now)
    try test(firstRefresh.status == .refreshing && firstRefresh.free == nil, "first refresh shows progress only while a request is running")
    try test(CapacityPresentation(state: .init(reading: reading), recorded: nil, now: now.addingTimeInterval(180)).status == .current
             && CapacityPresentation(state: .init(reading: reading), recorded: nil, now: now.addingTimeInterval(181)).status == .stale, "both sections cross the same capacity age boundary without another probe")
    try test(CapacityPresentation(state: .init(reading: reading), recorded: nil, now: now.addingTimeInterval(-1)).status == .stale, "future-dated capacity after a clock change is never presented as current")
    let recorded = Measurement(id: 1, timestamp: now.addingTimeInterval(-3600), container: "fixture", free: 10 * decimalGB, used: 90 * decimalGB, volumes: [])
    let fallback = CapacityPresentation(state: .init(), recorded: recorded, now: now)
    try test(fallback.status == .previous && fallback.source == .recorded && fallback.free == recorded.free && fallback.timestamp == recorded.timestamp, "recorded fallback stays previous and retains its timestamp")
    let failedFallback = CapacityPresentation(state: .init(lastAttempt: now, lastError: "failed"), recorded: recorded, now: now)
    try test(failedFallback.status == .failed && failedFallback.source == .recorded && failedFallback.free == recorded.free && !failedFallback.isCurrent, "recorded fallback cannot hide a failed live refresh")
    for seconds in [0.0, 60, 181, 500] {
        let state = LiveCapacityState(reading: reading, lastAttempt: now.addingTimeInterval(seconds), lastError: "failed")
        try test(CapacityPresentation(state: state, recorded: recorded, now: now.addingTimeInterval(seconds)).status == .failed, "repeated failed capacity attempt at \(seconds)s retains explicit failure")
    }
    let recovered = CapacityPresentation(state: .init(reading: .init(timestamp: now.addingTimeInterval(500), free: 30 * decimalGB, total: reading.total, dataVolumeUUID: "fixture")), recorded: recorded, now: now.addingTimeInterval(500))
    try test(recovered.status == .current && recovered.free == 30 * decimalGB, "a new capacity success clears failure and replaces previous values")

    let noInventory = InventoryStatus(generation: nil, state: "uninitialized", rootPath: nil, totalNodes: 0, completedDirectories: 0, pendingDirectories: 0, staleDirectories: 0, unknownDirectories: 0, queuedDirectoryJobs: 0, hasReconciliationWork: false, hasInitialDiscoveryWork: false, progress: nil, completeness: .unknown, reason: nil, updatedAt: nil, createdAt: nil, initialCompletion: .notStarted)
    func lifecycle(root: Bool = false, status: InventoryStatus? = nil, requested: Bool = false, loading: Bool = false, error: String? = nil, configured: Bool? = false) -> InventoryLifecyclePresentation {
        InventoryLifecyclePresentation(hasRoot: root, status: status, requested: requested, loading: loading, error: error, monitoringConfigured: configured)
    }
    try test(lifecycle(status: noInventory).state == .monitoringOff && lifecycle(status: noInventory).action == .openSettings && !lifecycle(status: noInventory).showsBrowser && !lifecycle(status: noInventory).showsProgress, "clean first launch resolves before renderer selection and offers Settings without a perpetual spinner")
    try test(lifecycle(status: noInventory, loading: true).state == .monitoringOff, "periodic reload does not turn first-run setup back into loading")
    try test(lifecycle(loading: true).state == .checking && lifecycle(loading: true).showsProgress, "an actual initial catalog read is checking")
    try test(lifecycle(status: noInventory, configured: true).state == .notCreated && lifecycle(status: noInventory, configured: true).action == .startIndexing, "configured helper with no generation offers deliberate first indexing")
    try test(lifecycle(status: noInventory, configured: nil).state == .notCreated && lifecycle(status: noInventory, configured: nil).action == .openSettings, "unknown configuration directs to Settings without inventing setup or starting a scan")
    try test(lifecycle(status: noInventory, requested: true).state == .indexing, "explicit first-index request waits for real results without a percentage")
    let failedIndexing = InventoryLifecyclePresentation(hasRoot: false, status: noInventory, requested: true, loading: false, error: nil, monitoringConfigured: true, indexingFailure: "Indexer could not start")
    try test(failedIndexing.state == .failed && failedIndexing.action == .retry && !failedIndexing.showsProgress, "an observed indexer failure ends initial waiting with recovery even before a database exists")
    func indexed(_ initial: InventoryInitialCompletion, _ completeness: InventoryValueStatus = .complete, pending: Int64 = 0, reconciling: Bool = false) -> InventoryStatus {
        InventoryStatus(generation: 1, state: initial == .inProgress ? "building" : "complete", rootPath: "/private/tmp/fixture", totalNodes: 1, completedDirectories: 1, pendingDirectories: pending, staleDirectories: completeness == .stale ? 1 : 0, unknownDirectories: 0, queuedDirectoryJobs: pending, hasReconciliationWork: reconciling, hasInitialDiscoveryWork: initial == .inProgress, progress: nil, completeness: completeness, reason: nil, updatedAt: now, createdAt: now, initialCompletion: initial)
    }
    var building = indexed(.inProgress)
    try test(lifecycle(status: building, configured: true).state == .indexing && !lifecycle(status: building, configured: true).showsBrowser, "first indexing without a root has a renderer-independent waiting state")
    try test(lifecycle(root: true, status: building).state == .indexing && lifecycle(root: true, status: building).showsBrowser, "first indexed results unlock the browser while discovery continues")
    building = indexed(.complete)
    try test(lifecycle(status: building, configured: true).state == .temporarilyUnavailable && lifecycle(status: building, configured: true).action == .retry && !lifecycle(status: building, configured: true).showsProgress, "completed catalog without root offers recovery instead of perpetual indexing")
    try test(lifecycle(root: true, status: building).state == .available && lifecycle(root: true, status: building).showsBrowser, "completed inventory reaches ordinary browsing")
    building = indexed(.complete, .stale)
    try test(lifecycle(root: true, status: building).state == .stale && lifecycle(root: true, status: building).showsBrowser, "stale inventory remains browseable with a qualification")
    try test(lifecycle(error: "fixture failure").state == .failed && lifecycle(error: "fixture failure").action == .retry && !lifecycle(error: "fixture failure").showsProgress, "failed first catalog read offers retry and stops loading")
    try test(lifecycle(root: true, status: building, error: "fixture failure").state == .temporarilyUnavailable && lifecycle(root: true, status: building, error: "fixture failure").showsBrowser, "temporary read failure keeps prior catalog results visible")

    // Disabling monitoring retains the catalog queue without advertising active work.
    let queued = indexed(.complete, .stale, pending: 2)
    let waiting = InventoryStatusPresentation(status: queued, monitoringEnabled: false)
    let enabled = InventoryStatusPresentation(status: queued, monitoringEnabled: true)
    try test(waiting.updatesAreWaiting && waiting.phase == .idle && waiting.headline == "Folder updates are waiting" && waiting.detail.contains("Settings"), "disabled queued work is waiting with recovery, never an active update")
    try test(waiting.condition == enabled.condition && waiting.activeListings == enabled.activeListings && waiting.foundFolders == enabled.foundFolders && waiting.affectedDirectories == enabled.affectedDirectories, "disabling monitoring preserves queued counts and inventory coverage")
    try test(enabled.phase == .updating && !enabled.updatesAreWaiting && InventoryStatusPresentation(status: queued).phase == .updating, "enabling resumes update presentation and unknown service evidence does not invent an off state")
    try test(!InventoryStatusPresentation(status: indexed(.complete), monitoringEnabled: false).updatesAreWaiting && InventoryStatusPresentation(status: indexed(.complete), monitoringEnabled: false).condition == .current, "completed inventory without pending work does not invent a waiting queue")
    var reconciling = indexed(.complete, .stale, pending: 2, reconciling: true)
    reconciling.hasEventGapRecheck = true; reconciling.refreshIsManual = true; reconciling.refreshFraction = 0.25
    try test(InventoryStatusPresentation(status: reconciling, monitoringEnabled: false).phase == .idle && InventoryStatusPresentation(status: reconciling, monitoringEnabled: false).condition == .needsReconciliation, "disabled reconciliation keeps its qualification without claiming an active event-gap or manual refresh")
    let firstPassWaiting = InventoryStatusPresentation(status: indexed(.inProgress), monitoringEnabled: false)
    try test(firstPassWaiting.updatesAreWaiting && firstPassWaiting.headline == "Indexing is waiting" && firstPassWaiting.condition == .initialInventory, "disabled first pass remains incomplete with no moving progress claim")
    var pausedQueue = queued; pausedQueue.lowSpacePaused = true
    let pausedWaiting = InventoryStatusPresentation(status: pausedQueue, monitoringEnabled: false)
    try test(pausedWaiting.condition == .paused && pausedWaiting.headline.contains("disk space is low") && pausedWaiting.detail.contains("also off"), "disabled services do not hide a low-space safety pause")
    var unavailableQueue = queued; unavailableQueue.eventHistoryUnavailable = true
    try test(InventoryStatusPresentation(status: unavailableQueue, monitoringEnabled: false).condition == .unavailable && InventoryStatusPresentation(status: unavailableQueue, monitoringEnabled: false).headline == "Changes can't be tracked right now", "disabled services do not hide unavailable event history")
    let stoppedBeforeRoot = InventoryLifecyclePresentation(hasRoot: false, status: indexed(.inProgress), requested: true, loading: false, error: nil, monitoringConfigured: false, monitoringEnabled: false)
    try test(stoppedBeforeRoot.state == .waiting && !stoppedBeforeRoot.showsProgress && stoppedBeforeRoot.action == .openSettings, "disabled first indexing before a readable root stops its indefinite spinner and offers Settings")
    let stoppedFailure = InventoryLifecyclePresentation(hasRoot: false, status: indexed(.inProgress), requested: true, loading: false, error: nil, monitoringConfigured: false, indexingFailure: "fixture indexer failure", monitoringEnabled: false)
    try test(stoppedFailure.state == .failed && stoppedFailure.detail.contains("fixture indexer failure") && stoppedFailure.action == .retry, "known-off indexing preserves an observed failure and recovery instead of hiding it as waiting")
    let completedAfterRequest = InventoryLifecyclePresentation(hasRoot: true, status: indexed(.complete), requested: true, loading: false, error: nil, monitoringConfigured: false, monitoringEnabled: false)
    try test(completedAfterRequest.state == .available && completedAfterRequest.showsBrowser && !completedAfterRequest.showsProgress, "a retained initial request does not invent waiting after a root is complete with no queue")
    var missingGeneration = noInventory; missingGeneration.initialCompletion = .inProgress
    let missingGenerationStopped = InventoryLifecyclePresentation(hasRoot: false, status: missingGeneration, requested: false, loading: false, error: nil, monitoringConfigured: false, monitoringEnabled: false)
    try test(missingGenerationStopped.state == .waiting && !missingGenerationStopped.showsProgress, "disabled initial work without a generation or request flag cannot remain spinning")
    let stoppedReadFailure = InventoryLifecyclePresentation(hasRoot: true, status: queued, requested: false, loading: false, error: "fixture catalog error", monitoringConfigured: false, monitoringEnabled: false)
    try test(stoppedReadFailure.state == .temporarilyUnavailable && stoppedReadFailure.showsBrowser && stoppedReadFailure.detail.contains("fixture catalog error"), "disabling monitoring preserves catalog read failures and existing browser results")

    let previousSizeNote = InventoryNodePresentation.sharedFreshnessText("Previously measured")
    try test(previousSizeNote?.contains("last completed measurement") == true && previousSizeNote?.contains("being rechecked") == false, "shared stale-size explanation qualifies earlier measurements without claiming a running recheck")
    let includedSizesNote = InventoryNodePresentation.sharedFreshnessText("Includes earlier sizes")
    try test(includedSizesNote?.contains("earlier sizes") == true && includedSizesNote?.contains("need rechecking") == true && includedSizesNote?.contains("while changes are rechecked") == false, "shared mixed-age explanation describes needed work without implying active indexing")

    let main = MonitoringSetupStatus.labels[0], worker = MonitoringSetupStatus.labels[2]
    func setup(_ state: MonitoringSetupStatus.State = .on, exit: Int = 0, pid: Int? = nil, workerExit: Int = 0, launchdKnown: Bool = true) -> MonitoringSetupStatus {
        var result = MonitoringSetupStatus(state: state, summary: "fixture", installedVersion: nil, bundledVersion: nil, helperExecutable: nil, installedApp: URL(fileURLWithPath: "/private/tmp/fixture-monitor"))
        result.launchd = launchdKnown ? LaunchdState(loaded: Set(MonitoringSetupStatus.labels), disabled: [], jobs: [main: .init(pid: pid, lastExitStatus: exit), worker: .init(pid: nil, lastExitStatus: workerExit)]) : nil
        return result
    }
    try test(setup(.off).inventoryUpdatesEnabled == false && setup(.on).inventoryUpdatesEnabled == true && setup(.needsUpdate).inventoryUpdatesEnabled == true, "reliable setup distinguishes monitoring off from enabled inventory scheduling")
    try test(setup(.incomplete).inventoryUpdatesEnabled == nil && setup(.off, launchdKnown: false).inventoryUpdatesEnabled == nil, "partial setup and missing launchd evidence do not invent a known-off state")
    var observedRunning = setup(.off)
    observedRunning.launchd?.jobs[worker] = .init(pid: 123, lastExitStatus: 78)
    try test(observedRunning.inventoryUpdatesEnabled == true, "a current registered indexer PID overrides an off setup snapshot while work drains")
    observedRunning.launchd?.reliable = false
    try test(observedRunning.inventoryUpdatesEnabled == nil, "unreliable output cannot reuse a PID to establish active indexing")
    var disabledIndexer = setup(); disabledIndexer.launchd?.disabled.insert(worker)
    try test(disabledIndexer.inventoryUpdatesEnabled == false, "a reliable disabled override makes queued indexing wait even when setup needs repair")
    disabledIndexer.launchd?.jobs[worker] = .init(pid: 123, lastExitStatus: 0)
    try test(disabledIndexer.inventoryUpdatesEnabled == true, "an indexer still running despite a disabled override remains active until it stops")
    var missingIndexer = setup(); missingIndexer.launchd?.loaded.remove(worker)
    try test(missingIndexer.inventoryUpdatesEnabled == nil, "an unregistered indexer cannot claim enabled scheduling from setup alone")
    func health(_ setup: MonitoringSetupStatus?, success: Date? = now, evidence: MonitoringHealthEvidence = .init(), wake: Date? = nil, at: Date = now) -> MonitoringHealthPresentation {
        MonitoringHealthPresentation(setup: setup, lastSuccess: success, evidence: evidence, lastWake: wake, now: at)
    }
    let parsedFailure = LaunchdState.parse(list: "PID  Status  Label\n-  78  \(main)\n123  78  \(worker)\n", disabled: "")
    try test(parsedFailure.jobs[main]?.lastExitStatus == 78 && parsedFailure.jobs[worker]?.pid == 123 && parsedFailure.reliable, "launchd parser preserves last exit and running PID with whitespace-separated rows")
    try test(health(setup()).state == .healthy && health(setup()).lastAttempt == nil && health(setup()).lastSuccess == now, "configured and registered with a recent success is healthy, with genuinely unknown attempt time")
    try test(health(setup(), success: now.addingTimeInterval(1)).state == .unknown, "future-dated recorded monitoring evidence cannot establish current health")
    try test(health(setup(), success: nil).state == .waiting, "registration and exit zero without a reading never prove working monitoring")
    try test(health(setup(exit: 78)).state == .failed, "a registered job with exit 78 is failed, not healthy")
    var evidence = MonitoringHealthEvidence(); evidence.observe(setup(exit: 78).launchd, at: now)
    try test(health(setup(exit: 78), evidence: evidence).state == .failed, "a success before or at observed failure does not clear that failure")
    evidence.observe(setup(exit: 78).launchd, at: now.addingTimeInterval(60))
    try test(evidence.failures[main] == now, "repeated polls retain the failure observation rather than continually moving its recovery boundary")
    try test(health(setup(exit: 78), success: now.addingTimeInterval(30), evidence: evidence, at: now.addingTimeInterval(60)).state == .healthy, "a newly recorded success supersedes an older retained free-space exit failure")
    evidence.observe(setup().launchd, at: now.addingTimeInterval(120))
    try test(health(setup(), success: now.addingTimeInterval(120), evidence: evidence, at: now.addingTimeInterval(120)).state == .healthy && evidence.failures.isEmpty, "exit zero and a later success recover from exit 78")
    try test(health(setup(exit: 78, pid: 432)).state == .running, "a running check supersedes its historical exit failure without claiming a new success")
    try test(health(setup(.off)).state == .off && health(setup(.incomplete)).state == .configurationNeedsAttention, "missing, disabled or partial setup stays separate from execution health")
    try test(health(setup(launchdKnown: false)).state == .unknown && health(nil).state == .unknown, "missing execution evidence remains unknown even with a recent historical reading")
    var unknown = setup(); unknown.launchd = malformed
    try test(health(unknown).state == .unknown, "malformed execution output never reports successful monitoring")
    try test(health(setup(), at: now.addingTimeInterval(4500)).state == .healthy && health(setup(), at: now.addingTimeInterval(4501)).state == .stale, "monitoring becomes stale after its 75-minute sleep/schedule tolerance, not a fatal error")
    try test(health(setup(), wake: now.addingTimeInterval(4500), at: now.addingTimeInterval(4501)).state == .waking
             && health(setup(), wake: now.addingTimeInterval(4500), at: now.addingTimeInterval(5101)).state == .stale, "wake has a bounded waiting state without falsely declaring old data healthy")
    try test(health(setup(workerExit: 75), success: nil).state == .resuming && health(setup(workerExit: 78)).state == .failed, "resumable inventory exit 75 differs from a fatal inventory exit 78")
    var baselineResuming = setup()
    baselineResuming.launchd?.jobs[MonitoringSetupStatus.labels[1]] = .init(pid: nil, lastExitStatus: 75)
    try test(health(baselineResuming, success: nil).state == .resuming && health(baselineResuming).state == .healthy, "baseline exit 75 is resumable work rather than a monitoring failure")
    func workerEvidence(_ offset: TimeInterval, _ payload: String) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) + " inventory " + payload + "\n" }
    let failedWorker = InventoryWorkerEvidence.parse(workerEvidence(-60, "{\"outcome\":\"failed\"}"), now: now)
    try test(failedWorker?.outcome == "failed", "timestamped inventory failure is read independently of exit zero")
    let hiddenFailure = MonitoringHealthPresentation(setup: setup(), lastSuccess: now, inventory: failedWorker, now: now)
    try test(hiddenFailure.state == .failed && hiddenFailure.title.contains("inventory") && hiddenFailure.detail.contains("do not clear"), "recent capacity plus registered exit-zero jobs cannot mask a recorded inventory failure")
    let skipped = InventoryWorkerEvidence.parse(workerEvidence(-60, "{\"outcome\":\"failed\"}") + workerEvidence(-30, "{\"outcome\":\"busy\"}"), now: now)
    try test(skipped == failedWorker, "busy inventory attempt does not erase prior failure")
    let workerRecovered = InventoryWorkerEvidence.parse(workerEvidence(-60, "{\"outcome\":\"failed\"}") + workerEvidence(-30, "{\"outcome\":\"partial\"}"), now: now)
    try test(workerRecovered?.outcome == "partial" && MonitoringHealthPresentation(setup: setup(), lastSuccess: now, inventory: workerRecovered, now: now).state == .healthy, "later committed partial inventory progress clears the same worker failure")
    let malformedWorker = InventoryWorkerEvidence.parse(workerEvidence(-30, "{truncated"), now: now)
    try test(malformedWorker?.outcome == "unknown" && MonitoringHealthPresentation(setup: setup(), lastSuccess: now, inventory: malformedWorker, now: now).state == .unknown, "malformed latest inventory summary requires rechecking rather than healthy status")
    try test(InventoryWorkerEvidence.parse(workerEvidence(60, "{\"outcome\":\"failed\"}"), now: now) == nil && InventoryWorkerEvidence.parse("unrelated log line", now: now) == nil, "future and unrelated log records cannot establish inventory health")
    try test(InventoryWorkerEvidence.retainingFailure(failedWorker, observed: nil) == failedWorker && InventoryWorkerEvidence.retainingFailure(failedWorker, observed: malformedWorker) == failedWorker, "observed inventory failure survives temporarily unreadable or truncated log tails")
    try test(InventoryWorkerEvidence.retainingFailure(failedWorker, observed: workerRecovered) == workerRecovered, "only later same-worker committed progress clears retained inventory failure")
    let closingReplay = InventoryWorkerEvidence.parse(workerEvidence(-30, "{\"outcome\":\"interrupted\",\"status\":\"completed\"}"), now: now)
    try test(closingReplay?.outcome == "complete", "drained worker's closing replay interruption retains its recorded completed status")
    let paused = InventoryWorkerEvidence.parse(workerEvidence(-60, "{\"outcome\":\"failed\"}") + workerEvidence(-30, "{\"outcome\":\"interrupted\",\"status\":\"paused\"}"), now: now)
    try test(paused == failedWorker, "paused worker does not manufacture recovery from an earlier failure")
    let sameSecond = InventoryWorkerEvidence.parse(workerEvidence(-30, "{\"outcome\":\"failed\"}") + workerEvidence(-30, "{\"outcome\":\"complete\"}"), now: now)
    try test(sameSecond?.outcome == "complete", "same-second later worker record establishes recovery in log order")
    let logFixture = URL(fileURLWithPath: "/private/tmp/storage-monitor-health-log-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: logFixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: logFixture) }
    try Data(workerEvidence(-60, "{\"outcome\":\"failed\"}").utf8).write(to: logFixture.appendingPathComponent("monitor.log.1"))
    try Data((String(repeating: "unrelated filler\n", count: 6000) + workerEvidence(-30, "{\"outcome\":\"partial\"}")).utf8).write(to: logFixture.appendingPathComponent("monitor.log"))
    try test(InventoryWorkerEvidence.read(directory: logFixture, now: now)?.outcome == "partial", "bounded real log tail reads newer worker progress across rotation and oversized unrelated content")
    try FileManager.default.removeItem(at: logFixture.appendingPathComponent("monitor.log"))
    try FileManager.default.createSymbolicLink(atPath: logFixture.appendingPathComponent("monitor.log").path, withDestinationPath: logFixture.appendingPathComponent("monitor.log.1").path)
    try test(InventoryWorkerEvidence.read(directory: logFixture, now: now)?.outcome == failedWorker?.outcome && InventoryWorkerEvidence.read(directory: logFixture, now: now)?.timestamp == failedWorker?.timestamp, "worker evidence refuses symlinked current log while preserving the owned rotated summary")
    do {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/storage-monitor-log-order-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        func line(_ outcome: String) -> Data { Data((ISO8601DateFormatter().string(from: now) + " inventory {\"outcome\":\"" + outcome + "\"}\n").utf8) }
        let current = root.appendingPathComponent("monitor.log"), rotated = root.appendingPathComponent("monitor.log.1")
        try line("complete").write(to: rotated); try line("failed").write(to: current)
        let cached = InventoryWorkerEvidence.read(directory: root, now: now)!
        try fm.removeItem(at: current)
        let older = InventoryWorkerEvidence.read(directory: root, now: now)!
        try test(older.outcome == "complete" && InventoryWorkerEvidence.retainingFailure(cached, observed: older) == cached, "older rotated same-second success cannot clear cached current-log failure when current is absent")
        try fm.removeItem(at: rotated)
        try (Data("unrelated μ猫\n".utf8) + line("failed")).write(to: current)
        let failed = InventoryWorkerEvidence.read(directory: root, now: now)!
        let append = try FileHandle(forWritingTo: current); try append.seekToEnd(); try append.write(contentsOf: line("partial")); try append.close()
        let later = InventoryWorkerEvidence.read(directory: root, now: now)!
        try test(later.outcome == "partial" && later.timestamp == failed.timestamp && later.position!.stream == failed.position!.stream && later.position!.offset > failed.position!.offset && InventoryWorkerEvidence.retainingFailure(failed, observed: later) == later, "genuine later same-second progress in the same readable stream clears failure")
        try (line("complete") + line("failed")).write(to: current)
        let tailFailure = InventoryWorkerEvidence.read(directory: root, now: now)!
        try fm.moveItem(at: current, to: rotated)
        let truncate = try FileHandle(forWritingTo: rotated); try truncate.truncate(atOffset: UInt64(line("complete").count)); try truncate.close()
        let oldOffset = InventoryWorkerEvidence.read(directory: root, now: now)!
        try test(oldOffset.position!.stream == tailFailure.position!.stream && oldOffset.position!.offset < tailFailure.position!.offset && InventoryWorkerEvidence.retainingFailure(tailFailure, observed: oldOffset) == tailFailure, "older same-stream offset exposed by rotation/truncation cannot clear later cached failure")
    }
    try test(health(setup(workerExit: 78), success: now.addingTimeInterval(60), at: now.addingTimeInterval(60)).state == .failed, "a capacity success does not erase a different indexer's fatal status")
}

@MainActor func correctnessCapacityMonitorTests(_ test: (Bool, String) throws -> Void) async throws {
    final class Source: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func read() -> LiveCapacityReading {
            entered.signal(); release.wait()
            return .init(timestamp: now, free: 30 * decimalGB, total: 100 * decimalGB, dataVolumeUUID: "fixture")
        }
    }
    let source = Source()
    let monitor = LiveCapacityMonitor(source: { source.read() }, clock: { source.now })
    var refreshing = [Bool]()
    let observation = monitor.$state.sink { refreshing.append($0.isRefreshing) }
    let task = Task { await monitor.refresh() }
    while !monitor.isRefreshing { await Task.yield() }
    try test(monitor.state.isRefreshing && refreshing.contains(true), "capacity publishes the start of a refresh before the detached probe finishes")
    source.release.signal()
    _ = await task.value
    try test(!monitor.isRefreshing && refreshing.last == false && monitor.state.reading?.free == 30 * decimalGB && monitor.state.lastAttempt == source.now,
             "capacity publishes refresh completion and uses the injected attempt clock")
    observation.cancel()
}
