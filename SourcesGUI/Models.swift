import Foundation

let decimalGB: Int64 = 1_000_000_000

func capacity(_ bytes: Int64, signed: Bool = false) -> String {
    let prefix = signed && bytes > 0 ? "+" : ""
    return prefix + String(format: "%.2f GB", Double(bytes) / Double(decimalGB))
}
func exactBytes(_ bytes: Int64) -> String { "\(bytes.formatted()) bytes" }
func minuteBoundary(_ date: Date) -> Date { Date(timeIntervalSince1970:floor(date.timeIntervalSince1970/60)*60) }
func signedChange(_ bytes: Int64) -> String {
    let magnitude = abs(Double(bytes))
    let sign = bytes < 0 ? "−" : (bytes > 0 ? "+" : "")
    if magnitude >= 10_000_000 { return sign + String(format:"%.2f GB",magnitude/1e9) }
    if magnitude >= 1_000_000 { return sign + String(format:"%.2f MB",magnitude/1e6) }
    if magnitude >= 1000 { return sign + String(format:"%.2f KB",magnitude/1000) }
    return "\(sign)\(Int64(magnitude)) B"
}

// Size of a change without its sign, for sentences like "decreased by 2.18 GB".
func changeMagnitude(_ bytes: Int64) -> String { String(signedChange(bytes == Int64.min ? Int64.max : abs(bytes)).drop { $0 == "+" }) }

enum EventSeverity: Int, CaseIterable, Codable, Sendable {
    case normal, information, warning, critical
    var label: String { ["Normal", "Information", "Warning", "Critical"][rawValue] }
    init(recorded: String) { self = Self.allCases.first { $0.label.lowercased() == recorded.lowercased() } ?? .information }
    static func capacity(_ free: Int64) -> Self { free < 15 * decimalGB ? .critical : (free < 25 * decimalGB ? .warning : .normal) }
}

