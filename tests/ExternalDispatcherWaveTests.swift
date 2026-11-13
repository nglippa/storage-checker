import Foundation
import Darwin

private let waveA = "11111111-1111-4111-8111-111111111111"
private let waveB = "22222222-2222-4222-8222-222222222222"

private final class WaveTape: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    private var executions = [String]()
    private var checks = [String]()
    private var samples = 0
    private var allowances = [TimeInterval]()
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
    func sampled() { lock.lock(); samples += 1; lock.unlock() }
    func checked(_ id: String) { lock.lock(); checks.append(id); lock.unlock() }
    func ran(_ id: String, budget: TimeInterval) { lock.lock(); executions.append(id); allowances.append(budget); lock.unlock() }
    func resetRuns() { lock.lock(); executions = []; allowances = []; lock.unlock() }
    var runs: [String] { lock.lock(); defer { lock.unlock() }; return executions }
    var validated: [String] { lock.lock(); defer { lock.unlock() }; return checks }
    var discoveries: Int { lock.lock(); defer { lock.unlock() }; return samples }
    var budgets: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return allowances }
}

private actor WaveGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private func waveResult(_ runnable: Bool = false) -> InventoryRunResult {
    var result = InventoryRunResult(outcome: "complete", generation: 1, entries: 0, directories: 0, pending: 0, reason: nil)
    result.runnableWorkRemains = runnable
    return result
}

private struct WaveFixture {
    let base = URL(fileURLWithPath: "/private/tmp/storage-external-wave-\(UUID().uuidString)")
    var registry: ExternalVolumeRegistry { ExternalVolumeRegistry(baseDirectory: base) }
    func drive(_ id: String) -> ExternalVolumeDescriptor {
        ExternalVolumeDescriptor(volumeUUID: id, name: id, mountPath: "/fixture-mount/" + id, filesystem: "exfat", device: 42,
            backingUUIDs: [id], isInternal: false, isLocal: true, isPhysical: true)
    }
    func enroll(_ ids: [String]) throws { for id in ids { _ = try registry.enroll(drive(id)) } }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func dependencies(_ tape: WaveTape, descriptors: [ExternalVolumeDescriptor], rejected: Set<String> = [],
                      runnable: Set<String> = [], failures: Set<String> = [],
                      discover: (() throws -> Void)? = nil,
                      startup: (([String]) async throws -> Void)? = nil) -> ExternalDispatchDependencies {
        ExternalDispatchDependencies(discover: {
            tape.sampled(); try discover?()
            return ExternalVolumeObservations(sampledAt: Date(), descriptors: descriptors, error: nil)
        }, validateExternal: { descriptor, registry in
            let id = try descriptor.identity().uuid
            tape.checked(id); try registry.validate(descriptor)
            if rejected.contains(id) { throw InventoryRootValidationError.disconnected }
        }, runStartup: { args, _ in
            let i = args.firstIndex(of: "--budget")!
            tape.ran("startup", budget: Double(args[i + 1])!)
            try await startup?(args)
            if failures.contains("startup") { throw Failure("fixture startup failure") }
            return waveResult(runnable.contains("startup"))
        }, runExternal: { _, descriptor, budget in
            let id = try descriptor.identity().uuid
            tape.ran(id, budget: budget)
            if failures.contains(id) { throw Failure("fixture external failure") }
            return waveResult(runnable.contains(id))
        }, now: tape.now)
    }
}

