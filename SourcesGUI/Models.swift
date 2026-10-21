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
    var isGrowth: Bool { max(allocatedDelta, logicalDelta) > 0 && kind != "shrank" && kind != "removed" }
}
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
    var latest: Measurement? { measurements.last }
    func baseline(seconds: TimeInterval) -> Measurement? {
        guard let latest else { return nil }
        let target = latest.timestamp.addingTimeInterval(-seconds)
        return measurements.last { $0.container == latest.container && $0.timestamp <= target && target.timeIntervalSince($0.timestamp) <= 2100 }
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
            guard let uuid = $0["APFSVolumeUUID"] as? String, let bytes = $0["CapacityInUse"] as? NSNumber, bytes.int64Value >= 0 else { return nil }
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
    static func project(measurements: [Measurement], alerts: [AlertRecord], diagnostics: [DiagnosticRecord], intervals: [Int64: IntervalEvidence] = [:], loadedAt: Date = Date()) -> HistorySnapshot {
        let readings = measurements.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        let snapshots = diagnostics.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        var attachedAlerts = Set<Int64>(), attachedDiagnostics = Set<Int64>(), previous = [String: Measurement](), events = [StorageEvent]()
        for reading in readings {
            let prior = previous[reading.container]
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
        return HistorySnapshot(measurements: readings, events: events, loadedAt: loadedAt)
    }
    private static func make(id: String, time: Date, category: String, delta: Int64?, prior: Measurement?, free: Int64?, severity: EventSeverity, measurement: Measurement?, alerts: [AlertRecord], diagnostics: [DiagnosticRecord], comparisons: [EvidenceComparison], source: String) -> StorageEvent {
        let volumeText = (measurement?.volumes ?? []).flatMap { [$0.name,$0.id,$0.roles.joined(separator:" ")] }
        let text = ([category, severity.label, source] + volumeText + alerts.flatMap { [$0.reasons, $0.notification,$0.rawSeverity] } + diagnostics.flatMap { [$0.interpretation] + $0.volumes.flatMap { [$0.name,$0.id,$0.roles.joined(separator:" ")] } + $0.commands.flatMap { [$0.name, $0.output, $0.error ?? ""] } + $0.metrics.flatMap { [$0.label, $0.path] } }).joined(separator: "\n")
        return StorageEvent(id: id, timestamp: time, category: category, delta: delta, previousFree: prior?.free, currentFree: free, previousTime: prior?.timestamp, severity: severity, measurement: measurement, previousMeasurement:prior, alerts: alerts, diagnostics: diagnostics, comparisons: comparisons, source: source, searchText: text)
    }
}

enum HistoryError: Error, LocalizedError {
    case missing(String), sqlite(String), invalid(String)
    var errorDescription: String? { switch self { case .missing(let path): return "No monitoring history at \(path). The background monitor has not created this database."; case .sqlite(let message): return "Could not read local history: \(message)"; case .invalid(let message): return "History contains an unreadable record: \(message)" } }
}
