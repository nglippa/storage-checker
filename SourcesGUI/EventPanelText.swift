import Foundation

// Plain-text counterparts of the inspector, for the clipboard. Copying never
// reads the disk or runs diagnostics. Provenance that the inspector keeps out
// of the main reading flow (reading IDs, UUIDs, exact bytes, exit codes, epoch
// timestamps) is always included here.
enum EventPanelText {
    static func bytes(_ value: Int64?, signed: Bool = false) -> String {
        value.map { "\(signed ? signedChange($0) : capacity($0)) (\(exactBytes($0)))" } ?? "Unknown"
    }
    static func stamp(_ date: Date) -> String { "\(date.formatted(date: .abbreviated, time: .standard)) [epoch \(String(format: "%.6f", date.timeIntervalSince1970))]" }

    // Short form used when copying a table row.
    static func summary(_ event: StorageEvent) -> String {
        """
        \(event.category)
        Timestamp: \(event.timestamp.formatted(date: .abbreviated, time: .complete))
        Severity: \(event.severity.label)
        Previous free: \(bytes(event.previousFree))
        Current free: \(bytes(event.currentFree))
        Net change: \(bytes(event.delta, signed: true))
        Source: \(event.source)
        """
    }

    static func details(_ event: StorageEvent) -> String {
        let analysis = CauseAnalyzer.analyze(event)
        var out = ["\(event.category) · \(event.severity.label)", event.timestamp.formatted(date: .abbreviated, time: .standard), analysis.headline]

        var causes = ["LIKELY CAUSES"]
        if analysis.causes.isEmpty { causes.append("Likely cause unavailable. \(analysis.causesUnavailable ?? "Insufficient diagnostic evidence.")") }
        for cause in analysis.causes {
            causes.append("\(cause.rank). \(cause.title)  \(signedChange(cause.delta))\n   \(cause.evidenceClass.label) — \(cause.allocationNote)\n   Responsible application: \(cause.application)\n   \(cause.explanation)" + cause.support.map { "\n   \($0)" }.joined())
        }
        out.append(causes.joined(separator: "\n"))

        let b = analysis.breakdown
        var breakdown = ["STORAGE BREAKDOWN", "Previous physical free: \(bytes(b.previousFree))", "Current physical free: \(bytes(b.currentFree))", "Net change: \(bytes(b.net, signed: true))"]
        if let start = b.start { breakdown.append("Interval: \(CauseAnalyzer.interval(start, b.end)) (\(CauseAnalyzer.span(start, b.end)))") }
        if b.hasVolumes {
            breakdown.append("Allocation change by volume:")
            breakdown += b.volumes.map { "  \($0.shortName.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.delta == 0 ? "—" : bytes($0.delta, signed: true))" }
        }
        if let text = b.reconciliationText { breakdown.append(text) }
        breakdown += analysis.attribution
        out.append(breakdown.joined(separator: "\n"))
        if event.observation != nil {
            out.append((["SNAPSHOTS AND SYSTEM ACTIVITY"] + StorageIntelligence.signals(event).map { "\($0.confidence.rawValue): \($0.title)\n\($0.detail)" }).joined(separator: "\n"))
        }

        var evidence = ["SUPPORTING EVIDENCE"]
        if analysis.evidence.isEmpty { evidence.append(event.diagnostics.isEmpty && event.interval == nil ? "No diagnostic snapshot or folder measurements were recorded for this event." : "No relevant measurements changed.") }
        for row in analysis.evidence { evidence.append("\(row.source.title): \(row.title)\n  \(row.values)\n  Change: \(row.change)\n  \(row.interval)\n  \(row.reliability)") }
        if analysis.hiddenUnchanged > 0 { evidence.append("\(analysis.hiddenUnchanged) unchanged measurement\(analysis.hiddenUnchanged == 1 ? "" : "s") not shown.") }
        if let collection = analysis.collection { evidence.append("Collection: \(collection.headline)" + collection.lines.map { "\n  \($0)" }.joined()) }
        out.append(evidence.joined(separator: "\n"))

        out.append(technical(event))
        return out.joined(separator: "\n\n")
    }