struct VolumeAllocation: Identifiable, Sendable {
    let id: String
    let name: String
    let bytes: Int64
    let roles: [String]
}
struct Measurement: Identifiable, Sendable {
    let id: Int64
    let timestamp: Date
    let container: String
    let free: Int64
    let used: Int64
    let volumes: [VolumeAllocation]
    var capacity: Int64 { free + used }
}
struct AlertRecord: Identifiable, Sendable {
    let id: Int64
    let timestamp: Date
    let severity: EventSeverity
    let reasons: String
    let free: Int64
    let delta: Int64?
    let notification: String
    let rawSeverity: String
    var severityKnown: Bool { EventSeverity.allCases.contains { $0.label.lowercased() == rawSeverity.lowercased() } }
    var severityDescription: String { severityKnown ? severity.label : "Unknown recorded severity: \(rawSeverity)" }
}
// Where a piece of evidence came from. Drives grouping in the inspector.
enum EvidenceSource: String, CaseIterable, Sendable {
    case apfs, swap, vm, temporaryFiles = "temporary_files", applicationData = "application_data", caches, developer, other
    case folders, fileActivity = "file_activity", processes
    var title: String {
        switch self {
        case .apfs: return "APFS"; case .swap: return "Swap"; case .vm: return "Virtual memory"
        case .temporaryFiles: return "Temporary files"; case .applicationData: return "Application data"
        case .caches: return "Caches"; case .developer: return "Developer tools"; case .other: return "Other"
        case .folders: return "Folder growth"; case .fileActivity: return "File activity"; case .processes: return "Process correlation"
        }
    }
    // Legacy (schema 1) records only carry a command name and path.
    static func infer(name: String, path: String?) -> Self {
        let text = (name + " " + (path ?? "")).lowercased()
        if text.contains("apfs") { return .apfs }
        if text.contains("swap") { return .swap }
        if text.contains("vm memory") || text.contains("vm_stat") { return .vm }
        if text.contains("signing clone") || text.contains("/private/var/folders") { return .temporaryFiles }
        if text.contains("/library/caches") { return .caches }
        if text.contains("claude") || text.contains("application support") { return .applicationData }
        return .other
    }
}
enum MeasurementStatus: String, Sendable {
    case complete, partial, timedOut = "timed_out", failed, absent, skipped, truncated, unknown
    var isComplete: Bool { self == .complete }
    var isProblem: Bool { ![.complete, .absent].contains(self) }
    var plain: String {
        switch self {
        case .complete: return "Complete"
        case .partial: return "Incomplete — some locations could not be read"
        case .timedOut: return "Incomplete — stopped at its time limit"
        case .failed: return "Not measured — collection failed"
        case .absent: return "Location not present"
        case .skipped: return "Not measured — time budget exhausted"
        case .truncated: return "Incomplete — output exceeded its size limit"
        case .unknown: return "Completeness unknown"
        }
    }
}
struct CommandEvidence: Identifiable, Sendable {
    let id: Int
    let name: String
    let path: String?
    let output: String
    let exitStatus: Int?
    let timedOut: Bool
    let truncated: Bool
    let error: String?
    var complete: Bool { exitStatus == 0 && !timedOut && !truncated && error == nil }
    var source: EvidenceSource { EvidenceSource.infer(name: name, path: path) }
    var status: MeasurementStatus {
        if let error { return error.lowercased().contains("absent") ? .absent : .failed }
        if timedOut { return .timedOut }
        if let exitStatus, exitStatus != 0 { return .partial }
        if truncated { return .truncated }
        return exitStatus == 0 ? .complete : .unknown
    }
    // Paths macOS refused, parsed from "du:/find: PATH: Operation not permitted".
    var refusedPaths: [String] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasSuffix(": Operation not permitted") || line.hasSuffix(": Permission denied") else { return nil }
            var text = String(line)
            for prefix in ["du: ", "find: "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
            guard let colon = text.range(of: ": ", options: .backwards) else { return nil }
            return String(text[..<colon.lowerBound])
        }
    }
    // Output with repeated permission refusals folded into one line.
    var condensedOutput: String {
        let refused = refusedPaths.count
        guard refused > 3 else { return output }
        var kept = [String](), shown = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasSuffix(": Operation not permitted") || line.hasSuffix(": Permission denied") { if shown < 2 { kept.append(String(line)); shown += 1 }; continue }
            kept.append(String(line))
        }
        kept.append("… \(refused - shown) more protected locations could not be inspected (full text available with Copy Raw Output)")
        return kept.joined(separator: "\n")
    }
    var qualifier: String {
        var parts = [String]()
        if timedOut { parts.append("Timed out") }
        if truncated { parts.append("Output truncated") }
        if let exitStatus, exitStatus != 0 { parts.append("Exit \(exitStatus); partial result") }
        if let error { parts.append(error) }
        return parts.isEmpty ? (complete ? "Recorded successfully" : "Availability unknown") : parts.joined(separator: " · ")
    }
}
// One collector's outcome, in a form the inspector can summarise.
struct CollectorStatus: Identifiable, Sendable {
    let id: String
    let source: EvidenceSource
    let label: String
    let status: MeasurementStatus
    let detail: String
    let refusedPaths: [String]
    let permissionDenied: Int
    let observedAt: Date?
}
struct DiagnosticMetric: Identifiable, Sendable {
    let id: String
    let label: String
    let path: String
    let bytes: Int64
    let kind: String
    let complete: Bool
    let qualifier: String
    var source: EvidenceSource = .other
    var observedAt: Date? = nil
    var allocatedBytes: Int64? = nil
    var exact = true
}
struct DiagnosticRecord: Identifiable, Sendable {
    let id: Int64
    let timestamp: Date
    let container: String?
    let free: Int64?
    let used: Int64?
    let volumes: [VolumeAllocation]
    let metrics: [DiagnosticMetric]
    let commands: [CommandEvidence]
    let interpretation: String
    var schemaVersion = 1
    var collectors = [CollectorStatus]()
    var vmCounters = [(String, Int64)]()
    var raw = ""
}
// Per-reading attribution evidence (interval_evidence table). See ATTRIBUTION.md.
struct FolderChange: Identifiable, Sendable {
    var id: String { path }
    let root: String, path: String, child: String, kind: String
    let beforeLogical: Int64, afterLogical: Int64, beforeAllocated: Int64, afterAllocated: Int64
    let beforeFiles: Int, afterFiles: Int
    let beforeMeasuredAt: Date?, afterMeasuredAt: Date?
    var allocatedDelta: Int64 { afterAllocated - beforeAllocated }
    var logicalDelta: Int64 { afterLogical - beforeLogical }
    // Moves (a renamed directory, or a file moved between areas) are neither growth nor reduction.
    var isMove: Bool { kind == "moved" || kind == "moved_in" || kind == "moved_out" }
    var isGrowth: Bool { !isMove && max(allocatedDelta, logicalDelta) > 0 && kind != "shrank" && kind != "removed" }
}
struct CoverageConcentration: Sendable, Equatable { let path: String; let allocated: Int64, total: Int64 }
struct ActivityGroup: Sendable { let path: String; let created: Int, modified: Int, removed: Int, renamed: Int, cloned: Int, events: Int }
struct ProcessCorrelation: Identifiable, Sendable {
    var id: String { "\(pid):\(folder)" }
    let pid: Int, name: String, executable: String, folder: String
    let openFiles: Int, writableFiles: Int, example: String
    let bytesWritten: Int64?
}
struct FolderRootSummary: Sendable { let label: String, path: String; let allocated: Int64, logical: Int64; let children: Int; let complete: Bool }
struct IntervalEvidence: Sendable {
    let readingId: Int64
    let previousReadingId: Int64?
    let collectedAt: Date?
    let folderStatus: String, folderMethod: String
    let measured: Int, carried: Int, pending: Int
    var firstMeasurements = 0, deferred = 0
    // Filesystem coverage block. Absent in historical rows, which are predefined-folder scope.
    var coverageScope = "folders", hasCoverageBlock = false
    var coverageLevel: String? = nil, coverageReason: String? = nil, gapReason: String? = nil
    var unitsMonitored = 0, inaccessibleCount = 0, fullDiskAccess: String? = nil
    var inaccessibleActivityEvents = 0, inaccessibleActivityPath: String? = nil
    var growthConcentration: CoverageConcentration? = nil, reductionConcentration: CoverageConcentration? = nil
    var movesCount = 0, splits = 0
    var openDeletedBytes: Int64 = 0, openDeletedFiles = 0, openDeletedHolders = [String]()
    var isComprehensive: Bool { coverageScope == "comprehensive" }
    let changes: [FolderChange], changesTotal: Int
    let incomparable: [(path: String, reason: String)], incomparableTotal: Int
    let roots: [FolderRootSummary]
    let activityStatus: String, activityReason: String?
    let activityEvents: Int, distinctPaths: Int
    let groups: [ActivityGroup], samples: [String], gaps: [String]
    let sinceEvent: UInt64?, untilEvent: UInt64?, device: String?
    let processStatus: String, processesSampled: Int
    let correlations: [ProcessCorrelation]
    let raw: String
    var comparable: Bool { folderStatus == "complete" || folderStatus == "partial" }

