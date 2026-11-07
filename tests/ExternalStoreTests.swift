import Foundation
import SQLite3

private actor DelayedHistory {
    let heldPath: String
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(heldPath: String) { self.heldPath = heldPath }
    func load(_ path: String) async throws -> HistorySnapshot {
        if path == heldPath {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try await HistoryReader(path: path).load()
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main enum ExternalStoreTests {
    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/storage-external-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", b = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let registry = ExternalVolumeRegistry(baseDirectory: base)
        for (uuid, name) in [(a, "One"), (b, "Two")] {
            _ = try registry.enroll(ExternalVolumeDescriptor(volumeUUID: uuid, name: name, mountPath: "/Volumes/\(name)", filesystem: "exfat", device: 42,
                backingUUIDs: [uuid], isInternal: false, isLocal: true, isPhysical: true))
        }
        let first = try ExternalVolumePaths(baseDirectory: base, uuid: a, capacityScope: "filesystem:" + a)
        let second = try ExternalVolumePaths(baseDirectory: base, uuid: b, capacityScope: "filesystem:" + b)
        try first.prepare(); try second.prepare()
        let startup = base.appendingPathComponent("history.sqlite3").path
        func history(_ path: String, free: Int64, scope: String = "fixture", timestamp: Double = 10_000) throws {
            var database: OpaquePointer?
            precondition(sqlite3_open(path, &database) == SQLITE_OK)
            defer { sqlite3_close(database) }
            let sql = "CREATE TABLE readings(id INTEGER PRIMARY KEY,timestamp REAL,container TEXT,free INTEGER,used INTEGER,volumes TEXT); CREATE TABLE alerts(id INTEGER PRIMARY KEY,timestamp REAL,severity TEXT,reasons TEXT,free INTEGER,delta INTEGER,notification TEXT); CREATE TABLE diagnostics(id INTEGER PRIMARY KEY,timestamp REAL,snapshot TEXT); INSERT INTO readings VALUES(1,\(timestamp),'\(scope)',\(free),100000000000,'[]');"
            precondition(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        try history(startup, free: 50_000_000_000); try history(first.capacityDatabase, free: 10_000_000_000, scope: first.capacityScope, timestamp: 20_000); try history(second.capacityDatabase, free: 80_000_000_000, scope: second.capacityScope, timestamp: 30_000)
        let suite = "StorageMonitor.ExternalStoreTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let delayed = DelayedHistory(heldPath: first.capacityDatabase)
        let config = ViewerConfiguration(database: startup, appearance: nil, windowSize: nil, isQA: false, readinessOutput: nil)
        let store = ViewerStore(configuration: config, preferencesOverride: preferences, historyLoader: { try await delayed.load($0) })
        store.section = "history"
        store.refreshTargets()
        for _ in 0..<600 where store.externalSettings.volumes.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
        precondition(store.externalSettings.volumes.count == 2)
        store.selectTarget(a)
        for _ in 0..<600 {
            if await delayed.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let heldStarted = await delayed.started
        precondition(heldStarted, "first history response is held")
        store.selectTarget(b)
        for _ in 0..<600 where store.snapshot?.latest?.free != 80_000_000_000 { try await Task.sleep(for: .milliseconds(5)) }
        await delayed.release()
        try await Task.sleep(for: .milliseconds(30))
        precondition(store.target.uuid == b && store.snapshot?.latest?.free == 80_000_000_000, "late previous-drive history cannot overwrite selected drive")
        for _ in 0..<600 where store.monitoringHealth(at: Date()).lastSuccess != Date(timeIntervalSince1970: 10_000) { try await Task.sleep(for: .milliseconds(5)) }
        precondition(store.monitoringHealth(at: Date()).lastSuccess == Date(timeIntervalSince1970: 10_000), "global monitoring health uses startup history while an external drive is selected")
        precondition(store.configuration.database == second.capacityDatabase && store.configuration.inventoryDatabase != second.inventoryDatabase, "both sections use the selected immutable context")
        precondition(store.live.state.reading == nil, "offline external drive cannot display startup live capacity")
        precondition(store.section == "history", "drive switching preserves current section")
        let replacement = ExternalVolumeDescriptor(volumeUUID: b, name: "New scope", mountPath: "/Volumes/Two", filesystem: "apfs", device: 42,
            containerUUID: a, backingUUIDs: [b], isInternal: false, isLocal: true, isPhysical: true)
        _ = try registry.enroll(replacement, replaceBacking: true)
        let newScope = try ExternalVolumePaths(baseDirectory: base, uuid: b, capacityScope: replacement.capacityScope())
        try newScope.prepare(); try history(newScope.capacityDatabase, free: 90_000_000_000, scope: newScope.capacityScope)
        for _ in 0..<600 where store.snapshot?.latest?.free != 90_000_000_000 {
            store.refreshTargets(); try await Task.sleep(for: .milliseconds(5))
        }
        precondition(store.configuration.database == newScope.capacityDatabase && store.snapshot?.latest?.free == 90_000_000_000, "same selected UUID changing capacity scope must replace its history reader")
        store.selectTarget(nil)
        for _ in 0..<600 where store.snapshot?.latest?.free != 50_000_000_000 { try await Task.sleep(for: .milliseconds(5)) }
        precondition(store.target.uuid == nil && store.snapshot?.latest?.free == 50_000_000_000, "returning to startup restores its own history")
        store.stop()
        let wrongScope = try await HistoryReader(path: startup).load()
        let misrouted = ViewerStore(configuration: config, preferencesOverride: preferences, historyLoader: { _ in wrongScope })
        misrouted.refreshTargets()
        for _ in 0..<600 where misrouted.externalSettings.volumes.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
        misrouted.selectTarget(b)
        for _ in 0..<600 where misrouted.error == nil { try await Task.sleep(for: .milliseconds(5)) }
        precondition(misrouted.snapshot == nil && misrouted.error != nil, "selected drive refuses history whose recorded capacity identity belongs elsewhere")
        misrouted.stop()
        let fakeHome = base.appendingPathComponent("helper-home")
        let app = fakeHome.appendingPathComponent("Applications/MacBook Storage Monitor.app")
        let executable = app.appendingPathComponent("Contents/MacOS/StorageMonitor")
        let agents = fakeHome.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("fixture, never executed".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        func plist(_ object: [String: Any], _ url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url)
        }
        try plist(["CFBundleShortVersionString": "1", "CFBundleVersion": "1", "StorageMonitorExternalVolumeSupport": 1], app.appendingPathComponent("Contents/Info.plist"))
        let registryPath = fakeHome.appendingPathComponent("Library/Application Support/MacBook Storage Monitor/external-volumes/registry.json").path
        let helperData = fakeHome.appendingPathComponent("Library/Application Support/MacBook Storage Monitor").path
        for (index, label) in MonitoringSetupStatus.labels.enumerated() {
            let command = ["check", "initialize-baseline", "inventory-work"][index]
            let watches = index == 2 ? [helperData + "/inventory-requests"] : [registryPath]
            try plist(["Label": label, "ProgramArguments": [executable.path, command, "--budget", "1200", "--data-dir", helperData], "RunAtLoad": true,
                "StartOnMount": true, "WatchPaths": watches, "KeepAlive": ["SuccessfulExit": false]], agents.appendingPathComponent(label + ".plist"))
        }
        precondition(MonitoringSetupStatus.externalVolumesReady(home: fakeHome), "helper capability requires compatible wake configuration")
        let loaded = LaunchdState(loaded: Set(MonitoringSetupStatus.labels), disabled: [])
        let disabled = LaunchdState(loaded: Set(MonitoringSetupStatus.labels), disabled: [MonitoringSetupStatus.labels[2]])
        precondition(MonitoringSetupStatus.externalVolumesReady(home: fakeHome, launchd: loaded) && !MonitoringSetupStatus.externalVolumesReady(home: fakeHome, launchd: disabled), "operational readiness respects cached macOS disabled state")
        try plist(["Label": MonitoringSetupStatus.labels[2], "ProgramArguments": [executable.path, "inventory-work", "--budget", "1200", "--data-dir", helperData]], agents.appendingPathComponent(MonitoringSetupStatus.labels[2] + ".plist"))
        precondition(!MonitoringSetupStatus.externalVolumesReady(home: fakeHome), "missing inventory wake/continuation configuration cannot advertise readiness")
        try plist(["Label": MonitoringSetupStatus.labels[0], "ProgramArguments": [executable.path]], agents.appendingPathComponent(MonitoringSetupStatus.labels[0] + ".plist"))
        precondition(!MonitoringSetupStatus.externalVolumesReady(home: fakeHome), "old wake configuration cannot advertise automatic resume")
        precondition(MonitoringSetupStatus.evaluate(home: fakeHome, bundledHelper: app).state == .needsUpdate, "same-version helper still requests update when external capability configuration is missing")
        print("13 external ViewerStore/helper integration tests passed")
    }
}
