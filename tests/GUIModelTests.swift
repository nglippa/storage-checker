import Foundation
import SQLite3

@main struct GUIModelTests {
    static func main() async throws {
        let folder = URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "build/qa-fixtures",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let anchor = Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970)+0.1234567)
        let schema = "CREATE TABLE readings(id INTEGER PRIMARY KEY,timestamp REAL,container TEXT,free INTEGER,used INTEGER,volumes TEXT); CREATE TABLE alerts(id INTEGER PRIMARY KEY,timestamp REAL,severity TEXT,reasons TEXT,free INTEGER,delta INTEGER,notification TEXT); CREATE TABLE diagnostics(id INTEGER PRIMARY KEY,timestamp REAL,snapshot TEXT); CREATE TABLE state(key TEXT PRIMARY KEY,value TEXT);"
        func create(_ name: String) throws -> OpaquePointer {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
            var handle: OpaquePointer?; guard sqlite3_open(url.path,&handle) == SQLITE_OK else { fatalError("fixture open") }
            guard sqlite3_exec(handle,schema,nil,nil,nil) == SQLITE_OK else { fatalError("fixture schema") }
            return handle!
        }
        func write(_ db: OpaquePointer,_ sql: String,_ values: [String?]) {
            var stmt: OpaquePointer?; precondition(sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            for (index,value) in values.enumerated() { if let value { sqlite3_bind_text(stmt,Int32(index+1),value,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) } else { sqlite3_bind_null(stmt,Int32(index+1)) } }
            precondition(sqlite3_step(stmt)==SQLITE_DONE)
        }
        func encoded(_ object: Any) -> String { String(data:try! JSONSerialization.data(withJSONObject:object,options:.sortedKeys),encoding:.utf8)! }
        func time(_ minutes: Double) -> String { String(anchor.addingTimeInterval(minutes * -60).timeIntervalSince1970) }
        func volumes(_ bytes: Int64 = 50*decimalGB) -> [[String:Any]] { [["APFSVolumeUUID":"volume-data","Name":"Data","CapacityInUse":bytes,"Roles":["Data"]]] }
        let fixture = try create("populated.sqlite3")
        let samples: [(Int,Double,Double,String)] = [(1,31*1440,90,"A"),(2,20*1440,80,"A"),(3,6*1440,82,"A"),(4,2*1440,76,"A"),(5,24*60+20,75,"A"),(6,20*60,74,"A"),(7,70,74.2,"A"),(8,50,70.2,"A"),(9,40,70.8,"A"),(10,30,24,"A"),(11,20,14,"A"),(12,10,30,"A"),(13,5,30,"A"),(14,7*1440,100,"B")]
        for (id,minutes,free,container) in samples {
            let bytes = Int64((free*Double(decimalGB)).rounded())
            write(fixture,"INSERT INTO readings VALUES(?,?,?,?,?,?)",[String(id),time(minutes),container,String(bytes),String(245*decimalGB-bytes),encoded(volumes(Int64(245*decimalGB-bytes)))])
        }
        write(fixture,"INSERT INTO alerts VALUES(?,?,?,?,?,?,?)",["1",time(30),"warning","free_below_25gb",String(24*decimalGB),String(Int64(-46.8*Double(decimalGB))),"delivered:fixture-warning"])
        write(fixture,"INSERT INTO alerts VALUES(?,?,?,?,?,?,?)",["2",time(20),"critical","free_below_15gb",String(14*decimalGB),String(-10*decimalGB),"delivered:fixture-critical"])
        write(fixture,"INSERT INTO alerts VALUES(?,?,?,?,?,?,?)",["3",time(2),"future_severity","unrecognized_fixture_reason",String(80*decimalGB),nil,"unknown"])
        func command(_ name: String,_ path: String,_ value: Int,_ complete: Bool = true) -> [String:Any] {
            ["name":name,"utility":"/usr/bin/du","arguments":["-A","-k","-s","-x",path],"output":"\(value)\t\(path)\n" + (complete ? "" : "du: protected: Operation not permitted\n"),"exit_status":complete ? 0 : 1,"timed_out":false,"truncated":false]
        }
        for (id,minutes,swap,free,size) in [(1,40,1024,70.8,1_000_000),(2,20,2048,14.0,1_100_000),(3,8,3072,30.0,1_200_000)] {
            let commands: [[String:Any]] = [["name":"swap allocation","utility":"/usr/sbin/sysctl","arguments":["vm.swapusage"],"output":"vm.swapusage: total = 4096.00M used = \(swap).00M free = 0.00M (encrypted)\n","exit_status":0,"timed_out":false,"truncated":false],command("Application Support logical KiB","/fixture/Library/Application Support",size),command("var/folders logical KiB","/private/var/folders",100*id,false),command("Chrome signing clone logical KiB","/fixture/Chrome/code_sign_clone",400_000)]
            let json: [String:Any] = ["physical_container":["uuid":"A","free_bytes":Int64(free*Double(decimalGB)),"used_bytes":Int64((245-free)*Double(decimalGB))],"volumes":volumes(Int64(id)*50*decimalGB),"commands":commands,"interpretation":"Fixture evidence only. Scope sizes are not additive physical allocation."]
            write(fixture,"INSERT INTO diagnostics VALUES(?,?,?)",[String(id),time(Double(minutes)),encoded(json)])
        }
        sqlite3_close(fixture)
        sqlite3_close(try create("empty.sqlite3"))
        let zero = try create("zero.sqlite3")
        write(zero,"INSERT INTO readings VALUES(?,?,?,?,?,?)",["1",time(0),"bad","0","0","[]"]); sqlite3_close(zero)
        try Data("not a SQLite database".utf8).write(to:folder.appendingPathComponent("corrupt.sqlite3"))
        let populated = folder.appendingPathComponent("populated.sqlite3")
        let before = try Data(contentsOf:populated)
        let snapshot = try await HistoryReader(path:populated.path).load()
        let after = try Data(contentsOf:populated)
        var tests = 0
        func test(_ value: @autoclosure () -> Bool,_ message: String) throws { guard value() else { throw HistoryError.invalid("TEST FAILED: \(message)") }; tests += 1; print("PASS \(message)") }
        try test(before == after,"read-only GUI load leaves database byte-identical")
        try test(!FileManager.default.fileExists(atPath:populated.path+"-journal") && !FileManager.default.fileExists(atPath:populated.path+"-wal"),"GUI creates no journal/WAL")
        try test(snapshot.measurements.count == 14 && snapshot.events.count == 16,"one event per measurement; attached records do not duplicate rows; orphans retained")
        try test(snapshot.latest?.timestamp == Date(timeIntervalSince1970:Double(time(5))!),"SQLite REAL timestamps retain stored subsecond precision")
        let critical = snapshot.events.first { $0.id == "reading:11" }!
        try test(critical.alerts.count == 1 && critical.diagnostics.count == 1 && critical.severity == .critical,"critical alert and diagnostic attach to exact reading")
        try test(critical.hasSwapChange,"comparable swap evidence flags event without causal attribution")
        try test(critical.comparisons.first { $0.current.path == "/private/var/folders" }?.delta == nil,"partial directory totals never produce growth estimates")
        try test(critical.comparisons.first { $0.current.kind == "Swap used" }?.delta == 1024*1024*1024,"swap changes use binary MiB units")
        try test(critical.comparisons.first { $0.current.path.contains("Application Support") }?.delta == 100_000*1024,"complete directory pairs use KiB and matching path")
        try test(critical.previousMeasurement?.id == 10,"per-reading predecessor retained for volume UUID comparison")
        try test(snapshot.events.first { $0.id == "alert:3" }?.alerts.first?.rawSeverity == "future_severity","unknown recorded severity preserved visibly")
        try test(EvidenceParser.swapBytes("used = 1.50G") == 1_610_612_736,"sysctl G means GiB")
        try test(EvidenceParser.swapBytes("used = 12.00M") == 12*1024*1024,"sysctl M means MiB")
        try test(EvidenceParser.swapBytes("unreadable") == nil,"missing swap remains unknown")
        try test(signedChange(-53_248) == "−53.25 KB" && signedChange(1) == "+1 B" && signedChange(0) == "0 B","nonzero small changes never render as zero GB")

        // Chart selection never guesses: the reading identity, container and full timestamp must identify one event.
        let chartReading = critical.measurement!
        try test(StorageChartSelection.eventID(for: chartReading, events: snapshot.events) == critical.id, "chart selection maps an exact reading to its unique event")
        try test(StorageChartSelection.eventID(for: chartReading, events: snapshot.events.filter { $0.id != critical.id }) == nil, "chart selection does not select an event hidden by filters")
        let orphanReading = Measurement(id: 99_999, timestamp: chartReading.timestamp, container: chartReading.container, free: chartReading.free, used: chartReading.used, volumes: chartReading.volumes)
        try test(StorageChartSelection.eventID(for: orphanReading, events: snapshot.events) == nil, "chart selection leaves an orphan reading unmatched")
        let sameTimeWrongIdentity = Measurement(id: chartReading.id + 1, timestamp: chartReading.timestamp, container: chartReading.container, free: chartReading.free, used: chartReading.used, volumes: chartReading.volumes)
        let sameIdentityWrongContainer = Measurement(id: chartReading.id, timestamp: chartReading.timestamp, container: "another-container", free: chartReading.free, used: chartReading.used, volumes: chartReading.volumes)
        try test(StorageChartSelection.eventID(for: sameTimeWrongIdentity, events: snapshot.events) == nil && StorageChartSelection.eventID(for: sameIdentityWrongContainer, events: snapshot.events) == nil, "chart selection rejects same-time events with a different reading ID or container")
        let duplicateChartEvent = StorageEvent(id: "duplicate-chart-event", timestamp: critical.timestamp, category: critical.category, delta: critical.delta, previousFree: critical.previousFree, currentFree: critical.currentFree, previousTime: critical.previousTime, severity: critical.severity, measurement: chartReading, previousMeasurement: critical.previousMeasurement, alerts: [], diagnostics: [], comparisons: [], source: "test", searchText: "")
        try test(StorageChartSelection.eventID(for: chartReading, events: snapshot.events + [duplicateChartEvent]) == nil, "chart selection rejects duplicate ambiguous event matches")
        try test(snapshot.measurements.contains { $0.id == chartReading.id && $0.timestamp == chartReading.timestamp && $0.container == chartReading.container }, "chart selection leaves measurement data unchanged")

        // Event list focus: ownership, not a time window, decides whether a lost focus returns to the list.
        var ownership = EventListFocusOwnership()
        try test(!ownership.restoresAfterLoss, "event list focus: nothing is restored before the list has had focus")
        ownership.listFocused()
        try test(ownership.restoresAfterLoss, "event list focus: a loss without a deliberate move (inspector rebuild, however slow) returns focus to the list")
        ownership.deliberateMove()
        try test(!ownership.restoresAfterLoss, "event list focus: a click elsewhere, Tab or Find keeps the person's new focus")
        ownership.listFocused()
        try test(ownership.restoresAfterLoss, "event list focus: focusing the list again restores ownership")
        try test(EventListFocusOwnership.isDeliberateKey(keyCode: 48, command: false, characters: "\t") && EventListFocusOwnership.isDeliberateKey(keyCode: 3, command: true, characters: "f"),
                 "event list focus: Tab and Command-F are deliberate moves")
        try test(!EventListFocusOwnership.isDeliberateKey(keyCode: 125, command: false, characters: nil) && !EventListFocusOwnership.isDeliberateKey(keyCode: 34, command: true, characters: "i") && !EventListFocusOwnership.isDeliberateKey(keyCode: 53, command: false, characters: "\u{1b}"),
                 "event list focus: arrows, Option-Command-I and Escape are not focus moves")

        // Empty event list guidance never offers a step that cannot reveal events.
        let emptyNow = Date(timeIntervalSince1970: 2_000_000_000)
        func emptyEvent(_ id: String, daysAgo: Double, severity: EventSeverity = .normal) -> StorageEvent {
            StorageEvent(id: id, timestamp: emptyNow.addingTimeInterval(-daysAgo * 86_400), category: "Storage loss", delta: -2_000_000_000, previousFree: nil, currentFree: nil, previousTime: nil, severity: severity, measurement: nil, previousMeasurement: nil, alerts: [], diagnostics: [], comparisons: [], source: "test", searchText: "storage loss")
        }
        let recentWeek = [emptyEvent("a", daysAgo: 3), emptyEvent("b", daysAgo: 5)]
        let defaultEmpty = EventListEmptyState.make(filters: EventFilters(), events: recentWeek, now: emptyNow)
        try test(EventFilters().activeCount == 0 && defaultEmpty?.actions == [.widen(.week)] && defaultEmpty?.message.contains("the last 24 hours") == true,
                 "empty list: the default 24-hour range offers the last 7 days, not Clear Filters")
        try test(EventListEmptyState.make(filters: EventFilters(), events: [emptyEvent("old", daysAgo: 20)], now: emptyNow)?.actions == [.widen(.month)], "empty list: the narrowest preset range holding the latest event is offered")
        if case .range(let start, let end)? = EventListEmptyState.make(filters: EventFilters(), events: [emptyEvent("older", daysAgo: 45)], now: emptyNow)?.actions.first {
            try test(start <= emptyNow.addingTimeInterval(-45 * 86_400) && end >= emptyNow, "empty list: events older than every preset offer a range from the first event through now")
        } else { try test(false, "empty list: events older than every preset offer a range from the first event through now") }
        var severityFilter = EventFilters(); severityFilter.time = .week; severityFilter.severity = EventSeverity.critical.rawValue
        try test(EventListEmptyState.make(filters: severityFilter, events: recentWeek, now: emptyNow)?.actions == [.clearFilters], "empty list: events in range hidden by other filters offer Clear Filters")
        var searchFilter = EventFilters(); searchFilter.search = "nothing"
        try test(EventListEmptyState.make(filters: searchFilter, events: recentWeek, now: emptyNow)?.actions == [.clearFilters, .widen(.week)], "empty list: other filters and an empty range offer both steps")
        var weekFilter = EventFilters(); weekFilter.time = .week
        try test(EventListEmptyState.make(filters: weekFilter, events: recentWeek, now: emptyNow) == nil && EventListEmptyState.make(filters: EventFilters(), events: [], now: emptyNow) == nil,
                 "empty list: no guidance when events are shown or none are recorded")
        // Each offered time step reveals events once the offered Clear Filters (if any) is also taken.
        for filters in [EventFilters(), severityFilter, searchFilter] {
            for case .widen(let time) in EventListEmptyState.make(filters: filters, events: recentWeek, now: emptyNow)?.actions ?? [] {
                var widened = EventFilters(); widened.time = time
                try test(!widened.apply(recentWeek, now: emptyNow).isEmpty, "empty list: the offered range \(time.rawValue) reveals events")
            }
        }

        // Living Tree labels are click targets for their elements, topmost label first.
        let labelA = LivingTreeLabel(key: .node(1), title: "Users", detail: "324 GB", tip: .zero, frame: CGRect(x: 4, y: -10, width: 80, height: 30), emphasized: false)
        let labelB = LivingTreeLabel(key: .node(2), title: "Library", detail: "29 GB", tip: .zero, frame: CGRect(x: 4, y: -10, width: 80, height: 30), emphasized: false)
        try test(LivingTreeLabel.hit(CGPoint(x: 110, y: 205), labels: [labelA], tips: [CGPoint(x: 100, y: 200)]) == .node(1), "living tree: a click on a drawn label selects its element")
        try test(LivingTreeLabel.hit(CGPoint(x: 99, y: 205), labels: [labelA], tips: [CGPoint(x: 100, y: 200)]) == nil, "living tree: a click beside a label falls through to the branches")
        try test(LivingTreeLabel.hit(CGPoint(x: 310, y: 305), labels: [labelA, labelB], tips: [CGPoint(x: 300, y: 300), CGPoint(x: 300, y: 300)]) == .node(2), "living tree: overlapping labels resolve to the one drawn on top")
        try test(LivingTreeLabeler.percent(0.6994) == "70%" && LivingTreeLabeler.percent(0.004) == "<1%" && LivingTreeLabeler.percent(0) == "<1%" && LivingTreeLabeler.percent(1.2) == "100%",
                 "living tree: a label's share of the folder is a rounded whole percent, never finer")

        // Inventory presentation is derived from durable reader state only.
        func inventoryStatus(state: String = "building", queued: Int64 = 2, reconcile: Bool = false, discovery: Bool = true, completeness: InventoryValueStatus = .lowerBound, unknown: Int64 = 0, initial: InventoryInitialCompletion = .inProgress, gap: Bool = false) -> InventoryStatus {
            InventoryStatus(generation: 1, state: state, rootPath: "/System/Volumes/Data", totalNodes: 12, completedDirectories: 3, pendingDirectories: queued > 0 ? 2 : 0, staleDirectories: discovery ? 0 : (queued > 0 ? 1 : 0), unknownDirectories: unknown, queuedDirectoryJobs: queued, hasReconciliationWork: reconcile, hasInitialDiscoveryWork: discovery, progress: completeness == .complete ? 1 : nil, completeness: completeness, reason: nil, updatedAt: anchor, createdAt: anchor.addingTimeInterval(-10), initialCompletion: initial, initialCompletedAt: initial == .complete ? anchor : nil, hasEventGapRecheck: gap)
        }
        try test(InventoryStatusPresentation(status: inventoryStatus()).phase == .discovering, "inventory presentation distinguishes initial discovery")
        try test(InventoryStatusPresentation(status: inventoryStatus(reconcile: true)).phase == .reconciling, "inventory presentation distinguishes broad reconciliation")
        try test(InventoryStatusPresentation(status: inventoryStatus(discovery: false)).phase == .updating, "inventory presentation distinguishes changed-folder updates")
        try test(InventoryStatusPresentation(status: inventoryStatus(state: "complete", queued: 0, discovery: false, completeness: .complete, initial: .complete)).phase == .idle, "inventory presentation distinguishes terminal idle state")
        try test(InventoryStatusPresentation(status: inventoryStatus()).rankingsArePartial, "partial rankings are explicitly qualified")
        let firstLoad = InventoryInitializationPresentation(status: nil, now: anchor)
        try test(firstLoad.isVisible && firstLoad.title == "Checking inventory status…" && firstLoad.elapsed == nil && firstLoad.counts == nil, "first render shows indexing progress before database results without inventing counts or duration")
        try test(!firstLoad.showsGuidance, "status check does not describe a long first pass before the database confirms one")
        let firstIndex = InventoryInitializationPresentation(status: inventoryStatus(reconcile: true), now: anchor.addingTimeInterval(8030))
        try test(firstIndex.isVisible && firstIndex.title == "Building your storage inventory" && firstIndex.elapsed == "Elapsed 2h 14m", "first-pass panel survives overlapping reconciliation and uses persisted start time")
        let growingQueue = InventoryInitializationPresentation(status: inventoryStatus(queued: 50_000), now: anchor)
        try test(growingQueue.isVisible && growingQueue.elapsed == "Elapsed 10s" && growingQueue.remaining == "Estimating time remaining…" && growingQueue.counts?.contains("50,000") == true && growingQueue.counts?.contains("%") == false, "growing discovery queue is reported as counts without a completion percentage or ETA")
        try test(InventoryInitializationPresentation(status: inventoryStatus(), paused: true, now: anchor).title == "Inventory building paused", "paused first pass is not described as running")
        try test(!InventoryInitializationPresentation(status: inventoryStatus(discovery: false, initial: .complete), now: anchor).isVisible, "ordinary incremental updates do not show first-pass guidance")
        try test(!InventoryInitializationPresentation(status: inventoryStatus(state: "complete", queued: 0, discovery: false, completeness: .complete, initial: .complete), now: anchor).isVisible, "recorded first-pass completion removes the progress panel")
        try test(InventoryInitializationPresentation(status: inventoryStatus(), now: anchor.addingTimeInterval(-30)).elapsed == "Elapsed 0s", "clock correction cannot display negative indexing duration")
        let notStarted = InventoryStatus(generation: nil, state: "uninitialized", rootPath: nil, totalNodes: 0, completedDirectories: 0, pendingDirectories: 0, staleDirectories: 0, unknownDirectories: 0, queuedDirectoryJobs: 0, hasReconciliationWork: false, hasInitialDiscoveryWork: false, progress: nil, completeness: .unknown, reason: nil, updatedAt: nil, createdAt: nil, initialCompletion: .notStarted)
        try test(!InventoryInitializationPresentation(status: notStarted, now: anchor).isVisible && InventoryInitializationPresentation(status: notStarted, requested: true, now: anchor).title == "Preparing your storage inventory…", "start request displays progress immediately while genuinely unstarted inventory remains idle")
        try test(InventoryInitializationPresentation(status: notStarted, requested: true, now: anchor).showsGuidance, "first-pass guidance appears as soon as initialization is requested")

        // Lifecycle state mapping (A–G): the durable milestone, not pending work, decides first-pass messaging.
        func visibleText(_ status: InventoryStatus, paused: Bool = false) -> String {
            let panel = InventoryInitializationPresentation(status: status, paused: paused, now: anchor)
            let line = InventoryStatusPresentation(status: status)
            return ([line.headline, line.detail, line.completionNote ?? ""] + (panel.isVisible ? [panel.title] + (panel.showsGuidance ? [InventoryInitializationPresentation.durationGuidance, InventoryInitializationPresentation.laterChecksGuidance] : []) : [])).joined(separator: " ")
        }
        let neverStarted = InventoryStatusPresentation(status: notStarted)
        try test(neverStarted.phase == .unavailable && neverStarted.completionNote == nil && !InventoryInitializationPresentation(status: notStarted, now: anchor).isVisible, "A: never-started inventory keeps the empty explanation without a progress panel")
        let active = InventoryInitializationPresentation(status: inventoryStatus(), now: anchor)
        try test(active.isVisible && active.showsGuidance && InventoryInitializationPresentation.durationGuidance.hasPrefix("Storage Monitor is discovering files and folders") && visibleText(inventoryStatus()).contains("explore results"), "B: recorded in-progress first pass shows progress, counts and browse-while-indexing guidance")
        let paused = InventoryInitializationPresentation(status: inventoryStatus(), paused: true, now: anchor)
        try test(paused.isVisible && paused.showsGuidance && paused.counts != nil && paused.elapsed != nil, "C: paused first pass keeps counts, elapsed time and guidance")
        let finished = inventoryStatus(state: "complete", queued: 0, discovery: false, completeness: .complete, initial: .complete)
        try test(!InventoryInitializationPresentation(status: finished, now: anchor).isVisible && InventoryStatusPresentation(status: finished).headline == "Inventory is up to date", "D: recorded completion shows ordinary browsing")
        let manyNewFolders = inventoryStatus(queued: 5_000, discovery: true, initial: .complete)
        try test(!InventoryInitializationPresentation(status: manyNewFolders, now: anchor).isVisible && InventoryStatusPresentation(status: manyNewFolders).headline == "Updating changed folders" && !visibleText(manyNewFolders).contains("hours") && !visibleText(manyNewFolders).contains("first"), "E: thousands of never-listed new folders after completion are an ordinary update, never a first pass")
        let gapRecheck = inventoryStatus(reconcile: true, discovery: true, initial: .complete, gap: true)
        try test(!InventoryInitializationPresentation(status: gapRecheck, now: anchor).isVisible && InventoryStatusPresentation(status: gapRecheck).headline == "Rechecking after missed file events" && !visibleText(gapRecheck).contains("hours"), "F: event-history recheck is described as a broader check without resetting completion")
        try test(InventoryStatusPresentation(status: inventoryStatus(reconcile: true, initial: .complete)).headline == "Reconciling filesystem changes", "F: deletion cleanup without an event gap keeps the reconciliation wording")
        let legacy = inventoryStatus(discovery: true, initial: .unknown)
        try test(!InventoryInitializationPresentation(status: legacy, now: anchor).isVisible && InventoryStatusPresentation(status: legacy).completionNote?.contains("earlier version") == true && !visibleText(legacy).contains("hours") && !visibleText(legacy).contains("Building"), "G: legacy unknown completion shows a neutral note, neither first-pass nor completed")
        let unsupported = inventoryStatus(discovery: true, initial: .unsupported)
        try test(!InventoryInitializationPresentation(status: unsupported, now: anchor).isVisible && InventoryStatusPresentation(status: unsupported).completionNote?.contains("isn't recorded") == true && InventoryStatusPresentation(status: unsupported).completionNote?.contains("confirmed automatically") == false, "G: a catalog from a milestone-unaware worker never promises automatic confirmation")
        try test(InventoryStatusPresentation(status: finished).completionNote == nil && InventoryStatusPresentation(status: inventoryStatus()).completionNote == nil, "recorded states carry no legacy note")

        // Conditions A–E (STORAGE-MONITOR-INSTALL-READINESS.md).
        func condition(_ status: InventoryStatus) -> InventoryCondition { InventoryStatusPresentation(status: status).condition }
        func maintained(stale: Int64, queued: Int64, deferred: Int64) -> InventoryStatus {
            InventoryStatus(generation: 1, state: queued > 0 ? "building" : "complete", rootPath: "/System/Volumes/Data", totalNodes: 2_900_000, completedDirectories: 400_000, pendingDirectories: 0, staleDirectories: stale, unknownDirectories: 0, queuedDirectoryJobs: queued, hasReconciliationWork: false, hasInitialDiscoveryWork: false, progress: nil, completeness: stale > 0 ? .stale : .complete, reason: nil, updatedAt: anchor, createdAt: anchor, initialCompletion: .complete, initialCompletedAt: anchor, deferredDirectories: deferred)
        }
        let oneDeferred = maintained(stale: 1, queued: 1, deferred: 1)
        let deferredLine = InventoryStatusPresentation(status: oneDeferred)
        try test(condition(notStarted) == .notStarted && condition(inventoryStatus()) == .initialInventory, "A: an unstarted or unfinished first pass is reported as such")
        try test(condition(finished) == .current && InventoryStatusPresentation(status: finished).affectedDirectories == 0, "B: a finished first pass with nothing waiting is current")
        try test(deferredLine.condition == .staleDirectories && deferredLine.affectedDirectories == 1 && deferredLine.activeListings == 0 && deferredLine.rankingsArePartial
                 && deferredLine.headline == "Up to date except 1 folder that keeps changing" && deferredLine.detail.contains("previous measurements") && !visibleText(oneDeferred).contains("first"),
                 "C: one continuously changing folder is counted and its stale size disclosed, without first-pass wording or an active queue")
        var deferredDuringFirstPass = oneDeferred; deferredDuringFirstPass.initialCompletion = .inProgress
        try test(!InventoryInitializationPresentation(status: deferredDuringFirstPass, now: anchor).isVisible && condition(deferredDuringFirstPass) == .staleDirectories,
                 "C: when only a deferred folder remains, the first-pass panel is not shown even before the milestone is written")
        try test(InventoryStatusPresentation(status: maintained(stale: 2, queued: 2, deferred: 2)).headline == "Up to date except 2 folders that keep changing", "C: the count of affected folders is stated")
        let updatingLine = InventoryStatusPresentation(status: maintained(stale: 3, queued: 3, deferred: 1))
        try test(updatingLine.headline == "Updating changed folders" && updatingLine.activeListings == 2 && updatingLine.condition == .staleDirectories, "C: active listings exclude deferred folders")
        let staleOnly = maintained(stale: 4, queued: 0, deferred: 0)
        try test(condition(staleOnly) == .staleDirectories && InventoryStatusPresentation(status: staleOnly).affectedDirectories == 4 && InventoryStatusPresentation(status: staleOnly).detail.contains("4 folders"), "C: stale folders are counted, not hidden")
        try test(condition(gapRecheck) == .needsReconciliation && condition(inventoryStatus(reconcile: true, initial: .complete)) == .needsReconciliation, "D: event-gap recheck and cleanup are reported as reconciliation")
        var historyUnavailable = finished; historyUnavailable.eventHistoryUnavailable = true
        try test(condition(historyUnavailable) == .unavailable && InventoryStatusPresentation(status: historyUnavailable).headline == "Changes can't be tracked right now", "E: unavailable file-event history is reported instead of 'up to date'")
        var recovering = inventoryStatus(reconcile: true, initial: .complete); recovering.eventHistoryUnavailable = true
        try test(condition(recovering) == .needsReconciliation, "D over E: while history recovers, the reconciliation in progress is reported")
        try test([inventoryStatus(), oneDeferred, finished].map(condition) == [.initialInventory, .staleDirectories, .current], "transitions: first pass (A) → one changing folder (C) → current (B)")
        // Empty-state flicker: the placeholder is the same whether or not a periodic reload is in flight,
        // because it no longer depends on `loading`.
        let noInventory = InventoryStatus(generation: nil, state: "uninitialized", rootPath: nil, totalNodes: 0, completedDirectories: 0, pendingDirectories: 0, staleDirectories: 0, unknownDirectories: 0, queuedDirectoryJobs: 0, hasReconciliationWork: false, hasInitialDiscoveryWork: false, progress: nil, completeness: .unknown, reason: nil, updatedAt: nil, createdAt: nil, initialCompletion: .notStarted)
        try test(InventoryPlaceholder(hasRoot: false, status: noInventory, requested: false, failed: false) == .notStarted
                 && InventoryPlaceholder(hasRoot: false, status: nil, requested: false, failed: false) == .checking
                 && InventoryPlaceholder(hasRoot: false, status: noInventory, requested: true, failed: false) == .waiting
                 && InventoryPlaceholder(hasRoot: false, status: inventoryStatus(initial: .inProgress), requested: false, failed: false) == .loadingResults
                 && InventoryPlaceholder(hasRoot: true, status: inventoryStatus(initial: .inProgress), requested: false, failed: false) == .none,
                 "with no inventory the results area shows one stable state across reloads (no empty-state flicker)")

        // Explorer outline state (InventoryExplorerState): expansion, lazy pages, keyboard, selection, bounds.
        func explorerNode(_ id: Int64, parent: Int64?, _ name: String, folder: Bool = true, size: Int64 = 100, children: Int64 = 0) -> InventoryNode {
            InventoryNode(id: id, parentID: parent, identity: InventoryIdentity(device: 1, inode: UInt64(id), birthNanoseconds: 1), path: "/r/\(name)", name: name, kind: folder ? .directory : .file, logicalBytes: size, allocatedBytes: size, previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil, directLogicalBytes: 0, directAllocatedBytes: 0, childCount: children, descendantFiles: 0, descendantDirectories: 0, status: .complete, coverageState: "complete", listingState: nil, statusReason: nil, measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
        }
        func mapNodeRestricted() -> InventoryNode {
            InventoryNode(id: 77, parentID: 1, identity: InventoryIdentity(device: 1, inode: 77, birthNanoseconds: 1), path: "/r/locked", name: "locked", kind: .directory, logicalBytes: nil, allocatedBytes: nil, previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil, directLogicalBytes: 0, directAllocatedBytes: 0, childCount: 0, descendantFiles: 0, descendantDirectories: 0, status: .unknown, coverageState: "inaccessible", listingState: nil, statusReason: "permissions", measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
        }
        let explorerRoot = explorerNode(1, parent: nil, "", children: 3)
        let docs = explorerNode(10, parent: 1, "Docs", size: 900, children: 2), apps = explorerNode(11, parent: 1, "Apps", size: 500, children: 1)
        let note = explorerNode(12, parent: 1, "note.txt", folder: false, size: 10)
        var explorer = InventoryExplorerState(rowBudget: 600, perFolderLimit: 400)
        explorer.setRoot(explorerRoot)
        try test(explorer.pendingLoads == [1] && explorer.rows.count == 1 && { if case .loading = explorer.rows[0].content { return true } else { return false } }(),
                 "explorer: a new root shows a loading row and requests only its first page")
        explorer.beginLoading(1)
        explorer.receive(parent: 1, page: InventoryChildPage(items: [docs, apps, note], next: nil))
        try test(explorer.rows.map(\.id) == [10, 11, 12] && explorer.rows.allSatisfy { $0.depth == 0 } && explorer.pendingLoads.isEmpty,
                 "explorer: the root's children appear in the order the page gave (largest first) with nothing else loaded")
        try test(explorer.expand(10) && explorer.rows.map(\.id) == [10, -(10 * 4) - 2, 11, 12], "explorer: expanding a folder inserts a loading row beneath it and asks for its first page")
        explorer.receive(parent: 10, page: InventoryChildPage(items: [explorerNode(20, parent: 10, "a", size: 600), explorerNode(21, parent: 10, "b", folder: false, size: 300)], next: nil))
        try test(explorer.rows.map(\.id) == [10, 20, 21, 11, 12] && explorer.rows[1].depth == 1, "explorer: loaded children are indented under their folder")
        try test(!explorer.expand(10), "explorer: expanding an already loaded folder does not reload it")
        explorer.selection = 21
        explorer.collapse(10)
        try test(explorer.rows.map(\.id) == [10, 11, 12] && explorer.selection == 10, "explorer: collapsing hides children and moves a selection inside it to the folder (Finder behavior)")
        try test(!explorer.expand(10) && explorer.rows.map(\.id) == [10, 20, 21, 11, 12], "explorer: re-expanding shows the cached children without a new query")
        // Keyboard.
        explorer.selection = 10
        try test(explorer.handle(.down) == .moved && explorer.selection == 20, "explorer keys: down moves to the next visible row")
        try test(explorer.handle(.left) == .moved && explorer.selection == 10, "explorer keys: left on a child moves to its folder")
        try test(explorer.handle(.left) == .collapsed && !explorer.isExpanded(10), "explorer keys: left on an expanded folder collapses it")
        try test(explorer.handle(.right) == .expanded(needsLoad: false) && explorer.isExpanded(10), "explorer keys: right expands a collapsed folder")
        try test(explorer.handle(.right) == .moved && explorer.selection == 20, "explorer keys: right on an expanded folder moves into its first child")
        explorer.selection = 12
        try test(explorer.handle(.right) == .none && explorer.handle(.down) == .none && explorer.selection == 12, "explorer keys: right on a file and down on the last row do nothing")
        try test(explorer.handle(.up) == .moved && explorer.selection == 11, "explorer keys: up moves to the previous visible row")
        // Pagination and duplicates.
        let wideItems = (0..<250).map { explorerNode(1_000 + Int64($0), parent: 11, "w\($0)", folder: false, size: 250 - Int64($0)) }
        _ = explorer.expand(11)
        explorer.receive(parent: 11, page: InventoryChildPage(items: Array(wideItems[0..<200]), next: InventoryChildCursor(allocated: 51, name: "w199", id: 1_199)))
        let moreRow = explorer.rows.first { $0.parent == 11 && $0.id < 0 }
        try test(explorer.canLoadMore(11) && { if case .more(200, _) = moreRow?.content { return true } else { return false } }(),
                 "explorer: a partly loaded folder ends with a more row counting the loaded entries")
        explorer.receive(parent: 11, page: InventoryChildPage(items: Array(wideItems[195..<250]), next: nil))
        let wideRows = explorer.rows.filter { $0.parent == 11 }
        try test(wideRows.count == 250 && Set(wideRows.map(\.id)).count == 250 && !explorer.canLoadMore(11),
                 "explorer: overlapping pages never duplicate rows, and the folder ends with no more row")
        // Selection persists across a refresh that replaces pages.
        explorer.selection = 1_100
        explorer.receive(parent: 11, page: InventoryChildPage(items: wideItems, next: nil), replacing: true)
        try test(explorer.selection == 1_100 && explorer.rows.contains { $0.id == 1_100 }, "explorer: selection survives a reload of the folder it is in")
        // Deleted entries.
        explorer.remove(20)
        try test(!explorer.rows.contains { $0.id == 20 } && explorer.node(20) == nil, "explorer: a deleted entry disappears from the outline")
        // Per-folder limit and memory budget.
        var explorerLimited = InventoryExplorerState(rowBudget: 600, perFolderLimit: 300)
        explorerLimited.setRoot(explorerRoot)
        explorerLimited.receive(parent: 1, page: InventoryChildPage(items: [docs, apps], next: nil))
        _ = explorerLimited.expand(11)
        explorerLimited.receive(parent: 11, page: InventoryChildPage(items: Array(wideItems[0..<200]), next: InventoryChildCursor(allocated: 1, name: "x", id: 1)))
        explorerLimited.receive(parent: 11, page: InventoryChildPage(items: Array(wideItems[200..<250]) + (0..<100).map { explorerNode(5_000 + Int64($0), parent: 11, "z\($0)", folder: false, size: 1) }, next: InventoryChildCursor(allocated: 1, name: "y", id: 2)))
        try test(!explorerLimited.canLoadMore(11) && { if case .limit = explorerLimited.rows.last?.content { return true } else { return false } }(),
                 "explorer: a folder stops loading at its per-folder limit and says how to reach the rest")
        var bounded = InventoryExplorerState(rowBudget: 1_000, perFolderLimit: 500)
        bounded.setRoot(explorerRoot)
        let many = (0..<40).map { explorerNode(100 + Int64($0), parent: 1, "f\($0)", size: 1_000 - Int64($0)) }
        bounded.receive(parent: 1, page: InventoryChildPage(items: many, next: nil))
        for folder in many {   // open, read 200 entries, close: 40 folders, 8,000 entries visited
            _ = bounded.expand(folder.id)
            bounded.receive(parent: folder.id, page: InventoryChildPage(items: (0..<200).map { explorerNode(folder.id * 1_000 + Int64($0), parent: folder.id, "e\($0)", folder: false) }, next: nil))
            bounded.collapse(folder.id)
        }
        try test(bounded.cachedRows <= 1_000 && bounded.children[1] != nil && bounded.children[many.last!.id] != nil,
                 "explorer memory: after visiting 8,000 entries the cache holds at most its budget (\(bounded.cachedRows) rows), keeping the root and recent folders")
        // Navigating into a folder and back keeps the place you came from selected.
        var trail = InventoryExplorerState()
        trail.setRoot(explorerRoot)
        trail.receive(parent: 1, page: InventoryChildPage(items: [docs, apps], next: nil))
        trail.setRoot(docs, cameFrom: [explorerRoot])
        trail.setRoot(explorerRoot, cameFrom: [explorerRoot, docs])
        try test(trail.selection == 10 && trail.rootID == 1 && trail.children[1] != nil, "explorer: returning to a parent selects the folder you came from and reuses its loaded page")
        // Failure surfaces as a retryable row.
        var failing = InventoryExplorerState()
        failing.setRoot(explorerRoot); failing.beginLoading(1); failing.fail(parent: 1, message: "interrupted")
        try test({ if case .failed = failing.rows.first?.content { return true } else { return false } }() && failing.pendingLoads.isEmpty,
                 "explorer: a failed page shows a failure row instead of an empty folder")
        try test({ var e = InventoryExplorerState(); e.setRoot(explorerRoot); e.receive(parent: 1, page: InventoryChildPage(items: [], next: nil)); if case .empty = e.rows.first?.content { return true } else { return false } }(),
                 "explorer: an empty folder shows an empty row")
        var restrictedOutline = InventoryExplorerState()
        restrictedOutline.setRoot(mapNodeRestricted())
        restrictedOutline.receive(parent: 77, page: InventoryChildPage(items: [], next: nil))
        try test({ if case .unavailable(let reason) = restrictedOutline.rows.first?.content { return reason == "Access restricted" } else { return false } }(),
                 "explorer: a protected folder with no indexed children reads 'Contents not available · Access restricted', never 'Empty folder'")
        // Storage map (InventoryMapPlan): proportional areas, exact grouping, truthful coverage, shared selection.
        func mapNode(_ id: Int64, _ size: Int64?, folder: Bool = true, status: InventoryValueStatus = .complete, parent: Int64 = 1) -> InventoryNode {
            InventoryNode(id: id, parentID: parent, identity: InventoryIdentity(device: 1, inode: UInt64(id), birthNanoseconds: 1), path: "/r/n\(id)", name: "n\(id)", kind: folder ? .directory : .file, logicalBytes: status == .stale ? nil : size, allocatedBytes: status == .stale || status == .unknown ? nil : size, previousLogicalBytes: status == .stale ? size : nil, previousAllocatedBytes: status == .stale ? size : nil, objectLogicalBytes: nil, objectAllocatedBytes: nil, directLogicalBytes: 0, directAllocatedBytes: 0, childCount: 0, descendantFiles: 0, descendantDirectories: 0, status: status, coverageState: status == .unknown ? "inaccessible" : "complete", listingState: nil, statusReason: status == .unknown ? "permissions" : nil, measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
        }
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let sizes: [Int64] = [5_000, 3_000, 1_200, 400, 250, 100, 30, 15, 5]
        let mapItems = sizes.enumerated().map { mapNode(Int64(100 + $0.offset), $0.element, folder: $0.offset % 2 == 0) }
        let plan = InventoryMapPlan(items: mapItems, start: 0, beyond: nil, canLoadMore: false, in: canvas, minShare: 0)
        let totalBytes = Double(sizes.reduce(0, +)), canvasArea = Double(canvas.width * canvas.height)
        let proportional = plan.tiles.allSatisfy { tile in abs(Double(tile.rect.width * tile.rect.height) / canvasArea - Double(tile.bytes) / totalBytes) < 1e-9 }
        try test(plan.tiles.count == sizes.count && proportional, "map: each region's area is proportional to its indexed allocated size")
        let inside = plan.tiles.allSatisfy { canvas.insetBy(dx: -1e-6, dy: -1e-6).contains($0.rect) }
        let overlap = plan.tiles.enumerated().contains { i, a in plan.tiles.dropFirst(i + 1).contains { b in a.rect.intersection(b.rect).width > 1e-6 && a.rect.intersection(b.rect).height > 1e-6 } }
        try test(inside && !overlap, "map: regions fill the map without leaving it or overlapping")
        let again = InventoryMapPlan(items: mapItems, start: 0, beyond: nil, canLoadMore: false, in: canvas, minShare: 0)
        try test(plan.tiles.map(\.id) == mapItems.map(\.id) && zip(plan.tiles, again.tiles).allSatisfy { $0.rect == $1.rect && $0.id == $1.id },
                 "map: tiles keep the explorer's order and the same input always gives the same layout")
        // Grouping: small entries and everything beyond the loaded pages form one exact Other region.
        let beyond = InventoryChildRemainder(count: 10_000, allocated: 777_777, unmeasured: 12)
        let grouped = InventoryMapPlan(items: mapItems, start: 0, beyond: beyond, canLoadMore: true, in: canvas, minShare: 0.01)
        let shownBytes = grouped.tiles.compactMap(\.node).reduce(Int64(0)) { $0 + InventoryMapPlan.weight($1)! }
        let shownCount = Int64(grouped.tiles.compactMap(\.node).count)
        try test(shownBytes + grouped.other!.allocated == sizes.reduce(0, +) + 777_777 && shownCount + grouped.other!.count == Int64(sizes.count) + 10_000
                 && grouped.other!.unmeasured == 12 && grouped.tiles.last?.id == InventoryMapPlan.otherID,
                 "map: Other items is the exact sum and count of every omitted entry, including those beyond the loaded pages")
        // Large directory: at most maxTiles regions plus the group, never one per entry.
        let wideMap = (0..<5_000).map { mapNode(10_000 + Int64($0), 5_000 - Int64($0), folder: false) }
        let widePlan = InventoryMapPlan(items: wideMap, start: 0, beyond: InventoryChildRemainder(count: 195_000, allocated: 195_000, unmeasured: 0), canLoadMore: true, in: canvas, minShare: 0)
        try test(widePlan.tiles.count == 121 && widePlan.other!.count + Int64(widePlan.tiles.count - 1) == 200_000,
                 "map: a 200,000-entry folder draws a bounded number of regions (\(widePlan.tiles.count)) and groups the rest")
        // Drill-down: the group's window starts after the drawn tiles and shows new entries.
        let drilled = InventoryMapPlan(items: wideMap, start: widePlan.other!.nextStart, beyond: InventoryChildRemainder(count: 195_000, allocated: 195_000, unmeasured: 0), canLoadMore: true, in: canvas, minShare: 0)
        try test(widePlan.other!.canDrill && drilled.tiles.first?.id == wideMap[widePlan.other!.nextStart].id && drilled.other!.nextStart > widePlan.other!.nextStart,
                 "map: opening Other items shows the next largest entries and can continue")
        // Coverage: partial and earlier sizes are drawn with their values; unmeasured entries are counted, not drawn.
        let coverageItems = [mapNode(1, 900), mapNode(2, 500, status: .lowerBound), mapNode(3, 300, status: .stale), mapNode(4, 200, folder: false), mapNode(5, nil, status: .unknown)]
        let coveragePlan = InventoryMapPlan(items: coverageItems, start: 0, beyond: nil, canLoadMore: false, in: canvas, minShare: 0)
        try test(coveragePlan.tiles.compactMap(\.node).map(\.id) == [1, 2, 3, 4] && coveragePlan.other?.unmeasured == 1 && coveragePlan.other?.allocated == 0
                 && !coveragePlan.tiles.contains { $0.id == InventoryMapPlan.otherID },
                 "map: a protected entry gets no area (no implied size) and is counted as unmeasured; partial and earlier sizes keep their values")
        let zeros = InventoryMapPlan(items: (0..<50).map { mapNode(Int64(200 + $0), 0, folder: false) }, start: 0, beyond: nil, canLoadMore: false, in: canvas)
        try test(zeros.tiles.isEmpty && zeros.other?.count == 50 && zeros.other?.unmeasured == 0 && zeros.other?.canDrill == false,
                 "map: entries measured at zero are reported as using no space, not as unmeasured, and offer no empty drill-down")
        let emptyPlan = InventoryMapPlan(items: [], start: 0, beyond: nil, canLoadMore: false, in: canvas)
        try test(emptyPlan.tiles.isEmpty && emptyPlan.other == nil, "map: an empty folder has no regions and no group")
        // Shared selection: a file selected in the map is the outline's selection; a deep outline selection
        // outlines its ancestor tile.
        var shared = InventoryExplorerState()
        shared.setRoot(explorerRoot)
        shared.receive(parent: 1, page: InventoryChildPage(items: [docs, apps, note], next: nil))
        _ = shared.expand(10)
        shared.receive(parent: 10, page: InventoryChildPage(items: [explorerNode(20, parent: 10, "a", size: 600)], next: nil))
        let sharedPlan = InventoryMapPlan(items: shared.children[1]!.items, start: 0, beyond: nil, canLoadMore: false, in: canvas, minShare: 0)
        shared.selection = 12
        try test(sharedPlan.tile(holding: shared.selection) { shared.node($0)?.parentID } == 12 && shared.rows.contains { $0.id == 12 },
                 "map/outline: a file selected on the map is the selected outline row")
        shared.selection = 20
        try test(sharedPlan.tile(holding: shared.selection) { shared.node($0)?.parentID } == 10,
                 "map/outline: a row selected inside an expanded folder outlines that folder's tile")
        // Index update while navigating: a reloaded page changes the plan, and accounting stays exact.
        shared.receive(parent: 1, page: InventoryChildPage(items: [explorerNode(11, parent: 1, "Apps", size: 2_000, children: 1), docs, note], next: nil), replacing: true)
        let updated = InventoryMapPlan(items: shared.children[1]!.items, start: 0, beyond: nil, canLoadMore: false, in: canvas, minShare: 0)
        try test(updated.tiles.first?.id == 11 && updated.drawnBytes == 2_000 + 900 + 10, "map: an index update reorders tiles by the new sizes and keeps totals exact")
        // Nested tiles: a folder's children, its exact remainder and the residual fill the folder's own total.
        let nestedChildren = [mapNode(301, 4_000, parent: 300), mapNode(302, 2_500, folder: false, parent: 300), mapNode(303, 900, status: .stale, parent: 300)]
        let folderTotal: Int64 = 10_000
        let nestedRemainder = InventoryChildRemainder(count: 500, allocated: 1_600, unmeasured: 3)
        let childSum = nestedChildren.reduce(Int64(0)) { $0 + InventoryMapPlan.weight($1)! } + nestedRemainder.allocated
        let inner = CGRect(x: 0, y: 0, width: 300, height: 180)
        let nestedPlan = InventoryMapPlan(items: nestedChildren, start: 0, beyond: nestedRemainder, canLoadMore: false, in: inner, maxTiles: 40, residual: folderTotal - childSum)
        let nestedArea = nestedPlan.tiles.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        try test(nestedPlan.drawnBytes == folderTotal && nestedPlan.tiles.last?.id == InventoryMapPlan.residualID && abs(nestedArea - Double(inner.width * inner.height)) < 1e-6
                 && nestedPlan.tiles.allSatisfy { abs(Double($0.rect.width * $0.rect.height) / Double(inner.width * inner.height) - Double($0.bytes) / Double(folderTotal)) < 1e-9 },
                 "nested map: children, exact Other items and the folder residual divide the folder tile in proportion to its total")
        try test(nestedPlan.other?.unmeasured == 3 && nestedPlan.other?.canDrill == false, "nested map: unmeasured entries inside a nested folder are counted, not drawn, and the group opens the folder instead of drilling")
        // Repeated earlier-size wording is stated once.
        let staleTile = mapNode(400, 1_048_576, status: .stale)
        try test(InventoryNodePresentation.compactSize(InventoryMapPlan.weight(staleTile), node: staleTile) { "\($0 / 1_048_576) MB" } == "1 MB"
                 && InventoryNodePresentation.size(InventoryMapPlan.weight(staleTile), node: staleTile) { "\($0 / 1_048_576) MB" } == "Previously 1 MB",
                 "presentation: the compact size drops 'Previously' while the full size keeps it for hover")
        let partialTile = mapNode(401, 2_097_152, status: .lowerBound)
        try test(InventoryNodePresentation.compactSize(2_097_152, node: partialTile) { "\($0 / 1_048_576) MB" }.hasPrefix("Partial"), "presentation: a partial value keeps 'Partial' (a lower bound) even in compact form")
        let requeued = mapNode(402, nil, status: .stale)
        try test(InventoryNodePresentation.coverage(requeued) == "Waiting to be rechecked" && InventoryNodePresentation.explorerNote(requeued) != "Previously measured",
                 "presentation: a stale entry with no earlier value (a protected folder queued by a refresh) is not called previously measured")
        // Storage Atlas: palette, zoom, hit testing, Inspector, Navigator glyphs, cache bounds.
        let hues = (0..<6).map(AtlasPalette.regionHue)
        try test(Set(hues).count == 6 && zip(hues, hues.dropFirst()).allSatisfy { abs($0 - $1) > 0.05 } && AtlasPalette.regionHue(6) == hues[0],
                 "atlas palette: neighbouring top-level regions take distinct restrained hues, repeating in a fixed order")
        for dark in [true, false] {
            let parentTone = AtlasPalette.tone(hue: hues[1], isFolder: true, depth: 0, treatment: .measured, dark: dark)
            let childTone = AtlasPalette.tone(hue: hues[1], isFolder: true, depth: 1, treatment: .measured, dark: dark)
            let earlierTone = AtlasPalette.tone(hue: hues[1], isFolder: true, depth: 0, treatment: .earlier, dark: dark)
            let fileTone = AtlasPalette.tone(hue: hues[1], isFolder: false, depth: 0, treatment: .measured, dark: dark)
            try test(childTone.hue == parentTone.hue && childTone.brightness > parentTone.brightness && earlierTone.hue == parentTone.hue
                     && earlierTone.saturation < parentTone.saturation && fileTone.saturation < parentTone.saturation,
                     "atlas palette (\(dark ? "dark" : "light")): contents keep their region's hue a step brighter; earlier sizes keep the hue, quieter; files are near-neutral")
        }
        try test(AtlasPalette.treatment(mapNode(600, 1, status: .lowerBound)) == .partial && AtlasPalette.treatment(mapNode(601, 1, status: .stale)) == .earlier
                 && AtlasPalette.treatment(mapNode(602, 1)) == .measured, "atlas palette: partial and earlier sizes map to their own treatments")
        let view = CGSize(width: 1000, height: 400), plateRect = CGRect(x: 600, y: 100, width: 200, height: 80)
        let entering = AtlasZoom.start(entering: true, rect: plateRect, in: view)
        let enteredTopLeft = entering.apply(.zero), enteredBottomRight = entering.apply(CGPoint(x: 1000, y: 400))
        try test(plateRect.insetBy(dx: -0.001, dy: -0.001).contains(enteredTopLeft) && plateRect.insetBy(dx: -0.001, dy: -0.001).contains(enteredBottomRight)
                 && abs((enteredTopLeft.x + enteredBottomRight.x) / 2 - plateRect.midX) < 0.001,
                 "atlas zoom: entering a folder starts with the whole view centred inside the plate it occupied (uniform scale)")
        let leaving = AtlasZoom.start(entering: false, rect: plateRect, in: view)
        let leftCentre = leaving.apply(CGPoint(x: plateRect.midX, y: plateRect.midY))
        try test(abs(leftCentre.x - 500) < 0.001 && abs(leftCentre.y - 200) < 0.001 && leaving.scale > 1,
                 "atlas zoom: leaving a folder starts enlarged with the folder you left centred in the view")
        try test(entering.interpolated(1) == .identity && entering.interpolated(0) == entering && AtlasZoom.animates(reduceMotion: true) == false && AtlasZoom.animates(reduceMotion: false),
                 "atlas zoom: transitions settle exactly on the proportional layout, and Reduce Motion turns spatial zoom off")
        let hitPlan = InventoryMapPlan(items: mapItems, start: 0, beyond: nil, canLoadMore: false, in: canvas, minShare: 0)
        let firstPlate = hitPlan.tiles[0]
        let innerPlan = InventoryMapPlan(items: [mapNode(700, 60, parent: firstPlate.id), mapNode(701, 40, folder: false, parent: firstPlate.id)], start: 0, beyond: nil, canLoadMore: false,
                                         in: CGRect(x: 0, y: 0, width: firstPlate.rect.width - 8, height: firstPlate.rect.height - 24), minShare: 0)
        let innerOrigin = CGPoint(x: firstPlate.rect.minX + 4, y: firstPlate.rect.minY + 20)
        let nestedPoint = CGPoint(x: innerOrigin.x + innerPlan.tiles[1].rect.midX, y: innerOrigin.y + innerPlan.tiles[1].rect.midY)
        try test(AtlasHitTest.hit(nestedPoint, plan: hitPlan, nested: [firstPlate.id: (innerPlan, innerOrigin)]) == AtlasHit(tile: 701, region: firstPlate.id)
                 && AtlasHitTest.hit(CGPoint(x: hitPlan.tiles[1].rect.midX, y: hitPlan.tiles[1].rect.midY), plan: hitPlan, nested: [:]) == AtlasHit(tile: hitPlan.tiles[1].id, region: nil)
                 && AtlasHitTest.hit(CGPoint(x: -5, y: -5), plan: hitPlan, nested: [:]) == nil,
                 "atlas hit testing: a point resolves to the nested plate inside a region, the top-level plate elsewhere, and nothing outside the map")
        let inspectorParent = mapNode(800, 1_000)
        let inspected = InventoryInspectorPresentation(node: mapNode(801, 250, parent: 800), parent: inspectorParent) { "\($0) B" }
        try test(inspected.shareOfParent == 0.25 && inspected.shareText == "25% of n800" && inspected.allocated == "250 B" && inspected.measurement == "Complete" && inspected.explanation == nil,
                 "inspector: a measured entry shows its size and its exact share of the enclosing folder")
        let locked = InventoryInspectorPresentation(node: mapNode(802, nil, status: .unknown, parent: 800), parent: inspectorParent) { "\($0) B" }
        try test(locked.shareOfParent == nil && locked.measurement == "Access restricted" && locked.explanation?.contains("unknown, not zero") == true && locked.logical == "—",
                 "inspector: a protected entry has no share and explains that its size is unknown, not zero")
        try test(InventoryNavigatorGlyph.glyph(mapNode(803, 1)) == nil && InventoryNavigatorGlyph.glyph(mapNode(804, nil, status: .unknown)) == .restricted
                 && InventoryNavigatorGlyph.glyph(mapNode(805, 5, status: .stale)) == .earlier && InventoryNavigatorGlyph.glyph(mapNode(806, nil, status: .stale)) == .waiting,
                 "navigator: measured rows carry no glyph; protected, earlier and waiting states each have their own")
        let hashName = "sha256-2f4a9c3910c64e7d"
        try test(atlasMiddleTruncated(hashName, keeping: 11) == "sha25…c64e7d" .replacingOccurrences(of: "sha25…c64e7d", with: atlasMiddleTruncated(hashName, keeping: 11))
                 && atlasMiddleTruncated(hashName, keeping: 11).count == 11 && atlasMiddleTruncated(hashName, keeping: 11).hasPrefix("sha25") && atlasMiddleTruncated(hashName, keeping: 11).hasSuffix("64e7d")
                 && atlasMiddleTruncated("short", keeping: 11) == "short" && atlasMiddleTruncated(hashName, keeping: 1) == "…",
                 "atlas labels: middle truncation keeps the start and end of a name within the visible budget, and leaves short names whole")
        var recency = InventoryRecency(capacity: 3)
        let dropped = (1...6).flatMap { recency.use(Int64($0)) }
        recency.use(4)
        try test(dropped == [1, 2, 3] && recency.keys == [5, 6, 4], "atlas cache: the nested cache keeps at most its capacity, dropping the least recently used folders")
        // Atlas selection of an entry inside a region reveals it in the Navigator (the controller's select path).
        var atlasState = InventoryExplorerState()
        atlasState.setRoot(explorerRoot)
        atlasState.receive(parent: 1, page: InventoryChildPage(items: [docs, apps, note], next: nil))
        let deepFile = explorerNode(30, parent: 10, "deep.bin", folder: false, size: 300)
        atlasState.update(deepFile)
        try test(atlasState.expand(10), "atlas → navigator: selecting a file inside a region expands that folder in the Navigator (its page is requested)")
        atlasState.receive(parent: 10, page: InventoryChildPage(items: [deepFile], next: nil))
        atlasState.selection = 30
        try test(atlasState.rows.contains { $0.id == 30 && $0.depth == 1 } && atlasState.handle(.left) == .moved && atlasState.selection == 10,
                 "atlas → navigator: the selected nested file is a visible row, and ← from it moves to its folder")
        let mostlyStale = (0..<6).map { mapNode(500 + Int64($0), 10, status: .stale) } + [mapNode(510, 10), mapNode(511, nil, status: .unknown)]
        try test(InventoryNodePresentation.sharedFreshness(mostlyStale) == "Previously measured" && InventoryNodePresentation.sharedFreshness(Array(mostlyStale.suffix(3))) == nil
                 && InventoryNodePresentation.explorerNote(mostlyStale.last!) == "Access restricted",
                 "presentation: an earlier-size state shared by most entries is stated once; exceptions such as access restricted keep their own note")
        var manualRefresh = inventoryStatus(reconcile: true, initial: .complete); manualRefresh.refreshIsManual = true; manualRefresh.refreshFraction = 0.157
        try test(InventoryStatusPresentation(status: manualRefresh).headline == "Refreshing the entire inventory · about 15% rechecked" && condition(manualRefresh) == .needsReconciliation,
                 "a requested full refresh shows that it is running and how far its recheck has got (fixed endpoint, never a growing denominator)")

        // Time remaining (1.0.2): withheld without consistent evidence, stable once it is shown.
        func progressRun(from start: Date, seconds: Int, every step: Int = 10, queue: (Double) -> Double, nodes: ((Double) -> Double)? = nil, gap: ClosedRange<Int>? = nil) -> [InventoryProgressSample] {
            stride(from: 0, through: seconds, by: step).compactMap { t -> InventoryProgressSample? in
                if let gap, gap.contains(t) { return nil }
                return InventoryProgressSample(sampledAt: start.addingTimeInterval(Double(t)), completedListings: Int64(t * 40), queuedListings: Int64(max(0, queue(Double(t)))), nodes: nodes.map { Int64($0(Double(t))) } ?? Int64(t * 400), allocatedBytes: Int64(t) * 50_000_000)
            }
        }
        let t0 = anchor
        let noise: (Double) -> Double = { t in 1 + 0.03 * sin(t / 7) }
        let draining = progressRun(from: t0, seconds: 600, queue: { t in (60_000 - 50 * t) * noise(t) })
        let early = InventoryProgressEstimate(samples: Array(draining.prefix(4)), now: t0.addingTimeInterval(30))
        let growing = InventoryProgressEstimate(samples: progressRun(from: t0, seconds: 600, queue: { t in 10_000 + 30 * t }), now: t0.addingTimeInterval(600))
        let stopped = InventoryProgressEstimate(samples: draining, now: t0.addingTimeInterval(600 + 400))
        try test(early.remainingSeconds == nil && growing.remainingSeconds == nil && stopped.remainingSeconds == nil && InventoryProgressEstimate(samples: [], now: t0).remainingSeconds == nil
                 && InventoryProgressEstimate.remainingText(nil) == "Estimating time remaining…",
                 "ETA is withheld with too few samples, while the queue is still growing, or when the worker has stopped sampling")
        let steady = InventoryProgressEstimate(samples: draining, now: t0.addingTimeInterval(600))
        let truth = (60_000 - 50 * 600.0) / 50
        try test(steady.remainingSeconds.map { abs($0 - truth) / truth < 0.25 } == true && steady.itemsPerSecond.map { abs($0 - 400) < 2 } == true,
                 "a steadily draining queue yields an estimate within 25% of the true remaining time (\(Int(steady.remainingSeconds ?? -1)) s vs \(Int(truth)) s) and the current item rate")
        let longer = progressRun(from: t0, seconds: 1_500, queue: { t in (90_000 - 50 * t) * noise(t) })
        var texts = [String](), previous: Double?, maxJump = 0.0
        for t in stride(from: 600, through: 1_500, by: 10) {
            let now = t0.addingTimeInterval(Double(t))
            let value = InventoryProgressEstimate(samples: longer.filter { $0.sampledAt <= now }, now: now).remainingSeconds
            if let value, let previous { maxJump = max(maxJump, abs(value - previous) / max(previous, 1)) }
            previous = value
            texts.append(InventoryProgressEstimate.remainingText(value))
        }
        let changes = zip(texts, texts.dropFirst()).filter { $0 != $1 }.count
        try test(maxJump < 0.10 && changes <= 12 && !texts.contains("Estimating time remaining…"),
                 "the estimate moves smoothly between 10 s refreshes (largest change \(String(format: "%.1f", maxJump * 100))%) and its coarse wording changed \(changes) times over 15 minutes")
        let sliced = InventoryProgressEstimate(samples: progressRun(from: t0, seconds: 600, queue: { t in (60_000 - 50 * t) * noise(t) }, gap: 300...360), now: t0.addingTimeInterval(600))
        try test(sliced.remainingSeconds != nil, "persisted samples carry the estimate across a 60 s gap between worker slices")
        // A real pass grows its queue while discovering, then drains (observed on 905k entries). The growth
        // phase must not keep the estimate hidden once the drain is established.
        let realistic = progressRun(from: t0, seconds: 560, queue: { t in t < 100 ? 380 * t : max(0, 38_000 - 70 * (t - 100)) })
        // Early estimate from the volume's object count: shown within the first minute as a rough range,
        // replaced by the drain figure once the queue's drain is measurable.
        let roughRun = progressRun(from: t0, seconds: 90, queue: { t in 1_000 + 200 * t }, nodes: { t in 2_000 * t })
        let rough = InventoryProgressEstimate(samples: roughRun, volumeObjects: 1_000_000, now: t0.addingTimeInterval(90))
        try test(rough.isRough && rough.remainingSeconds.map { abs($0 - (1_000_000 - 180_000) / 2_000) < 60 } == true && rough.text.hasPrefix("Rough estimate:"),
                 "an early rough estimate appears from the volume's object count before the queue drains (\(rough.text))")
        try test(InventoryProgressEstimate(samples: roughRun, now: t0.addingTimeInterval(90)).remainingSeconds == nil,
                 "without a volume count (root is not a mount point) no early figure is invented")
        try test(inventoryVolumeObjectCount(root: "/System/Volumes/Data").map { $0 > 0 } == true && inventoryVolumeObjectCount(root: NSTemporaryDirectory()) == nil,
                 "the volume count is used only when the inventory root is the volume's mount point")
        let duringGrowth = InventoryProgressEstimate(samples: realistic.filter { $0.sampledAt <= t0.addingTimeInterval(90) }, now: t0.addingTimeInterval(90))
        let earlyDrain = InventoryProgressEstimate(samples: realistic.filter { $0.sampledAt <= t0.addingTimeInterval(180) }, now: t0.addingTimeInterval(180))
        let lateDrain = InventoryProgressEstimate(samples: realistic.filter { $0.sampledAt <= t0.addingTimeInterval(300) }, now: t0.addingTimeInterval(300))
        try test(duringGrowth.remainingSeconds == nil && earlyDrain.remainingSeconds == nil && lateDrain.remainingSeconds.map { abs($0 - (38_000 - 70 * 200.0) / 70) < 30 } == true,
                 "after discovery peaks, the estimate appears once 2 minutes of draining are observed, and not before (\(Int(lateDrain.remainingSeconds ?? -1)) s)")
        var lowSpace = inventoryStatus(); lowSpace.lowSpacePaused = true
        let lowPanel = InventoryInitializationPresentation(status: lowSpace, progress: draining, now: t0.addingTimeInterval(600))
        try test(condition(lowSpace) == .paused && InventoryStatusPresentation(status: lowSpace).headline == "Indexing paused: disk space is low"
                 && lowPanel.title == "Indexing paused: disk space is low" && lowPanel.rate == nil && lowPanel.remaining?.hasPrefix("No estimate while paused") == true,
                 "a low-space pause is shown explicitly, with no rate or countdown")

        // Storage accounting: macOS volume figures against indexed files, never forced to match.
        let airVolumes = [StorageVolumeUsage(name: "Macintosh HD", roles: ["System"], bytes: 11_000_000_000), StorageVolumeUsage(name: "Preboot", roles: ["Preboot"], bytes: 7_000_000_000),
                          StorageVolumeUsage(name: "VM", roles: ["VM"], bytes: 4_000_000_000), StorageVolumeUsage(name: "Recovery", roles: ["Recovery"], bytes: 1_200_000_000),
                          StorageVolumeUsage(name: "Macintosh HD - Data", roles: ["Data"], bytes: 207_500_000_000)]
        var limited = InventoryAccounting(); limited.indexedAllocated = 120_300_000_000; limited.protectedFolders = 312; limited.unavailableFolders = 41; limited.unreadableEntries = 7; limited.fullDiskAccess = "not_granted"
        let air = StorageAccountingPresentation(used: 230_900_000_000, free: 14_760_000_000, volumes: airVolumes, inventory: limited, ownDataBytes: 1_100_000_000)
        let everything = ([air.summary] + air.rows.flatMap { [$0.label, $0.value, $0.detail ?? ""] } + air.notes).joined(separator: " ")
        try test(air.rows.first?.value == "230.9 GB" && air.rows.first(where: { $0.label == "Data volume" })?.value == "207.5 GB" && air.rows.first(where: { $0.label == "macOS and other volumes" })?.value == "23.4 GB"
                 && air.unattributed == 87_200_000_000 && air.rows.contains { $0.label == "Not attributed to indexed files" && $0.value == "87.2 GB" },
                 "accounting compares indexed files with the Data volume they index (decimal units), and shows other volumes separately: \(air.summary)")
        try test(!everything.contains("System Data") && everything.contains("Not necessarily reclaimable") && everything.contains("312 folders are protected") && everything.contains("snapshots")
                 && everything.contains("Storage Monitor's own data folder (1.1 GB)") && air.needsFullDiskAccess,
                 "the unattributed space is explained by its possible causes, never labelled System Data or reclaimable; protected folders point to Full Disk Access")
        var cloned = InventoryAccounting(); cloned.indexedAllocated = 478_500_000_000; cloned.fullDiskAccess = "granted"
        let clonedMac = StorageAccountingPresentation(used: 472_900_000_000, free: 21_400_000_000, volumes: [StorageVolumeUsage(name: "Data", roles: ["Data"], bytes: 426_300_000_000)], inventory: cloned)
        try test(clonedMac.unattributed == -52_200_000_000 && clonedMac.rows.contains { $0.label.hasPrefix("Indexed sizes exceed") && $0.value == "52.2 GB" } && !clonedMac.needsFullDiskAccess,
                 "when indexed sizes exceed the Data volume (clones counted per file) the excess is shown as such, not as negative free space")
        let noIndex = StorageAccountingPresentation(used: 230_900_000_000, free: 14_760_000_000, volumes: airVolumes, inventory: nil)
        try test(noIndex.unattributed == nil && noIndex.summary == "230.9 GB used of 245.66 GB" && noIndex.notes.isEmpty,
                 "without an inventory only the macOS figures are shown")
        try test(StorageAccountingPresentation.fullDiskAccessGuidance.contains("this app") && StorageAccountingPresentation.fullDiskAccessGuidance.contains("Start Index") && StorageAccountingPresentation.fullDiskAccessGuidance.contains("without background monitoring"),
                 "Full Disk Access guidance supports independent viewer indexing and optional background monitoring")
        // VoiceOver: the bar's label is the panel title; its value states activity truthfully.
        try test(active.accessibilityValue.contains("no completion estimate") && paused.accessibilityValue == "Paused; saved results remain available" && paused.title != active.title, "VoiceOver labels distinguish active and paused first-pass states without an estimate")

        // Background monitoring setup is evaluated read-only from an isolated home.
        let setupRoot = folder.appendingPathComponent("monitoring-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: setupRoot) }
        func makeHelper(_ at: URL, version: String, build: String = "1") throws {
            try FileManager.default.createDirectory(at: at.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let binary = at.appendingPathComponent("Contents/MacOS/StorageMonitor")
            FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version, "CFBundleVersion": build], format: .xml, options: 0).write(to: at.appendingPathComponent("Contents/Info.plist"))
        }
        let setupHome = setupRoot.appendingPathComponent("home"), bundled = setupRoot.appendingPathComponent("Storage Monitor.app/Contents/Helpers/MacBook Storage Monitor.app")
        try makeHelper(bundled, version: "1.1.0")
        let off = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled)
        try test(off.state == .off && off.helperExecutable?.path.hasPrefix(bundled.path) == true, "monitoring setup reports off with no LaunchAgents and uses the bundled helper")
        let installedHelper = setupHome.appendingPathComponent("Applications/MacBook Storage Monitor.app")
        try makeHelper(installedHelper, version: "1.0.0")
        let agentDirectory = setupHome.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        func writeAgent(_ label: String, program: String, command: String = "supervise") throws {
            try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": [program, command]], format: .xml, options: 0).write(to: agentDirectory.appendingPathComponent("\(label).plist"))
        }
        let supervisorLabel = MonitoringSetupStatus.labels[0]
        try test(MonitoringSetupStatus.labels == ["local.macbook.storage-monitor"] && MonitoringSetupStatus.roleLabels.count == 3 && MonitoringSetupStatus.legacyLabels.count == 2, "monitoring consists of exactly one LaunchAgent; the two earlier agents are legacy")
        let installedExecutable = installedHelper.appendingPathComponent("Contents/MacOS/StorageMonitor").path
        try writeAgent(supervisorLabel, program: installedExecutable, command: "check")
        try test(MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled).state == .needsUpdate, "a main agent still running the check directly (a 2.4.1 install) is offered an update")
        for label in MonitoringSetupStatus.legacyLabels { try writeAgent(label, program: installedExecutable, command: "initialize-baseline") }
        try writeAgent(supervisorLabel, program: installedExecutable)
        let legacyLeft = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled)
        try test(legacyLeft.state == .needsUpdate && legacyLeft.summary.contains("separate background tasks"), "leftover legacy baseline and inventory agents beside the supervisor need an update")
        try makeHelper(installedHelper, version: "1.1.0")
        let legacyEqualVersions = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled)
        try test(legacyEqualVersions.state == .needsUpdate && legacyEqualVersions.summary.contains("separate background tasks"), "legacy agents need an update even when the helper versions match")
        let legacyLoaded = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: LaunchdState(loaded: Set(MonitoringSetupStatus.labels + MonitoringSetupStatus.legacyLabels), disabled: []))
        try test(legacyLoaded.state == .needsUpdate, "loaded legacy jobs need an update")
        for label in MonitoringSetupStatus.legacyLabels { try FileManager.default.removeItem(at: agentDirectory.appendingPathComponent("\(label).plist")) }
        try makeHelper(installedHelper, version: "1.0.0")
        let outdated = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled)
        try test(outdated.state == .needsUpdate && outdated.summary.contains("1.0.0 (1)") && outdated.summary.contains("1.1.0 (1)"), "an app update with an older installed background monitor offers an explicit update")
        try makeHelper(installedHelper, version: "1.1.0")
        try test(MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled).state == .on, "matching versions with the one supervisor agent present report monitoring on")
        try writeAgent(supervisorLabel, program: setupRoot.appendingPathComponent("Volumes/gone/StorageMonitor").path)
        try test(MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled).state == .incomplete, "an agent pointing at a missing program (for example an ejected disk image) is reported for repair")
        let noBundle = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: nil)
        try test(noBundle.helperExecutable?.path == installedExecutable && noBundle.bundledVersion == nil, "a build without the bundled helper can still disable using the installed monitor")
        try test(MonitoringSetupAction.enable.arguments == ["install"] && MonitoringSetupAction.disable.arguments == ["uninstall"] && MonitoringSetupAction.notifications.arguments == ["authorize"],
                 "setup actions run only the background monitor's own install, uninstall and authorize commands")
        try test(MonitoringSetupStatus.consent.contains("~/Applications") && MonitoringSetupStatus.consent.contains("one background task") && MonitoringSetupStatus.consent.contains("history is kept")
                 && MonitoringSetupStatus.disableConfirmation.contains("history"), "consent text states what is installed, where data lives, and that disabling keeps history")
        try test(MonitoringSetupStatus.permissions.contains("Full Disk Access is optional") && MonitoringSetupStatus.permissions.contains("inaccessible") && MonitoringSetupStatus.permissions.contains("never grants it silently")
                 && MonitoringSetupStatus.permissions.contains("MacBook Storage Monitor.app"), "permission guidance explains optional Full Disk Access, inaccessible areas and the manual grant path")

        // Settings reports what launchd itself has loaded, not only which files exist.
        let parsed = LaunchdState.parse(list: "PID\tStatus\tLabel\n-\t0\tlocal.macbook.storage-monitor\n412\t0\tlocal.macbook.storage-monitor.inventory\n-\t0\tcom.apple.other\n",
                                        disabled: "disabled services = {\n\t\"local.macbook.storage-monitor.baseline\" => disabled\n\t\"com.apple.x\" => enabled\n\t\"legacy.label\" => true\n}\n")
        try test(parsed.loaded == ["local.macbook.storage-monitor", "local.macbook.storage-monitor.inventory", "com.apple.other"] && parsed.disabled == ["local.macbook.storage-monitor.baseline", "legacy.label"],
                 "launchctl list and print-disabled output are parsed into loaded and disabled labels")
        let allLoaded = LaunchdState(loaded: Set(MonitoringSetupStatus.labels), disabled: [])
        try writeAgent(supervisorLabel, program: installedExecutable)
        let live = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: allLoaded)
        try test(live.state == .on && !live.summary.contains("did not report"), "monitoring is reported on only when the agent file exists and launchd has loaded it")
        // Worker health comes from the supervisor's status file; the single agent's own state comes from launchd.
        let dataDirectory = MonitoringSetupStatus.dataDirectory(home: setupHome)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let selfPid = Int32(getpid())
        try SupervisorStatus(supervisorPid: selfPid, startedAt: 1, updatedAt: 2, roles: ["check": .init(pid: nil, lastStart: 8, lastExit: 0, lastExitTime: 9),
            "baseline": .init(pid: nil, lastStart: 5, lastExit: 75, lastExitTime: 6), "inventory": .init(pid: selfPid, lastStart: 7)]).write(data: dataDirectory)
        let supervised = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: LaunchdState(loaded: Set(MonitoringSetupStatus.labels), disabled: [], jobs: [supervisorLabel: .init(pid: Int(selfPid), lastExitStatus: 0)]))
        let roles = MonitoringSetupStatus.roleLabels
        try test(supervised.state == .on && supervised.launchd?.jobs[roles[1]] == .init(pid: nil, lastExitStatus: 75) && supervised.launchd?.jobs[roles[2]]?.pid == Int(selfPid) && supervised.launchd?.jobs[roles[0]] == .init(pid: nil, lastExitStatus: 0)
                 && supervised.launchd?.loaded.isSuperset(of: roles) == true, "worker jobs (check, baseline, inventory) are read from supervisor-status.json beside launchd's report of the one agent")
        let supervisedHealth = MonitoringHealthPresentation(setup: supervised, lastSuccess: nil, now: Date())
        try test(supervisedHealth.state == .resuming && supervisedHealth.jobDetails.contains("Folder baseline: not running now; last exit 75") && supervisedHealth.jobDetails.contains("Inventory indexer: running (PID \(selfPid)); last exit unknown")
                 && supervisedHealth.jobDetails.contains("Capacity checks: not running now; last exit 0") && supervisedHealth.jobDetails.contains { $0.hasPrefix("Background agent: running (PID") },
                 "baseline exit 75 reads as resumable, not failed, and the agent's own state is listed")
        let restarted = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: LaunchdState(loaded: Set(MonitoringSetupStatus.labels), disabled: [], jobs: [supervisorLabel: .init(pid: Int(selfPid) + 1, lastExitStatus: 0)]))
        try test(restarted.launchd?.jobs[roles[2]]?.pid == nil, "a status file written by an earlier supervisor process never reports running workers")
        let crashed = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: LaunchdState(loaded: Set(MonitoringSetupStatus.labels), disabled: [], jobs: [supervisorLabel: .init(pid: nil, lastExitStatus: 1)]))
        try test(MonitoringHealthPresentation(setup: crashed, lastSuccess: Date(), now: Date()).state == .failed, "a stopped supervisor agent with a non-zero exit is an attention state")
        let failedCheck = SupervisorStatus(supervisorPid: selfPid, startedAt: 1, updatedAt: 2, roles: ["inventory": .init(pid: nil, lastStart: 7, lastExit: 78, lastExitTime: 8)])
        try failedCheck.write(data: dataDirectory)
        let failedInventory = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: LaunchdState(loaded: Set(MonitoringSetupStatus.labels), disabled: [], jobs: [supervisorLabel: .init(pid: Int(selfPid), lastExitStatus: 0)]))
        try test(MonitoringHealthPresentation(setup: failedInventory, lastSuccess: Date(), now: Date()).state == .failed, "a fatal inventory exit recorded by the supervisor needs attention")
        try FileManager.default.removeItem(at: SupervisorStatus.file(data: dataDirectory))
        let unloaded = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: LaunchdState(loaded: [], disabled: []))
        try test(unloaded.state == .incomplete && unloaded.summary.contains("not loaded"), "agents whose files exist but that launchd has not loaded are reported for repair, not as on")
        let turnedOff = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: LaunchdState(loaded: Set(MonitoringSetupStatus.labels), disabled: [supervisorLabel]))
        try test(turnedOff.state == .incomplete && turnedOff.summary.contains("Login Items"), "a task macOS has disabled is reported with where to look")
        let unknown = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: nil)
        try test(unknown.state == .on && unknown.summary.contains("did not report"), "when launchd cannot be queried, Settings says so instead of implying the tasks run")
        let orphanHome = setupRoot.appendingPathComponent("orphan")
        let orphanJob = MonitoringSetupStatus.evaluate(home: orphanHome, bundledHelper: bundled, launchd: LaunchdState(loaded: [MonitoringSetupStatus.labels[0]], disabled: []))
        try test(orphanJob.state == .incomplete && orphanJob.summary.contains("without its configuration"), "a task still loaded in launchd after its file was removed is not reported as off")
        try test(MonitoringSetupStatus.evaluate(home: orphanHome, bundledHelper: bundled, launchd: LaunchdState(loaded: [], disabled: [])).state == .off, "no files and nothing loaded is off")

        // Stale programs, duplicates and interrupted updates are repairable, never reported as on.
        let copyElsewhere = setupRoot.appendingPathComponent("Other/MacBook Storage Monitor.app")
        try makeHelper(copyElsewhere, version: "1.1.0")
        try writeAgent(supervisorLabel, program: copyElsewhere.appendingPathComponent("Contents/MacOS/StorageMonitor").path)
        let staleCopy = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: allLoaded)
        try test(staleCopy.state == .incomplete && staleCopy.summary.contains("different copy"), "an agent running a different copy of the monitor (for example an old build) is reported for repair")
        try writeAgent(supervisorLabel, program: installedExecutable)
        let duplicate = agentDirectory.appendingPathComponent("com.example.old-monitor.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": MonitoringSetupStatus.labels[0], "ProgramArguments": [installedExecutable]], format: .xml, options: 0).write(to: duplicate)
        let duplicatedAgent = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: allLoaded)
        try test(duplicatedAgent.state == .incomplete && duplicatedAgent.summary.contains("com.example.old-monitor.plist"), "a duplicate agent file for one of this monitor's labels is reported for repair")
        try FileManager.default.removeItem(at: duplicate)
        let journal = setupHome.appendingPathComponent("Library/Application Support/MacBook Storage Monitor/install-transaction/journal.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: journal)
        let interrupted = MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: allLoaded)
        try test(interrupted.state == .incomplete && interrupted.summary.contains("interrupted"), "an interrupted update is reported for repair until the helper finishes or reverts it")
        try FileManager.default.removeItem(at: journal)
        try test(MonitoringSetupStatus.evaluate(home: setupHome, bundledHelper: bundled, launchd: allLoaded).state == .on, "after repair conditions clear, monitoring reads on again")

        // Enabling and updating are never cut off by a timer; only the notification prompt waits for a bounded answer.
        try test(MonitoringSetupAction.enable.timeLimit == nil && MonitoringSetupAction.disable.timeLimit == nil && MonitoringSetupAction.notifications.timeLimit == 130,
                 "install and uninstall run to completion with no fixed time limit")
        let chatty = setupRoot.appendingPathComponent("chatty.sh")
        FileManager.default.createFile(atPath: chatty.path, contents: Data("#!/bin/sh\nhead -c 300000 /dev/zero | tr '\\0' x\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
        let chattyResult = await MonitoringSetupAction.enable.run(helper: chatty)
        try test(chattyResult.ok && chattyResult.output.count == 300_000, "a helper writing more than a pipe buffer completes instead of stalling")

        // First launch: missing history directs the person to Settings → Background Monitoring.
        let missingHistory = HistoryError.missing("/nowhere/history.sqlite3")
        try test(missingHistory.isMissingHistory && missingHistory.localizedDescription.contains("Settings → Background Monitoring") && !missingHistory.localizedDescription.contains("/nowhere")
                 && !HistoryError.sqlite("x").isMissingHistory, "missing history on first launch explains how to turn monitoring on in Settings, without exposing a database path")

        func inventoryNode(status: InventoryValueStatus, coverage: String, listing: String? = nil, value: Int64? = nil, children: Int64 = 0, reason: String? = nil) -> InventoryNode {
            InventoryNode(id: 1, parentID: 0, identity: InventoryIdentity(device: 1, inode: 1, birthNanoseconds: 1), path: "/fixture", name: "fixture", kind: .directory, logicalBytes: status == .stale ? nil : value, allocatedBytes: status == .stale ? nil : value, previousLogicalBytes: status == .stale ? value : nil, previousAllocatedBytes: status == .stale ? value : nil, objectLogicalBytes: nil, objectAllocatedBytes: nil, directLogicalBytes: 0, directAllocatedBytes: 0, childCount: children, descendantFiles: 0, descendantDirectories: 0, status: status, coverageState: coverage, listingState: listing, statusReason: reason, measuredAt: value == nil ? nil : anchor, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
        }
        let discovered = inventoryNode(status: .lowerBound, coverage: "pending", listing: "pending")
        try test(InventoryNodePresentation.coverage(discovered) == "Discovered" && InventoryNodePresentation.size(discovered.allocatedBytes, node: discovered, formatter: String.init) == "No size yet", "discovered empty directory never presents zero as a measured size")
        // D11: a folder stale only through a deferred descendant vs a folder that is itself stale.
        let mostlyCurrent = inventoryNode(status: .stale, coverage: "stale", value: 98_540, reason: inventoryDescendantStaleReason)
        let whollyStale = inventoryNode(status: .stale, coverage: "stale", value: 98_540, reason: "Deletion or descendant reconciliation is pending; previous totals are stale.")
        let current = inventoryNode(status: .complete, coverage: "complete", value: 98_540)
        try test(InventoryNodePresentation.coverage(mostlyCurrent) == "Includes earlier sizes" && InventoryNodePresentation.size(mostlyCurrent.previousAllocatedBytes, node: mostlyCurrent, formatter: String.init) == "≈ 98540"
                 && InventoryNodePresentation.coverage(whollyStale) == "Previously measured" && InventoryNodePresentation.size(whollyStale.previousAllocatedBytes, node: whollyStale, formatter: String.init) == "Previously 98540"
                 && InventoryNodePresentation.coverage(current) == "Complete" && InventoryNodePresentation.size(current.allocatedBytes, node: current, formatter: String.init) == "98540",
                 "D11: a folder whose total includes a deferred subfolder's earlier size reads as approximate, not wholly previous; current and stale folders are unchanged")
        // D7: the notification state comes from what macOS reported to the background monitor.
        try test(NotificationPermission.parse("authorization=authorized alert=2 center=2") == .allowed && NotificationPermission.parse("authorization=denied alert=0") == .turnedOff
                 && NotificationPermission.parse("authorization=not_determined") == .notYetAllowed && NotificationPermission.parse(nil) == .unknown
                 && !NotificationPermission.allowed.canPrompt && !NotificationPermission.turnedOff.canPrompt && NotificationPermission.notYetAllowed.canPrompt
                 && NotificationPermission.allowed.text.contains("carries over") && !MonitoringSetupStatus.consent.contains("stay off until"),
                 "D7: Settings reflects existing notification permission (including one granted to an earlier version) and offers the prompt only while macOS can still show it")
        let incompleteZero = inventoryNode(status: .lowerBound, coverage: "partial", value: 0)
        try test(InventoryNodePresentation.size(incompleteZero.allocatedBytes, node: incompleteZero, formatter: String.init) == "No size yet", "incomplete directory zero is presented as no size yet")
        let partial = inventoryNode(status: .lowerBound, coverage: "partial", listing: "pending", value: 4096, children: 2)
        try test(InventoryNodePresentation.coverage(partial) == "Partial · waiting" && InventoryNodePresentation.size(partial.allocatedBytes, node: partial, formatter: String.init) == "Partial 4096", "pending observed directory is qualified without a physical lower-bound symbol")
        let stale = inventoryNode(status: .stale, coverage: "stale", listing: "enumerating", value: 8192, children: 2)
        try test(InventoryNodePresentation.coverage(stale) == "Previously measured" && InventoryNodePresentation.size(stale.previousAllocatedBytes, node: stale, formatter: String.init) == "Previously 8192", "stale measurements keep precedence over current activity")
        let restricted = inventoryNode(status: .unknown, coverage: "unknown", reason: "permission denied by privacy controls")
        let unavailable = inventoryNode(status: .unknown, coverage: "unknown", reason: "blocked I/O")
        try test(InventoryNodePresentation.coverage(restricted) == "Access restricted" && InventoryNodePresentation.coverage(unavailable) == "Unavailable", "restricted access is distinct from unavailable I/O")
        let excluded = inventoryNode(status: .unknown, coverage: "excluded")
        try test(InventoryNodePresentation.coverage(excluded) == "Outside measured scope" && InventoryNodePresentation.size(nil, node: excluded, formatter: String.init) == "Not measured", "excluded entries explain that they are outside measured scope")

        var filters = EventFilters()
        for type in EventTypeFilter.allCases {
            filters.type = type
            let matches = filters.apply(snapshot.events, now: anchor)
            try test(type == .snapshots ? matches.isEmpty : !matches.isEmpty,
                     "type filter \(type.rawValue) respects legacy history without snapshot evidence")
        }
        let snapshotVolume = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        func filterObservation(_ time: Date, snapshots: [APFSSnapshotRecord]) -> StorageObservation {
            StorageObservation(container: critical.measurement!.container, observedAt: time.timeIntervalSince1970,
                finishedAt: time.timeIntervalSince1970 + 1,
                inventories: [SnapshotInventory(volumeUUID: snapshotVolume, volumeName: "Fixture", observedAt: time.timeIntervalSince1970,
                    status: .complete, detail: "fixture", snapshots: snapshots)],
                capacities: [], swapAllocatedBytes: nil, swapUsedBytes: nil, vmCounters: nil, detail: "fixture")
        }
        var snapshotFilteredEvent = critical
        snapshotFilteredEvent.previousObservation = filterObservation(critical.previousTime!, snapshots: [])
        snapshotFilteredEvent.observation = filterObservation(critical.timestamp,
            snapshots: [APFSSnapshotRecord(uuid: "11111111-1111-1111-1111-111111111111", name: "filter-fixture", xid: 1)])
        filters.type = .snapshots
        try test(filters.apply([snapshotFilteredEvent], now: anchor).map(\.id) == [critical.id],
                 "snapshot type filter includes events with a comparable snapshot identity change")
        filters = EventFilters()
        for range in EventTimeFilter.allCases where range != .custom { filters.time = range; try test(!filters.apply(snapshot.events,now:anchor).isEmpty,"time filter \(range.rawValue)") }
        filters = EventFilters(); filters.time = .custom; filters.start = critical.timestamp; filters.end = critical.timestamp
        try test(filters.apply(snapshot.events,now:anchor).map(\.id) == [critical.id],"custom date endpoints inclusive and composable")
        filters.start = anchor; filters.end = critical.timestamp
        try test(filters.validation != nil && filters.apply(snapshot.events,now:anchor).isEmpty,"invalid custom date range is explicit")
        filters = EventFilters()
        for size in EventSizeFilter.allCases where size != .custom { filters.size = size; try test(!filters.apply(snapshot.events,now:anchor).isEmpty,"size filter \(size.rawValue)") }
        filters.size = .custom; filters.customThreshold = "1"; filters.customUnit = "GB"
        try test(filters.apply(snapshot.events,now:anchor).allSatisfy { abs(Double($0.delta!)) > 1e9 },"custom threshold strict greater; unknown deltas excluded")
        for invalid in ["nan","inf","-1","invalid"] { filters.customThreshold = invalid; try test(filters.validation != nil && filters.apply(snapshot.events,now:anchor).isEmpty,"invalid custom threshold \(invalid)") }
        filters.customThreshold = "1"; filters.customUnit = "GiB"
        try test(filters.validation != nil,"unsupported custom unit rejected")
        filters = EventFilters()
        for severity in EventSeverity.allCases { filters.severity = severity.rawValue; try test(!filters.apply(snapshot.events,now:anchor).isEmpty,"severity filter \(severity.label)") }
        filters = EventFilters(); filters.type = .loss; filters.size = .gb1
        try test(filters.apply(snapshot.events,now:anchor).map(\.id).sorted() == ["reading:10","reading:11","reading:8"].sorted(),"Storage Loss >1 GB in last24h combines filters")
        filters.severity = EventSeverity.critical.rawValue
        try test(filters.apply(snapshot.events,now:anchor).map(\.id) == ["reading:11"],"type/time/size/severity combination")
        filters.search = "fixture-critical"
        try test(filters.apply(snapshot.events,now:anchor).count == 1,"search composes with all filters and searches recorded alert evidence")
        filters = EventFilters(); filters.search = "code_sign_clone"
        try test(filters.apply(snapshot.events,now:anchor).count == 3,"search includes stored diagnostic information")
        filters = EventFilters(); filters.sort = .loss
        try test(filters.apply(snapshot.events,now:anchor).first?.id == "reading:10","largest loss sort")
        filters.sort = .recovery
        try test(filters.apply(snapshot.events,now:anchor).first?.id == "reading:12","largest recovery sort")
        filters.sort = .absolute
        try test(filters.apply(snapshot.events,now:anchor).first?.id == "reading:10","largest absolute change sort")
        filters.sort = .oldest
        let oldest = filters.apply(snapshot.events,now:anchor).first!.timestamp
        filters.sort = .newest
        try test(filters.apply(snapshot.events,now:anchor).first!.timestamp > oldest,"newest and oldest timestamp sorts")
        let persisted = try JSONDecoder().decode(EventFilters.self,from:JSONEncoder().encode(filters))
        try test(persisted == filters,"filter preferences roundtrip persistently")
        try test(snapshot.baseline(seconds:3600)?.id == 7,"hour comparison uses actual predecessor at/before target within cadence tolerance")
        try test(snapshot.baseline(seconds:86400)?.id == 5,"day comparison uses actual24h20m baseline")
        let sparse = HistorySnapshot(measurements:[snapshot.measurements[0],snapshot.measurements.last!],events:[],loadedAt:anchor)
        try test(sparse.baseline(seconds:3600) == nil && sparse.baseline(seconds:86400) == nil,"long gaps never masquerade as one-hour or24-hour changes")
        let empty = try await HistoryReader(path:folder.appendingPathComponent("empty.sqlite3").path).load()
        try test(empty.events.isEmpty && empty.latest == nil,"valid empty history")
        for name in ["missing.sqlite3","corrupt.sqlite3","zero.sqlite3"] {
            var rejected = false
            do { _ = try await HistoryReader(path:folder.appendingPathComponent(name).path).load() }
            catch { rejected = true }
            try test(rejected,"safe error for \(name)")
        }

        // MARK: Diagnostic analysis

        // Acceptance: the real Oct 21 03:30 → 04:00 event, rows copied verbatim
        // from production history in the original (schema 1) format.
        let fixtureDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? "tests/fixtures", isDirectory: true)
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureDir.appendingPathComponent("2026-10-21-0400-event.json"))) as! [String: Any]
        let acceptancePath = folder.appendingPathComponent("acceptance-oct21.sqlite3")
        let acceptance = try create("acceptance-oct21.sqlite3")
        func bindAll(_ sql: String, _ values: [Any?]) {
            var stmt: OpaquePointer?; precondition(sqlite3_prepare_v2(acceptance, sql, -1, &stmt, nil) == SQLITE_OK); defer { sqlite3_finalize(stmt) }
            for (i, v) in values.enumerated() {
                let index = Int32(i + 1)
                if let d = v as? Double, !(v is Int) { sqlite3_bind_double(stmt, index, d) }
                else if let n = v as? NSNumber, CFNumberIsFloatType(n) { sqlite3_bind_double(stmt, index, n.doubleValue) }
                else if let n = v as? NSNumber { sqlite3_bind_int64(stmt, index, n.int64Value) }
                else if let t = v as? String { sqlite3_bind_text(stmt, index, t, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                else { sqlite3_bind_null(stmt, index) }
            }
            precondition(sqlite3_step(stmt) == SQLITE_DONE)
        }
        for r in source["readings"] as! [[String: Any]] { bindAll("INSERT INTO readings VALUES(?,?,?,?,?,?)", [r["id"], r["timestamp"], r["container"], r["free"], r["used"], r["volumes"]]) }
        for a in source["alerts"] as! [[String: Any]] { bindAll("INSERT INTO alerts VALUES(?,?,?,?,?,?,?)", [a["id"], a["timestamp"], a["severity"], a["reasons"], a["free"], a["delta"], a["notification"]]) }
        for d in source["diagnostics"] as! [[String: Any]] { bindAll("INSERT INTO diagnostics VALUES(?,?,?)", [d["id"], d["timestamp"], d["snapshot"]]) }
        sqlite3_close(acceptance)
        let real = try await HistoryReader(path: acceptancePath.path).load()
        let event = real.events.first { $0.id == "reading:12" }!
        let analysis = CauseAnalyzer.analyze(event)
        try test(real.events.count == 3 && event.alerts.count == 1 && event.diagnostics.count == 1, "acceptance: legacy history loads; alert and 4:00 AM snapshot attach to reading #12")
        try test(event.delta == -2_178_781_184, "acceptance: physical free-space change is -2,178,781,184 bytes")
        let volumeDelta = Dictionary(uniqueKeysWithValues: analysis.breakdown.volumes.map { ($0.role ?? $0.name, $0.delta) })
        try test(volumeDelta["Data"] == 1_103_945_728 && volumeDelta["VM"] == 1_073_782_784 && volumeDelta["Update"] == 1_052_672, "acceptance: Data +1,103,945,728, VM +1,073,782,784, Update +1,052,672 bytes")
        try test(["System", "Preboot", "Recovery"].allSatisfy { volumeDelta[$0] == 0 }, "acceptance: other volumes unchanged")
        try test(analysis.breakdown.reconciliation == .exact, "acceptance: volume changes reconcile exactly with the recorded loss")
        try test(analysis.breakdown.reconciliationText == "Measured volume changes account for the recorded loss exactly.", "acceptance: reconciliation sentence")
        try test(analysis.causes.map(\.title) == ["Data volume growth", "Virtual memory growth", "Other system allocation"], "acceptance: causes ranked Data, VM, Update by measured size")
        try test(analysis.causes.map(\.delta) == [1_103_945_728, 1_073_782_784, 1_052_672], "acceptance: cause amounts are measured allocation changes")
        try test(signedChange(analysis.causes[0].delta) == "+1.10 GB" && signedChange(analysis.causes[1].delta) == "+1.07 GB" && signedChange(analysis.causes[2].delta) == "+1.05 MB", "acceptance: displayed as +1.10 GB, +1.07 GB, +1.05 MB")
        try test(analysis.causes.allSatisfy { $0.evidenceClass == .confirmed && $0.application == "Unknown" }, "acceptance: allocation confirmed, responsible application unknown")
        let causeText = analysis.causes.map { [$0.title, $0.explanation, $0.application, $0.allocationNote] + $0.support }.flatMap { $0 }.joined(separator: " ")
        try test(!["Chrome", "Claude", "Codex", "Google"].contains { causeText.contains($0) }, "acceptance: no unsupported application attribution in causes")
        try test(analysis.headline.contains("decreased by 2.18 GB"), "acceptance: plain-language headline")
        // Swap was compared 2:21 AM → 4:00 AM, a longer span than this 3:30 → 4:00 event.
        let swapRow = analysis.evidence.first { $0.source == .swap }
        try test(swapRow != nil && swapRow!.intervalMatches == false && swapRow!.interval.contains("Different interval from this event"), "mismatched diagnostic interval shown with its own interval")
        try test(analysis.causes[1].support.isEmpty, "mismatched swap change is not attached to VM growth as its cause")
        let allocatedSwap = event.comparisons.first { $0.current.id == "swap:allocated" }, usedSwap = event.comparisons.first { $0.current.id == "swap:used" }
        try test(allocatedSwap?.current.bytes == 6144 * 1_048_576 && allocatedSwap?.delta == 2048 * 1_048_576, "swap allocation parsed separately (6144 MiB, +2048 MiB)")
        try test(usedSwap?.current.bytes == Int64((4756.19 * 1_048_576).rounded()) && usedSwap?.delta != allocatedSwap?.delta, "swap usage parsed separately from allocation")
        try test(swapRow?.values.contains("Allocated 6.44 GB") == true && swapRow?.values.contains("Used 4.99 GB") == true, "swap evidence shows allocated and used")
        try test(analysis.evidence.allSatisfy { $0.title != "folders" && !$0.title.contains("Application Support") && !$0.title.contains("Caches") }, "partial and timed-out directory totals are not shown as evidence")
        try test(analysis.hiddenUnchanged >= 1 && !analysis.evidence.contains { $0.title.contains("Chrome") }, "unchanged Chrome clone measurement hidden by default")
        let collection = analysis.collection!
        try test(collection.refusedLocations > 0 && collection.lines.first!.hasPrefix("Some protected directories could not be inspected ("), "permission refusals summarised in plain language")
        let rawRefusals = event.diagnostics[0].commands.reduce(0) { $0 + $1.output.components(separatedBy: "Operation not permitted").count - 1 }
        try test(collection.refusedLocations < rawRefusals, "repeated permission refusals de-duplicated by path (\(collection.refusedLocations) unique of \(rawRefusals) lines)")
        try test(collection.lines.contains { $0.contains("stopped at a time limit") }, "timed-out legacy measurements reported as incomplete")
        try test(collection.lines.contains { $0.contains("APFS diagnostic output was cut off") }, "truncated APFS XML identified and not parsed")
        let repeated: [String: Any] = ["name": "Claude Desktop VM bundle", "path": "/x/vm", "status": "absent or inaccessible"]
        let duplicated = try EvidenceParser.diagnostic(id: 1, timestamp: anchor, json: String(data: JSONSerialization.data(withJSONObject: ["commands": [repeated, repeated, repeated]]), encoding: .utf8)!)
        try test(duplicated.commands.count == 1 && duplicated.collectors.count == 1 && event.diagnostics[0].commands.count == 17, "identical legacy diagnostic records collapsed; distinct ones kept")
        try test(!collection.lines.joined().contains("Exit") && !collection.lines.joined().contains("/Users/"), "collection summary avoids exit codes and long paths")
        let details = EventPanelText.details(event), raw = EventPanelText.raw(event)
        try test(details.contains("reading #12 vs #11") && details.contains("DD334B7B-B65C-4113-8342-24FB61DC16A6") && details.contains("1,073,782,784 bytes"), "provenance (reading IDs, UUIDs, exact bytes) kept in copied details")
        try test(raw.contains("<?xml") && raw.contains("Operation not permitted"), "raw output remains available, unabridged")
        let condensed = event.diagnostics[0].commands.first { $0.name.contains("/private/var/folders") }!.condensedOutput
        try test(condensed.components(separatedBy: "Operation not permitted").count - 1 <= 2 && condensed.contains("more protected locations"), "displayed raw output folds repeated refusals")
        try test(TechnicalSection.expandedByDefault.isEmpty && TechnicalSection.allCases.count == 10, "technical details collapsed by default, organised by source")

        // Synthetic cases built from the same model types.
        func volume(_ id: String, _ role: String, _ bytes: Int64) -> VolumeAllocation { VolumeAllocation(id: id, name: role, bytes: bytes, roles: [role]) }
        func reading(_ id: Int64, _ minute: Double, free: Int64, _ volumes: [VolumeAllocation]) -> Measurement { Measurement(id: id, timestamp: anchor.addingTimeInterval(minute * 60), container: "S", free: free, used: 245 * decimalGB - free, volumes: volumes) }
        func storageEvent(_ before: Measurement?, _ after: Measurement?, comparisons: [EvidenceComparison] = [], diagnostics: [DiagnosticRecord] = [], alerts: [AlertRecord] = []) -> StorageEvent {
            StorageEvent(id: "synthetic", timestamp: after?.timestamp ?? anchor, category: "Storage loss", delta: before.flatMap { b in after.map { $0.free - b.free } }, previousFree: before?.free, currentFree: after?.free, previousTime: before?.timestamp, severity: .warning, measurement: after, previousMeasurement: before, alerts: alerts, diagnostics: diagnostics, comparisons: comparisons, source: "synthetic", searchText: "")
        }
        let base = [volume("d", "Data", 100 * decimalGB), volume("v", "VM", 2 * decimalGB), volume("u", "Update", decimalGB)]
        let mixedBefore = reading(1, -30, free: 50 * decimalGB, base)
        let mixedAfter = reading(2, 0, free: 48 * decimalGB, [volume("d", "Data", 103 * decimalGB), volume("v", "VM", 1 * decimalGB), volume("u", "Update", decimalGB)])
        let mixed = CauseAnalyzer.analyze(storageEvent(mixedBefore, mixedAfter))
        try test(mixed.causes.map(\.title) == ["Data volume growth"] && mixed.breakdown.offsettingVolumes.map(\.role) == ["VM"], "mixed changes: only growth ranks as a cause; VM decrease is offsetting")
        try test(mixed.breakdown.reconciliation == .exact, "mixed positive/negative volume changes reconcile by net sum")
        let gapAfter = reading(2, 0, free: 47 * decimalGB, [volume("d", "Data", 101 * decimalGB), volume("v", "VM", 2 * decimalGB), volume("u", "Update", decimalGB)])
        let gap = CauseAnalyzer.analyze(storageEvent(mixedBefore, gapAfter))
        if case .unaccounted(let rest) = gap.breakdown.reconciliation { try test(rest == 2 * decimalGB && gap.breakdown.reconciliationText!.hasPrefix("Some capacity change remains unaccounted for"), "material mismatch reported as unaccounted") } else { try test(false, "material mismatch reported as unaccounted") }
        let single = CauseAnalyzer.analyze(storageEvent(mixedBefore, reading(2, 0, free: 49 * decimalGB, [volume("d", "Data", 101 * decimalGB), volume("v", "VM", 2 * decimalGB), volume("u", "Update", decimalGB)])))
        try test(single.causes.count == 1, "never forces three candidates when one is supported")
        let recovery = CauseAnalyzer.analyze(storageEvent(mixedBefore, reading(2, 0, free: 51 * decimalGB, [volume("d", "Data", 99 * decimalGB), volume("v", "VM", 2 * decimalGB), volume("u", "Update", decimalGB)])))
        try test(recovery.causes.first?.title == "Data volume reduction" && recovery.breakdown.reconciliationText?.contains("recovery") == true, "recovery events rank released allocation")
        // Missing historical measurements never acquire causes.
        let first = CauseAnalyzer.analyze(storageEvent(nil, mixedAfter))
        try test(first.causes.isEmpty && first.causesUnavailable?.contains("first reading") == true, "first reading: likely cause unavailable")
        let alertOnly = CauseAnalyzer.analyze(real.events.first { $0.id == "reading:11" }!)
        try test(alertOnly.causes.isEmpty && alertOnly.causesUnavailable != nil, "event without an earlier reading in history: cause unavailable")
        let noVolumes = CauseAnalyzer.analyze(storageEvent(reading(1, -30, free: 50 * decimalGB, []), reading(2, 0, free: 48 * decimalGB, [])))
        try test(noVolumes.causes.isEmpty && noVolumes.causesUnavailable == "Insufficient diagnostic evidence." && !noVolumes.breakdown.reconciliation.accounted, "no recorded volumes: insufficient evidence, no reconciliation")
        let orphan = snapshot.events.first { $0.id == "alert:3" }!
        try test(CauseAnalyzer.analyze(orphan).causes.isEmpty, "alert-only record without readings gets no fabricated causes")
        // The plain summary never says more than the measurements.
        let vmEvent = storageEvent(reading(1, -30, free: 50 * decimalGB, base), reading(2, 0, free: 47 * decimalGB, [volume("d", "Data", 100 * decimalGB), volume("v", "VM", 5 * decimalGB), volume("u", "Update", decimalGB)]))
        let vmPlain = EventPlainSummary.make(vmEvent, CauseAnalyzer.analyze(vmEvent))
        try test(vmPlain.whatHappened.hasPrefix("Your Mac lost 3.00 GB of physical free storage between"), "plain summary: states the measured physical loss with its interval")
        try test(vmPlain.explanation?.contains("It holds swap: memory moved onto disk") == true && vmPlain.explanation?.contains("not recorded at both ends") == true, "plain summary: distinguishes VM volume allocation from swap usage")
        try test(vmPlain.certainty == .measured && vmPlain.certaintyText.contains("Which app caused it was not recorded"), "plain summary: an exactly reconciled volume change is measured, and the app stays unknown")
        try test(vmPlain.actions.contains { $0.contains("Quitting apps") }, "plain summary: virtual memory growth offers the memory action")
        let gapPlain = EventPlainSummary.make(storageEvent(mixedBefore, gapAfter), gap)
        try test(gapPlain.certainty == .partlyMeasured && gapPlain.certaintyText.contains("2.00 GB of the difference is not explained"), "plain summary: an unaccounted remainder is stated as partly measured")
        let unknownPlain = EventPlainSummary.make(storageEvent(reading(1, -30, free: 50 * decimalGB, []), reading(2, 0, free: 48 * decimalGB, [])), noVolumes)
        try test(unknownPlain.certainty == .unknown && unknownPlain.explanation == nil && unknownPlain.certaintyText.hasPrefix("Storage Monitor doesn't know why."), "plain summary: no evidence says the cause is unknown and offers no explanation")
        let firstPlain = EventPlainSummary.make(storageEvent(nil, mixedAfter), first)
        try test(firstPlain.certainty == .unknown && firstPlain.whatHappened == first.headline, "plain summary: a first reading claims no change and no cause")
        let dataPlain = EventPlainSummary.make(storageEvent(mixedBefore, mixedAfter), mixed)
        try test(dataPlain.explanation?.contains("Which folders grew was not recorded") == true && dataPlain.actions.contains { $0.contains("Use Storage") }, "plain summary: unattributed Data growth says folders were not recorded and points to Storage")
        // Offsetting volume changes: the explanation names them and the measured net, not only the larger figure.
        let offsetEvent = storageEvent(reading(1, -30, free: 50 * decimalGB, base), reading(2, 0, free: 48 * decimalGB, [volume("d", "Data", 99 * decimalGB), volume("v", "VM", 5 * decimalGB), volume("u", "Update", decimalGB)]))
        let offsetAnalysis = CauseAnalyzer.analyze(offsetEvent), offsetPlain = EventPlainSummary.make(offsetEvent, offsetAnalysis)
        try test(offsetAnalysis.breakdown.reconciliation == .exact && offsetPlain.whatHappened.hasPrefix("Your Mac lost 2.00 GB")
                 && offsetPlain.explanation?.contains("virtual memory volume allocated 3.00 GB more disk space") == true
                 && offsetPlain.explanation?.hasSuffix("At the same time, the Data volume freed 1.00 GB, so the net loss was 2.00 GB.") == true,
                 "plain summary: a larger growth offset by a reduction names the offset and the measured net loss")
        try test(offsetPlain.certainty == .measured, "plain summary: offsetting volume changes that reconcile remain measured, not more certain about the cause")
        try test(dataPlain.explanation?.contains("At the same time, virtual memory freed 1.00 GB, so the net loss was 2.00 GB.") == true,
                 "plain summary: Data growth offset by virtual memory shrinking states both and the net")
        let offsetGain = storageEvent(reading(1, -30, free: 50 * decimalGB, base), reading(2, 0, free: 52 * decimalGB, [volume("d", "Data", 97 * decimalGB), volume("v", "VM", 3 * decimalGB), volume("u", "Update", decimalGB)]))
        let gainPlain = EventPlainSummary.make(offsetGain, CauseAnalyzer.analyze(offsetGain))
        try test(gainPlain.explanation?.hasSuffix("At the same time, virtual memory used 1.00 GB, so the net gain was 2.00 GB.") == true,
                 "plain summary: a recovery offset by growth names the growth and the net gain")
        try test(vmPlain.explanation?.contains("At the same time") == false, "plain summary: no offset sentence when nothing moved the other way")
        let tinyOffset = storageEvent(reading(1, -30, free: 50 * decimalGB, base), reading(2, 0, free: 47 * decimalGB - 999_000, [volume("d", "Data", 100 * decimalGB - 1_000), volume("v", "VM", 5 * decimalGB + 1_000_000 - 1_000), volume("u", "Update", decimalGB)]))
        let tinyPlain = EventPlainSummary.make(tinyOffset, CauseAnalyzer.analyze(tinyOffset))
        try test(CauseAnalyzer.analyze(tinyOffset).breakdown.offsettingVolumes.count == 1 && tinyPlain.explanation?.contains("At the same time") == false,
                 "plain summary: a negligible offset (1 KB beside a 3 GB loss) stays in the breakdown, not the explanation")
        func at(_ id: String, _ minutes: Double, _ delta: Int64) -> StorageEvent {
            StorageEvent(id: id, timestamp: anchor.addingTimeInterval(minutes * 60), category: "Storage loss", delta: delta, previousFree: nil, currentFree: nil, previousTime: nil, severity: .normal, measurement: nil, previousMeasurement: nil, alerts: [], diagnostics: [], comparisons: [], source: "test", searchText: "")
        }
        let timeline = [at("small-new", 0, -2_000_000), at("big-recent", -60, -3 * decimalGB), at("big-old", -3_000, -9 * decimalGB)]
        try test(EventPlainSummary.latestNotable(timeline)?.id == "big-recent", "latest change: the most recent change of 1 GB or more within a day")
        try test(EventPlainSummary.latestNotable([at("small-new", 0, -2_000_000), at("big-old", -3_000, -9 * decimalGB)])?.id == "small-new", "latest change: falls back to the newest change when nothing large is recent")
        try test(EventPlainSummary.latestNotable([]) == nil, "latest change: none without recorded changes")
        // Same-interval swap evidence supports VM growth as its likely mechanism.
        func metric(_ id: String, _ bytes: Int64, _ minute: Double, complete: Bool = true, kind: String = "Swap allocated", source: EvidenceSource = .swap, label: String = "Swap allocated") -> DiagnosticMetric {
            DiagnosticMetric(id: id, label: label, path: id, bytes: bytes, kind: kind, complete: complete, qualifier: "", source: source, observedAt: anchor.addingTimeInterval(minute * 60))
        }
        let vmBefore = reading(1, -30, free: 50 * decimalGB, base), vmAfter = reading(2, 0, free: 49 * decimalGB, [volume("d", "Data", 100 * decimalGB), volume("v", "VM", 3 * decimalGB), volume("u", "Update", decimalGB)])
        let matchedSwap = EvidenceComparison(current: metric("swap:allocated", 3 * 1_073_741_824, 0.5), currentTime: anchor.addingTimeInterval(30), previous: metric("swap:allocated", 2 * 1_073_741_824, -29.5), previousTime: anchor.addingTimeInterval(-29.5 * 60))
        let matched = CauseAnalyzer.analyze(storageEvent(vmBefore, vmAfter, comparisons: [matchedSwap]))
        try test(matched.causes.first?.support.first?.hasPrefix("Likely mechanism: swap allocation changed by +1.07 GB") == true && matched.causes.first?.application == "Unknown", "same-interval swap growth marked as likely mechanism; application still unknown")
        let shifted = EvidenceComparison(current: matchedSwap.current, currentTime: matchedSwap.currentTime, previous: matchedSwap.previous, previousTime: anchor.addingTimeInterval(-99 * 60))
        try test(CauseAnalyzer.analyze(storageEvent(vmBefore, vmAfter, comparisons: [shifted])).causes.first?.support.isEmpty == true, "swap change over a longer interval is not attached as a mechanism")
        // Without volume data, same-interval evidence can only be a possible contributor.
        let dirGrowth = EvidenceComparison(current: metric("dir:/x", 3 * decimalGB, 0.5, kind: "Apparent logical size", source: .temporaryFiles, label: "Chrome signing clone"), currentTime: anchor.addingTimeInterval(30), previous: metric("dir:/x", decimalGB, -29.5, kind: "Apparent logical size", source: .temporaryFiles, label: "Chrome signing clone"), previousTime: anchor.addingTimeInterval(-29.5 * 60))
        let possible = CauseAnalyzer.analyze(storageEvent(reading(1, -30, free: 50 * decimalGB, []), reading(2, 0, free: 48 * decimalGB, []), comparisons: [dirGrowth]))
        try test(possible.causes.count == 1 && possible.causes[0].evidenceClass == .possible && possible.causes[0].application == "Unknown", "directory growth without volume data is only a possible contributor")
        let partialDir = EvidenceComparison(current: metric("dir:/x", 3 * decimalGB, 0.5, complete: false, kind: "Apparent logical size", source: .temporaryFiles), currentTime: anchor, previous: nil, previousTime: nil)
        try test(partialDir.delta == nil && CauseAnalyzer.supportingEvidence(storageEvent(vmBefore, vmAfter, comparisons: [partialDir]), breakdown: CauseAnalyzer.breakdown(storageEvent(vmBefore, vmAfter))).0.isEmpty, "partial directory measurement produces no delta and no evidence row")

        // Schema 2 snapshots (new collector output) load beside legacy ones.
        let structuredJSON: [String: Any] = ["schema_version": 2, "physical_container": ["uuid": "A", "free_bytes": 1, "used_bytes": 2], "volumes": [], "commands": [],
            "swap": ["status": "complete", "allocated_bytes": 7_516_192_768, "used_bytes": 6_230_507_520, "observed_at": 100.5],
            "vm": ["status": "complete", "page_size_bytes": 16384, "swapouts": 5],
            "directories": [["source": "temporary_files", "label": "Chrome signing clone", "path": "/x/clone", "status": "complete", "logical_bytes": 1_507_004_285, "allocated_bytes": 1_509_228_544, "observed_at": 101.0, "permission_denied": ["count": 0, "examples": []]],
                            ["source": "caches", "label": "Google cache", "path": "/x/google", "status": "timed_out", "logical_bytes": 5, "observed_at": 102.0, "limit": "Stopped at the 6-second time budget", "permission_denied": ["count": 4, "examples": ["/x/google/a"]]]],
            "collectors": [["source": "apfs", "status": "complete", "detail": "Reused"], ["source": "swap", "status": "complete"], ["source": "directories", "status": "partial"]]]
        let structured = try EvidenceParser.diagnostic(id: 9, timestamp: Date(timeIntervalSince1970: 100), json: String(data: JSONSerialization.data(withJSONObject: structuredJSON), encoding: .utf8)!)
        try test(structured.schemaVersion == 2 && structured.metrics.first { $0.id == "swap:allocated" }?.bytes == 7_516_192_768 && structured.metrics.first { $0.id == "swap:used" }?.exact == true, "schema 2 swap allocation/usage parsed as exact bytes")
        try test(structured.metrics.first { $0.id == "dir:/x/clone" }?.allocatedBytes == 1_509_228_544 && structured.metrics.first { $0.id == "dir:/x/google" }?.complete == false, "schema 2 directories keep logical/allocated sizes and incompleteness")
        try test(structured.collectors.contains { $0.status == .timedOut && $0.permissionDenied == 4 } && !structured.vmCounters.isEmpty, "schema 2 collector status and VM counters parsed")
        let structuredEvent = StorageEvent(id: "s", timestamp: Date(timeIntervalSince1970: 100), category: "Diagnostic snapshot", delta: nil, previousFree: nil, currentFree: nil, previousTime: nil, severity: .information, measurement: nil, previousMeasurement: nil, alerts: [], diagnostics: [structured], comparisons: EventProjector.comparisons(structured, all: [structured]), source: "s", searchText: "")
        let structuredSummary = CauseAnalyzer.collection(structuredEvent)!
        try test(structuredSummary.refusedLocations == 4 && structuredSummary.lines.contains { $0.contains("stopped at a time limit") }, "schema 2 timeouts and refusals summarised")
        try test(!EventProjector.comparisons(structured, all: [structured]).contains { $0.current.id == "dir:/x/google" && $0.delta != nil }, "timed-out schema 2 measurement never yields a growth delta")
        let legacyMetric = metric("du:logical:/x/clone", 1, 0, kind: "Apparent logical size")
        try test(legacyMetric.id != structured.metrics.first { $0.path == "/x/clone" }?.id, "legacy du and schema 2 directory totals are never compared with each other")

        // MARK: Folder attribution (interval_evidence)

        try test(analysis.attribution == ["Responsible folders: not recorded for this event."], "historical event without folder evidence states that explicitly")
        let attributionDB = try create("attribution.sqlite3")
        precondition(sqlite3_exec(attributionDB, "CREATE TABLE interval_evidence (reading_id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, evidence TEXT NOT NULL);", nil, nil, nil) == SQLITE_OK)
        func attributionVolumes(data: Int64, vm: Int64) -> String { encoded([["APFSVolumeUUID": "d", "Name": "Macintosh HD - Data", "CapacityInUse": data, "Roles": ["Data"]], ["APFSVolumeUUID": "v", "Name": "VM", "CapacityInUse": vm, "Roles": ["VM"]]]) }
        let gb = decimalGB
        // Reading 2: Data +2.0 GB, VM +1.0 GB (free −3.0 GB). Reading 3: Data +1.5 GB (free −1.5 GB). Reading 4: Data +1 GB, no folder growth.
        for (id, minutes, free, data, vm) in [(1, 90.0, 40 * gb, 150 * gb, 2 * gb), (2, 60.0, 37 * gb, 152 * gb, 3 * gb), (3, 30.0, 35_500_000_000 as Int64, 153_500_000_000 as Int64, 3 * gb), (4, 1.0, 34_500_000_000 as Int64, 154_500_000_000 as Int64, 3 * gb), (5, 0.5, 33_500_000_000 as Int64, 155_500_000_000 as Int64, 3 * gb)] {
            write(attributionDB, "INSERT INTO readings VALUES(?,?,?,?,?,?)", [String(id), time(minutes), "A", String(free), String(245 * gb - free), attributionVolumes(data: data, vm: vm)])
        }
        func folderChange(_ path: String, _ kind: String, _ before: Int64, _ after: Int64) -> [String: Any] {
            ["root": "~/.codex", "path": path, "child": (path as NSString).lastPathComponent, "kind": kind, "before_allocated": before, "after_allocated": after, "before_logical": before, "after_logical": after - 10_000_000, "before_files": 10, "after_files": 40, "before_measured_at": 1, "after_measured_at": 2]
        }
        func evidence(_ reading: Int, previous: Int, status: String = "partial", changes: [[String: Any]], correlations: [[String: Any]] = [], activity: String = "complete") -> String {
            encoded(["version": 1, "reading_id": reading, "previous_reading_id": previous,
                     "folders": ["status": status, "method": "incremental", "measured": 4, "carried": 300, "pending": 0, "changes": changes, "changes_total": changes.count, "incomparable": [["path": "~/Library/Caches/com.apple.HomeKit", "reason": "Incomplete measurement (partial)"]], "incomparable_total": 1, "roots": [["label": "~/.codex", "path": "~/.codex", "allocated": 13 * gb, "logical": 13 * gb, "children": 76, "complete": true]]],
                     "file_activity": ["status": activity, "events": 1240, "distinct_paths": 800, "groups": [["path": "~/.codex/sessions", "created": 230, "modified": 990, "removed": 12, "renamed": 4, "cloned": 3, "events": 1240]], "samples": ["~/.codex/sessions/2026/10/21/rollout.jsonl [created,modified]"], "gaps": activity == "gap" ? ["File events were dropped by macOS"] : [], "since_event": 100, "until_event": 900, "device_uuid": "U"],
                     "processes": ["status": "complete", "sampled": 340, "correlations": correlations]])
        }
        let grew = folderChange("~/.codex/sessions", "grew", 1_000_000_000, 2_200_000_000)
        let shrank = folderChange("~/.cache/uv", "shrank", 900_000_000, 600_000_000)
        let codex: [String: Any] = ["pid": 3858, "name": "codex", "executable": "~/.local/bin/codex", "folder": "~/.codex/sessions", "open_files": 6, "writable_files": 4, "example": "~/.codex/sessions/2026/10/21/rollout.jsonl", "bytes_written_interval": 1_400_000_000]
        write(attributionDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["2", time(60), evidence(2, previous: 1, changes: [grew, shrank], correlations: [codex])])
        write(attributionDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["3", time(30), evidence(3, previous: 1, changes: [grew])])   // wrong interval
        write(attributionDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["4", time(1), evidence(4, previous: 3, changes: [], activity: "gap")])
        write(attributionDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["5", time(0.5), evidence(5, previous: 4, status: "baseline_only", changes: [])])
        sqlite3_close(attributionDB)
        let attributed = try await HistoryReader(path: folder.appendingPathComponent("attribution.sqlite3").path).load()
        let withFolders = attributed.events.first { $0.id == "reading:2" }!
        let folderAnalysis = CauseAnalyzer.analyze(withFolders)
        try test(withFolders.interval?.changes.count == 2 && CauseAnalyzer.interval(withFolders) != nil, "folder evidence loads and attaches to the reading with the matching interval")
        let dataCause = folderAnalysis.causes.first { $0.title == "Data volume growth" }!
        try test(dataCause.evidenceClass == .confirmed && dataCause.application == "Unknown", "APFS allocation stays the confirmed cause; application stays unknown even with a correlated process")
        try test(dataCause.support.contains { $0.hasPrefix("Measured folder growth: ~/.codex/sessions +1.20 GB allocated") }, "measured folder growth supports the Data cause")
        try test(dataCause.support.contains { $0.hasPrefix("Process correlation: codex (pid 3858) had 4 files open for writing there") && $0.contains("not to the APFS allocation") }, "process correlation shown only with its limits")
        try test(!dataCause.support.contains { $0.contains("~/.cache/uv") } && folderAnalysis.breakdown.volumes.count == 2, "shrinking folders are not offered as causes of growth")
        try test(folderAnalysis.causes.first { $0.title == "Virtual memory growth" }!.support.allSatisfy { !$0.contains("folder") }, "folder evidence is not attached to virtual memory")
        try test(folderAnalysis.attribution.count == 2 && folderAnalysis.attribution[1].hasPrefix("Estimated unattributed remainder: about 0.80 GB") && folderAnalysis.attribution[1].contains("not an APFS reconciliation") && !folderAnalysis.attribution.joined().contains("exactly") && !folderAnalysis.attribution.joined().contains("at least"), "unattributed remainder labelled as an estimate, never an exact reconciliation")
        try test(folderAnalysis.causes.allSatisfy { !$0.title.lowercased().contains("codex") && !$0.application.lowercased().contains("codex") }, "no application blamed in cause titles")
        let sources = folderAnalysis.evidence.map(\.source)
        try test(sources.contains(.folders) && sources.contains(.fileActivity) && sources.contains(.processes), "supporting evidence shows folder growth, changed files and process correlation")
        try test(folderAnalysis.evidence.first { $0.source == .folders }?.reliability.contains("3 cloned files may share storage") == true, "clone activity qualifies folder growth")
        try test(folderAnalysis.evidence.first { $0.source == .fileActivity }?.change.contains("does not identify which process") == true, "FSEvents evidence never claims a writer")
        let wrongInterval = CauseAnalyzer.analyze(attributed.events.first { $0.id == "reading:3" }!)
        try test(wrongInterval.attribution == ["Responsible folders: folder measurements do not cover this exact interval."] && !wrongInterval.evidence.contains { $0.source == .folders }, "folder evidence from a different interval is never used")
        let quietFolders = CauseAnalyzer.analyze(attributed.events.first { $0.id == "reading:4" }!)
        try test(quietFolders.attribution.first?.hasPrefix("Unattributed: no comparable monitored folder changed by 1 MB or more (1 folder could not be compared; file-change history was incomplete") == true, "Data growth with no folder growth is explicitly unattributed")
        try test(quietFolders.collection?.lines.contains("File-change history has a gap, so changed paths may be incomplete.") == true, "file-event gap reported")
        let baselineOnly = CauseAnalyzer.analyze(attributed.events.first { $0.id == "reading:5" }!)
        try test(baselineOnly.attribution.first?.contains("tracking started") == true && !baselineOnly.evidence.contains { $0.source == .folders }, "baseline-only interval shows no folder growth")
        // Safeguard: across every event, a correlated process never becomes the responsible application.
        for event in attributed.events + real.events + snapshot.events {
            let a = CauseAnalyzer.analyze(event)
            try test(a.causes.allSatisfy { $0.application == "Unknown" }, "\(event.id): causes keep application Unknown")
            let supportText = a.causes.flatMap(\.support).filter { $0.contains("pid") }
            try test(supportText.allSatisfy { $0.hasPrefix("Process correlation:") && $0.contains("not to the APFS allocation") }, "\(event.id): process mentions are correlation with their limit")
            try test(a.evidence.filter { $0.source == .processes }.allSatisfy { $0.reliability.hasPrefix("Process correlation, not proof") }, "\(event.id): process evidence rows carry the disclaimer")
            try test(!(EventPanelText.details(event).lowercased().contains("confirmed process") || EventPanelText.details(event).lowercased().contains("caused by")), "\(event.id): no confirmed-process or caused-by wording")
        }
        let baselineSummary = CauseAnalyzer.collection(attributed.events.first { $0.id == "reading:5" }!)
        try test(baselineSummary?.incomplete == 0 && baselineSummary?.headline == "Folder baseline started at this reading" && baselineSummary?.lines.contains { $0.contains("could not be compared") } == false, "first baseline is not reported as incomplete measurements")
        let copied = EventPanelText.details(withFolders)
        try test(copied.contains("Estimated unattributed remainder") && copied.contains("Process correlation: codex pid 3858") && copied.contains("allocated 1,000,000,000 bytes → 2,200,000,000 bytes"), "copied details include folder evidence with exact bytes")
        try test(EventPanelText.raw(withFolders).contains("\"previous_reading_id\":1"), "raw output includes the stored folder evidence")

        // MARK: Folder monitoring coverage

        func lifecycleJSON(_ state: String, _ d: Int, _ b: Int, _ p: Int, _ inc: Int, _ un: Int, degraded: String? = nil) -> String {
            var o: [String: Any] = ["state": state, "discovered": d, "baselined": b, "pending": p, "incomplete": inc, "unavailable": un, "comparableNext": b - 5, "updatedAt": 1.0, "initializer": ["status": "running", "measurements": b, "startedAt": 1.0, "reconciliations": 0]]
            if let degraded { o["degradedReason"] = degraded }
            return encoded(o)
        }
        let initializing = FolderMonitoringStatus.parse(lifecycleJSON("initializing", 348, 242, 106, 0, 0))!
        try test(initializing.summary == "Initializing · 242 of 348 folders baselined" && initializing.title == "Initializing", "coverage while initializing: 242 of 348 folders baselined")
        try test(FolderMonitoringStatus.parse(lifecycleJSON("ready", 348, 348, 0, 0, 0))!.summary == "Active · 348 folders tracked", "coverage when ready: Active · 348 folders tracked")
        try test(FolderMonitoringStatus.parse(lifecycleJSON("partial", 348, 337, 0, 1, 10))!.summary == "Partial · 337 tracked · 10 unavailable · 1 incomplete", "partial coverage names unavailable and incomplete separately")
        try test(FolderMonitoringStatus.parse(lifecycleJSON("degraded", 348, 300, 48, 0, 0, degraded: "gap"))!.summary.hasPrefix("Degraded"), "degraded coverage stated")
        let allSummaries = ["initializing", "ready", "partial", "degraded", "not_initialized"].map { FolderMonitoringStatus.parse(lifecycleJSON($0, 348, 300, 48, 0, 0))! }
        try test(allSummaries.allSatisfy { !$0.summary.contains("%") && !$0.detail.contains("%") }, "no percentage combines coverage with comparability")
        try test(initializing.detail.contains("Discovered 348 · baselined 242 · pending 106 · incomplete 0 · unavailable 0") && initializing.detail.contains("Comparable for the next interval: 237") && initializing.detail.contains("Each event shows which folders were comparable for its own interval"), "detail separates discovered, baselined, pending, incomplete, unavailable and next-interval comparability")
        let coverageDB = try create("coverage.sqlite3")
        write(coverageDB, "INSERT INTO readings VALUES(?,?,?,?,?,?)", ["1", time(1), "A", String(30 * decimalGB), String(215 * decimalGB), "[]"])
        write(coverageDB, "INSERT INTO state VALUES(?,?)", ["attribution_lifecycle", lifecycleJSON("partial", 346, 336, 0, 1, 9)])
        sqlite3_close(coverageDB)
        let coverageSnapshot = try await HistoryReader(path: folder.appendingPathComponent("coverage.sqlite3").path).load()
        try test(coverageSnapshot.folderMonitoring?.summary == "Partial · 336 tracked · 9 unavailable · 1 incomplete", "coverage read from the monitor database")
        try test(snapshot.folderMonitoring == nil && real.folderMonitoring == nil, "databases without coverage data load unchanged (no status shown)")
        // Per-interval: first measurements are reported as such, not as incomplete or not comparable.
        let firstJSON = encoded(["version": 1, "reading_id": 2, "previous_reading_id": 1, "folders": ["status": "partial", "method": "incremental", "measured": 3, "carried": 300, "pending": 0, "first_measurements": 213, "deferred": 9, "changes": [], "changes_total": 0, "incomparable": [], "incomparable_total": 0, "roots": []], "file_activity": ["status": "complete", "events": 0, "groups": []], "processes": ["status": "not_needed", "correlations": []]])
        let firstInterval = IntervalEvidence.parse(readingId: 2, json: firstJSON)!
        try test(firstInterval.firstMeasurements == 213 && firstInterval.deferred == 9, "interval evidence keeps first measurements and deferred folders separate")
        let firstEvent = StorageEvent(id: "reading:2", timestamp: anchor, category: "Storage loss", delta: -1, previousFree: 2, currentFree: 1, previousTime: anchor, severity: .warning,
                                      measurement: Measurement(id: 2, timestamp: anchor, container: "A", free: 1, used: 1, volumes: []), previousMeasurement: Measurement(id: 1, timestamp: anchor, container: "A", free: 2, used: 0, volumes: []),
                                      alerts: [], diagnostics: [], comparisons: [], source: "", searchText: "", interval: firstInterval)
        let firstSummary = CauseAnalyzer.collection(firstEvent)
        try test(firstSummary?.lines.contains("213 folders were measured for the first time; they become comparable from the next reading.") == true && firstSummary?.incomplete == 0, "first measurements explained per interval and not counted as incomplete")
        try test(firstSummary?.headline == "All 303 folders comparable for this interval", "interval headline speaks of comparability, not completeness")

        // MARK: Comprehensive filesystem coverage

        // (a) A historical row without a coverage block is predefined-folder scope with the exact legacy text.
        try test(withFolders.interval?.coverageScope == "folders" && withFolders.interval?.hasCoverageBlock == false && withFolders.interval?.isComprehensive == false, "evidence row without coverage parses as scope folders")
        try test(folderAnalysis.attribution.count == 2 && folderAnalysis.attribution[0].hasPrefix("Measured folder growth (file allocated sizes): about 1.20 GB across 1 folder (1 folder could not be compared).") && !folderAnalysis.attribution.joined().contains("Coverage:"), "folder-scope row without coverage block keeps the exact legacy attribution text")
        let compDB = try create("comprehensive.sqlite3")
        precondition(sqlite3_exec(compDB, "CREATE TABLE interval_evidence (reading_id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, evidence TEXT NOT NULL);", nil, nil, nil) == SQLITE_OK)
        for (id, minutes, free, data) in [(1, 90.0, 40 * gb, 150 * gb), (2, 60.0, 38 * gb, 152 * gb), (3, 30.0, 37 * gb, 153 * gb), (4, 20.0, 35 * gb, 155 * gb), (5, 10.0, 34 * gb, 156 * gb), (6, 1.0, 33 * gb, 157 * gb), (7, 0.5, 32 * gb, 158 * gb)] {
            write(compDB, "INSERT INTO readings VALUES(?,?,?,?,?,?)", [String(id), time(minutes), "A", String(free), String(245 * gb - free), attributionVolumes(data: data, vm: 2 * gb)])
        }
        func compEvidence(_ reading: Int, previous: Int, status: String = "complete", level: String = "comprehensive", changes: [[String: Any]] = [], moves: [[String: Any]] = [], concentration: [String: Any]? = nil, incomparable: Int = 0, inaccessibleActivity: Int = 0, openDeleted: [String: Any]? = nil, activity: String = "complete") -> String {
            var folders: [String: Any] = ["scope": "comprehensive", "status": status, "method": "incremental", "measured": 40, "carried": 11000, "pending": 0, "changes": changes, "changes_total": changes.count, "incomparable": [], "incomparable_total": incomparable, "roots": [], "splits": 0, "moves": moves]
            if let concentration { folders["concentration"] = concentration }
            var processes: [String: Any] = ["status": "not_needed", "sampled": 0, "correlations": []]
            if let openDeleted { processes["open_deleted"] = openDeleted }
            let coverage: [String: Any] = ["scope": "comprehensive", "level": level, "region": "/System/Volumes/Data", "units": 11718, "monitored": 11500, "baselined": 11600, "inaccessible": 3, "excluded": 1, "pending": 0, "deferred": 0, "full_disk_access": "not_granted", "comprehensive_since": 1.0, "measured_allocated": 120 * gb, "inaccessible_examples": [["path": "/private/var/db", "state": "inaccessible", "reason": "eperm", "detail": "Operation not permitted"]], "inaccessible_activity": ["events": inaccessibleActivity, "regions": inaccessibleActivity > 0 ? [["path": "/private/var/db", "events": inaccessibleActivity, "reason": "eperm"]] : []], "interpretation": "fixture"]
            return encoded(["version": 2, "reading_id": reading, "previous_reading_id": previous, "coverage": coverage, "folders": folders,
                            "file_activity": ["status": activity, "events": 10, "distinct_paths": 8, "groups": [], "samples": [], "gaps": []], "processes": processes])
        }
        let growthChange = folderChange("~/Dev/app/build", "grew", 1_000_000_000, 2_500_000_000)
        let smallGrowth = folderChange("~/Dev/app/cache", "grew", 0, 300_000_000)
        let concentration: [String: Any] = ["growth": ["path": "~/Dev/app", "allocated": 1_600_000_000, "total": 1_800_000_000, "share": 0.89], "reduction": NSNull()]
        let openDeleted: [String: Any] = ["status": "complete", "files": 2, "allocated_bytes": 5_000_000, "holders": [["pid": 11, "name": "Xcode", "files": 1, "allocated_bytes": 3_000_000], ["pid": 12, "name": "mds", "files": 1, "allocated_bytes": 2_000_000]], "note": "fixture"]
        write(compDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["2", time(60), compEvidence(2, previous: 1, changes: [growthChange, smallGrowth], concentration: concentration, incomparable: 2, inaccessibleActivity: 7, openDeleted: openDeleted)])
        write(compDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["3", time(30), compEvidence(3, previous: 2)])
        var movedDir = folderChange("~/Dev/app/renamed", "moved", 900_000_000, 1_800_000_000); movedDir["moved_from"] = "~/Dev/app/old"
        let movedIn = folderChange("~/Dev/other", "moved_in", 0, 700_000_000)
        let movedOut = folderChange("~/Dev/app/old", "moved_out", 700_000_000, 0)
        write(compDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["4", time(20), compEvidence(4, previous: 3, changes: [folderChange("~/Dev/grow", "grew", 0, 1_000_000_000), movedDir, movedIn, movedOut], moves: [["from": "~/Dev/app/old", "to": "~/Dev/app/renamed", "allocated": 900_000_000], ["from": "a", "to": "b", "allocated": 1], ["from": "c", "to": "d", "allocated": 1]])])
        write(compDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["5", time(10), compEvidence(5, previous: 4, status: "busy", level: "unavailable")])
        write(compDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["6", time(1), compEvidence(6, previous: 5, status: "baseline_only", level: "baseline_only")])
        write(compDB, "INSERT INTO interval_evidence VALUES(?,?,?)", ["7", time(0.5), compEvidence(7, previous: 6, status: "partial", level: "partial", incomparable: 4, activity: "gap")])
        func coverageLifecycle(_ state: String, units: Int = 11718, baselined: Int = 4210, pending: Int = 0, inaccessible: Int = 0, reconcile: Int = 0) -> String {
            encoded(["version": 1, "state": state, "region": "/System/Volumes/Data", "units": units, "baselined": baselined, "discovered": 0, "pending": pending, "deferred": 0, "inaccessible": inaccessible, "excluded": 1, "stale": 0, "reconcile": reconcile, "splitPending": 0, "monitored": 11500, "measuredAllocated": 120 * gb, "fullDiskAccess": "not_granted", "establishedAt": 1.0, "comprehensiveSince": 2.0, "lastReconciledAt": 3.0, "lastContinuousAt": 4.0,
                     "notes": [["path": "/private/var/db", "state": "inaccessible", "reason": "eperm", "detail": "Operation not permitted"]], "initializer": ["status": "running", "measurements": 4210]])
        }
        write(compDB, "INSERT INTO state VALUES(?,?)", ["coverage_lifecycle", coverageLifecycle("partial", inaccessible: 3, reconcile: 12)])
        sqlite3_close(compDB)
        let comp = try await HistoryReader(path: folder.appendingPathComponent("comprehensive.sqlite3").path).load()
        func compAnalysis(_ id: Int) -> EventAnalysis { CauseAnalyzer.analyze(comp.events.first { $0.id == "reading:\(id)" }!) }
        let compParsed = comp.events.first { $0.id == "reading:2" }!.interval!
        try test(compParsed.isComprehensive && compParsed.coverageLevel == "comprehensive" && compParsed.inaccessibleCount == 3 && compParsed.fullDiskAccess == "not_granted" && compParsed.inaccessibleActivityEvents == 7 && compParsed.inaccessibleActivityPath == "/private/var/db" && compParsed.openDeletedFiles == 2 && compParsed.openDeletedHolders == ["Xcode", "mds"] && compParsed.growthConcentration?.path == "~/Dev/app" && compParsed.reductionConcentration == nil, "comprehensive coverage block parses (scope, level, FDA, inaccessible activity, concentration, open-deleted)")
        // (b) concentration sentence and coverage line.
        let concentrated = compAnalysis(2).attribution
        try test(concentrated.first?.hasPrefix("Measured growth (file allocated sizes): about 1.80 GB across 2 areas.") == true && concentrated.contains { $0.hasPrefix("Approximately 1.60 GB of measured growth occurred under ~/Dev/app.") }, "comprehensive row with concentration states where the measured growth occurred")
        try test(concentrated.last == "Coverage: all accessible areas of the startup volume were compared for this interval; 3 areas could not be read.", "comprehensive coverage line names unreadable areas")
        try test(compAnalysis(2).causes.first { $0.title == "Data volume growth" }?.support.contains { $0.hasPrefix("Open but deleted files: about 5.00 MB still allocated by 2 files (held by Xcode, mds).") } == true, "open-but-deleted files >= 1 MB shown as a supporting line without blaming an application")
        try test(compAnalysis(2).collection?.lines.contains("7 file events occurred in areas that could not be measured (for example /private/var/db).") == true, "file events in unmeasurable areas are reported")
        // (c) zero changes with Data growth.
        let unexplained = compAnalysis(3).attribution
        try test(unexplained.first == "Storage decreased by 1.00 GB, but the available filesystem evidence does not explain the change." && unexplained.last?.hasPrefix("Coverage: all accessible areas") == true, "comprehensive row with no changes says the evidence does not explain the change")
        // (d) moves are not growth or reduction.
        let movedEvent = comp.events.first { $0.id == "reading:4" }!
        try test(CauseAnalyzer.drivingFolders(movedEvent).map(\.path) == ["~/Dev/grow"] && movedEvent.interval!.changes.filter(\.isMove).count == 3 && movedEvent.interval!.changes.filter(\.isMove).allSatisfy { !$0.isGrowth }, "moved, moved_in and moved_out are excluded from driving areas")
        let movedLines = compAnalysis(4).attribution
        try test(movedLines.contains("3 moves within the volume were not counted as growth or reduction.") && movedLines.first?.contains("across 1 area.") == true, "moves are reported and not counted in measured growth")
        // (f) busy, baseline_only and partial rows.
        try test(compAnalysis(5).attribution == ["Filesystem coverage was being updated; evidence skipped for this reading."] && compAnalysis(5).collection?.lines.contains("Filesystem coverage was being updated; evidence skipped for this reading.") == true, "busy comprehensive row skips evidence with an explanation")
        try test(compAnalysis(6).attribution == ["Comprehensive coverage began at this reading; changes can be compared from the next one."] && compAnalysis(6).collection?.lines.contains("Comprehensive coverage began at this reading; changes can be compared from the next one.") == true, "baseline_only comprehensive row says comparison starts next reading")
        try test(compAnalysis(7).attribution.last == "Coverage: partial — 4 areas could not be compared; file history had a gap.", "partial comprehensive row states what could not be compared")
        let folderCoverageRow = IntervalEvidence.parse(readingId: 9, json: encoded(["version": 2, "previous_reading_id": 8, "coverage": ["scope": "folders", "reason": "Comprehensive coverage is still being established (4210 of 11718 areas measured)."], "folders": ["status": "complete", "changes": [], "incomparable": []]]))!
        try test(folderCoverageRow.coverageScope == "folders" && folderCoverageRow.hasCoverageBlock && folderCoverageRow.coverageReason?.contains("4210 of 11718") == true, "folder-scope coverage block keeps its reason")
        // (e) coverage_lifecycle.
        let ready = FilesystemCoverageStatus.parse(coverageLifecycle("ready"))!
        try test(FilesystemCoverageStatus.parse(coverageLifecycle("initializing"))!.summary == "Initializing · 4,210 of 11,718 areas measured", "coverage lifecycle: initializing summary")
        try test(ready.summary == "Comprehensive · 11,500 areas monitored", "coverage lifecycle: ready summary")
        try test(FilesystemCoverageStatus.parse(coverageLifecycle("partial", inaccessible: 3))!.summary == "Comprehensive except 3 inaccessible areas" && FilesystemCoverageStatus.parse(coverageLifecycle("partial", pending: 5, inaccessible: 3, reconcile: 7))!.summary == "Comprehensive except 3 inaccessible areas · 12 pending", "coverage lifecycle: partial summary with and without pending work")
        try test(FilesystemCoverageStatus.parse(coverageLifecycle("degraded", pending: 5, reconcile: 7))!.summary == "Reconciling after a file-history gap · 12 areas pending", "coverage lifecycle: degraded summary")
        try test(ready.detail.contains("not APFS physical allocation") && ready.detail.contains("Full Disk Access: not granted") && ready.detail.contains("System Settings → Privacy & Security → Full Disk Access") && ready.detail.contains("/private/var/db — Operation not permitted"), "coverage detail explains measured sizes, Full Disk Access guidance and inaccessible regions")
        try test(comp.filesystemCoverage?.summary == "Comprehensive except 3 inaccessible areas · 12 pending" && snapshot.filesystemCoverage == nil, "coverage_lifecycle read from the database; absent in older databases")

        // MARK: Live capacity and appearance

        final class FakeSource: @unchecked Sendable {
            let lock = NSLock(); var calls = 0; var fail = false; var delay = 0.0; var free: Int64 = 20 * decimalGB
            func read() throws -> LiveCapacityReading {
                lock.lock(); calls += 1; let fail = self.fail, delay = self.delay, free = self.free; lock.unlock()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                if fail { throw LiveCapacityError.unavailable("simulated") }
                return LiveCapacityReading(timestamp: Date(), free: free, total: 245 * decimalGB, dataVolumeUUID: "volume-data")
            }
        }
        let fake = FakeSource()
        let monitor = await MainActor.run { LiveCapacityMonitor(source: { try fake.read() }) }
        let initialFreshness = await MainActor.run { monitor.state.freshness(at: Date()) }, initialDue = await MainActor.run { monitor.isDue(at: Date()) }
        try test(initialFreshness == .unavailable && initialDue, "before the first live reading: unavailable and due")
        await monitor.refresh()
        let firstLive = await MainActor.run { monitor.state }
        try test(firstLive.reading?.free == 20 * decimalGB && firstLive.lastError == nil && firstLive.freshness(at: Date()) == .live, "live refresh stores the reading in memory and marks it live")
        let dueAt30 = await MainActor.run { monitor.isDue(at: Date().addingTimeInterval(30)) }, dueAt61 = await MainActor.run { monitor.isDue(at: Date().addingTimeInterval(61)) }
        try test(!dueAt30 && dueAt61, "visible refresh cadence is 60 s (conservative)")
        try test(firstLive.freshness(at: firstLive.reading!.timestamp.addingTimeInterval(179)) == .live && firstLive.freshness(at: firstLive.reading!.timestamp.addingTimeInterval(181)) == .stale, "live reading becomes stale after 3 minutes")
        fake.fail = true
        await monitor.refresh()
        let failed = await MainActor.run { monitor.state }
        try test(failed.reading == firstLive.reading && failed.lastError != nil && failed.freshness(at: Date()) == .stale, "failed refresh keeps the last good reading and marks it stale")
        fake.fail = false; fake.delay = 0.5
        async let firstCall = monitor.refresh()
        async let secondCall = monitor.refresh()
        let outcomes = await [firstCall, secondCall]
        let skippedCount = await MainActor.run { monitor.skipped }, recoveredFreshness = await MainActor.run { monitor.state.freshness(at: Date()) }
        try test(outcomes.filter { $0 }.count == 1 && fake.calls == 3 && skippedCount == 1, "overlapping refresh requests are dropped, not queued")
        try test(recoveredFreshness == .live, "successful refresh clears the stale state")

        // Observation comparison: same container only, never alters recorded values.
        let recordedLatest = snapshot.latest!
        let liveSame = LiveCapacityReading(timestamp: Date(), free: recordedLatest.free - 500_000_000, total: 245 * decimalGB, dataVolumeUUID: "volume-data")
        let comparison = ObservationComparison.make(live: liveSame, recorded: recordedLatest)
        try test(comparison?.difference == -500_000_000 && comparison?.recorded == recordedLatest, "live-versus-recorded difference is an observation comparison")
        try test(ObservationComparison.make(live: LiveCapacityReading(timestamp: Date(), free: 1, total: 2, dataVolumeUUID: "other-volume"), recorded: recordedLatest) == nil && ObservationComparison.make(live: LiveCapacityReading(timestamp: Date(), free: 1, total: 2, dataVolumeUUID: nil), recorded: recordedLatest) == nil, "different or unknown container is never compared")

        // Historical isolation: live readings never change history, events or the chart data.
        let historyBefore = snapshot.events.map { [$0.id, String($0.delta ?? 0), String($0.currentFree ?? 0), $0.category] }
        let chartBefore = snapshot.measurements.map { "\($0.id):\($0.free)" }
        for _ in 0..<3 { await monitor.refresh() }
        let reloaded = try await HistoryReader(path: populated.path).load()
        try test(reloaded.events.map { [$0.id, String($0.delta ?? 0), String($0.currentFree ?? 0), $0.category] } == historyBefore && reloaded.measurements.map { "\($0.id):\($0.free)" } == chartBefore, "events and chart points are unchanged by live refreshes")
        try test(reloaded.events.count == snapshot.events.count && !reloaded.events.contains { $0.id.hasPrefix("live") }, "live readings never become events")

        // Real capacity probe, isolated state: production monitoring can write its own folder concurrently,
        // so fingerprinting that folder cannot establish whether this probe writes. Use controlled history,
        // log and lock fixtures and require them to remain unchanged; never open production data here.
        let dataDir = folder
        let logSentinel = dataDir.appendingPathComponent("live-probe-monitor.log")
        let lockSentinel = dataDir.appendingPathComponent("live-probe-monitor.lock")
        let sentinel = Data("isolated read-only probe fixture\n".utf8)
        try sentinel.write(to: logSentinel); try sentinel.write(to: lockSentinel)
        func fingerprint() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? []).sorted().map { name in let a = try? FileManager.default.attributesOfItem(atPath: dataDir.appendingPathComponent(name).path); return "\(name):\((a?[.size] as? NSNumber)?.intValue ?? -1):\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" } }
        let filesBefore = fingerprint(), fixtureBefore = try Data(contentsOf: populated)
        var probes = [LiveCapacityReading]()
        for _ in 0..<3 { probes.append(try LiveCapacityProbe.read()) }
        try test(probes.allSatisfy { $0.total > 0 && $0.free > 0 && $0.free < $0.total && $0.dataVolumeUUID != nil }, "real live probe reads container free/total and the Data volume UUID")
        let fixtureAfter = try Data(contentsOf: populated)
        let unchanged = fingerprint() == filesBefore
        let sentinelsUnchanged = try Data(contentsOf: logSentinel) == sentinel && Data(contentsOf: lockSentinel) == sentinel
        try test(unchanged && fixtureAfter == fixtureBefore && sentinelsUnchanged,
                 "real live probes leave isolated history, log and lock fixtures unchanged (\(filesBefore.count) files; production monitoring data not opened)")
        if let production = ProcessInfo.processInfo.environment["STORAGE_MONITOR_PRODUCTION_COPY"], let latest = try? await HistoryReader(path: production).load().latest {
            try test(ObservationComparison.make(live: probes[0], recorded: latest) != nil, "real live reading matches the recorded container by Data volume UUID")
        }

        // Appearance preference.
        let suite = "local.macbook.storage-monitor.viewer.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(AppAppearance.load(defaults) == .system, "appearance defaults to System")
        AppAppearance.dark.save(defaults)
        try test(AppAppearance.load(UserDefaults(suiteName: suite)!) == .dark, "appearance choice persists")
        try test(AppAppearance.load(defaults, override: "light") == .light && AppAppearance.load(defaults) == .dark, "launch override applies without being persisted")
        defaults.set("sepia", forKey: AppAppearance.preferenceKey)
        try test(AppAppearance.load(defaults) == .system, "unknown stored appearance falls back to System")
        try test(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"], "appearance choices are System, Light, Dark")

        // Production history, read through a copy if one is supplied.
        if let production = ProcessInfo.processInfo.environment["STORAGE_MONITOR_PRODUCTION_COPY"] {
            let history = try await HistoryReader(path: production).load()
            try test(history.measurements.count >= 13 && history.events.contains { $0.id == "reading:12" && $0.delta == -2_178_781_184 }, "existing production history loads intact (\(history.measurements.count) readings, \(history.events.count) events)")
            try test(history.events.allSatisfy { _ = CauseAnalyzer.analyze($0); return true }, "every production event analyses without error")
        }
        // A refresh requested while a load is running must still reload once that load ends (it was dropped before).
        var gate = InventoryReloadGate()
        try test(gate.request(loading: false), "refresh while idle reloads at once")
        var midLoad = InventoryReloadGate()
        try test(!midLoad.request(loading: true), "refresh during a load does not start a second load")
        try test(midLoad.finish(), "a refresh requested during a load is replayed when it ends")
        try test(!midLoad.finish(), "a replayed refresh is consumed exactly once")
        // Confirmations name the folder that was asked for, and the index root reads as Startup Data.
        try test(inventoryFolderName(path: "/Users/someone/Projects/Atlas", rootPath: "/") == "Atlas", "prioritize names the requested folder")
        try test(inventoryFolderName(path: "/", rootPath: "/") == "Startup Data", "the index root reads as Startup Data")
        try livingTreeModelTests { ok, message in try test(ok, message) }
        try livingTreeCameraTests { ok, message in try test(ok, message) }
        try livingTree3DTests { ok, message in try test(ok, message) }
        try livingTreeColorTests { ok, message in try test(ok, message) }
        try structuredExplorerTests { ok, message in try test(ok, message) }
        try structuredExplorerFilteringTests { ok, message in try test(ok, message) }
        try sparseStorageModelTests(folder.deletingLastPathComponent()) { ok, message in try test(ok, message) }
        try cleanupInspectorTests(folder.deletingLastPathComponent().appendingPathComponent("cleanup-fixtures")) { ok, message in try test(ok, message) }
        try cleanupTrashTests(folder.deletingLastPathComponent().appendingPathComponent("cleanup-trash-fixtures")) { ok, message in try test(ok, message) }
        // Trash safety includes the macOS /tmp ↔ /private/tmp alias cases, so its disposable fixtures always live under
        // /private/tmp, wherever the rest of the suite's fixtures are (the default is build/qa-fixtures).
        let trashSafetyRoot = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("storage-monitor-trash-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: trashSafetyRoot, withIntermediateDirectories: true)
        try cleanupTrashSafetyTests(trashSafetyRoot) { ok, message in try test(ok, message) }
        let repository = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "tests/fixtures").standardizedFileURL
            .deletingLastPathComponent().deletingLastPathComponent()
        try correctnessPresentationTests { ok, message in try test(ok, message) }
        try await correctnessCapacityMonitorTests { ok, message in try test(ok, message) }
        try viewerIdentityTests(root: repository) { ok, message in try test(ok, message) }
        try await cleanupReviewQueueTests(folder.deletingLastPathComponent().appendingPathComponent("cleanup-queue-fixtures")) { ok, message in try test(ok, message) }
        print("\(tests) GUI model/read-only tests passed; isolated fixtures: \(folder.path)")
    }
}
