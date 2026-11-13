import AppKit
import Darwin
import Foundation
import SwiftUI

struct OnDemandIndexCommandSpecification: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let outputLimit: Int
}

struct OnDemandIndexCommandResult: Equatable, Sendable {
    let exitStatus: Int32?
    let output: String
    let timedOut: Bool
    let cancelled: Bool
    let launchError: String?
    let diagnostics: String

    init(exitStatus: Int32?, output: String, timedOut: Bool = false, cancelled: Bool = false, launchError: String? = nil, diagnostics: String = "") {
        self.exitStatus = exitStatus
        self.output = output
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.launchError = launchError
        self.diagnostics = diagnostics
    }
}

protocol OnDemandIndexCommandRunning: AnyObject, Sendable {
    func run(_ specification: OnDemandIndexCommandSpecification) async -> OnDemandIndexCommandResult
    func cancel()
}

private final class OnDemandIndexOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if remaining > 0 { data.append(chunk.prefix(remaining)) }
        if chunk.count > remaining { truncated = true }
    }

    func value() -> String {
        lock.lock(); defer { lock.unlock() }
        var text = String(decoding: data, as: UTF8.self)
        if truncated { text += "\n[output truncated]" }
        return text
    }
}

final class SystemOnDemandIndexCommandRunner: OnDemandIndexCommandRunning, @unchecked Sendable {
    private struct Active {
        let id: UUID
        var process: Process?
        var cancelled: Bool
    }

    private let lock = NSLock()
    private var active: Active?

