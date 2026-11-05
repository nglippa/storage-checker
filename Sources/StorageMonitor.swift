import Foundation
import AppKit
import UserNotifications
import SQLite3
import Darwin

let label = "local.macbook.storage-monitor"
let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let gb: Int64 = 1_000_000_000
let retention: TimeInterval = 30 * 86400
let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func required(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
func iso(_ t: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t)) }
func size(_ n: Int64) -> String { String(format: "%.2f GB", Double(n) / Double(gb)) }
func json(_ value: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}" }
func privateDirectory(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }

// Each subprocess gets a deadline and bounded captured output. No shell, inherited aliases,
// stdin, network, or filesystem mutation commands are used for measurements.
struct CommandResult { var data: Data; var errors: Data; var status: Int32; var timedOut: Bool; var truncated: Bool; var pid: Int32 = 0; var text: String { String(decoding: data, as: UTF8.self) + String(decoding: errors, as: UTF8.self) } }
var subprocessCount = 0
func run(_ path: String, _ args: [String], timeout: Double = 10, cap: Int = 262144) throws -> CommandResult {
    let task = Process(), pipe = Pipe(), errorPipe = Pipe()
    subprocessCount += 1
    task.executableURL = URL(fileURLWithPath: path); task.arguments = args
    task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe; task.standardError = errorPipe
    try task.run()
    let fd = pipe.fileHandleForReading.fileDescriptor, errorFD = errorPipe.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, O_NONBLOCK); _ = fcntl(errorFD, F_SETFL, O_NONBLOCK)
    let deadline = Date().addingTimeInterval(timeout)
    return captureCommandOutput(task, pipe, errorPipe, deadline: deadline, cap: cap)
}

// Shared capture engine: the caller owns launch/readiness; the absolute deadline never resets.
private func captureCommandOutput(_ task: Process, _ pipe: Pipe, _ errorPipe: Pipe, deadline: Date, cap: Int) -> CommandResult {
    let fd = pipe.fileHandleForReading.fileDescriptor, errorFD = errorPipe.fileHandleForReading.fileDescriptor
    var bytes = Data(), errors = Data(), expired = false, truncated = false
    func drainStream(_ descriptor: Int32, _ destination: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<64 { let n = read(descriptor, &buffer, buffer.count); if n <= 0 { break }; if n > cap - destination.count { truncated = true }; if destination.count < cap { destination.append(contentsOf: buffer.prefix(min(n, cap - destination.count))) } }
    }
    func drain() { drainStream(fd, &bytes); drainStream(errorFD, &errors) }
    while task.isRunning {
        drain()
        if Date() >= deadline { expired = true; task.terminate(); break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    if expired {
        let grace = Date().addingTimeInterval(1)
        while task.isRunning && Date() < grace { drain(); Thread.sleep(forTimeInterval: 0.02) }
        if task.isRunning { _ = kill(task.processIdentifier, SIGKILL) }
    }
    task.waitUntilExit(); drain(); try? pipe.fileHandleForReading.close(); try? errorPipe.fileHandleForReading.close()
    return CommandResult(data: bytes, errors: errors, status: task.terminationStatus, timedOut: expired, truncated: truncated, pid: task.processIdentifier)
}
// A property list is parsed only from complete output: a capped, timed-out or
// failed capture is rejected rather than read as a partial document.
func completePlist(_ result: CommandResult) throws -> [String: Any] {
    try required(result.status == 0 && !result.timedOut && !result.truncated, "diskutil failed, timed out, or output exceeded capture limit (status \(result.status), timed out \(result.timedOut), truncated \(result.truncated))")
    guard let value = try PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any] else { throw Failure("Invalid diskutil plist") }; return value
}
func plistCommand(_ args: [String]) throws -> [String: Any] { try completePlist(try run("/usr/sbin/diskutil", args)) }
func number(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

struct Reading {
    let timestamp: Double; let container: String; let free: Int64; let used: Int64; let volumes: String
}
func measure() throws -> Reading {
    let root = try plistCommand(["info", "-plist", "/"])
    guard let reference = root["APFSContainerReference"] as? String else { throw Failure("Root filesystem is not an identifiable APFS container") }
    let list = try plistCommand(["apfs", "list", "-plist"])
    guard let containers = list["Containers"] as? [[String: Any]], let container = containers.first(where: { $0["ContainerReference"] as? String == reference }),
          let free = number(container["CapacityFree"]), let ceiling = number(container["CapacityCeiling"]), free >= 0, ceiling > 0, free <= ceiling,
          let uuid = container["APFSContainerUUID"] as? String,
          let stores = container["PhysicalStores"] as? [[String: Any]], !stores.isEmpty else { throw Failure("Incomplete APFS container capacity data") }
    for store in stores {
        guard let device = store["DeviceIdentifier"] as? String else { throw Failure("Unidentified APFS physical store") }
        let info = try plistCommand(["info", "-plist", device])
        try required(info["Internal"] as? Bool == true, "Root APFS container is not entirely on internal storage")
    }
    return Reading(timestamp: Date().timeIntervalSince1970, container: uuid, free: free, used: ceiling - free, volumes: json(container["Volumes"] ?? []))
}

final class Database {
    var db: OpaquePointer?
    /// The busy timeout covers the moments another process (the check or the inventory worker) commits.
    /// Background work can afford to wait; 10 s keeps the scheduled check from being starved (D9).
    init(_ path: String, busyTimeout: Int32 = 10_000) throws {
        try required(sqlite3_open(path, &db) == SQLITE_OK, "Cannot open SQLite history")
        sqlite3_busy_timeout(db, busyTimeout)
        try exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA auto_vacuum=INCREMENTAL; CREATE TABLE IF NOT EXISTS readings (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, container TEXT NOT NULL, free INTEGER NOT NULL, used INTEGER NOT NULL, volumes TEXT NOT NULL); CREATE INDEX IF NOT EXISTS readings_time ON readings(timestamp); CREATE TABLE IF NOT EXISTS alerts (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, severity TEXT NOT NULL, reasons TEXT NOT NULL, free INTEGER NOT NULL, delta INTEGER, notification TEXT NOT NULL); CREATE TABLE IF NOT EXISTS diagnostics (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, snapshot TEXT NOT NULL); CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS interval_evidence (reading_id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, evidence TEXT NOT NULL); " +
            // Comprehensive coverage (additive; see Coverage.swift). Current state, not history: no retention.
            "CREATE TABLE IF NOT EXISTS coverage_units (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, parent INTEGER, depth INTEGER NOT NULL, kind TEXT NOT NULL, state TEXT NOT NULL, reason TEXT, inode INTEGER, logical INTEGER NOT NULL DEFAULT 0, allocated INTEGER NOT NULL DEFAULT 0, files INTEGER NOT NULL DEFAULT 0, entries INTEGER NOT NULL DEFAULT 0, complete INTEGER NOT NULL DEFAULT 0, measured_at REAL, valid_event INTEGER, valid_at REAL, valid_reading INTEGER, first_valid_reading INTEGER, listing_reading INTEGER, discovered_at REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_attempt REAL, needs_split INTEGER NOT NULL DEFAULT 0, agg_logical INTEGER NOT NULL DEFAULT 0, agg_allocated INTEGER NOT NULL DEFAULT 0, agg_files INTEGER NOT NULL DEFAULT 0, agg_complete INTEGER NOT NULL DEFAULT 0, agg_holes INTEGER NOT NULL DEFAULT 0); CREATE INDEX IF NOT EXISTS coverage_units_parent ON coverage_units(parent); CREATE TABLE IF NOT EXISTS coverage_epochs (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, reading_id INTEGER, scope TEXT NOT NULL, detail TEXT NOT NULL);")
        _ = chmod(path, 0o600)
    }
    deinit { sqlite3_close(db) }
    func exec(_ sql: String) throws { try required(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "SQLite: \(String(cString: sqlite3_errmsg(db)))") }
    func statement(_ sql: String, _ values: [Any] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        try required(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, "SQLite prepare failed")
        for (i, value) in values.enumerated() {
            if let v = value as? Int64 { sqlite3_bind_int64(stmt, Int32(i+1), v) }
            else if let v = value as? Double { sqlite3_bind_double(stmt, Int32(i+1), v) }
            else if let v = value as? String { sqlite3_bind_text(stmt, Int32(i+1), v, -1, transient) }
            else { sqlite3_bind_null(stmt, Int32(i+1)) }
        }
        return stmt!
    }
    func write(_ sql: String, _ values: [Any] = []) throws { let s = try statement(sql, values); defer { sqlite3_finalize(s) }; try required(sqlite3_step(s) == SQLITE_DONE, "SQLite write failed") }
    func rows(_ sql: String, _ values: [Any] = []) throws -> [[String: String]] {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }; var result = [[String: String]]()
        while true { let rc = sqlite3_step(s); if rc == SQLITE_DONE { return result }; try required(rc == SQLITE_ROW, "SQLite read failed")
            var row = [String: String](); for i in 0..<sqlite3_column_count(s) { if let v = sqlite3_column_text(s, i) { row[String(cString: sqlite3_column_name(s, i))] = String(cString: v) } }; result.append(row)
        }
    }
    func state(_ key: String) throws -> String { try rows("SELECT value FROM state WHERE key=?", [key]).first?["value"] ?? "" }
    func state(_ key: String, _ value: String) throws { try write("INSERT OR REPLACE INTO state VALUES (?,?)", [key, value]) }
    func retain(_ now: Double) throws {
        for table in ["readings", "alerts", "diagnostics"] { try write("DELETE FROM \(table) WHERE timestamp < ?", [now - retention]) }
        // Also bound pathological repeated manual runs and diagnostics independently of age.
        for (table, count) in [("readings", 10000), ("alerts", 5000), ("diagnostics", 120)] { try exec("DELETE FROM \(table) WHERE id NOT IN (SELECT id FROM \(table) ORDER BY timestamp DESC,id DESC LIMIT \(count))") }
        // Attribution rows live and die with their reading.
        try exec("DELETE FROM interval_evidence WHERE reading_id NOT IN (SELECT id FROM readings)")
        try exec("PRAGMA incremental_vacuum(256)")
    }
}

