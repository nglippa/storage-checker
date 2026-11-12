import Foundation
import Darwin

public struct TimeMachineSnapshotCommandResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let output: String
    public let timedOut: Bool
    public let outputTruncated: Bool

    public init(exitStatus: Int32, output: String, timedOut: Bool, outputTruncated: Bool) {
        self.exitStatus = exitStatus
        self.output = output
        self.timedOut = timedOut
        self.outputTruncated = outputTruncated
    }
}

public protocol TimeMachineSnapshotCreating: Sendable {
    func createLocalSnapshot() -> TimeMachineSnapshotCommandResult
}

public struct TimeMachineSnapshotCommandSpecification: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let nullStandardInput: Bool
    public let mergedStandardOutputAndError: Bool
    public let outputLimit: Int
    public let timeout: TimeInterval
}

/// A synchronous adapter. GUI callers must invoke it from a background task.
public struct SystemTimeMachineSnapshotCommand: TimeMachineSnapshotCreating {
    public static let specification = TimeMachineSnapshotCommandSpecification(
        executable: "/usr/bin/tmutil",
        arguments: ["localsnapshot"],
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"],
        nullStandardInput: true,
        mergedStandardOutputAndError: true,
        outputLimit: 64 * 1024,
        timeout: 120
    )

    public init() {}

    public func createLocalSnapshot() -> TimeMachineSnapshotCommandResult {
        let spec = Self.specification
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        let capture = BoundedCommandCapture(limit: spec.outputLimit)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            capture.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            capture.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let message = "Unable to start /usr/bin/tmutil: \(error.localizedDescription)"
            return .init(exitStatus: -1, output: boundedTimeMachineOutput(message), timedOut: false, outputTruncated: capture.truncated)
        }

        let deadline = Date().addingTimeInterval(spec.timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        capture.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let value = capture.value()
        return .init(
            exitStatus: process.terminationStatus,
            output: value.output,
            timedOut: timedOut,
            outputTruncated: value.truncated
        )
    }
}

private final class BoundedCommandCapture: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private(set) var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if remaining > 0 { data.append(chunk.prefix(remaining)) }
        if chunk.count > remaining { truncated = true }
    }

    func value() -> (output: String, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (boundedTimeMachineOutput(String(decoding: data, as: UTF8.self)), truncated)
    }
}

public enum TimeMachineSnapshotOutcome: String, Codable, Sendable {
    case started
    case reportedCreated
    case failed
    case uncertain
    case interrupted
}

public struct TimeMachineSnapshotActivity: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var finishedAt: Date?
    public var outcome: TimeMachineSnapshotOutcome
    /// The timestamp token reported by tmutil, not a snapshot UUID or ownership assertion.
    public var returnedTimestampToken: String?
    public var output: String
    public var exitCode: Int32?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        outcome: TimeMachineSnapshotOutcome = .started,
        returnedTimestampToken: String? = nil,
        output: String = "",
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.returnedTimestampToken = returnedTimestampToken
        self.output = boundedTimeMachineOutput(output)
        self.exitCode = exitCode
    }
}

public enum TimeMachineSnapshotHistoryError: Error, Equatable, LocalizedError, Sendable {
    case unsafeStorage
    case corruptHistory
    case commandInProgress
    case acknowledgementRequired
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeStorage: return "Time Machine snapshot history storage is unsafe or has been replaced."
        case .corruptHistory: return "Time Machine snapshot history is corrupt; no command was run."
        case .commandInProgress: return "Another Time Machine local snapshot request is already in progress."
        case .acknowledgementRequired: return "The previous request has an uncertain outcome. Acknowledge it before requesting another snapshot."
        case .persistenceFailed: return "The snapshot request could not be recorded durably, so no command was run or its outcome remains unknown."
        }
    }
}

private struct TimeMachineSnapshotJournal: Codable {
    var schema = 1
    var activities: [TimeMachineSnapshotActivity] = []
}

