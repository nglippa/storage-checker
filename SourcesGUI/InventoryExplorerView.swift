import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Loads explorer pages from the inventory database. Reads only the folders the person expands, one
/// bounded page at a time; never scans the filesystem.
/// What a large folder tile shows inside: the children of the folder, or of the single subfolder that holds
/// almost all of it (`chain`, outermost first), read in one snapshot per folder.
struct InventoryNestedContent {
    let chain: [InventoryNode]
    let page: InventoryChildPage
    let remainder: InventoryChildRemainder?
}

@MainActor final class InventoryExplorerController: ObservableObject {
    @Published private(set) var state = InventoryExplorerState()
    @Published private(set) var rows = [InventoryExplorerRow]()
    /// Exact totals of each folder's children beyond its loaded span, keyed by the span they were read for.
    @Published private(set) var remainders = [Int64: (loaded: Int, value: InventoryChildRemainder)]()
    /// Storage-map windows per folder: each drill into "Other items" pushes the window's first entry.
    @Published private(set) var mapWindows = [Int64: [Int]]()
    /// Nested map contents of large folder tiles: each folder's 60 largest children and the exact
    /// remainder, read in one snapshot. Bounded to `nestedLimit` folders, least recently used dropped.
    @Published private(set) var nested = [Int64: InventoryNestedContent]()
    /// A row the outline should scroll to (set when the map selects something).
    @Published private(set) var scrollRequest: Int64?
    static let nestedLimit = 24, nestedPage = 60
    private var nestedRecency = InventoryRecency(capacity: InventoryExplorerController.nestedLimit)
    private var nestedReads = Set<Int64>()
    private var nestedStale = Set<Int64>()
    private let reader: InventoryReader
    private var lastReload = Date.distantPast
    private var lastFullReload = Date.distantPast
    /// Position in the inventory's change feed; bounded (a cursor and at most 512 folder ids to retry).
    private var tracker = InventoryChangeTracker()
    /// Counts of refresh work done and avoided, for diagnostics and measurements.
    private(set) var statistics = InventoryRefreshStatistics()
    private var reloading = false
    private var pendingChange = false
    private var retry: Task<Void, Never>?

    init(database: String) { reader = InventoryReader(path: database) }

    var selection: Int64? {
        get { state.selection }
        set {
            // Placeholder rows are not selectable; choosing "Show more" loads the next page instead.
            if let newValue, newValue < 0 {
                if let row = rows.first(where: { $0.id == newValue }), case .more = row.content { loadMore(row.parent) }
                return
            }
            state.selection = newValue
            PerformanceTrace.mark("selection.change", "\(newValue.map(String.init) ?? "none")", frame: true)
            publish()
        }
    }

    func show(root: InventoryNode, trail: [InventoryNode]) {
        state.setRoot(root, cameFrom: trail)
        publish()
        for parent in state.pendingLoads { load(parent) }
        // A folder already loaded earlier still needs its remainder for the map's "Other items".
        refreshRemainder(root.id)
    }

    func toggle(_ id: Int64) {
        if state.isExpanded(id) { state.collapse(id); publish() }
        else if state.expand(id) { publish(); load(id) } else { publish() }
    }

    func handle(_ key: InventoryExplorerState.Key) {
        let result = state.handle(key)
        publish()
        if case .expanded(true) = result, let id = state.selection { load(id) }
    }

    func loadMore(_ parent: Int64) {
        guard state.canLoadMore(parent) else { return }
        load(parent, after: state.children[parent]?.next)
    }

    func retry(_ parent: Int64) { load(parent) }

    // MARK: Storage map

    /// The current map window of `folder`. A window that no longer exists after an index update (the
    /// folder shrank below it) falls back to the start.
    func mapStart(_ folder: Int64) -> Int {
        guard let start = mapWindows[folder]?.last, let list = state.children[folder] else { return 0 }
        return start < list.items.count || state.loading.contains(folder) || list.next != nil ? start : 0
    }

    /// The remainder beyond the loaded span, when it matches the current span (nil: fully loaded or pending).
    func beyond(_ folder: Int64) -> InventoryChildRemainder? {
        guard let list = state.children[folder], list.next != nil else { return nil }
        guard let cached = remainders[folder], cached.loaded == list.items.count else { return nil }
        return cached.value
    }

