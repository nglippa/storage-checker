import Foundation
import SQLite3
import Darwin

/// All writes are disposable SQLite/file fixtures. Snapshot probes are injected except the
/// explicit --live read-only mode. No snapshot, Time Machine or production mutation exists.
@main enum APFSSnapshotIntegrationTests {
    static func main() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/storage-snapshot-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", vmID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let snapshotA = "11111111-1111-1111-1111-111111111111", snapshotB = "22222222-2222-2222-2222-222222222222"
        let container = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        var checks = 0
        func test(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            try required(try value(), "FAIL: \(message)"); checks += 1; print("PASS \(message)")
        }
        func plist(_ value: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
        func result(_ data: Data, status: Int32 = 0, timedOut: Bool = false, truncated: Bool = false) -> CommandResult {
            CommandResult(data: data, errors: Data(), status: status, timedOut: timedOut, truncated: truncated)
        }
        let volumeJSON = json([["APFSVolumeUUID": dataID, "Name": "Data", "DeviceIdentifier": "disk99s1", "CapacityInUse": 60 * gb, "Roles": ["Data"]] as [String: Any]])
        let probeReading = Reading(timestamp: Date().timeIntervalSince1970, container: container, free: 20 * gb, used: 80 * gb, volumes: volumeJSON)
        let info = try plist(["VolumeUUID": dataID, "FilesystemType": "apfs", "Locked": false, "DeviceIdentifier": "disk99s1"])
        let listed = try plist(["Snapshots": [["SnapshotUUID": snapshotA, "SnapshotName": "fixture", "SnapshotXID": 10, "Purgeable": true]]])
        var commands = [[String]]()
        let good = SnapshotObserver.capture(probeReading, includeVM: false, runner: { executable, args, timeout, cap in
            try required(executable == "/usr/sbin/diskutil" && timeout <= 2 && cap == SnapshotObserver.outputLimit, "bounded fixed executable")
            commands.append(args); return result(args.first == "info" ? info : listed)
        }, capacityPaths: [:])
        try test(good.inventories.first?.snapshots.first?.uuid == snapshotA, "successful inventory records snapshot UUID with verified volume")
        try test(commands == [["info", "-plist", "disk99s1"], ["apfs", "listSnapshots", "-plist", "disk99s1"], ["info", "-plist", "disk99s1"]], "collector has only read-only info and listSnapshots command paths")
        try test(good.swapAllocatedBytes == nil && good.vmCounters == nil, "external scope never receives startup swap/VM allocation")
        try test(good.inventories.first?.snapshots.first?.privateBytes == nil && good.inventories.first?.snapshots.first?.createdAt == nil, "unsupported snapshot bytes and creation timestamps stay unknown")
        try test(StorageObservation.decode(try good.encoded()) != nil, "collected observation round trips with boot/uptime and bounded metadata")
        for failure in [result(listed, status: 1), result(listed, timedOut: true), result(listed, truncated: true), result(try plist(["Error": "Permission denied"]))] {
            let observation = SnapshotObserver.capture(probeReading, includeVM: false, runner: { _, args, _, _ in args.first == "info" ? result(info) : failure }, capacityPaths: [:])
            try test(observation.inventories.first?.status == .unavailable && observation.inventories.first?.snapshots.isEmpty == true, "failed, timed-out, capped or permission-denied listing is unknown, never an empty complete inventory")
        }
        var infoCalls = 0
        let otherInfo = try plist(["VolumeUUID": vmID, "FilesystemType": "apfs", "Locked": false, "DeviceIdentifier": "disk99s1"])
        let changed = SnapshotObserver.capture(probeReading, includeVM: false, runner: { _, args, _, _ in
            if args.first == "info" { infoCalls += 1; return result(infoCalls == 1 ? info : otherInfo) }; return result(listed)
        }, capacityPaths: [:])
        try test(changed.inventories.first?.status == .unavailable, "device-number reuse during collection discards snapshot identities")
        let skipped = SnapshotObserver.capture(probeReading, includeVM: false, budget: 0, runner: { _, _, _, _ in fatalError("deadline must prevent launch") }, capacityPaths: [:])
        try test(skipped.inventories.first?.status == .skipped, "exhausted observation budget skips without launching a command")
        let unselected = SnapshotObserver.capture(probeReading, enrolled: [vmID], includeVM: false, runner: { _, _, _, _ in fatalError("unselected volume must not be probed") }, capacityPaths: [:])
        try test(unselected.inventories.isEmpty, "external snapshot collection respects explicitly enrolled volume UUIDs")
        let systemJSON = json([["APFSVolumeUUID": dataID, "Name": "System", "DeviceIdentifier": "disk99s1", "Roles": ["System"]] as [String: Any]])
        let systemReading = Reading(timestamp: Date().timeIntervalSince1970, container: container, free: 20 * gb, used: 80 * gb, volumes: systemJSON)
        let systemInfo = try plist(["VolumeUUID": dataID, "FilesystemType": "apfs", "Locked": false, "DeviceIdentifier": "disk99s1", "APFSContainerReference": "disk99", "MountPoint": ""])
        let bootInfo = try plist(["DeviceIdentifier": "disk99s1s1", "APFSSnapshot": true, "APFSContainerReference": "disk99", "APFSSnapshotUUID": snapshotA])
        var listedBoot = false
        let bootInventory = SnapshotObserver.capture(systemReading, runner: { _, args, _, _ in
            if args.first == "info" { return result(args.last == "/" ? bootInfo : systemInfo) }
            listedBoot = args.last == "disk99s1s1"; return result(listed)
        }, capacityPaths: [:])
        try test(listedBoot && bootInventory.inventories.first?.status == .complete, "unmounted sealed System volume uses verified mounted boot snapshot device without mounting anything")

        func observation(_ time: Double, _ ids: [String], swap: Int64, status: SnapshotInventoryStatus = .complete, scope: String = container) -> StorageObservation {
            let records = ids.map { APFSSnapshotRecord(uuid: $0, name: $0 == snapshotA ? "old" : "com.apple.os.update-fixture", xid: $0 == snapshotA ? 10 : 11) }
            return StorageObservation(container: scope, observedAt: time, finishedAt: time + 1,
                inventories: [SnapshotInventory(volumeUUID: dataID, volumeName: "Data", observedAt: time + 0.1, status: status, detail: "fixture", snapshots: records)],
                capacities: [VolumeCapacityObservation(volumeUUID: dataID, path: "/fixture", observedAt: time + 0.2, availableBytes: 20 * gb, importantAvailableBytes: 30 * gb + Int64(time), opportunisticAvailableBytes: nil, detail: "policy estimate fixture")],
                swapAllocatedBytes: swap, swapUsedBytes: swap / 2, vmCounters: ["swapouts": 20], detail: "fixture, no snapshot operations")
        }
        let old = observation(10_000, [snapshotA], swap: 3 * gb), current = observation(11_800, [snapshotB], swap: gb)
        func measurement(_ id: Int64, _ time: Double, free: Int64, vm: Int64) -> Measurement {
            Measurement(id: id, timestamp: Date(timeIntervalSince1970: time), container: container, free: free, used: 100 * gb - free,
                volumes: [VolumeAllocation(id: dataID, name: "Data", bytes: 73 * gb - free - vm, roles: ["Data"]),
                          VolumeAllocation(id: vmID, name: "VM", bytes: vm, roles: ["VM"])])
        }
        let first = measurement(1, 10_000, free: 20 * gb, vm: 3 * gb), second = measurement(2, 11_800, free: 25 * gb, vm: gb)
        let intervalJSON = json(["previous_reading_id": 1, "folders": ["status": "partial", "incomparable": [["path": "/protected", "reason": "permission denied"]]],
            "coverage": ["scope": "comprehensive", "level": "partial", "inaccessible": 1],
            "file_activity": ["status": "complete", "events": 7, "groups": [["path": "/fixture", "created": 2, "removed": 3, "modified": 2, "events": 7]]]] as [String: Any])
        let interval = IntervalEvidence.parse(readingId: 2, json: intervalJSON)!
        func event(_ observations: [Int64: StorageObservation], sessions: Set<Int64> = [], intervals: [Int64: IntervalEvidence] = [:]) -> StorageEvent {
            EventProjector.project(measurements: [first, second], alerts: [], diagnostics: [], intervals: intervals, segmentStarts: sessions, observations: observations).events.last!
        }
        let concurrent = event([1: old, 2: current], intervals: [2: interval])
        let signals = StorageIntelligence.signals(concurrent)
        try test(concurrent.snapshotComparison.changes.count == 2 && concurrent.delta == 5 * gb, "snapshot appearance/disappearance shares the existing capacity event without duplicated rows")
        try test(signals.first { $0.id == "thinning" }?.confidence == .plausible, "capacity recovery near snapshot disappearance is only a plausible explanation")
        try test(signals.first { $0.id == "vm-correlation" }?.confidence == .strongCorrelation, "aligned VM allocation contraction and swap contraction are a strong correlation")
        try test(signals.contains { $0.id == "files" } && signals.contains { $0.id == "snapshots" } && signals.contains { $0.id == "unresolved" }, "concurrent files, snapshots and VM preserve unresolved cause instead of double-counting")
        try test(CauseAnalyzer.breakdown(concurrent).volumeNet == -5 * gb && CauseAnalyzer.breakdown(concurrent).reconciliation.accounted, "shared APFS container change reconciles volume allocation once; snapshots and swap add no extra bytes")
        try test(signals.first { $0.id == "update-snapshot" }?.confidence == .plausible, "update naming is qualified evidence, not proof of an operating-system update")
        try test(EventPanelText.details(concurrent).contains("1 inaccessible") && EventPanelText.raw(concurrent).contains("snapshot"), "event exports preserve partial permission coverage and system evidence")
        try test(event([1: old, 2: current], sessions: [2]).snapshotComparison.changes.isEmpty, "external reconnection session cannot infer snapshot deletion")
        let failed = observation(11_800, [], swap: gb, status: .unavailable)
        try test(event([1: old, 2: failed]).snapshotComparison.changes.isEmpty, "permission failure after successful inventory never claims snapshots disappeared")
        try test(StorageIntelligence.inventoryText(event([1: old, 2: failed]))?.contains("Snapshot count unknown") == true,
                 "unavailable snapshot inventory displays an unknown count instead of zero snapshots")
        let noFiles = event([1: old, 2: current])
        try test(StorageIntelligence.signals(noFiles).contains { $0.id == "thinning" } && StorageIntelligence.signals(noFiles).contains { $0.id == "unresolved" }, "capacity recovery without file events still shows snapshot evidence and uncertainty")
        var reboot = current; reboot.bootSession = UUID().uuidString
        var oldBoot = old; oldBoot.bootSession = UUID().uuidString
        try test(!event([1: oldBoot, 2: reboot]).observationContinuous, "reboot starts a new snapshot/system baseline")
        let growing = measurement(2, 11_800, free: 15 * gb, vm: 5 * gb)
        let growthObservation = observation(11_800, [snapshotA], swap: 5 * gb)
        let growth = EventProjector.project(measurements: [first, growing], alerts: [], diagnostics: [], observations: [1: old, 2: growthObservation]).events.last!
        try test(StorageIntelligence.signals(growth).first { $0.id == "vm-correlation" }?.confidence == .strongCorrelation && growth.delta == -5 * gb, "VM/swap growth is correlated with allocation without equating swap usage to physical bytes")
        let vmPrimaryReading = measurement(2, 11_800, free: 15 * gb, vm: 7 * gb)
        let vmPrimaryEvent = EventProjector.project(measurements: [first, vmPrimaryReading], alerts: [], diagnostics: []).events.last!
        let vmPrimarySummary = EventPlainSummary.make(vmPrimaryEvent, CauseAnalyzer.analyze(vmPrimaryEvent))
        try test(vmPrimarySummary.explanation?.contains("Data volume allocation grew") == true &&
                 vmPrimarySummary.explanation?.contains("files and apps grew") == false,
                 "secondary Data-volume growth is described as allocation rather than measured file growth")
        let unchangedSnapshots = observation(11_800, [snapshotA], swap: 3 * gb)
        let unexplained = event([1: old, 2: unchangedSnapshots])
        try test(!StorageIntelligence.signals(unexplained).contains { $0.id == "thinning" } && StorageIntelligence.signals(unexplained).contains { $0.id == "unresolved" }, "capacity recovery with no file or snapshot changes retains an unknown cause")
        var filter = EventFilters(); filter.time = .custom; filter.start = first.timestamp; filter.end = second.timestamp; filter.type = .snapshots
        try test(filter.matches(concurrent, now: second.timestamp), "snapshot changes are selectable through the existing timeline filter")
        filter.search = "com.apple.os.update"
        try test(filter.matches(concurrent, now: second.timestamp), "snapshot names can be found in the timeline search")
        filter.search = "old"
        try test(filter.matches(concurrent, now: second.timestamp), "disappeared snapshot names remain searchable on the event that observed their absence")
        filter.search = snapshotA
        try test(filter.matches(concurrent, now: second.timestamp), "disappeared snapshot UUIDs remain searchable")
        let capacities = CapacityPresentation(state: LiveCapacityState(reading: LiveCapacityReading(timestamp: second.timestamp, free: 25 * gb, total: 100 * gb, dataVolumeUUID: dataID, availableBytes: 30 * gb, importantAvailableBytes: 35 * gb)), recorded: nil, now: second.timestamp)
        try test(capacities.title == "Free now" && capacities.availabilityText?.contains("30.00") == true && capacities.detail.contains("not exact purgeable"), "physical free, ordinary availability and policy estimates stay distinct")

        let dbPath = directory.appendingPathComponent("history.sqlite3").path
        do {
            let db = try Database(dbPath)
            for (value, observed) in [(first, old), (second, current)] {
                let reading = Reading(timestamp: value.timestamp.timeIntervalSince1970, container: container, free: value.free, used: value.used, volumes: json(value.volumes.map { ["APFSVolumeUUID": $0.id, "Name": $0.name, "CapacityInUse": $0.bytes, "Roles": $0.roles] as [String: Any] }))
                try db.write("INSERT INTO readings(id,timestamp,container,free,used,volumes) VALUES(?,?,?,?,?,?)", [value.id, reading.timestamp, container, reading.free, reading.used, reading.volumes])
                try storeStorageObservation(observed, readingID: value.id, reading: reading, db: db)
            }
            try db.write("INSERT INTO interval_evidence VALUES(?,?,?)", [Int64(2), 11_800.0, intervalJSON])
        }
        let beforeLoad = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        let loaded = try await HistoryReader(path: dbPath).load()
        try test(loaded.events.last?.snapshotComparison.changes.count == 2, "SQLite persistence and read-only viewer projection retain snapshot comparisons")
        try test(try Data(contentsOf: URL(fileURLWithPath: dbPath)) == beforeLoad, "loading new snapshot history leaves SQLite byte-identical")
        do {
            let db = try Database(dbPath)
            try db.write("UPDATE storage_observations SET observation=? WHERE reading_id=2", ["{corrupt"])
        }
        let corrupt = try await HistoryReader(path: dbPath).load()
        try test(corrupt.events.last?.observation == nil && corrupt.measurements.count == 2, "malformed additive evidence does not destroy readable capacity history")
        do {
            let db = try Database(dbPath)
            try db.retain(11_800 + retention + 1)
            try test(try db.rows("SELECT * FROM storage_observations").isEmpty, "observation retention removes orphans with expired readings; it never touches APFS snapshots")
            // Simulate the old on-disk schema and reopen through the additive migration.
            try db.exec("DROP TABLE storage_observations")
            try db.write("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES(?,?,?,?,?)", [30_000.0, container, 10 * gb, 90 * gb, "[]"])
        }
        let legacy = try await HistoryReader(path: dbPath).load()
        try test(legacy.measurements.count == 1 && legacy.events.first?.observation == nil, "legacy history without the new table remains readable")
        do {
            let db = try Database(dbPath)
            try test(try db.rows("SELECT * FROM storage_observations").isEmpty && db.rows("SELECT * FROM readings").count == 1, "additive migration preserves legacy readings and starts with unknown snapshot history")
        }
        do {
            let db = try Database(directory.appendingPathComponent("budget.sqlite3").path)
            let dense = String(repeating: "x", count: 1_000_000)
            for id in Int64(1)...40 {
                try db.write("INSERT INTO readings(id,timestamp,container,free,used,volumes) VALUES(?,?,?,?,?,?)", [id, Double(40_000 + id), container, gb, gb, "[]"])
                try db.write("INSERT INTO storage_observations VALUES(?,?,?)", [id, Double(40_000 + id), dense])
            }
            try db.retain(50_000)
            let bytes = try db.rows("SELECT SUM(length(CAST(observation AS BLOB))) AS bytes FROM storage_observations").first?["bytes"].flatMap(Int64.init) ?? 0
            try test(bytes <= 33_554_432 && bytes > 0 && db.rows("SELECT * FROM readings").count == 40, "snapshot evidence byte budget prunes oldest observations while preserving capacity history")
            let newest = Reading(timestamp: 50_001, container: container, free: gb, used: gb, volumes: "[]")
            try db.write("INSERT INTO readings(id,timestamp,container,free,used,volumes) VALUES(?,?,?,?,?,?)", [Int64(41), newest.timestamp, container, newest.free, newest.used, newest.volumes])
            storeOptionalStorageObservation(observation(50_001, [snapshotA], swap: 0), readingID: 41,
                                            reading: newest, db: db, logDirectory: directory)
            let postInsertBytes = try db.rows("SELECT SUM(length(CAST(observation AS BLOB))) AS bytes FROM storage_observations").first?["bytes"].flatMap(Int64.init) ?? 0
            try test(postInsertBytes <= 33_554_432 && db.rows("SELECT * FROM storage_observations WHERE reading_id=41").count == 1 && !db.transactionActive,
                     "optional evidence transaction enforces byte budget after inserting newest evidence")
        }
        do {
            let db = try Database(directory.appendingPathComponent("startup-rollback.sqlite3").path)
            let startup = Reading(timestamp: 55_000, container: container, free: 20 * gb, used: 80 * gb, volumes: "[]")
            let evaluation = evaluate(startup, nil, [])
            let plan = try AlertPlan(db, startup, evaluation)
            let readingID = try persistStartupReading(startup, plan: plan, db: db)
            try db.write("INSERT INTO alerts(timestamp,severity,reasons,free,delta,notification) VALUES(?,?,?,?,?,?)",
                         [startup.timestamp, evaluation.severity, plan.signature, startup.free, evaluation.delta as Any, "fixture"])
            try db.retain(startup.timestamp)
            try db.exec("CREATE TRIGGER reject_startup_evidence BEFORE INSERT ON storage_observations BEGIN SELECT RAISE(ROLLBACK, 'fixture startup evidence transaction rollback'); END")
            storeOptionalStorageObservation(observation(55_000, [snapshotA], swap: 0), readingID: readingID,
                                            reading: startup, db: db, logDirectory: directory)
            try test(try db.rows("SELECT * FROM readings").count == 1 && db.rows("SELECT * FROM alerts").count == 1 &&
                     db.state("container") == container && db.state("conditions") == "free_below_25gb" &&
                     db.rows("SELECT * FROM storage_observations").isEmpty && !db.transactionActive,
                     "startup optional evidence transaction rollback preserves reading and alert state")
            try db.exec("DROP TRIGGER reject_startup_evidence")
            try db.exec("BEGIN IMMEDIATE")
            try db.state("nested_fixture", "pending")
            storeOptionalStorageObservation(observation(55_000, [snapshotA], swap: 0), readingID: readingID,
                                            reading: startup, db: db, logDirectory: directory)
            try test(try db.transactionActive && db.state("nested_fixture") == "pending" && db.rows("SELECT * FROM storage_observations").isEmpty,
                     "optional evidence refuses to enter or roll back a caller-owned transaction")
            try db.exec("ROLLBACK")
            try test(try db.state("nested_fixture").isEmpty && db.rows("SELECT * FROM readings").count == 1,
                     "refused nested evidence leaves caller rollback and committed reading intact")
        }
        do {
            let db = try Database(directory.appendingPathComponent("startup-cleanup-rollback.sqlite3").path)
            try db.write("INSERT INTO storage_observations VALUES(?,?,?)", [Int64(999), 1.0, "orphan fixture"])
            try db.exec("CREATE TRIGGER reject_evidence_cleanup BEFORE DELETE ON storage_observations BEGIN SELECT RAISE(ROLLBACK, 'fixture evidence cleanup rollback'); END")
            let startup = Reading(timestamp: 56_000, container: container, free: 50 * gb, used: 50 * gb, volumes: "[]")
            let plan = try AlertPlan(db, startup, evaluate(startup, nil, []))
            var readingID: Int64?
            do { readingID = try persistStartupReading(startup, plan: plan, db: db) }
            catch { print("EXPECTED REGRESSION EVIDENCE: \(error)") }
            try test(try readingID != nil && db.rows("SELECT * FROM readings").count == 1 && db.state("container") == container,
                     "optional evidence cleanup cannot roll back startup capacity or alert state")
            storeOptionalStorageObservation(observation(56_000, [snapshotA], swap: 0), readingID: readingID!,
                                            reading: startup, db: db, logDirectory: directory)
            try test(try db.rows("SELECT * FROM readings").count == 1 && !db.transactionActive &&
                     db.rows("SELECT * FROM storage_observations WHERE reading_id=?", [readingID!]).isEmpty,
                     "failed evidence cleanup rolls back only its new observation")
            try db.exec("DROP TRIGGER reject_evidence_cleanup")
            storeOptionalStorageObservation(observation(56_000, [snapshotA], swap: 0), readingID: readingID!,
                                            reading: startup, db: db, logDirectory: directory)
            try test(try db.rows("SELECT * FROM storage_observations").count == 1 &&
                     db.rows("SELECT * FROM storage_observations WHERE reading_id=?", [readingID!]).count == 1 && !db.transactionActive,
                     "optional evidence recovers and cleans orphans after a cleanup failure")
        }
        do {
            let paths = try ExternalVolumePaths(baseDirectory: directory.appendingPathComponent("external"), uuid: dataID, capacityScope: "apfs:" + container)
            let firstExternal = Reading(timestamp: 60_000, container: paths.capacityScope, free: 50 * gb, used: 50 * gb, volumes: "[]")
            var saved = false
            do {
                saved = try ExternalCapacityMonitoring.store(firstExternal, paths: paths, label: "Fixture",
                    observation: observation(60_000, [], swap: 0), validate: {}, notification: { _, _ in "fixture" }) != nil
            } catch { print("EXPECTED REGRESSION EVIDENCE: \(error)") }
            let db = try Database(paths.capacityDatabase)
            try test(saved && db.rows("SELECT * FROM readings").count == 1 && db.rows("SELECT * FROM storage_observations").isEmpty,
                     "invalid optional snapshot evidence cannot discard an external capacity reading")
            try db.exec("CREATE TRIGGER reject_evidence BEFORE INSERT ON storage_observations BEGIN SELECT RAISE(ABORT, 'fixture evidence write failure'); END")
            let nextExternal = Reading(timestamp: 61_800, container: paths.capacityScope, free: 49 * gb, used: 51 * gb, volumes: "[]")
            _ = try ExternalCapacityMonitoring.store(nextExternal, paths: paths, label: "Fixture",
                observation: observation(61_800, [], swap: 0, scope: paths.capacityScope), validate: {}, notification: { _, _ in "fixture" })
            try test(try db.rows("SELECT * FROM readings").count == 2 && db.rows("SELECT * FROM storage_observations").isEmpty,
                     "optional evidence ABORT preserves external capacity history and session")
            try db.exec("DROP TRIGGER reject_evidence")
            try db.exec("CREATE TRIGGER reject_evidence BEFORE INSERT ON storage_observations BEGIN SELECT RAISE(ROLLBACK, 'fixture external evidence transaction rollback'); END")
            let rollbackExternal = Reading(timestamp: 63_600, container: paths.capacityScope, free: 48 * gb, used: 52 * gb, volumes: "[]")
            _ = try ExternalCapacityMonitoring.store(rollbackExternal, paths: paths, label: "Fixture",
                observation: observation(63_600, [snapshotA], swap: 0, scope: paths.capacityScope), validate: {}, notification: { _, _ in "fixture" })
            try test(try db.rows("SELECT * FROM readings").count == 3 && db.rows("SELECT * FROM external_capacity_sessions").count == 1 &&
                     db.state("container") == paths.capacityScope && db.rows("SELECT * FROM storage_observations").isEmpty && !db.transactionActive,
                     "external optional evidence transaction rollback preserves reading, alert state and session")
            try db.exec("DROP TRIGGER reject_evidence")
            let finalExternal = Reading(timestamp: 65_400, container: paths.capacityScope, free: 47 * gb, used: 53 * gb, volumes: "[]")
            var observedCommittedReading = false
            _ = try ExternalCapacityMonitoring.store(finalExternal, paths: paths, label: "Fixture",
                observe: {
                    observedCommittedReading = (try? db.rows("SELECT * FROM readings WHERE timestamp=?", [finalExternal.timestamp]).count) == 1
                    return observation(65_400, [snapshotA], swap: 0, scope: paths.capacityScope)
                }, validate: {}, notification: { _, _ in "fixture" })
            try test(observedCommittedReading, "external capacity reading is durable before optional snapshot collection starts")
            try test(try db.rows("SELECT * FROM readings").count == 4 && db.rows("SELECT * FROM storage_observations").count == 1 && !db.transactionActive,
                     "valid external snapshot evidence persists after an unavailable observation")
        }
        if CommandLine.arguments.contains("--live") {
            let measured = try measure()
            let live = SnapshotObserver.capture(measured)
            try test(StorageObservation.decode(try live.encoded()) != nil, "real read-only host observation encodes valid bounded evidence")
            try test(live.inventories.contains { $0.status == .complete }, "real APFS snapshot inventories read successfully without elevated privileges")
            print("LIVE: \(live.inventories.count) volume outcomes, \(live.inventories.filter { $0.status == .complete }.count) complete, \(live.inventories.reduce(0) { $0 + $1.snapshots.count }) snapshots, \(live.capacities.count) Foundation capacity observations")
        }
        print("\(checks) snapshot integration checks passed")
    }
}
