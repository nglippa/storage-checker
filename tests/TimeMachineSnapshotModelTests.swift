import Foundation
import Darwin

private final class ModelFakeRunner: TimeMachineSnapshotCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [TimeMachineSnapshotCommandResult]
    private var callCount = 0
    private var mainThreadCalls = 0
    var entered: DispatchSemaphore?
    var release: DispatchSemaphore?

    init(_ results: [TimeMachineSnapshotCommandResult] = [ModelFakeRunner.ok()]) {
        self.results = results
    }

    var calls: Int { lock.withLock { callCount } }
    var callsOnMainThread: Int { lock.withLock { mainThreadCalls } }
    func waitUntilEntered() -> Bool { entered?.wait(timeout: .now() + 3) == .success }

    func createLocalSnapshot() -> TimeMachineSnapshotCommandResult {
        let result = lock.withLock { () -> TimeMachineSnapshotCommandResult in
            callCount += 1
            if Thread.isMainThread { mainThreadCalls += 1 }
            return results[min(callCount - 1, results.count - 1)]
        }
        entered?.signal()
        release?.wait()
        return result
    }

    static func ok(_ token: String = "2026-11-12-141501") -> TimeMachineSnapshotCommandResult {
        .init(exitStatus: 0, output: "Created local snapshot with date: \(token)\n", timedOut: false, outputTruncated: false)
    }
}

@main
struct TimeMachineSnapshotModelTests {
    @MainActor
    static func main() async throws {
        try await testBusyDoubleRequestOffMainAndHelperIndependence()
        try await testQAHasNoCommandsOrJournalWrites()
        try await testAcknowledgementFlowAndExactMapping()
        try await testInterruptedRecoveryReload()
        try await testLoadErrorMapping()
        try await testRequestErrorMapping()
        testTimeMachineInventoryCannotBecomeManaged()
        print("Time Machine snapshot model tests passed")
    }

    @MainActor
    private static func testBusyDoubleRequestOffMainAndHelperIndependence() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ModelFakeRunner()
        runner.entered = DispatchSemaphore(value: 0)
        runner.release = DispatchSemaphore(value: 0)
        let model = SnapshotManagementModel(isQA: false, timeMachineDirectory: root.appendingPathComponent("History"), timeMachineRunner: runner)
        model.available = false
        model.response.volumes = [unsupportedVolume()]
        model.volumeID = model.response.volumes[0].id

        let first = model.requestTimeMachineSnapshot()
        expect(first != nil && model.tmBusy, "request marks Time Machine work busy synchronously")
        expect(model.requestTimeMachineSnapshot() == nil, "a second model request cannot overlap")
        let didEnter = await Task.detached { runner.waitUntilEntered() }.value
        expect(didEnter, "fake runner starts")
        expect(runner.calls == 1, "busy gate permits exactly one invocation")
        runner.release?.signal()
        await first?.value