    /// Whether the map can be drawn truthfully: a folder with unloaded children needs its exact remainder.
    func mapReady(_ folder: Int64) -> Bool {
        guard let list = state.children[folder] else { return false }
        return list.next == nil || beyond(folder) != nil
    }

    /// Shows the entries grouped as "Other items" as the next map window, loading a page if needed.
    func drill(_ folder: Int64, to start: Int) {
        mapWindows[folder, default: []].append(start)
        if let list = state.children[folder], list.items.count < start + 120 { loadMore(folder) }
    }

    func mapBack(_ folder: Int64) { _ = mapWindows[folder]?.popLast() }

    /// Reads nested contents for the given large folder tiles that are missing or outdated. At most one read
    /// per folder is in flight; the cache keeps the `nestedLimit` most recently requested folders.
    func requestNested(_ folders: [Int64]) {
        for folder in folders {
            for dropped in nestedRecency.use(folder) { nested[dropped] = nil; nestedStale.remove(dropped) }
            guard nested[folder] == nil || nestedStale.contains(folder), !nestedReads.contains(folder) else { continue }
            nestedReads.insert(folder)
            let reader = reader
            Task {
                defer { nestedReads.remove(folder) }
                // A folder that is almost entirely one subfolder (Users → your home folder) shows that
                // subfolder's contents instead: up to four bounded reads, each one page.
                var chain = [InventoryNode](), current = folder, hops = 0
                while let span = try? await reader.explorerSpan(parentID: current, count: Self.nestedPage, pageLimit: Self.nestedPage) {
                    let total = span.page.items.reduce(Int64(0)) { $0 + (InventoryMapPlan.weight($1) ?? 0) } + (span.remainder?.allocated ?? 0)
                    if hops < 4, let first = span.page.items.first, first.kind == .directory, first.childCount > 0, first.status != .unknown,
                       let weight = InventoryMapPlan.weight(first), total > 0, Double(weight) >= 0.9 * Double(total) {
                        chain.append(first); current = first.id; hops += 1; continue
                    }
                    // A folder evicted while its read was in flight is not re-added: the cache stays bounded.
                    if nestedRecency.keys.contains(folder) {
                        nested[folder] = InventoryNestedContent(chain: chain, page: span.page, remainder: span.remainder)
                    }
                    nestedStale.remove(folder)
                    break
                }
            }
        }
    }

    func scrollHandled() { scrollRequest = nil }

    /// Selects an entry shown on the map. An entry inside a nested folder expands that folder in the
    /// outline so the same row becomes visible, and the outline is asked to scroll to it.
    func select(_ node: InventoryNode) {
        state.update(node)
        if let parent = node.parentID, parent != state.rootID, state.node(parent) != nil, !state.isExpanded(parent) {
            if state.expand(parent) { load(parent) }
        }
        state.selection = node.id
        scrollRequest = node.id
        PerformanceTrace.mark("selection.change", "\(node.id)", frame: true)
        publish()
    }

    /// Folders opened in the Navigator only to reveal a selection made in the Living Tree; closed again when the
    /// next reveal no longer passes through them, so revealing never accumulates expanded folders.
    private var revealExpanded = Set<Int64>()

    /// Selects an entry chosen deeper in a visualization. Every folder on the way from the current folder (`chain`,
    /// outermost first) is opened in the Navigator so the entry's row can appear; `openTarget` also opens the entry
    /// itself (a folder whose grouped small items were chosen).
    func select(_ node: InventoryNode, through chain: [InventoryNode], openTarget: Bool = false) {
        for folder in chain { state.update(folder) }
        state.update(node)
        let opening = chain.filter { $0.id != state.rootID && $0.kind == .directory } + (openTarget && node.id != state.rootID && node.kind == .directory ? [node] : [])
        let keep = Set(opening.map(\.id))
        for folder in revealExpanded.subtracting(keep) where folder != node.id { state.collapse(folder) }
        // A folder opened for an earlier reveal and selected now stays open, and stays tracked so that a later
        // reveal elsewhere still closes it.
        revealExpanded = revealExpanded.filter { keep.contains($0) || ($0 == node.id && state.isExpanded($0)) }
        for folder in opening where !state.isExpanded(folder.id) {
            revealExpanded.insert(folder.id)
            if state.expand(folder.id) { load(folder.id) }
        }
        state.selection = node.id
        scrollRequest = node.id
        PerformanceTrace.mark("selection.change", "\(node.id) nested", frame: true)
        publish()
    }