@main enum ExternalDispatcherWaveTests {
    static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ value: Bool, _ name: String) throws { try required(value, name); checks += 1; print("PASS " + name) }
        let args = ["inventory-work", "--budget", "120"]
        do {
            let fixture = WaveFixture(); defer { fixture.remove() }
            try fixture.enroll([waveA, waveB])
            let tape = WaveTape()
            let dependencies = fixture.dependencies(tape, descriptors: [waveA, waveB].map(fixture.drive))
            _ = try await indexSelectedExternalVolume(uuid: waveA, directory: fixture.base, budget: 10, dependencies: dependencies)
            try check(tape.runs == [waveA] && tape.validated == [waveA], "manual indexing runs only the selected external drive, never startup or another enrolled drive")
            _ = try fixture.registry.setIndexingPaused(uuid: waveA, paused: true)
            let paused = try await indexSelectedExternalVolume(uuid: waveA, directory: fixture.base, budget: 10, dependencies: dependencies)
            try check(paused.reason == "cancelled" && !paused.runnableWorkRemains && tape.runs == [waveA], "paused selected drive is not restarted by a manual slice")
            do {
                _ = try await indexSelectedExternalVolume(uuid: "99999999-9999-4999-8999-999999999999", directory: fixture.base, budget: 10, dependencies: dependencies)
                fatalError("unknown manual target accepted")
            } catch {}
            try check(tape.runs == [waveA], "unregistered manual targets cannot fall back to startup indexing")
        }
        do {
            let fixture = WaveFixture(); defer { fixture.remove() }
            let disabled = "33333333-3333-4333-8333-333333333333", paused = "44444444-4444-4444-8444-444444444444"
            let offline = "55555555-5555-4555-8555-555555555555", ambiguous = "66666666-6666-4666-8666-666666666666", failed = "77777777-7777-4777-8777-777777777777"
            try fixture.enroll([waveA, waveB, disabled, paused, offline, ambiguous, failed])
            _ = try fixture.registry.setEnabled(uuid: disabled, enabled: false)
            _ = try fixture.registry.setIndexingPaused(uuid: paused, paused: true)
            let tape = WaveTape()
            let descriptors = [waveA, waveB, disabled, paused, ambiguous, ambiguous, failed].map(fixture.drive)
            let pending = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(tape, descriptors: descriptors, rejected: [failed]))
            try check(tape.runs == ["startup", waveA, "startup", waveB], "real wave alternates startup and valid external targets")
            try check(Set(tape.validated) == [waveA, waveB, failed], "disabled, paused, offline and ambiguous targets never reach availability validation")
            try check(!pending && tape.discoveries == 1, "a drained wave goes idle after one discovery")
            try check(!FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("history.sqlite3").path), "injected startup runner cannot create a startup inventory database")
            let revision = try fixture.registry.read().revision
            tape.resetRuns()
            let reconnected = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(tape, descriptors: descriptors + [fixture.drive(offline)], rejected: [failed]))
            try check(!reconnected && tape.runs.filter { $0 == offline }.count == 1, "a chosen offline drive resumes automatically when discovery sees it again")
            try check(try fixture.registry.read().revision == revision, "automatic reconnect needs no settings change or re-enrollment")
        }
        do {
            let fixture = WaveFixture(); defer { fixture.remove() }; try fixture.enroll([waveA, waveB])
            let tape = WaveTape()
            let first = fixture.dependencies(tape, descriptors: [waveA, waveB].map(fixture.drive), startup: { _ in tape.advance(100) })
            let pending = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args, dependencies: first)
            try check(pending && tape.runs == ["startup"], "budget reserve stops before another target and requests continuation")
            try check(tape.budgets == [120], "first runnable target receives the full remaining slice budget")
            tape.resetRuns()
            let drained = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(tape, descriptors: [waveA, waveB].map(fixture.drive)))
            try check(tape.runs == [waveA, "startup", waveB, "startup"], "next wave resumes after the persisted last target")
            try check(!drained, "the resumed drained wave returns to normal idle")
        }
        do {
            let fixture = WaveFixture(); defer { fixture.remove() }; try fixture.enroll([waveA])
            let tape = WaveTape()
            let pending = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(tape, descriptors: [fixture.drive(waveA)], runnable: [waveA]))
            try check(pending, "a runnable external slice propagates continuation")
            let noExternal = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(WaveTape(), descriptors: []))
            try check(!noExternal, "an absent chosen drive does not create a relaunch loop")
        }
        do {
            let fixture = WaveFixture(); defer { fixture.remove() }; try fixture.enroll([waveA])
            let control = ExternalVolumeControl(baseDirectory: fixture.base)
            let pending = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(WaveTape(), descriptors: [fixture.drive(waveA)], discover: { try control.signal() }))
            try check(pending, "a wake arriving during discovery survives through the full wave")
            let drained = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(WaveTape(), descriptors: [fixture.drive(waveA)]))
            try check(!drained, "a consumed wake does not cause repeated continuation")
            let late = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(WaveTape(), descriptors: [fixture.drive(waveA)], startup: { _ in try control.signal() }))
            try check(late, "a wake arriving during execution requests another wave")
        }
        do {
            let fixture = WaveFixture(); defer { fixture.remove() }; try fixture.enroll([waveA, waveB])
            let tape = WaveTape()
            let pending = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(tape, descriptors: [waveA, waveB].map(fixture.drive), failures: [waveA]))
            try check(tape.runs.contains(waveB), "one failed external runner does not suppress a valid peer")
            try check(!pending, "a failed drained runner waits for a scheduled wake")
            try Data("{broken".utf8).write(to: fixture.registry.registryURL)
            let fallback = WaveTape()
            let continues = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args,
                dependencies: fixture.dependencies(fallback, descriptors: [fixture.drive(waveA)], runnable: ["startup"]))
            try check(continues && fallback.runs == ["startup"], "corrupt external settings preserve startup work without running an external target")
        }
        do {
            let fixture = WaveFixture(); defer { fixture.remove() }
            let tape = WaveTape(), gate = WaveGate()
            let dependencies = fixture.dependencies(tape, descriptors: [], startup: { _ in await gate.hold() })
            let first = Task { try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args, dependencies: dependencies) }
            for _ in 0..<600 {
                if await gate.started { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let started = await gate.started
            try check(started, "first dispatcher holds its runner under the global lock")
            let second = try await dispatchExternalInventoryForTesting(directory: fixture.base, args: args, dependencies: dependencies)
            try check(!second && tape.runs == ["startup"] && tape.discoveries == 1, "concurrent dispatcher cannot discover or run a second scan")
            await gate.release(); let finished = try await first.value
            try check(!finished, "the lock owner drains normally after the competing attempt")
        }
        print("\(checks) external dispatcher-wave checks passed")
    }
}