    static func parse(readingId: Int64, json: String) -> IntervalEvidence? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        func n(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
        func i(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        func d(_ v: Any?) -> Date? { (v as? NSNumber).flatMap { $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue) : nil } }
        let folders = root["folders"] as? [String: Any] ?? [:]
        let activity = root["file_activity"] as? [String: Any] ?? [:]
        let processes = root["processes"] as? [String: Any] ?? [:]
        let changes = (folders["changes"] as? [[String: Any]] ?? []).map {
            FolderChange(root: $0["root"] as? String ?? "", path: $0["path"] as? String ?? "", child: $0["child"] as? String ?? "", kind: $0["kind"] as? String ?? "",
                         beforeLogical: n($0["before_logical"]), afterLogical: n($0["after_logical"]), beforeAllocated: n($0["before_allocated"]), afterAllocated: n($0["after_allocated"]),
                         beforeFiles: i($0["before_files"]), afterFiles: i($0["after_files"]), beforeMeasuredAt: d($0["before_measured_at"]), afterMeasuredAt: d($0["after_measured_at"]))
        }
        let groups = (activity["groups"] as? [[String: Any]] ?? []).map { ActivityGroup(path: $0["path"] as? String ?? "", created: i($0["created"]), modified: i($0["modified"]), removed: i($0["removed"]), renamed: i($0["renamed"]), cloned: i($0["cloned"]), events: i($0["events"])) }
        let correlations = (processes["correlations"] as? [[String: Any]] ?? []).map {
            ProcessCorrelation(pid: i($0["pid"]), name: $0["name"] as? String ?? "?", executable: $0["executable"] as? String ?? "", folder: $0["folder"] as? String ?? "",
                               openFiles: i($0["open_files"]), writableFiles: i($0["writable_files"]), example: $0["example"] as? String ?? "", bytesWritten: ($0["bytes_written_interval"] as? NSNumber)?.int64Value)
        }
        let roots = (folders["roots"] as? [[String: Any]] ?? []).map { FolderRootSummary(label: $0["label"] as? String ?? "", path: $0["path"] as? String ?? "", allocated: n($0["allocated"]), logical: n($0["logical"]), children: i($0["children"]), complete: $0["complete"] as? Bool ?? false) }
        return IntervalEvidence(readingId: readingId, previousReadingId: (root["previous_reading_id"] as? NSNumber)?.int64Value, collectedAt: d(root["collected_at"]),
                                folderStatus: folders["status"] as? String ?? "unavailable", folderMethod: folders["method"] as? String ?? "",
                                measured: i(folders["measured"]), carried: i(folders["carried"]), pending: i(folders["pending"]),
                                changes: changes, changesTotal: i(folders["changes_total"]),
                                incomparable: (folders["incomparable"] as? [[String: Any]] ?? []).map { (path: $0["path"] as? String ?? "", reason: $0["reason"] as? String ?? "") }, incomparableTotal: i(folders["incomparable_total"]),
                                roots: roots, activityStatus: activity["status"] as? String ?? "unavailable", activityReason: activity["reason"] as? String,
                                activityEvents: i(activity["events"]), distinctPaths: i(activity["distinct_paths"]), groups: groups, samples: activity["samples"] as? [String] ?? [], gaps: activity["gaps"] as? [String] ?? [],
                                sinceEvent: (activity["since_event"] as? NSNumber)?.uint64Value, untilEvent: (activity["until_event"] as? NSNumber)?.uint64Value, device: activity["device_uuid"] as? String,
                                processStatus: processes["status"] as? String ?? "unavailable", processesSampled: i(processes["sampled"]), correlations: correlations, raw: json)
            .with(first: i(folders["first_measurements"]), deferred: i(folders["deferred"]))
            .withCoverage(root: root, folders: folders, processes: processes)
    }
    private func withCoverage(root: [String: Any], folders: [String: Any], processes: [String: Any]) -> IntervalEvidence {
        func i(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        func n(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
        var copy = self
        let coverage = root["coverage"] as? [String: Any]
        copy.hasCoverageBlock = coverage != nil
        copy.coverageScope = (coverage?["scope"] as? String) ?? (folders["scope"] as? String) ?? "folders"
        if let coverage {
            copy.coverageLevel = coverage["level"] as? String; copy.coverageReason = coverage["reason"] as? String; copy.gapReason = coverage["gap_reason"] as? String
            copy.unitsMonitored = i(coverage["monitored"]); copy.fullDiskAccess = coverage["full_disk_access"] as? String
            copy.inaccessibleCount = i(coverage["inaccessible"])
            let activity = coverage["inaccessible_activity"] as? [String: Any]
            copy.inaccessibleActivityEvents = i(activity?["events"])
            copy.inaccessibleActivityPath = (activity?["regions"] as? [[String: Any]])?.first?["path"] as? String
        }
        func concentration(_ v: Any?) -> CoverageConcentration? {
            guard let o = v as? [String: Any], let path = o["path"] as? String else { return nil }
            return CoverageConcentration(path: path, allocated: n(o["allocated"]), total: n(o["total"]))
        }
        let concentrationBlock = folders["concentration"] as? [String: Any]
        copy.growthConcentration = concentration(concentrationBlock?["growth"]); copy.reductionConcentration = concentration(concentrationBlock?["reduction"])
        copy.movesCount = (folders["moves"] as? [Any])?.count ?? 0; copy.splits = i(folders["splits"])
        if let open = processes["open_deleted"] as? [String: Any] {
            copy.openDeletedBytes = n(open["allocated_bytes"]); copy.openDeletedFiles = i(open["files"])
            copy.openDeletedHolders = (open["holders"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        return copy
    }
    func with(first: Int, deferred: Int) -> IntervalEvidence { var copy = self; copy.firstMeasurements = first; copy.deferred = deferred; return copy }
}

// Coverage of the folder baseline right now (state key attribution_lifecycle). This is not
// interval comparability: each event carries its own evidence for its own interval.
struct FolderMonitoringStatus: Sendable, Equatable {
    let state: String
    let discovered: Int, baselined: Int, pending: Int, incomplete: Int, unavailable: Int, comparableNext: Int
    let degradedReason: String?
    let updatedAt: Date?
    let initializerStatus: String?, initializerMeasurements: Int?

    static func parse(_ json: String) -> FolderMonitoringStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], let state = root["state"] as? String else { return nil }
        func i(_ key: String) -> Int { (root[key] as? NSNumber)?.intValue ?? 0 }
        let initializer = root["initializer"] as? [String: Any]
        return FolderMonitoringStatus(state: state, discovered: i("discovered"), baselined: i("baselined"), pending: i("pending"), incomplete: i("incomplete"), unavailable: i("unavailable"), comparableNext: i("comparableNext"),
                                      degradedReason: root["degradedReason"] as? String, updatedAt: (root["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                                      initializerStatus: initializer?["status"] as? String, initializerMeasurements: (initializer?["measurements"] as? NSNumber)?.intValue)
    }
    var title: String {
        switch state {
        case "initializing": return "Initializing"
        case "ready": return "Active"
        case "partial": return "Partial"
        case "degraded": return "Degraded"
        default: return "Not started"
        }
    }
    // Counts only; no percentage that would blur coverage with comparability.
    var summary: String {
        switch state {
        case "initializing": return "Initializing · \(baselined) of \(discovered) folders baselined"
        case "ready": return "Active · \(baselined) folders tracked"
        case "partial": return (["Partial · \(baselined) tracked"] + (unavailable > 0 ? ["\(unavailable) unavailable"] : []) + (incomplete > 0 ? ["\(incomplete) incomplete"] : [])).joined(separator: " · ")
        case "degraded": return "Degraded · \(baselined) tracked · re-measuring after a file-history gap"
        default: return "Not started"
        }
    }
    var detail: String {
        var lines = ["Discovered \(discovered) · baselined \(baselined) · pending \(pending) · incomplete \(incomplete) · unavailable \(unavailable)"]
        lines.append("Comparable for the next interval: \(comparableNext)")
        if let degradedReason { lines.append(degradedReason) }
        if unavailable > 0 { lines.append("Unavailable folders are protected by macOS and are retried daily.") }
        if incomplete > 0 { lines.append("Incomplete folders stopped at their time limit three times and are retried every 6 hours.") }
        lines.append("This describes the current baseline. Each event shows which folders were comparable for its own interval.")
        return lines.joined(separator: "\n")
    }
}

// Comprehensive filesystem coverage right now (state key coverage_lifecycle).
struct FilesystemCoverageStatus: Sendable, Equatable {
    static let guidance = "To widen coverage, open System Settings → Privacy & Security → Full Disk Access, click +, and add ~/Applications/MacBook Storage Monitor.app (the background monitor). Storage Monitor never requests this itself; without it, monitoring continues and protected folders are reported as inaccessible."
    let state: String
    let units: Int, baselined: Int, discovered: Int, pending: Int, deferred: Int, inaccessible: Int, excluded: Int, stale: Int, reconcile: Int, splitPending: Int, monitored: Int
    let measuredAllocated: Int64
    let fullDiskAccess: String
    let establishedAt: Date?, comprehensiveSince: Date?, lastReconciledAt: Date?, lastContinuousAt: Date?
    let degradedReason: String?
    let notes: [(path: String, state: String, detail: String)]
    let initializerStatus: String?, initializerMeasurements: Int?

    static func == (a: Self, b: Self) -> Bool {
        (a.state, a.units, a.baselined, a.discovered, a.pending, a.deferred) == (b.state, b.units, b.baselined, b.discovered, b.pending, b.deferred)
            && (a.inaccessible, a.excluded, a.stale, a.reconcile, a.splitPending, a.monitored) == (b.inaccessible, b.excluded, b.stale, b.reconcile, b.splitPending, b.monitored)
            && (a.measuredAllocated, a.fullDiskAccess, a.establishedAt, a.lastReconciledAt, a.lastContinuousAt) == (b.measuredAllocated, b.fullDiskAccess, b.establishedAt, b.lastReconciledAt, b.lastContinuousAt)
            && (a.degradedReason, a.notes.count, a.initializerStatus, a.initializerMeasurements) == (b.degradedReason, b.notes.count, b.initializerStatus, b.initializerMeasurements)
    }
    static func parse(_ json: String) -> FilesystemCoverageStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], let state = root["state"] as? String else { return nil }
        func i(_ key: String) -> Int { (root[key] as? NSNumber)?.intValue ?? 0 }
        func d(_ key: String) -> Date? { (root[key] as? NSNumber).flatMap { $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue) : nil } }
        let initializer = root["initializer"] as? [String: Any]
        let notes = (root["notes"] as? [[String: Any]] ?? []).map { (path: $0["path"] as? String ?? "", state: $0["state"] as? String ?? "", detail: ($0["detail"] as? String) ?? ($0["reason"] as? String) ?? "") }
        return FilesystemCoverageStatus(state: state, units: i("units"), baselined: i("baselined"), discovered: i("discovered"), pending: i("pending"), deferred: i("deferred"), inaccessible: i("inaccessible"), excluded: i("excluded"), stale: i("stale"), reconcile: i("reconcile"), splitPending: i("splitPending"), monitored: i("monitored"),
                                        measuredAllocated: (root["measuredAllocated"] as? NSNumber)?.int64Value ?? 0, fullDiskAccess: root["fullDiskAccess"] as? String ?? "unknown",
                                        establishedAt: d("establishedAt"), comprehensiveSince: d("comprehensiveSince"), lastReconciledAt: d("lastReconciledAt"), lastContinuousAt: d("lastContinuousAt"),
                                        degradedReason: root["degradedReason"] as? String, notes: notes, initializerStatus: initializer?["status"] as? String, initializerMeasurements: (initializer?["measurements"] as? NSNumber)?.intValue)
    }
    var pendingWork: Int { discovered + pending + stale + reconcile + splitPending }
    var title: String {
        switch state {
        case "initializing": return "Initializing"
        case "ready": return "Comprehensive"
        case "partial": return "Partial"
        case "degraded": return "Reconciling"
        default: return "Not started"
        }
    }
    var summary: String {
        switch state {
        case "initializing": return "Initializing · \(baselined.formatted()) of \(units.formatted()) areas measured"
        case "ready": return "Comprehensive · \((monitored > 0 ? monitored : baselined).formatted()) areas monitored"
        case "partial": return "Comprehensive except \(inaccessible.formatted()) inaccessible areas" + (deferred > 0 ? " · \(deferred.formatted()) deferred" : "") + (pendingWork > 0 ? " · \(pendingWork.formatted()) pending" : "")
        case "degraded": return "Reconciling after a file-history gap · \(pendingWork.formatted()) areas pending"
        default: return "Not started"
        }
    }
    var detail: String {
        var lines = ["Areas \(units.formatted()) · measured \(baselined.formatted()) · monitored at last reading \(monitored.formatted()) · pending \(pendingWork.formatted()) · deferred \(deferred.formatted()) · inaccessible \(inaccessible.formatted()) · excluded \(excluded.formatted())"]
        lines.append("Measured file data: \(capacity(measuredAllocated)). Measured sizes are file sizes, not APFS physical allocation.")
        switch fullDiskAccess {
        case "granted": lines.append("Full Disk Access: granted to the background monitor.")
        case "not_granted": lines.append("Full Disk Access: not granted.\n" + Self.guidance)
        default: lines.append("Full Disk Access: unknown.\n" + Self.guidance)
        }
        if let degradedReason { lines.append(degradedReason) }
        if let comprehensiveSince { lines.append("Comprehensive since \(comprehensiveSince.formatted(date:.abbreviated,time:.shortened))") }
        if let lastReconciledAt { lines.append("Last successful reconciliation \(lastReconciledAt.formatted(date:.abbreviated,time:.shortened))") }
        if let lastContinuousAt { lines.append("Last continuous check \(lastContinuousAt.formatted(date:.abbreviated,time:.shortened))") }
        if !notes.isEmpty { lines.append("Inaccessible or excluded:\n" + notes.prefix(8).map { "\($0.path) — \($0.detail)" }.joined(separator: "\n") + (notes.count > 8 ? "\n… and \(notes.count - 8) more" : "")) }
        if let initializerStatus { lines.append("Initializer: \(initializerStatus)" + (initializerMeasurements.map { " · \($0.formatted()) measurements" } ?? "")) }
        return lines.joined(separator: "\n")
    }
}

struct EvidenceComparison: Identifiable, Sendable {
    var id: String { current.id }
    let current: DiagnosticMetric
    let currentTime: Date
    let previous: DiagnosticMetric?
    let previousTime: Date?
    var delta: Int64? { previous.map { current.bytes - $0.bytes } }
    var allocatedDelta: Int64? { guard let now = current.allocatedBytes, let before = previous?.allocatedBytes else { return nil }; return now - before }
}
struct StorageEvent: Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let category: String
    let delta: Int64?
    let previousFree: Int64?
    let currentFree: Int64?
    let previousTime: Date?
    let severity: EventSeverity
    let measurement: Measurement?
    let previousMeasurement: Measurement?
    let alerts: [AlertRecord]
    let diagnostics: [DiagnosticRecord]
    let comparisons: [EvidenceComparison]
    let source: String
    let searchText: String
    var interval: IntervalEvidence? = nil
    var isRecordedScan: Bool { measurement != nil }
    var hasDiagnostics: Bool { !diagnostics.isEmpty }
    var hasSwapChange: Bool { comparisons.contains { $0.current.source == .swap && ($0.delta ?? 0) != 0 } }
    var changeOrder: Int64 { delta ?? Int64.max }
    var freeOrder: Int64 { currentFree ?? Int64.max }
    var severityOrder: Int { severity.rawValue }
    var symbol: String { delta.map { $0 < 0 ? "arrow.down.right" : ($0 > 0 ? "arrow.up.right" : "clock") } ?? (hasDiagnostics ? "doc.text.magnifyingglass" : "clock") }
}
struct HistorySnapshot: Sendable {
    let measurements: [Measurement]
    let events: [StorageEvent]
    let loadedAt: Date
    var folderMonitoring: FolderMonitoringStatus? = nil
    var filesystemCoverage: FilesystemCoverageStatus? = nil
    var segmentStarts: Set<Int64> = []
    var latest: Measurement? { measurements.last }
    func baseline(seconds: TimeInterval) -> Measurement? {
        guard let latest else { return nil }
        let target = latest.timestamp.addingTimeInterval(-seconds)
        let start = measurements.last { $0.container == latest.container && segmentStarts.contains($0.id) }?.timestamp ?? .distantPast
        return measurements.last { $0.container == latest.container && $0.timestamp >= start && $0.timestamp <= target && target.timeIntervalSince($0.timestamp) <= 2100 }
    }
}

/// Presentation-only bridge from a plotted reading to its recorded event. A chart point is actionable only when
/// exactly one supplied event carries the same reading identity, container and full-precision timestamp.
enum StorageChartSelection {
    static func eventID(for reading: Measurement, events: [StorageEvent]) -> String? {
        let matches = events.filter { event in
            guard let measurement = event.measurement else { return false }
            return measurement.id == reading.id && measurement.container == reading.container && measurement.timestamp == reading.timestamp
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}

enum EventTypeFilter: String, CaseIterable, Codable, Sendable {
    case all = "All Events", loss = "Storage Loss", recovery = "Storage Recovery", warning = "Warnings", critical = "Critical Events", scans = "Recorded Scans", swap = "Swap Changes", diagnostic = "Diagnostic Events"
}
enum EventTimeFilter: String, CaseIterable, Codable, Sendable {
    case hour = "Last Hour", day = "Last 24 Hours", week = "Last 7 Days", month = "Last 30 Days", custom = "Custom Date Range"
    var seconds: TimeInterval? { switch self { case .hour: return 3600; case .day: return 86400; case .week: return 7*86400; case .month: return 30*86400; case .custom: return nil } }
}
enum EventSizeFilter: String, CaseIterable, Codable, Sendable {
    case all = "All Changes", mb100 = "Greater Than 100 MB", mb500 = "Greater Than 500 MB", gb1 = "Greater Than 1 GB", gb3 = "Greater Than 3 GB", gb5 = "Greater Than 5 GB", custom = "Custom Threshold"
    var bytes: Double? { switch self { case .all: return nil; case .mb100: return 100_000_000; case .mb500: return 500_000_000; case .gb1: return 1_000_000_000; case .gb3: return 3_000_000_000; case .gb5: return 5_000_000_000; case .custom: return nil } }
}
enum EventSort: String, CaseIterable, Codable, Sendable {
    case newest = "Newest First", oldest = "Oldest First", loss = "Largest Storage Loss", recovery = "Largest Storage Recovery", absolute = "Largest Absolute Change"
}
struct EventFilters: Codable, Equatable, Sendable {
    var type: EventTypeFilter = .all
    var time: EventTimeFilter = .day
    var size: EventSizeFilter = .all
    var severity: Int = -1
    var search = ""
    var sort: EventSort = .newest
    var customThreshold = "1"
    var customUnit = "GB"
    var start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86400))
    var end = minuteBoundary(Date())
    var threshold: Double? {
        guard size == .custom else { return size.bytes }
        guard ["MB","GB"].contains(customUnit), let value = Double(customThreshold), value.isFinite, value >= 0 else { return nil }
        let bytes = value * (customUnit == "MB" ? 1_000_000 : 1_000_000_000)
        return bytes.isFinite && bytes < Double(Int64.max) ? bytes : nil
    }
    var validation: String? {
        if size == .custom && threshold == nil { return "Enter a finite, nonnegative size threshold." }
        if time == .custom && start > end { return "Start must be before or equal to end. Dates use local time; both endpoints are included." }
        return nil
    }
    var activeCount: Int { [type != .all, time != .day, size != .all, severity != -1, !search.isEmpty].filter { $0 }.count }
    func matches(_ event: StorageEvent, now: Date) -> Bool {
        guard validation == nil else { return false }
        let lower = time.seconds.map { now.addingTimeInterval(-$0) } ?? start
        let upper = time == .custom ? end : now
        guard event.timestamp >= lower && event.timestamp <= upper else { return false }
        if severity != -1 && event.severity.rawValue != severity { return false }
        if size != .all { guard let delta = event.delta, let threshold, abs(Double(delta)) > threshold else { return false } }
        switch type {
        case .all: break
        case .loss: if (event.delta ?? 0) >= 0 { return false }
        case .recovery: if (event.delta ?? 0) <= 0 { return false }
        case .warning: if event.severity != .warning { return false }
        case .critical: if event.severity != .critical { return false }
        case .scans: if !event.isRecordedScan { return false }
        case .swap: if !event.hasSwapChange { return false }
        case .diagnostic: if !event.hasDiagnostics { return false }
        }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || event.searchText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    func apply(_ events: [StorageEvent], now: Date = Date()) -> [StorageEvent] {
        events.filter { matches($0, now: now) }.sorted { a,b in
            switch sort {
            case .newest: if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
            case .oldest: if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            case .loss, .recovery, .absolute:
                if a.delta == nil && b.delta != nil { return false }
                if a.delta != nil && b.delta == nil { return true }
                if let x = a.delta, let y = b.delta {
                    let lhs = sort == .absolute ? abs(Double(x)) : Double(x), rhs = sort == .absolute ? abs(Double(y)) : Double(y)
                    if lhs != rhs { return sort == .loss ? lhs < rhs : lhs > rhs }
                }
                if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
            }
            return a.id < b.id
        }
    }
}

enum EvidenceParser {
    static func volumes(_ value: Any?) -> [VolumeAllocation] {
        (value as? [[String: Any]] ?? []).compactMap {
            guard let uuid = ($0["APFSVolumeUUID"] ?? $0["VolumeUUID"]) as? String, let bytes = $0["CapacityInUse"] as? NSNumber, bytes.int64Value >= 0 else { return nil }
            return VolumeAllocation(id: uuid, name: $0["Name"] as? String ?? "Unnamed volume", bytes: bytes.int64Value, roles: $0["Roles"] as? [String] ?? [])
        }
    }
    // sysctl prints M/G suffixes that mean MiB/GiB, rounded to two decimals.
    static func swapValue(_ output: String, field: String) -> Int64? {
        let regex = try! NSRegularExpression(pattern: "\\b\(field)\\s*=\\s*([0-9]+(?:\\.[0-9]+)?)\\s*([KMGT]?)", options: [.caseInsensitive])
        let string = output as NSString
        guard let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: string.length)), let value = Double(string.substring(with: match.range(at: 1))) else { return nil }
        let unit = string.substring(with: match.range(at: 2)).uppercased()
        let exponent = ["":0, "K":1, "M":2, "G":3, "T":4][unit] ?? 0
        let bytes = value * pow(1024, Double(exponent))
        return bytes.isFinite && bytes >= 0 && bytes < Double(Int64.max) ? Int64(bytes.rounded()) : nil
    }
    static func swapBytes(_ output: String) -> Int64? { swapValue(output, field: "used") }
    static func swapAllocation(_ output: String) -> Int64? { swapValue(output, field: "total") }

    static func diagnostic(id: Int64, timestamp: Date, json: String) throws -> DiagnosticRecord {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw HistoryError.invalid("Diagnostic #\(id) is not an object.") }
        let physical = root["physical_container"] as? [String: Any] ?? [:]
        let version = (root["schema_version"] as? NSNumber)?.intValue ?? 1
        var record = version >= 2 ? structured(root, timestamp: timestamp) : legacy(root, timestamp: timestamp)
        record = DiagnosticRecord(id: id, timestamp: timestamp, container: physical["uuid"] as? String, free: (physical["free_bytes"] as? NSNumber)?.int64Value, used: (physical["used_bytes"] as? NSNumber)?.int64Value, volumes: volumes(root["volumes"]), metrics: record.metrics, commands: record.commands, interpretation: root["interpretation"] as? String ?? "Directory and volume sizes are not additive physical allocation.", schemaVersion: version, collectors: record.collectors, vmCounters: record.vmCounters, raw: json)
        return record
    }
    private static func date(_ value: Any?) -> Date? { (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }

    // Schema 2: normalized fields written by the monitor.
    private static func structured(_ root: [String: Any], timestamp: Date) -> DiagnosticRecord {
        var metrics = [DiagnosticMetric](), collectors = [CollectorStatus](), counters = [(String, Int64)]()
        if let swap = root["swap"] as? [String: Any] {
            let status = MeasurementStatus(rawValue: swap["status"] as? String ?? "") ?? .unknown
            let observed = date(swap["observed_at"]) ?? timestamp
            if let allocated = (swap["allocated_bytes"] as? NSNumber)?.int64Value {
                metrics.append(DiagnosticMetric(id: "swap:allocated", label: "Swap allocated", path: "vm.swapusage", bytes: allocated, kind: "Swap allocated", complete: status.isComplete, qualifier: "Exact bytes from sysctl", source: .swap, observedAt: observed))
            }
            if let used = (swap["used_bytes"] as? NSNumber)?.int64Value {
                metrics.append(DiagnosticMetric(id: "swap:used", label: "Swap in use", path: "vm.swapusage", bytes: used, kind: "Swap used", complete: status.isComplete, qualifier: "Exact bytes from sysctl", source: .swap, observedAt: observed))
            }
        }
        if let vm = root["vm"] as? [String: Any] {
            for key in ["page_size_bytes", "free_pages", "active_pages", "inactive_pages", "wired_pages", "compressor_pages", "swapins", "swapouts"] {
                if let value = (vm[key] as? NSNumber)?.int64Value { counters.append((key, value)) }
            }
        }
        for (index, item) in (root["directories"] as? [[String: Any]] ?? []).enumerated() {
            let path = item["path"] as? String ?? "Unknown location"
            let label = item["label"] as? String ?? (path as NSString).lastPathComponent
            let status = MeasurementStatus(rawValue: item["status"] as? String ?? "") ?? .unknown
            let source = EvidenceSource(rawValue: item["source"] as? String ?? "") ?? .other
            let denied = item["permission_denied"] as? [String: Any]
            collectors.append(CollectorStatus(id: "dir:\(index):\(path)", source: source, label: label, status: status, detail: item["limit"] as? String ?? status.plain, refusedPaths: denied?["examples"] as? [String] ?? [], permissionDenied: (denied?["count"] as? NSNumber)?.intValue ?? 0, observedAt: date(item["observed_at"])))
            if let logical = (item["logical_bytes"] as? NSNumber)?.int64Value {
                metrics.append(DiagnosticMetric(id: "dir:\(path)", label: label, path: path, bytes: logical, kind: "Apparent logical size", complete: status.isComplete, qualifier: status.plain, source: source, observedAt: date(item["observed_at"]) ?? timestamp, allocatedBytes: (item["allocated_bytes"] as? NSNumber)?.int64Value))
            }
        }
        for item in root["collectors"] as? [[String: Any]] ?? [] where item["source"] as? String != "directories" {
            let source = EvidenceSource(rawValue: item["source"] as? String ?? "") ?? .other
            let status = MeasurementStatus(rawValue: item["status"] as? String ?? "") ?? .unknown
            collectors.insert(CollectorStatus(id: "collector:\(source.rawValue)", source: source, label: source.title, status: status, detail: item["detail"] as? String ?? status.plain, refusedPaths: [], permissionDenied: 0, observedAt: date(item["observed_at"])), at: min(collectors.count, 3))
        }
        return DiagnosticRecord(id: 0, timestamp: timestamp, container: nil, free: nil, used: nil, volumes: [], metrics: metrics, commands: [], interpretation: "", collectors: collectors, vmCounters: counters)
    }

    // Schema 1: raw command records. Identical records are kept once.
    private static func legacy(_ root: [String: Any], timestamp: Date) -> DiagnosticRecord {
        var commands = [CommandEvidence](), metrics = [DiagnosticMetric](), collectors = [CollectorStatus](), seen = Set<String>()
        for value in root["commands"] as? [[String: Any]] ?? [] {
            let args = value["arguments"] as? [String] ?? []
            let name = value["name"] as? String ?? "Diagnostic command"
            let output = (value["output"] as? String) ?? ((value["stdout"] as? String ?? "") + (value["stderr"] as? String ?? ""))
            let error = value["error"] as? String ?? value["status"] as? String
            let path = args.last ?? value["path"] as? String
            guard seen.insert([name, path ?? "", output, error ?? ""].joined(separator: "\u{1}")).inserted else { continue }
            let command = CommandEvidence(id: commands.count, name: name, path: path, output: output, exitStatus: (value["exit_status"] as? NSNumber)?.intValue, timedOut: value["timed_out"] as? Bool ?? false, truncated: value["truncated"] as? Bool ?? false, error: error)
            commands.append(command)
            var detail = command.status.plain
            if command.source == .apfs && command.truncated { detail = "Output was cut off at its 4 KB limit and was not parsed; volume figures use the complete capacity reading" }
            collectors.append(CollectorStatus(id: "command:\(command.id)", source: command.source, label: name, status: command.status, detail: detail, refusedPaths: command.refusedPaths, permissionDenied: command.refusedPaths.count, observedAt: timestamp))
            if command.source == .swap {
                let note = command.qualifier + " · sysctl rounds to 0.01 MiB"
                if let allocated = swapAllocation(output) { metrics.append(DiagnosticMetric(id: "swap:allocated", label: "Swap allocated", path: "vm.swapusage", bytes: allocated, kind: "Swap allocated", complete: command.complete, qualifier: note, source: .swap, observedAt: timestamp, exact: false)) }
                if let used = swapBytes(output) { metrics.append(DiagnosticMetric(id: "swap:used", label: "Swap in use", path: "vm.swapusage", bytes: used, kind: "Swap used", complete: command.complete, qualifier: note, source: .swap, observedAt: timestamp, exact: false)) }
            } else if value["utility"] as? String == "/usr/bin/du" {
                for line in output.split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let kib = Int64(parts[0]), kib >= 0, kib <= Int64.max / 1024 else { continue }
                    let logical = args.contains("-A")
                    metrics.append(DiagnosticMetric(id: "du:\(logical ? "logical" : "blocks"):\(parts[1])", label: name, path: parts[1], bytes: kib * 1024, kind: logical ? "Apparent logical size" : "File-block estimate", complete: command.complete, qualifier: command.qualifier, source: EvidenceSource.infer(name: name, path: parts[1]), observedAt: timestamp))
                    break
                }
            }
        }
        return DiagnosticRecord(id: 0, timestamp: timestamp, container: nil, free: nil, used: nil, volumes: [], metrics: metrics, commands: commands, interpretation: "", collectors: collectors)
    }
}

