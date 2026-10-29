import SwiftUI
import Charts

extension EventSeverity {
    var color: Color { switch self { case .normal: return .secondary; case .information: return .blue; case .warning: return .orange; case .critical: return .red } }
}
struct SeverityLabel: View {
    let severity: EventSeverity
    var textColor: Color = .primary
    var body: some View {
        HStack(spacing:4) {
            Image(systemName:severity == .critical ? "exclamationmark.octagon.fill" : (severity == .warning ? "exclamationmark.triangle.fill" : (severity == .information ? "info.circle" : "checkmark.circle"))).foregroundColor(severity.color)
            Text(severity.label).foregroundStyle(textColor)
        }.font(.caption.weight(.medium))
            .accessibilityLabel("Severity: \(severity.label)")
    }
}

struct OverviewView: View {
    let snapshot: HistorySnapshot?
    @ObservedObject var live: LiveCapacityMonitor
    var historyMissing = false
    var historyLoading = false
    var compact = false
    @ViewState private var showStorageStatus = false
    var body: some View {
        if let recorded = snapshot?.latest {
            // Re-evaluates staleness every 15 s without touching the disk.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                content(recorded: recorded, now: context.date)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                liveOnly(now: context.date)
            }
        }
    }
    @ViewBuilder private func liveOnly(now: Date) -> some View {
        let state = live.state
        if let reading = state.reading {
            let severity = EventSeverity.capacity(reading.free)
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("Internal storage", systemImage: "internaldrive").font(.headline)
                    Spacer(minLength: 8)
                    if severity != .normal { SeverityLabel(severity: severity) }
                }
                availableSummary(free: reading.free, reading: reading, freshness: state.freshness(at: now), now: now)
                compactUsage(free: reading.free, total: reading.total, severity: severity)
                InspectorDisclosure("Storage status", isExpanded: $showStorageStatus) {
                    Text(historyMissing ? "No history is recorded yet. Turn on background monitoring in Settings to record capacity at login and every 30 minutes. This live reading is not recorded."
                         : historyLoading ? "Recorded history is still loading. Live capacity is read-only and does not create an event or alert."
                         : "No capacity readings are recorded yet. Live capacity is read-only and does not create an event or alert.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 22).padding(.vertical, compact ? 7 : 13)
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading live capacity…").font(.headline)
                    Text("Recorded history loads independently.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 22).padding(.vertical, 16).accessibilityIdentifier("overview.liveLoading")
        }
    }
    @ViewBuilder private func content(recorded: Measurement, now: Date) -> some View {
        let state = live.state
        let freshness = state.freshness(at: now)
        let reading = state.reading
        let free = reading?.free ?? recorded.free, total = reading?.total ?? recorded.capacity
        let severity = EventSeverity.capacity(free)
        VStack(alignment:.leading,spacing:compact ? 7 : 10) {
            HStack(alignment:.firstTextBaseline) {
                Label("Internal storage",systemImage:"internaldrive").font(.headline)
                Spacer()
                if severity != .normal { SeverityLabel(severity:severity) }
            }
            availableSummary(free:free,reading:reading,freshness:freshness,now:now)
            compactUsage(free:free,total:total,severity:severity)
            InspectorDisclosure("Storage status", isExpanded:$showStorageStatus) {
                VStack(alignment:.leading,spacing:10) {
                    recordedLine(recorded,reading:reading)
                    changes(recorded)
                    if let coverage = snapshot?.filesystemCoverage, coverage.state != "not_initialized" { filesystemCoverageLine(coverage) }
                    if let folders = snapshot?.folderMonitoring, snapshot?.filesystemCoverage?.establishedAt == nil { folderMonitoringLine(folders) }
                }
            }
        }.padding(.horizontal,22).padding(.vertical,compact ? 7 : 13)
    }

    private func availableSummary(free: Int64, reading: LiveCapacityReading?, freshness: LiveFreshness, now: Date) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            VStack(alignment:.leading,spacing:1) {
                Text(reading == nil ? "Available (last recorded)" : "Available now").font(.caption).foregroundStyle(.secondary)
                Text(capacity(free)).font(.system(size:compact ? 28 : 32,weight:.semibold,design:.rounded)).monospacedDigit()
                    .accessibilityIdentifier("overview.available")
            }
            Spacer(minLength:8)
            liveStatus(reading:reading,freshness:freshness,now:now)
        }
    }

    private func compactUsage(free: Int64, total: Int64, severity: EventSeverity) -> some View {
        VStack(spacing:4) {
            ProgressView(value:Double(total-free),total:Double(max(total,1))).tint(severity == .normal ? .accentColor : severity.color)
                .accessibilityLabel("Physical storage used").accessibilityValue("\(Int(Double(total-free)/Double(max(total,1))*100)) percent")
            HStack { Text("\(capacity(total-free)) used"); Spacer(); Text("\(capacity(total)) total") }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func available(free: Int64, reading: LiveCapacityReading?, freshness: LiveFreshness, now: Date) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Text(reading == nil ? "Available (last recorded)" : "Available now").font(.subheadline).foregroundStyle(.secondary)
            Text(capacity(free)).font(.system(size:34,weight:.semibold,design:.rounded)).monospacedDigit()
                .accessibilityLabel("\(reading == nil ? "Last recorded" : "Live") available APFS capacity: \(capacity(free))")
                .accessibilityIdentifier("overview.available")
            liveStatus(reading:reading,freshness:freshness,now:now)
        }
    }
    @ViewBuilder private func liveStatus(reading: LiveCapacityReading?, freshness: LiveFreshness, now: Date) -> some View {
        Group {
            switch freshness {
            case .live:
                Label { Text("Live · updated \(reading!.timestamp.formatted(date:.omitted,time:.standard))") } icon: { Circle().fill(Color.green).frame(width:7,height:7) }
            case .stale:
                Label("Stale · last live reading \(reading!.timestamp.formatted(date:.omitted,time:.shortened))" + (live.state.lastError != nil ? " · refresh failed" : ""),systemImage:"exclamationmark.circle")
                    .foregroundStyle(.orange)
            case .unavailable:
                Label(live.state.lastError ?? (live.isRefreshing ? "Reading live capacity…" : "Live reading unavailable"),systemImage:"circle.dashed")
            }
        }
        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        .help("Live readings come from the filesystem when the viewer opens, becomes active, every minute while visible, and on ⌘R. They are not stored and never trigger alerts.")
        // Explicit label so assistive technologies get the current status, not a cached one.
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(liveStatusText(reading:reading,freshness:freshness))
        .accessibilityIdentifier("overview.liveStatus")
    }
    private func liveStatusText(reading: LiveCapacityReading?, freshness: LiveFreshness) -> String {
        switch freshness {
        case .live: return "Live, updated \(reading!.timestamp.formatted(date:.omitted,time:.standard))"
        case .stale: return "Stale, last live reading \(reading!.timestamp.formatted(date:.omitted,time:.shortened))" + (live.state.lastError != nil ? ", refresh failed" : "")
        case .unavailable: return live.state.lastError ?? "Live reading unavailable"
        }
    }
    private func usage(free: Int64, total: Int64, severity: EventSeverity) -> some View {
        VStack(alignment:.leading,spacing:7) {
            HStack { Text("\(capacity(total-free)) used"); Spacer(); Text("\(capacity(total)) total") }.font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value:Double(total-free),total:Double(max(total,1))).tint(severity == .normal ? .accentColor : severity.color)
                .accessibilityLabel("Physical storage used").accessibilityValue("\(Int(Double(total-free)/Double(max(total,1))*100)) percent")
            Text(severity == .critical ? "Critical pressure · less than 15 GB available" : (severity == .warning ? "Low capacity · less than 25 GB available" : "Capacity within configured thresholds"))
                .font(.subheadline).foregroundStyle(severity == .normal ? Color.secondary : Color.primary)
        }.frame(maxWidth:.infinity)
    }
    private func changes(_ current: Measurement) -> some View {
        VStack(alignment:.leading,spacing:9) {
            baseline("Recorded 1-hour change",seconds:3600,current:current)
            baseline("Recorded 24-hour change",seconds:86400,current:current)
        }.frame(width:190,alignment:.leading)
    }
    // The last background reading, kept visibly separate from the live value.
    private func recordedLine(_ recorded: Measurement, reading: LiveCapacityReading?) -> some View {
        let comparison = ObservationComparison.make(live: reading, recorded: recorded)
        return ViewThatFits(in:.horizontal) {
            HStack(spacing:6) { recordedText(recorded); comparisonText(comparison, live: reading, inline: true); Spacer(minLength:0) }
            VStack(alignment:.leading,spacing:3) { recordedText(recorded); comparisonText(comparison, live: reading, inline: false) }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Last recorded reading \(recorded.timestamp.formatted(date:.omitted,time:.shortened)), \(capacity(recorded.free))" + (comparison.map { ". Live is \(signedChange($0.difference)) versus that reading; an observation comparison, not a recorded event." } ?? ""))
        .accessibilityIdentifier("overview.recorded")
    }
    // Baseline coverage now, separate from any event's interval comparability.
    private func folderMonitoringLine(_ status: FolderMonitoringStatus) -> some View {
        HStack(spacing:5) {
            Image(systemName: ["ready":"folder.badge.checkmark","initializing":"folder.badge.gearshape","partial":"folder.badge.minus","degraded":"exclamationmark.triangle"][status.state] ?? "folder")
                .foregroundStyle(status.state == "degraded" ? Color.orange : Color.secondary)
            Text("Folder monitoring").fontWeight(.medium)
            Text("· \(status.summary)").lineLimit(1).truncationMode(.tail)
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .help(status.detail)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Folder monitoring: \(status.summary)")
        .accessibilityHint(status.detail)
        .accessibilityIdentifier("overview.folderMonitoring")
    }
    private func filesystemCoverageLine(_ status: FilesystemCoverageStatus) -> some View {
        HStack(spacing:5) {
            Image(systemName: ["ready":"internaldrive.badge.checkmark","initializing":"internaldrive","partial":"internaldrive.badge.exclamationmark","degraded":"exclamationmark.triangle"][status.state] ?? "internaldrive")
                .foregroundStyle(status.state == "degraded" ? Color.orange : Color.secondary)
            Text("Filesystem coverage").fontWeight(.medium)
            Text("· \(status.summary)").lineLimit(1).truncationMode(.tail)
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .help(status.detail)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Filesystem coverage: \(status.summary)")
        .accessibilityHint(status.detail)
        .accessibilityIdentifier("overview.filesystemCoverage")
    }
    private func recordedText(_ recorded: Measurement) -> some View {
        HStack(spacing:5) {
            Image(systemName:Date().timeIntervalSince(recorded.timestamp)>4500 ? "clock.badge.exclamationmark" : "clock")
            Text("Last recorded \(recorded.timestamp.formatted(date:.abbreviated,time:.shortened)): \(capacity(recorded.free)) available")
                .help("Background monitor reading \(recorded.timestamp.formatted(date:.complete,time:.complete)). History, events and the chart use recorded readings only.")
        }.lineLimit(1)
    }
    @ViewBuilder private func comparisonText(_ comparison: ObservationComparison?, live: LiveCapacityReading?, inline: Bool) -> some View {
        if let comparison {
            Text("\(inline ? "· " : "")\(comparison.difference == 0 ? "No change since then" : "\(changeMagnitude(comparison.difference)) \(comparison.difference < 0 ? "less" : "more") available now")")
                .lineLimit(inline ? 1 : 2).fixedSize(horizontal: inline, vertical: !inline)
                .help("Live \(exactBytes(comparison.live.free)) at \(comparison.live.timestamp.formatted(date:.omitted,time:.standard)) minus recorded \(exactBytes(comparison.recorded.free)). An observation comparison: not stored, not a recorded event, not an alert.")
        } else if live != nil {
            Text("\(inline ? "· " : "")Live and recorded readings are from different containers; not compared").lineLimit(inline ? 1 : 2).fixedSize(horizontal: inline, vertical: !inline)
        }
    }
    @ViewBuilder private func baseline(_ title: String,seconds: Double,current: Measurement) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                if let prior = snapshot?.baseline(seconds:seconds) {
                    Text(signedChange(current.free-prior.free)).font(.callout.weight(.medium)).monospacedDigit()
                    Text("Over \(duration(current.timestamp.timeIntervalSince(prior.timestamp)))").font(.caption).foregroundStyle(.secondary)
                        .help("Compared with \(prior.timestamp.formatted(date:.complete,time:.complete)), the nearest same-container reading at or before the requested baseline. No interpolation.")
                } else { Text("Not enough history").font(.callout).foregroundStyle(.secondary).help("No same-container reading at or before \(current.timestamp.addingTimeInterval(-seconds).formatted(date:.abbreviated,time:.standard)).") }
            }
        }
    }
    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds/60)
        if minutes >= 1440 { return "\(minutes/1440)d \((minutes%1440)/60)h" }
        return "\(minutes/60)h \(minutes%60)m"
    }
}