struct Evaluation {
    let severity: String; let reasons: [String]; let growth: Set<String>; let delta: Int64?
}
func evaluate(_ current: Reading, _ previous: Reading?, _ window: [Reading]) -> Evaluation {
    let delta = previous.map { current.free - $0.free }
    var reasons = [String](), growth = Set<String>()
    if let delta, delta <= -3*gb { reasons.append("drop_3gb_since_previous"); growth.insert("drop_3gb_since_previous") }
    if let high = window.filter({ $0.timestamp >= current.timestamp - 7200 && $0.timestamp < current.timestamp && $0.container == current.container }).map(\.free).max(), high - current.free >= 5*gb { reasons.append("drop_5gb_within_2h"); growth.insert("drop_5gb_within_2h") }
    let severity: String
    if current.free < 15*gb { severity = "critical"; reasons.append("free_below_15gb") }
    else if current.free < 25*gb { severity = "warning"; reasons.append("free_below_25gb") }
    else { severity = growth.isEmpty ? "normal" : "warning" }
    return Evaluation(severity: severity, reasons: reasons, growth: growth, delta: delta)
}
func notificationDue(active: Set<String>, prior: Set<String>, acknowledged: Set<String>, now: Double, lastAttempt: Double) -> Bool {
    !active.isEmpty && !active.subtracting(acknowledged).isEmpty && (!active.subtracting(prior).isEmpty || now - lastAttempt >= 1800)
}
struct AlertPlan {
    let active: Set<String>, prior: Set<String>, acknowledged: Set<String>, newReasons: Set<String>
    let signature: String, needsNotification: Bool
    init(_ db: Database, _ current: Reading, _ evaluation: Evaluation, retryNotifications: Bool = false) throws {
        active = Set(evaluation.reasons)
        let same = try db.state("container") == current.container
        prior = same ? Set(try db.state("conditions").split(separator: ",").map(String.init)) : []
        acknowledged = same ? Set(try db.state("last_sent").split(separator: ",").map(String.init)) : []
        newReasons = active.subtracting(prior); signature = active.sorted().joined(separator: ",")
        let lastAttempt = Double(try db.state("notification_attempt")) ?? 0
        needsNotification = (retryNotifications && !active.subtracting(acknowledged).isEmpty) || notificationDue(active: active, prior: prior, acknowledged: acknowledged, now: current.timestamp, lastAttempt: lastAttempt)
    }
    func persist(_ db: Database, _ current: Reading) throws {
        try db.state("container", current.container); try db.state("conditions", signature)
        try db.state("last_sent", acknowledged.intersection(active).sorted().joined(separator: ","))
    }
    func notificationResult(_ db: Database, _ current: Reading, _ result: String) throws {
        try db.state("notification_attempt", String(current.timestamp)); try db.state("notification_result", result)
        if result.hasPrefix("delivered:") { try db.state("last_sent", signature) }
    }
}
func reading(_ row: [String: String]) -> Reading? {
    guard let time = Double(row["timestamp"] ?? ""), let container = row["container"], let free = Int64(row["free"] ?? ""), let used = Int64(row["used"] ?? "") else { return nil }
    return Reading(timestamp: time, container: container, free: free, used: used, volumes: row["volumes"] ?? "[]")
}

func waitFor(_ seconds: Double, _ done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    return done()
}
func notificationStatus() -> (UNAuthorizationStatus, String) {
    var settings: UNNotificationSettings?
    UNUserNotificationCenter.current().getNotificationSettings { settings = $0 }
    guard waitFor(8, { settings != nil }), let s = settings else { return (.notDetermined, "settings_timeout") }
    let names: [UNAuthorizationStatus: String] = [.notDetermined: "not_determined", .denied: "denied", .authorized: "authorized", .provisional: "provisional"]
    return (s.authorizationStatus, "authorization=\(names[s.authorizationStatus] ?? "unknown") alert=\(s.alertSetting.rawValue) center=\(s.notificationCenterSetting.rawValue)")
}
func authorize() throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    var completed = false, granted = false, failure = ""
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { value, error in granted = value; failure = error.map(String.init(describing:)) ?? ""; completed = true }
    try required(waitFor(120, { completed }), "Notification authorization timed out")
    print("Notification permission granted=\(granted) \(notificationStatus().1) \(failure)")
    try required(granted, "Notifications denied; enable MacBook Storage Monitor in System Settings > Notifications")
}
var notificationRequests = 0
func notify(_ title: String, _ body: String) -> String {
    notificationRequests += 1
    let (status, detail) = notificationStatus()
    guard status == .authorized || status == .provisional else { return "unavailable: \(detail)" }
    let id = UUID().uuidString, content = UNMutableNotificationContent()
    content.title = title; content.body = body; content.sound = .default
    var completed = false, failure: String?
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))) { error in failure = error.map(String.init(describing:)); completed = true }
    guard waitFor(8, { completed }), failure == nil else { return "failed: \(failure ?? "submission_timeout")" }
    var delivered = false
    let deadline = Date().addingTimeInterval(8)
    while !delivered && Date() < deadline {
        var queried = false
        UNUserNotificationCenter.current().getDeliveredNotifications { values in delivered = values.contains { $0.request.identifier == id }; queried = true }
        _ = waitFor(2, { queried }); if !delivered { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
    }
    return delivered ? "delivered:\(id)" : "submitted_unconfirmed:\(id)"
}

