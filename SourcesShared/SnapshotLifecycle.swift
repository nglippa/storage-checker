import Foundation

// Snapshot management has its own state and security boundary. Historical evidence remains read-only.
enum SnapshotLifecycleError: Error, LocalizedError {
    case refused(String)
    var errorDescription: String? { if case .refused(let text) = self { return text }; return nil }
}
func lifecycleRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw SnapshotLifecycleError.refused(message) }
}
struct ManagedVolume: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var container: String
    var name: String
    var mountPath: String
    var device: String
    var roles: [String]
    var writable: Bool
    var local: Bool
    var compatibilityIssue: String? {
        if UUID(uuidString: id) == nil || UUID(uuidString: container) == nil { return "APFS volume/container identity is unavailable." }
        if !local { return "Only locally mounted APFS volumes are supported." }
        if !roles.isEmpty { return "System, Data and other role-bearing volumes are observation-only. Use a dedicated roleless APFS data volume." }
        if !writable { return "The volume is locked, unmounted or read-only." }
        if mountPath == "/" || mountPath.hasPrefix("/System/") || !mountPath.hasPrefix("/") { return "Startup and system mounts are observation-only." }
        return nil
    }
}
struct LifecycleSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var xid: UInt64?
    var purgeable: Bool? = nil
    // The supported listing interface does not establish exclusive/reclaimable bytes or creation date.
}
enum ManagedSnapshotState: String, Codable, Sendable { case creating, managed, deleting, deleted, quarantined }
struct ManagedSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var volumeUUID: String
    var containerUUID: String
    var domain: String
    var name: String
    var label: String
    var snapshotUUID: String
    var xid: UInt64?
    var createdAt: Date
    var owner: UInt32
    var protected = false
    var excludedFromRetention = false
    var state: ManagedSnapshotState = .managed
    init(volume: ManagedVolume, domain: String, name label: String, snapshotUUID: String, xid: UInt64?, createdAt: Date, owner: UInt32, operationID: String = UUID().uuidString) {
        id = operationID; volumeUUID = volume.id; containerUUID = volume.container; self.domain = domain
        self.label = label; name = Self.nativeName(domain: domain, operation: operationID, label: label)
        self.snapshotUUID = snapshotUUID; self.xid = xid; self.createdAt = createdAt; self.owner = owner
    }
    static func nativeName(domain: String, operation: String, label: String) -> String { "local.storage-monitor.\(domain.lowercased()).\(operation.lowercased()).\(label.isEmpty ? "Snapshot" : label)" }
}
enum SnapshotInterval: String, Codable, CaseIterable, Sendable {
    case hourly, daily, weekly, custom
    var seconds: TimeInterval { switch self { case .hourly: return 3600; case .daily: return 86400; case .weekly: return 604800; case .custom: return 0 } }
}
struct SnapshotPolicy: Codable, Equatable, Sendable {
    var enabled = false
    var interval: SnapshotInterval = .daily
    var customIntervalMinutes = 60
    var maximumCount = 24
    var maximumAgeDays = 30
    var minimumFreeBytes: Int64? = nil
    var retentionEnabled = false
    var seconds: TimeInterval { interval == .custom ? Double(customIntervalMinutes) * 60 : interval.seconds }
    func validate() throws {
        try lifecycleRequire(customIntervalMinutes >= 15 && customIntervalMinutes <= 525600, "Custom intervals must be between 15 minutes and one year.")
        try lifecycleRequire((1...4096).contains(maximumCount), "Keep between 1 and 4096 managed snapshots.")
        try lifecycleRequire((1...3650).contains(maximumAgeDays), "Maximum age must be between 1 and 3650 days.")
        if let bytes = minimumFreeBytes { try lifecycleRequire(bytes >= 0 && bytes <= 1_000_000_000_000_000, "Invalid free-space threshold.") }
    }
}
struct VolumeSnapshotPolicy: Codable, Equatable, Identifiable, Sendable {
    var volume: ManagedVolume
    var owner: UInt32
    var policy: SnapshotPolicy
    var nextDue: Date
    var id: String { "\(owner):\(volume.id)" }
    func isDue(now: Date) -> Bool { policy.enabled && now >= nextDue }
    mutating func didAttempt(at now: Date) { nextDue = now.addingTimeInterval(policy.seconds) }
}
enum SnapshotOwnership {
    static func verify(_ record: ManagedSnapshot, against observed: LifecycleSnapshot, volume: ManagedVolume, domain: String, owner: UInt32) throws {
        try lifecycleRequire(volume.compatibilityIssue == nil, volume.compatibilityIssue ?? "Unsupported volume.")
        try lifecycleRequire(record.state == .managed && record.domain == domain && record.owner == owner, "Snapshot ownership is missing, uncertain or belongs to another user/domain.")
        try lifecycleRequire(record.volumeUUID == volume.id && record.containerUUID == volume.container, "Volume/container identity changed; refusing mutation.")
        try lifecycleRequire(UUID(uuidString: record.id) != nil && UUID(uuidString: domain) != nil && record.name == ManagedSnapshot.nativeName(domain: domain, operation: record.id, label: record.label), "Invalid management-domain identity.")
        try lifecycleRequire(UUID(uuidString: observed.id) != nil && record.snapshotUUID == observed.id && record.name == observed.name && record.xid != nil && record.xid == observed.xid, "Snapshot UUID, name or transaction identity changed; refusing mutation.")
        try lifecycleRequire(!observed.name.hasPrefix("com.apple."), "Apple and Time Machine snapshots cannot be managed here.")
    }
}
enum SnapshotRetention {
    static func candidates(records: [ManagedSnapshot], volume: ManagedVolume, policy: SnapshotPolicy, now: Date) -> [ManagedSnapshot] {
        let all = records.filter { $0.volumeUUID == volume.id && $0.containerUUID == volume.container && $0.state == .managed }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        // Count includes protected/excluded snapshots, but those never become candidates. Keep at least the newest recovery point.
        let excess = max(0, all.count - policy.maximumCount)
        let newest = all.last?.id
        let eligible = all.filter { $0.id != newest && !$0.protected && !$0.excludedFromRetention }
        let countIDs = Set(eligible.prefix(excess).map(\.id))
        return all.filter { record in
            record.id != newest && !record.protected && !record.excludedFromRetention &&
            (countIDs.contains(record.id) || now.timeIntervalSince(record.createdAt) > Double(policy.maximumAgeDays) * 86400)
        }
    }
}
struct SnapshotActivity: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var at = Date()
    var owner: UInt32
    var volumeUUID: String
    var snapshotID: String?
    var action: String
    var status: String
    var detail: String
    var freeBefore: Int64?
    var freeAfter: Int64?
    var observedCapacityChange: Int64? {
        guard let a = freeBefore, let b = freeAfter else { return nil }; return b - a
    }
}
struct SnapshotMountLease: Codable, Identifiable, Sendable {
    var id: String
    var owner: UInt32
    var volumeUUID: String
    var leftSnapshotID: String
    var rightSnapshotID: String
    var leftPath: String
    var rightPath: String
    var expires: Date
}
struct SnapshotLedgerDocument: Codable, Sendable {
    var schema = 1
    var domain = UUID().uuidString
    var revision: UInt64 = 0
    var snapshots = [ManagedSnapshot]()
    var policies = [VolumeSnapshotPolicy]()
    var activities = [SnapshotActivity]()
    var leases = [SnapshotMountLease]()
}
struct SnapshotDeletionPreview: Codable, Identifiable, Sendable {
    var id: String
    var volumeUUID: String
    var records: [ManagedSnapshot]
    var expires: Date
    var reason: String
    var revision: UInt64
}
enum SnapshotServiceAction: String, Codable, Sendable { case inventory, create, protect, recover, previewManual, previewRetention, deletePreview, savePolicy, beginComparison, endComparison }
struct SnapshotServiceRequest: Codable, Sendable {
    var action: SnapshotServiceAction
    var protocolVersion = 1
    var volumeUUID: String? = nil
    var snapshotIDs: [String] = []
    var label: String? = nil
    var protected: Bool? = nil
    var excluded: Bool? = nil
    var policy: SnapshotPolicy? = nil
    var token: String? = nil
}
struct SnapshotServiceResponse: Codable, Sendable {
    var error: String? = nil
    var volumes: [ManagedVolume] = []
    var inventories: [String: [LifecycleSnapshot]] = [:]
    var inventoryErrors: [String: String] = [:]
    var records: [ManagedSnapshot] = []
    var policies: [VolumeSnapshotPolicy] = []
    var activities: [SnapshotActivity] = []
    var preview: SnapshotDeletionPreview? = nil
    var lease: SnapshotMountLease? = nil
    var message: String? = nil
}