/// A private per-user journal. It records OS-reported creation only; it never adopts or owns snapshots.
public final class TimeMachineSnapshotHistory: @unchecked Sendable {
    public let directory: URL
    private let runner: any TimeMachineSnapshotCreating
    private let uid = getuid()
    private let beforeIntentCommit: (@Sendable () throws -> Void)?
    private static let historyLimit = 200
    private static let fileLimit = 1024 * 1024

    public init(directory: URL, runner: any TimeMachineSnapshotCreating) {
        self.directory = directory
        self.runner = runner
        self.beforeIntentCommit = nil
    }

    init(
        directory: URL,
        runner: any TimeMachineSnapshotCreating,
        beforeIntentCommit: (@Sendable () throws -> Void)?
    ) {
        self.directory = directory
        self.runner = runner
        self.beforeIntentCommit = beforeIntentCommit
    }

    public func load() throws -> [TimeMachineSnapshotActivity] {
        try prepareDirectory()
        let lock = try openLock()
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw TimeMachineSnapshotHistoryError.unsafeStorage }
            return try readJournal().activities
        }
        defer { _ = flock(lock, LOCK_UN) }
        var journal = try readJournal()
        if recoverInterrupted(in: &journal) {
            try save(journal)
        }
        return journal.activities
    }

    public func create(acknowledgeUncertain: Bool = false) throws -> TimeMachineSnapshotActivity {
        try prepareDirectory()
        let lock = try openLock()
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw TimeMachineSnapshotHistoryError.commandInProgress }
            throw TimeMachineSnapshotHistoryError.unsafeStorage
        }
        defer { _ = flock(lock, LOCK_UN) }

        var journal = try readJournal()
        if recoverInterrupted(in: &journal) { try save(journal) }
        if !acknowledgeUncertain && journal.activities.contains(where: { $0.outcome == .uncertain || $0.outcome == .interrupted }) {
            throw TimeMachineSnapshotHistoryError.acknowledgementRequired
        }

        let intent = TimeMachineSnapshotActivity()
        journal.activities.append(intent)
        journal.activities = Array(journal.activities.suffix(Self.historyLimit))
        do {
            try beforeIntentCommit?()
            try save(journal)
        } catch {
            throw TimeMachineSnapshotHistoryError.persistenceFailed
        }

        let result = runner.createLocalSnapshot()
        var final = intent
        final.finishedAt = Date()
        final.exitCode = result.exitStatus
        final.output = boundedTimeMachineOutput(result.output)
        if result.timedOut || result.outputTruncated {
            final.outcome = .uncertain
        } else if result.exitStatus != 0 {
            final.outcome = .failed
        } else if let token = strictTimeMachineTimestamp(in: result.output) {
            final.outcome = .reportedCreated
            final.returnedTimestampToken = token
        } else {
            final.outcome = .uncertain
        }

        guard let index = journal.activities.firstIndex(where: { $0.id == intent.id }) else {
            throw TimeMachineSnapshotHistoryError.persistenceFailed
        }
        journal.activities[index] = final
        do { try save(journal) }
        catch { throw TimeMachineSnapshotHistoryError.persistenceFailed }
        return final
    }

    private func prepareDirectory() throws {
        var parent = stat()
        let parentPath = directory.deletingLastPathComponent().path
        guard lstat(parentPath, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == uid, parent.st_mode & 0o022 == 0 else {
            throw TimeMachineSnapshotHistoryError.unsafeStorage
        }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw TimeMachineSnapshotHistoryError.unsafeStorage
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == uid, info.st_mode & 0o777 == 0o700 else {
            throw TimeMachineSnapshotHistoryError.unsafeStorage
        }
    }

    private func openLock() throws -> Int32 {
        let path = directory.appendingPathComponent("create.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TimeMachineSnapshotHistoryError.unsafeStorage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == uid,
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(fd); throw TimeMachineSnapshotHistoryError.unsafeStorage
        }
        return fd
    }

    private func readJournal() throws -> TimeMachineSnapshotJournal {
        let path = directory.appendingPathComponent("history.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return TimeMachineSnapshotJournal() }
        guard fd >= 0 else { throw TimeMachineSnapshotHistoryError.unsafeStorage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == uid,
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size >= 0,
              info.st_size <= Self.fileLimit else { throw TimeMachineSnapshotHistoryError.unsafeStorage }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard let journal = try? JSONDecoder().decode(TimeMachineSnapshotJournal.self, from: data),
              valid(journal) else { throw TimeMachineSnapshotHistoryError.corruptHistory }
        return journal
    }

    private func valid(_ journal: TimeMachineSnapshotJournal) -> Bool {
        guard journal.schema == 1, journal.activities.count <= Self.historyLimit,
              Set(journal.activities.map(\.id)).count == journal.activities.count else { return false }
        return journal.activities.allSatisfy { activity in
            guard activity.startedAt.timeIntervalSince1970.isFinite,
                  activity.output.utf8.count <= SystemTimeMachineSnapshotCommand.specification.outputLimit else { return false }
            if activity.outcome == .started {
                return activity.finishedAt == nil && activity.returnedTimestampToken == nil && activity.exitCode == nil
            }
            guard let finished = activity.finishedAt,
                  finished.timeIntervalSince1970.isFinite, finished >= activity.startedAt else { return false }
            if activity.outcome == .reportedCreated {
                return activity.exitCode == 0 && activity.returnedTimestampToken.map(validTimeMachineTimestamp) == true
            }
            return activity.returnedTimestampToken == nil
        }
    }

    private func recoverInterrupted(in journal: inout TimeMachineSnapshotJournal) -> Bool {
        var changed = false
        for index in journal.activities.indices where journal.activities[index].outcome == .started {
            journal.activities[index].outcome = .interrupted
            journal.activities[index].finishedAt = Date()
            journal.activities[index].output = "The prior request ended without a durable result. Creation is unknown; it was not retried."
            changed = true
        }
        return changed
    }

    private func save(_ journal: TimeMachineSnapshotJournal) throws {
        guard valid(journal), let data = try? JSONEncoder().encode(journal), data.count <= Self.fileLimit else {
            throw TimeMachineSnapshotHistoryError.persistenceFailed
        }
        let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TimeMachineSnapshotHistoryError.persistenceFailed }
        var installed = false
        defer { close(fd); if !installed { unlink(temporary.path) } }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw TimeMachineSnapshotHistoryError.persistenceFailed }
                    offset += count
                }
            }
            guard fsync(fd) == 0,
                  rename(temporary.path, directory.appendingPathComponent("history.json").path) == 0 else {
                throw TimeMachineSnapshotHistoryError.persistenceFailed
            }
            installed = true
            let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFD >= 0 else { throw TimeMachineSnapshotHistoryError.persistenceFailed }
            defer { close(dirFD) }
            guard fsync(dirFD) == 0 else { throw TimeMachineSnapshotHistoryError.persistenceFailed }
        } catch {
            throw TimeMachineSnapshotHistoryError.persistenceFailed
        }
    }
}

private func strictTimeMachineTimestamp(in output: String) -> String? {
    let prefix = "Created local snapshot with date: "
    let matches = output.split(whereSeparator: \Character.isNewline).compactMap { line -> String? in
        let value = String(line)
        guard value.hasPrefix(prefix) else { return nil }
        let token = String(value.dropFirst(prefix.count))
        return validTimeMachineTimestamp(token) ? token : nil
    }
    return matches.count == 1 ? matches[0] : nil
}

private func validTimeMachineTimestamp(_ token: String) -> Bool {
    guard token.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$", options: .regularExpression) != nil else { return false }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    formatter.isLenient = false
    return formatter.date(from: token) != nil
}

private func boundedTimeMachineOutput(_ value: String) -> String {
    let limit = SystemTimeMachineSnapshotCommand.specification.outputLimit
    if value.utf8.count <= limit { return value }
    var result = ""
    result.reserveCapacity(limit)
    var count = 0
    for character in value {
        let size = String(character).utf8.count
        if count + size > limit { break }
        result.append(character); count += size
    }
    return result
}