let defaultData = home.appendingPathComponent("Library/Application Support/MacBook Storage Monitor")
let installedApp = home.appendingPathComponent("Applications/MacBook Storage Monitor.app")
let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
func agentPlist(_ executable: String, _ data: String) -> [String: Any] {
    ["Label": label, "ProgramArguments": [executable, "check", "--data-dir", data], "RunAtLoad": true, "StartCalendarInterval": [["Minute": 0], ["Minute": 30]], "ProcessType": "Background", "LowPriorityIO": true, "Nice": 10, "Umask": 63, "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null", "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]]
}
// One-time baseline initializer. It runs at load (install/login), exits 0 once coverage
// reaches a terminal state and is then idle; a non-zero exit (time limit, busy) lets
// launchd resume it after the throttle interval. The scheduled check wakes it when
// coverage is incomplete. It never records readings or sends notifications.
let baselineLabel = "local.macbook.storage-monitor.baseline"
let baselineAgentURL = home.appendingPathComponent("Library/LaunchAgents/\(baselineLabel).plist")
func baselineAgentPlist(_ executable: String, _ data: String) -> [String: Any] {
    ["Label": baselineLabel, "ProgramArguments": [executable, "initialize-baseline", "--data-dir", data], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 300,
     "ProcessType": "Background", "LowPriorityIO": true, "Nice": 15, "Umask": 63, "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null", "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]]
}
func launchctl(_ args: [String], acceptable: Bool = false) throws -> CommandResult {
    let r = try run("/bin/launchctl", args, timeout: 15); if !acceptable { try required(r.status == 0, "launchctl \(args.first ?? "") failed: \(r.text)") }; return r
}
// Consistent online copy of the history database, verified before anything is replaced.
// Keeps the three newest install backups; other files are never touched.
func backupDatabase(_ directory: URL, keep: Int = 3) throws -> URL? {
    let source = directory.appendingPathComponent("history.sqlite3")
    guard fm.fileExists(atPath: source.path) else { return nil }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let target = directory.appendingPathComponent("history.install-backup-\(stamp).sqlite3")
    var from: OpaquePointer?, to: OpaquePointer?
    defer { sqlite3_close(from); sqlite3_close(to) }
    try required(sqlite3_open_v2(source.path, &from, SQLITE_OPEN_READONLY, nil) == SQLITE_OK && sqlite3_open(target.path, &to) == SQLITE_OK, "Cannot open database for backup")
    sqlite3_busy_timeout(from, 10000)
    guard let backup = sqlite3_backup_init(to, "main", from, "main") else { throw Failure("Backup could not start: \(String(cString: sqlite3_errmsg(to)))") }
    let step = sqlite3_backup_step(backup, -1); sqlite3_backup_finish(backup)
    try required(step == SQLITE_DONE, "Backup did not complete (\(step))")
    _ = chmod(target.path, 0o600)
    func scalar(_ db: OpaquePointer?, _ sql: String) -> String {
        var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return "" }
        return String(cString: text)
    }
    try required(scalar(to, "PRAGMA integrity_check") == "ok", "Backup failed its integrity check")
    for table in ["readings", "alerts", "diagnostics", "state"] {
        try required(scalar(from, "SELECT count(*) FROM \(table)") == scalar(to, "SELECT count(*) FROM \(table)"), "Backup row count differs for \(table)")
    }
    let old = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("history.install-backup-") && $0.hasSuffix(".sqlite3") }.sorted()
    for name in old.dropLast(keep) { try? fm.removeItem(at: directory.appendingPathComponent(name)) }
    return target
}
// Paths and launchd control are injectable so installation can be verified against an
// isolated home with a recording launch control, never the user's real LaunchAgents.
struct MonitorInstallLayout {
    let home: URL
    let qa: LifecycleQAScope?
    init(home: URL, qa: LifecycleQAScope? = nil) { self.home = home; self.qa = qa }
    static let current = MonitorInstallLayout(home: fm.homeDirectoryForCurrentUser)
    static var active: MonitorInstallLayout { LifecycleQAScope.active.map { MonitorInstallLayout(home: $0.home, qa: $0) } ?? .current }
    var labels: [String] { qa?.labels ?? [label, baselineLabel, inventoryLabel] }
    var data: URL { home.appendingPathComponent("Library/Application Support/MacBook Storage Monitor") }
    var app: URL { home.appendingPathComponent("Applications/MacBook Storage Monitor.app") }
    var executable: String { app.appendingPathComponent("Contents/MacOS/StorageMonitor").path }
    func agent(_ name: String) -> URL { home.appendingPathComponent("Library/LaunchAgents/\(name).plist") }
    var agents: [(label: String, url: URL, plist: [String: Any])] {
        if let qa {
            return zip(qa.labels, [agentPlist(executable, data.path), baselineAgentPlist(executable, data.path), inventoryAgentPlist(executable, data.path)]).enumerated().map { index, pair in
                var plist = pair.1
                plist["Label"] = pair.0
                plist["ProgramArguments"] = qa.workerArguments(command: ["check", "initialize-baseline", "inventory-work"][index])
                plist["StandardOutPath"] = qa.logs + "/agent-\(index).log"
                plist["StandardErrorPath"] = qa.logs + "/agent-\(index)-errors.log"
                plist["EnvironmentVariables"] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": qa.temporary + "/", "SQLITE_TMPDIR": qa.temporary]
                return (pair.0, agent(pair.0), plist)
            }
        }
        return [(label, agent(label), agentPlist(executable, data.path)),
         (baselineLabel, agent(baselineLabel), baselineAgentPlist(executable, data.path)),
         (inventoryLabel, agent(inventoryLabel), inventoryAgentPlist(executable, data.path))]
    }
}
/// The inventory worker's periodic wake, issued after each scheduled check (:00/:30; launchd runs a
/// missed calendar check once on wake). nil unless background monitoring is installed for this data
/// directory, so disabling it stops maintenance. `kickstart` without `-k` never restarts a running
/// worker, so wakes cannot overlap a run.
func scheduledInventoryWake(directory: URL, layout: MonitorInstallLayout = .active) -> [String]? {
    guard directory.standardizedFileURL == layout.data.standardizedFileURL, fm.fileExists(atPath: layout.agent(layout.labels[2]).path) else { return nil }
    return ["kickstart", "gui/\(getuid())/\(layout.labels[2])"]
}
typealias LaunchControl = (_ arguments: [String], _ acceptable: Bool) throws -> Void
let systemLaunchControl: LaunchControl = { arguments, acceptable in _ = try launchctl(arguments, acceptable: acceptable) }

/// Downloaded copies carry com.apple.quarantine; an unnotarized background helper may then be
/// refused by Gatekeeper with no visible prompt. Detected and reported, never removed.
func isQuarantined(_ url: URL) -> Bool { getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }

