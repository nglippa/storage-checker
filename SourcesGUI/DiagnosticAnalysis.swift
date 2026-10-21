import Foundation

// Turns one recorded event into the inspector's reading order:
// likely causes → storage breakdown → supporting evidence → collection status.
//
// Rules this file keeps:
// - A cause is a measured APFS allocation change, never an application.
// - Allocation confidence and "who is responsible" are reported separately.
// - Evidence measured over a different interval is shown with its own interval
//   and never treated as the cause of this event.
// - Nothing is estimated for history that was not recorded.

// Technical sources under "Technical details". All start collapsed.
enum TechnicalSection: String, CaseIterable, Identifiable {
    case apfs = "APFS", vm = "Virtual memory", temporary = "Temporary files", application = "Application data", folders = "Folder growth", activity = "File activity", processes = "Processes", collectors = "Collector status", raw = "Raw command output", provenance = "Provenance"
    var id: String { rawValue }
    static let expandedByDefault: Set<TechnicalSection> = []
}

enum EvidenceClass: Int, Comparable, Sendable {
    case confirmed, likely, possible, unknown
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["Confirmed contributor", "Likely contributor", "Possible contributor", "Unknown"][rawValue] }
    var symbol: String { ["checkmark.seal.fill", "circle.lefthalf.filled", "circle.dotted", "questionmark.circle"][rawValue] }
}

struct VolumeChange: Identifiable, Sendable {
    let id: String
    let name: String
    let role: String?
    let before: Int64
    let after: Int64
    var delta: Int64 { after - before }
    var shortName: String { (role ?? name).uppercased() }
    var friendlyName: String {
        switch role {
        case "VM": return "Virtual memory"
        case "Data": return "Data volume"
        case .some(let role): return "\(role) volume"
        case nil: return name
        }
    }
    var order: Int { ["Data", "VM", "Update", "Preboot", "System", "Recovery"].firstIndex(of: role ?? "") ?? 99 }
}

enum Reconciliation: Equatable, Sendable {
    case exact, withinTolerance(Int64), unaccounted(Int64), unavailable(String)
    var accounted: Bool { if case .exact = self { return true }; if case .withinTolerance = self { return true }; return false }
}

struct StorageBreakdown: Sendable {
    let previousFree: Int64?
    let currentFree: Int64?
    let net: Int64?
    let start: Date?
    let end: Date
    let volumes: [VolumeChange]
    let unmatchedVolumes: [String]
    let reconciliation: Reconciliation
    var volumeNet: Int64 { volumes.reduce(0) { $0 + $1.delta } }
    var hasVolumes: Bool { !volumes.isEmpty }
    // Changes in the same direction as the event fill the proportional bar.
    var drivingVolumes: [VolumeChange] {
        guard let net, net != 0 else { return [] }
        return volumes.filter { net < 0 ? $0.delta > 0 : $0.delta < 0 }.sorted { abs($0.delta) > abs($1.delta) }
    }
    var offsettingVolumes: [VolumeChange] {
        guard let net, net != 0 else { return [] }
        return volumes.filter { net < 0 ? $0.delta < 0 : $0.delta > 0 }
    }
    var reconciliationText: String? {
        guard let net, net != 0 else { return nil }
        let noun = net < 0 ? "loss" : "recovery"
        switch reconciliation {
        case .exact: return "Measured volume changes account for the recorded \(noun) exactly."
        case .withinTolerance: return "Measured volume changes account for the recorded \(noun)."
        case .unaccounted(let rest): return "Some capacity change remains unaccounted for (\(signedChange(rest)) not explained by volume changes)."
        case .unavailable(let reason): return reason
        }
    }
}

struct LikelyCause: Identifiable, Sendable {
    var id: String { volumeID ?? title }
    let rank: Int
    let title: String
    let delta: Int64
    let evidenceClass: EvidenceClass
    let allocationNote: String
    let application: String
    let explanation: String
    let support: [String]
    let volumeID: String?
}

struct EvidenceRow: Identifiable, Sendable {
    let id: String
    let source: EvidenceSource
    let title: String
    let values: String
    let change: String
    let interval: String
    let intervalMatches: Bool
    let reliability: String
}

struct CollectionSummary: Sendable {
    let lines: [String]
    let measured: Int
    let incomplete: Int
    let refusedLocations: Int
    var hasProblems: Bool { incomplete > 0 || refusedLocations > 0 }
    var headline: String { incomplete > 0 || refusedLocations > 0 ? "\(incomplete) of \(measured) measurements incomplete" : "All \(measured) measurements complete" }
}

