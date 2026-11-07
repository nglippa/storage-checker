import Foundation
import Darwin

// Live APFS capacity for the viewer.
//
// Read-only and in-process: one statfs() on the Data volume plus its volume
// UUID. statfs reports the APFS container's free and total blocks, which match
// the monitor's CapacityFree and CapacityCeiling. Live readings are never
// written to history, never evaluated for alerts, and never notify.

struct LiveCapacityReading: Sendable, Equatable {
    let timestamp: Date
    let free: Int64
    let total: Int64
    let dataVolumeUUID: String?
    var used: Int64 { total - free }
}

enum LiveCapacityError: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return "Live capacity unavailable: \(message)" }; return nil }
}

enum LiveCapacityProbe {
    static let dataVolume = "/System/Volumes/Data"
    static func read(descriptor: ExternalVolumeDescriptor, now: Date = Date()) throws -> LiveCapacityReading {
        let before = try ExternalMountProbe.read(descriptor.mountPath)
        guard before.volumeUUID == (try descriptor.identity().uuid), before.device == descriptor.device else {
            throw LiveCapacityError.unavailable("the selected mount identity changed")
        }
        let value = try read(path: descriptor.mountPath, now: now)
        guard try ExternalMountProbe.read(descriptor.mountPath) == before,
              value.dataVolumeUUID.flatMap({ try? ExternalVolumeIdentity($0).uuid }) == before.volumeUUID else {
            throw LiveCapacityError.unavailable("the selected volume disconnected during the probe")
        }
        return value
    }
    static func read(path: String = dataVolume, now: Date = Date()) throws -> LiveCapacityReading {
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw LiveCapacityError.unavailable(String(cString: strerror(errno))) }
        let block = Int64(info.f_bsize)
        let free = Int64(info.f_bavail) * block, total = Int64(info.f_blocks) * block
        guard block > 0, total > 0, free >= 0, free <= total else { throw LiveCapacityError.unavailable("invalid filesystem counters") }
        let uuid = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return LiveCapacityReading(timestamp: now, free: free, total: total, dataVolumeUUID: uuid)
    }
}

enum LiveFreshness: Equatable, Sendable { case live, stale, unavailable }

struct LiveCapacityState: Sendable, Equatable {
    var reading: LiveCapacityReading?
    var lastAttempt: Date?
    var lastError: String?
    var isRefreshing = false
    // Three missed refresh intervals.
    static let staleAfter: TimeInterval = 180
    func freshness(at now: Date) -> LiveFreshness {
        guard let reading else { return .unavailable }
        if lastError != nil { return .stale }
        let age = now.timeIntervalSince(reading.timestamp)
        return age < 0 || age > Self.staleAfter ? .stale : .live
    }
}

/// One value and freshness contract for Storage and Monitoring. Missing values stay absent.
struct CapacityPresentation: Equatable {
    enum Status: Equatable { case current, refreshing, failed, stale, previous, unavailable }
    enum Source: Equatable { case live, recorded, none }
    let status: Status
    let source: Source
    let free: Int64?
    let total: Int64?
    let timestamp: Date?
    let title: String
    let statusText: String
    let detail: String
    var used: Int64? { guard let free, let total else { return nil }; return total - free }
    var isCurrent: Bool { status == .current }