@discardableResult
func install(layout: MonitorInstallLayout = .current, source: URL = Bundle.main.bundleURL, control: @escaping LaunchControl = systemLaunchControl,
             fault: (InstallJournal.Phase) throws -> Void = { _ in }, rollbackOnFailure: Bool = true) throws -> [String] {
    try layout.validateQABoundary()
    if let qa = layout.qa {
        try qa.admit(command: "install")
        try qa.validateBundle(source, roles: ["V1", "V2"])
    }
    let control = layout.guardedControl(control)
    guard source.pathExtension == "app" else { throw Failure("Build and run the bundled executable using bin/storage-monitor") }
    try privateDirectory(layout.data)
    var notes = try recoverInterruptedInstall(layout: layout, control: control)
    try fm.createDirectory(at: layout.app.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: layout.agent(layout.labels[0]).deletingLastPathComponent(), withIntermediateDirectories: true)
    var transaction = try InstallTransaction.begin(layout, control: control)
    do {
        // Stop only this monitor's agents (by label, whatever program a stale agent points at).
        try transaction.stopAgents()
        try transaction.advance(.stopped); try fault(.stopped)
        if fm.fileExists(atPath: layout.history.path) {
            transaction.journal.schemaBefore = try schemaFingerprint(layout.history.path)
            try snapshotDatabase(layout.history, to: layout.snapshot)
            transaction.journal.snapshot = true
            try transaction.advance(.snapshotted); try fault(.snapshotted)
        }
        if source.standardizedFileURL != layout.app.standardizedFileURL {
            // The previous installation is moved aside, not discarded, until the update commits.
            let staging = layout.app.deletingLastPathComponent().appendingPathComponent(".MacBook Storage Monitor.staging.\(UUID().uuidString).app")
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: layout.previousApp.path) { try fm.removeItem(at: layout.previousApp) }
            if fm.fileExists(atPath: layout.app.path) { try fm.moveItem(at: layout.app, to: layout.previousApp) }
            try fm.moveItem(at: staging, to: layout.app)
        }
        try transaction.advance(.swapped); try fault(.swapped)
        try required(fm.isExecutableFile(atPath: layout.executable), "Installed background monitor is missing its executable: \(layout.executable)")
        // This code's schema, applied while nothing else can write, so a failed migration rolls back.
        _ = try Database(layout.history.path)
        try initializeInventorySchema(databasePath: layout.history.path)
        try transaction.advance(.migrated); try fault(.migrated)
        if layout.home == MonitorInstallLayout.current.home {
            _ = try run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", layout.app.path])
        }
        try privateDirectory(InventoryRequests.directory(database: layout.history.path))
        for duplicate in layout.duplicateAgents { try fm.removeItem(at: duplicate) }
        for agent in layout.agents {
            let data = try PropertyListSerialization.data(fromPropertyList: agent.plist, format: .xml, options: 0)
            try data.write(to: agent.url, options: .atomic); _ = chmod(agent.url.path, 0o600)
        }
        // From the first bootstrap a started agent may write history: a rollback no longer restores it.
        try transaction.advance(.registering); try fault(.registering)
        for agent in layout.agents {
            try control(["enable", "\(transaction.domain)/\(agent.label)"], false)
            try control(["bootstrap", transaction.domain, agent.url.path], false)
            try control(["print", "\(transaction.domain)/\(agent.label)"], false)    // loaded, not just written
        }
        try transaction.advance(.registered); try fault(.registered)
        notes += try transaction.commit()
    } catch {
        guard rollbackOnFailure else { throw error }
        let restored: [String]
        do { restored = try transaction.rollback() } catch let rollbackError {
            throw Failure("\(error). Restoring the previous installation also failed (\(rollbackError)); run the update again to finish the repair.")
        }
        throw Failure(([("\(error). The previous installation and history were restored.")] + restored.filter { $0.hasPrefix("Could not restart") }).joined(separator: "\n"))
    }
    if isQuarantined(layout.app) {
        notes.append("This copy was downloaded, so macOS may block the background monitor without showing a prompt. If no readings appear, open ~/Applications/MacBook Storage Monitor.app once in Finder and allow it in System Settings → Privacy & Security.")
    }
    notes.append("Installed \(layout.agent(layout.labels[0]).path)\n" + (layout.qa == nil ? "Runs at login and every :00/:30 (calendar catch-up after sleep)." : "Disposable fixture services registered. Private plists do not establish login persistence."))
    return notes
}

@discardableResult
func uninstall(layout: MonitorInstallLayout = .current, control: @escaping LaunchControl = systemLaunchControl) throws -> [String] {
    try layout.validateQABoundary()
    let control = layout.guardedControl(control)
    var notes = try recoverInterruptedInstall(layout: layout, control: control, restart: layout.qa == nil)
    for agent in layout.agents { try control(["bootout", "gui/\(getuid())/\(agent.label)"], true) }
    for url in layout.agents.map(\.url) + layout.duplicateAgents where fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    notes.append("Background monitoring disabled; LaunchAgents removed. App and history retained: \(layout.data.path)")
    return notes
}

func log(_ directory: URL, _ message: String) {
    let url = directory.appendingPathComponent("monitor.log"), previous = directory.appendingPathComponent("monitor.log.1")
    if let attr = try? fm.attributesOfItem(atPath: url.path), let bytes = attr[.size] as? NSNumber, bytes.intValue > 262144 {
        if fm.fileExists(atPath: previous.path) { try? fm.removeItem(at: previous) }; try? fm.moveItem(at: url, to: previous)
    }
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    if let file = try? FileHandle(forWritingTo: url) { defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: Data("\(iso(Date().timeIntervalSince1970)) \(message.prefix(4096))\n".utf8)) }
}
func check(_ directory: URL, forceDiagnostics: Bool = false, retryNotifications: Bool = false, qa: LifecycleQAScope? = nil) throws {
    if let qa { try qa.admit(command: "check"); try qa.validateFixtures(); try required(directory.path == qa.data.path, "Lifecycle QA check data mismatch") }
    try privateDirectory(directory)
    let lockFD = open(directory.appendingPathComponent("check.lock").path, O_RDWR | O_CREAT, 0o600)
    try required(lockFD >= 0, "Cannot open execution lock")
    defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { print("A check is already running; skipped."); return }
    do {
        let db = try Database(directory.appendingPathComponent("history.sqlite3").path)
        let current = try measure()
        let marker = currentEventMarker(qa?.fixtures ?? home.path)   // FSEvents position at this reading
        let previousRow = try db.rows("SELECT id,timestamp FROM readings WHERE container=? AND timestamp < ? ORDER BY timestamp DESC,id DESC LIMIT 1", [current.container, current.timestamp]).first
        let previous = try db.rows("SELECT * FROM readings WHERE container=? AND timestamp < ? ORDER BY timestamp DESC,id DESC LIMIT 1", [current.container, current.timestamp]).first.flatMap(reading)
        let window = try db.rows("SELECT * FROM readings WHERE container=? AND timestamp >= ? AND timestamp < ?", [current.container, current.timestamp - 7200, current.timestamp]).compactMap(reading)
        let evaluation = evaluate(current, previous, window)
        let plan = try AlertPlan(db, current, evaluation, retryNotifications: retryNotifications)
        var readingId: Int64 = 0
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.write("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES(?,?,?,?,?)", [current.timestamp, current.container, current.free, current.used, current.volumes])
            readingId = sqlite3_last_insert_rowid(db.db)
            try plan.persist(db,current)
            try db.retain(current.timestamp); try db.exec("COMMIT")
        } catch { try? db.exec("ROLLBACK"); throw error }
        var notification = qa == nil ? "deduplicated" : "suppressed:lifecycle-qa"
        if plan.needsNotification && qa == nil {
            let delta = evaluation.delta.map { size($0) } ?? "no previous reading"
            notification = notify("Storage \(evaluation.severity.uppercased())", "\(size(current.free)) free; change \(delta). \(evaluation.reasons.joined(separator: "; "))")
            try plan.notificationResult(db,current,notification)
        }
        if !plan.newReasons.isEmpty || plan.needsNotification {
            try db.write("INSERT INTO alerts(timestamp,severity,reasons,free,delta,notification) VALUES(?,?,?,?,?,?)", [current.timestamp, evaluation.severity, plan.signature, current.free, evaluation.delta as Any, notification])
        }
        // Folder, file-activity and process evidence for this interval. Bounded,
        // read-only, and never allowed to fail the check.
        let evidenceStarted = Date()
        let prior = previousRow.flatMap { row in Int64(row["id"] ?? "").flatMap { id in Double(row["timestamp"] ?? "").map { (id: id, time: $0) } } }
        // Comprehensive coverage of the startup Data volume once established; until then (or with
        // {"mode":"folders"} in coverage.json) the predefined monitored folders.
        let comprehensive = qa == nil && coverageMode(directory) == "comprehensive"
        let region = comprehensive ? startupDataRegion(current) : (region: nil, reason: "Comprehensive coverage is turned off in coverage.json.")
        let lockPath = directory.appendingPathComponent("attribution.lock").path
        var evidence: [String: Any]
        if let coverageRegion = region.region, let wide = collectCoverageEvidence(db: db, readingId: readingId, readingTime: current.timestamp, previous: prior, marker: marker, region: coverageRegion, volumeAllocated: dataVolumeAllocated(current)?.allocated, lockPath: lockPath) {
            evidence = wide
        } else {
            evidence = collectIntervalEvidence(db: db, readingId: readingId, readingTime: current.timestamp, previous: prior, marker: marker,
                roots: qa.map { [MonitoredRoot(path: $0.fixtures, label: "Disposable lifecycle fixtures")] } ?? (defaultMonitoredRoots() + configuredRoots(directory)),
                within: qa?.root ?? home.path, includeProcesses: qa == nil, lockPath: lockPath)
            let lifecycle = decodeCoverageLifecycle(db)
            evidence["coverage"] = ["scope": "folders", "reason": region.reason ?? (lifecycle == nil ? "Comprehensive coverage has not started yet." : "Comprehensive coverage is still being established (\(lifecycle!.baselined) of \(lifecycle!.units) areas measured)."),
                                    "comprehensive_state": lifecycle?.state ?? "not_initialized"]
            if region.region == nil { recordCoverageEpoch(db, scope: "folders", readingId: readingId, at: current.timestamp, detail: region.reason ?? "Predefined monitored folders") }
        }
        // Incomplete coverage: wake the background initializer instead of stretching this check.
        let needsInitializer = region.region != nil ? coverageNeedsWork(db, at: current.timestamp) : (decodeLifecycle(db).map { ["not_initialized", "initializing"].contains($0.state) } ?? false)
        if needsInitializer, directory.standardizedFileURL == defaultData.standardizedFileURL, fm.fileExists(atPath: baselineAgentURL.path) {
            _ = try? launchctl(["kickstart", "gui/\(getuid())/\(baselineLabel)"], acceptable: true)
        }
        do { try db.write("INSERT OR REPLACE INTO interval_evidence(reading_id,timestamp,evidence) VALUES(?,?,?)", [readingId, current.timestamp, json(evidence)]) }
        catch { log(directory, "attribution not stored: \(error)") }
        let folders = evidence["folders"] as? [String: Any] ?? [:]
        log(directory, "attribution \((evidence["coverage"] as? [String: Any])?["scope"] ?? "folders") \(folders["status"] ?? "?") measured=\(folders["measured"] ?? 0) carried=\(folders["carried"] ?? 0) pending=\(folders["pending"] ?? 0) changes=\(folders["changes_total"] ?? 0) activity=\((evidence["file_activity"] as? [String: Any])?["status"] ?? "?") \(Int(Date().timeIntervalSince(evidenceStarted) * 1000))ms peakMB=\(peakMemoryBytes() / 1_048_576)")
        if qa == nil && (forceDiagnostics || !evaluation.growth.subtracting(plan.prior).isEmpty) {
            let snapshot = diagnosticSnapshot(current)
            try db.write("INSERT INTO diagnostics(timestamp,snapshot) VALUES(?,?)", [current.timestamp, snapshot])
        }
        try db.retain(current.timestamp)
        if qa != nil { try db.state("lifecycle_qa_last_check_role", LifecycleQAScope.compiledFixtureRole) }
        let summary = "\(evaluation.severity.uppercased()) free=\(size(current.free)) used=\(size(current.used)) change=\(evaluation.delta.map(size) ?? "baseline") reasons=\(plan.signature.isEmpty ? "none" : plan.signature) notification=\(notification)"
        log(directory, summary); print(summary)
        // Inventory only wakes after capacity and attribution are durable. Its traversal and
        // event replay run in a separate process with their own short SQLite transactions.
        // What macOS currently allows this helper to post, for Settings (D7). Only the installed helper
        // reads it: permission belongs to this bundle, and test binaries have no notification identity.
        if directory.standardizedFileURL == defaultData.standardizedFileURL, Bundle.main.bundleIdentifier == "local.macbook.storage-monitor" {
            try? db.state("notification_authorization", notificationStatus().1)
        }
        if let wake = scheduledInventoryWake(directory: directory) {
            if let qa { try MonitorInstallLayout(home: qa.home, qa: qa).guardedControl(systemLaunchControl)(wake, true) }
            else { _ = try? run("/bin/launchctl", wake, timeout: 2) }
        }
        if let qa, needsInitializer, fm.fileExists(atPath: qa.agentURL(qa.labels[1]).path) {
            try MonitorInstallLayout(home: qa.home, qa: qa).guardedControl(systemLaunchControl)(["kickstart", "gui/\(getuid())/\(qa.labels[1])"], true)
        }
    } catch { log(directory, "ERROR \(error)"); throw error }
}

