import Foundation
import AppKit

private final class FakeOnDemandIndexRunner: OnDemandIndexCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [OnDemandIndexCommandResult]
    private var specifications: [OnDemandIndexCommandSpecification] = []
    private var cancelled = false
    private let delayNanoseconds: UInt64
    private var cancelCalls = 0

    init(_ results: [OnDemandIndexCommandResult], delayNanoseconds: UInt64 = 0) {
        queued = results; self.delayNanoseconds = delayNanoseconds
    }
    var calls: Int { lock.withLock { specifications.count } }
    var specs: [OnDemandIndexCommandSpecification] { lock.withLock { specifications } }
    var cancellations: Int { lock.withLock { cancelCalls } }

    func run(_ specification: OnDemandIndexCommandSpecification) async -> OnDemandIndexCommandResult {
        let result = lock.withLock { () -> OnDemandIndexCommandResult in
            specifications.append(specification)
            return queued.isEmpty ? .init(exitStatus: 0, output: summary(outcome: "complete", status: "completed", continues: false)) : queued.removeFirst()
        }
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        return lock.withLock { cancelled ? .init(exitStatus: nil, output: "", cancelled: true) : result }
    }
    func cancel() { lock.withLock { cancelled = true; cancelCalls += 1 } }
}

@main struct OnDemandIndexTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--fixture-output") {
            FileHandle.standardOutput.write(Data(repeating: 65, count: 1024 * 1024))
            return
        }
        if CommandLine.arguments.contains("--fixture-diagnostics") {
            FileHandle.standardError.write(Data("fixture warning\n".utf8))
            FileHandle.standardOutput.write(Data(summary(outcome: "complete", status: "completed", continues: false).utf8))
            return
        }
        await testSystemRunnerLaunchFailureReturnsPromptly()
        await testSystemRunnerTimeoutTerminatesChild()
        await testSystemRunnerBoundsOutput()
        let separated = await SystemOnDemandIndexCommandRunner().run(systemSpec(executable: URL(fileURLWithPath: CommandLine.arguments[0]), arguments: ["--fixture-diagnostics"]))
        expect(separated.exitStatus == 0 && separated.diagnostics.contains("fixture warning") && (try? JSONSerialization.jsonObject(with: Data(separated.output.utf8))) != nil, "stderr diagnostics cannot corrupt the stdout command summary")
        await testContinuationAndExactCommand()
        await testTerminalStatesNeverRetry()
        await testMalformedNonzeroAndTimeoutNeverRetry()
        await testBusyGateAndTargetStability()
        testQAAndMissingExecutableNeverLaunch()
        await testCancellation()
        await testApplicationQuitStopsContinuation()
        print("On-demand index tests passed")
    }

    private static func systemSpec(executable: URL, arguments: [String] = [], timeout: TimeInterval = 1, outputLimit: Int = 4096) -> OnDemandIndexCommandSpecification {
        .init(executable: executable, arguments: arguments, environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: timeout, outputLimit: outputLimit)
    }

    private static func testSystemRunnerLaunchFailureReturnsPromptly() async {
        let runner = SystemOnDemandIndexCommandRunner(), began = Date()
        let result = await runner.run(systemSpec(executable: URL(fileURLWithPath: "/private/tmp/storage-monitor-no-such-executable-\(UUID().uuidString)")))
        expect(result.launchError != nil && Date().timeIntervalSince(began) < 1, "launch failure closes the pipe and returns promptly")
    }

    private static func testSystemRunnerTimeoutTerminatesChild() async {
        let runner = SystemOnDemandIndexCommandRunner(), began = Date()
        let result = await runner.run(systemSpec(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.05))
        expect(result.timedOut && !result.cancelled && Date().timeIntervalSince(began) < 1.5, "timeout terminates only the owned sleep process within its grace period")
    }

    private static func testSystemRunnerBoundsOutput() async {
        let runner = SystemOnDemandIndexCommandRunner()
        let result = await runner.run(systemSpec(executable: URL(fileURLWithPath: CommandLine.arguments[0]), arguments: ["--fixture-output"], timeout: 2, outputLimit: 1024))
        expect(result.exitStatus == 0 && !result.timedOut && result.output.utf8.count < 1200 && result.output.hasSuffix("[output truncated]"), "runner drains a large producer while bounding retained output")
    }

    @MainActor private static func testContinuationAndExactCommand() async {
        let runner = FakeOnDemandIndexRunner([
            .init(exitStatus: 0, output: summary(outcome: "partial", status: "continuing", continues: true, reason: "More work remains.")),
            .init(exitStatus: 0, output: summary(outcome: "complete", status: "completed", continues: false))
        ])
        let controller = OnDemandIndexController(runner: runner)
        let uuid = "11111111-1111-4111-8111-111111111111"
        await controller.start(executable: executable(), database: "/private/tmp/on-demand-a/catalog/inventory.sqlite3", baseDirectory: URL(fileURLWithPath: "/private/tmp/on-demand-a/app-state"), volumeUUID: uuid, isQA: false)?.value
        expect(runner.calls == 2, "continuing runnable summaries drain another bounded slice")
        expect(runner.specs.allSatisfy { $0.arguments == ["inventory-index", "--data-dir", "/private/tmp/on-demand-a/app-state", "--budget", "240", "--uuid", uuid.uppercased()] }, "every slice retains the root data directory, external target and fixed budget")
        expect(runner.specs.allSatisfy { $0.environment == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"] && $0.timeout == 310 && $0.outputLimit == 256 * 1024 }, "environment, deadline and output bound are fixed")
        expect(controller.database == "/private/tmp/on-demand-a/catalog/inventory.sqlite3" && controller.volumeUUID == uuid.uppercased(), "target identity remains published independently from the command data directory")
        expect(controller.message == "Indexing completed (complete)." && controller.error == nil && controller.revision == 3 && !controller.isRunning, "terminal result and revisions are published")
    }

    @MainActor private static func testTerminalStatesNeverRetry() async {
        let terminal = [("partial", "deferred"), ("partial", "paused"), ("partial", "skipped"), ("busy", "continuing"), ("failed", "failed"), ("partial", "completed")]
        for (outcome, status) in terminal {
            let runner = FakeOnDemandIndexRunner([.init(exitStatus: 0, output: summary(outcome: outcome, status: status, continues: true))])
            let controller = OnDemandIndexController(runner: runner)
            await controller.start(executable: executable(), database: "/private/tmp/on-demand-terminal/db.sqlite3", isQA: false)?.value
            expect(runner.calls == 1 && !controller.isRunning, "\(outcome)/\(status) is never retried")
            if outcome == "busy" || outcome == "failed" { expect(controller.error != nil, "\(outcome) is published as an actionable error") }
        }
    }

    @MainActor private static func testMalformedNonzeroAndTimeoutNeverRetry() async {
        let cases: [(OnDemandIndexCommandResult, String)] = [
            (.init(exitStatus: 0, output: "not json"), "malformed"),
            (.init(exitStatus: 0, output: "{\"outcome\":\"partial\",\"status\":\"continuing\",\"continues\":true}"), "malformed"),
            (.init(exitStatus: 7, output: "worker failed"), "status 7"),
            (.init(exitStatus: 0, output: "", timedOut: true), "time limit")
        ]
        for (result, expected) in cases {
            let runner = FakeOnDemandIndexRunner([result]), controller = OnDemandIndexController(runner: runner)
            await controller.start(executable: executable(), database: "/private/tmp/on-demand-errors/db.sqlite3", isQA: false)?.value
            expect(runner.calls == 1 && controller.error?.localizedCaseInsensitiveContains(expected) == true, "\(expected) terminates without retry")
            expect(controller.revision == 2, "result and termination each publish a revision")
        }
    }

    @MainActor private static func testBusyGateAndTargetStability() async {
        let runner = FakeOnDemandIndexRunner([.init(exitStatus: 0, output: summary(outcome: "complete", status: "completed", continues: false))], delayNanoseconds: 150_000_000)
        let controller = OnDemandIndexController(runner: runner)
        var displayedDatabase = "/private/tmp/on-demand-original/db.sqlite3"
        let first = controller.start(executable: executable(), database: displayedDatabase, volumeUUID: "22222222-2222-4222-8222-222222222222", isQA: false)
        displayedDatabase = "/private/tmp/on-demand-other/db.sqlite3"
        expect(first != nil && controller.isRunning && controller.start(executable: executable(), database: displayedDatabase, isQA: false) == nil, "busy gate refuses a duplicate synchronously")
        await first?.value
        expect(runner.calls == 1 && runner.specs[0].arguments.contains("/private/tmp/on-demand-original"), "display changes cannot redirect an active target")
        expect(controller.database == "/private/tmp/on-demand-original/db.sqlite3", "published database remains the session target")
    }

    @MainActor private static func testQAAndMissingExecutableNeverLaunch() {
        let runner = FakeOnDemandIndexRunner([]), controller = OnDemandIndexController(runner: runner)
        expect(controller.start(executable: executable(), database: "/Users/example/Library/Application Support/production.sqlite3", isQA: true) == nil, "QA is refused synchronously")
        expect(runner.calls == 0 && controller.database == nil && controller.error?.contains("QA") == true, "QA refusal precedes runner access and target retention")
        expect(controller.start(executable: nil, database: "/private/tmp/unused.sqlite3", isQA: false) == nil, "missing executable is refused")
        expect(runner.calls == 0 && controller.error?.contains("missing") == true, "missing executable is actionable without launching")
    }

    @MainActor private static func testCancellation() async {
        let runner = FakeOnDemandIndexRunner([.init(exitStatus: 0, output: summary(outcome: "partial", status: "continuing", continues: true))], delayNanoseconds: 2_000_000_000)
        let controller = OnDemandIndexController(runner: runner)
        let task = controller.start(executable: executable(), database: "/private/tmp/on-demand-cancel/db.sqlite3", isQA: false)
        while runner.calls == 0 { await Task.yield() }
        controller.stop(); await task?.value
        expect(runner.cancellations == 1 && runner.calls == 1, "stop cancels only the active runner and starts no new slice")
        expect(!controller.isRunning && controller.message == "On-demand indexing stopped." && controller.revision == 2, "cancel publishes result and termination")
    }
    @MainActor private static func testApplicationQuitStopsContinuation() async {
        let runner = FakeOnDemandIndexRunner([.init(exitStatus: 0, output: summary(outcome: "partial", status: "continuing", continues: true))], delayNanoseconds: 2_000_000_000)
        let controller = OnDemandIndexController(runner: runner)
        let task = controller.start(executable: executable(), database: "/private/tmp/on-demand-quit/db.sqlite3", isQA: false)
        while runner.calls == 0 { await Task.yield() }
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        await task?.value
        expect(!controller.isRunning && runner.calls == 1 && runner.cancellations == 1, "application quit stops the loop and its owned child before another slice")
        expect(controller.start(executable: executable(), database: "/private/tmp/unused.sqlite3", isQA: false) == nil, "termination prevents a late queued action from launching a new worker")
    }
}

private func executable() -> URL { URL(fileURLWithPath: "/usr/bin/true") }
private func summary(outcome: String, status: String, continues: Bool, reason: String = "") -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["outcome": outcome, "status": status, "continues": continues, "reason": reason], options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