    /// An entry to draw in the Living Tree even when it is small (a search result shown in its folder). Each request
    /// is distinct, so revealing the same entry again is delivered again.
    struct RevealRequest: Equatable { let node: Int64; let folder: Int64?; let serial: Int }
    @Published private(set) var revealRequest: RevealRequest?
    func reveal(_ node: InventoryNode) {
        select(node)
        revealRequest = RevealRequest(node: node.id, folder: node.parentID, serial: (revealRequest?.serial ?? 0) + 1)
    }

    private var spanReads = Set<Int64>()

    /// Re-reads the map folder's loaded span together with the exact remainder in one SQLite snapshot, and
    /// replaces both at once, so drawn tiles and "Other items" always describe the same moment.
    private func refreshRemainder(_ folder: Int64) {
        guard let list = state.children[folder], list.next != nil else { remainders[folder] = nil; return }
        let loaded = list.items.count, reader = reader
        if remainders[folder]?.loaded == loaded || spanReads.contains(folder) { return }
        spanReads.insert(folder)
        Task {
            defer { spanReads.remove(folder) }
            guard let span = try? await PerformanceTrace.measure("explorer.span", "\(folder)", { try await reader.explorerSpan(parentID: folder, count: loaded) }),
                  state.children[folder]?.items.count == loaded else { return }
            state.receive(parent: folder, page: span.page, replacing: true)
            remainders[folder] = span.remainder.map { (span.page.items.count, $0) }
            publish()
        }
    }

    private func load(_ parent: Int64, after cursor: InventoryChildCursor? = nil) {
        state.beginLoading(parent)
        let reader = reader
        Task {
            do {
                let page = try await PerformanceTrace.measure("explorer.children", "\(parent)") { try await reader.explorerChildren(parentID: parent, after: cursor, limit: 200) }
                // A reply for a folder that was collapsed and evicted meanwhile is still harmless to keep.
                state.receive(parent: parent, page: page)
                if parent == state.rootID { refreshRemainder(parent) }
            } catch {
                state.fail(parent: parent, message: (error as? InventoryReaderError).map { "\($0)" } ?? error.localizedDescription)
            }
            publish()
        }
    }

    /// Brings what is shown up to date after the inventory changed. The change feed names the directories whose
    /// committed state changed; only loaded folders among them (and folders beneath a changed subtree) are re-read,
    /// each for the span it had loaded, so the outline does not jump and unchanged branches are not read at all.
    /// Without a usable cursor (first pass, no journal, a backlog beyond one read, history pruned past the cursor)
    /// every visible folder is re-read instead, at most every five seconds. A change that arrives during a re-read
    /// or inside the throttle window is kept and re-checked, not dropped.
    func inventoryChanged() {
        guard !reloading, Date().timeIntervalSince(lastReload) >= 1 else { deferInventoryChange(); return }
        pendingChange = false
        reloading = true; lastReload = Date()
        let reader = reader, tracker = tracker
        Task {
            defer { reloading = false; publish() }
            let batch = try? await reader.changes(since: tracker.cursor)
            let (plan, next) = tracker.planned(batch)
            let visible = state.reloadPlan.count
            let targets: [(parent: Int64, count: Int)]
            statistics.passes += 1
            switch plan {
            case .none:
                self.tracker = next; statistics.foldersSkipped += visible; return
            case .everything:
                // Keep the plan uncommitted when throttled: the same backlog is planned again shortly.
                guard Date().timeIntervalSince(lastFullReload) >= 5 else { deferInventoryChange(); return }
                lastFullReload = Date(); statistics.fullRefreshes += 1
                state.invalidateCollapsed()
                nestedStale.formUnion(nested.keys)
                targets = state.reloadPlan
            case .folders(let listing, let subtrees):
                statistics.incrementalRefreshes += 1
                state.invalidateCollapsed(listing: listing, subtrees: subtrees)
                for (folder, content) in nested {
                    let ids = Set([folder] + content.chain.map(\.id))
                    if !ids.isDisjoint(with: listing) || (!subtrees.isEmpty && ids.contains(where: { state.isAtOrBeneath($0, subtrees) })) { nestedStale.insert(folder) }
                }
                targets = state.refreshTargets(listing: listing, subtrees: subtrees)
            }
            // Nested map contents stay drawn and are re-read only where their source changed.
            requestNested(nestedRecency.keys)
            statistics.foldersReloaded += targets.count; statistics.foldersSkipped += max(0, visible - targets.count)
            let selection = state.selection
            let result = await InventoryVisibleRefresh.perform(reader: reader, targets: targets, selection: selection,
                                                               selectionParent: selection.flatMap { state.node($0)?.parentID },
                                                               previous: state.shownEntries(targets.map(\.parent)))
            // A folder that loaded more entries during the re-read keeps them and is refreshed again.
            let superseded = state.apply(result)
            statistics.failedReads += result.failed.count; statistics.deletedFolders += result.deleted.count
            var committed = next
            committed.noteFailed(result.failed + superseded, loaded: state.loadedFolders)
            self.tracker = committed
            // The index changed: the grouped remainder is read again for the reloaded span.
            if let root = state.rootID, targets.contains(where: { $0.parent == root }) { remainders[root] = nil; refreshRemainder(root) }
            if !committed.retry.isEmpty { deferInventoryChange() }
        }
    }

