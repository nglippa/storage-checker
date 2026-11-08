import Foundation
import Darwin

// The supervisor's scheduling decisions are pure functions; the process plumbing runs against a stand-in
// worker script in an isolated data directory. No real check, baseline, inventory or launchd job is involved.
func supervisorSelfTest(_ test: (Bool, String) throws -> Void) throws {
    // Half-hour slots follow the local wall clock, including zones that are not a whole hour from UTC.
    let base = 1_800_000_000.0 - 1_800_000_000.0.truncatingRemainder(dividingBy: 1_800)   // a :00/:30 boundary in UTC
    for offset in [0.0, -18_000.0, 19_800.0, 45_900.0] as [Double] {
        let slot = SupervisorSchedule.slot(base + 100, utcOffset: offset)
        try test(SupervisorSchedule.slot(base + 100 + 1_699, utcOffset: offset) - slot <= 1 && SupervisorSchedule.slot(base + 100 + 1_800, utcOffset: offset) == slot + 1,
                 "half-hour slots advance every 1800 s of wall-clock time (UTC offset \(offset))")
    }
    let start = base + 60, nextSlot = base + 1_800 + 5
    func state(_ role: SupervisorRole, running: Bool = false, started: Double? = nil, exit: Int32? = nil, wake: Bool = false) -> SupervisorRoleState {
        SupervisorRoleState(running: running, lastStart: started, lastExit: exit, wakePending: wake)
    }
    func should(_ role: SupervisorRole, _ s: SupervisorRoleState, trigger: Bool = false, at now: Double) -> Bool {
        SupervisorSchedule.shouldStart(role, state: s, trigger: trigger, now: now, utcOffset: 0)
    }
    for role in SupervisorRole.allCases {
        try test(should(role, state(role), at: start), "\(role.rawValue) starts at launch")
        try test(!should(role, state(role, running: true, started: start, wake: true), trigger: true, at: nextSlot + 10_000), "\(role.rawValue) is never started twice at once")
    }
    try test(!should(.check, state(.check, started: start, exit: 0), at: start + 600) && should(.check, state(.check, started: start, exit: 0), at: nextSlot),
             "the check runs once per :00/:30 slot, not more often")
    try test(should(.check, state(.check, started: start, exit: 0), at: base + 5 * 1_800 + 400) && SupervisorSchedule.slot(base + 5 * 1_800 + 400, utcOffset: 0) - SupervisorSchedule.slot(start, utcOffset: 0) == 5,
             "slots missed during sleep run the check once on wake (launchd calendar catch-up)")
    try test(!should(.check, state(.check, started: base + 1_800 + 2, exit: 0), at: base + 1_800 + 300) && should(.check, state(.check, started: start, exit: 0), trigger: true, at: start + 5),
             "a pending mount or registry trigger starts the check immediately; otherwise it waits for the next slot")
    try test(!should(.check, state(.check, started: start, exit: 1), at: start + 120), "a failed check is not retried before its next slot")
    for (role, throttle) in [(SupervisorRole.baseline, 300.0), (.inventory, 60.0)] {
        try test(role.restartThrottle == throttle, "\(role.rawValue) restart throttle is \(Int(throttle)) s")
        try test(!should(role, state(role, started: start, exit: 75), at: start + throttle - 1) && should(role, state(role, started: start, exit: 75), at: start + throttle),
                 "\(role.rawValue) is resumed after exit 75 (non-zero) no sooner than \(Int(throttle)) s after its last start")
        try test(!should(role, state(role, started: start, exit: 1), at: start + throttle - 1) && should(role, state(role, started: start, exit: 1), at: start + throttle + 1),
                 "\(role.rawValue) restarts after any non-zero exit, honouring the throttle")
        try test(!should(role, state(role, started: start, exit: 0), at: start + 10 * 3_600), "\(role.rawValue) stays idle after a clean exit until woken")
        try test(should(role, state(role, started: start, exit: 0, wake: true), at: start + 1), "\(role.rawValue) starts when woken, even inside the throttle")
    }
    try test(SupervisorSchedule.isResumableExit(75) && !SupervisorSchedule.isResumableExit(1), "exit 75 means saved work resumes, not failure")
    try test(SupervisorSchedule.hasNewMount(previous: ["Macintosh HD"], current: ["Macintosh HD", "Backup"]) && !SupervisorSchedule.hasNewMount(previous: ["Macintosh HD", "Backup"], current: ["Macintosh HD"]),
             "only a new /Volumes entry counts as a mount")
    let wakes = SupervisorSchedule.resolveWakes(fileNames: ["baseline", "inventory", "check", "junk"], running: [.inventory])
    try test(wakes.pending == [.baseline] && wakes.discard == [.inventory], "a wake of an idle role is pending, of a running role discarded (no-op), and unknown wake files are ignored")
    try test(SupervisorRole.inventory.arguments(data: "/d") == ["inventory-work", "--budget", "1200", "--data-dir", "/d"] && SupervisorRole.check.arguments(data: "/d") == ["check", "--data-dir", "/d"]
             && SupervisorRole.baseline.arguments(data: "/d") == ["initialize-baseline", "--data-dir", "/d"] && SupervisorRole.check.niceness == nil && SupervisorRole.inventory.niceness == 15,
             "children run the existing commands unchanged; baseline and inventory get nice 15")

    // Status file round trip and permissions.
    let root = monitorSelfTestFixture("supervisor")
    defer { finishMonitorSelfTestFixture(root) }
    let data = root.appendingPathComponent("data")
    try privateDirectory(data)
    try SupervisorStatus(supervisorPid: 42, startedAt: 1, updatedAt: 2, roles: ["baseline": .init(pid: nil, lastStart: 3, lastExit: 75, lastExitTime: 4)]).write(data: data)
    var info = stat()
    try test(SupervisorStatus.read(data: data)?[.baseline].lastExit == 75 && SupervisorStatus.read(data: data)?[.inventory] == SupervisorRoleStatus()
             && stat(SupervisorStatus.file(data: data).path, &info) == 0 && info.st_mode & 0o777 == 0o600, "the status file round-trips and is private (0600)")
    try? fm.removeItem(at: SupervisorStatus.file(data: data))

    // Real child processes: a stand-in worker records each start; baseline exits 75, inventory exits 0.
    let record = root.appendingPathComponent("starts.log")
    let script = root.appendingPathComponent("worker.sh")
    try Data("#!/bin/sh\necho \"$1\" >> \"$2\"\ncase \"$1\" in baseline) sleep 0.3; exit 75;; inventory) sleep 0.3; exit 0;; *) exit 0;; esac\n".utf8).write(to: script)
    _ = chmod(script.path, 0o755)
    func starts(_ role: String) -> Int { ((try? String(contentsOf: record, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == role }.count }
    func wait(_ condition: () -> Bool, _ seconds: Double = 6) -> Bool { let end = Date().addingTimeInterval(seconds); while Date() < end { if condition() { return true }; usleep(50_000) }; return condition() }
    let volumes = root.appendingPathComponent("volumes")
    try privateDirectory(volumes)
    let supervisor = Supervisor(.init(executable: "/bin/sh", data: data, arguments: { [script.path, $0.rawValue, record.path] }, tick: 0.4, volumes: volumes.path))
    supervisor.run()
    defer { supervisor.stop() }
    try test(wait({ starts("check") == 1 && starts("baseline") == 1 && starts("inventory") == 1 }), "at launch the supervisor starts the check, baseline and inventory workers once each")
    try test(wait({ let status = SupervisorStatus.read(data: data); return status?[.baseline].lastExit == 75 && status?[.inventory].lastExit == 0 && status?[.check].pid == nil }),
             "the status file records each worker's last start and exit (75 for the resumable baseline) and its supervisor PID")
    usleep(1_200_000)
    try test(starts("check") == 1 && starts("baseline") == 1 && starts("inventory") == 1, "idle workers are not restarted early (baseline waits 300 s after exit 75, inventory stays idle after exit 0)")
    // Wake requests start only the requested idle role and are cleared.
    try SupervisorWakes.request(data: data, role: .baseline)
    try test(wait({ starts("baseline") == 2 }) && wait({ !fm.fileExists(atPath: SupervisorWakes.file(data: data, role: .baseline).path) }) && starts("inventory") == 1,
             "a wake file starts the baseline role once and is removed when the role starts")
    // A viewer request in inventory-requests wakes the inventory worker.
    let requests = InventoryRequests.directory(database: data.appendingPathComponent("history.sqlite3").path)
    try Data("{}".utf8).write(to: requests.appendingPathComponent("request.json"))
    try test(wait({ starts("inventory") >= 2 }), "a new file in inventory-requests starts the inventory worker")
    // Mount and registry triggers start the check.
    let checksBefore = starts("check")
    try privateDirectory(volumes.appendingPathComponent("Backup"))
    try test(wait({ starts("check") == checksBefore + 1 }), "a new volume in /Volumes starts a check (StartOnMount equivalent)")
    try privateDirectory(data.appendingPathComponent("external-volumes"))
    try Data("{}".utf8).write(to: data.appendingPathComponent("external-volumes/registry.json"))
    try test(wait({ starts("check") == checksBefore + 2 }), "creating external-volumes/registry.json (a path that did not exist at launch) starts a check")
    try Data("{\"v\":2}".utf8).write(to: data.appendingPathComponent("external-volumes/registry.json"))
    try test(wait({ starts("check") == checksBefore + 3 }), "changing external-volumes/registry.json starts a check")
    try Data("x".utf8).write(to: data.appendingPathComponent("external-volumes/observations.json"))
    usleep(1_200_000)
    try test(starts("check") == checksBefore + 3, "other files in external-volumes (written by every check) do not retrigger the check")
}