func show(_ directory: URL, _ command: String, _ limit: Int) throws {
    guard fm.fileExists(atPath: directory.appendingPathComponent("history.sqlite3").path) else { print("No measurements yet. Run check."); return }
    let db = try Database(directory.appendingPathComponent("history.sqlite3").path)
    try db.retain(Date().timeIntervalSince1970)
    if command == "diagnostics" { for row in try db.rows("SELECT * FROM diagnostics ORDER BY timestamp DESC,id DESC LIMIT ?", [Int64(limit)]) { print(row["snapshot"] ?? "{}") }; return }
    if command == "attribution" { for row in try db.rows("SELECT evidence FROM interval_evidence ORDER BY reading_id DESC LIMIT ?", [Int64(limit)]) { print(row["evidence"] ?? "{}") }; return }
    if command == "alerts" { for row in try db.rows("SELECT * FROM alerts ORDER BY timestamp DESC,id DESC LIMIT ?", [Int64(limit)]) { print(json(row)) }; return }
    for row in try db.rows("SELECT * FROM readings ORDER BY timestamp DESC,id DESC LIMIT ?", [Int64(command == "status" ? 1 : limit)]) {
        if let r = reading(row) { print("\(iso(r.timestamp)) free=\(size(r.free)) used=\(size(r.used)) container=\(r.container)"); if command == "status" { print("Measurement age: \(Int(Date().timeIntervalSince1970 - r.timestamp))s; conditions: \(try db.state("conditions"))\nVolume allocation: \(r.volumes)") } }
    }
    if command == "status" {
        print("Notification: \(notificationStatus().1); last result: \(try db.state("notification_result"))")
        let service = try launchctl(["print", "gui/\(getuid())/\(label)"], acceptable: true)
        print("LaunchAgent: \(service.status == 0 ? "loaded" : "not loaded")")
        for line in service.text.split(separator: "\n") where line.contains("last exit code") || line.contains("runs =") || line.contains("state =") { print(line.trimmingCharacters(in: .whitespaces)) }
    }
}

// A continuous-output fixture must actually be producing before its 100 ms capture test starts.
// Process startup (including first Rosetta translation) has its own bounded fixture allowance.
private func selfTestContinuousOutput() throws -> CommandResult {
    let task = Process(), pipe = Pipe(), errorPipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe; task.standardError = errorPipe
    try task.run()
    let fd = pipe.fileHandleForReading.fileDescriptor, errorFD = errorPipe.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, O_NONBLOCK); _ = fcntl(errorFD, F_SETFL, O_NONBLOCK)
    var captured = false
    defer {
        if !captured { _ = captureCommandOutput(task, pipe, errorPipe, deadline: .distantPast, cap: 16) }
    }
    let clock = SuspendingClock(), readyUntil = SuspendingClock.now.advanced(by: .seconds(10))
    // FIONREAD = _IOR('f', 127, int) in Darwin sys/filio.h; the macro is unavailable to Swift.
    let readableBytesRequest: UInt = 0x4004667f
    var ready = false, available: Int32 = 0
    while task.isRunning && clock.now < readyUntil {
        if ioctl(fd, readableBytesRequest, &available) == 0 && available > 16 { ready = true; break }
        Thread.sleep(forTimeInterval: 0.005)
    }
    try required(ready, "Continuous-output self-test fixture did not become ready within 10 active seconds (buffered=\(available))")
    let result = captureCommandOutput(task, pipe, errorPipe, deadline: Date().addingTimeInterval(0.1), cap: 16)
    captured = true
    return result
}