    init(state: LiveCapacityState, recorded: Measurement?, now: Date) {
        source = state.reading != nil ? .live : (recorded != nil ? .recorded : .none)
        free = state.reading?.free ?? recorded?.free
        total = state.reading?.total ?? recorded?.capacity
        timestamp = state.reading?.timestamp ?? recorded?.timestamp
        if state.isRefreshing { status = .refreshing }
        else if state.lastError != nil { status = .failed }
        else if state.reading != nil { status = state.freshness(at: now) == .live ? .current : .stale }
        else { status = recorded != nil ? .previous : .unavailable }
        title = status == .current ? "Available now" : (source == .recorded ? "Available · last recorded" : (free != nil ? "Available · previous reading" : "Available capacity"))
        let age = timestamp.map { Self.age(of: $0, at: now) }
        switch status {
        case .current: statusText = "Live · updated \(age!)"
        case .refreshing: statusText = free == nil ? "Reading capacity…" : "Refreshing · previous reading \(age!)"
        case .failed: statusText = free == nil ? "Capacity refresh failed · no reading" : "Refresh failed · previous reading \(age!)"
        case .stale: statusText = "Stale · last live reading \(age!)"
        case .previous: statusText = "Last recorded \(age!) · live reading unavailable"
        case .unavailable: statusText = "No capacity reading available"
        }
        detail = [timestamp.map { "Reading from " + $0.formatted(date: .complete, time: .complete) + "." }, state.lastError,
                  "Live capacity refreshes on opening, activation, every minute while visible, and Refresh. It is not recorded and never triggers alerts."].compactMap { $0 }.joined(separator: " ")
    }
    private static func age(of date: Date, at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

// A live observation set beside the latest recorded reading. This is a
// comparison of two observations, not a recorded event.
struct ObservationComparison: Sendable, Equatable {
    let live: LiveCapacityReading
    let recorded: Measurement
    var difference: Int64 { live.free - recorded.free }
    var elapsed: TimeInterval { live.timestamp.timeIntervalSince(recorded.timestamp) }

    // Only when the live Data volume belongs to the recorded container.
    static func make(live: LiveCapacityReading?, recorded: Measurement?) -> ObservationComparison? {
        guard let live, let recorded, let uuid = live.dataVolumeUUID, recorded.volumes.contains(where: { $0.id == uuid }) else { return nil }
        return ObservationComparison(live: live, recorded: recorded)
    }
}
extension Measurement: Equatable {
    static func == (a: Measurement, b: Measurement) -> Bool { a.id == b.id && a.timestamp == b.timestamp && a.free == b.free && a.used == b.used && a.container == b.container }
}

// Refreshes live capacity without overlapping requests.
@MainActor final class LiveCapacityMonitor: ObservableObject {
    @Published private(set) var state = LiveCapacityState()
    private var source: @Sendable () throws -> LiveCapacityReading
    private var sourceRevision: UInt64 = 0
    private let clock: @Sendable () -> Date
    private(set) var started = 0, skipped = 0
    // Conservative cadence while the window is visible and the app is active.
    static let visibleInterval: TimeInterval = 60

    init(source: @escaping @Sendable () throws -> LiveCapacityReading = { try LiveCapacityProbe.read() }, clock: @escaping @Sendable () -> Date = { Date() }) { self.source = source; self.clock = clock }

    func selectSource(preserveReading: Bool = false, _ source: @escaping @Sendable () throws -> LiveCapacityReading) {
        sourceRevision &+= 1
        self.source = source
        state.isRefreshing = false
        if !preserveReading { state = LiveCapacityState() }
    }

    var isRefreshing: Bool { state.isRefreshing }
    func isDue(at now: Date) -> Bool { state.lastAttempt.map { now.timeIntervalSince($0) >= Self.visibleInterval } ?? true }

    // Returns false when a refresh is already running.
    @discardableResult func refresh() async -> Bool {
        guard !state.isRefreshing else { skipped += 1; return false }
        state.isRefreshing = true; state.lastAttempt = clock(); started += 1
        let revision = sourceRevision
        defer { if revision == sourceRevision { state.isRefreshing = false } }
        let source = self.source
        let result = await Task.detached(priority: .utility) { Result { try source() } }.value
        guard revision == sourceRevision, !Task.isCancelled else { return false }
        var next = state
        switch result {
        case .success(let reading): next.reading = reading; next.lastError = nil
        case .failure(let error): next.lastError = error.localizedDescription  // keep the last good reading, now stale
        }
        state = next
        return true
    }
}

// MARK: Appearance

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { ["System", "Light", "Dark"][Self.allCases.firstIndex(of: self)!] }
    static let preferenceKey = "appearance"
    // A launch override (QA captures) wins and is never persisted.
    static func load(_ defaults: UserDefaults, override: String? = nil) -> AppAppearance {
        if let override, let value = AppAppearance(rawValue: override) { return value }
        return defaults.string(forKey: preferenceKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
    func save(_ defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.preferenceKey) }
}