private struct PlotReading: Identifiable {
    var id: Int64 { measurement.id }
    let measurement: Measurement
    let segment: Int
    var date: Date { measurement.timestamp }
    var freeGB: Double { Double(measurement.free)/Double(decimalGB) }
}
private struct MeaningfulChartEvent: Identifiable {
    var id: String { event.id }
    let event: StorageEvent
    let point: PlotReading
}
struct CapacityChart: View {
    let readings: [Measurement]
    let events: [StorageEvent]
    let selectedEventID: String?
    @Binding var range: EventTimeFilter
    let compact: Bool
    let selectEvent: (String) -> Void
    @ViewState private var hovered: PlotReading?
    @ViewState private var selectionMessage: String?
    private var points: [PlotReading] {
        let cutoff = Date().addingTimeInterval(-(range.seconds ?? 86400))
        var segment = 0, previous: Measurement?
        return readings.filter { $0.timestamp >= cutoff }.map { reading in
            if let previous, previous.container != reading.container || reading.timestamp.timeIntervalSince(previous.timestamp)>4500 { segment += 1 }
            previous = reading
            return PlotReading(measurement:reading,segment:segment)
        }
    }
    private var meaningfulEvents: [MeaningfulChartEvent] {
        events.compactMap { event in
            guard let delta = event.delta, abs(Double(delta)) >= Double(decimalGB), let measurement = event.measurement,
                  let point = points.first(where: { $0.measurement.id == measurement.id && $0.measurement.container == measurement.container && $0.measurement.timestamp == measurement.timestamp }) else { return nil }
            return MeaningfulChartEvent(event:event,point:point)
        }
    }
    private var selectedPoint: PlotReading? {
        guard let selectedEventID, let event = events.first(where: { $0.id == selectedEventID }), let measurement = event.measurement else { return nil }
        return points.first { $0.measurement.id == measurement.id && $0.measurement.container == measurement.container && $0.measurement.timestamp == measurement.timestamp }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("Recorded available capacity").font(.subheadline.weight(.semibold)).fixedSize()
                Text("\(points.count) points").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                Spacer()
                Picker("Chart time range",selection:$range) { ForEach(EventTimeFilter.allCases.filter { $0 != .custom },id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width:145).accessibilityIdentifier("chart.range")
            }
            HStack(spacing:10) {
                Text("Orange/red: 25/15 GB thresholds")
                Text("Colored points: loss or recovery ≥ 1 GB")
            }.font(.caption).foregroundStyle(.secondary)
            if points.isEmpty { Text("No recorded capacity measurements in this chart range.").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:80) }
            else {
                Chart {
                    RuleMark(y:.value("Warning",25)).foregroundStyle(.orange.opacity(0.6)).lineStyle(StrokeStyle(lineWidth:1,dash:[4,4]))
                    RuleMark(y:.value("Critical",15)).foregroundStyle(.red.opacity(0.55)).lineStyle(StrokeStyle(lineWidth:1,dash:[3,4]))
                    ForEach(points) { point in
                        LineMark(x:.value("Time",point.date),y:.value("Free GB",point.freeGB),series:.value("Recorded segment",point.segment)).foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth:1.5))
                        PointMark(x:.value("Time",point.date),y:.value("Free GB",point.freeGB)).foregroundStyle(Color.accentColor).symbolSize(14)
                            .accessibilityLabel("\(point.date.formatted()): \(capacity(point.measurement.free)) available")
                    }
                    ForEach(meaningfulEvents) { item in
                        PointMark(x:.value("Event time",item.point.date),y:.value("Available",item.point.freeGB))
                            .foregroundStyle((item.event.delta ?? 0) < 0 ? Color.orange : Color.green)
                            .symbolSize(42)
                            .accessibilityLabel("\(item.event.category), \(item.event.delta.map(signedChange) ?? "")")
                    }
                    if let hovered, points.contains(where: { $0.id == hovered.id }) {
                        RuleMark(x:.value("Selected reading",hovered.date)).foregroundStyle(.secondary.opacity(0.5))
                        PointMark(x:.value("Selected reading",hovered.date),y:.value("Available",hovered.freeGB)).foregroundStyle(Color.accentColor).symbolSize(55)
                            .annotation(position:.top,alignment:.leading) { Text("\(hovered.date.formatted(date:.abbreviated,time:.standard)) · \(capacity(hovered.measurement.free))").font(.caption2).padding(5).background(.regularMaterial,in:RoundedRectangle(cornerRadius:5)) }
                    }
                    if let selectedPoint {
                        PointMark(x:.value("Selected event",selectedPoint.date),y:.value("Available",selectedPoint.freeGB))
                            .foregroundStyle(Color.accentColor).symbolSize(90)
                            .annotation(position:.top,alignment:.trailing) {
                                if hovered == nil, let delta = events.first(where: { $0.id == selectedEventID })?.delta {
                                    Text("\(selectedPoint.date.formatted(date:.abbreviated,time:.shortened)) · \(signedChange(delta)) · \(capacity(selectedPoint.measurement.free))")
                                        .font(.caption2.monospacedDigit()).padding(5).background(.regularMaterial,in:RoundedRectangle(cornerRadius:5))
                                }
                            }
                    }
                }
                .chartYScale(domain:0...max(30,(points.map(\.freeGB).max() ?? 25)+3))
                .chartYAxis { AxisMarks(position:.trailing,values:.automatic(desiredCount:4)) { value in AxisGridLine(stroke:StrokeStyle(lineWidth:0.5)); AxisValueLabel { if let gb = value.as(Double.self) { Text("\(gb,format:.number.precision(.fractionLength(0))) GB").font(.caption) } } } }
                .chartXAxis { AxisMarks(values:.automatic(desiredCount:5)) { _ in AxisGridLine(stroke:StrokeStyle(lineWidth:0.5)); AxisTick(); AxisValueLabel().font(.caption) } }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { return }
                                let origin = geometry[frame].origin, local = CGPoint(x:location.x-origin.x,y:location.y-origin.y)
                                hovered = points.compactMap { point -> (PlotReading,CGFloat)? in
                                    guard let x = proxy.position(forX:point.date), let y = proxy.position(forY:point.freeGB) else { return nil }
                                    return (point,hypot(x-local.x,y-local.y))
                                }.min { $0.1 < $1.1 }.flatMap { $0.1 <= 14 ? $0.0 : nil }
                            case .ended: hovered = nil
                            }
                        }
                        .gesture(SpatialTapGesture().onEnded { value in
                            guard let frame = proxy.plotFrame else { return }
                            let origin = geometry[frame].origin, local = CGPoint(x:value.location.x-origin.x,y:value.location.y-origin.y)
                            guard let nearest = points.compactMap({ point -> (PlotReading,CGFloat)? in
                                guard let x = proxy.position(forX:point.date), let y = proxy.position(forY:point.freeGB) else { return nil }
                                return (point,hypot(x-local.x,y-local.y))
                            }).min(by:{ $0.1 < $1.1 }), nearest.1 <= 14 else { selectionMessage = nil; return }
                            if let eventID = StorageChartSelection.eventID(for:nearest.0.measurement,events:events) {
                                selectionMessage = nil; selectEvent(eventID)
                            } else {
                                selectionMessage = "That reading has no unique event in the current filters. Use the event table or adjust Filters."
                            }
                        })
                    }
                }.frame(height:compact ? 96 : 160)
                .accessibilityIdentifier("capacity.chart")
                .help("Actual recorded points. Lines connect adjacent readings only; gaps over 75 minutes and container changes are not joined. Click close to a point to open its unique visible event.")
            }
            if let selectionMessage { Text(selectionMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("chart.selectionMessage") }
        }.padding(.horizontal,22).padding(.vertical,12)
    }
}
