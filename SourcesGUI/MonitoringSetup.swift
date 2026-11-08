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
    /// The one LaunchAgent (since 2.4.2): a supervisor that runs the capacity check, folder baseline and inventory indexer.
    static let labels = ["local.macbook.storage-monitor"]
    /// Separate agents installed by versions before 2.4.2. Their presence means the monitor needs an Update.
    static let legacyLabels = ["local.macbook.storage-monitor.baseline", "local.macbook.storage-monitor.inventory"]
    /// Keys under which `LaunchdState.jobs` carries the supervisor's three workers (capacity check, folder baseline,
    /// inventory indexer), taken from its status file. They are not launchd labels.
    static func roleLabels(for supervisor: String) -> [String] { ["#check", "#baseline", "#inventory"].map { supervisor + $0 } }
    static let roleLabels = roleLabels(for: labels[0])
    static func dataDirectory(home: URL) -> URL { home.appendingPathComponent("Library/Application Support/MacBook Storage Monitor") }
    let state: State
    let summary: String
    let installedVersion: String?
    let bundledVersion: String?
    /// The helper that performs changes: the copy bundled in this app, else the installed one.
    let helperExecutable: URL?
    let installedApp: URL
    var notifications: NotificationPermission = .unknown
    var launchd: LaunchdState?
    /// Worker keys in `launchd.jobs`: capacity check, folder baseline, inventory indexer.
    var jobLabels: [String] = MonitoringSetupStatus.roleLabels
    /// The LaunchAgent that hosts the workers.
    var supervisorLabel: String = MonitoringSetupStatus.labels[0]

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

    static func bundledHelper(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/Helpers/MacBook Storage Monitor.app") }

    /// The supervisor's worker state (from supervisor-status.json) as launchd-style jobs under `roleLabels`, beside
    /// launchd's own report for the supervisor agent. A status file written by an earlier supervisor process
    /// (different PID than the one launchd reports) carries no running workers.
    static func withWorkerJobs(_ launchd: LaunchdState?, home: URL, supervisor: String) -> LaunchdState? {
        guard var state = launchd else { return nil }
        guard state.reliable, state.loaded.contains(supervisor) else { return state }
        let status = SupervisorStatus.read(data: dataDirectory(home: home))
        let livePid = state.jobs[supervisor]?.pid
        let current = status.flatMap { s in livePid.map { Int(s.supervisorPid) == $0 } } ?? false
        for (role, key) in zip(SupervisorRole.allCases, roleLabels(for: supervisor)) {
            state.loaded.insert(key)
            if state.disabled.contains(supervisor) { state.disabled.insert(key) }
            let worker = status?[role]
            let pid = current && SupervisorStatus.isAlive(worker?.pid) ? worker?.pid.map(Int.init) : nil
            state.jobs[key] = LaunchdState.Job(pid: pid, lastExitStatus: worker?.lastExit.map(Int.init))
        }
        return state
    }

    static func evaluate(home: URL, bundledHelper: URL?, launchd: LaunchdState? = nil, labels: [String] = MonitoringSetupStatus.labels) -> MonitoringSetupStatus {
        let agents = labels.map { home.appendingPathComponent("Library/LaunchAgents/\($0).plist") }
        let present = agents.filter { FileManager.default.fileExists(atPath: $0.path) }
        let legacyLabels = labels == MonitoringSetupStatus.labels ? MonitoringSetupStatus.legacyLabels : []
        let legacyPresent = legacyLabels.filter { FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/\($0).plist").path) }
        let installedApp = home.appendingPathComponent("Applications/MacBook Storage Monitor.app")
        let installedVersion = version(of: installedApp), bundledVersion = bundledHelper.flatMap(version(of:))
        let bundledExecutable = bundledHelper.map { $0.appendingPathComponent("Contents/MacOS/StorageMonitor") }.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        let installedExecutable = installedApp.appendingPathComponent("Contents/MacOS/StorageMonitor")
        let helper = bundledExecutable ?? (FileManager.default.isExecutableFile(atPath: installedExecutable.path) ? installedExecutable : nil)
        let programs = present.compactMap { (NSDictionary(contentsOf: $0) as? [String: Any])?["ProgramArguments"] as? [String] }
        let targets = programs.compactMap(\.first)
        let interrupted = FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/MacBook Storage Monitor/install-transaction/journal.json").path)
        let duplicates = duplicateAgents(home: home, labels: labels)
        let reported = launchd.flatMap { $0.reliable ? $0 : nil }
        let loaded = reported.map { Set(labels).intersection($0.loaded) } ?? []
        let legacyLoaded = reported.map { Set(legacyLabels).intersection($0.loaded) } ?? []
        let notLoaded = reported == nil ? [] : labels.filter { label in present.contains { $0.lastPathComponent == "\(label).plist" } && !loaded.contains(label) }
        let disabled = reported.map { labels.filter($0.disabled.contains) } ?? []
        let state: State, summary: String
        if interrupted {
            state = .incomplete; summary = "An update of the background monitor was interrupted. Repair finishes or reverts it; your history is kept."
        } else if present.isEmpty && loaded.isEmpty && duplicates.isEmpty && legacyPresent.isEmpty && legacyLoaded.isEmpty {
            state = .off; summary = "Background monitoring is off."
        } else if present.isEmpty {
            state = .incomplete; summary = "A background task is still registered with macOS without its configuration (\((Array(loaded) + Array(legacyLoaded) + legacyPresent + duplicates.map(\.lastPathComponent)).sorted().joined(separator: ", "))). Repair or disable it."
        } else if targets.count < present.count || !targets.allSatisfy({ FileManager.default.isExecutableFile(atPath: $0) }) {
            state = .incomplete
            summary = "Background monitoring is partly set up (its background task points to a missing program). Repair or disable it."
        } else if !duplicates.isEmpty {
            state = .incomplete; summary = "A duplicate background task (\(duplicates.map(\.lastPathComponent).joined(separator: ", "))) runs this monitor from another file. Repair removes it."
        } else if targets.contains(where: { $0 != installedExecutable.path }) {
            state = .incomplete; summary = "A background task runs a different copy of the monitor than the one in ~/Applications. Repair points it at the installed copy."
        } else if !legacyPresent.isEmpty || !legacyLoaded.isEmpty || programs.contains(where: { $0.dropFirst().first != "supervise" }) {
            state = .needsUpdate
            summary = "Update the background monitor: it still runs as separate background tasks from an earlier version. Update replaces them with one."
        } else if !disabled.isEmpty {
            state = .incomplete; summary = "macOS has turned off this monitor's background task (System Settings → General → Login Items). Repair turns it back on."
        } else if !notLoaded.isEmpty {
            state = .incomplete; summary = "The background task is configured but not loaded by macOS, so it will not run. Repair registers it again."
        } else if labels == MonitoringSetupStatus.labels && (bundledHelper.map(supportsExternalVolumes) == true || supportsExternalVolumes(installedApp)) && !externalVolumesReady(home: home) {
            state = .needsUpdate
            summary = "Update the background monitor to enable external-drive discovery and automatic resume. Its capability or wake configuration is out of date."
        } else if let bundledVersion, bundledVersion != installedVersion {
            state = .needsUpdate
            summary = "The installed background monitor (\(installedVersion ?? "unknown version")) differs from this app (\(bundledVersion)). Update it to match."
        } else {
            state = .on
            summary = "Background monitoring is configured for your account. It checks free space at login and every 30 minutes while you are logged in; sleep can delay checks." + (reported == nil ? " (macOS did not report whether its tasks are loaded.)" : "")
        }
        var status = MonitoringSetupStatus(state: state, summary: summary, installedVersion: installedVersion, bundledVersion: bundledVersion, helperExecutable: helper, installedApp: installedApp)
        status.launchd = withWorkerJobs(launchd, home: home, supervisor: labels[0])
        status.supervisorLabel = labels[0]
        status.jobLabels = roleLabels(for: labels[0])
        status.notifications = .recorded(home: home)
        return status
    }

    /// LaunchAgent files carrying one of this monitor's labels under another file name.
    static func supportsExternalVolumes(_ app: URL) -> Bool {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["StorageMonitorExternalVolumeSupport"] as? NSNumber)?.intValue == 1
    }
    static func externalVolumesReady(home: URL, launchd: LaunchdState? = nil) -> Bool {
        let app = home.appendingPathComponent("Applications/MacBook Storage Monitor.app")
        let executable = app.appendingPathComponent("Contents/MacOS/StorageMonitor")
        guard supportsExternalVolumes(app), FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        let agents = labels.compactMap { NSDictionary(contentsOf: home.appendingPathComponent("Library/LaunchAgents/\($0).plist")) as? [String: Any] }
        guard agents.count == labels.count else { return false }
        if let launchd, !Set(labels).isSubset(of: launchd.loaded) || !Set(labels).isDisjoint(with: launchd.disabled) { return false }
        // No legacy per-role agent may remain: the supervisor owns the schedule, the mount and registry wakes and the inventory wake.
        let folder = home.appendingPathComponent("Library/LaunchAgents")
        if legacyLabels.contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0).plist").path) }) { return false }
        let data = dataDirectory(home: home).path
        guard let agent = agents.first, agent["Label"] as? String == labels[0], agent["RunAtLoad"] as? Bool == true, agent["KeepAlive"] as? Bool == true,
              let arguments = agent["ProgramArguments"] as? [String], arguments.count >= 2,
              arguments[0] == executable.path, arguments[1] == "supervise",
              let i = arguments.firstIndex(of: "--data-dir"), i + 1 < arguments.count, arguments[i + 1] == data else { return false }
        return true
    }

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

        Storage Monitor will copy its background monitor to ~/Applications and add one background task for your user account only (no administrator password). It does three things:

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
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let deadline = Date().addingTimeInterval(2)
        var data = Data(), invalid = false
        func drain() {
            var buffer = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<32 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                if data.count + count > 262_144 { invalid = true; break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        while process.isRunning {
            drain()
            if invalid || Date() >= deadline { invalid = true; process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if invalid {
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit(); drain(); try? pipe.fileHandleForReading.close()
        return !invalid && process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}

/// Tracks when a failure was first *observed*, never claims that is when the job attempted to run.
/// A subsequent successful reading can supersede an old free-space exit status even if macOS retains it.
struct MonitoringHealthEvidence {
    private(set) var failures: [String: Date] = [:]
    private var exits: [String: Int] = [:]
    mutating func observe(_ launchd: LaunchdState?, at now: Date, labels: [String] = MonitoringSetupStatus.roleLabels) {
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
    init(timestamp: Date, outcome: String, position: Position? = nil) {
        self.timestamp = timestamp; self.outcome = outcome; self.position = position
    }
    static func parse(_ text: String, now: Date) -> Self? { parse(Data(text.utf8), now: now) }
    private static func parse(_ data: Data, now: Date, stream: Stream? = nil, start: UInt64 = 0) -> Self? {
        let formatter = ISO8601DateFormatter()
        var offset = start
        return newest(data.split(separator: 10, omittingEmptySubsequences: false).compactMap { bytes -> Self? in
            let position = stream.map { Position(stream: $0, offset: offset) }
            offset += UInt64(bytes.count) + 1
            let line = String(decoding: bytes, as: UTF8.self)
            guard let marker = line.range(of: " inventory "),
                  let date = formatter.date(from: String(line[..<marker.lowerBound])), date <= now else { return nil }
            let data = Data(line[marker.upperBound...].utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outcome = json["outcome"] as? String else { return Self(timestamp: date, outcome: "unknown", position: position) }
            if outcome == "failed" { return Self(timestamp: date, outcome: "failed", position: position) }
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
            guard ["complete", "partial"].contains(observed.outcome) else { return previous }
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
    enum State: Equatable { case off, configurationNeedsAttention, unknown, waiting, running, healthy, failed, stale, resuming, waking }
    let state: State
    let title: String
    let detail: String
    let lastSuccess: Date?
    /// Only supplied by timestamped evidence; launchctl list alone never sets this.
    let lastAttempt: Date?
    let jobDetails: [String]
    static let staleAfter: TimeInterval = 75 * 60
    static let wakeGrace: TimeInterval = 10 * 60
    init(setup: MonitoringSetupStatus?, lastSuccess: Date?, evidence: MonitoringHealthEvidence = .init(), lastAttempt: Date? = nil, lastWake: Date? = nil, inventory: InventoryWorkerEvidence? = nil, now: Date) {
        self.lastSuccess = lastSuccess; self.lastAttempt = lastAttempt
        let jobs = setup?.launchd?.jobs ?? [:]
        let labels = setup?.jobLabels ?? MonitoringSetupStatus.roleLabels
        let main = labels[0], baseline = labels[1], worker = labels[2]
        let supervisor = setup?.supervisorLabel ?? MonitoringSetupStatus.labels[0]
        jobDetails = labels.map { label in
            let name = label == main ? "Capacity checks" : (label == worker ? "Inventory indexer" : "Folder baseline")
            guard let job = jobs[label] else { return name + ": execution details unknown" }
            return name + ": " + (job.pid.map { "running (PID \($0))" } ?? "not running now") + "; last exit " + (job.lastExitStatus.map(String.init) ?? "unknown")
        } + [jobs[supervisor].map { "Background agent: " + ($0.pid.map { "running (PID \($0))" } ?? "not running now") + "; last exit " + ($0.lastExitStatus.map(String.init) ?? "unknown") } ?? "Background agent: execution details unknown"]
        let failed = (labels + [supervisor]).filter { label in
            guard let job = jobs[label], job.pid == nil, let exit = job.lastExitStatus, exit != 0 else { return false }
            if (label == worker || label == baseline) && exit == 75 { return false } // Saved work resumes in the next worker slice.
            if label == main, let observed = evidence.failures[label], let lastSuccess, lastSuccess > observed { return false }
            return true
        }
        if setup == nil { state = .unknown; title = "Checking background monitoring" }
        else if setup?.state == .off { state = .off; title = "Background monitoring is off" }
        else if setup?.state == .incomplete { state = .configurationNeedsAttention; title = "Background setup needs attention" }
        else if setup?.launchd?.reliable != true { state = .unknown; title = "Background execution is unknown" }
        else if !failed.isEmpty {
            state = .failed
            title = "Monitoring enabled · attention needed"
        } else if inventory?.outcome == "failed" {
            state = .failed; title = "Monitoring enabled · inventory needs attention"
        } else if inventory?.outcome == "unknown" {
            state = .unknown; title = "Inventory execution needs rechecking"
        } else if jobs[main]?.pid != nil { state = .running; title = "A capacity check is running" }
        else if let lastSuccess, lastSuccess > now { state = .unknown; title = "Background reading time needs rechecking" }
        else if let lastSuccess, now.timeIntervalSince(lastSuccess) <= Self.staleAfter {
            state = .healthy; title = "Recent background reading received"
        } else if let lastWake, now.timeIntervalSince(lastWake) >= 0, now.timeIntervalSince(lastWake) < Self.wakeGrace {
            state = .waking; title = "Waiting for a check after wake"
        } else if lastSuccess != nil { state = .stale; title = "Background readings are older than expected" }
        else if jobs[worker]?.lastExitStatus == 75 || jobs[baseline]?.lastExitStatus == 75 { state = .resuming; title = "Folder indexing will resume" }
        else { state = .waiting; title = "Waiting for the first background reading" }
        let successText = lastSuccess.map { "Last successful capacity reading: " + $0.formatted(date: .abbreviated, time: .standard) + "." } ?? "No successful capacity reading is recorded."
        let attemptText = lastAttempt.map { "Last attempt: " + $0.formatted(date: .abbreviated, time: .standard) + "." } ?? "Last attempt time is unknown; macOS does not report it here."
        let recovery: String
        switch state {
        case .failed: recovery = "Check Background Monitoring in Settings and repair the helper if needed. A later running task or successful check can show recovery; a registered task alone does not prove it is working."
        case .stale, .waking, .waiting: recovery = "Checks are scheduled at login and every 30 minutes for your account. They do not run while logged out; sleep can delay them. After wake, allow the next scheduled check, then reload status or check setup if readings remain old."
        case .resuming: recovery = "Folder indexing saved its progress; the next background run can resume it. This is not a fatal failure."
        case .configurationNeedsAttention: recovery = setup?.summary ?? "Check setup in Settings."
        case .unknown: recovery = "Configuration and registration do not establish successful execution. Reload status to try again."
        default: recovery = "Capacity checks are scheduled at login and every 30 minutes while your account is logged in. Sleep can delay checks."
        }
        let inventoryText = inventory.map { " Last recorded inventory outcome: " + $0.outcome + " at " + $0.timestamp.formatted(date: .abbreviated, time: .standard) + ". Capacity readings do not clear an inventory failure." } ?? ""
        detail = successText + " " + attemptText + " " + recovery + inventoryText
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
