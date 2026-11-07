import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Navigator: the explorer's outline as a calm list of files and folders, sharing the Atlas's
/// selection, expansion and lazy pages (InventoryExplorerState). The detailed table remains available as
/// the technical view.
struct InventoryNavigatorView: View {
    @ObservedObject var browser: InventoryBrowserModel
    @ObservedObject var explorer: InventoryExplorerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { explorer.selection }, set: { explorer.selection = $0 })) {
                let shared = sharedNote
                ForEach(explorer.rows) { row in
                    NavigatorRow(row: row, explorer: explorer, hueIndex: hueIndex(row), sharedNote: shared)
                        .tag(row.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 14))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 28)
            .accessibilityIdentifier("inventory.navigator")
            .onKeyPress(.leftArrow) { explorer.handle(.left); return .handled }
            .onKeyPress(.rightArrow) { explorer.handle(.right); return .handled }
            .onKeyPress(.return) { open(selected); return .handled }
            .onCopyCommand { selected.map { [NSItemProvider(object: $0.path as NSString)] } ?? [] }
            .contextMenu(forSelectionType: Int64.self) { ids in
                if let id = ids.first, let node = explorer.state.node(id) { InventoryActions(browser: browser, node: node).menu }
            } primaryAction: { ids in
                if let id = ids.first { open(explorer.state.node(id)) }
            }
            .onChange(of: explorer.scrollRequest) { _, id in
                guard let id, explorer.rows.contains(where: { $0.id == id }) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                explorer.scrollHandled()
            }
            .onChange(of: explorer.rows.count) { _, _ in
                if let id = explorer.scrollRequest, explorer.rows.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center); explorer.scrollHandled() }
            }
        }
    }

    private var selected: InventoryNode? { explorer.selection.flatMap { explorer.state.node($0) } }

    /// The earlier-size note most entries here share (stated once in the Atlas footer).
    private var sharedNote: String? {
        explorer.state.rootID.flatMap { explorer.state.children[$0]?.items }.flatMap(InventoryNodePresentation.sharedFreshness)
    }

    private func open(_ node: InventoryNode?) {
        if let node, node.kind == .directory { browser.navigate(node) }
    }

    /// Rows take the hue of the top-level region they belong to, as the Atlas paints it.
    private func hueIndex(_ row: InventoryExplorerRow) -> Int {
        guard let root = explorer.state.rootID, let top = explorer.state.children[root]?.items else { return 0 }
        var id: Int64? = row.node?.id ?? row.parent, steps = 0
        while let current = id, steps < 64 {
            if let index = top.firstIndex(where: { $0.id == current }) { return index }
            id = explorer.state.node(current)?.parentID; steps += 1
        }
        return 0
    }
}

private struct NavigatorRow: View {
    let row: InventoryExplorerRow
    @ObservedObject var explorer: InventoryExplorerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hueIndex: Int
    let sharedNote: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            switch row.content {
            case .node(let node): entry(node)
            case .loading: placeholder { ProgressView().controlSize(.mini); Text("Loading…") }
            case .more(let loaded, let total):
                placeholder {
                    Button("Show more · \(loaded.formatted()) of \(total.formatted())") { explorer.loadMore(row.parent) }
                        .buttonStyle(.link).onAppear { explorer.loadMore(row.parent) }
                }
            case .limit(let loaded, let total): placeholder { Text("The \(loaded.formatted()) largest of \(total.formatted()) items are listed. Use Largest items for the rest.") }
            case .empty: placeholder { Text("Empty folder").foregroundStyle(.tertiary) }
            case .unavailable(let reason): placeholder { Text("Contents not available · \(reason)") }
            case .failed(let message):
                placeholder {
                    Text("Couldn't load this folder.").help(message)
                    Button("Try Again") { explorer.retry(row.parent) }.buttonStyle(.link)
                }
            }
        }
        .frame(height: 26)
    }

    private func placeholder<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { Color.clear.frame(width: 14, height: 1); content() }.font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private func entry(_ node: InventoryNode) -> some View {
        if node.kind == .directory && node.childCount > 0 {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { explorer.toggle(node.id) } } label: {
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(explorer.state.isExpanded(node.id) ? 90 : 0))
                    .frame(width: 14, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(explorer.state.isExpanded(node.id) ? "Collapse \(node.name)" : "Expand \(node.name)")
        } else { Color.clear.frame(width: 14, height: 1) }
        Image(nsImage: ExplorerIcons.icon(for: node)).resizable().interpolation(.high).frame(width: 18, height: 18)
        Text(node.name.isEmpty ? "Startup Data" : node.name)
            .font(.system(size: 13, weight: node.kind == .directory ? .medium : .regular))
            .foregroundStyle(InventoryMapPlan.weight(node) == nil ? .secondary : .primary)
            .lineLimit(1).truncationMode(.middle).help(node.path)
        Spacer(minLength: 10)
        // Only exceptions to the folder's shared state get a glyph.
        if let glyph = InventoryNavigatorGlyph.glyph(node), InventoryNodePresentation.explorerNote(node) != sharedNote {
            Image(systemName: glyph.rawValue).font(.system(size: 10.5)).foregroundStyle(.secondary)
                .help(InventoryNodePresentation.coverage(node)).accessibilityLabel(InventoryNodePresentation.coverage(node))
        }
        Text(size(node)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
            .help(InventoryNodePresentation.size(InventoryMapPlan.weight(node), node: node, formatter: AtlasText.bytes))
        shareBar(node).frame(width: 46, height: 4)
    }

    private func size(_ node: InventoryNode) -> String {
        InventoryMapPlan.weight(node) == nil && node.status != .lowerBound ? "—"
            : InventoryNodePresentation.compactSize(InventoryMapPlan.weight(node), node: node, formatter: AtlasText.bytes)
    }

    /// Share of the enclosing folder, in the row's region hue.
    private func shareBar(_ node: InventoryNode) -> some View {
        let parent = explorer.state.node(row.parent).flatMap(InventoryMapPlan.weight)
        let share = InventoryMapPlan.weight(node).flatMap { v in parent.flatMap { p in p > 0 ? min(1, Double(v) / Double(p)) : nil } }
        let dark = colorScheme == .dark
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let share, share > 0 {
                    Capsule().fill(Color(hue: AtlasPalette.regionHue(hueIndex), saturation: dark ? 0.5 : 0.45, brightness: dark ? 0.7 : 0.62))
                        .frame(width: max(2, proxy.size.width * share))
                }
            }
        }.opacity(share == nil ? 0 : 1).accessibilityHidden(true)
    }
}