    // Exact values and provenance, as shown under Technical Details.
    static func technical(_ event: StorageEvent) -> String {
        var lines = ["TECHNICAL DETAILS", "Event: \(event.id) · \(event.source)", "Recorded: \(stamp(event.timestamp))"]
        if let start = event.previousTime { lines.append("Compared with: \(stamp(start))") }
        if let inventory = StorageIntelligence.inventoryText(event) { lines.append(inventory) }
        if let reading = event.measurement {
            lines.append("Container: \(reading.container) · reading #\(reading.id)" + (event.previousMeasurement.map { " vs #\($0.id)" } ?? ""))
            for volume in reading.volumes {
                let prior = event.previousMeasurement?.volumes.first { $0.id == volume.id }
                lines.append("Volume \(volume.name) [\(volume.roles.joined(separator: ","))] \(volume.id): \(exactBytes(volume.bytes))" + (prior.map { "; previous \(exactBytes($0.bytes)); change \(exactBytes(volume.bytes - $0.bytes))" } ?? ""))
            }
        }
        for alert in event.alerts {
            lines.append("Alert #\(alert.id) · \(alert.severityDescription) · reasons \(alert.reasons) · notification \(alert.notification)")
            if !alert.severityKnown { lines.append("  Unrecognized recorded severity; Information is used only for display and filtering.") }
        }
        if let i = event.interval {
            lines.append("Folder evidence for reading #\(i.readingId) vs #\(i.previousReadingId.map(String.init) ?? "none") · folders \(i.folderStatus) (\(i.measured) measured, \(i.carried) carried) · file activity \(i.activityStatus) · processes \(i.processStatus)")
            for c in i.changes { lines.append("  \(c.path) [\(c.kind)]: allocated \(exactBytes(c.beforeAllocated)) → \(exactBytes(c.afterAllocated)); logical \(exactBytes(c.beforeLogical)) → \(exactBytes(c.afterLogical))") }
            for c in i.correlations { lines.append("  Process correlation: \(c.name) pid \(c.pid) (\(c.executable)), \(c.writableFiles) writable files in \(c.folder)" + (c.bytesWritten.map { ", wrote \(exactBytes($0)) during interval" } ?? "")) }
            if let since = i.sinceEvent, let until = i.untilEvent { lines.append("  FSEvents \(since) → \(until), \(i.activityEvents) events, status \(i.activityStatus)") }
        }
        for diagnostic in event.diagnostics {
            lines.append("Diagnostic snapshot #\(diagnostic.id) · schema \(diagnostic.schemaVersion) · \(stamp(diagnostic.timestamp))")
            for comparison in event.comparisons where comparison.current.observedAt.map({ abs($0.timeIntervalSince(diagnostic.timestamp)) < 600 }) ?? true {
                var text = "  \(comparison.current.kind) · \(comparison.current.path): \(exactBytes(comparison.current.bytes))"
                if let allocated = comparison.current.allocatedBytes { text += " (allocated \(exactBytes(allocated)))" }
                if let previous = comparison.previous, let time = comparison.previousTime { text += "; previous \(exactBytes(previous.bytes)) at \(stamp(time))" }
                text += " · \(comparison.current.complete ? "complete" : "incomplete: \(comparison.current.qualifier)")"
                lines.append(text)
            }
            for collector in diagnostic.collectors {
                var text = "  Collector \(collector.label) [\(collector.source.title)]: \(collector.status.rawValue) — \(collector.detail)"
                if collector.permissionDenied > 0 { text += " · \(collector.permissionDenied) protected location(s), e.g. \(collector.refusedPaths.prefix(3).joined(separator: ", "))" }
                lines.append(text)
            }
            for command in diagnostic.commands { lines.append("  Command \(command.name): \(command.qualifier)") }
        }
        return lines.joined(separator: "\n")
    }

    // Everything recorded, verbatim and unabridged.
    static func raw(_ event: StorageEvent) -> String {
        var out = [String]()
        for diagnostic in event.diagnostics {
            out.append("=== Diagnostic snapshot #\(diagnostic.id) (\(stamp(diagnostic.timestamp)))")
            if diagnostic.commands.isEmpty { out.append(diagnostic.raw) }
            for command in diagnostic.commands {
                out.append("--- \(command.name)\(command.path.map { " · \($0)" } ?? "")\n\(command.qualifier)\n\(command.output.isEmpty ? (command.error ?? "No output recorded") : command.output)")
            }
        }
        if let i = event.interval { out.append("=== Folder evidence for reading #\(i.readingId)\n\(i.raw)") }
        if let observation = event.observation { out.append("=== Snapshot/system observation\n" + ((try? observation.encoded()) ?? "Unreadable observation")) }
        if out.isEmpty { out.append("No raw diagnostic output was recorded for this event.") }
        return out.joined(separator: "\n\n")
    }

    static func full(_ event: StorageEvent) -> String { details(event) }
}
