import Foundation
import Darwin

// One resident LaunchAgent (`supervise`) replaces the former check, baseline and inventory agents so macOS
// shows a single Background Items entry. The supervisor reproduces the old launchd semantics by spawning the
// same executable's existing commands. Everything that decides *when* to start a role lives here as pure
// functions (unit-tested without launchd); the process plumbing is in Sources/Supervisor.swift.

public enum SupervisorRole: String, CaseIterable, Codable, Sendable {
    case check, baseline, inventory

    /// The helper command the role runs (the same commands the separate agents ran).
    public var command: String {
        switch self { case .check: "check"; case .baseline: "initialize-baseline"; case .inventory: "inventory-work" }
    }
    /// Minimum seconds between the start of a run and the restart after a non-zero exit
    /// (launchd ThrottleInterval of the former agent). The check is never restarted after failure.
    public var restartThrottle: TimeInterval? {
        switch self { case .check: nil; case .baseline: 300; case .inventory: 60 }
    }
    /// The former agents' Nice value (the check inherited the job's Nice 10).
    public var niceness: Int32? {
        switch self { case .check: nil; case .baseline, .inventory: 15 }
    }
    public static let inventoryBudget = 1_200
    /// Arguments after the executable for production children.
    public func arguments(data: String) -> [String] {
        (self == .inventory ? [command, "--budget", String(Self.inventoryBudget)] : [command]) + ["--data-dir", data]
    }
}

public struct SupervisorRoleStatus: Codable, Equatable, Sendable {
    public var pid: Int32?
    public var lastStart: Double?
    public var lastExit: Int32?
    public var lastExitTime: Double?
    public init(pid: Int32? = nil, lastStart: Double? = nil, lastExit: Int32? = nil, lastExitTime: Double? = nil) {
        self.pid = pid; self.lastStart = lastStart; self.lastExit = lastExit; self.lastExitTime = lastExitTime
    }
}

public struct SupervisorStatus: Codable, Equatable, Sendable {
    public var version = 1
    public var supervisorPid: Int32
    public var startedAt: Double
    public var updatedAt: Double
    public var roles: [String: SupervisorRoleStatus]

    public init(supervisorPid: Int32, startedAt: Double, updatedAt: Double, roles: [String: SupervisorRoleStatus] = [:]) {
        self.supervisorPid = supervisorPid; self.startedAt = startedAt; self.updatedAt = updatedAt; self.roles = roles
    }
    public subscript(role: SupervisorRole) -> SupervisorRoleStatus { roles[role.rawValue] ?? SupervisorRoleStatus() }

    public static func file(data: URL) -> URL { data.appendingPathComponent("supervisor-status.json") }

    public func write(data: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let url = Self.file(data: data)
        try encoder.encode(self).write(to: url, options: .atomic)
        _ = chmod(url.path, 0o600)
    }
    /// Bounded, symlink-refusing read. nil when absent or unreadable.
    public static func read(data: URL) -> SupervisorStatus? {
        let fd = open(file(data: data).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size >= 0, info.st_size <= 65_536,
              let bytes = try? handle.readToEnd() else { return nil }
        return try? JSONDecoder().decode(SupervisorStatus.self, from: bytes)
    }
    public static func isAlive(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Wake requests: an empty file `<data>/supervisor-wakes/<role>`. The supervisor removes it.
public enum SupervisorWakes {
    public static func directory(data: URL) -> URL { data.appendingPathComponent("supervisor-wakes", isDirectory: true) }
    public static func file(data: URL, role: SupervisorRole) -> URL { directory(data: data).appendingPathComponent(role.rawValue) }
    /// Only the baseline and inventory roles can be woken; the check runs on its own schedule.
    public static func role(fileName: String) -> SupervisorRole? {
        guard let role = SupervisorRole(rawValue: fileName), role != .check else { return nil }
        return role
    }
    /// Writes a wake request. Callers decide whether monitoring is installed for this data directory.
    public static func request(data: URL, role: SupervisorRole) throws {
        precondition(role != .check, "the capacity check is not woken by request")
        let folder = directory(data: data)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(data: data, role: role)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// What the scheduler knows about one role.
public struct SupervisorRoleState: Equatable, Sendable {
    public var running = false
    public var lastStart: Double?
    public var lastExit: Int32?
    public var wakePending = false
    public init(running: Bool = false, lastStart: Double? = nil, lastExit: Int32? = nil, wakePending: Bool = false) {
        self.running = running; self.lastStart = lastStart; self.lastExit = lastExit; self.wakePending = wakePending
    }
}

public enum SupervisorSchedule {
    public static let slotLength: Double = 1_800

    /// Index of the wall-clock half hour (:00/:30 local time) containing `time`.
    public static func slot(_ time: Double, utcOffset: Double) -> Int64 { Int64(((time + utcOffset) / slotLength).rounded(.down)) }

    /// Whether a role should start now. Never true for a running role, so two instances of one role cannot overlap.
    /// - check: at launch, once per half-hour slot (a slot missed during sleep runs once, on wake), or when a
    ///   mount / registry trigger is pending.
    /// - baseline / inventory: at launch, on a pending wake, or after a non-zero exit once the throttle has elapsed.
    ///   After a clean exit they stay idle until woken.
    public static func shouldStart(_ role: SupervisorRole, state: SupervisorRoleState, trigger: Bool = false, now: Double, utcOffset: Double) -> Bool {
        if state.running { return false }
        guard let started = state.lastStart else { return true }
        switch role {
        case .check:
            return trigger || slot(now, utcOffset: utcOffset) != slot(started, utcOffset: utcOffset)
        case .baseline, .inventory:
            if state.wakePending { return true }
            if let exit = state.lastExit, exit != 0, let throttle = role.restartThrottle { return now - started >= throttle }
            return false
        }
    }

    /// An exit that launchd's KeepAlive SuccessfulExit=false would restart. 75 (resumable) is a non-zero exit too.
    public static func isResumableExit(_ code: Int32?) -> Bool { code == 75 }

    /// A mount is only a new entry in /Volumes; removals are not StartOnMount events.
    public static func hasNewMount(previous: Set<String>, current: Set<String>) -> Bool { !current.subtracting(previous).isEmpty }

    /// Wake files present now, for roles that can be woken. A running role's wake is a no-op (kickstart without -k).
    public static func resolveWakes(fileNames: [String], running: Set<SupervisorRole>) -> (pending: Set<SupervisorRole>, discard: Set<SupervisorRole>) {
        var pending = Set<SupervisorRole>(), discard = Set<SupervisorRole>()
        for name in fileNames {
            guard let role = SupervisorWakes.role(fileName: name) else { continue }
            if running.contains(role) { discard.insert(role) } else { pending.insert(role) }
        }
        return (pending, discard)
    }
}

/// Cheap change signature for a file that may not exist yet.
public struct FileSignature: Equatable, Sendable {
    public let inode: UInt64, size: Int64, modified: Int64
    public static func of(_ path: String) -> FileSignature? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileSignature(inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
    }
}
