import Foundation
import SQLite3

/// Background monitoring as seen from the desktop app. Read-only evaluation of the user's
/// LaunchAgents; changes happen only when the person explicitly asks, by running the bundled
/// background monitor's own `install`, `uninstall` or `authorize` command.
/// What macOS allows the background monitor to post, as the monitor itself last read it at a
/// scheduled check (D7). The viewer cannot ask on the monitor's behalf: permission is per app.
enum NotificationPermission: Equatable {
    case unknown, allowed, notYetAllowed, turnedOff
    static func parse(_ detail: String?) -> Self {
        guard let detail else { return .unknown }
        if detail.contains("authorization=authorized") || detail.contains("authorization=provisional") { return .allowed }
        if detail.contains("authorization=denied") { return .turnedOff }
        if detail.contains("authorization=not_determined") { return .notYetAllowed }
        return .unknown
    }
    /// Reads the monitor's recorded state from its history database, read-only.
    static func recorded(home: URL) -> Self {
        let path = home.appendingPathComponent("Library/Application Support/MacBook Storage Monitor/history.sqlite3").path
        var db: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard FileManager.default.fileExists(atPath: path), sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key='notification_authorization'", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return .unknown }
        return parse(String(cString: text))
    }
    var text: String {
        switch self {
        case .allowed: return "Low-space notifications are allowed for the background monitor. Permission given to an earlier version carries over; change it in System Settings → Notifications → MacBook Storage Monitor."
        case .turnedOff: return "Low-space notifications are turned off in System Settings → Notifications → MacBook Storage Monitor."
        case .notYetAllowed: return "Low-space notifications are off until you allow them."
        case .unknown: return "Notification permission is read at the next background check."
        }
    }
    /// macOS shows its permission prompt only while the choice is undecided.
    var canPrompt: Bool { self == .notYetAllowed || self == .unknown }
}

struct MonitoringSetupStatus: Equatable {
    enum State: Equatable { case off, on, needsUpdate, incomplete }
    static let labels = ["local.macbook.storage-monitor", "local.macbook.storage-monitor.baseline", "local.macbook.storage-monitor.inventory"]
    let state: State
    let summary: String
    let installedVersion: String?
    let bundledVersion: String?
    /// The helper that performs changes: the copy bundled in this app, else the installed one.
    let helperExecutable: URL?
    let installedApp: URL
    var notifications: NotificationPermission = .unknown