/// Actions on an entry, shared by the Navigator, the technical table and the Inspector.
@MainActor struct InventoryActions {
    let browser: InventoryBrowserModel
    let node: InventoryNode

    @ViewBuilder var menu: some View {
        if node.kind == .directory { Button("Open") { browser.navigate(node) } }
        Button("Reveal in Finder") { reveal() }.disabled(browser.livePath(node) == nil)
        Button("Copy Path") { copy() }
    }

    func reveal() { browser.revealInFinder(node) }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.path, forType: .string) }
}

/// The Inspector: what is selected (or, with nothing selected, the folder being shown). A quiet column
/// beside the Atlas and Navigator, not a card; it can be hidden.
struct InventoryInspectorView: View {
    @ObservedObject var browser: InventoryBrowserModel
    @ObservedObject var explorer: InventoryExplorerController
    @ObservedObject private var cleanup: CleanupInspectorController
    @ObservedObject private var migration: MigrationReadinessController
    var reviewSubject: InventoryNode? = nil
    var showsTrash = true
    var usesQueueEvidence = false
    @ViewState private var showingAccounting = false
    @ViewState private var showingCleanup = false

    init(browser: InventoryBrowserModel, explorer: InventoryExplorerController, reviewSubject: InventoryNode? = nil, showsTrash: Bool = true, usesQueueEvidence: Bool = false) {
        self.browser = browser; self.explorer = explorer
        self.reviewSubject = reviewSubject; self.showsTrash = showsTrash; self.usesQueueEvidence = usesQueueEvidence
        _cleanup = ObservedObject(wrappedValue: browser.cleanup)
        _migration = ObservedObject(wrappedValue: browser.migration)
    }

    private var subject: (node: InventoryNode, isSelection: Bool)? {
        if let reviewSubject { return (reviewSubject, true) }
        if let id = explorer.selection, let node = explorer.state.node(id) { return (node, true) }
        if let root = explorer.state.rootID, let node = explorer.state.node(root) { return (node, false) }
        return nil
    }