func selfTest() throws {
    var count = 0
    func test(_ value: Bool, _ description: String) throws { try required(value, "FAIL: \(description)"); count += 1; print("PASS \(description)") }
    func r(_ t: Double, _ f: Int64, _ c: String = "test") -> Reading { Reading(timestamp: t, container: c, free: f, used: 245*gb-f, volumes: "[]") }
    try test(evaluate(r(0,25*gb), nil, []).severity == "normal", "25 GB boundary is normal")
    try test(evaluate(r(0,25*gb-1), nil, []).reasons == ["free_below_25gb"], "strict low threshold")
    try test(evaluate(r(0,15*gb), nil, []).severity == "warning", "15 GB boundary warning")
    try test(evaluate(r(0,15*gb-1), nil, []).severity == "critical", "critical below 15 GB")
    try test(evaluate(r(1800,47*gb), r(0,50*gb), []).growth.contains("drop_3gb_since_previous"), "3 GB previous reading boundary")
    try test(evaluate(r(1800,47*gb+1), r(0,50*gb), []).growth.isEmpty, "below 3 GB excluded")
    try test(evaluate(r(7200,45*gb), r(5400,47*gb), [r(0,50*gb)]).growth.contains("drop_5gb_within_2h"), "5 GB inclusive two-hour boundary")
    try test(evaluate(r(7201,45*gb), r(5400,47*gb), [r(0,50*gb)]).growth.isEmpty, "outside two-hour window excluded")
    try test(evaluate(r(7200,45*gb), nil, [r(0,100*gb,"external")]).growth.isEmpty, "container isolation")
    let folder = monitorSelfTestFixture("test")
    try privateDirectory(folder); defer { finishMonitorSelfTestFixture(folder) }
    let db = try Database(folder.appendingPathComponent("test.sqlite3").path)
    let now = Date().timeIntervalSince1970
    for time in [now-retention-1, now-retention, now] { try db.write("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES(?,?,?,?,?)", [time,"test",50*gb,195*gb,"[]"]); try db.write("INSERT INTO alerts(timestamp,severity,reasons,free,notification) VALUES(?,?,?,?,?)",[time,"warning","test",50*gb,"test"]); try db.write("INSERT INTO diagnostics(timestamp,snapshot) VALUES(?,?)", [time,"{}"] ) }
    try db.retain(now)
    for table in ["readings","alerts","diagnostics"] { try test(try db.rows("SELECT * FROM \(table)").count == 2, "30-day retention \(table)") }
    let low: Set<String> = ["free_below_25gb"], critical: Set<String> = ["free_below_15gb"]
    try db.state("conditions", low.sorted().joined(separator: ","))
    try test(low.subtracting(Set(try db.state("conditions").split(separator: ",").map(String.init))).isEmpty, "unchanged warning deduplicated persistently")
    try test(!critical.subtracting(low).isEmpty, "critical escalates warning")
    try db.state("conditions", "")
    try test(!low.subtracting(Set(try db.state("conditions").split(separator: ",").map(String.init))).isEmpty, "recovery rearms warning")
    try test(notificationDue(active: low, prior: [], acknowledged: [], now: 100, lastAttempt: 0), "new warning requests notification")
    try test(!notificationDue(active: low, prior: low, acknowledged: low, now: 4000, lastAttempt: 100), "delivered persistent warning never duplicates")
    try test(notificationDue(active: critical, prior: low, acknowledged: low, now: 101, lastAttempt: 100), "critical escalation bypasses retry delay")
    try test(!notificationDue(active: low, prior: low, acknowledged: [], now: 200, lastAttempt: 100), "failed delivery retry rate limited")
    try test(notificationDue(active: low, prior: low, acknowledged: [], now: 1900, lastAttempt: 100), "failed delivery retries after thirty minutes")
    try test(!notificationDue(active: low, prior: low.union(["drop_3gb_since_previous"]), acknowledged: low, now: 4000, lastAttempt: 0), "resolved growth does not renotify unchanged low condition")
    let transitionPath = folder.appendingPathComponent("transitions.sqlite3").path
    func transition(_ t: Double, _ free: Int64, _ previous: Reading?, _ window: [Reading], _ result: String? = nil, _ container: String = "test") throws -> Bool {
        // Reopen SQLite for every transition, as separate launchd invocations do.
        let store = try Database(transitionPath), current = r(t,free,container)
        let plan = try AlertPlan(store,current,evaluate(current,previous,window))
        try plan.persist(store,current)
        if let result { try plan.notificationResult(store,current,result) }
        return plan.needsNotification
    }
    try test(try transition(100,20*gb,r(0,26*gb),[r(0,26*gb)],"delivered:test"), "SQLite lifecycle low plus growth alerts")
    try test(try !transition(200,20*gb,r(100,20*gb),[]), "SQLite reopen growth resolves without duplicate low alert")
    try test(try transition(201,14*gb,r(200,20*gb),[],"delivered:test"), "SQLite critical escalation")
    try test(try !transition(300,40*gb,r(201,14*gb),[]), "SQLite recovery clears acknowledged state")
    try test(try transition(400,24*gb,r(300,40*gb),[],"unavailable:denied"), "SQLite recovery rearms and denied delivery stays pending")
    try test(try !transition(500,24*gb,r(400,24*gb),[]), "SQLite failed retry rate limit")
    try test(try transition(2200,24*gb,r(500,24*gb),[],"delivered:test"), "SQLite failed notification retries after cooldown")
    try test(try !transition(4000,24*gb,r(2200,24*gb),[]), "SQLite successful retry deduplicates")
    try test(try transition(4001,24*gb,nil,[],nil,"new-container"), "SQLite container change resets baseline")
    let plist = agentPlist("/Users/test/Applications/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor", "/Users/test/Library/Application Support/MacBook Storage Monitor")
    let serialized = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    let parsed = try PropertyListSerialization.propertyList(from: serialized, format: nil) as! [String: Any]
    try test(parsed["StartInterval"] == nil && parsed["RunAtLoad"] as? Bool == true, "single calendar schedule and login startup")
    try test((parsed["StartCalendarInterval"] as? [[String:Int]]) == [["Minute":0],["Minute":30]], "calendar wake catch-up")
    try test((parsed["ProgramArguments"] as? [String])?.count == 4, "LaunchAgent absolute executable/data arguments with spaces")
    let lockPath = folder.appendingPathComponent("lock").path
    let a = open(lockPath,O_RDWR|O_CREAT,0o600), b = open(lockPath,O_RDWR,0o600)
    defer { close(a); close(b) }; _ = flock(a,LOCK_EX|LOCK_NB)
    try test(flock(b,LOCK_EX|LOCK_NB) != 0, "overlapping check lock")
    let timed = try run("/bin/sleep", ["2"], timeout: 0.1, cap: 16)
    try test(timed.timedOut, "subprocess deadlines enforced")
    try test(timed.data.isEmpty && timed.errors.isEmpty && !timed.truncated, "a deadline before producer output remains a valid bounded capture")
    let streams = try run("/usr/bin/du", ["-k", "-s", folder.appendingPathComponent("missing").path, folder.path], cap: 16)
    try test(!streams.data.isEmpty && !streams.errors.isEmpty && streams.truncated, "noisy stderr cannot displace directory-size stdout")
    let continuous = try selfTestContinuousOutput()
    try test(continuous.timedOut && continuous.truncated && continuous.data.count == 16, "continuous output cannot starve deadline or exceed capture cap (timedOut=\(continuous.timedOut), truncated=\(continuous.truncated), bytes=\(continuous.data.count))")
    try test(kill(continuous.pid, 0) == -1 && errno == ESRCH, "continuous-output subprocess is terminated and reaped")
    try test(kill(timed.pid, 0) == -1 && errno == ESRCH, "timed-out subprocess is terminated and reaped, not orphaned")

    // Truncated property lists are refused, never parsed as partial documents.
    let plistFile = folder.appendingPathComponent("volumes.plist")
    try PropertyListSerialization.data(fromPropertyList: ["Containers": (0..<200).map { ["Index": $0, "Name": "Volume \($0)"] }], format: .xml, options: 0).write(to: plistFile)
    let clipped = try run("/bin/cat", [plistFile.path], cap: 512)
    try test(clipped.truncated && (try? completePlist(clipped)) == nil, "truncated APFS plist output is rejected")
    try test((try? completePlist(try run("/bin/cat", [plistFile.path]))) != nil, "complete APFS plist output parses")

    // Directory measurement: exact totals, permission limits, deadlines, caps.
    let tree = folder.appendingPathComponent("tree")
    try privateDirectory(tree.appendingPathComponent("nested"))
    try Data(count: 1000).write(to: tree.appendingPathComponent("a.bin")); try Data(count: 2345).write(to: tree.appendingPathComponent("nested/b.bin"))
    let complete = measureDirectory(DirectoryTarget(source: "test", label: "tree", path: tree.path), budget: 5)
    try test(complete.status == .complete && complete.logical == 3345 && complete.files == 2, "complete directory measurement is exact")
    try test(complete.duration > 0 && (complete.json["duration_ms"] as? Int) != nil, "directory measurement records its duration")
    var lockedPaths = [String]()
    for index in 0..<12 {
        let locked = tree.appendingPathComponent("protected-\(index)")
        try privateDirectory(locked); try Data(count: 10).write(to: locked.appendingPathComponent("hidden.bin"))
        _ = chmod(locked.path, 0); lockedPaths.append(locked.path)
    }
    defer { for path in lockedPaths { _ = chmod(path, 0o700) } }
    let refused = measureDirectory(DirectoryTarget(source: "test", label: "tree", path: tree.path), budget: 5)
    try test(refused.status == .partial && refused.permission.count == 12 && refused.logical == 3345, "permission refusals make a usable partial lower bound")
    try test(refused.permission.examples.count == 3, "repeated permission refusals are aggregated (12 counted, 3 examples kept)")
    try test((refused.json["permission_denied"] as? [String: Any])?["count"] as? Int == 12, "permission count is persisted, not raw error text")
    let many = folder.appendingPathComponent("many"); try privateDirectory(many)
    for index in 0..<300 { fm.createFile(atPath: many.appendingPathComponent("\(index)").path, contents: Data([1])) }
    let expired = measureDirectory(DirectoryTarget(source: "test", label: "many", path: many.path), budget: 0.000_001)
    try test(expired.status == .timedOut, "directory time budget marks the measurement incomplete")
    let capped = measureDirectory(DirectoryTarget(source: "test", label: "many", path: many.path), budget: 5, maxEntries: 10)
    try test(capped.status == .partial && capped.limit != nil, "entry cap marks the measurement incomplete")
    try test(measureDirectory(DirectoryTarget(source: "test", label: "missing", path: folder.appendingPathComponent("absent").path), budget: 5).status == .absent, "absent optional location is not an error")
    try test(measureDirectory(DirectoryTarget(source: "test", label: "late", path: tree.path), budget: 0).status == .skipped, "exhausted total budget skips instead of blocking")

    // Swap allocation and usage come from sysctl as exact bytes.
    let swap = swapObservation()
    let allocated = swap["allocated_bytes"] as? Int64 ?? -1, used = swap["used_bytes"] as? Int64 ?? -1
    try test(swap["status"] as? String == "complete" && allocated >= used && used >= 0, "swap allocation and usage are separate exact values")
    try test(vmObservation()["status"] as? String == "complete", "VM counters collected in-process")

    // A whole snapshot stays small, fast and subprocess-free.
    let before = subprocessCount, clock = Date()
    let reading = Reading(timestamp: Date().timeIntervalSince1970, container: "test", free: 50*gb, used: 195*gb, volumes: "[{\"APFSVolumeUUID\":\"v\",\"Name\":\"Data\",\"CapacityInUse\":1,\"Roles\":[\"Data\"]}]")
    let snapshot = diagnosticSnapshot(reading, targets: [DirectoryTarget(source: "test", label: "tree", path: tree.path), DirectoryTarget(source: "test", label: "missing", path: folder.appendingPathComponent("absent").path)])
    let elapsed = Date().timeIntervalSince(clock)
    let parsed2 = (try? JSONSerialization.jsonObject(with: Data(snapshot.utf8))) as? [String: Any] ?? [:]
    try test(subprocessCount == before && elapsed < 3, "diagnostic snapshot launches no subprocesses and finishes quickly (\(String(format: "%.2f", elapsed)) s)")
    try test(parsed2["schema_version"] as? Int == 2 && (parsed2["directories"] as? [Any])?.count == 1 && snapshot.utf8.count < 16_384, "snapshot is structured, omits absent locations, and stays small")
    try test(!snapshot.contains("Operation not permitted") && !snapshot.contains("<?xml"), "snapshot contains no raw error dumps or XML")
    let defaults = defaultDirectoryTargets().map(\.path)
    try test(!defaults.contains("/private/var/folders") && !defaults.contains(home.path) && !defaults.contains(home.appendingPathComponent("Library/Caches").path) && !defaults.contains(home.appendingPathComponent("Library/Application Support").path), "no broad protected or whole-library scan targets")
    try attributionSelfTest(test)
    try baselineInitializationSelfTest(test)
    try coverageSelfTest(test)
    try inventorySelfTest(test)
    try installSelfTest(test)
    print("\(count) tests passed")
}