    static func bundledHelper(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/Helpers/MacBook Storage Monitor.app") }

    static func evaluate(home: URL, bundledHelper: URL?, launchd: LaunchdState? = nil) -> MonitoringSetupStatus {
        let agents = labels.map { home.appendingPathComponent("Library/LaunchAgents/\($0).plist") }
        let present = agents.filter { FileManager.default.fileExists(atPath: $0.path) }
        let installedApp = home.appendingPathComponent("Applications/MacBook Storage Monitor.app")
        let installedVersion = version(of: installedApp), bundledVersion = bundledHelper.flatMap(version(of:))
        let bundledExecutable = bundledHelper.map { $0.appendingPathComponent("Contents/MacOS/StorageMonitor") }.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        let installedExecutable = installedApp.appendingPathComponent("Contents/MacOS/StorageMonitor")
        let helper = bundledExecutable ?? (FileManager.default.isExecutableFile(atPath: installedExecutable.path) ? installedExecutable : nil)
        let targets = present.compactMap { (NSDictionary(contentsOf: $0) as? [String: Any])?["ProgramArguments"] as? [String] }.compactMap(\.first)
        let interrupted = FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/MacBook Storage Monitor/install-transaction/journal.json").path)
        let duplicates = duplicateAgents(home: home)
        let loaded = launchd.map { Set(labels).intersection($0.loaded) } ?? []
        let notLoaded = launchd == nil ? [] : labels.filter { label in present.contains { $0.lastPathComponent == "\(label).plist" } && !loaded.contains(label) }
        let disabled = launchd.map { labels.filter($0.disabled.contains) } ?? []
        let state: State, summary: String
        if interrupted {
            state = .incomplete; summary = "An update of the background monitor was interrupted. Repair finishes or reverts it; your history is kept."
        } else if present.isEmpty && loaded.isEmpty && duplicates.isEmpty {
            state = .off; summary = "Background monitoring is off."
        } else if present.isEmpty {
            state = .incomplete; summary = "A background task is still registered with macOS without its configuration (\((Array(loaded) + duplicates.map(\.lastPathComponent)).sorted().joined(separator: ", "))). Repair or disable it."
        } else if present.count < agents.count || targets.count < present.count || !targets.allSatisfy({ FileManager.default.isExecutableFile(atPath: $0) }) {
            state = .incomplete
            summary = "Background monitoring is partly set up (\(present.count) of \(agents.count) background tasks, or a task points to a missing program). Repair or disable it."
        } else if !duplicates.isEmpty {
            state = .incomplete; summary = "A duplicate background task (\(duplicates.map(\.lastPathComponent).joined(separator: ", "))) runs this monitor from another file. Repair removes it."
        } else if targets.contains(where: { $0 != installedExecutable.path }) {
            state = .incomplete; summary = "A background task runs a different copy of the monitor than the one in ~/Applications. Repair points it at the installed copy."
        } else if !disabled.isEmpty {
            state = .incomplete; summary = "macOS has turned off \(disabled.count) of this monitor's background tasks (System Settings → General → Login Items). Repair turns them back on."
        } else if !notLoaded.isEmpty {
            state = .incomplete; summary = "\(notLoaded.count) of \(agents.count) background tasks are configured but not loaded by macOS, so they will not run. Repair registers them again."
        } else if let bundledVersion, bundledVersion != installedVersion {
            state = .needsUpdate
            summary = "The installed background monitor (\(installedVersion ?? "unknown version")) differs from this app (\(bundledVersion)). Update it to match."
        } else {
            state = .on
            summary = "Background monitoring is on. It checks free space at login and every 30 minutes." + (launchd == nil ? " (macOS did not report whether its tasks are loaded.)" : "")
        }
        var status = MonitoringSetupStatus(state: state, summary: summary, installedVersion: installedVersion, bundledVersion: bundledVersion, helperExecutable: helper, installedApp: installedApp)
        status.notifications = .recorded(home: home)
        return status
    }

    /// LaunchAgent files carrying one of this monitor's labels under another file name.
    static func duplicateAgents(home: URL) -> [URL] {
        let folder = home.appendingPathComponent("Library/LaunchAgents"), canonical = Set(labels.map { "\($0).plist" })
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().filter { $0.hasSuffix(".plist") && !canonical.contains($0) }.map { folder.appendingPathComponent($0) }
            .filter { ((NSDictionary(contentsOf: $0) as? [String: Any])?["Label"] as? String).map(labels.contains) ?? false }
    }

    static func version(of app: URL) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let short = info["CFBundleShortVersionString"] as? String else { return nil }
        return (info["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }

    static let consent = """
        Storage Monitor will copy its background monitor to ~/Applications and add three background tasks for your user account only (no administrator password):

        • A free-space check at login and every 30 minutes. It notifies you about low space only if macOS allows notifications for MacBook Storage Monitor: permission given to an earlier version carries over, and otherwise Allow Low-Space Notifications… shows the macOS prompt.
        • A one-time folder baseline used to explain changes.
        • Disk inventory indexing at low priority. The first pass over a large disk can take hours.

        History is stored in ~/Library/Application Support/MacBook Storage Monitor. You can turn this off at any time; your history is kept.
        """
    static let disableConfirmation = "Background checks and indexing stop and their background tasks are removed. Your history and the installed background monitor in ~/Applications are kept."
    static let permissions = """
        Without extra permission, Storage Monitor measures free space, APFS volumes and every folder macOS lets it read. Protected places, such as other users' folders and some app data in ~/Library (Mail, Messages, Safari), are reported as inaccessible and never guessed.

        Full Disk Access is optional. Granting it to the background monitor lets it measure those protected folders; monitoring keeps working without it. macOS never grants it silently: open System Settings → Privacy & Security → Full Disk Access, click +, and add ~/Applications/MacBook Storage Monitor.app (the background monitor, not this window).
        """
}

/// What launchd itself reports for this user, not what the LaunchAgent files say. Read-only.
struct LaunchdState: Equatable {
    var loaded: Set<String>, disabled: Set<String>
    static func current() -> LaunchdState? {
        guard let list = read(["list"]), let overrides = read(["print-disabled", "gui/\(getuid())"]) else { return nil }
        return parse(list: list, disabled: overrides)
    }
    /// `launchctl list`: "PID\tStatus\tLabel" rows. `print-disabled`: "\"label\" => disabled" (older systems: "=> true").
    static func parse(list: String, disabled: String) -> LaunchdState {
        let loaded = list.split(separator: "\n").dropFirst().compactMap { $0.split(separator: "\t").last.map(String.init) }
        let off = disabled.split(separator: "\n").compactMap { line -> String? in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2, ["disabled", "true"].contains(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return LaunchdState(loaded: Set(loaded), disabled: Set(off))
    }
    private static func read(_ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}

enum MonitoringSetupAction: String {
    case enable, disable, notifications
    var arguments: [String] {
        switch self { case .enable: ["install"]; case .disable: ["uninstall"]; case .notifications: ["authorize"] }
    }
    /// Install and uninstall are transactional and are never cut off: a time limit could only leave
    /// an update half done. Authorization waits for the person's answer to a system prompt.
    var timeLimit: TimeInterval? { self == .notifications ? 130 : nil }
    /// Runs the background monitor's own command off the main thread.
    func run(helper: URL) async -> (ok: Bool, output: String) {
        let arguments = arguments, limit = timeLimit
        return await Task.detached(priority: .userInitiated) {
            let process = Process(), pipe = Pipe()
            process.executableURL = helper; process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            do { try process.run() } catch { return (false, "Could not start the background monitor: \(error.localizedDescription)") }
            // Drained while it runs: a full pipe must never stall a command that has no time limit.
            let output = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
            let deadline = limit.map { Date().addingTimeInterval($0) } ?? .distantFuture
            while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate(); return (false, "No answer within \(Int(limit ?? 0)) seconds. Try again when you can respond to the macOS prompt.") }
            let text = String(data: await output.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus == 0, text.isEmpty ? (process.terminationStatus == 0 ? "Done." : "Failed with status \(process.terminationStatus).") : text)
        }.value
    }
}