    var body: some View {
        ScrollView {
            if let subject {
                let node = subject.node
                let parent = node.parentID.flatMap { explorer.state.node($0) }
                // A detected disk image is named by Migration Readiness ("Docker Desktop disk image"), not by its extension
                // alone (".raw" would otherwise read as a camera raw photo).
                let type = migration.item(node.id)?.title ?? (node.kind == .file ? UTType(filenameExtension: (node.name as NSString).pathExtension)?.localizedDescription : nil)
                let info = InventoryInspectorPresentation(node: node, parent: parent, typeDescription: type, formatter: AtlasText.bytes)
                VStack(alignment: .leading, spacing: StorageDesign.sectionGap) {
                    identity(node, info: info, isSelection: subject.isSelection)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Indexed size").font(.caption).foregroundStyle(.secondary)
                        // The "Previously measured" caption below states an earlier size once; partial values keep their prefix.
                        Text(InventoryNodePresentation.compactSize(InventoryMapPlan.weight(node), node: node, formatter: AtlasText.bytes)).font(.title2.weight(.semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                        if let share = info.shareOfParent, let text = info.shareText { shareView(share, text: text) }
                        Text(info.measurement).font(.caption).foregroundStyle(.secondary)
                    }
                    actions(node)
                    if let item = migration.item(node.id) {
                        Divider()
                        MigrationReadinessInspectorSection(item: item, filesystem: migration.report?.filesystem)
                            .task(id: node.id) { await migration.recheck(node.id) }
                    }
                    largestContents(node)
                    Divider()
                    if browser.allowsCleanup && (subject.isSelection || node.parentID != nil) {
                        cleanupSummary(node)
                        InspectorDisclosure("Cleanup & safety", isExpanded: $showingCleanup) {
                            CleanupInspectorSection(cleanup: cleanup, node: node, showsTrash: showsTrash)
                        }
                    } else if browser.allowsCleanup {
                        Text("Choose a folder or file to see its cleanup review options.").font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    InspectorDisclosure("Storage details", isExpanded: $showingAccounting) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            row("Indexed allocation", info.allocated)
                            row("Logical size", info.logical)
                            if let contents = info.contents { row("Contains", contents) }
                            if let date = info.measured { row("Measured", date.formatted(date: .abbreviated, time: .shortened)) }
                        }
                        if let explanation = info.explanation { Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        Text("Indexed sizes may include shared APFS storage. They are not guaranteed recoverable space.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(StorageDesign.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(node.id)
            } else {
                ContentUnavailableView("Choose a folder or file", systemImage: "cursorarrow.click", description: Text("Select it in the map or Navigator to see its size and review options."))
                    .padding(16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("inventory.inspector")
        .onAppear { if browser.allowsCleanup && !usesQueueEvidence { cleanup.update(subject?.node) { explorer.state.node($0) != nil } } }
        .onChange(of: subject.map { CleanupInspectorController.fingerprint($0.node) }) { _, _ in
            if browser.allowsCleanup && !usesQueueEvidence { cleanup.update(subject?.node) { explorer.state.node($0) != nil } }
        }
        .onChange(of: subject?.node.id) { _, _ in showingAccounting = false; showingCleanup = false }
        .onChange(of: showingCleanup) { _, shown in
            if !shown { cleanup.cancelTrashConfirmation(); cleanup.closePreview() }
        }
        .onChange(of: browser.revision) { _, _ in if browser.allowsCleanup && !usesQueueEvidence { cleanup.inventoryChanged(subject?.node) } }
    }

    private func identity(_ node: InventoryNode, info: InventoryInspectorPresentation, isSelection: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isSelection ? "Selection" : "Current folder").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: ExplorerIcons.icon(for: node)).resizable().interpolation(.high).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name).font(.title3.weight(.semibold)).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    Text(info.kind).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(info.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(info.path)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).font(.callout.monospacedDigit()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shareView(_ share: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: share).progressViewStyle(.linear).tint(.accentColor)
                .accessibilityLabel("Share of parent").accessibilityValue(text)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }.padding(.top, 7)
    }

    @ViewBuilder private func largestContents(_ node: InventoryNode) -> some View {
        if node.kind == .directory, let children = explorer.state.children[node.id]?.items, !children.isEmpty {
            let largest = Array(children.sorted { (InventoryMapPlan.weight($0) ?? -1) > (InventoryMapPlan.weight($1) ?? -1) }.prefix(3))
            VStack(alignment: .leading, spacing: 9) {
                Text("Largest loaded items").font(.subheadline.weight(.semibold))
                ForEach(largest) { child in
                    Button {
                        if reviewSubject != nil { browser.revealReviewCandidate(child) }
                        else { explorer.selection = child.id }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(child.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 3)
                            Text(InventoryNodePresentation.compactSize(InventoryMapPlan.weight(child), node: child, formatter: AtlasText.bytes)).monospacedDigit().lineLimit(1)
                        }.font(.caption).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(child.path)
                }
                Text(largest.contains { $0.status == .stale } ? "From the currently loaded folder page. Some sizes are from the last completed measurement." : "From the currently loaded folder page.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func cleanupSummary(_ node: InventoryNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cleanup review").font(.subheadline.weight(.semibold))
            if cleanup.inspecting == node.id && cleanup.inspection?.nodeID != node.id {
                HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("Checking this item…").font(.callout).foregroundStyle(.secondary) }
            } else if let inspection = cleanup.inspection, inspection.nodeID == node.id,
                      let shown = CleanupInspectorPresentation(inspection, formatter: AtlasText.bytes) {
                Label(shown.statusTitle, systemImage: shown.status == .protected ? "lock" : shown.status == .reviewCandidate ? "checklist" : "info.circle")
                    .font(.callout.weight(.medium))
                Text(shown.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let reason = shown.reasons.first { Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            } else {
                Text("No automatic cleanup suggestion for this item.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ node: InventoryNode) -> some View {
        let actions = InventoryActions(browser: browser, node: node)
        return VStack(alignment: .leading, spacing: 10) {
            if node.kind == .directory && node.id != explorer.state.rootID {
                Button {
                    browser.mode = .explorer; browser.navigate(node)
                } label: { Label("Explore Folder", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
            }
            HStack(spacing: 12) {
                Button { actions.reveal() } label: { Label("Finder", systemImage: "folder") }
                    .help("Reveal in Finder")
                    .disabled(browser.livePath(node) == nil)
                Button { actions.copy() } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("Copy path").help("Copy full path")
            }.buttonStyle(.borderless).font(.callout)
        }
    }
}