enum EventProjector {
    // Each metric is compared only with the same metric, measured the same way,
    // complete at both ends, in the nearest earlier snapshot of the same container.
    // APFS volumes are compared from the capacity readings instead.
    static func comparisons(_ current: DiagnosticRecord, all: [DiagnosticRecord]) -> [EvidenceComparison] {
        let previous = all.last { $0.timestamp < current.timestamp && $0.container != nil && $0.container == current.container }
        let old = previous?.metrics ?? []
        return current.metrics.map { metric in
            let prior = metric.complete ? old.first { $0.id == metric.id && $0.kind == metric.kind && $0.complete } : nil
            return EvidenceComparison(current: metric, currentTime: metric.observedAt ?? current.timestamp, previous: prior, previousTime: prior.map { $0.observedAt ?? previous!.timestamp })
        }
    }
    static func project(measurements: [Measurement], alerts: [AlertRecord], diagnostics: [DiagnosticRecord], intervals: [Int64: IntervalEvidence] = [:], loadedAt: Date = Date(), segmentStarts: Set<Int64> = []) -> HistorySnapshot {
        let readings = measurements.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        let snapshots = diagnostics.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        var attachedAlerts = Set<Int64>(), attachedDiagnostics = Set<Int64>(), previous = [String: Measurement](), events = [StorageEvent]()
        for reading in readings {
            let prior = segmentStarts.contains(reading.id) ? nil : previous[reading.container]
            let delta = prior.map { reading.free - $0.free }
            let relatedAlerts = alerts.filter { abs($0.timestamp.timeIntervalSince(reading.timestamp)) < 0.001 && $0.free == reading.free && !attachedAlerts.contains($0.id) }
            let relatedDiagnostics = snapshots.filter { abs($0.timestamp.timeIntervalSince(reading.timestamp)) < 0.001 && $0.container == reading.container && !attachedDiagnostics.contains($0.id) }
            attachedAlerts.formUnion(relatedAlerts.map(\.id)); attachedDiagnostics.formUnion(relatedDiagnostics.map(\.id))
            let severity = ([EventSeverity.capacity(reading.free)] + relatedAlerts.filter(\.severityKnown).map(\.severity)).max { $0.rawValue < $1.rawValue }!
            let category = delta.map { $0 < 0 ? "Storage loss" : ($0 > 0 ? "Storage recovery" : "Recorded scan") } ?? (relatedAlerts.isEmpty ? "Recorded scan" : "Low-space warning")
            let evidence = relatedDiagnostics.flatMap { comparisons($0, all: snapshots) }
            var event = make(id: "reading:\(reading.id)", time: reading.timestamp, category: category, delta: delta, prior: prior, free: reading.free, severity: severity, measurement: reading, alerts: relatedAlerts, diagnostics: relatedDiagnostics, comparisons: evidence, source: "readings #\(reading.id); scan origin unknown (not recorded)")
            event.interval = intervals[reading.id]
            events.append(event)
            previous[reading.container] = reading
        }
        for alert in alerts where !attachedAlerts.contains(alert.id) {
            let category = alert.severityKnown && alert.severity == .critical ? "Critical alert" : (alert.severityKnown && alert.severity == .warning ? "Warning" : "Recorded alert")
            events.append(make(id: "alert:\(alert.id)", time: alert.timestamp, category: category, delta: alert.delta, prior: nil, free: alert.free, severity: alert.severity, measurement: nil, alerts: [alert], diagnostics: [], comparisons: [], source: "alerts #\(alert.id); no matching capacity reading"))
        }
        for diagnostic in snapshots where !attachedDiagnostics.contains(diagnostic.id) {
            events.append(make(id: "diagnostic:\(diagnostic.id)", time: diagnostic.timestamp, category: "Diagnostic snapshot", delta: nil, prior: nil, free: diagnostic.free, severity: .information, measurement: nil, alerts: [], diagnostics: [diagnostic], comparisons: comparisons(diagnostic, all: snapshots), source: "diagnostics #\(diagnostic.id); no matching capacity reading"))
        }
        var snapshot = HistorySnapshot(measurements: readings, events: events, loadedAt: loadedAt)
        snapshot.segmentStarts = segmentStarts
        return snapshot
    }
    private static func make(id: String, time: Date, category: String, delta: Int64?, prior: Measurement?, free: Int64?, severity: EventSeverity, measurement: Measurement?, alerts: [AlertRecord], diagnostics: [DiagnosticRecord], comparisons: [EvidenceComparison], source: String) -> StorageEvent {
        let volumeText = (measurement?.volumes ?? []).flatMap { [$0.name,$0.id,$0.roles.joined(separator:" ")] }
        let text = ([category, severity.label, source] + volumeText + alerts.flatMap { [$0.reasons, $0.notification,$0.rawSeverity] } + diagnostics.flatMap { [$0.interpretation] + $0.volumes.flatMap { [$0.name,$0.id,$0.roles.joined(separator:" ")] } + $0.commands.flatMap { [$0.name, $0.output, $0.error ?? ""] } + $0.metrics.flatMap { [$0.label, $0.path] } }).joined(separator: "\n")
        return StorageEvent(id: id, timestamp: time, category: category, delta: delta, previousFree: prior?.free, currentFree: free, previousTime: prior?.timestamp, severity: severity, measurement: measurement, previousMeasurement:prior, alerts: alerts, diagnostics: diagnostics, comparisons: comparisons, source: source, searchText: text)
    }
}