@MainActor func runMain() async throws {
    umask(0o077)
    if try await runLifecycleQACommand(arguments: CommandLine.arguments) { return }
    if CommandLine.arguments.contains("--qa-runtime-root") || CommandLine.arguments.contains(where: { $0.hasPrefix("--qa-") }) {
        try await runNativeQAWorker(arguments: CommandLine.arguments); return
    }
    var args = Array(CommandLine.arguments.dropFirst()), directory = defaultData
    if let i = args.firstIndex(of: "--data-dir") { try required(args.count > i+1, "--data-dir requires an absolute path"); try required(args[i+1].hasPrefix("/"), "--data-dir must be absolute"); directory = URL(fileURLWithPath: args[i+1]); args.removeSubrange(i...i+1) }
    let command = args.first ?? "help"
    if ["check", "diagnose", "initialize-baseline", "coverage-probe", "attribution-probe"].contains(command) { applyObservationalIOPolicy() }
    let limit = min(1000,max(1,Int(args.dropFirst().first ?? "10") ?? 10))
    do { try await runCommand(command, args: args, directory: directory, limit: limit) }
    catch {
        // launchd discards stderr: record background failures where they can be found (D10).
        if command.hasPrefix("inventory-") || command == "initialize-baseline" { logBackgroundFailure(directory, command: command, error: error) }
        throw error
    }
}

/// One `monitor.log` line for a failed background command, with the home folder shown as "~".
func logBackgroundFailure(_ directory: URL, command: String, error: Error) {
    let message = String(describing: error).replacingOccurrences(of: home.path, with: "~")
    log(directory, "ERROR \(command) failed: \(message.prefix(512))")
}