    /// Keeps a throttled change and re-checks it every quarter second until the window and any running re-read pass.
    private func deferInventoryChange() {
        pendingChange = true
        guard retry == nil else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.retry = nil
            if self.pendingChange { self.inventoryChanged() }
        }
    }
    private func publish() { rows = state.rows }
}

/// The visualization shown above the Navigator.
enum InventoryVisualization: String, CaseIterable, Identifiable {
    case atlas, tree
    var id: String { rawValue }
    var title: String { self == .atlas ? "Atlas" : "Living Tree" }
}

struct InventoryExplorerView: View {
    @ObservedObject var browser: InventoryBrowserModel
    /// Owned by the browser model, so the outline and the storage map share one navigation and selection
    /// state, and switching browse modes keeps what was expanded.
    @ObservedObject private var explorer: InventoryExplorerController
    @AppStorage("inventory.explorer.showMap", store: ViewerStore.viewPreferences) private var showMap = true
    /// Height of the map above the outline; kept between launches.
    @AppStorage("inventory.explorer.mapHeight", store: ViewerStore.viewPreferences) private var mapHeight = 440.0
    @State private var dragStartHeight: Double?
    /// The Navigator (default) or the detailed table, the technical view.
    @AppStorage("inventory.explorer.technical", store: ViewerStore.viewPreferences) private var technicalView = false
    @AppStorage("inventory.explorer.inspector", store: ViewerStore.viewPreferences) private var showInspector = true
    /// The visualization above the Navigator: the Storage Atlas or the Living Tree (remembered).
    @AppStorage("inventory.explorer.visualization", store: ViewerStore.viewPreferences) private var visualization = InventoryVisualization.tree
    @AppStorage("inventory.explorer.treeNavigatorExpanded", store: ViewerStore.viewPreferences) private var treeNavigatorExpanded = false
    /// The Living Tree's presentation: the Structured Explorer, or (QA fallback, set only with `defaults write`) the
    /// classic branching tree. Not offered in the interface; an absent or unknown value is the Structured Explorer.
    @AppStorage("inventory.livingTree.renderer", store: ViewerStore.viewPreferences) private var treeRenderer = LivingTreeRenderer.structured.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Space not attributed to indexed files is stated once, in the Disk Inventory header above the explorer.
    init(browser: InventoryBrowserModel) {
        self.browser = browser
        _explorer = ObservedObject(wrappedValue: browser.explorer)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let freshness = sharedFreshness {
                    Text(freshness).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 5)
                        .accessibilityIdentifier("inventory.explorer.freshness")
                    Divider()
                }
                if showMap {
                    GeometryReader { geometry in
                        let navigatorVisible = visualization != .tree || treeNavigatorExpanded
                        let maximumHeight = max(160, geometry.size.height - (navigatorVisible ? 198 : 40))
                        let minimumHeight = min(visualization == .tree ? 280 : 160, maximumHeight)
                        let height = navigatorVisible ? min(max(minimumHeight, mapHeight), maximumHeight) : maximumHeight
                        VStack(spacing: 0) {
                            Group {
                                switch visualization {
                                case .atlas: StorageAtlasView(browser: browser, explorer: explorer)
                                case .tree:
                                    switch LivingTreeRenderer(preference: treeRenderer) {
                                    case .structured: StructuredExplorerView(browser: browser, explorer: explorer, tree: browser.livingTree, showsSelectionContext: !showInspector)
                                    case .classic: LivingTreeView(browser: browser, explorer: explorer, tree: browser.livingTree, showsSelectionContext: !showInspector)
                                    }
                                }
                            }.frame(height: height)
                            if navigatorVisible {
                                splitHandle(current: height, minimum: minimumHeight, limit: maximumHeight)
                                lowerPane
                            } else { paneToolbar }
                        }
                    }
                } else { lowerPane }
                if !showInspector { Divider(); selectionBar }
            }
            if showInspector {
                Divider()
                InventoryInspectorView(browser: browser, explorer: explorer)
                    .frame(width: StorageDesign.inspectorWidth)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onAppear(perform: syncRoot)
        .onChange(of: visualization) { _, value in PerformanceTrace.mark("visualization.change", value.rawValue, frame: true) }
        .onChange(of: browser.directory?.id) { _, _ in syncRoot() }
        .onChange(of: browser.status?.updatedAt) { _, _ in explorer.inventoryChanged() }
        .onChange(of: browser.revision) { _, _ in explorer.inventoryChanged() }
    }

    /// A thin divider the map can be resized with; the height is remembered.
    private func splitHandle(current: Double, minimum: Double, limit: Double) -> some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            .padding(.vertical, 3).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartHeight ?? current
                    dragStartHeight = start
                    mapHeight = min(max(minimum, start + value.translation.height), limit)
                }
                .onEnded { _ in dragStartHeight = nil })
            .accessibilityLabel("Resize storage map")
    }

    /// The earlier-size state most entries here share, stated once instead of on every row and tile.
    private var sharedNote: String? {
        explorer.state.rootID.flatMap { explorer.state.children[$0]?.items }.flatMap(InventoryNodePresentation.sharedFreshness)
    }

    /// Stated in the map's status line when the map is shown; as its own line only when it is hidden.
    private var sharedFreshness: String? {
        showMap ? nil : InventoryNodePresentation.sharedFreshnessText(sharedNote).map { $0 + ". Hover an item for its exact state." }
    }

    /// The Navigator or the technical table, with a slim bar to switch views and show the Inspector or Atlas.
    private var lowerPane: some View {
        VStack(spacing: 0) {
            paneToolbar
            Divider()
            if technicalView { outline } else { InventoryNavigatorView(browser: browser, explorer: explorer) }
        }
    }

    private var paneToolbar: some View {
        HStack(spacing: 10) {
            if visualization == .tree && showMap {
                Button { treeNavigatorExpanded.toggle() } label: {
                    Label(treeNavigatorExpanded ? "Hide List" : "Show List", systemImage: "list.bullet.indent")
                }.controlSize(.small).accessibilityIdentifier("inventory.navigatorToggle")
                if treeNavigatorExpanded {
                    Menu("List style") {
                        Picker("List style", selection: $technicalView) { Text("List").tag(false); Text("Table").tag(true) }
                    }.controlSize(.small).fixedSize()
                }
            } else {
                Picker("View", selection: $technicalView) {
                    Text("List").tag(false)
                    Text("Table").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .help("A folder list, or a table with every column")
            }
                Spacer()
                if showMap {
                    Picker("Visualization", selection: $visualization) {
                        ForEach(InventoryVisualization.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                    .help("Two pictures of the same folder: Atlas (rectangles) or Living Tree (branches)")
                    .accessibilityIdentifier("inventory.visualization")
                }
                Toggle(isOn: $showMap) { Image(systemName: "square.grid.2x2") }.toggleStyle(.button).controlSize(.small)
                    .help(showMap ? "Hide the \(visualization.title)" : "Show the \(visualization.title)").accessibilityLabel("Visualization")
                Toggle(isOn: Binding(get: { showInspector }, set: { value in withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { showInspector = value } })) {
                    Image(systemName: "sidebar.right")
                }.toggleStyle(.button).controlSize(.small)
                .help(showInspector ? "Hide the Inspector" : "Show the Inspector").accessibilityLabel("Inspector")
            }.padding(.horizontal, 16).padding(.vertical, 6)
    }

    private var outline: some View {
        ScrollViewReader { proxy in
            Table(explorer.rows, selection: Binding(get: { explorer.selection }, set: { explorer.selection = $0 })) {
                TableColumn("Name") { row in nameCell(row) }.width(min: 220, ideal: 420, max: .infinity)
                TableColumn("Allocated") { row in
                    if let node = row.node {
                        // Entries with no measured size (unreadable, or never measured) get one quiet dash,
                        // explained in the Measurement column.
                        if InventoryMapPlan.weight(node) == nil && node.status != .lowerBound { Text("—").foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing) }
                        else { allocatedCell(node, parent: row.parent) }
                    }
                }.width(min: 150, ideal: 170, max: 200)
                TableColumn("Logical") { row in
                    if let node = row.node, InventoryMapPlan.weight(node) != nil || node.status == .lowerBound {
                        Text(compact(node.objectLogicalBytes ?? node.logicalBytes ?? node.previousLogicalBytes, node))
                            .monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.width(min: 110, ideal: 135, max: 160)
                TableColumn("Items") { row in
                    if let node = row.node, node.kind == .directory, InventoryMapPlan.weight(node) != nil || node.childCount > 0 {
                        Text(node.childCount.formatted()).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.width(min: 55, ideal: 70, max: 90)
                // Only states that differ from the folder's shared note, which is stated once above.
                TableColumn("Measurement") { row in
                    if let node = row.node, let note = InventoryNodePresentation.explorerNote(node), note != sharedNote {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(node.statusReason ?? note)
                    }
                }.width(min: 90, ideal: 150, max: 220)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .environment(\.defaultMinListRowHeight, 22)
            .accessibilityIdentifier("inventory.explorer")
            .onKeyPress(.leftArrow) { explorer.handle(.left); return .handled }
            .onKeyPress(.rightArrow) { explorer.handle(.right); return .handled }
            .onKeyPress(.return) { drillIn(); return .handled }
            .onCopyCommand { selectedNode.map { [NSItemProvider(object: $0.path as NSString)] } ?? [] }
            .contextMenu(forSelectionType: Int64.self) { ids in
                if let id = ids.first, let node = explorer.state.node(id) { menu(for: node) }
            } primaryAction: { ids in
                // Double-click opens a folder, like Return and a click on its map tile; the chevron and the
                // arrow keys expand it in place.
                if let id = ids.first, let node = explorer.state.node(id), node.kind == .directory { browser.navigate(node) }
            }
            // A selection made on the map brings its row into view (it may have just been revealed).
            .onChange(of: explorer.scrollRequest) { _, id in
                guard let id else { return }
                if explorer.rows.contains(where: { $0.id == id }) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    explorer.scrollHandled()
                }
            }
            .onChange(of: explorer.rows.count) { _, _ in
                // The row appears once its folder's page has loaded.
                if let id = explorer.scrollRequest, explorer.rows.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center); explorer.scrollHandled() }
            }
        }
    }

    private var selectedNode: InventoryNode? { explorer.selection.flatMap { explorer.state.node($0) } }

    // MARK: Cells

    @ViewBuilder private func nameCell(_ row: InventoryExplorerRow) -> some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            switch row.content {
            case .node(let node):
                disclosure(node)
                Image(nsImage: ExplorerIcons.icon(for: node)).resizable().frame(width: 16, height: 16)
                Text(node.name.isEmpty ? "Startup Data" : node.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(node.status == .unknown ? .secondary : .primary)
                    .help(node.path)
            case .loading:
                spacer
                ProgressView().controlSize(.mini)
                Text("Loading…").foregroundStyle(.secondary)
            case .more(let loaded, let total):
                spacer
                Button("Show more · \(loaded.formatted()) of \(total.formatted())") { explorer.loadMore(row.parent) }
                    .buttonStyle(.link).font(.callout)
                    .onAppear { explorer.loadMore(row.parent) }
            case .limit(let loaded, let total):
                spacer
                Text("Showing the \(loaded.formatted()) largest of \(total.formatted()) items. Use Largest items to rank the rest.")
                    .font(.callout).foregroundStyle(.secondary)
            case .empty:
                spacer
                Text("Empty folder").font(.callout).foregroundStyle(.tertiary)
            case .unavailable(let reason):
                spacer
                Text("Contents not available · \(reason)").font(.callout).foregroundStyle(.secondary)
            case .failed(let message):
                spacer
                Text("Couldn't load this folder.").font(.callout).foregroundStyle(.secondary).help(message)
                Button("Try Again") { explorer.retry(row.parent) }.buttonStyle(.link).font(.callout)
            }
        }
    }

    private var spacer: some View { Color.clear.frame(width: 14, height: 1) }

    @ViewBuilder private func disclosure(_ node: InventoryNode) -> some View {
        if node.kind == .directory && node.childCount > 0 {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { explorer.toggle(node.id) } } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(explorer.state.isExpanded(node.id) ? 90 : 0))
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(explorer.state.isExpanded(node.id) ? "Collapse \(node.name)" : "Expand \(node.name)")
        } else { spacer }
    }

    private func allocatedCell(_ node: InventoryNode, parent: Int64) -> some View {
        let value = node.allocatedBytes ?? node.previousAllocatedBytes
        let parentValue = explorer.state.node(parent).flatMap { $0.allocatedBytes ?? $0.previousAllocatedBytes }
        let share = value.flatMap { v in parentValue.flatMap { p in p > 0 ? min(1, Double(v) / Double(p)) : nil } }
        return HStack(spacing: 8) {
            // Share of the enclosing folder, drawn only when both sizes are known.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                if let share { Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: max(share > 0 ? 2 : 0, 40 * share)) }
            }.frame(width: 40, height: 4).opacity(share == nil ? 0 : 1).accessibilityHidden(true)
            Text(compact(value, node)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                .help(size(value, node))
        }
    }

    /// Sizes without the repeated "Previously"/"≈" prefix; the state is in the Measurement column, the shared
    /// note above, and the full wording on hover.
    private func compact(_ value: Int64?, _ node: InventoryNode) -> String {
        InventoryNodePresentation.compactSize(value, node: node) { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private func size(_ value: Int64?, _ node: InventoryNode) -> String {
        InventoryNodePresentation.size(value, node: node) { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    // MARK: Actions

    @ViewBuilder private func menu(for node: InventoryNode) -> some View {
        if node.kind == .directory { Button("Show Contents") { browser.navigate(node) } }
        Button("Reveal in Finder") { reveal(node) }
        Button("Copy Path") { copy(node) }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            if let node = selectedNode {
                Image(nsImage: ExplorerIcons.icon(for: node)).resizable().frame(width: 14, height: 14)
                Text(node.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                if node.kind == .directory { Button("Show Contents") { browser.navigate(node) }.controlSize(.small) }
                Button("Reveal in Finder") { reveal(node) }.controlSize(.small)
                Button("Copy Path") { copy(node) }.controlSize(.small)
            } else {
                Text("Select an item to see its path. ← and → collapse and expand; Return or double-click opens a folder.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
        }.padding(.horizontal, 22).frame(height: 32).accessibilityIdentifier("inventory.explorer.selection")
    }

    private func drillIn() {
        if let node = selectedNode, node.kind == .directory { browser.navigate(node) }
    }

    private func reveal(_ node: InventoryNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    private func copy(_ node: InventoryNode) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.path, forType: .string)
    }

    /// Follows the browser's current folder (breadcrumbs, Go to folder…, Show Contents).
    private func syncRoot() {
        guard let folder = browser.directory else { return }
        explorer.show(root: folder, trail: lastTrail)
        lastTrail = browser.breadcrumbs
        // A search result opened in its folder is selected there and drawn in the Living Tree even when small.
        if let pending = browser.pendingReveal, pending.parentID == folder.id {
            browser.pendingReveal = nil
            explorer.reveal(pending)
        }
    }
    @State private var lastTrail = [InventoryNode]()
}

/// File-type icons from Launch Services by type only: no filesystem access, cached per extension.
@MainActor enum ExplorerIcons {
    private static var cache = [String: NSImage]()
    static func icon(for node: InventoryNode) -> NSImage {
        let key: String, type: UTType
        switch node.kind {
        case .directory:
            let ext = (node.name as NSString).pathExtension.lowercased()
            if ext == "app" { key = "app"; type = .applicationBundle }
            else if !ext.isEmpty, let bundle = UTType(filenameExtension: ext), bundle.conforms(to: .package) { key = "pkg." + ext; type = bundle }
            else { key = "folder"; type = .folder }
        case .symlink: key = "link"; type = .symbolicLink
        default:
            let ext = (node.name as NSString).pathExtension.lowercased()
            key = "f." + ext; type = UTType(filenameExtension: ext) ?? .data
        }
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
