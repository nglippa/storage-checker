import SwiftUI
import AppKit

struct EventDetailView: View {
    let event: StorageEvent?
    var body: some View {
        if let event {
            EventInspector(event: event, analysis: CauseAnalyzer.analyze(event))
                .accessibilityIdentifier("event.details")
        } else {
            ContentUnavailableView("Select an event", systemImage: "sidebar.right", description: Text("See what most likely changed available storage, and the measurements behind it."))
                .accessibilityIdentifier("event.noSelection")
        }
    }
}

private struct EventInspector: View {
    let event: StorageEvent
    let analysis: EventAnalysis
    @ViewState private var expanded = TechnicalSection.expandedByDefault
    @ViewState private var showFullExplanation = false
    /// The measurements behind the summary. Remembered while the viewer is open.
    @AppStorage("event.showEvidence", store: ViewerStore.viewPreferences) private var showEvidence = false

    // QA-only capture aids; ignored unless the viewer was opened on a QA database.
    private static let qaArgs = ViewerConfiguration.current.isQA ? CommandLine.arguments : []
    private static let qaScrollBottom = qaArgs.contains("--inspector-scroll-bottom")
    private static let qaShowEvidence = qaArgs.contains("--show-evidence")
    private static let qaExpanded: Set<TechnicalSection> = qaArgs.firstIndex(of: "--expand-technical").flatMap { i in qaArgs.count > i+1 ? Set(qaArgs[i+1].split(separator: ",").compactMap { TechnicalSection(rawValue: String($0)) }) : nil } ?? []