    func run(_ specification: OnDemandIndexCommandSpecification) async -> OnDemandIndexCommandResult {
        let id = UUID()
        guard begin(id: id) else {
            return .init(exitStatus: nil, output: "", launchError: "An on-demand index command is already running.")
        }
        return await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .utility) { [self] in execute(specification, id: id) }.value
        }, onCancel: { [self] in cancel() })
    }

    private func begin(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { return false }
        active = Active(id: id, process: nil, cancelled: false)
        return true
    }

    func cancel() {
        lock.lock()
        guard var current = active else { lock.unlock(); return }
        current.cancelled = true
        active = current
        let process = current.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func execute(_ specification: OnDemandIndexCommandSpecification, id: UUID) -> OnDemandIndexCommandResult {
        let process = Process(), pipe = Pipe(), errorPipe = Pipe()
        let capture = OnDemandIndexOutputCapture(limit: specification.outputLimit)
        let errors = OnDemandIndexOutputCapture(limit: specification.outputLimit)
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        let descriptor = readHandle.fileDescriptor
        let errorDescriptor = errorPipe.fileHandleForReading.fileDescriptor
        for fd in [descriptor, errorDescriptor] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                finish(id: id)
                return .init(exitStatus: nil, output: "", launchError: "Cannot prepare nonblocking index output capture.")
            }
        }
        process.executableURL = specification.executable
        process.arguments = specification.arguments
        process.environment = specification.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = errorPipe

        func drain(_ fd: Int32, into destination: OnDemandIndexOutputCapture, maximumBytes: Int = 64 * 1024) {
            var remaining = maximumBytes
            var buffer = [UInt8](repeating: 0, count: 8192)
            while remaining > 0 {
                let requested = min(remaining, buffer.count)
                let count = Darwin.read(fd, &buffer, requested)
                if count > 0 {
                    destination.append(Data(buffer.prefix(count)))
                    remaining -= count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        func drainOutput() { drain(descriptor, into: capture); drain(errorDescriptor, into: errors) }

        func closePipe() {
            try? writeHandle.close()
            try? readHandle.close()
            try? errorPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForReading.close()
        }

        lock.lock()
        guard var current = active, current.id == id else {
            lock.unlock(); closePipe()
            return .init(exitStatus: nil, output: "", cancelled: true)
        }
        if current.cancelled {
            active = nil
            lock.unlock(); closePipe()
            return .init(exitStatus: nil, output: "", cancelled: true)
        }
        current.process = process
        active = current
        lock.unlock()

        do { try process.run() }
        catch {
            try? writeHandle.close()
            try? errorPipe.fileHandleForWriting.close()
            drainOutput()
            closePipe()
            finish(id: id)
            return .init(exitStatus: nil, output: capture.value(), launchError: error.localizedDescription)
        }
        // The launched child owns its duplicated write descriptor. Keeping the parent copy open
        // would make EOF impossible even after the child exits.
        try? writeHandle.close()
        try? errorPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(specification.timeout)
        var timedOut = false, cancelled = false
        while process.isRunning {
            lock.lock(); cancelled = active?.id == id ? (active?.cancelled ?? true) : true; lock.unlock()
            if cancelled { break }
            if Date() >= deadline { timedOut = true; break }
            drainOutput()
            Thread.sleep(forTimeInterval: 0.025)
        }
        if (cancelled || timedOut), process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        // Never wait for EOF: a descendant could have inherited stdout after this child exited.
        drainOutput()
        closePipe()
        finish(id: id)
        return .init(exitStatus: process.terminationStatus, output: capture.value(), timedOut: timedOut, cancelled: cancelled, diagnostics: errors.value())
    }

    private func finish(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if active?.id == id { active = nil }
    }
}

@MainActor final class OnDemandIndexController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var database: String?
    @Published private(set) var volumeUUID: String?
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    @Published private(set) var revision = 0

    private struct Summary: Decodable {
        let outcome: String
        let status: String
        let continues: Bool
        let reason: String
    }

    private let runner: any OnDemandIndexCommandRunning
    private var session: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var terminating = false
    private static let budgetSeconds = 240
    private static let commandTimeout: TimeInterval = 310
    private static let outputLimit = 256 * 1024

    init(runner: any OnDemandIndexCommandRunning = SystemOnDemandIndexCommandRunner()) {
        self.runner = runner
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.terminating = true
                self?.stop()
            }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    @discardableResult
    func start(executable: URL?, database: String, baseDirectory: URL? = nil, volumeUUID: String? = nil, isQA: Bool) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        guard !terminating else { return nil }
        error = nil; message = nil
        guard !isQA else {
            error = "On-demand indexing is disabled in read-only QA sessions."; revision += 1; return nil
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            error = "The Storage Monitor executable is missing. Rebuild or reinstall the app, then try Start Index again."; revision += 1; return nil
        }
        let canonicalUUID: String?
        if let volumeUUID {
            guard let parsed = UUID(uuidString: volumeUUID) else {
                error = "The selected external volume identifier is invalid. Reload the drive list and try again."; revision += 1; return nil
            }
            canonicalUUID = parsed.uuidString
        } else { canonicalUUID = nil }

        let retainedDatabase = URL(fileURLWithPath: database).standardizedFileURL.path
        let dataDirectory = (baseDirectory?.standardizedFileURL ?? URL(fileURLWithPath: retainedDatabase).deletingLastPathComponent()).path
        var arguments = ["inventory-index", "--data-dir", dataDirectory, "--budget", String(Self.budgetSeconds)]
        if let canonicalUUID { arguments += ["--uuid", canonicalUUID] }
        let specification = OnDemandIndexCommandSpecification(
            executable: executable,
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"],
            timeout: Self.commandTimeout,
            outputLimit: Self.outputLimit
        )

        self.database = retainedDatabase
        self.volumeUUID = canonicalUUID
        isRunning = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSession(specification)
        }
        session = task
        return task
    }

    func stop() {
        guard isRunning else { return }
        session?.cancel(); runner.cancel(); message = "Stopping on-demand indexing…"
    }

    private func runSession(_ specification: OnDemandIndexCommandSpecification) async {
        defer { isRunning = false; session = nil; revision += 1 }
        while !Task.isCancelled {
            let result = await runner.run(specification)
            revision += 1
            if result.cancelled || Task.isCancelled { message = "On-demand indexing stopped."; return }
            if result.timedOut { error = "The indexing slice exceeded its time limit and was stopped. It was not retried."; return }
            if let launchError = result.launchError { error = "The Storage Monitor executable could not be started: \(launchError)"; return }
            guard result.exitStatus == 0 else {
                let detail = (result.output + "\n" + result.diagnostics).trimmingCharacters(in: .whitespacesAndNewlines)
                error = detail.isEmpty
                    ? "The indexing slice failed with status \(result.exitStatus.map(String.init) ?? "unknown"). It was not retried."
                    : "The indexing slice failed with status \(result.exitStatus.map(String.init) ?? "unknown"): \(detail)"
                return
            }
            guard let summary = decodeSummary(result.output) else {
                error = "The indexing slice returned a missing or malformed summary. It was not retried."; return
            }
            if summary.outcome == "failed" || summary.status == "failed" {
                error = summary.reason.isEmpty ? "The indexing slice reported a failure. It was not retried." : summary.reason
                return
            }
            if summary.outcome == "busy" {
                error = summary.reason.isEmpty ? "Another indexing process is using this target. Try Start Index again after it finishes." : summary.reason
                return
            }
            message = summary.reason.isEmpty ? "Indexing \(summary.status) (\(summary.outcome))." : summary.reason
            error = nil
            guard shouldContinue(summary) else { return }
        }
        message = "On-demand indexing stopped."
    }

    private func decodeSummary(_ output: String) -> Summary? {
        guard let data = output.data(using: .utf8),
              let summary = try? JSONDecoder().decode(Summary.self, from: data),
              ["complete", "partial", "busy", "failed"].contains(summary.outcome),
              ["completed", "continuing", "deferred", "paused", "skipped", "failed"].contains(summary.status) else { return nil }
        return summary
    }

    private func shouldContinue(_ summary: Summary) -> Bool {
        summary.continues && summary.status == "continuing" && ["complete", "partial"].contains(summary.outcome)
    }
}