enum HistoryError: Error, LocalizedError {
    case missing(String), sqlite(String), invalid(String)
    /// First launch: nothing is recorded until the person turns monitoring on.
    static let noHistoryGuidance = "No monitoring history yet. Storage Monitor records free space only after you turn on background monitoring in Settings → Background Monitoring."
    var isMissingHistory: Bool { if case .missing = self { return true }; return false }
    var errorDescription: String? { switch self { case .missing: return Self.noHistoryGuidance; case .sqlite(let message): return "Could not read local history: \(message)"; case .invalid(let message): return "History contains an unreadable record: \(message)" } }
}

/// Keyboard focus ownership of the event list. The list owns focus from the moment it takes it until the person moves
/// focus deliberately: a click outside the list, Tab or Shift-Tab, or Find (⌘F). Losing focus without such a move (the
/// inspector opening rebuilds the split view and removes the list's responder, however long that takes) is undone.
struct EventListFocusOwnership: Equatable {
    private(set) var ownsFocus = false
    mutating func listFocused() { ownsFocus = true }
    mutating func deliberateMove() { ownsFocus = false }
    var restoresAfterLoss: Bool { ownsFocus }
    static func isDeliberateKey(keyCode: UInt16, command: Bool, characters: String?) -> Bool {
        keyCode == 48 || (command && characters?.lowercased() == "f")
    }
}

