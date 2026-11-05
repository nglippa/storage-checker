import Foundation
import SQLite3
import Darwin

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
    var launchd: LaunchdState?
    var jobLabels: [String] = MonitoringSetupStatus.labels

    /// A retained catalog queue is not proof of running work. Unknown service output stays unknown.
    var inventoryUpdatesEnabled: Bool? {
        guard let launchd, launchd.reliable, jobLabels.count > 2 else { return nil }
        let indexer = jobLabels[2]
        if launchd.loaded.contains(indexer), launchd.jobs[indexer]?.pid != nil { return true }
        if launchd.disabled.contains(indexer) { return false }
        switch state {
        case .off: return false
        case .on, .needsUpdate:
            return launchd.loaded.contains(indexer) && !launchd.disabled.contains(indexer) ? true : nil
        case .incomplete: return nil
        }
    }

    /// Registration and exit zero do not establish that the indexer produced results.
    func inventoryFailure(_ evidence: InventoryWorkerEvidence?) -> String? {
        if let failure = evidence?.failureDescription { return failure }
        guard let launchd, launchd.reliable, jobLabels.count > 2,
              let job = launchd.jobs[jobLabels[2]], job.pid == nil,
              let exit = job.lastExitStatus, exit != 0 && exit != 75 else { return nil }
        return "Disk indexing stopped unexpectedly (exit code \(exit)) before it produced results."
    }

    static func bundledHelper(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/Helpers/MacBook Storage Monitor.app") }

    static func evaluate(home: URL, bundledHelper: URL?, launchd: LaunchdState? = nil, labels: [String] = MonitoringSetupStatus.labels) -> MonitoringSetupStatus {
        let agents = labels.map { home.appendingPathComponent("Library/LaunchAgents/\($0).plist") }
        let present = agents.filter { FileManager.default.fileExists(atPath: $0.path) }
        let installedApp = home.appendingPathComponent("Applications/MacBook Storage Monitor.app")
        let installedVersion = version(of: installedApp), bundledVersion = bundledHelper.flatMap(version(of:))
        let bundledExecutable = bundledHelper.map { $0.appendingPathComponent("Contents/MacOS/StorageMonitor") }.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        let installedExecutable = installedApp.appendingPathComponent("Contents/MacOS/StorageMonitor")
        let helper = bundledExecutable ?? (FileManager.default.isExecutableFile(atPath: installedExecutable.path) ? installedExecutable : nil)
        let targets = present.compactMap { (NSDictionary(contentsOf: $0) as? [String: Any])?["ProgramArguments"] as? [String] }.compactMap(\.first)
        let interrupted = FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/MacBook Storage Monitor/install-transaction/journal.json").path)
        let duplicates = duplicateAgents(home: home, labels: labels)
        let reported = launchd.flatMap { $0.reliable ? $0 : nil }
        let loaded = reported.map { Set(labels).intersection($0.loaded) } ?? []
        let notLoaded = reported == nil ? [] : labels.filter { label in present.contains { $0.lastPathComponent == "\(label).plist" } && !loaded.contains(label) }
        let disabled = reported.map { labels.filter($0.disabled.contains) } ?? []
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
            summary = "Background monitoring is configured for your account. It checks free space at login and every 30 minutes while you are logged in; sleep can delay checks." + (reported == nil ? " (macOS did not report whether its tasks are loaded.)" : "")
        }
        var status = MonitoringSetupStatus(state: state, summary: summary, installedVersion: installedVersion, bundledVersion: bundledVersion, helperExecutable: helper, installedApp: installedApp)
        status.launchd = launchd
        status.jobLabels = labels
        status.notifications = .recorded(home: home)
        return status
    }

    /// LaunchAgent files carrying one of this monitor's labels under another file name.
    static func duplicateAgents(home: URL, labels: [String] = MonitoringSetupStatus.labels) -> [URL] {
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
        Storage Monitor is the viewer. MacBook Storage Monitor is its background helper, which records readings, indexes folders, and sends notifications. macOS permission prompts name that helper.

        Storage Monitor will copy its background monitor to ~/Applications and add three background tasks for your user account only (no administrator password):

        • A free-space check at login and every 30 minutes. It notifies you about low space only if macOS allows notifications for MacBook Storage Monitor: permission given to an earlier version carries over, and otherwise Allow Low-Space Notifications… shows the macOS prompt.
        • A one-time folder baseline used to explain changes.
        • Disk inventory indexing at low priority. The first pass over a large disk can take hours.

        Monitoring covers the internal startup volume only, for your logged-in account. Checks run approximately every 30 minutes, stop while logged out, and may be delayed by sleep. Low-space thresholds are fixed at 25 GB and 15 GB. Growth alerts use a drop of 3 GB since the previous reading or 5 GB within two hours. All thresholds use decimal GB.

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
    struct Job: Equatable {
        let pid: Int?
        let lastExitStatus: Int?
    }
    var loaded: Set<String>, disabled: Set<String>
    var jobs: [String: Job] = [:]
    var reliable = true
    static func current() -> LaunchdState? {
        guard let list = read(["list"]), let overrides = read(["print-disabled", "gui/\(getuid())"]) else { return nil }
        return parse(list: list, disabled: overrides)
    }
    /// Registration, current PID and last exit are different facts. This output contains no attempt time.
    static func parse(list: String, disabled: String) -> LaunchdState {
        let lines = list.split(whereSeparator: \.isNewline)
        guard let header = lines.first, header.split(whereSeparator: \.isWhitespace).map(String.init) == ["PID", "Status", "Label"] else {
            return LaunchdState(loaded: [], disabled: [], reliable: false)
        }
        var jobs: [String: Job] = [:], reliable = true
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3, fields[0] == "-" || (Int(fields[0]).map { $0 > 0 } ?? false),
                  fields[1] == "-" || Int(fields[1]) != nil else { reliable = false; continue }
            jobs[fields[2]] = Job(pid: Int(fields[0]), lastExitStatus: Int(fields[1]))
        }
        let off = disabled.split(separator: "\n").compactMap { line -> String? in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2, ["disabled", "true"].contains(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return LaunchdState(loaded: Set(jobs.keys), disabled: Set(off), jobs: jobs, reliable: reliable)
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

/// Tracks when a failure was first *observed*, never claims that is when the job attempted to run.
/// A subsequent successful reading can supersede an old free-space exit status even if macOS retains it.
struct MonitoringHealthEvidence {
    private(set) var failures: [String: Date] = [:]
    private var exits: [String: Int] = [:]
    mutating func observe(_ launchd: LaunchdState?, at now: Date, labels: [String] = MonitoringSetupStatus.labels) {
        guard let launchd, launchd.reliable else { return }
        for label in labels {
            guard let job = launchd.jobs[label], let exit = job.lastExitStatus else { continue }
            if job.pid != nil || exit == 0 { failures[label] = nil; exits[label] = nil }
            else if exits[label] != exit { failures[label] = now; exits[label] = exit }
        }
    }
}

/// Existing worker summaries are timestamped even when its scheduled-process exit is deliberately zero.
/// Read at most two 64KiB tails; never enumerate directories or parse an unbounded log.
struct InventoryWorkerEvidence: Equatable, Sendable {
    struct Stream: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let birthNanoseconds: Int64
    }
    struct Position: Equatable, Sendable {
        let stream: Stream
        let offset: UInt64
    }
    let timestamp: Date
    let outcome: String
    let position: Position?
    let reason: String?
    init(timestamp: Date, outcome: String, position: Position? = nil, reason: String? = nil) {
        self.timestamp = timestamp; self.outcome = outcome; self.position = position; self.reason = reason
    }
    var failureDescription: String? {
        guard outcome == "failed" else { return nil }
        return "Disk indexing stopped with an error." + (reason.map { " " + $0 } ?? "")
    }
    static func parse(_ text: String, now: Date) -> Self? { parse(Data(text.utf8), now: now) }
    private static func parse(_ data: Data, now: Date, stream: Stream? = nil, start: UInt64 = 0) -> Self? {
        let formatter = ISO8601DateFormatter()
        var offset = start
        return newest(data.split(separator: 10, omittingEmptySubsequences: false).compactMap { bytes -> Self? in
            let position = stream.map { Position(stream: $0, offset: offset) }
            offset += UInt64(bytes.count) + 1
            let line = String(decoding: bytes, as: UTF8.self)
            if let marker = line.range(of: " ERROR inventory-work failed: "),
               let date = formatter.date(from: String(line[..<marker.lowerBound])), date <= now {
                let reason = String(line[marker.upperBound...].prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
                return Self(timestamp: date, outcome: "failed", position: position, reason: reason.isEmpty ? nil : reason)
            }
            guard let marker = line.range(of: " inventory "),
                  let date = formatter.date(from: String(line[..<marker.lowerBound])), date <= now else { return nil }
            let data = Data(line[marker.upperBound...].utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outcome = json["outcome"] as? String else { return Self(timestamp: date, outcome: "unknown", position: position) }
            if outcome == "failed" {
                let reason = (json["reason"] as? String).map { String($0.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines) }
                return Self(timestamp: date, outcome: "failed", position: position, reason: reason?.isEmpty == false ? reason : nil)
            }
            if let status = json["status"] as? String {
                if ["skipped", "paused"].contains(status) { return nil }
                if ["completed", "continuing", "deferred"].contains(status), ["complete", "partial", "interrupted", "stale"].contains(outcome) {
                    return Self(timestamp: date, outcome: status == "completed" ? "complete" : "partial", position: position)
                }
            }
            if outcome == "busy" { return nil }
            return Self(timestamp: date, outcome: ["complete", "partial", "failed"].contains(outcome) ? outcome : "unknown", position: position)
        })
    }
    static func retainingFailure(_ previous: Self?, observed: Self?) -> Self? {
        guard let observed else { return previous }
        guard let previous else { return observed }
        guard observed.timestamp >= previous.timestamp else { return previous }
        if previous.outcome == "failed" {
            guard ["failed", "complete", "partial"].contains(observed.outcome) else { return previous }
            if observed.timestamp == previous.timestamp {
                // Log timestamps have second resolution. Only physical order in the same
                // opened log stream proves recovery; a rotated/temporarily missing tail cannot.
                guard let old = previous.position, let new = observed.position,
                      old.stream == new.stream, new.offset > old.offset else { return previous }
            }
        }
        return observed
    }
    private static func newest(_ entries: [Self]) -> Self? {
        entries.reduce(nil) { current, next in
            guard let current else { return next }
            return next.timestamp >= current.timestamp ? next : current
        }
    }
    static func read(directory: URL, now: Date) -> Self? {
        newest(["monitor.log.1", "monitor.log"].compactMap { name -> Self? in
            let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size >= 0 else { return nil }
            let offset = max(0, info.st_size - 65_536)
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.read(upToCount: 65_536) else { return nil }
            var payload = data, start = UInt64(offset)
            if offset > 0 {
                guard let newline = data.firstIndex(of: 10) else { return nil }
                let skip = data.distance(from: data.startIndex, to: newline) + 1
                payload = Data(data.dropFirst(skip)); start += UInt64(skip)
            }
            let stream = Stream(device: Int64(info.st_dev), inode: UInt64(info.st_ino), birthNanoseconds: Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec))
            return parse(payload, now: now, stream: stream, start: start)
        })
    }
}

struct MonitoringHealthPresentation: Equatable {
    enum State: Equatable { case off, configurationNeedsAttention, unknown, waiting, running, healthy, failed, stale, resuming, waking, paused }
    let state: State
    let title: String
    let detail: String
    let lastSuccess: Date?
    /// Only supplied by timestamped evidence; launchctl list alone never sets this.
    let lastAttempt: Date?
    /// Technical per-task lines (process IDs, exit codes), shown under a Technical details disclosure.
    let jobDetails: [String]
    /// When a saved pause marker exists, the time it was written.
    let pausedSince: Date?
    /// Repair reinstalls the background tasks; offer it whenever something has failed.
    var offersRepair: Bool { state == .failed || state == .configurationNeedsAttention }
    static let staleAfter: TimeInterval = 75 * 60
    static let wakeGrace: TimeInterval = 10 * 60
    init(setup: MonitoringSetupStatus?, lastSuccess: Date?, evidence: MonitoringHealthEvidence = .init(), lastAttempt: Date? = nil, lastWake: Date? = nil, inventory: InventoryWorkerEvidence? = nil, inventoryPausedSince: Date? = nil, now: Date) {
        self.lastSuccess = lastSuccess; self.lastAttempt = lastAttempt; self.pausedSince = inventoryPausedSince
        let jobs = setup?.launchd?.jobs ?? [:]
        let labels = setup?.jobLabels ?? MonitoringSetupStatus.labels
        let main = labels[0], baseline = labels[1], worker = labels[2]
        jobDetails = labels.map { label in
            let name = label == main ? "Capacity checks" : (label == worker ? "Inventory indexer" : "Folder baseline")
            guard let job = jobs[label] else { return name + ": execution details unknown" }
            return name + ": " + (job.pid.map { "running (PID \($0))" } ?? "not running now") + "; last exit " + (job.lastExitStatus.map(String.init) ?? "unknown")
        }
        let failed = labels.filter { label in
            guard let job = jobs[label], job.pid == nil, let exit = job.lastExitStatus, exit != 0 else { return false }
            if (label == worker || label == baseline) && exit == 75 { return false } // Saved work resumes in the next worker slice.
            if label == main, let observed = evidence.failures[label], let lastSuccess, lastSuccess > observed { return false }
            return true
        }
        let configured = setup != nil && setup?.state != .off && setup?.state != .incomplete
        if setup == nil { state = .unknown; title = "Checking background monitoring…" }
        else if setup?.state == .off { state = .off; title = "Background monitoring is off" }
        else if setup?.state == .incomplete { state = .configurationNeedsAttention; title = "Background monitoring needs repair" }
        else if setup?.launchd?.reliable != true { state = .unknown; title = "Couldn't confirm the background tasks are running" }
        else if !failed.isEmpty {
            state = .failed
            title = "A background task stopped unexpectedly"
        } else if inventory?.outcome == "failed" {
            state = .failed; title = "Disk indexing stopped with an error"
        } else if configured, inventoryPausedSince != nil {
            // A saved pause outlives updates; capacity checks alone must never make this look healthy.
            state = .paused; title = "Disk indexing is paused"
        } else if inventory?.outcome == "unknown" {
            state = .unknown; title = "Couldn't confirm disk indexing ran"
        } else if jobs[main]?.pid != nil { state = .running; title = "Checking free space now" }
        else if let lastSuccess, lastSuccess > now { state = .unknown; title = "The last reading's time looks wrong" }
        else if let lastSuccess, now.timeIntervalSince(lastSuccess) <= Self.staleAfter {
            state = .healthy; title = "Working normally"
        } else if let lastWake, now.timeIntervalSince(lastWake) >= 0, now.timeIntervalSince(lastWake) < Self.wakeGrace {
            state = .waking; title = "Waiting for a check after wake"
        } else if lastSuccess != nil { state = .stale; title = "Readings are older than expected" }
        else if jobs[worker]?.lastExitStatus == 75 || jobs[baseline]?.lastExitStatus == 75 { state = .resuming; title = "Disk indexing will continue" }
        else { state = .waiting; title = "Waiting for the first reading" }
        let successText = lastSuccess.map { "Last free-space reading: " + $0.formatted(date: .abbreviated, time: .shortened) + "." } ?? "No free-space reading has been recorded yet."
        let recovery: String
        switch state {
        case .failed: recovery = "Choose Repair to reinstall the background tasks. Your history is kept."
        case .paused: recovery = "Disk indexing has been paused since " + (inventoryPausedSince ?? now).formatted(date: .abbreviated, time: .shortened) + ". A pause stays in effect, even after app updates, until you choose Resume Indexing. Free-space checks continue."
        case .stale, .waking, .waiting: recovery = "Checks run at login and every 30 minutes while you're logged in; sleep can delay them. If readings stay old, choose Check Again, or Repair."
        case .resuming: recovery = "Disk indexing saved its progress and continues in the next background run. Nothing needs fixing."
        case .configurationNeedsAttention: recovery = setup?.summary ?? "Choose Repair to fix the setup."
        case .unknown: recovery = setup == nil ? "" : "macOS didn't report whether the background tasks ran. Choose Check Again."
        case .off: recovery = "Turn it on to record free space and build your disk inventory."
        default: recovery = "Free space is checked at login and every 30 minutes while you're logged in."
        }
        let inventoryText: String
        if state == .paused { inventoryText = "" }
        else if let inventory {
            let when = inventory.timestamp.formatted(date: .abbreviated, time: .shortened)
            switch inventory.outcome {
            case "complete": inventoryText = " Disk indexing last finished normally (" + when + ")."
            case "partial": inventoryText = " Disk indexing last saved its progress (" + when + ") and continues in the next run."
            case "failed": inventoryText = " Disk indexing stopped with an error (" + when + ")" + (inventory.reason.map { ": " + $0 } ?? "") + "."
            default: inventoryText = " Disk indexing's last result couldn't be read (" + when + ")."
            }
        } else { inventoryText = "" }
        detail = [successText, recovery].filter { !$0.isEmpty }.joined(separator: " ") + inventoryText
    }
    /// Raw evidence for the Technical details disclosure.
    func technicalLines(inventory: InventoryWorkerEvidence?) -> [String] {
        var lines = jobDetails
        if let lastAttempt { lines.append("Last attempt: " + lastAttempt.formatted(date: .abbreviated, time: .standard)) }
        if let inventory {
            lines.append("Last inventory outcome: " + inventory.outcome + " at " + inventory.timestamp.formatted(date: .abbreviated, time: .standard) + (inventory.reason.map { " — " + $0 } ?? ""))
        }
        return lines
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
    func run(helper: URL, scope: LifecycleQAScope? = nil) async -> (ok: Bool, output: String) {
        if let scope {
            do {
                guard self != .notifications, helper.path == scope.installer.path else { try LifecycleQAScope.refuse("setup must use the stable installer; notification prompts require separate acceptance") }
                try scope.admit(command: arguments[0]); try scope.validateBundle(scope.bundle("Installer"), roles: ["Installer"])
            } catch { return (false, String(describing: error)) }
        }
        let arguments = arguments + (scope?.arguments ?? []), limit = timeLimit
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