struct EventAnalysis: Sendable {
    let headline: String
    let causes: [LikelyCause]
    let causesUnavailable: String?
    let breakdown: StorageBreakdown
    let evidence: [EvidenceRow]
    let hiddenUnchanged: Int
    let collection: CollectionSummary?
    var attribution: [String] = []   // folder attribution and unattributed remainder, under the breakdown
}

enum CauseAnalyzer {
    // Diagnostics run just after their reading; anything further apart is a different interval.
    static let intervalTolerance: TimeInterval = 120
    static let maxCauses = 3
    // Directory changes smaller than this are treated as unchanged in the main view.
    static let negligibleChange: Int64 = 1_000_000

    static func analyze(_ event: StorageEvent) -> EventAnalysis {
        let breakdown = self.breakdown(event)
        let (evidence, hidden) = supportingEvidence(event, breakdown: breakdown)
        let (causes, unavailable) = rank(event, breakdown: breakdown)
        return EventAnalysis(headline: headline(breakdown), causes: causes, causesUnavailable: unavailable, breakdown: breakdown, evidence: evidence, hiddenUnchanged: hidden, collection: collection(event), attribution: attribution(event, breakdown: breakdown))
    }

    // MARK: Folder attribution

    // Evidence only counts for this event if it was measured between the same two readings.
    static func interval(_ event: StorageEvent) -> IntervalEvidence? {
        guard let interval = event.interval, let previous = event.previousMeasurement, interval.previousReadingId == previous.id else { return nil }
        return interval
    }
    // Folder changes in the direction of the event, largest first.
    static func drivingFolders(_ event: StorageEvent) -> [FolderChange] {
        guard let interval = interval(event), interval.comparable, let net = event.delta, net != 0 else { return [] }
        return interval.changes.filter { net < 0 ? $0.isGrowth : !$0.isGrowth }.sorted { abs($0.allocatedDelta) > abs($1.allocatedDelta) }
    }
    static func attribution(_ event: StorageEvent, breakdown: StorageBreakdown) -> [String] {
        guard let net = event.delta, net != 0, let data = breakdown.volumes.first(where: { $0.role == "Data" }), (net < 0) == (data.delta > 0), abs(data.delta) >= 1_000_000 else { return [] }
        let word = net < 0 ? "growth" : "reduction"
        guard let interval = event.interval else { return ["Responsible folders: not recorded for this event."] }
        guard interval.previousReadingId == event.previousMeasurement?.id else { return ["Responsible folders: folder measurements do not cover this exact interval."] }
        guard interval.comparable else { return ["Responsible folders: tracking started at this reading, so folder growth can be compared from the next reading."] }
        let folders = drivingFolders(event)
        let total = folders.reduce(Int64(0)) { $0 + abs($1.allocatedDelta) }
        // Coverage caveat: folders that could not be compared, or a gap in file-change history.
        var coverage = [String]()
        if interval.incomparableTotal > 0 { coverage.append("\(interval.incomparableTotal) folder\(interval.incomparableTotal == 1 ? "" : "s") could not be compared") }
        if interval.activityStatus != "complete" { coverage.append("file-change history was incomplete, so folders were re-measured instead") }
        let caveat = coverage.isEmpty ? "" : " (" + coverage.joined(separator: "; ") + ")"
        if folders.isEmpty { return ["Unattributed: no comparable monitored folder changed by 1 MB or more\(caveat), so the Data volume \(word) of \(changeMagnitude(data.delta)) is not explained by monitored folders."] }
        let remainder = abs(data.delta) - total
        let summary = "Measured folder \(word) (file allocated sizes): about \(changeMagnitude(total)) across \(folders.count) folder\(folders.count == 1 ? "" : "s")\(caveat)."
        if remainder > 1_000_000 { return [summary, "Estimated unattributed remainder: about \(changeMagnitude(remainder)) (Data volume \(word) minus measured folder \(word)). This is an estimate, not an APFS reconciliation: folder sizes are not physical allocation."] }
        return [summary, "Measured folder \(word) is as large as the Data volume \(word). This is an estimate, not an APFS reconciliation: clones, compression and snapshots mean folder sizes do not prove physical allocation."]
    }
    private static func folderSupport(_ event: StorageEvent) -> [String] {
        guard let interval = interval(event) else { return [] }
        var lines = [String]()
        for folder in drivingFolders(event).prefix(2) {
            let logical = folder.logicalDelta != folder.allocatedDelta ? ", logical \(signedChange(folder.logicalDelta))" : ""
            lines.append("Measured folder \(folder.isGrowth ? "growth" : "reduction"): \(folder.path) \(signedChange(folder.allocatedDelta)) allocated\(logical).")
            for correlation in interval.correlations.filter({ $0.folder == folder.path }).prefix(2) {
                lines.append("Process correlation: \(correlation.name) (pid \(correlation.pid)) had \(correlation.writableFiles) file\(correlation.writableFiles == 1 ? "" : "s") open for writing there. This links the process to the folder, not to the APFS allocation.")
            }
        }
        return lines
    }