@MainActor private func runCommand(_ command: String, args: [String], directory: URL, limit: Int) async throws {
    switch command {
    case let value where value.hasPrefix("inventory-"):
        try await inventoryCommand(value, args: args, directory: directory)
    case "check": try check(directory, retryNotifications: args.contains("--retry-notifications"))
    case "diagnose": try check(directory, forceDiagnostics: true)
    case "status", "history", "alerts", "diagnostics", "attribution": try show(directory,command,limit)
    case "install": for note in try install() { print(note) }; print("Low-space notifications: allowed only if macOS permits them for MacBook Storage Monitor. Permission given to an earlier version carries over; Settings shows the current state (command line: authorize).")
    case "uninstall": for note in try uninstall() { print(note) }
    case "authorize":
        if Bundle.main.bundleURL.standardizedFileURL != installedApp.standardizedFileURL || ProcessInfo.processInfo.environment["STORAGE_MONITOR_AUTH_IN_APP"] == nil {
            try required(fm.fileExists(atPath: installedApp.path), "Install first")
            let r = try run("/usr/bin/open", ["-W", "-n", installedApp.path, "--args", "authorize-in-app"], timeout: 125)
            try required(r.status == 0, "Could not launch notification authorization app: \(r.text)")
            print(notificationStatus().1)
        } else { try authorize() }
    case "authorize-in-app": try authorize()
    case "test-notification":
        let r = try measure(); let result = notify("Storage Monitor TEST", "\(size(r.free)) free; change 0.00 GB (test); severity TEST.")
        print(result); try required(result.hasPrefix("delivered:"), "Test notification was not confirmed delivered: \(result)")
    case "notification-status": print(notificationStatus().1)
    case "self-test":
        if args.contains("--inventory") {
            var count = 0
            try inventorySelfTest { value, description in try required(value, "FAIL: \(description)"); count += 1; print("PASS \(description)") }
            print("\(count) inventory tests passed")
        } else if args.contains("--coverage") {   // only the comprehensive coverage tests
            var count = 0
            try coverageSelfTest { value, description in try required(value, "FAIL: \(description)"); count += 1; print("PASS \(description)") }
            print("\(count) tests passed")
        } else { try selfTest() }
    case "initialize-baseline":
        // Background, one worker at a time, checkpointed; never notifies.
        try privateDirectory(directory)
        if coverageMode(directory) == "comprehensive", let region = startupDataRegion(try? measure()).region {
            let result = initializeCoverage(dbPath: directory.appendingPathComponent("history.sqlite3").path, directory: directory, region: region)
            let l = result.lifecycle
            let summary = "initialize-baseline comprehensive \(result.outcome) state=\(l?.state ?? "?") units=\(l?.units ?? 0) baselined=\(l?.baselined ?? 0) discovered=\(l?.discovered ?? 0) pending=\(l?.pending ?? 0) inaccessible=\(l?.inaccessible ?? 0) excluded=\(l?.excluded ?? 0) deferred=\(l?.deferred ?? 0) measurements=\(l?.initializer?.measurements ?? 0) reconciliations=\(l?.initializer?.reconciliations ?? 0) fda=\(l?.fullDiskAccess ?? "?") peakMB=\((l?.initializer?.peakMemoryBytes ?? 0) / 1_048_576) seconds=\(Int((l?.initializer?.finishedAt ?? Date().timeIntervalSince1970) - (l?.initializer?.startedAt ?? Date().timeIntervalSince1970)))"
            log(directory, summary); print(summary)
            if !["terminal", "already_running"].contains(result.outcome) { exit(75) }
            return
        }
        let result = initializeBaseline(dbPath: directory.appendingPathComponent("history.sqlite3").path, directory: directory, roots: defaultMonitoredRoots() + configuredRoots(directory))
        let l = result.lifecycle
        let summary = "initialize-baseline \(result.outcome) state=\(l?.state ?? "?") discovered=\(l?.discovered ?? 0) baselined=\(l?.baselined ?? 0) pending=\(l?.pending ?? 0) incomplete=\(l?.incomplete ?? 0) unavailable=\(l?.unavailable ?? 0) measurements=\(l?.initializer?.measurements ?? 0) reconciliations=\(l?.initializer?.reconciliations ?? 0) peakMB=\((l?.initializer?.peakMemoryBytes ?? 0) / 1_048_576)"
        log(directory, summary); print(summary)
        if !["terminal", "already_running"].contains(result.outcome) { exit(75) }   // launchd resumes after its throttle interval
    case "stress-state-writes":
        // Test helper: initializer-style state writes to the given database.
        let db = try Database(args[1]); let count = Int(args[2]) ?? 100; var failures = 0
        let payload = String(repeating: "x", count: 60_000)
        for index in 0..<count { do { try db.state("attribution_baseline", "{\"n\":\(index),\"pad\":\"\(payload)\"}") } catch { failures += 1 } }
        print("failures=\(failures)")
    case "baseline-status":
        let db = try Database(directory.appendingPathComponent("history.sqlite3").path)
        print(decodeLifecycle(db).map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? "{\"state\":\"not_initialized\"}")
    case "coverage-status":
        // Current comprehensive coverage, its limits, and how to widen it. Read-only.
        let db = try Database(directory.appendingPathComponent("history.sqlite3").path)
        print(decodeCoverageLifecycle(db).map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? "{\"state\":\"not_initialized\"}")
        for row in try db.rows("SELECT timestamp, reading_id, scope, detail FROM coverage_epochs ORDER BY id") { print("epoch \(iso(Double(row["timestamp"] ?? "") ?? 0)) reading=\(row["reading_id"] ?? "-") \(row["scope"] ?? "") \(row["detail"] ?? "")") }
        if args.contains("--units") {
            let states = args.drop(while: { $0 != "--units" }).dropFirst().prefix(1)
            for row in try db.rows("SELECT path, kind, state, reason, agg_allocated, entries FROM coverage_units" + (states.isEmpty ? "" : " WHERE state=?") + " ORDER BY path", states.map { $0 as Any }) {
                print("\(row["state"] ?? "")\t\(row["kind"] ?? "")\t\(row["agg_allocated"] ?? "0")\t\(row["reason"] ?? "-")\t/\(row["path"] ?? "")")
            }
        }
        if fullDiskAccessState() != "granted" { print(fullDiskAccessGuidance) }
    case "coverage-probe":
        // Development aid: comprehensive evidence only, into a separate --data-dir. No reading, alert, or notification.
        try required(directory != defaultData, "coverage-probe needs a separate --data-dir")
        try privateDirectory(directory)
        let db = try Database(directory.appendingPathComponent("history.sqlite3").path)
        let rootArg = args.firstIndex(of: "--root").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        guard let region = rootArg.map({ coverageRegion(root: $0) }) ?? startupDataRegion(nil).region else { throw Failure("No coverage region") }
        let cursor = decodeState(db, "coverage_cursor", as: CoverageCursor.self)
        let id = (cursor?.readingId ?? 0) + 1, now = Date().timeIntervalSince1970
        let clock = Date()
        guard let evidence = collectCoverageEvidence(db: db, readingId: id, readingTime: now, previous: cursor.map { (id: $0.readingId, time: $0.timestamp) }, marker: currentEventMarker(region.root), region: region, lockPath: directory.appendingPathComponent("attribution.lock").path) else { print("Coverage not established; run initialize-baseline with this --data-dir first."); return }
        try db.write("INSERT OR REPLACE INTO interval_evidence(reading_id,timestamp,evidence) VALUES(?,?,?)", [id, now, json(evidence)])
        print(args.contains("--summary") ? json(["folders": (evidence["folders"] as? [String: Any] ?? [:]).filter { ["status", "measured", "carried", "pending", "first_measurements", "changes_total", "incomparable_total", "method"].contains($0.key) }, "coverage": (evidence["coverage"] as? [String: Any] ?? [:]).filter { ["level", "units", "monitored", "inaccessible", "excluded", "pending"].contains($0.key) }, "events": (evidence["file_activity"] as? [String: Any])?["events"] ?? 0, "seconds": Date().timeIntervalSince(clock), "peakMB": peakMemoryBytes() / 1_048_576]) : json(evidence))
    case "attribution-probe":
        // Development aid: evidence collection only, into a separate --data-dir.
        // No capacity reading, alert, or notification.
        try required(directory != defaultData, "attribution-probe needs a separate --data-dir")
        try privateDirectory(directory)
        let db = try Database(directory.appendingPathComponent("history.sqlite3").path)
        let prior = decodeState(db, "attribution_baseline", as: AttributionBaseline.self)
        let id = (prior?.readingId ?? 0) + 1, now = Date().timeIntervalSince1970
        let evidence = collectIntervalEvidence(db: db, readingId: id, readingTime: now, previous: prior.map { (id: $0.readingId, time: $0.timestamp) }, marker: currentEventMarker(), roots: defaultMonitoredRoots() + configuredRoots(directory))
        try db.write("INSERT OR REPLACE INTO interval_evidence(reading_id,timestamp,evidence) VALUES(?,?,?)", [id, now, json(evidence)])
        print(json(evidence))
    default: print("MacBook Storage Monitor\nCommands: install | uninstall | check | diagnose | status | history [count] | alerts [count] | diagnostics [count] | attribution [count] | initialize-baseline | baseline-status | coverage-status [--units [state]] | authorize | notification-status | test-notification | self-test\nInventory: inventory-status | inventory-children [node-id] | inventory-largest files|directories|all | inventory-search prefix | inventory-request [--path /absolute/path] | inventory-cancel | inventory-resume | inventory-initialize | inventory-update | inventory-work\nInventory query options: --limit 1..256 --offset N --under node-id\nInventory worker options: --budget seconds --batch 1..256; --root /absolute/path requires isolated data\nOptional: --data-dir /absolute/private/path\nThresholds use decimal GB: 3 GB/check, 5 GB/2h, low <25 GB, critical <15 GB. Monitoring never deletes user files or changes system settings.")
    }
}
#if !INVENTORY_TESTS
@main enum StorageMonitorEntry {
    static func main() async { do { try await runMain() } catch { fputs("Storage Monitor: \(error)\n", stderr); exit(1) } }
}
#endif
