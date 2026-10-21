import SwiftUI
import AppKit

struct HistoryView: View {
    @ObservedObject var store: ViewerStore
    @ViewState private var order = [KeyPathComparator<StorageEvent>]()
    @FocusState private var searchFocused: Bool
    @ViewState private var showFilters = false
    private var events: [StorageEvent] { order.isEmpty ? store.visibleEvents : store.visibleEvents.sorted(using:order) }
    var body: some View {
        VStack(spacing:0) {
            if store.configuration.isQA {
                Label("QA history · \(URL(fileURLWithPath:store.configuration.database).lastPathComponent)",systemImage:"testtube.2").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,22).padding(.vertical,6).background(Color.yellow.opacity(0.08))
            }
            if let snapshot = store.snapshot, snapshot.latest != nil { OverviewView(snapshot:snapshot,live:store.live); Divider() }
            if let error = store.error {
                HStack(alignment:.top) {
                    Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange)
                    VStack(alignment:.leading,spacing:4) { Text(store.snapshot == nil ? "History unavailable" : "Could not refresh history").font(.headline); Text(error).font(.caption).textSelection(.enabled) }
                    Spacer(); Button("Retry") { store.refresh() }.accessibilityIdentifier("history.retry")
                }.padding(16).background(Color.orange.opacity(0.07)).accessibilityIdentifier("history.error")
                Divider()
            }
            filterBar
            Divider()
            if let validation = store.filters.validation { Label(validation,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.primary).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,22).padding(.vertical,8).accessibilityIdentifier("filters.validation") }
            ZStack {
                Table(events,selection:$store.selection,sortOrder:$order) {
                    TableColumn("Time",value:\.timestamp) { event in Text(event.timestamp,format:.dateTime.month(.abbreviated).day().hour().minute().second()).monospacedDigit().font(.callout) }.width(min:135,ideal:175,max:220)
                    TableColumn("Event") { event in Label(event.category,systemImage:event.symbol).font(.callout).lineLimit(1).help(event.category) }.width(min:125,ideal:150,max:240)
                    TableColumn("Net change",value:\.changeOrder) { (event: StorageEvent) in ChangeCell(event:event) }.width(min:90,ideal:110,max:140)
                    TableColumn("Free space",value:\.freeOrder) { event in Text(event.currentFree.map { capacity($0) } ?? "—").monospacedDigit().frame(maxWidth:.infinity,alignment:.trailing) }.width(min:85,ideal:100,max:130)
                    TableColumn("Severity",value:\.severityOrder) { event in SeverityLabel(severity:event.severity) }.width(min:90,ideal:110,max:130)
                }
                .textSelection(.disabled)
                .tableStyle(.inset(alternatesRowBackgrounds:false))
                .accessibilityIdentifier("history.table")
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
                    else {
                        VStack(spacing:10) {
                            Image(systemName:store.error != nil ? "externaldrive.badge.questionmark" : "line.3.horizontal.decrease.circle").font(.largeTitle).foregroundStyle(.secondary)
                            Text(store.error != nil && store.snapshot == nil ? "Could not load history" : (store.snapshot?.events.isEmpty == false ? "No matching events" : "No recorded events yet")).font(.headline)
                            Text(store.error != nil && store.snapshot == nil ? "Retry after checking that the monitor's database is available." : (store.snapshot?.events.isEmpty == false ? "Try another time range or clear your filters." : "The independent background monitor is configured to record capacity at login and every half hour.")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if store.hasActiveFilters { Button("Clear Filters") { store.clearFilters(); order = [] } }
                        }.padding(25).frame(maxWidth:460).accessibilityIdentifier("history.empty")
                    }
                }
            }.frame(minHeight:170,maxHeight:.infinity)
            HStack {
                Text("\(events.count) of \(store.snapshot?.events.count ?? 0) events").accessibilityIdentifier("history.resultCount")
                if let selection = store.selectedEvent { Text("· \(selection.category)").lineLimit(1) }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                Text("Read-only · background monitor is independent")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,22).padding(.vertical,8)
            Divider()
            CapacityChart(readings:store.snapshot?.measurements ?? [],range:$store.chartRange)
        }
        .textSelection(.enabled)
        .background(Color(nsColor:.windowBackgroundColor))
        .inspector(isPresented:$store.showInspector) {
            EventDetailView(event:store.selectedEvent)
                .inspectorColumnWidth(min:300,ideal:360,max:480)
        }
        .toolbar {
            ToolbarItem(placement:.navigation) { Label("Storage Monitor",systemImage:"internaldrive").font(.headline) }
            ToolbarItemGroup(placement:.primaryAction) {
                Button { store.refreshAll() } label: { Image(systemName:"arrow.clockwise") }.help("Refresh live capacity and recorded history (⌘R). Does not record a reading, run diagnostics, or send alerts.").accessibilityLabel("Refresh").accessibilityIdentifier("history.refresh")
                Button { store.showInspector.toggle() } label: { Image(systemName:"sidebar.right") }.help("Show Event Details (⌥⌘I)").accessibilityLabel("Show Event Details").accessibilityIdentifier("history.inspector")
            }
        }
        .onChange(of:store.filters) { _,_ in order = [] }
        .onChange(of:store.selection) { _,value in if value != nil { store.showInspector = true } }
        .onExitCommand { store.showInspector = false }
        .background(Button("Focus search") { searchFocused = true }.keyboardShortcut("f").hidden())
        .navigationTitle(store.configuration.isQA ? "Storage Monitor — QA: \(URL(fileURLWithPath:store.configuration.database).lastPathComponent)" : "Storage Monitor")
    }
    private var filterBar: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(spacing:10) {
                Text("Event history").font(.headline)
                Spacer()
                HStack(spacing:6) {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search recorded events",text:$store.filters.search).textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("filter.search").accessibilityLabel("Search descriptions, categories, and diagnostic evidence")
                    if !store.filters.search.isEmpty { Button { store.filters.search = "" } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
                }.padding(.horizontal,8).padding(.vertical,5).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:6)).frame(minWidth:160,maxWidth:300)
                Button("Clear Filters") { store.clearFilters(); order = [] }.disabled(!store.hasActiveFilters).accessibilityIdentifier("filter.clear")
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:8) { primaryFilters; sortPicker }
                HStack(spacing:8) {
                    Button { showFilters.toggle() } label: { Label("Filters\(store.filters.activeCount == 0 ? "" : " (\(store.filters.activeCount))")",systemImage:"line.3.horizontal.decrease") }.fixedSize().accessibilityIdentifier("filter.expand")
                        .popover(isPresented:$showFilters,arrowEdge:.bottom) { Form { primaryFilters; customControls }.formStyle(.grouped).frame(width:400).padding(8) }
                    Text(filterSummary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                    Spacer(); sortPicker
                }
            }
            if store.filters.time == .custom || store.filters.size == .custom { customControls }
        }.padding(.horizontal,22).padding(.vertical,12)
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
        }.frame(minWidth:150,idealWidth:200,maxWidth:210).accessibilityIdentifier("filter.sort")
    }
    @ViewBuilder private var customControls: some View {
        VStack(alignment:.leading,spacing:7) {
            if store.filters.time == .custom {
                HStack {
                    DatePicker("From",selection:Binding(get:{store.filters.start},set:{store.filters.start = minuteBoundary($0)}),displayedComponents:[.date,.hourAndMinute]).accessibilityIdentifier("filter.start")
                    DatePicker("Through",selection:Binding(get:{store.filters.end},set:{store.filters.end = minuteBoundary($0)}),displayedComponents:[.date,.hourAndMinute]).accessibilityIdentifier("filter.end")
                }
                Text("Local time · endpoints at :00 seconds, inclusive").font(.caption).foregroundStyle(.secondary)
            }
            if store.filters.size == .custom {
                HStack {
                    Text("Absolute change greater than").font(.caption)
                    TextField("Threshold",text:$store.filters.customThreshold).frame(width:80).accessibilityIdentifier("filter.threshold")
                    Picker("Units",selection:$store.filters.customUnit) { Text("MB").tag("MB"); Text("GB").tag("GB") }.labelsHidden().frame(width:70).accessibilityIdentifier("filter.units")
                }
                Text("Decimal units · unknown changes excluded").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var filterSummary: String { "\(store.filters.type.rawValue) · \(store.filters.time.rawValue) · \(store.filters.size.rawValue)" }
}

private struct ChangeCell: View {
    let event: StorageEvent
    var body: some View { Text(event.delta.map(signedChange) ?? "—").monospacedDigit().foregroundStyle(.primary).frame(maxWidth:.infinity,alignment:.trailing) }
}