    // MARK: Breakdown

    static func breakdown(_ event: StorageEvent) -> StorageBreakdown {
        var changes = [VolumeChange](), unmatched = [String]()
        if let current = event.measurement, let previous = event.previousMeasurement {
            for volume in current.volumes {
                if let prior = previous.volumes.first(where: { $0.id == volume.id }) {
                    changes.append(VolumeChange(id: volume.id, name: volume.name, role: volume.roles.first, before: prior.bytes, after: volume.bytes))
                } else { unmatched.append(volume.name) }
            }
            unmatched += previous.volumes.filter { old in !current.volumes.contains { $0.id == old.id } }.map(\.name)
        }
        changes.sort { $0.order == $1.order ? $0.name < $1.name : $0.order < $1.order }
        let reconciliation: Reconciliation
        if let net = event.delta, event.measurement != nil, event.previousMeasurement != nil {
            if changes.isEmpty { reconciliation = .unavailable("Volume allocations were not recorded for both readings.") }
            else if !unmatched.isEmpty { reconciliation = .unavailable("The set of APFS volumes changed between readings, so totals cannot be reconciled.") }
            else {
                // Free space falls by exactly what volumes allocate, so the sum should be zero.
                let rest = -net - changes.reduce(0) { $0 + $1.delta }
                let tolerance = max(Int64(1_048_576), abs(net) / 100)
                reconciliation = rest == 0 ? .exact : (abs(rest) <= tolerance ? .withinTolerance(rest) : .unaccounted(rest))
            }
        } else { reconciliation = .unavailable("No earlier comparable reading.") }
        return StorageBreakdown(previousFree: event.previousFree, currentFree: event.currentFree, net: event.delta, start: event.previousTime, end: event.timestamp, volumes: changes, unmatchedVolumes: unmatched, reconciliation: reconciliation)
    }

    static func headline(_ breakdown: StorageBreakdown) -> String {
        guard let net = breakdown.net else { return "No earlier reading to compare with." }
        let span = breakdown.start.map { " between \(interval($0, breakdown.end))" } ?? ""
        if net == 0 { return "Available capacity did not change\(span)." }
        return "Available capacity \(net < 0 ? "decreased" : "increased") by \(changeMagnitude(net))\(span)."
    }

    // MARK: Ranking

