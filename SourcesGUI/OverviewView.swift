import SwiftUI
import Charts
import AppKit

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
    var target: StorageTargetContext? = nil
    private var driveTitle: String { target?.uuid == nil ? "Internal storage" : target?.title ?? "External storage" }
    @ViewState private var showStorageStatus = false
    var monitoringHealth: ((Date) -> MonitoringHealthPresentation)? = nil
    var body: some View {
        // Both sections use the same freshness policy and visible clock; no disk read on an age tick.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let presentation = CapacityPresentation(state: live.state, recorded: snapshot?.latest, now: context.date)
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                Label(driveTitle, systemImage: target?.uuid == nil ? "internaldrive" : "externaldrive").font(.headline)
                Text("Physical volume capacity · indexed file totals are separate; inaccessible folders limit coverage.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.title).font(.caption).foregroundStyle(.secondary)
                        if let free = presentation.free {
                            Text(capacity(free)).font(.system(size: compact ? 28 : 32, weight: .semibold, design: .rounded)).monospacedDigit().accessibilityIdentifier("overview.available")
                        } else { Text("No reading").font(.title2) }
                    }
                    Spacer(minLength: 8)
                    capacityStatus(presentation)
                }
                if let free = presentation.free, let total = presentation.total {
                    compactUsage(free: free, total: total, severity: EventSeverity.capacity(free))
                }
                if target?.uuid == nil, let health = monitoringHealth?(context.date) {
                    Text(health.title).font(.callout.weight(.medium)).help(health.detail + " " + health.jobDetails.joined(separator: ". ")).accessibilityIdentifier("overview.monitoringHealth")
                }
                InspectorDisclosure("Storage status", isExpanded: $showStorageStatus) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(presentation.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if target?.uuid == nil, let health = monitoringHealth?(context.date) { Text(health.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        if let recorded = snapshot?.latest {
                            recordedLine(recorded, reading: presentation.isCurrent ? live.state.reading : nil)
                            changes(recorded)
                            if let coverage = snapshot?.filesystemCoverage, coverage.state != "not_initialized" { filesystemCoverageLine(coverage) }
                            if let folders = snapshot?.folderMonitoring, snapshot?.filesystemCoverage?.establishedAt == nil { folderMonitoringLine(folders) }
                        } else {
                            Text(target?.uuid != nil ? "No capacity history is recorded for this drive yet. The background monitor records chosen, connected drives at login, on mount and every 30 minutes." : historyMissing ? "No history is recorded yet. Enable Background Monitoring in Settings to record capacity at login and every 30 minutes. This live reading is not recorded." : historyLoading ? "Recorded history is still loading." : "No capacity readings are recorded yet.")
                                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }.padding(.horizontal, 22).padding(.vertical, compact ? 7 : 13)
        }
    }
    private func capacityStatus(_ presentation: CapacityPresentation) -> some View {
        HStack(spacing: 6) {
            if presentation.status == .refreshing { ProgressView().controlSize(.small) }
            Text(presentation.statusText).fixedSize(horizontal: false, vertical: true)
        }.font(.subheadline).foregroundStyle(presentation.status == .failed || presentation.status == .stale ? Color.primary : Color.secondary)
            .help(presentation.detail).accessibilityElement(children: .combine).accessibilityIdentifier("overview.liveStatus")
    }
    private func compactUsage(free: Int64, total: Int64, severity: EventSeverity) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(total-free), total: Double(max(total,1))).tint(severity == .normal ? .accentColor : severity.color)
                .accessibilityLabel("Physical storage used").accessibilityValue("\(Int(Double(total-free)/Double(max(total,1))*100)) percent")
            HStack { Text("\(capacity(total-free)) used"); Spacer(); Text("\(capacity(total)) total") }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
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
    /// Geometry regression seams (tests/CapacityChartGeometryTests.swift): start hovered on the reading at this time, and
    /// report the plot frame and point positions after each layout. Nil in the app.
    var inspectHoverAt: Date? = nil
    var onPlotLayout: ((CGRect,[Date:CGPoint]) -> Void)? = nil
    /// Hover seam: the hovered reading after each pointer move, and the drawn hover callout's frame in the overlay.
    var onHoverLayout: ((Date?,CGRect?) -> Void)? = nil
    @ViewState private var hovered: PlotReading?
    /// Time, available space, and the change from the previous joined reading (none at a segment's start).
    /// The pointer, in the overlay's coordinates (nil: it left the chart), hovers the nearest drawn reading in reach.
    private func pointerMoved(to location: CGPoint?,proxy: ChartProxy,plot: CGRect) {
        let next = location.flatMap { location in
            CapacityChartHover.nearest(location,among:points.compactMap { point -> (PlotReading,CGPoint)? in
                guard let x = proxy.position(forX:point.date), let y = proxy.position(forY:point.freeGB) else { return nil }
                return (point,CGPoint(x:plot.minX+x,y:plot.minY+y))
            })
        }
        if next?.id != hovered?.id { hovered = next }   // only invalidate when the hovered reading changes
        onHoverLayout?(hovered?.date,nil)
    }
    private func hoverText(_ reading: PlotReading) -> String {
        let shown = points
        let previous = shown.firstIndex { $0.id == reading.id }.flatMap { i in i > 0 && shown[i-1].segment == reading.segment ? shown[i-1].measurement.free : nil }
        return CapacityChartHover.describe(date:reading.date,free:reading.measurement.free,previousFree:previous)
    }
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
                    // No `.annotation` here: an annotation near a plot edge makes Charts pad the scale to fit it, which moved
                    // every point (and the hovered one out from under the pointer) — the hover/unhover flicker. The labels
                    // are drawn in the overlay below, which cannot change the chart's layout.
                    if let hovered, points.contains(where: { $0.id == hovered.id }) {
                        RuleMark(x:.value("Selected reading",hovered.date)).foregroundStyle(.secondary.opacity(0.5))
                        PointMark(x:.value("Selected reading",hovered.date),y:.value("Available",hovered.freeGB)).foregroundStyle(Color.accentColor).symbolSize(55)
                    }
                    if let selectedPoint {
                        PointMark(x:.value("Selected event",selectedPoint.date),y:.value("Available",selectedPoint.freeGB))
                            .foregroundStyle(Color.accentColor).symbolSize(90)
                    }
                }
                .chartYScale(domain:0...max(30,(points.map(\.freeGB).max() ?? 25)+3))
                .chartYAxis { AxisMarks(position:.trailing,values:.automatic(desiredCount:4)) { value in AxisGridLine(stroke:StrokeStyle(lineWidth:0.5)); AxisValueLabel { if let gb = value.as(Double.self) { Text("\(gb,format:.number.precision(.fractionLength(0))) GB").font(.caption) } } } }
                .chartXAxis { AxisMarks(values:.automatic(desiredCount:5)) { _ in AxisGridLine(stroke:StrokeStyle(lineWidth:0.5)); AxisTick(); AxisValueLabel().font(.caption) } }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                        Rectangle().fill(.clear).contentShape(Rectangle())
                        .onAppear { if let inspectHoverAt { hovered = points.first { $0.date == inspectHoverAt } } }
                        .onChange(of:"\(plot)|\(hovered?.id ?? 0)|\(proxy.position(forX:points[0].date) ?? 0),\(proxy.position(forY:points[0].freeGB) ?? 0)",initial:true) { _, _ in
                            guard let onPlotLayout else { return }
                            var positions: [Date:CGPoint] = [:]
                            for point in points { if let x = proxy.position(forX:point.date), let y = proxy.position(forY:point.freeGB) { positions[point.date] = CGPoint(x:plot.minX+x,y:plot.minY+y) } }
                            onPlotLayout(plot,positions)
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
                        // Pointer moves arrive through an AppKit tracking area that never takes clicks (the tap above and
                        // the tooltip still receive them). The pointer is in this overlay's coordinates, as are the points.
                        ChartPointerLayer { pointerMoved(to:$0,proxy:proxy,plot:plot) }.allowsHitTesting(false)
                        if let hovered, let x = proxy.position(forX:hovered.date), let y = proxy.position(forY:hovered.freeGB) {
                            ChartCallout(text:hoverText(hovered),anchor:CGPoint(x:plot.minX+x,y:plot.minY+y),bounds:geometry.size) { onHoverLayout?(hovered.date,$0) }
                        } else if let selectedPoint, let delta = events.first(where: { $0.id == selectedEventID })?.delta,
                                  let x = proxy.position(forX:selectedPoint.date), let y = proxy.position(forY:selectedPoint.freeGB) {
                            ChartCallout(text:"\(selectedPoint.date.formatted(date:.abbreviated,time:.shortened)) · \(signedChange(delta)) · \(capacity(selectedPoint.measurement.free))",anchor:CGPoint(x:plot.minX+x,y:plot.minY+y),bounds:geometry.size)
                        }
                    }
                    .coordinateSpace(name:ChartCallout.space)
                }.frame(height:compact ? 96 : 160)
                .accessibilityIdentifier("capacity.chart")
                .help("Actual recorded points. Lines connect adjacent readings only; gaps over 75 minutes and container changes are not joined. Click close to a point to open its unique visible event.")
            }
            if let selectionMessage { Text(selectionMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("chart.selectionMessage") }
        }.padding(.horizontal,22).padding(.vertical,12)
    }
}
/// A chart label drawn in the overlay, beside its point and always inside the chart. It extends away from the nearer
/// horizontal edge and sits above the point unless that would leave the top, so it never needs measuring and never
/// feeds back into the chart's layout or the hover hit test.
private struct ChartCallout: View {
    static let space = "capacityChart.overlay"
    let text: String
    let anchor: CGPoint
    let bounds: CGSize
    var drawn: ((CGRect) -> Void)? = nil
    var body: some View {
        let leftward = anchor.x > bounds.width/2, above = anchor.y > 30
        Text(text).font(.caption2.monospacedDigit()).lineLimit(1).padding(5)
            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:5))
            .background(GeometryReader { g in
                let frame = g.frame(in:.named(Self.space))
                Color.clear.onChange(of:"\(frame)",initial:true) { _, _ in drawn?(frame) }
            })
            .frame(width:max(0,leftward ? min(bounds.width,anchor.x+6) : bounds.width-max(0,anchor.x-6)),height:max(0,above ? anchor.y-6 : bounds.height-anchor.y-6),
                   alignment:Alignment(horizontal:leftward ? .trailing : .leading,vertical:above ? .bottom : .top))
            .offset(x:leftward ? 0 : max(0,anchor.x-6),y:above ? 0 : anchor.y+6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
/// Which reading a pointer is on: the nearest drawn point within `radius`, or none over empty plot.
enum CapacityChartHover {
    static let radius: CGFloat = 14
    static func nearest<Reading>(_ location: CGPoint,among positions: [(Reading,CGPoint)],radius: CGFloat = radius) -> Reading? {
        positions.map { ($0.0,hypot($0.1.x-location.x,$0.1.y-location.y)) }.min { $0.1 < $1.1 }.flatMap { $0.1 <= radius ? $0.0 : nil }
    }
    /// The hover callout: time, available space, and the change from the previous joined reading when there is one.
    static func describe(date: Date,free: Int64,previousFree: Int64?) -> String {
        var parts = [date.formatted(date:.abbreviated,time:.standard),"\(capacity(free)) available"]
        if let previousFree { parts.append("\(signedChange(free-previousFree)) since previous reading") }
        return parts.joined(separator:" · ")
    }
}
/// The chart's pointer tracking. `moved` receives the pointer in this view's (top-left) coordinates, nil on leaving.
/// It never takes clicks: hit testing passes through to the chart below.
struct ChartPointerLayer: NSViewRepresentable {
    let moved: (CGPoint?) -> Void
    func makeNSView(context: Context) -> ChartPointerView { let view = ChartPointerView(); view.moved = moved; return view }
    func updateNSView(_ view: ChartPointerView, context: Context) { view.moved = moved }
}
final class ChartPointerView: NSView {
    var moved: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInActiveApp,.inVisibleRect],owner:self)
        addTrackingArea(area); tracking = area
    }
    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow,from:nil) }
    override func mouseEntered(with event: NSEvent) { moved?(point(event)) }
    override func mouseMoved(with event: NSEvent) { moved?(point(event)) }
    override func mouseExited(with event: NSEvent) { moved?(nil) }
}
