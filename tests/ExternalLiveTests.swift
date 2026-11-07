import Foundation

private final class HeldLiveSource: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func waitStarted() -> Bool { started.wait(timeout: .now() + 5) == .success }
    func read() -> LiveCapacityReading {
        started.signal(); _ = release.wait(timeout: .now() + 5)
        return LiveCapacityReading(timestamp: Date(), free: 10, total: 100, dataVolumeUUID: "old-drive")
    }
}

@main enum ExternalLiveTests {
    @MainActor static func main() async throws {
        let held = HeldLiveSource()
        let monitor = LiveCapacityMonitor(source: { held.read() })
        let old = Task { await monitor.refresh() }
        let started = await Task.detached { held.waitStarted() }.value
        precondition(started, "old probe started")
        monitor.selectSource { LiveCapacityReading(timestamp: Date(), free: 80, total: 100, dataVolumeUUID: "new-drive") }
        _ = await monitor.refresh()
        held.release.signal(); _ = await old.value
        precondition(monitor.state.reading?.dataVolumeUUID == "new-drive", "late old drive probe cannot overwrite selection")
        precondition(!monitor.isRefreshing, "old probe cannot leave selected target busy")
        monitor.selectSource { throw LiveCapacityError.unavailable("offline") }
        precondition(monitor.state.reading == nil, "switch clears previous drive capacity")
        _ = await monitor.refresh()
        precondition(monitor.state.reading == nil && monitor.state.lastError != nil, "offline target never falls back to startup capacity")
        let readings = [Measurement(id: 1, timestamp: Date(timeIntervalSince1970: 10_000), container: "external", free: 80, used: 20, volumes: []),
                        Measurement(id: 2, timestamp: Date(timeIntervalSince1970: 15_000), container: "external", free: 10, used: 90, volumes: [])]
        let projected = EventProjector.project(measurements: readings, alerts: [], diagnostics: [], segmentStarts: [2])
        precondition(projected.events.first(where: { $0.id == "reading:2" })?.delta == nil, "history projection respects external session baseline")
        precondition(projected.baseline(seconds: 3600) == nil, "hourly comparison cannot cross an external session boundary")
        precondition(EvidenceParser.volumes([["VolumeUUID": "exfat-identity", "Name": "Portable", "CapacityInUse": 42]]).first?.id == "exfat-identity", "generic filesystem allocation retains its UUID")
        let generic = readings.map { value in Measurement(id: value.id, timestamp: value.timestamp, container: "filesystem:fixture", free: value.free, used: value.used,
            volumes: [VolumeAllocation(id: "portable", name: "Portable", bytes: value.used, roles: [])]) }
        let event = EventProjector.project(measurements: generic, alerts: [], diagnostics: []).events.first { $0.id == "reading:2" }!
        let analysis = CauseAnalyzer.analyze(event)
        precondition(analysis.causes.isEmpty && !analysis.breakdown.hasVolumes, "generic used-capacity deltas cannot become confirmed APFS causes")
        precondition(!EventPanelText.details(event).contains("APFS"), "generic filesystem event copy never claims APFS evidence")
        print("9 external viewer model tests passed")
    }
}
