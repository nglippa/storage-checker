import Foundation
import Darwin

// The single resident background agent. It starts the helper's existing commands as child processes
// with the semantics the three separate LaunchAgents had (SourcesShared/SupervisorModel.swift decides when;
// this file is the process and file-watching plumbing):
//   check      at launch, every :00/:30 (a slot missed during sleep runs once on wake), on a new mount,
//              and when external-volumes/registry.json changes
//   baseline   at launch; again after a non-zero exit (>= 300 s after its last start) or when woken
//   inventory  at launch; again after a non-zero exit (>= 60 s after its last start), when anything changes
//              in inventory-requests, or when woken
// Each role runs at most one process at a time; roles run concurrently with each other.

final class Supervisor {
    struct Configuration {
        let executable: String
        let data: URL
        let arguments: (SupervisorRole) -> [String]
        var tick: TimeInterval = 60
        var volumes = "/Volumes"
        var utcOffset: () -> Double = { Double(TimeZone.current.secondsFromGMT()) }
    }

    private final class DirectoryWatch {
        let path: String
        let onChange: () -> Void
        var inode: UInt64?
        var source: DispatchSourceFileSystemObject?
        init(path: String, onChange: @escaping () -> Void) { self.path = path; self.onChange = onChange }
        /// (Re)attaches when the directory exists and is not the one already watched. Tolerates a missing directory.
        func ensure(queue: DispatchQueue) {
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { source?.cancel(); source = nil; inode = nil; return }
            if source != nil, inode == UInt64(info.st_ino) { return }
            source?.cancel(); source = nil
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .link], queue: queue)
            watch.setEventHandler { [onChange] in onChange() }
            watch.setCancelHandler { close(fd) }
            watch.resume()
            source = watch; inode = UInt64(info.st_ino)
        }
    }

    let configuration: Configuration
    let queue = DispatchQueue(label: "local.macbook.storage-monitor.supervisor")
    private var states = Dictionary(uniqueKeysWithValues: SupervisorRole.allCases.map { ($0, SupervisorRoleState()) })
    private var statuses = [SupervisorRole: SupervisorRoleStatus]()
    private var processes = [SupervisorRole: Process]()
    private var checkTrigger = false
    private var shuttingDown = false
    private let startedAt = Date().timeIntervalSince1970
    private var volumes = Set<String>()
    private var registrySignature: FileSignature?
    private var watches = [DirectoryWatch]()
    private var timer: DispatchSourceTimer?
    private var signals = [DispatchSourceSignal]()

    init(_ configuration: Configuration) { self.configuration = configuration }

    private var data: URL { configuration.data }
    private var registryPath: String { data.appendingPathComponent("external-volumes/registry.json").path }

    func run() {
        try? privateDirectory(data)
        try? privateDirectory(InventoryRequests.directory(database: data.appendingPathComponent("history.sqlite3").path))
        try? privateDirectory(SupervisorWakes.directory(data: data))
        volumes = listing(configuration.volumes)
        registrySignature = FileSignature.of(registryPath)
        let requests = InventoryRequests.directory(database: data.appendingPathComponent("history.sqlite3").path).path
        watches = [
            DirectoryWatch(path: requests) { [weak self] in self?.inventoryRequestsChanged() },
            DirectoryWatch(path: SupervisorWakes.directory(data: data).path) { [weak self] in self?.evaluate() },
            DirectoryWatch(path: configuration.volumes) { [weak self] in self?.pollVolumes(); self?.evaluate() },
            DirectoryWatch(path: data.appendingPathComponent("external-volumes").path) { [weak self] in self?.pollRegistry(); self?.evaluate() },
        ]
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: configuration.tick, leeway: .milliseconds(Int(min(10, configuration.tick / 4) * 1000)))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume(); self.timer = timer
        log(data, "supervisor started pid=\(getpid())")
    }

    /// Production only: SIGTERM (launchctl bootout) or SIGINT forwards to the children and exits.
    func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume(); signals.append(source)
        }
    }

    /// Stops scheduling and watching and terminates running children. Does not exit the process (tests).
    func stop() {
        queue.sync {
            shuttingDown = true
            timer?.cancel(); timer = nil
            for watch in watches { watch.source?.cancel(); watch.source = nil }
            for process in processes.values where process.isRunning { process.terminate() }
        }
    }

    private func tick() {
        for watch in watches { watch.ensure(queue: queue) }
        pollVolumes(); pollRegistry()
        evaluate()
    }

    private func listing(_ path: String) -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: path)) ?? []) }

    private func pollVolumes() {
        let now = listing(configuration.volumes)
        if SupervisorSchedule.hasNewMount(previous: volumes, current: now) { checkTrigger = true }
        volumes = now
    }
    private func pollRegistry() {
        let signature = FileSignature.of(registryPath)
        if signature != registrySignature { registrySignature = signature; if signature != nil { checkTrigger = true } }
    }
    private func inventoryRequestsChanged() {
        states[.inventory]?.wakePending = true
        evaluate()
    }

    private func scanWakes() {
        let names = (try? fm.contentsOfDirectory(atPath: SupervisorWakes.directory(data: data).path)) ?? []
        let running = Set(SupervisorRole.allCases.filter { states[$0]?.running == true })
        let result = SupervisorSchedule.resolveWakes(fileNames: names, running: running)
        for role in result.pending { states[role]?.wakePending = true }
        for role in result.discard { try? fm.removeItem(at: SupervisorWakes.file(data: data, role: role)) }
    }

    private func evaluate() {
        guard !shuttingDown else { return }
        scanWakes()
        let now = Date().timeIntervalSince1970, offset = configuration.utcOffset()
        for role in SupervisorRole.allCases {
            guard let state = states[role] else { continue }
            if SupervisorSchedule.shouldStart(role, state: state, trigger: role == .check && checkTrigger, now: now, utcOffset: offset) { start(role, at: now) }
        }
    }

    private func start(_ role: SupervisorRole, at now: Double) {
        states[role]?.wakePending = false
        if role == .check { checkTrigger = false }
        try? fm.removeItem(at: SupervisorWakes.file(data: data, role: role))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments(role)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in self?.queue.async { self?.exited(role, finished) } }
        states[role]?.lastStart = now
        do { try process.run() } catch {
            states[role]?.lastExit = 127
            statuses[role] = SupervisorRoleStatus(pid: nil, lastStart: now, lastExit: 127, lastExitTime: now)
            log(data, "supervisor could not start \(role.rawValue): \(error)")
            writeStatus(); return
        }
        if let nice = role.niceness { _ = setpriority(PRIO_PROCESS, id_t(process.processIdentifier), nice) }
        processes[role] = process
        states[role]?.running = true
        var status = statuses[role] ?? SupervisorRoleStatus()
        status.pid = process.processIdentifier; status.lastStart = now
        statuses[role] = status
        log(data, "supervisor started \(role.rawValue) pid=\(process.processIdentifier)")
        writeStatus()
    }

    private func exited(_ role: SupervisorRole, _ process: Process) {
        guard processes[role] === process else { return }
        let code = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
        let now = Date().timeIntervalSince1970
        processes[role] = nil
        states[role]?.running = false; states[role]?.lastExit = code
        var status = statuses[role] ?? SupervisorRoleStatus()
        status.pid = nil; status.lastExit = code; status.lastExitTime = now
        statuses[role] = status
        log(data, "supervisor \(role.rawValue) exited status=\(code)")
        writeStatus()
        evaluate()
    }

    private func writeStatus() {
        var roles = [String: SupervisorRoleStatus]()
        for (role, status) in statuses { roles[role.rawValue] = status }
        try? SupervisorStatus(supervisorPid: getpid(), startedAt: startedAt, updatedAt: Date().timeIntervalSince1970, roles: roles).write(data: data)
    }

    /// SIGTERM (launchctl bootout): children get SIGTERM, are given a short time to finish, then the supervisor exits.
    private func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        timer?.cancel()
        for watch in watches { watch.source?.cancel(); watch.source = nil }
        let running = processes.values.filter { $0.isRunning }
        for process in running { process.terminate() }
        let pids = running.map(\.processIdentifier)
        log(data, "supervisor stopping (SIGTERM forwarded to \(pids.count) child process(es))")
        DispatchQueue.global().async { [self] in
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
            queue.sync {
                for role in SupervisorRole.allCases { statuses[role]?.pid = nil }
                writeStatus()
            }
            exit(0)
        }
    }
}

/// `supervise`: the entry point of the single LaunchAgent. Production children run the same executable's
/// commands; a lifecycle QA scope runs exactly the generated fixture worker arguments instead.
@MainActor func runSupervisor(directory: URL, qa: LifecycleQAScope? = nil) async throws {
    let executable: String
    if let qa { executable = qa.executable }
    else if CommandLine.arguments[0].hasPrefix("/") { executable = CommandLine.arguments[0] }
    else { executable = Bundle.main.executablePath ?? CommandLine.arguments[0] }
    try required(fm.isExecutableFile(atPath: executable), "supervise: executable not found")
    let data = qa?.data ?? directory
    let arguments: (SupervisorRole) -> [String] = { role in
        if let qa { return Array(qa.workerArguments(command: role.command).dropFirst()) }
        return role.arguments(data: data.path)
    }
    let supervisor = Supervisor(.init(executable: executable, data: data, arguments: arguments))
    supervisor.installSignalHandlers()
    supervisor.run()
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
}
