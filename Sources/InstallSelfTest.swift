import Foundation
import Darwin
import SQLite3

// Background-monitoring installation, verified against an isolated home with a recording
// launch control: no real LaunchAgent, launchd job or user database is touched.
func installSelfTest(_ test: (Bool, String) throws -> Void) throws {
    let root = monitorSelfTestFixture("install")
    defer { finishMonitorSelfTestFixture(root) }
    let layout = MonitorInstallLayout(home: root.appendingPathComponent("home"))
    try test(!layout.home.path.hasPrefix(fm.homeDirectoryForCurrentUser.path) && layout.agents.allSatisfy { $0.url.path.hasPrefix(root.path) },
             "install verification uses an isolated home, never the real LaunchAgents")

    // The helper as bundled inside the app on a mounted disk image.
    func helper(_ version: String, executable: Bool = true) throws -> URL {
        let app = root.appendingPathComponent("Volumes/Storage Monitor \(version)/Storage Monitor.app/Contents/Helpers/MacBook Storage Monitor.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        if executable {
            let binary = app.appendingPathComponent("Contents/MacOS/StorageMonitor")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary); _ = chmod(binary.path, 0o755)
        }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": label, "CFBundleShortVersionString": version], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    func installedVersion() -> String? {
        (NSDictionary(contentsOf: layout.app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }
    func agentFiles() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: layout.home.appendingPathComponent("Library/LaunchAgents").path)) ?? []).sorted()
    }

    // Existing history must survive installation and updates.
    try privateDirectory(layout.data)
    let history = layout.data.appendingPathComponent("history.sqlite3").path
    do { let db = try Database(history); try db.write("INSERT INTO readings(id,timestamp,container,free,used,volumes) VALUES (9,1,'keep',2,3,'[]')") }

    var calls = [[String]]()
    let notes = try install(layout: layout, source: try helper("1.0.0")) { arguments, _ in calls.append(arguments) }
    let plists = layout.agents.map { NSDictionary(contentsOf: $0.url) as? [String: Any] ?? [:] }
    let programs = plists.map { $0["ProgramArguments"] as? [String] ?? [] }
    try test(agentFiles() == [baselineLabel, label, inventoryLabel].map { $0 + ".plist" }.sorted(), "install writes exactly the three per-user LaunchAgents")
    try test(programs.allSatisfy { $0.first == layout.executable && $0.suffix(2) == ["--data-dir", layout.data.path] },
             "every agent runs the stable installed copy in ~/Applications with the user's data directory")
    try test(plists.allSatisfy { !String(describing: $0).contains("/Volumes/") }, "agents never reference the disk image or the app's install location")
    try test(plists.allSatisfy { $0["RunAtLoad"] as? Bool == true && $0["ProcessType"] as? String == "Background" }, "agents start at login with background priority")
    let inventoryAgent = plists[2], inventoryProgram = programs[2]
    try test(inventoryProgram.dropFirst().prefix(3) == ["inventory-work", "--budget", String(inventoryAgentBudget)] && (inventoryAgent["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false]
             && (inventoryAgent["WatchPaths"] as? [String]) == [layout.data.appendingPathComponent("inventory-requests").path] && inventoryAgent["StartInterval"] == nil && inventoryAgent["StartCalendarInterval"] == nil,
             "inventory agent: verified \(inventoryAgentBudget) s slices, relaunched only after a non-zero exit, woken by viewer requests; no polling interval of its own")
    try test(fm.isExecutableFile(atPath: layout.executable) && installedVersion() == "1.0.0", "the bundled helper is copied to ~/Applications with its executable")
    let domain = "gui/\(getuid())"
    try test(Array(calls.prefix(3)).allSatisfy { $0.first == "bootout" } && calls.dropFirst(3).map(\.first!) == Array(repeating: ["enable", "bootstrap", "print"], count: 3).flatMap { $0 }
             && calls.filter { $0.first == "bootstrap" }.allSatisfy { $0.count == 3 && $0[1] == domain },
             "existing agents are booted out before the executable is replaced, then each is enabled, bootstrapped and confirmed loaded in the user's GUI domain")
    func dataFiles() -> [String] { ((try? fm.contentsOfDirectory(atPath: layout.data.path)) ?? []).sorted() }
    try test(notes.contains { $0.contains("migrated the history schema") } && dataFiles().filter { $0.hasPrefix("history.pre-update-") }.count == 1 && !dataFiles().contains("install-transaction"),
             "a first install whose migration changes the schema keeps exactly one pre-update snapshot and no transaction leftovers")

    // An app update reinstalls in place without duplicate agents or leftovers.
    calls.removeAll()
    _ = try install(layout: layout, source: try helper("1.1.0")) { arguments, _ in calls.append(arguments) }
    let leftovers = ((try? fm.contentsOfDirectory(atPath: layout.app.deletingLastPathComponent().path)) ?? []).filter { $0.contains("staging") }
    try test(installedVersion() == "1.1.0" && agentFiles().count == 3 && leftovers.isEmpty && calls.filter { $0.first == "bootstrap" }.count == 3,
             "updating replaces the installed helper in place with no duplicate agents or staging leftovers")
    let preserved = try Database(history).rows("SELECT container FROM readings WHERE id=9").first?["container"]
    try test(preserved == "keep", "installation and update preserve monitoring history")
    let ordinary = try install(layout: layout, source: try helper("1.1.1")) { _, _ in }
    try test(ordinary.contains { $0.contains("no backup was needed") } && dataFiles().filter { $0.contains("pre-update") || $0.contains("install-backup") || $0.contains("snapshot") }.count == 1,
             "an ordinary update (no schema change) copies no history: its constant-time snapshot is discarded and no backup is added")
    let cloneTarget = root.appendingPathComponent("clone-check.sqlite3")
    try test((try snapshotDatabase(URL(fileURLWithPath: history), to: cloneTarget)) == "clone" && (try schemaFingerprint(cloneTarget.path)) == (try schemaFingerprint(history)),
             "on APFS the pre-update snapshot is a clone of a committed database state, not a full copy")

    // Setup failures surface clearly and leave history intact.
    var failed = ""
    do {
        _ = try install(layout: layout, source: try helper("1.2.0")) { arguments, _ in
            if arguments.first == "bootstrap" { throw Failure("launchctl bootstrap failed: Input/output error") }
        }
    } catch { failed = String(describing: error) }
    try test(failed.contains("bootstrap failed") && failed.contains("restored") && (try Database(history).rows("SELECT COUNT(*) AS n FROM readings WHERE id=9").first?["n"]) == "1",
             "a launchd registration failure is reported, not swallowed, and history is retained")
    func strayFiles() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: layout.app.deletingLastPathComponent().path)) ?? []).filter { $0.contains("staging") || $0.contains("previous") }
            + (fm.fileExists(atPath: layout.transaction.path) ? ["install-transaction"] : [])
    }
    try test(installedVersion() == "1.1.1" && agentFiles().count == 3 && strayFiles().isEmpty, "after the failed update the previous helper and its agents are back in place, with no leftovers")

    // A failure at every phase rolls back to the exact previous installation.
    for phase in InstallJournal.Phase.allCases where phase != .begun {
        var registered = [[String]]()
        var message = ""
        do { _ = try install(layout: layout, source: try helper("1.3.0"), control: { arguments, _ in registered.append(arguments) }, fault: { if $0 == phase { throw Failure("injected at \(phase.rawValue)") } }) }
        catch { message = String(describing: error) }
        let reRegistered = registered.reversed().prefix(6).filter { $0.first == "bootstrap" }.count
        try test(message.contains("injected at \(phase.rawValue)") && message.contains("restored") && installedVersion() == "1.1.1" && agentFiles().count == 3 && strayFiles().isEmpty
                 && reRegistered == 3 && (try Database(history).rows("SELECT container FROM readings WHERE id=9").first?["container"]) == "keep",
                 "a failure after '\(phase.rawValue)' restores the previous helper, re-registers its agents and keeps history")
    }

    // An update killed mid-way (no rollback ran) is reverted by the next install or uninstall. A
    // dropped index makes this update's migration change the schema.
    try Database(history).exec("DROP INDEX IF EXISTS inventory_nodes_name")
    let beforeKill = try schemaFingerprint(history)
    do { _ = try install(layout: layout, source: try helper("1.4.0"), control: { _, _ in }, fault: { if $0 == .migrated { throw Failure("killed") } }, rollbackOnFailure: false) } catch {}
    try test(fm.fileExists(atPath: layout.journal.path) && installedVersion() == "1.4.0" && (try schemaFingerprint(history)) != beforeKill,
             "a killed update leaves its durable journal, the new helper and a migrated schema")
    let reverted = try recoverInterruptedInstall(layout: layout) { _, _ in }
    try test(reverted.first == "Reverted an interrupted update." && installedVersion() == "1.1.1" && (try schemaFingerprint(history)) == beforeKill && agentFiles().count == 3 && strayFiles().isEmpty
             && (try Database(history).rows("SELECT container FROM readings WHERE id=9").first?["container"]) == "keep",
             "recovery restores the previous helper, its agents and the pre-migration database from the snapshot")
    do { _ = try install(layout: layout, source: try helper("1.5.0"), control: { _, _ in }, fault: { if $0 == .registered { throw Failure("killed") } }, rollbackOnFailure: false) } catch {}
    let completed = try recoverInterruptedInstall(layout: layout) { _, _ in }
    try test(completed.first == "Completed an interrupted update." && installedVersion() == "1.5.0" && strayFiles().isEmpty && dataFiles().filter { $0.hasPrefix("history.pre-update-") }.count == 1,
             "an update killed after its agents were registered is completed, never rolled back over newer writes")
    // Once an agent has started it may write history: neither a failed registration nor a kill
    // during registration may restore the snapshot over those writes (migrations are additive).
    for kill in [false, true] {
        try Database(history).exec("DROP INDEX IF EXISTS inventory_nodes_name")
        var bootstraps = 0
        let agentWrites: LaunchControl = { arguments, _ in
            guard arguments.first == "bootstrap" else { return }
            bootstraps += 1
            if bootstraps == 1 { try Database(history).write("INSERT INTO readings(id,timestamp,container,free,used,volumes) VALUES (\(kill ? 21 : 20),2,'written-by-started-agent',2,3,'[]')") }
            else { throw Failure("launchctl bootstrap failed: Input/output error") }
        }
        var message = ""
        do { _ = try install(layout: layout, source: try helper("1.7.0"), control: agentWrites, rollbackOnFailure: !kill) } catch { message = String(describing: error) }
        if kill { _ = try recoverInterruptedInstall(layout: layout) { _, _ in } }
        let survived = try Database(history).rows("SELECT container FROM readings WHERE id=\(kill ? 21 : 20)").first?["container"]
        try test(message.contains("bootstrap failed") && survived == "written-by-started-agent" && installedVersion() == "1.5.0" && strayFiles().isEmpty
                 && dataFiles().contains { $0.hasPrefix("history.pre-update-") },
                 kill ? "an update killed after an agent started keeps that agent's writes on recovery, restores the previous helper and keeps the snapshot aside"
                      : "a registration failure after an agent started keeps that agent's writes, restores the previous helper and keeps the snapshot aside")
    }

    // A WAL-mode database is copied, never cloned: its committed pages may live only in -wal.
    let walPath = root.appendingPathComponent("wal.sqlite3").path
    var walDB: OpaquePointer?
    _ = sqlite3_open(walPath, &walDB)
    _ = sqlite3_exec(walDB, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t(v); INSERT INTO t VALUES ('committed-in-wal');", nil, nil, nil)
    let walSnapshot = root.appendingPathComponent("wal-snapshot.sqlite3")
    let walMethod = try snapshotDatabase(URL(fileURLWithPath: walPath), to: walSnapshot)
    sqlite3_close(walDB)
    var copied: OpaquePointer?, row: OpaquePointer?
    _ = sqlite3_open_v2(walSnapshot.path, &copied, SQLITE_OPEN_READONLY, nil)
    let walRow = sqlite3_prepare_v2(copied, "SELECT v FROM t", -1, &row, nil) == SQLITE_OK && sqlite3_step(row) == SQLITE_ROW ? sqlite3_column_text(row, 0).map { String(cString: $0) } : nil
    sqlite3_finalize(row); sqlite3_close(copied)
    try test(walMethod == "copy" && walRow == "committed-in-wal", "a WAL-mode database is snapshotted through the backup API, including commits still in its -wal file")

    do { _ = try install(layout: layout, source: try helper("1.6.0"), control: { _, _ in }, fault: { if $0 == .swapped { throw Failure("killed") } }, rollbackOnFailure: false) } catch {}
    let viaUninstall = try uninstall(layout: layout) { _, _ in }
    try test(viaUninstall.first == "Reverted an interrupted update." && installedVersion() == "1.5.0" && agentFiles().isEmpty && strayFiles().isEmpty,
             "disabling after an interrupted update first reverts it, then removes the agents")
    _ = try install(layout: layout, source: try helper("1.5.0")) { _, _ in }

    // Duplicate agents for this monitor's labels (for example from an old build) are replaced.
    let stale = layout.home.appendingPathComponent("Library/LaunchAgents/com.example.old-storage-monitor.plist")
    try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": ["/Volumes/Old Storage Monitor/StorageMonitor", "check"]], format: .xml, options: 0).write(to: stale)
    let unrelated = layout.home.appendingPathComponent("Library/LaunchAgents/com.example.other.plist")
    try PropertyListSerialization.data(fromPropertyList: ["Label": "local.macbook.storage-monitor.inventory-qa", "ProgramArguments": ["/tmp/qa"]], format: .xml, options: 0).write(to: unrelated)
    try test(layout.duplicateAgents == [stale], "a differently named agent carrying this monitor's label is detected as a duplicate; other labels are not")
    _ = try install(layout: layout, source: try helper("1.5.0")) { _, _ in }
    try test(!fm.fileExists(atPath: stale.path) && fm.fileExists(atPath: unrelated.path) && agentFiles().count == 4, "install removes duplicate agents and leaves unrelated agents alone")
    try fm.removeItem(at: unrelated)
    var missing = ""
    do { _ = try install(layout: layout, source: try helper("2.0.0", executable: false)) { _, _ in } } catch { missing = String(describing: error) }
    try test(missing.contains("missing its executable"), "a helper bundle without its executable is refused with a clear error")
    var notBundle = ""
    do { _ = try install(layout: layout, source: root.appendingPathComponent("StorageMonitor")) { _, _ in } } catch { notBundle = String(describing: error) }
    try test(!notBundle.isEmpty, "installation from a bare executable outside an app bundle is refused")

    // Scheduled maintenance: each check wakes an idle worker without restarting a running one.
    try test(scheduledInventoryWake(directory: layout.data, layout: layout) == ["kickstart", "gui/\(getuid())/\(inventoryLabel)"],
             "after an idle exit the next scheduled check wakes the inventory worker (kickstart without -k cannot restart or overlap a running worker)")
    try test(scheduledInventoryWake(directory: root.appendingPathComponent("other-data"), layout: layout) == nil, "checks against another data directory never wake the installed worker")

    // Disabling removes every agent and keeps the app copy and history.
    calls.removeAll()
    _ = try uninstall(layout: layout) { arguments, _ in calls.append(arguments) }
    try test(agentFiles().isEmpty && calls.count == 3 && calls.allSatisfy { $0.first == "bootout" }, "disabling boots out and removes all three agents")
    try test(scheduledInventoryWake(directory: layout.data, layout: layout) == nil, "with background monitoring disabled no check wakes the inventory worker")
    try test(fm.fileExists(atPath: history) && fm.fileExists(atPath: layout.app.path), "disabling retains history and the installed helper")
    _ = try uninstall(layout: layout) { _, _ in }
    try test(agentFiles().isEmpty, "disabling twice is harmless")

    // D10: right after an in-place update launchd starts every agent at once. A worker that starts while
    // the check holds the write lock must wait and finish (exit 0), and any failure must be logged.
    if let executable = Bundle.main.executablePath {
        let fixture = root.appendingPathComponent("startup-root"), state = root.appendingPathComponent("startup-state")
        for index in 0..<20 { try fm.createDirectory(at: fixture.appendingPathComponent("d\(index)"), withIntermediateDirectories: true); try Data([1]).write(to: fixture.appendingPathComponent("d\(index)/f")) }
        let first = try run(executable, ["inventory-work", "--root", fixture.path, "--data-dir", state.path, "--budget", "30"], timeout: 120)
        let database = state.appendingPathComponent("history.sqlite3").path
        let locked = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            if let other = try? Database(database), (try? other.exec("BEGIN IMMEDIATE")) != nil {
                try? other.write("INSERT OR REPLACE INTO state VALUES ('lock-holder','check')")
                locked.signal(); Thread.sleep(forTimeInterval: 4); try? other.exec("COMMIT")
            } else { locked.signal() }
            released.signal()
        }
        locked.wait()
        let contended = try run(executable, ["inventory-work", "--root", fixture.path, "--data-dir", state.path, "--budget", "30"], timeout: 120)
        released.wait()
        let failing = try run(executable, ["inventory-work", "--root", root.appendingPathComponent("missing").path, "--data-dir", state.path], timeout: 60)
        let logText = (try? String(contentsOf: state.appendingPathComponent("monitor.log"), encoding: .utf8)) ?? ""
        try test(first.status == 0 && contended.status == 0 && logText.components(separatedBy: "\n").filter { $0.contains(" inventory {") }.count >= 2,
                 "a worker started while another process holds the history write lock waits and completes (exit \(contended.status)), as after an in-place update")
        try test(failing.status != 0 && logText.contains("ERROR inventory-work failed:") && !logText.contains(home.path),
                 "a failed background worker writes one ERROR line to monitor.log (stderr goes to /dev/null), with the home folder shown as ~")
    }

    // Quarantine is detected for reporting, never removed.
    let marked = root.appendingPathComponent("quarantined.app")
    try fm.createDirectory(at: marked, withIntermediateDirectories: true)
    let value = "0081;00000000;Safari;"
    _ = value.withCString { setxattr(marked.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    try test(isQuarantined(marked) && !isQuarantined(layout.app), "a quarantined (downloaded) helper is detected so setup can explain Gatekeeper")
}
