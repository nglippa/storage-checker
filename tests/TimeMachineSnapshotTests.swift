import Foundation
import Darwin

private final class FakeRunner: TimeMachineSnapshotCreating, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    var result: TimeMachineSnapshotCommandResult
    var entered: DispatchSemaphore?
    var release: DispatchSemaphore?

    init(_ result: TimeMachineSnapshotCommandResult) { self.result = result }

    func createLocalSnapshot() -> TimeMachineSnapshotCommandResult {
        lock.lock(); calls += 1; lock.unlock()
        entered?.signal(); release?.wait()
        return result
    }
}

@main
struct TimeMachineSnapshotTests {
    static func main() throws {
        testFixedCommandSpecification()
        try testReportedCreationAndColdReload()
        try testFailureAndUncertainOutcomes()
        try testInterruptedRecoveryAndAcknowledgement()
        try testMalformedAndSymlinkRefusal()
        try testFailedIntentPreventsInvocation()
        try testCrossInstanceLock()
        print("Time Machine snapshot tests passed")
    }

    private static func testFixedCommandSpecification() {
        let value = SystemTimeMachineSnapshotCommand.specification
        expect(value.executable == "/usr/bin/tmutil", "uses fixed tmutil path")
        expect(value.arguments == ["localsnapshot"], "uses only the localsnapshot verb")
        expect(value.environment == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], "sanitizes environment")
        expect(value.nullStandardInput && value.mergedStandardOutputAndError, "nulls stdin and merges diagnostic output")
        expect(value.outputLimit == 64 * 1024 && value.timeout == 120, "bounds output and runtime")
        let forbidden = ([value.executable] + value.arguments).joined(separator: " ").lowercased()
        expect(!forbidden.contains("sudo") && !forbidden.contains("delete") && !forbidden.contains("destination") && !forbidden.contains("enable") && !forbidden.contains("disable"), "contains no shell, deletion, or settings command")
    }

    private static func testReportedCreationAndColdReload() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner(.init(exitStatus: 0, output: "Created local snapshot with date: 2026-11-12-141501\n", timedOut: false, outputTruncated: false))
        let history = TimeMachineSnapshotHistory(directory: root.appendingPathComponent("History"), runner: runner)
        let created = try history.create()
        expect(created.outcome == .reportedCreated && created.returnedTimestampToken == "2026-11-12-141501", "accepts exact tmutil success line")
        expect(created.exitCode == 0 && created.finishedAt != nil, "records completed command")
        let cold = TimeMachineSnapshotHistory(directory: root.appendingPathComponent("History"), runner: runner)
        let reloaded = try cold.load()
        expect(reloaded == [created], "durable history survives cold reload")
        expect(mode(root.appendingPathComponent("History")) == 0o700, "history directory is private")
        expect(mode(root.appendingPathComponent("History/history.json")) == 0o600, "history file is private")
    }

    private static func testFailureAndUncertainOutcomes() throws {
        let cases: [(TimeMachineSnapshotCommandResult, TimeMachineSnapshotOutcome, String)] = [
            (.init(exitStatus: 1, output: "Operation not permitted", timedOut: false, outputTruncated: false), .failed, "nonzero permission denial"),
            (.init(exitStatus: 0, output: "", timedOut: false, outputTruncated: false), .uncertain, "zero with no report"),
            (.init(exitStatus: 0, output: "Created local snapshot with date: 2026-11-12-141501\n", timedOut: true, outputTruncated: false), .uncertain, "timeout"),
            (.init(exitStatus: 0, output: "Created local snapshot with date: 2026-11-12-141501\n", timedOut: false, outputTruncated: true), .uncertain, "truncation")
        ]
        for (result, outcome, label) in cases {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let runner = FakeRunner(result)
            let activity = try TimeMachineSnapshotHistory(directory: root.appendingPathComponent("History"), runner: runner).create()
            expect(activity.outcome == outcome, "\(label) has conservative outcome")
            expect(activity.output == result.output, "\(label) preserves bounded raw output")
            if outcome != .reportedCreated { expect(activity.returnedTimestampToken == nil, "\(label) claims no timestamp") }
        }
    }

    private static func testInterruptedRecoveryAndAcknowledgement() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("History")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let started = TimeMachineSnapshotActivity(startedAt: Date(timeIntervalSince1970: 100))
        let payload: [String: Any] = [
            "schema": 1,
            "activities": [["id": started.id.uuidString, "startedAt": 100, "outcome": "started", "output": ""]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: directory.appendingPathComponent("history.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("history.json").path)
        let runner = FakeRunner(.init(exitStatus: 0, output: "Created local snapshot with date: 2026-11-12-141501\n", timedOut: false, outputTruncated: false))
        let history = TimeMachineSnapshotHistory(directory: directory, runner: runner)
        let recovered = try history.load()
        expect(recovered.count == 1 && recovered[0].outcome == .interrupted, "cold started intent recovers as interrupted")
        expectThrows(.acknowledgementRequired, "unresolved interrupted result blocks automatic retry") { _ = try history.create() }
        expect(runner.calls == 0, "acknowledgement gate does not invoke tmutil")
        let next = try history.create(acknowledgeUncertain: true)
        expect(next.outcome == .reportedCreated && runner.calls == 1, "explicit acknowledgement permits a new request")
    }

    private static func testMalformedAndSymlinkRefusal() throws {
        do {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("History")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("not json".utf8).write(to: directory.appendingPathComponent("history.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("history.json").path)
            expectThrows(.corruptHistory, "malformed history is refused") {
                _ = try TimeMachineSnapshotHistory(directory: directory, runner: FakeRunner(ok())).load()
            }
        }
        do {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("History")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let target = root.appendingPathComponent("target")
            try Data("{}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("history.json"), withDestinationURL: target)
            expectThrows(.unsafeStorage, "symlink history is refused") {
                _ = try TimeMachineSnapshotHistory(directory: directory, runner: FakeRunner(ok())).load()
            }
        }
    }

    private static func testFailedIntentPreventsInvocation() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner(ok())
        let history = TimeMachineSnapshotHistory(directory: root.appendingPathComponent("History"), runner: runner) {
            throw TimeMachineSnapshotHistoryError.persistenceFailed
        }
        expectThrows(.persistenceFailed, "failed durable intent aborts request") { _ = try history.create() }
        expect(runner.calls == 0, "failed intent persistence causes zero invocations")
    }

    private static func testCrossInstanceLock() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("History")
        let firstRunner = FakeRunner(ok()), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        firstRunner.entered = entered; firstRunner.release = release
        let first = TimeMachineSnapshotHistory(directory: directory, runner: firstRunner)
        let secondRunner = FakeRunner(ok())
        let second = TimeMachineSnapshotHistory(directory: directory, runner: secondRunner)
        let complete = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = try? first.create(); complete.signal() }
        expect(entered.wait(timeout: .now() + 3) == .success, "first instance holds lock while command runs")
        expectThrows(.commandInProgress, "second instance cannot overlap") { _ = try second.create() }
        expect(secondRunner.calls == 0, "rejected overlapping instance does not invoke tmutil")
        release.signal()
        expect(complete.wait(timeout: .now() + 3) == .success, "first command exits and releases lock")
    }

    private static func fixture() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-snapshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func ok() -> TimeMachineSnapshotCommandResult {
        .init(exitStatus: 0, output: "Created local snapshot with date: 2026-11-12-141501\n", timedOut: false, outputTruncated: false)
    }

    private static func mode(_ url: URL) -> Int {
        let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    private static func expectThrows(_ expected: TimeMachineSnapshotHistoryError, _ message: String, body: () throws -> Void) {
        do { try body(); fputs("FAIL: \(message)\n", stderr); exit(1) }
        catch let error as TimeMachineSnapshotHistoryError { expect(error == expected, "\(message): got \(error)") }
        catch { fputs("FAIL: \(message): unexpected \(error)\n", stderr); exit(1) }
    }
}
