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
        var filters = EventFilters()
        for type in EventTypeFilter.allCases { filters.type = type; try test(!filters.apply(snapshot.events,now:anchor).isEmpty,"type filter \(type.rawValue)") }
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

        // Real probe: read-only, consistent with recorded APFS units, no side effects on monitoring files.
        let dataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacBook Storage Monitor")
        func fingerprint() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? []).sorted().map { name in let a = try? FileManager.default.attributesOfItem(atPath: dataDir.appendingPathComponent(name).path); return "\(name):\((a?[.size] as? NSNumber)?.intValue ?? -1):\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" } }
        let filesBefore = fingerprint(), fixtureBefore = try Data(contentsOf: populated)
        var probes = [LiveCapacityReading]()
        for _ in 0..<3 { probes.append(try LiveCapacityProbe.read()) }
        try test(probes.allSatisfy { $0.total > 0 && $0.free > 0 && $0.free < $0.total && $0.dataVolumeUUID != nil }, "real live probe reads container free/total and the Data volume UUID")
        let fixtureAfter = try Data(contentsOf: populated)
        try test(fingerprint() == filesBefore && fixtureAfter == fixtureBefore, "live probes do not touch the monitor's database, log, or lock (\(filesBefore.count) files unchanged)")
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
        print("\(tests) GUI model/read-only tests passed; isolated fixtures: \(folder.path)")
    }
}