/// What the empty event list says and offers when recorded events exist but none are shown. Clearing filters is offered
/// only when filters other than the time range are set; a time range that holds no events offers the narrowest wider
/// range that holds the most recent one, so the guidance always names a step that reveals something.
struct EventListEmptyState: Equatable {
    enum Action: Equatable {
        case clearFilters
        case widen(EventTimeFilter)
        /// A custom range from the first recorded event through now (older than every preset range).
        case range(start: Date, end: Date)
    }
    let title: String
    let message: String
    let actions: [Action]

    static func make(filters: EventFilters, events: [StorageEvent], now: Date = Date()) -> EventListEmptyState? {
        guard !events.isEmpty, filters.apply(events, now: now).isEmpty else { return nil }
        guard filters.validation == nil else { return EventListEmptyState(title: "No matching events", message: "Correct the highlighted filter to see events.", actions: []) }
        var timeOnly = EventFilters()
        timeOnly.time = filters.time; timeOnly.start = filters.start; timeOnly.end = filters.end
        let otherFilters = filters.type != .all || filters.size != .all || filters.severity != -1 || !filters.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let inRange = timeOnly.apply(events, now: now)
        if !inRange.isEmpty {
            return EventListEmptyState(title: "No matching events", message: "\(inRange.count == 1 ? "1 event" : "\(inRange.count) events") in this time range \(inRange.count == 1 ? "doesn't" : "don't") match the other filters.", actions: [.clearFilters])
        }
        let range = filters.time == .custom ? "the selected dates" : filters.time.rawValue.lowercased().replacingOccurrences(of: "last", with: "the last")
        guard let latest = events.map(\.timestamp).max(), let earliest = events.map(\.timestamp).min() else { return nil }
        let wider: Action
        if let preset = [EventTimeFilter.day, .week, .month].first(where: { ($0.seconds ?? 0) > (filters.time.seconds ?? 0) && latest >= now.addingTimeInterval(-($0.seconds ?? 0)) }) {
            wider = .widen(preset)
        } else {
            wider = .range(start: minuteBoundary(earliest), end: minuteBoundary(now.addingTimeInterval(60)))
        }
        let message = "Nothing was recorded in \(range). The most recent change was \(latest.formatted(date: .abbreviated, time: .shortened))."
        return EventListEmptyState(title: "No events in this time range", message: message, actions: (otherFilters ? [.clearFilters] : []) + [wider])
    }
}