        expect(!model.tmBusy, "busy clears after request")
        expect(runner.callsOnMainThread == 0, "synchronous runner executes off the main thread")
        expect(model.tmActivities.first?.outcome == .reportedCreated, "request succeeds without helper availability")
        expect(model.volume?.compatibilityIssue != nil, "fixture actually uses an unsupported selected volume")
    }

    @MainActor
    private static func testQAHasNoCommandsOrJournalWrites() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("History")
        let runner = ModelFakeRunner()
        let model = SnapshotManagementModel(isQA: true, timeMachineDirectory: directory, timeMachineRunner: runner)

        expect(model.loadTimeMachineHistory() == nil, "QA load avoids the mutating history backend")
        expect(model.requestTimeMachineSnapshot() == nil, "QA request is refused before scheduling work")
        expect(runner.calls == 0, "QA never invokes the command runner")
        expect(!FileManager.default.fileExists(atPath: directory.path), "QA creates no history directory or journal")
        expect(model.tmActivities.isEmpty && !model.tmBusy, "QA retains an empty, idle history model")
        try seedStartedJournal(directory: directory)
        let before = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        await model.loadTimeMachineHistory()?.value
        await model.requestTimeMachineSnapshot(acknowledgeUncertain: true)?.value
        let after = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        expect(before == after && runner.calls == 0, "QA neither recovers existing intents nor permits an acknowledged command")
    }

    @MainActor
    private static func testAcknowledgementFlowAndExactMapping() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let uncertain = TimeMachineSnapshotCommandResult(exitStatus: 0, output: "No reported token\n", timedOut: false, outputTruncated: false)
        let runner = ModelFakeRunner([uncertain, ModelFakeRunner.ok("2026-11-12-141502")])
        let model = SnapshotManagementModel(isQA: false, timeMachineDirectory: root.appendingPathComponent("History"), timeMachineRunner: runner)

        await model.requestTimeMachineSnapshot()?.value
        expect(model.tmActivities.first?.outcome == .uncertain, "uncertain command result is published")
        expect(!model.tmNeedsAcknowledgement, "the request producing uncertainty does not auto-open acknowledgement")

        await model.requestTimeMachineSnapshot()?.value
        expect(runner.calls == 1, "unacknowledged uncertainty blocks a retry before runner invocation")
        expect(model.tmNeedsAcknowledgement, "acknowledgement-required error is exposed for UI")
        expect(model.tmError == TimeMachineSnapshotHistoryError.acknowledgementRequired.errorDescription, "acknowledgement error uses the exact backend description")
        expect(model.tmUncertainActivities.count == 1, "latest uncertain journal entries are reloaded for acknowledgement")

        model.tmNeedsAcknowledgement = false
        await model.requestTimeMachineSnapshot(acknowledgeUncertain: true)?.value
        expect(runner.calls == 2, "explicit acknowledgement permits exactly one new request")
        expect(model.tmActivities.first?.outcome == .reportedCreated, "acknowledged request publishes the new result")
        expect(!model.tmNeedsAcknowledgement && model.tmError == nil, "successful acknowledged request clears acknowledgement state")
    }

    @MainActor
    private static func testInterruptedRecoveryReload() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("History")
        try seedStartedJournal(directory: directory)
        let runner = ModelFakeRunner()
        let model = SnapshotManagementModel(isQA: false, timeMachineDirectory: directory, timeMachineRunner: runner)

        await model.loadTimeMachineHistory()?.value
        expect(model.tmActivities.count == 1 && model.tmActivities[0].outcome == .interrupted, "load publishes recovered interrupted intent")
        expect(!model.tmNeedsAcknowledgement, "history load alone does not prompt acknowledgement")
        await model.requestTimeMachineSnapshot()?.value
        expect(model.tmNeedsAcknowledgement && model.tmUncertainActivities.first?.outcome == .interrupted, "request reloads interrupted entry before prompting")
        expect(runner.calls == 0, "interrupted recovery is never auto-retried")
    }

    @MainActor
    private static func testLoadErrorMapping() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingParent = root.appendingPathComponent("missing/History")
        let model = SnapshotManagementModel(isQA: false, timeMachineDirectory: missingParent, timeMachineRunner: ModelFakeRunner())
        await model.loadTimeMachineHistory()?.value
        expect(model.tmError == TimeMachineSnapshotHistoryError.unsafeStorage.errorDescription, "history errors map to their exact localized descriptions")
        expect(!model.tmBusy, "load error clears busy state")
    }

    @MainActor
    private static func testTimeMachineInventoryCannotBecomeManaged() {
        let model = SnapshotManagementModel(isQA: true, timeMachineDirectory: URL(fileURLWithPath: "/private/tmp/not-used"), timeMachineRunner: ModelFakeRunner())
        let volume = unsupportedVolume()
        let snapshot = LifecycleSnapshot(id: UUID().uuidString, name: "com.apple.TimeMachine.2026-11-12-141501.local", xid: 42)
        model.response.volumes = [volume]
        model.response.inventories[volume.id] = [snapshot]
        model.response.records = [ManagedSnapshot(volume: volume, domain: "fixture", name: "fixture", snapshotUUID: snapshot.id, xid: snapshot.xid, createdAt: Date(), owner: getuid())]
        model.response.records[0].name = snapshot.name
        model.volumeID = volume.id
        model.selected = [snapshot.id]
        expect(model.record(snapshot) == nil && model.selectedRecords.isEmpty, "Time Machine inventory remains foreign even if a forged record matches")
    }

    @MainActor
    private static func testRequestErrorMapping() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("History")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let journal = directory.appendingPathComponent("history.json")
        try Data("broken journal".utf8).write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let runner = ModelFakeRunner()
        let model = SnapshotManagementModel(isQA: false, timeMachineDirectory: directory, timeMachineRunner: runner)
        await model.requestTimeMachineSnapshot()?.value
        expect(model.tmError == TimeMachineSnapshotHistoryError.corruptHistory.errorDescription && runner.calls == 0 && !model.tmBusy, "corrupt journal errors are mapped without running a command")
        try FileManager.default.removeItem(at: journal)
        let lock = open(directory.appendingPathComponent("create.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "fixture holds the request lock")
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        await model.requestTimeMachineSnapshot()?.value
        expect(model.tmError == TimeMachineSnapshotHistoryError.commandInProgress.errorDescription && runner.calls == 0 && !model.tmBusy, "cross-instance lock errors are mapped without running a command")
    }

    private static func fixture() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tm-snapshot-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func seedStartedJournal(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let payload: [String: Any] = [
            "schema": 1,
            "activities": [["id": UUID().uuidString, "startedAt": 100, "outcome": "started", "output": ""]]
        ]
        let history = directory.appendingPathComponent("history.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: history)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
    }

    private static func unsupportedVolume() -> ManagedVolume {
        .init(id: UUID().uuidString, container: UUID().uuidString, name: "System Fixture", mountPath: "/", device: "disk99s1", roles: ["System"], writable: false, local: true)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