    private var summary: EventPlainSummary { EventPlainSummary.make(event, analysis) }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 0).id("inspector.top")
                header
                plainSummary
                Divider()
                InspectorDisclosure("Details and evidence", isExpanded: $showEvidence) {
                    VStack(alignment: .leading, spacing: 0) {
                        InspectorSection(title: "Measured changes", id: "event.causes") { causes }
                        InspectorSection(title: "Storage breakdown", id: "event.breakdown") { breakdown }
                        if event.measurement != nil {
                            InspectorSection(title: "Snapshots and system activity", id: "event.snapshotIntelligence") { snapshotIntelligence }
                        }
                        InspectorSection(title: "Supporting evidence", id: "event.evidence") { evidence }
                        InspectorSection(title: "Technical details", id: "event.technical", divider: false) { technical }
                    }
                }
                .padding(.top, 10)
                .accessibilityHint("Exact measurements, volume allocation, timestamps and diagnostic output")
                .accessibilityIdentifier("event.evidenceDisclosure")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(height: 1).id("inspector.bottom")
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // A newly selected event starts with every technical disclosure collapsed, at the top.
        .onChange(of: event.id) { _, _ in expanded = TechnicalSection.expandedByDefault; proxy.scrollTo("inspector.top", anchor: .top) }
        .onAppear {
            if Self.qaShowEvidence || !Self.qaExpanded.isEmpty { showEvidence = true }
            if !Self.qaExpanded.isEmpty { expanded = Self.qaExpanded }
            if Self.qaScrollBottom { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo("inspector.bottom", anchor: .bottom) } }
        }
        }
    }

    // MARK: Plain summary

    private var plainSummary: some View {
        let s = summary
        return VStack(alignment: .leading, spacing: 14) {
            PlainBlock(title: "What happened", id: "event.whatHappened") {
                Text(s.whatHappened).font(.body)
            }
            PlainBlock(title: "Possible explanation", id: "event.explanation") {
                VStack(alignment:.leading,spacing:8) {
                    if analysis.causes.isEmpty {
                        Text(s.explanation ?? analysis.causesUnavailable ?? "No measured contributor was recorded.").font(.body)
                    } else {
                        ForEach(analysis.causes.prefix(3)) { cause in CompactCauseRow(cause:cause) }
                        Text("These are observed measurements or correlations, not proof that an application caused the change.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !analysis.breakdown.offsettingVolumes.isEmpty {
                        Text("Offsetting allocation: " + analysis.breakdown.offsettingVolumes.map { "\($0.friendlyName) \(signedChange($0.delta))" }.joined(separator:", ") + ".")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            PlainBlock(title: "How certain is this?", id: "event.certainty") {
                Label { Text(s.certaintyText) } icon: {
                    Image(systemName: s.certainty == .measured ? "checkmark.circle" : (s.certainty == .unknown ? "questionmark.circle" : "circle.lefthalf.filled"))
                        .foregroundStyle(s.certainty == .measured ? Color.green : Color.secondary)
                }.font(.callout).foregroundStyle(.secondary)
            }
            let related = StorageIntelligence.signals(event).filter { $0.confidence == .plausible || $0.confidence == .strongCorrelation || ($0.id == "snapshots" && !event.snapshotComparison.changes.isEmpty) }
            if !related.isEmpty {
                PlainBlock(title: "Related system activity", id: "event.systemActivity") {
                    ForEach(related) { signal in
                        Text("\(signal.confidence.rawValue): \(signal.title)").font(.callout).help(signal.detail)
                    }
                }
            }
            if !s.actions.isEmpty {
                PlainBlock(title: "What can I do?", id: "event.actions") {
                    VStack(alignment: .leading, spacing: 7) { ForEach(s.actions, id: \.self) { Text($0).font(.callout) } }
                }
            }
            // The full sentence is only hidden when measured contributors replaced it above; never shown twice.
            if !analysis.causes.isEmpty, let explanation = s.explanation {
                InspectorDisclosure("Full explanation", isExpanded:$showFullExplanation) {
                    Text(explanation).font(.callout).fixedSize(horizontal:false,vertical:true)
                }
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.category).font(.headline)
                Spacer(minLength: 8)
                SeverityLabel(severity: event.severity)
                Menu {
                    Button("Copy Details") { copy(EventPanelText.details(event)) }.accessibilityIdentifier("event.copyDetails")
                    Button("Copy Raw Output") { copy(EventPanelText.raw(event)) }.accessibilityIdentifier("event.copyRaw")
                } label: { Image(systemName: "doc.on.doc") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Copy event details or raw diagnostic output")
                    .accessibilityLabel("Copy")
                    .accessibilityIdentifier("event.copyMenu")
            }
            Text(event.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 16).padding(.bottom, 14)
    }

    // MARK: A — Likely causes

    @ViewBuilder private var causes: some View {
        if analysis.causes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Label("Likely cause unavailable", systemImage: "questionmark.circle").font(.callout.weight(.medium))
                Text(analysis.causesUnavailable ?? "Insufficient diagnostic evidence.").font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(analysis.causes) { CauseRow(cause: $0) }
            }
        }
    }

    // MARK: B — Storage breakdown

    @ViewBuilder private var breakdown: some View {
        let b = analysis.breakdown
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ValueRow(label: "Previous physical free", value: b.previousFree.map { capacity($0) } ?? "—")
                ValueRow(label: "Current physical free", value: b.currentFree.map { capacity($0) } ?? "—")
                ValueRow(label: "Free space change", value: b.net.map(signedChange) ?? "Unknown", emphasized: true)
                if let start = b.start { ValueRow(label: "Interval", value: "\(start.formatted(date: .omitted, time: .shortened)) → \(b.end.formatted(date: .omitted, time: .shortened)) · \(CauseAnalyzer.span(start, b.end))") }
            }
            if b.hasVolumes {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allocation change by volume").font(.subheadline).foregroundStyle(.secondary)
                    if !b.drivingVolumes.isEmpty { SegmentBar(volumes: b.drivingVolumes) }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(b.volumes) { volume in
                            GridRow {
                                HStack(spacing: 6) {
                                    Circle().fill(volume.delta == 0 ? Color.clear : volumeColor(volume)).frame(width: 6, height: 6)
                                    Text(volume.shortName).font(.subheadline.monospaced()).foregroundStyle(volume.delta == 0 ? .secondary : .primary)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(volume.friendlyName): \(volume.delta == 0 ? "no change" : signedChange(volume.delta))")
                                Text(volume.delta == 0 ? "—" : signedChange(volume.delta)).font(.subheadline.monospacedDigit()).foregroundStyle(volume.delta == 0 ? .secondary : .primary)
                                    .gridColumnAlignment(.trailing)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            if let text = b.reconciliationText {
                Label(text, systemImage: b.reconciliation.accounted ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("event.reconciliation")
            }
            if !analysis.attribution.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(analysis.attribution, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(analysis.attribution.joined(separator: " "))
                .accessibilityIdentifier("event.attribution")
            }
            if !b.offsettingVolumes.isEmpty {
                Text("Offsetting change: \(b.offsettingVolumes.map { "\($0.friendlyName) \(signedChange($0.delta))" }.joined(separator: ", ")). Volume allocation and free space move in opposite directions.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: C — Supporting evidence

    private var snapshotIntelligence: some View {
        VStack(alignment: .leading, spacing: 12) {
            if event.observation == nil {
                Text("Snapshot and system evidence was not recorded or could not be read for this capacity event. Historical file and volume measurements remain available; no snapshot absence is inferred.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(StorageIntelligence.signals(event)) { signal in
                VStack(alignment: .leading, spacing: 3) {
                    Text(signal.title).font(.subheadline.weight(.medium))
                    Text(signal.confidence.rawValue).font(.caption).foregroundStyle(.secondary)
                    Text(signal.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
            }
            DisclosureGroup("Snapshot inventory and measurement sources") {
                Text(StorageIntelligence.inventoryText(event) ?? "Not recorded")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("event.snapshotInventory")
        }
    }

    @ViewBuilder private var evidence: some View {
        VStack(alignment: .leading, spacing: 12) {
            if analysis.evidence.isEmpty {
                Text(event.diagnostics.isEmpty && event.interval == nil ? "No diagnostic snapshot or folder measurements were recorded for this event." : "No relevant measurements changed.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(analysis.evidence) { EvidenceRowView(row: $0) }
            if analysis.hiddenUnchanged > 0 {
                Text("\(analysis.hiddenUnchanged) unchanged measurement\(analysis.hiddenUnchanged == 1 ? "" : "s") not shown. See Technical details.")
                    .font(.subheadline).foregroundStyle(.tertiary)
            }
            if let collection = analysis.collection {
                VStack(alignment: .leading, spacing: 3) {
                    Label(collection.headline, systemImage: collection.hasProblems ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(collection.lines, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.top, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(([collection.headline] + collection.lines).joined(separator: ". "))
                .accessibilityIdentifier("event.collection")
            }
        }
    }

    // MARK: D — Technical details

    private var technical: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(TechnicalSection.allCases) { section in
                if let content = technicalText(section) {
                    DisclosureGroup(isExpanded: binding(section)) {
                        Text(content).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4).padding(.leading, 2)
                    } label: { Text(section.rawValue).font(.callout) }
                    .accessibilityIdentifier("event.technical.\(section.rawValue)")
                }
            }
            HStack(spacing: 8) {
                Button("Copy Details") { copy(EventPanelText.details(event)) }
                Button("Copy Raw Output") { copy(EventPanelText.raw(event)) }.disabled(event.diagnostics.isEmpty && event.interval == nil && event.observation == nil)
            }.controlSize(.small).padding(.top, 6)
        }
    }
    private func binding(_ section: TechnicalSection) -> Binding<Bool> {
        Binding(get: { expanded.contains(section) }, set: { if $0 { expanded.insert(section) } else { expanded.remove(section) } })
    }

    private func technicalText(_ section: TechnicalSection) -> String? {
        let comparisons = event.comparisons
        func metrics(_ sources: Set<EvidenceSource>) -> String? {
            let rows = comparisons.filter { sources.contains($0.current.source) && $0.current.source != .swap }
            guard !rows.isEmpty else { return nil }
            return rows.map { c in
                var text = "\(c.current.label)\n\(c.current.path)\n\(c.current.kind): \(exactBytes(c.current.bytes))"
                if let a = c.current.allocatedBytes { text += "\nAllocated: \(exactBytes(a))" }
                if let p = c.previous, let t = c.previousTime { text += "\nPrevious: \(exactBytes(p.bytes)) at \(EventPanelText.stamp(t))\nChange: \(exactBytes(c.current.bytes - p.bytes))" }
                text += "\nStatus: \(c.current.complete ? "complete" : c.current.qualifier)"
                return text
            }.joined(separator: "\n\n")
        }
        switch section {
        case .apfs:
            guard let reading = event.measurement else { return nil }
            var lines = ["Container \(reading.container)", "Reading #\(reading.id) · \(EventPanelText.stamp(reading.timestamp))"]
            if let p = event.previousMeasurement { lines.append("Previous reading #\(p.id) · \(EventPanelText.stamp(p.timestamp))") }
            for v in reading.volumes {
                let prior = event.previousMeasurement?.volumes.first { $0.id == v.id }
                lines.append("\n\(v.name) [\(v.roles.joined(separator: ", "))]\nUUID \(v.id)\nAllocated \(exactBytes(v.bytes))" + (prior.map { "\nPrevious \(exactBytes($0.bytes))\nChange \(exactBytes(v.bytes - $0.bytes))" } ?? ""))
            }
            if event.diagnostics.contains(where: { $0.commands.contains { $0.source == .apfs && $0.truncated } }) {
                lines.append("\nThe diagnostic's own APFS property list output was cut off at 4 KB and was not parsed.")
            }
            return lines.joined(separator: "\n")
        case .vm:
            var parts = [String]()
            for c in comparisons where c.current.source == .swap {
                parts.append("\(c.current.label): \(exactBytes(c.current.bytes))" + (c.previous.map { " · previous \(exactBytes($0.bytes)) at \(EventPanelText.stamp(c.previousTime!))" } ?? "") + "\n\(c.current.qualifier)")
            }
            for d in event.diagnostics {
                if !d.vmCounters.isEmpty { parts.append(d.vmCounters.map { "\($0.0): \($0.1)" }.joined(separator: "\n")) }
                for c in d.commands where c.source == .vm { parts.append(c.output) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        case .folders:
            guard let i = event.interval else { return nil }
            var lines = ["Status: \(i.folderStatus) · method \(i.folderMethod) · \(i.measured) measured, \(i.carried) carried forward, \(i.pending) pending, \(i.firstMeasurements) first measurements, \(i.deferred) deferred (unavailable or exhausted)",
                         "Reading #\(i.readingId) compared with #\(i.previousReadingId.map(String.init) ?? "none")" + (i.previousReadingId == event.previousMeasurement?.id ? "" : " (does not match this event's previous reading; not used)")]
            if i.hasCoverageBlock || i.isComprehensive {
                lines.append("Coverage: scope \(i.coverageScope)" + (i.coverageLevel.map { " · level \($0)" } ?? "") + " · \(i.unitsMonitored) areas monitored · \(i.inaccessibleCount) inaccessible · Full Disk Access \(i.fullDiskAccess ?? "unknown")")
                if let reason = i.coverageReason { lines.append(reason) }
                if let gap = i.gapReason { lines.append("File-history gap: \(gap)") }
                if i.movesCount > 0 { lines.append("Moves not counted as growth or reduction: \(i.movesCount)") }
                if i.openDeletedFiles > 0 { lines.append("Open but deleted: \(i.openDeletedFiles) files, \(exactBytes(i.openDeletedBytes)) allocated" + (i.openDeletedHolders.isEmpty ? "" : " (held by \(i.openDeletedHolders.joined(separator: ", ")))")) }
            }
            for c in i.changes { lines.append("\n\(c.path) [\(c.kind)]\nAllocated \(exactBytes(c.beforeAllocated)) → \(exactBytes(c.afterAllocated)) (\(exactBytes(c.allocatedDelta)))\nLogical \(exactBytes(c.beforeLogical)) → \(exactBytes(c.afterLogical))\nFiles \(c.beforeFiles) → \(c.afterFiles)" + (c.afterMeasuredAt.map { "\nMeasured \(EventPanelText.stamp(c.beforeMeasuredAt ?? $0)) → \(EventPanelText.stamp($0))" } ?? "")) }
            if i.changesTotal > i.changes.count { lines.append("\n\(i.changesTotal - i.changes.count) smaller changes not stored") }
            if !i.incomparable.isEmpty { lines.append("\nNot comparable (\(i.incomparableTotal)):\n" + i.incomparable.map { "\($0.path): \($0.reason)" }.joined(separator: "\n")) }
            lines.append("\nRoots:\n" + i.roots.map { "\($0.label == $0.path ? $0.path : "\($0.label) (\($0.path))"): \(exactBytes($0.allocated)) allocated, \($0.children) entries\($0.complete ? "" : " (incomplete)")" }.joined(separator: "\n"))
            return lines.joined(separator: "\n")
        case .activity:
            guard let i = event.interval, i.activityStatus != "unavailable" || i.activityReason != nil else { return nil }
            var lines = ["Status: \(i.activityStatus)" + (i.activityReason.map { " — \($0)" } ?? "")]
            if let since = i.sinceEvent, let until = i.untilEvent { lines.append("FSEvents IDs \(since) → \(until) · volume \(i.device ?? "?")") }
            lines.append("\(i.activityEvents) events · \(i.distinctPaths) distinct paths")
            if !i.gaps.isEmpty { lines.append("Gaps: " + i.gaps.joined(separator: "; ")) }
            for g in i.groups { lines.append("\(g.path): \(g.events) events (created \(g.created), modified \(g.modified), removed \(g.removed), renamed \(g.renamed), cloned \(g.cloned))") }
            if !i.samples.isEmpty { lines.append("\nSample paths:\n" + i.samples.joined(separator: "\n")) }
            lines.append("\nFSEvents records paths only. It does not record which process made a change.")
            return lines.joined(separator: "\n")
        case .processes:
            guard let i = event.interval else { return nil }
            var lines = ["Status: \(i.processStatus) · \(i.processesSampled) same-user processes sampled"]
            for c in i.correlations { lines.append("\n\(c.name) pid \(c.pid)\n\(c.executable)\nFolder \(c.folder): \(c.writableFiles) writable of \(c.openFiles) open\nExample \(c.example)" + (c.bytesWritten.map { "\nDisk writes during interval: \(exactBytes($0)) (all destinations)" } ?? "")) }
            if i.correlations.isEmpty { lines.append(i.processStatus == "not_needed" ? "No folder grew enough to look for processes." : "No process held files open for writing in a grown folder.") }
            lines.append("\nConfirmed process attribution would need Endpoint Security or root tracing, which Storage Monitor does not use.")
            return lines.joined(separator: "\n")
        case .temporary: return metrics([.temporaryFiles])
        case .application: return metrics([.applicationData, .caches, .developer, .other])
        case .collectors:
            let all = event.diagnostics.flatMap(\.collectors)
            guard !all.isEmpty else { return nil }
            return all.map { c in
                var text = "\(c.label) — \(c.status.plain)"
                if c.detail != c.status.plain { text += "\n\(c.detail)" }
                if c.permissionDenied > 0 { text += "\n\(c.permissionDenied) protected location\(c.permissionDenied == 1 ? "" : "s"), e.g.\n" + c.refusedPaths.prefix(3).map { "  \($0)" }.joined(separator: "\n") }
                return text
            }.joined(separator: "\n\n")
        case .raw:
            let commands = event.diagnostics.flatMap(\.commands)
            guard !commands.isEmpty else { return event.diagnostics.isEmpty ? nil : "This snapshot was collected without external commands. Use Copy Raw Output for the stored record." }
            return commands.map { c in [c.name, c.qualifier, c.output.isEmpty ? (c.error == nil ? "No output recorded" : nil) : String(c.condensedOutput.prefix(2_000))].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
        case .provenance:
            return EventPanelText.technical(event)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: Components

func volumeColor(_ volume: VolumeChange) -> Color {
    switch volume.role { case "Data": return .accentColor; case "VM": return .purple; default: return .gray }
}

/// One question in the plain summary: a quiet label above a full-width answer that wraps.
private struct PlainBlock<Content: View>: View {
    let title: String
    let id: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    var prominent = false
    let id: String
    var divider = true
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text(title)
                .font(prominent ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(prominent ? .primary : .secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, prominent ? 14 : 12).padding(.bottom, 8)
            content.padding(.bottom, prominent ? 16 : 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}

private struct CauseRow: View {
    let cause: LikelyCause
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(cause.rank)").font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(.secondary).frame(width: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(cause.title).font(.body.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(signedChange(cause.delta)).font(.body.monospacedDigit().weight(.semibold))
                }
                HStack(spacing: 4) {
                    Image(systemName: cause.evidenceClass.symbol).foregroundStyle(cause.evidenceClass == .confirmed ? Color.green : Color.secondary).imageScale(.small)
                    Text("\(cause.evidenceClass.label) · \(cause.allocationNote)")
                }.font(.subheadline).foregroundStyle(.secondary)
                Text("Responsible application: \(cause.application)").font(.subheadline).foregroundStyle(.secondary)
                ForEach(cause.support, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cause.rank). \(cause.title), \(signedChange(cause.delta)). \(cause.evidenceClass.label), \(cause.allocationNote). Responsible application: \(cause.application). \(cause.support.joined(separator: " "))")
        .help(cause.explanation)
    }
}

private struct CompactCauseRow: View {
    let cause: LikelyCause
    var body: some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {
            VStack(alignment:.leading,spacing:2) {
                Text(cause.title).font(.callout.weight(.semibold))
                Text("\(cause.evidenceClass.label) · \(cause.allocationNote) · app not established")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:8)
            Text(signedChange(cause.delta)).font(.callout.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("\(cause.title), \(signedChange(cause.delta)). \(cause.evidenceClass.label); application not established.")
    }
}

private struct ValueRow: View {
    let label: String
    let value: String
    var emphasized = false
    var body: some View {
        GridRow {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(emphasized ? .callout.monospacedDigit().weight(.semibold) : .callout.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SegmentBar: View {
    let volumes: [VolumeChange]
    var body: some View {
        let total = Double(volumes.reduce(0) { $0 + abs($1.delta) })
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(volumes) { volume in
                    Rectangle().fill(volumeColor(volume).opacity(0.85))
                        .frame(width: max(2, (proxy.size.width - 1.5 * Double(volumes.count - 1)) * Double(abs(volume.delta)) / max(total, 1)))
                }
            }
        }
        .frame(height: 5)
        .clipShape(RoundedRectangle(cornerRadius: 2.5))
        .accessibilityHidden(true)
    }
}

private struct EvidenceRowView: View {
    let row: EvidenceRow
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if row.source.title != row.title { Text(row.source.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
            Text(row.title).font(.callout.weight(.medium))
            Text(row.values).font(.subheadline.monospacedDigit())
            Text(row.change).font(.subheadline.monospacedDigit())
            Label(row.interval, systemImage: row.intervalMatches ? "clock" : "clock.badge.exclamationmark")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(row.reliability).font(.subheadline).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.source.title): \(row.title). \(row.values). Change: \(row.change). \(row.interval). \(row.reliability)")
    }
}