    static func rank(_ event: StorageEvent, breakdown: StorageBreakdown) -> ([LikelyCause], String?) {
        guard event.measurement != nil || !event.diagnostics.isEmpty || !event.alerts.isEmpty else { return ([], "Insufficient diagnostic evidence.") }
        guard let net = breakdown.net else { return ([], event.measurement == nil ? "This record has no capacity readings to compare." : "This is the first reading for this container, so there is no earlier measurement to compare.") }
        guard net != 0 else { return ([], "Available capacity did not change, so there is nothing to attribute.") }
        let loss = net < 0
        let matched = event.comparisons.filter { matchesEvent($0, event) }
        var causes = [LikelyCause]()
        for volume in breakdown.drivingVolumes.prefix(maxCauses) {
            var support = [String]()
            if volume.role == "VM" { support += swapSupport(matched) }
            if volume.role == "Data" { support += folderSupport(event) + directorySupport(matched, loss: loss) }
            let amount = changeMagnitude(volume.delta)
            causes.append(LikelyCause(rank: causes.count + 1, title: title(volume, growth: loss), delta: volume.delta, evidenceClass: .confirmed,
                                      allocationNote: "measured APFS allocation \(loss ? "increase" : "decrease")", application: "Unknown",
                                      explanation: "\(volume.friendlyName) allocation \(loss ? "increased" : "decreased") by \(amount).", support: support, volumeID: volume.id))
        }
        if !causes.isEmpty { return (causes, nil) }
        // Without volume figures, same-interval measurements are at most possible contributors.
        for comparison in matched.sorted(by: { abs($0.delta ?? 0) > abs($1.delta ?? 0) }) where causes.count < maxCauses {
            guard let delta = comparison.delta, delta != 0, (delta > 0) == loss, comparison.current.kind != "File-block estimate", comparison.current.kind != "Swap used" else { continue }
            let what = comparison.current.source == .swap ? "Swap allocation" : comparison.current.label
            causes.append(LikelyCause(rank: causes.count + 1, title: "\(what) \(loss ? "growth" : "reduction")", delta: delta, evidenceClass: .possible,
                                      allocationNote: "measured over the same interval; not an APFS allocation", application: "Unknown",
                                      explanation: "\(what) changed by \(signedChange(delta)) over the same interval. Logical sizes do not establish physical allocation.", support: [], volumeID: nil))
        }
        if !causes.isEmpty { return (causes, nil) }
        if breakdown.hasVolumes { return ([], "No volume allocation moved in the direction of this change.") }
        return ([], "Insufficient diagnostic evidence.")
    }

    static func title(_ volume: VolumeChange, growth: Bool) -> String {
        switch volume.role {
        case "VM": return growth ? "Virtual memory growth" : "Virtual memory reduction"
        case "Data": return growth ? "Data volume growth" : "Data volume reduction"
        default: return growth ? "Other system allocation" : "Other system allocation released"
        }
    }

    private static func swapSupport(_ matched: [EvidenceComparison]) -> [String] {
        guard let swap = matched.first(where: { $0.current.id == "swap:allocated" }), let delta = swap.delta else { return [] }
        if delta == 0 { return ["Swap allocation did not change over the same interval."] }
        return ["Likely mechanism: swap allocation changed by \(signedChange(delta)) over the same interval."]
    }
    private static func directorySupport(_ matched: [EvidenceComparison], loss: Bool) -> [String] {
        matched.filter { $0.current.kind == "Apparent logical size" && abs($0.delta ?? 0) >= negligibleChange && (($0.delta ?? 0) > 0) == loss }
            .sorted { abs($0.delta ?? 0) > abs($1.delta ?? 0) }.prefix(2)
            .map { "Possible related change: \($0.current.label) logical size \(signedChange($0.delta ?? 0)) over the same interval." }
    }

    // MARK: Intervals

    static func matchesEvent(_ comparison: EvidenceComparison, _ event: StorageEvent) -> Bool {
        guard let start = event.previousTime, let before = comparison.previousTime else { return false }
        return abs(before.timeIntervalSince(start)) <= intervalTolerance && abs(comparison.currentTime.timeIntervalSince(event.timestamp)) <= intervalTolerance
    }

    static func interval(_ start: Date, _ end: Date) -> String {
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        let first = sameDay ? start.formatted(date: .omitted, time: .shortened) : start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let last = sameDay ? end.formatted(date: .omitted, time: .shortened) : end.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(first) and \(last)"
    }
    static func span(_ start: Date, _ end: Date) -> String {
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 120 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours < 48 ? String(format: "%.1f h", hours) : String(format: "%.1f days", hours / 24)
    }

    // MARK: Supporting evidence

