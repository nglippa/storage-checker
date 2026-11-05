import SwiftUI
import AppKit

struct HistoryView: View {
    @ObservedObject var store: ViewerStore
    @ViewState private var order = [KeyPathComparator<StorageEvent>]()
    @FocusState private var searchFocused: Bool
    @ViewState private var showFilters = false
    @FocusState private var tableFocused: Bool
    @ViewState private var summaryHeight: CGFloat = 0
    /// The table's AppKit side: keeps keyboard focus with the list through inspector rebuilds and scrolls rows into view.
    @ViewState private var tableBridge = EventTableBridge.Handle()
    @Environment(\.colorScheme) private var colorScheme
    /// Height kept for the event list (filters, header, at least six rows, footer) before the summary above it scrolls.
    /// At the 1000 × 700 minimum (about 648 pt of content) the compact summary (379 pt) then fits without clipping the chart.
    static let eventListReserve: CGFloat = 254
    private var events: [StorageEvent] { order.isEmpty ? store.visibleEvents : store.visibleEvents.sorted(using:order) }
    var body: some View {
        GeometryReader { geometry in
        let compact = geometry.size.width < 1100 || geometry.size.height < 740
        VStack(spacing:0) {
            if store.configuration.isQA {
                Label("QA history · \(URL(fileURLWithPath:store.configuration.database).lastPathComponent)",systemImage:"testtube.2").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,22).padding(.vertical,6).background(Color.yellow.opacity(0.08))
            }
            // The summary keeps its natural (measured) height when there is room. In a short window it scrolls on its
            // own, so the event list below always keeps at least `eventListReserve`.
            ScrollView {
                summary(compact: compact).background(GeometryReader { proxy in Color.clear.preference(key:SummaryHeight.self,value:proxy.size.height) })
            }
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(SummaryHeight.self) { summaryHeight = $0 }
            .frame(height:summaryHeight > 0 ? min(summaryHeight, max(180, geometry.size.height - Self.eventListReserve)) : nil)
            .accessibilityIdentifier("history.summaryScroll")
            Divider()
            eventList
        }
        }
        .textSelection(.enabled)
        .background(Color(nsColor:.windowBackgroundColor))
        .inspector(isPresented:$store.showInspector) {
            EventDetailView(event:store.selectedEvent)
                .inspectorColumnWidth(min:300,ideal:360,max:480)
                .environment(\.colorScheme, colorScheme)
        }
        .toolbar {
            ToolbarItem(placement:.navigation) { Label("Storage Monitor",systemImage:"internaldrive").font(.headline) }
            ToolbarItemGroup(placement:.primaryAction) {
                Button { store.refreshAll() } label: { Label("Reload History & Capacity", systemImage:"arrow.clockwise").labelStyle(.titleAndIcon) }.help("Refresh live capacity and recorded history (⌘R). Does not record a reading, run diagnostics, or send alerts.").accessibilityLabel("Reload history and check disk capacity").accessibilityIdentifier("history.refresh")
                Button { store.showInspector.toggle() } label: { Image(systemName:"sidebar.right") }.help("Show Event Details (⌥⌘I)").accessibilityLabel("Show Event Details").accessibilityIdentifier("history.inspector")
            }
        }
        .onChange(of:store.filters) { _,_ in order = [] }
        .onChange(of:store.selection) { _,value in
            guard let value else { return }
            store.showInspector = true
            // A selection made elsewhere (the chart, Latest change) brings its row into view; a visible row stays put.
            if let row = events.firstIndex(where: { $0.id == value }) { DispatchQueue.main.async { tableBridge.scrollToRow(row) } }
        }
        .onExitCommand { store.showInspector = false }
        .onAppear { PerformanceTrace.mark("monitoring.appear") }
        .background(Button("Focus search") { searchFocused = true }.keyboardShortcut("f").hidden())
    }

    /// Current storage, the latest notable change and the chart.
    @ViewBuilder private func summary(compact: Bool) -> some View {
        VStack(spacing:0) {
            OverviewView(snapshot:store.snapshot,live:store.live,historyMissing:store.historyMissing,historyLoading:store.isLoading && store.snapshot == nil,compact:compact,monitoringHealth:store.monitoringHealth)
            Divider()
            if let error = store.error {
                HStack(alignment:.top) {
                    Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange)
                    VStack(alignment:.leading,spacing:4) { Text(store.historyMissing ? "Background monitoring is not on" : (store.snapshot == nil ? "History unavailable" : "Could not refresh history")).font(.headline); Text(error).font(.caption).textSelection(.enabled) }
                    Spacer()
                    if store.historyMissing { SettingsLink { Text("Open Settings…") }.accessibilityIdentifier("history.openSettings") }
                    Button("Retry") { store.refresh() }.accessibilityIdentifier("history.retry")
                }.padding(16).background(Color.orange.opacity(0.07)).accessibilityIdentifier("history.error")
                Divider()
            }
            if let event = LatestChange.pick(store.snapshot?.events ?? []) {
                LatestChange(event: event, compact: compact) { store.selection = event.id; store.showInspector = true }
                Divider()
            }
            CapacityChart(readings:store.snapshot?.measurements ?? [],events:store.visibleEvents,selectedEventID:store.selection,range:$store.chartRange,compact:compact) { eventID in
                store.selection = eventID; store.showInspector = true
                // The chart is not a keyboard control: the list takes focus, so its row shows as selected and the arrow
                // keys continue from the chosen event.
                tableBridge.focusTable()
            }
        }
    }

    /// Filters, the recorded events and the count.
    @ViewBuilder private var eventList: some View {
        VStack(spacing:0) {
            filterBar
            Divider()
            if let validation = store.filters.validation { Label(validation,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.primary).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,22).padding(.vertical,8).accessibilityIdentifier("filters.validation") }
            ZStack {
                Table(events,selection:$store.selection,sortOrder:$order) {
                    TableColumn("Time",value:\.timestamp) { event in
                        Text(event.timestamp,format:.dateTime.month(.abbreviated).day().hour().minute()).monospacedDigit().font(.callout)
                            .help(event.timestamp.formatted(date:.complete,time:.complete))
                    }.width(min:105,ideal:125,max:155)
                    TableColumn("Change",value:\.changeOrder) { (event: StorageEvent) in ChangeCell(event:event) }.width(min:90,ideal:105,max:130)
                    TableColumn("Event") { event in EventCell(event:event) }.width(min:190,ideal:340,max:.infinity)
                    TableColumn("Available",value:\.freeOrder) { event in Text(event.currentFree.map { capacity($0) } ?? "—").monospacedDigit().frame(maxWidth:.infinity,alignment:.trailing) }.width(min:95,ideal:115,max:145)
                }
                .textSelection(.disabled)
                .tableStyle(.inset(alternatesRowBackgrounds:false))
                .accessibilityIdentifier("history.table")
                .focused($tableFocused)
                .background(EventTableBridge(handle:tableBridge))
                .onCopyCommand {
                    guard let event = store.selectedEvent else { return [] }
                    return [NSItemProvider(object:EventPanelText.summary(event) as NSString)]
                }
                .contextMenu(forSelectionType:String.self) { ids in
                    if let id = ids.first, let event = events.first(where: { $0.id == id }) {
                        Button("Copy Event") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(EventPanelText.summary(event),forType:.string)
                        }
                        Button("Show Event Details") { store.selection = id; store.showInspector = true }
                    }
                }
                if events.isEmpty {
                    if store.isLoading && store.snapshot == nil { ProgressView("Loading local history…").controlSize(.small) }
                    else if let empty = EventListEmptyState.make(filters:store.filters,events:store.snapshot?.events ?? []) { filteredEmpty(empty) }
                    else {
                        VStack(spacing:10) {
                            Image(systemName:store.error != nil ? "externaldrive.badge.questionmark" : "line.3.horizontal.decrease.circle").font(.largeTitle).foregroundStyle(.secondary)
                            Text(store.historyMissing ? "No monitoring history yet" : store.error != nil && store.snapshot == nil ? "Could not load history" : "No recorded events yet").font(.headline)
                            Text(store.historyMissing ? "Turn on background monitoring in Settings → Background Monitoring. The first reading is recorded right away." : store.error != nil && store.snapshot == nil ? "Retry after checking that the monitor's database is available." : "The independent background monitor is configured to record capacity at login and every half hour.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(25).frame(maxWidth:460).accessibilityIdentifier("history.empty")
                    }
                }
            }.frame(minHeight:72,maxHeight:.infinity)   // the scrollable table gives way first, so the view fits the minimum window
            HStack {
                Text("\(events.count) of \(store.snapshot?.events.count ?? 0) events").accessibilityIdentifier("history.resultCount")
                if let selection = store.selectedEvent { Text("· \(selection.category)").lineLimit(1) }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                Text("View only · the background monitor records history on its own")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,22).padding(.vertical,8)
        }
    }
    /// Recorded events exist but none are shown: say why, and offer only steps that reveal events.
    private func filteredEmpty(_ empty: EventListEmptyState) -> some View {
        // In a short list (minimum window) the icon gives way first; the explanation always wraps in full.
        ViewThatFits(in:.vertical) {
            filteredEmptyContent(empty,icon:true).padding(25)
            filteredEmptyContent(empty,icon:false).padding(.horizontal,25).padding(.vertical,10)
        }.frame(maxWidth:460).accessibilityIdentifier("history.empty")
    }
    private func filteredEmptyContent(_ empty: EventListEmptyState, icon: Bool) -> some View {
        VStack(spacing:icon ? 10 : 6) {
            if icon { Image(systemName:"line.3.horizontal.decrease.circle").font(.largeTitle).foregroundStyle(.secondary) }
            Text(empty.title).font(.headline)
            Text(empty.message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
            HStack {
                ForEach(Array(empty.actions.enumerated()),id:\.offset) { _,action in
                    switch action {
                    case .clearFilters: Button("Clear Filters") { store.clearFilters(); order = [] }.accessibilityIdentifier("history.empty.clear")
                    case .widen(let time): Button("Show \(time.rawValue)") { store.filters.time = time }.accessibilityIdentifier("history.empty.widen")
                    case .range(let start,let end): Button("Show All Recorded Events") { store.filters.start = start; store.filters.end = end; store.filters.time = .custom }.accessibilityIdentifier("history.empty.range")
                    }
                }
            }
        }
    }
    // One quiet row: the filters live in a popover, summarised beside their button.
    private var filterBar: some View {
        VStack(alignment:.leading,spacing:9) {
            ViewThatFits(in:.horizontal) {
                HStack(spacing:10) { filterTitle; filterButton; Spacer(minLength:8); searchField; sortPicker; clearButton }
                VStack(alignment:.leading,spacing:8) {
                    HStack(spacing:10) { filterTitle; Spacer(minLength:8); searchField }
                    HStack(spacing:10) { filterButton; Spacer(minLength:8); sortPicker; clearButton }
                }
            }
            if store.filters.time == .custom || store.filters.size == .custom { customControls }
        }.padding(.horizontal,22).padding(.vertical,10)
    }
    private var filterTitle: some View { Text("All recorded changes").font(.headline).fixedSize() }
    private var filterButton: some View {
        Button { showFilters.toggle() } label: { Label("Filters\(store.filters.activeCount == 0 ? "" : " (\(store.filters.activeCount))")",systemImage:"line.3.horizontal.decrease") }.fixedSize().accessibilityIdentifier("filter.expand")
                .popover(isPresented:$showFilters,arrowEdge:.bottom) { Form { primaryFilters; customControls }.formStyle(.grouped).frame(width:400).padding(8) }
                .help(filterSummary)
    }
    private var searchField: some View {
        HStack(spacing:6) {
            Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
            TextField("Search recorded events",text:$store.filters.search).textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("filter.search").accessibilityLabel("Search descriptions, categories, and diagnostic evidence")
            if !store.filters.search.isEmpty { Button { store.filters.search = "" } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
        }.padding(.horizontal,8).padding(.vertical,5).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:6)).frame(minWidth:150,maxWidth:240)
    }
    private var clearButton: some View {
        Button("Clear Filters") { store.clearFilters(); order = [] }.disabled(!store.hasActiveFilters).fixedSize().accessibilityIdentifier("filter.clear")
    }
    @ViewBuilder private var primaryFilters: some View {
        Picker("Type",selection:$store.filters.type) { ForEach(EventTypeFilter.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.frame(minWidth:155).accessibilityIdentifier("filter.type")
        Picker("Time",selection:$store.filters.time) { ForEach(EventTimeFilter.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.frame(minWidth:170).accessibilityIdentifier("filter.time")
        Picker("Size",selection:$store.filters.size) { ForEach(EventSizeFilter.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.frame(minWidth:195).accessibilityIdentifier("filter.size")
        Picker("Severity",selection:$store.filters.severity) { Text("All Severities").tag(-1); ForEach(EventSeverity.allCases,id:\.rawValue) { Text($0.label).tag($0.rawValue) } }.frame(minWidth:160).accessibilityIdentifier("filter.severity")
    }
    private var sortPicker: some View {
        Picker("Sort",selection:Binding(get:{ order.isEmpty ? store.filters.sort.rawValue : "__columns" },set:{ value in if let sort = EventSort(rawValue:value) { store.filters.sort = sort; order = [] } })) {
            ForEach(EventSort.allCases,id:\.self) { Text($0.rawValue).tag($0.rawValue) }
            if !order.isEmpty { Text("Table Column Order").tag("__columns") }
        }.labelsHidden().frame(minWidth:130,idealWidth:150,maxWidth:170).accessibilityIdentifier("filter.sort")
    }
    @ViewBuilder private var customControls: some View {
        VStack(alignment:.leading,spacing:7) {
            if store.filters.time == .custom {
                HStack {
                    DatePicker("From",selection:Binding(get:{store.filters.start},set:{store.filters.start = minuteBoundary($0)}),displayedComponents:[.date,.hourAndMinute]).accessibilityIdentifier("filter.start")
                    DatePicker("Through",selection:Binding(get:{store.filters.end},set:{store.filters.end = minuteBoundary($0)}),displayedComponents:[.date,.hourAndMinute]).accessibilityIdentifier("filter.end")
                }
                Text("Local time · start and end times are included").font(.caption).foregroundStyle(.secondary)
            }
            if store.filters.size == .custom {
                HStack {
                    Text("Absolute change greater than").font(.caption)
                    TextField("Threshold",text:$store.filters.customThreshold).frame(width:80).accessibilityIdentifier("filter.threshold")
                    Picker("Units",selection:$store.filters.customUnit) { Text("MB").tag("MB"); Text("GB").tag("GB") }.labelsHidden().frame(width:70).accessibilityIdentifier("filter.units")
                }
                Text("1 GB = 1,000,000,000 bytes · changes of unknown size are left out").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var filterSummary: String { "\(store.filters.type.rawValue) · \(store.filters.time.rawValue) · \(store.filters.size.rawValue)" }
}

private struct ChangeCell: View {
    let event: StorageEvent
    var body: some View { Text(event.delta.map(signedChange) ?? "—").monospacedDigit().foregroundStyle(.primary).frame(maxWidth:.infinity,alignment:.trailing) }
}

private struct EventCell: View {
    let event: StorageEvent
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName:event.symbol).foregroundStyle(event.severity == .critical || event.severity == .warning ? event.severity.color : Color.secondary)
            Text(event.category).font(.callout).lineLimit(1)
            if event.severity == .warning || event.severity == .critical {
                Text(event.severity.label).font(.caption.weight(.medium)).foregroundStyle(event.severity.color)
            }
        }
        .help(event.category)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("\(event.category)\(event.severity == .warning || event.severity == .critical ? ", \(event.severity.label)" : "")")
    }
}

/// "What changed?": the most important recent recorded change, in plain words, with a way into its details.
struct LatestChange: View {
    let event: StorageEvent
    let compact: Bool
    let showDetails: () -> Void
    static func pick(_ events: [StorageEvent]) -> StorageEvent? { EventPlainSummary.latestNotable(events) }
    var body: some View {
        let summary = EventPlainSummary.make(event, CauseAnalyzer.analyze(event))
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                Text("Latest change · \(event.timestamp.formatted(date: .abbreviated, time: .shortened))").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(summary.whatHappened).font(compact ? .callout.weight(.semibold) : .title3.weight(.medium)).lineLimit(compact ? 1 : 2)
                if !compact, let explanation = summary.explanation { Text(explanation).font(.callout).lineLimit(2) }
                Text(summary.certainty == .measured ? "Measured · which app caused it was not recorded" : (summary.certainty == .unknown ? "Cause unknown" : (summary.certainty == .related ? "Possible cause, not established" : "Partly measured")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Explain", action: showDetails).accessibilityIdentifier("latest.details")
        }
        .padding(.horizontal, 22).padding(.vertical, compact ? 6 : 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("latest.change")
    }
}

private struct SummaryHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// AppKit side of the event table. Keyboard focus is owned by the list from the moment its table becomes first responder
/// or is clicked until the person moves focus deliberately (a click outside the table, Tab or Shift-Tab, ⌘F; see
/// `EventListFocusOwnership`). Opening the inspector rebuilds the split view and takes the responder from the table; while
/// the list owns focus it is given back as soon as a table is in the window again, however long the rebuild takes. The
/// responder is observed directly: SwiftUI's focus binding does not report a table focused by a click. The event monitor
/// is local to this app, observes only this window and returns every event unchanged; both stop when the table leaves.
private struct EventTableBridge: NSViewRepresentable {
    @MainActor final class Handle {
        fileprivate weak var anchor: AnchorView?
        /// Kept here, not in the anchor: the anchor is replaced when the split view is rebuilt.
        fileprivate var ownership = EventListFocusOwnership()
        /// The event table: the table view whose scroll view covers the anchor (the table's background).
        fileprivate func table() -> NSTableView? {
            guard let anchor, let content = anchor.window?.contentView else { return nil }
            let area = anchor.convert(anchor.bounds, to: nil)
            func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
            return tables(content).first { $0.enclosingScrollView.map { $0.convert($0.bounds, to: nil).intersects(area) } ?? false }
        }
        /// Scrolls so `row` (in display order) is visible; a visible row does not move.
        func scrollToRow(_ row: Int) {
            guard let table = table(), row >= 0, row < table.numberOfRows else { return }
            table.scrollRowToVisible(row)
        }
        /// Gives the list keyboard focus (after a choice in the chart, which is not a keyboard control).
        func focusTable() {
            ownership.listFocused()
            DispatchQueue.main.async { self.restoreIfOwned() }
        }
        fileprivate func responderChanged(_ responder: NSResponder?) {
            guard let table = table() else { return }
            if let view = responder as? NSView, view === table || view.isDescendant(of: table) {
                if !ownership.ownsFocus { PerformanceTrace.mark("eventList.focus", "list took focus") }
                ownership.listFocused(); return
            }
            guard ownership.restoresAfterLoss else { return }
            // Let the rebuild finish before handing focus back (the next pass, not a time window).
            DispatchQueue.main.async { self.restoreIfOwned() }
        }
        fileprivate func restoreIfOwned() {
            guard ownership.restoresAfterLoss, let table = table(), let window = table.window, window.firstResponder !== table else { return }
            let restored = window.makeFirstResponder(table)
            PerformanceTrace.mark("eventList.focus", "returned to list: \(restored)")
        }
        fileprivate func deliberateMove() {
            if ownership.ownsFocus { PerformanceTrace.mark("eventList.focus", "moved deliberately") }
            ownership.deliberateMove()
        }
    }
    let handle: Handle
    func makeNSView(context: Context) -> AnchorView { let view = AnchorView(); view.handle = handle; handle.anchor = view; return view }
    func updateNSView(_ view: AnchorView, context: Context) { view.handle = handle; handle.anchor = view }

    final class AnchorView: NSView {
        fileprivate var handle: Handle?
        private var monitor: Any?
        private var responderObservation: NSKeyValueObservation?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            responderObservation = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.type == .keyDown {
                    if EventListFocusOwnership.isDeliberateKey(keyCode: event.keyCode, command: event.modifierFlags.contains(.command), characters: event.charactersIgnoringModifiers) { self.handle?.deliberateMove() }
                } else if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    // A click in the list makes it the keyboard focus, as in any native table (SwiftUI's table keeps
                    // the window as first responder after a row click, so the arrow keys did nothing).
                    self.handle?.focusTable()
                } else {
                    self.handle?.deliberateMove()
                }
                return event
            }
            responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
                DispatchQueue.main.async { self?.handle?.responderChanged(window.firstResponder) }
            }
            // A table rebuilt into the window while the list owns focus takes it back.
            DispatchQueue.main.async { [weak self] in self?.handle?.restoreIfOwned() }
        }
    }
}
