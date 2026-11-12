import Foundation
import Security
import Darwin

private final class SnapshotEndpoint: NSObject, SnapshotServiceProtocol {
    let owner: UInt32
    let session = UUID().uuidString
    let host: SnapshotServiceHost
    init(owner: UInt32, host: SnapshotServiceHost) { self.owner = owner; self.host = host }
    func perform(_ request: Data, authorization: Data, reply: @escaping (Data) -> Void) {
        guard request.count <= 1024*1024 && authorization.count <= 64 else {
            reply(Self.encoded(.init(error: "Request exceeded its safety limit."))); return
        }
        host.queue.async { [self] in
            do {
                let command = try JSONDecoder().decode(SnapshotServiceRequest.self, from: request)
                try lifecycleRequire(command.protocolVersion == 1 && command.snapshotIDs.count <= 256, "Unsupported protocol or request size.")
                try SnapshotAuthorization.verify(authorization, action: command.action)
                let result = try host.engine.handle(command, owner: owner, session: session)
                reply(Self.encoded(result))
            } catch { reply(Self.encoded(.init(error: String(describing: error)))) }
        }
    }
    static func encoded(_ result: SnapshotServiceResponse) -> Data {
        (try? JSONEncoder().encode(result)) ?? Data("{\"error\":\"Response encoding failed.\"}".utf8)
    }
}
private final class SnapshotServiceHost: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "local.macbook.storage-monitor.snapshots.serial", qos: .utility)
    let engine: SnapshotLifecycleEngine
    let team: String
    private var timer: DispatchSourceTimer?
    private var signals = [DispatchSourceSignal]()
    init(engine: SnapshotLifecycleEngine, team: String) { self.engine = engine; self.team = team }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier >= 501 else { return false }
        connection.setCodeSigningRequirement(SnapshotCodeIdentity.requirement(identifier: SnapshotServiceIdentity.clientIdentifier, team: team))
        let endpoint = SnapshotEndpoint(owner: connection.effectiveUserIdentifier, host: self)
        connection.exportedInterface = NSXPCInterface(with: SnapshotServiceProtocol.self)
        connection.exportedObject = endpoint
        let session = endpoint.session
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.queue.async { try? self.engine.connectionClosed(session: session) }
        }
        connection.resume(); return true
    }
    func startTimer() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                do { try self?.engine.closeLeases() }
                catch { fputs("Snapshot comparison cleanup deferred until next start: \(error)\n", stderr) }
                exit(0)
            }
            source.resume(); signals.append(source)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // launchd starts the daemon at boot and restarts it after failure. One persisted nextDue per
        // volume coalesces sleep/missed periods; a serial 60-second timer never launches overlapping work.
        timer.schedule(deadline: .now() + 5, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            do { try self?.engine.tick() } catch { fputs("Snapshot service paused: \(error)\n", stderr) }
        }
        timer.resume(); self.timer = timer
    }
}
@main struct SnapshotServiceMain {
    static func main() {
        do {
            try lifecycleRequire(CommandLine.arguments.count == 1, "This service accepts only its fixed XPC protocol; no shell or root command mode exists.")
            try lifecycleRequire(geteuid() == 0, "Snapshot service must be explicitly enabled through Service Management.")
            guard let team = SnapshotCodeIdentity.team(SnapshotCodeIdentity.information()) else { throw SnapshotLifecycleError.refused("Ad-hoc/development helper cannot manage snapshots.") }
            try lifecycleRequire(sm_snapshot_has_entitlement() == 1, "Apple's snapshot entitlement is missing. No mutations or scheduling will start.")
            let root = URL(fileURLWithPath: SnapshotServiceIdentity.stateRoot)
            if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw SnapshotLifecycleError.refused("Cannot create private service state directory.") }
            let ledger = try SnapshotLifecycleLedger(directory: root.appendingPathComponent("Ledger"), owner: 0)
            let engine = try SnapshotLifecycleEngine(ledger: ledger, backend: NativeSnapshotBackend())
            try SnapshotAuthorization.installRightsIfMissing()
            let host = SnapshotServiceHost(engine: engine, team: team)
            let listener = NSXPCListener(machServiceName: SnapshotServiceIdentity.label)
            listener.delegate = host; host.startTimer(); listener.resume()
            RunLoop.current.run()
        } catch { fputs("Snapshot Management unavailable: \(error)\n", stderr); exit(78) }
    }
}