    static func supportingEvidence(_ event: StorageEvent, breakdown: StorageBreakdown) -> ([EvidenceRow], Int) {
        var rows = [EvidenceRow](), hidden = 0
        let vmMoved = breakdown.volumes.contains { $0.role == "VM" && $0.delta != 0 }
        let comparisons = event.comparisons
        let allocated = comparisons.first { $0.current.id == "swap:allocated" }, used = comparisons.first { $0.current.id == "swap:used" }
        if let anchor = allocated ?? used {
            let changed = (allocated?.delta ?? 0) != 0 || (used?.delta ?? 0) != 0
            if changed || vmMoved || anchor.previous == nil {
                let values = [allocated.map { "Allocated \(capacity($0.current.bytes))" }, used.map { "Used \(capacity($0.current.bytes))" }].compactMap { $0 }.joined(separator: " · ")
                let change: String
                if anchor.previous == nil { change = "No earlier measurement" }
                else { change = [allocated?.delta.map { "Allocated \(signedChange($0))" }, used?.delta.map { "used \(signedChange($0))" }].compactMap { $0 }.joined(separator: ", ") }
                rows.append(row(id: "swap", source: .swap, title: "Swap", values: values, change: change, comparison: anchor, event: event,
                                reliability: anchor.current.exact ? "Exact values from the system" : "Recorded values are rounded to 0.01 MiB"))
            } else { hidden += [allocated, used].compactMap { $0 }.count }
        }
        if let interval = interval(event), interval.comparable {
            let driving = drivingFolders(event)
            let others = interval.changes.filter { change in !driving.contains { $0.path == change.path } }.sorted { abs($0.allocatedDelta) > abs($1.allocatedDelta) }
            for change in (driving + others).prefix(5) {
                let cloned = interval.groups.first { $0.path == change.path }?.cloned ?? 0
                rows.append(EvidenceRow(id: "folder:" + change.path, source: .folders, title: change.path,
                                        values: "Allocated \(changeMagnitude(change.beforeAllocated)) → \(changeMagnitude(change.afterAllocated)) · logical \(changeMagnitude(change.beforeLogical)) → \(changeMagnitude(change.afterLogical))",
                                        change: "\(signedChange(change.allocatedDelta)) allocated, logical \(signedChange(change.logicalDelta))\(change.kind == "new" ? " (new folder)" : change.kind == "removed" ? " (removed)" : "")",
                                        interval: "Measured at this event's two readings", intervalMatches: true,
                                        reliability: "Measured file sizes, not APFS physical allocation" + (cloned > 0 ? " · \(cloned) cloned file\(cloned == 1 ? "" : "s") may share storage" : "")))
            }
            if interval.activityStatus != "unavailable" {
                let created = interval.groups.reduce(0) { $0 + $1.created }, removed = interval.groups.reduce(0) { $0 + $1.removed }, cloned = interval.groups.reduce(0) { $0 + $1.cloned }
                rows.append(EvidenceRow(id: "activity", source: .fileActivity, title: "Changed files (FSEvents)",
                                        values: "\(interval.activityEvents.formatted()) changes in \(interval.groups.count) folder\(interval.groups.count == 1 ? "" : "s") · \(created.formatted()) created, \(removed.formatted()) removed\(cloned > 0 ? ", \(cloned.formatted()) cloned" : "")",
                                        change: "Paths only; FSEvents does not identify which process wrote them",
                                        interval: interval.activityStatus == "complete" ? "Complete history between this event's two readings" : "History has a gap: \(interval.gaps.first ?? "incomplete")",
                                        intervalMatches: interval.activityStatus == "complete", reliability: interval.activityStatus == "complete" ? "Event counts are coalesced by macOS, not byte amounts" : "Changed paths may be incomplete"))
            }
            for correlation in interval.correlations.prefix(3) {
                rows.append(EvidenceRow(id: "process:\(correlation.id)", source: .processes, title: "\(correlation.name) (pid \(correlation.pid))",
                                        values: "\(correlation.writableFiles) of \(correlation.openFiles) open file\(correlation.openFiles == 1 ? "" : "s") writable in \(correlation.folder)",
                                        change: correlation.bytesWritten.map { "Wrote \(changeMagnitude($0)) to disk during the interval (all destinations)" } ?? "Disk writes during the interval not available",
                                        interval: "Files open at the end of this interval", intervalMatches: true,
                                        reliability: "Process correlation, not proof that this process allocated the storage"))
            }
        }
        for comparison in comparisons where comparison.current.kind == "Apparent logical size" {
            guard comparison.current.complete else { continue }  // reported under collection status instead
            if let delta = comparison.delta, abs(delta) < negligibleChange { hidden += 1; continue }
            var values = "Logical size \(changeMagnitude(comparison.current.bytes))"
            if let allocatedBytes = comparison.current.allocatedBytes { values += " · allocated \(changeMagnitude(allocatedBytes))" }
            let change = comparison.delta.map { "Logical size \(signedChange($0))" } ?? "No earlier measurement"
            let name = comparison.current.source == .temporaryFiles || comparison.current.label.hasPrefix("Chrome") ? comparison.current.label : friendlyLabel(comparison.current)
            rows.append(row(id: comparison.id, source: comparison.current.source, title: name, values: values, change: change, comparison: comparison, event: event,
                            reliability: "Complete measurement · logical size is not physical allocation"))
        }
        return (rows, hidden)
    }
    private static func friendlyLabel(_ metric: DiagnosticMetric) -> String {
        // Legacy labels read like "logical apparent bytes (KiB) /path"; show the folder instead.
        if metric.label.contains("/") || metric.label.lowercased().contains("kib") { return (metric.path as NSString).lastPathComponent }
        return metric.label
    }
    private static func row(id: String, source: EvidenceSource, title: String, values: String, change: String, comparison: EvidenceComparison, event: StorageEvent, reliability: String) -> EvidenceRow {
        let matches = matchesEvent(comparison, event)
        let intervalText: String
        if let start = comparison.previousTime {
            intervalText = matches ? "Same interval as this event" : "Measured between \(interval(start, comparison.currentTime)) (\(span(start, comparison.currentTime))). Different interval from this event, so not treated as its cause."
        } else { intervalText = "Observed at \(comparison.currentTime.formatted(date: .omitted, time: .shortened))" }
        return EvidenceRow(id: id, source: source, title: title, values: values, change: change, interval: intervalText, intervalMatches: matches, reliability: reliability)
    }

    // MARK: Collection status

    static func collection(_ event: StorageEvent) -> CollectionSummary? {
        let folderLines = folderStatusLines(event)
        guard !event.diagnostics.isEmpty else {
            guard let interval = interval(event) else { return nil }
            let measured = interval.measured + interval.carried
            // On a first baseline, "not compared" means "no earlier measurement", not incomplete.
            return CollectionSummary(lines: folderLines, measured: measured, incomplete: interval.comparable ? interval.incomparableTotal : 0, refusedLocations: 0)
        }
        let collectors = event.diagnostics.flatMap(\.collectors).filter { $0.status != .absent }
        // Old records repeat the same refused paths across du -A, du -k and find,
        // so count unique paths. New records store a count per distinct location.
        var refused = Set<String>(), structuredCount = 0
        for diagnostic in event.diagnostics {
            for collector in diagnostic.collectors where collector.status != .absent {
                if diagnostic.schemaVersion >= 2 { structuredCount += collector.permissionDenied } else { refused.formUnion(collector.refusedPaths) }
            }
        }
        let refusedTotal = refused.count + structuredCount
        let timedOut = collectors.filter { $0.status == .timedOut }.count
        let partial = collectors.filter { [.partial, .truncated, .unknown].contains($0.status) && $0.source != .apfs }.count
        let failed = collectors.filter { [.failed, .skipped].contains($0.status) }.count
        var lines = [String]()
        if refusedTotal > 0 { lines.append("Some protected directories could not be inspected (\(refusedTotal) location\(refusedTotal == 1 ? "" : "s")). macOS restricts these by design.") }
        if timedOut > 0 { lines.append("\(timedOut) measurement\(timedOut == 1 ? "" : "s") stopped at a time limit and \(timedOut == 1 ? "is" : "are") incomplete.") }
        if partial > 0 { lines.append("\(partial) measurement\(partial == 1 ? " is" : "s are") incomplete and \(partial == 1 ? "is" : "are") not used to calculate changes.") }
        if failed > 0 { lines.append("\(failed) measurement\(failed == 1 ? " was" : "s were") not collected.") }
        if collectors.contains(where: { $0.source == .apfs && $0.status == .truncated }) { lines.append("The APFS diagnostic output was cut off and was not used. Volume figures come from the complete capacity reading.") }
        let incomplete = collectors.filter { $0.status.isProblem }.count
        return CollectionSummary(lines: lines + folderLines, measured: collectors.count, incomplete: incomplete, refusedLocations: refusedTotal)
    }
    static func folderStatusLines(_ event: StorageEvent) -> [String] {
        guard let interval = interval(event) else { return [] }
        var lines = [String]()
        if interval.folderStatus == "baseline_only" { lines.append("Folder tracking began at this reading; changes can be compared from the next one.") }
        if interval.comparable && interval.incomparableTotal > 0 { lines.append("\(interval.incomparableTotal) folder\(interval.incomparableTotal == 1 ? "" : "s") could not be compared (incomplete, protected, or not measured at the previous reading).") }
        if interval.activityStatus == "gap" { lines.append("File-change history has a gap, so changed paths may be incomplete.") }
        if interval.activityStatus == "unavailable", let reason = interval.activityReason { lines.append(reason) }
        return lines
    }
}
