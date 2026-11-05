import SwiftUI
import AppKit

// The Living Tree's default presentation: the Structured Explorer (layout, scale, labels and hit testing in
// SourcesShared/StructuredExplorer.swift). It draws the Living Tree controller's model and the explorer's shared
// selection, so the Navigator, Atlas and Inspector always show the same folder; double-click and Return open a folder
// (the app's navigation), Esc and Up go to the enclosing folder. Pointer input is the Living Tree's input layer and
// gesture interpretation: scrolling and pinching zoom about the pointer, dragging pans, nothing orbits. It redraws only
// when the tree, the camera, the selection or the hover changes; the layout is recomputed only when the tree, the
// number of levels, or a selection that is not shown changes.

/// Camera, viewport and the cached layout; kept outside the view so pointer moves do not rebuild the layout.
@MainActor final class StructuredExplorerState: ObservableObject {
    @Published var camera = StructuredExplorerCamera()
    @Published var filter = StructuredExplorerFilter()
    @Published private(set) var isolatedRoot: LivingTreeKey?
    /// Detected Migration Readiness items as catalog chains (root first, item last), for the Migration Review filter.
    @Published private(set) var migrationTargets: [[Int64]] = []
    private var migrationRevision = 0
    private(set) var isolationSelection: Int64?
    private var isolationBase: LivingTreeKey?
    var viewport = CGSize(width: 900, height: 520)
    private var baseline: (revision: Int, depth: Int, layout: StructuredExplorerLayout, stamp: Int)?
    private var retained: (key: LivingTreeKey, fullChain: Bool, layout: StructuredExplorerLayout, stamp: Int)?
    private struct VisibilityKey: Equatable {
        let layout: Int, filter: StructuredExplorerFilter, selection: LivingTreeKey?, migration: Int
    }
    private var visibilityCache: (key: VisibilityKey, value: StructuredExplorerVisibility)?
    private(set) var visibilityEvaluations = 0
    /// The last drawn layout and transform (where a folder was on screen when the tree moves to it).
    private(set) var drawn: (root: LivingTreeKey, layout: StructuredExplorerLayout, transform: StructuredExplorerTransform)?
    private var previousDrawn: (root: LivingTreeKey, layout: StructuredExplorerLayout, transform: StructuredExplorerTransform)?
    private(set) var layouts = 0, lastLayoutSeconds = 0.0
    /// Which built layout `layout(...)` last returned (labels are cached against it).
    private var current = 0
    private struct LabelKey: Equatable {
        let layout: Int, transform: StructuredExplorerTransform, size: CGSize, selected: LivingTreeKey?, hovered: LivingTreeKey?
        let filter: StructuredExplorerFilter, filtered: Bool
    }
    private var placed: (key: LabelKey, labels: [StructuredExplorerLabel])?
    private(set) var labelPlacements = 0

    /// The layout for this tree and level count. A selection that is already shown never re-lays the tree out; one that
    /// is not (beyond the per-folder limit or the shown levels) is laid out on its chain.
    func layout(_ model: LivingTreeModel, revision: Int, depth: Int, selection: LivingTreeKey?) -> StructuredExplorerLayout {
        let root = isolatedRoot.flatMap { model[$0]?.isFolder == true ? $0 : nil } ?? model.rootKey
        if baseline?.revision != revision || baseline?.depth != depth || baseline?.layout.rootKey != root {
            baseline = (revision, depth, build(model, depth: depth, selection: nil), layouts)
            retained = nil
        }
        let base = baseline!
        guard let selection, base.layout.index[selection] == nil, model[selection] != nil else { current = base.stamp; return base.layout }
        let fullChain = filter.isActive || isolatedRoot != nil
        if retained?.key != selection || retained?.fullChain != fullChain { retained = (selection, fullChain, build(model, depth: depth, selection: selection), layouts) }
        current = retained!.stamp
        return retained!.layout
    }

    /// Labels for the layout `layout(...)` just returned, placed once per drawn state. The view's body re-evaluates on
    /// every pointer move (the hover lens follows the pointer); only a change of hover, selection, camera, canvas or tree
    /// places them again.
    func labels(_ layout: StructuredExplorerLayout, model: LivingTreeModel, transform: StructuredExplorerTransform, size: CGSize,
                selected: LivingTreeKey?, hovered: LivingTreeKey?, visibility: StructuredExplorerVisibility? = nil) -> [StructuredExplorerLabel] {
        let key = LabelKey(layout: current, transform: transform, size: size, selected: selected, hovered: hovered, filter: filter, filtered: visibility != nil)
        if let placed, placed.key == key { return placed.labels }
        let labels = layout.labels(model: model, transform: transform, size: size, selected: selected, hovered: hovered,
                                   detail: StructuredExplorerText.size, measure: StructuredExplorerPainter.measure,
                                   allowed: visibility?.visible, preferred: visibility?.prominent)
        placed = (key, labels); labelPlacements += 1
        return labels
    }
    private func build(_ model: LivingTreeModel, depth: Int, selection: LivingTreeKey?) -> StructuredExplorerLayout {
        let started = Date()
        let layout = StructuredExplorerLayout(model: model, depth: depth, keep: selection, root: isolatedRoot,
                                             keepFullAncestry: filter.isActive || isolatedRoot != nil)
        lastLayoutSeconds = Date().timeIntervalSince(started); layouts += 1
        return layout
    }
    func noteDrawn(_ layout: StructuredExplorerLayout, _ transform: StructuredExplorerTransform) {
        if let drawn, drawn.root != layout.rootKey { previousDrawn = drawn }
        drawn = (layout.rootKey, layout, transform)
    }
    func drawnBeforeRootChange(from root: LivingTreeKey) -> (root: LivingTreeKey, layout: StructuredExplorerLayout, transform: StructuredExplorerTransform)? {
        if let drawn, drawn.root == root { return drawn }
        return previousDrawn?.root == root ? previousDrawn : nil
    }
    func transform(_ layout: StructuredExplorerLayout) -> StructuredExplorerTransform { camera.transform(bounds: layout.bounds, size: viewport) }

    func visibility(_ layout: StructuredExplorerLayout, model: LivingTreeModel, selection: LivingTreeKey?) -> StructuredExplorerVisibility {
        let key = VisibilityKey(layout: current, filter: filter, selection: selection, migration: filter.migrationReview ? migrationRevision : 0)
        if let visibilityCache, visibilityCache.key == key { return visibilityCache.value }
        let value = StructuredExplorerVisibility(layout: layout, model: model, filter: filter, selection: selection, migrationTargets: migrationTargets)
        visibilityCache = (key, value); visibilityEvaluations += 1
        return value
    }

    /// Replaces the Migration Review targets (a new report). Unchanged targets keep the cached visibility.
    func setMigrationTargets(_ targets: [[Int64]]) {
        guard targets != migrationTargets else { return }
        migrationTargets = targets; migrationRevision += 1
        if targets.isEmpty, filter.migrationReview { filter.migrationReview = false }
    }

    @discardableResult func isolate(_ key: LivingTreeKey, model: LivingTreeModel, selection: Int64?) -> Bool {
        guard key.nodeID != nil, model[key]?.isFolder == true, key != (isolatedRoot ?? model.rootKey) else { return false }
        if isolatedRoot == nil { isolationSelection = selection; isolationBase = model.rootKey }
        isolatedRoot = key; camera = StructuredExplorerCamera()
        return true
    }

    @discardableResult func exitIsolation() -> Int64? {
        let selection = isolationSelection
        isolatedRoot = nil; isolationSelection = nil; isolationBase = nil
        camera = StructuredExplorerCamera()
        return selection
    }

    @discardableResult func resetFilters() -> Int64? {
        filter = StructuredExplorerFilter()
        return exitIsolation()
    }

    @discardableResult func upIsolation(model: LivingTreeModel) -> LivingTreeKey? {
        guard let root = isolatedRoot else { return nil }
        guard let parent = model[root]?.parent else { exitIsolation(); return model.rootKey }
        if parent == model.rootKey { exitIsolation() }
        else { isolatedRoot = parent; camera = StructuredExplorerCamera() }
        return parent
    }

    func reconcileIsolation(_ model: LivingTreeModel) {
        if let isolatedRoot, isolationBase != model.rootKey || model[isolatedRoot]?.isFolder != true { exitIsolation() }
    }
}

/// Colours: category tones from the Living Tree's colouring, adapted to the appearance; orange marks the selection.
struct StructuredExplorerPalette {
    let dark: Bool
    var ground: Color { dark ? Color(red: 0.072, green: 0.078, blue: 0.087) : Color(red: 0.975, green: 0.972, blue: 0.962) }
    var ink: Color { dark ? Color(white: 0.93) : Color(white: 0.13) }
    var secondary: Color { dark ? Color(white: 0.64) : Color(white: 0.40) }
    var plate: Color { dark ? Color(white: 0.115).opacity(0.9) : Color.white.opacity(0.92) }
    var plateEdge: Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.11) }
    static let accent = Color(red: 0.98, green: 0.60, blue: 0.14)
    /// Migration Review rings: distinct from the orange selection and from the category tones.
    static let review = Color(red: 0.56, green: 0.44, blue: 0.98)

    func tone(_ key: LivingTreeKey, coloring: LivingTreeColoring) -> Color {
        let neutral = dark ? AtlasTone(hue: 0.60, saturation: 0.10, brightness: 0.80) : AtlasTone(hue: 0.60, saturation: 0.14, brightness: 0.50)
        var tone = neutral
        if let hue = coloring[key] {
            let c = hue.category.tone, t = LivingTreePainter.strength(hue.purity)
            tone = AtlasTone(hue: c.hue, saturation: neutral.saturation + (c.saturation - neutral.saturation) * t, brightness: neutral.brightness + (c.brightness - neutral.brightness) * t)
        }
        // Tones are tuned for a dark ground; on a light one they are deepened to keep their contrast.
        return dark ? LivingTreePainter.color(tone, opacity: 1) : Color(hue: tone.hue, saturation: min(1, tone.saturation * 1.15 + 0.05), brightness: tone.brightness * 0.72)
    }
}

enum StructuredExplorerText {
    static func size(_ element: LivingTreeElement) -> String {
        if let node = element.node { return InventoryNodePresentation.compactSize(element.bytes, node: node, formatter: AtlasText.bytes) }
        return element.bytes.map(AtlasText.bytes) ?? "Size unknown"
    }
    static func share(_ element: LivingTreeElement, model: LivingTreeModel) -> String? {
        guard let parent = element.parent.flatMap({ model[$0] }), let share = StructuredExplorerScale.share(element.bytes, of: parent.bytes), element.bytes != nil else { return nil }
        let percent = share > 0 && share < 0.001 ? "less than 0.1%" : share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)))
        return "\(percent) of \(parent.role == .trunk && parent.node?.parentID == nil ? "Startup Data" : parent.name)"
    }
    /// What VoiceOver reads: name (with its folder when the name repeats), kind, size, share, level and path context.
    static func spoken(_ key: LivingTreeKey, layout: StructuredExplorerLayout, model: LivingTreeModel, selected: Bool) -> String {
        guard let element = model[key] else { return "" }
        var parts = [LivingTreeText.spoken(element, glow: nil)]
        if let share = share(element, model: model) { parts.append(share) }
        if let node = layout[key] { parts.append(node.ring == 0 ? "centre" : "level \(node.ring + node.elided)") }
        if layout.repeatedNames.contains(element.name), let path = element.node?.path { parts.append("in \((path as NSString).deletingLastPathComponent)") }
        if selected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}

/// Applies an AtlasZoom interpolated by `progress`, animatable so SwiftUI drives the frames of a recentre.
private struct StructuredExplorerZoomEffect: ViewModifier, Animatable {
    var zoom: AtlasZoom
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let current = zoom.interpolated(progress)
        content.scaleEffect(current.scale, anchor: .topLeading).offset(current.offset)
    }
}

struct StructuredExplorerView: View {
    @ObservedObject var browser: InventoryBrowserModel
    @ObservedObject var explorer: InventoryExplorerController
    @ObservedObject var tree: LivingTreeController
    var showsSelectionContext = true
    @ObservedObject private var state: StructuredExplorerState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.livingTreeInteractive) private var interactive
    /// Levels shown below the centre, remembered.
    @AppStorage("inventory.structuredExplorer.depth", store: ViewerStore.viewPreferences) private var depth = StructuredExplorerLayout.defaultDepth
    @State private var hover: LivingTreeKey?
    @State private var pointer: CGPoint?
    @State private var gesture = LivingTreeGesture()
    @State private var showingHelp = false
    @State private var zoom = AtlasZoom.identity
    @State private var zoomProgress = 1.0
    @State private var fade = 1.0
    @State private var shownRoot: LivingTreeKey?
    @FocusState private var focused: Bool

    init(browser: InventoryBrowserModel, explorer: InventoryExplorerController, tree: LivingTreeController, showsSelectionContext: Bool = true) {
        self.browser = browser; self.explorer = explorer; self.tree = tree; self.showsSelectionContext = showsSelectionContext
        _state = ObservedObject(wrappedValue: browser.structuredExplorer)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { proxy in
                content(size: proxy.size)
                    .modifier(StructuredExplorerZoomEffect(zoom: zoom, progress: zoomProgress))
                    .opacity(fade)
                    .clipped()
                    .onAppear { state.viewport = proxy.size }
                    .onChange(of: proxy.size) { _, size in state.viewport = size }
            }
            Divider()
            footer
        }
        .background(StructuredExplorerPalette(dark: scheme == .dark).ground)
        .accessibilityIdentifier("inventory.structuredExplorer")
        .onAppear { sync(); shownRoot = tree.model?.rootKey }
        .onChange(of: browser.directory?.id) { _, _ in sync() }
        .onChange(of: browser.status?.updatedAt) { _, _ in tree.inventoryChanged() }
        .onChange(of: browser.revision) { _, _ in tree.inventoryChanged() }
        .onChange(of: explorer.revealRequest) { _, request in if let request { tree.reveal(request.node, serial: request.serial) } }
        .onChange(of: explorer.selection) { _, id in
            if let override = tree.focusOverride, override.restFolder != id { tree.focusOverride = nil }
            if let root = state.isolatedRoot, let model = tree.model,
               let key = selectionKey(model), !model.ancestry(of: key).contains(root) { state.exitIsolation() }
            revealSelection()
        }
        .onChange(of: tree.revision) { _, _ in if let model = tree.model { state.reconcileIsolation(model) }; transition() }
        .onChange(of: depth) { _, _ in state.camera = StructuredExplorerCamera() }
        .onChange(of: state.filter) { _, _ in hover = nil; revealSelection() }
        .onChange(of: state.isolatedRoot) { _, _ in hover = nil }
    }

    private func sync() {
        guard let folder = browser.directory else { return }
        if tree.model?.root.id != folder.id, state.isolatedRoot != nil { state.exitIsolation() }
        tree.show(root: folder, trail: browser.breadcrumbs)
        if let request = explorer.revealRequest, request.folder == folder.id { tree.reveal(request.node, serial: request.serial) }
    }

    // MARK: Content

    @ViewBuilder private func content(size: CGSize) -> some View {
        if let model = tree.model {
            let selection = selectionKey(model)
            let layout = state.layout(model, revision: tree.revision, depth: depth, selection: selection)
            canvas(model: model, layout: layout, selection: selection, size: size)
        } else {
            switch tree.phase {
            case .failed(let message): placeholder("The folder structure could not be read · \(message)")
            default: placeholder("Reading the folder structure…", spinning: true)
            }
        }
    }

    private func placeholder(_ text: String, spinning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.small) }
            Text(text).foregroundStyle(.secondary)
        }.font(.callout).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canvas(model: LivingTreeModel, layout: StructuredExplorerLayout, selection: LivingTreeKey?, size: CGSize) -> some View {
        let t = state.camera.transform(bounds: layout.bounds, size: size)
        let _ = state.noteDrawn(layout, t)
        let shownSelection = selection.flatMap { layout.shownKey(for: $0, in: model) }
        let visibility = state.visibility(layout, model: model, selection: selection)
        let labels = state.labels(layout, model: model, transform: t, size: size, selected: shownSelection, hovered: hover, visibility: visibility)
        let palette = StructuredExplorerPalette(dark: scheme == .dark)
        let coloring = tree.coloring
        // Bound virtual children at high depth, while always exposing the current selection. The Navigator lists all.
        let visibleNodes = layout.nodes.filter { visibility.visible.contains($0.key) }
        let accessibleNodes = Array(visibleNodes.prefix(160)) + visibleNodes.dropFirst(160).filter { $0.key == shownSelection }
        return ZStack(alignment: .topLeading) {
            Canvas(rendersAsynchronously: false) { context, _ in
                StructuredExplorerPainter(layout: layout, model: model, coloring: coloring, palette: palette)
                    .paint(&context, transform: t, size: size, selected: shownSelection, exact: selection == shownSelection, hovered: hover, labels: labels, visibility: visibility)
            }
            .id(state.filter)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.filter)
            .allowsHitTesting(false)
            if model[model.rootKey]?.children.isEmpty ?? true {
                Text("Nothing indexed inside this folder yet.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 24)
            }
            if interactive {
                LivingTreeInputLayer(contextMenu: { p in contextMenu(at: p, model: model, layout: layout, transform: t, labels: labels, visibility: visibility) }) {
                    event in handle(event, model: model, layout: layout, transform: t, labels: labels)
                }
            }
            if visibility.noMatches {
                HStack(spacing: 8) {
                    if state.filter.migrationReview {
                        Text("No migration review items under this folder in the loaded view.")
                        Button("Turn Off Migration Review") { state.filter.migrationReview = false }
                    } else {
                        Text("No folders meet this size in the loaded view.")
                        Button("Show All") { state.filter.minimumBytes = 0 }
                    }
                }.font(.caption).padding(8).background(palette.plate, in: RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 8)
            } else if state.isolatedRoot != nil, model[layout.rootKey]?.children.isEmpty == true {
                VStack(spacing: 6) {
                    Text(model[layout.rootKey]?.expanded == true ? "No additional indexed items in this folder." : "This folder's descendants are not loaded in the current view.")
                    if model[layout.rootKey]?.expanded != true, let node = model[layout.rootKey]?.node {
                        Button("Explore indexed folder") { state.exitIsolation(); browser.navigate(node) }
                    }
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 12)
            }
            sizeKey(model: model, root: layout.rootKey, transform: t, palette: palette).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).allowsHitTesting(false)
            lens(model: model, size: size)
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            if press.modifiers.contains(.option) || press.modifiers.contains(.shift) {
                let step = min(size.width, size.height) * 0.14
                switch press.key {
                case .upArrow: pan(CGVector(dx: 0, dy: step), layout)
                case .downArrow: pan(CGVector(dx: 0, dy: -step), layout)
                case .leftArrow: pan(CGVector(dx: step, dy: 0), layout)
                default: pan(CGVector(dx: -step, dy: 0), layout)
                }
                return .handled
            }
            let move: StructuredExplorerLayout.Move
            switch press.key {
            case .upArrow: move = .outward
            case .downArrow: move = .inward
            case .leftArrow: move = .previousSibling
            default: move = .nextSibling
            }
            guard let next = layout.move(move, from: shownSelection, allowed: visibility.visible) else { return .ignored }
            choose(next, model: model)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-_0fF")) { press in
            switch press.characters {
            case "+", "=": zoomBy(1.5, at: nil, layout)
            case "-", "_": zoomBy(1 / 1.5, at: nil, layout)
            case "0": resetView()
            default: frameSelection(layout, model: model)
            }
            return .handled
        }
        .onKeyPress(.return) { if let shownSelection { open(shownSelection, model: model) }; return .handled }
        .onKeyPress(.escape) { if showingHelp { showingHelp = false } else { goUp() }; return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Structured Explorer of \(browser.directory.map(browser.displayName) ?? "the current folder")")
        .accessibilityValue("\(filterStatus(visibility)), \(layout.depth) levels, zoom \(LivingTreeView.percent(state.camera.zoom)), \(state.filter.presentation.rawValue), focus \(state.filter.focus.rawValue)")
        .accessibilityHint("Arrow keys move: up to the largest item inside, down to the enclosing one, left and right around the ring. Return explores a folder; Escape goes to the enclosing folder; plus and minus zoom; 0 resets the view.")
        .accessibilityZoomAction { action in
            switch action.direction {
            case .zoomIn: zoomBy(1.5, at: nil, layout)
            case .zoomOut: zoomBy(1 / 1.5, at: nil, layout)
            @unknown default: break
            }
        }
        .accessibilityChildren {
            ForEach(accessibleNodes, id: \.key) { node in
                accessibleNode(node, layout: layout, model: model, transform: t, selected: node.key == shownSelection, review: visibility.reviewPaths.contains(node.key))
            }
        }
    }

    @ViewBuilder private func accessibleNode(_ node: StructuredExplorerLayout.Node, layout: StructuredExplorerLayout,
                                model: LivingTreeModel, transform: StructuredExplorerTransform, selected: Bool, review: Bool = false) -> some View {
        let diameter = max(CGFloat(12), layout.screenRadius(node, transform) * 2)
        let label = StructuredExplorerText.spoken(node.key, layout: layout, model: model, selected: selected) + (review ? ", on a migration review path" : "")
        let traits: AccessibilityTraits = selected ? [.isButton, .isSelected] : .isButton
        let base = Circle().frame(width: diameter, height: diameter).position(transform.apply(node.point))
            .accessibilityLabel(label).accessibilityAddTraits(traits)
            .accessibilityAction { choose(node.key, model: model) }
            .accessibilityAction(named: "Explore") { open(node.key, model: model) }
            .accessibilityAction(named: "Up one level") { goUp() }
        let actions = base
            .accessibilityAction(named: "Clear Focus / Isolation") { clearFocus() }
            .accessibilityHint(model[node.key]?.isFolder == true && node.key != layout.rootKey ? "Explore shows what is inside" : "")
        if model[node.key]?.isFolder == true && node.key.nodeID != nil {
            let folderActions = actions
                .accessibilityAction(named: "Show Path to Root") { pathFocus(node.key, model: model, mode: .path) }
                .accessibilityAction(named: "Focus on Selection") { pathFocus(node.key, model: model, mode: .subtree) }
            if node.key != layout.rootKey {
                folderActions.accessibilityAction(named: "Isolate This Path") { isolate(node.key, model: model) }
            } else { folderActions }
        } else { actions }
    }

    // MARK: Camera

    private func zoomBy(_ factor: Double, at point: CGPoint?, _ layout: StructuredExplorerLayout) { state.camera.zoom(by: factor, at: point, bounds: layout.bounds, size: state.viewport) }
    private func pan(_ delta: CGVector, _ layout: StructuredExplorerLayout) { state.camera.pan(by: delta, bounds: layout.bounds, size: state.viewport) }
    private func resetView() { state.camera = StructuredExplorerCamera() }
    /// Fit: the selection's branch when one is selected, otherwise everything shown.
    private func frameSelection(_ layout: StructuredExplorerLayout, model: LivingTreeModel) {
        guard let key = selectionKey(model).flatMap({ layout.shownKey(for: $0, in: model) }), key != layout.rootKey, let rect = layout.subtreeBounds(key) else { resetView(); return }
        state.camera.frame(rect, bounds: layout.bounds, size: state.viewport)
    }
    /// A selection made elsewhere (Navigator, Atlas, keyboard, search) is brought on screen; one already visible stays.
    private func revealSelection() {
        guard let model = tree.model, let key = selectionKey(model) else { return }
        let layout = state.layout(model, revision: tree.revision, depth: depth, selection: key)
        guard let shown = layout.shownKey(for: key, in: model), let node = layout[shown] else { return }
        state.camera.reveal(CGRect(x: node.point.x - node.radius, y: node.point.y - node.radius, width: 2 * node.radius, height: 2 * node.radius), bounds: layout.bounds, size: state.viewport)
    }

    // MARK: Input

    private func handle(_ event: LivingTreeInputView.Event, model: LivingTreeModel, layout: StructuredExplorerLayout, transform t: StructuredExplorerTransform, labels: [StructuredExplorerLabel]) {
        let visibility = state.visibility(layout, model: model, selection: selectionKey(model))
        let hit = { (p: CGPoint) in filteredHit(p, layout: layout, transform: t, labels: labels, visibility: visibility) }
        let opens = { (key: LivingTreeKey) -> Bool in
            guard key != model.rootKey, let element = model[key] else { return false }
            return element.role == .rest || element.node?.kind == .directory
        }
        var actions = [LivingTreeGesture.Action]()
        switch event {
        case .down(let p, let clicks, let modifiers):
            focused = true
            actions = gesture.down(at: p, clickCount: clicks, modifiers: modifiers, target: hit(p), opens: opens)
        case .dragged(let p): actions = gesture.dragged(to: p)
        case .up(let p, let clicks): actions = gesture.up(at: p, clickCount: clicks, target: gesture.isDragging ? nil : hit(p))
        case .moved(let p):
            pointer = p
            guard !gesture.isDragging else { return }
            let next = p.flatMap(hit)
            if next != hover { hover = next }
        case .scroll(let delta, let precise, let momentum, let modifiers, let p):
            if let action = LivingTreeGesture.scroll(delta, precise: precise, modifiers: modifiers, at: p, momentum: momentum) { actions = [action] }
        case .magnify(let m, let p): if let action = LivingTreeGesture.magnify(m, at: p) { actions = [action] }
        case .smartMagnify(let p): actions = [.toggleZoom(at: p)]
        case .rotate: break
        case .command(let command):
            switch command {
            case .zoomIn: zoomBy(1.5, at: nil, layout)
            case .zoomOut: zoomBy(1 / 1.5, at: nil, layout)
            case .fit, .focusSelection: frameSelection(layout, model: model)
            case .reset: resetView()
            }
        }
        for action in actions {
            switch action {
            case .select(let key): choose(key, model: model)
            case .open(let key): open(key, model: model)
            case .focus(let key): choose(key, model: model); if let rect = layout.subtreeBounds(key) { state.camera.frame(rect, bounds: layout.bounds, size: state.viewport) }
            case .pan(let d): pan(d, layout)
            case .zoom(let factor, let p, _): zoomBy(factor, at: p, layout)
            case .toggleZoom(let p): if state.camera.zoom > 1.05 { resetView() } else { zoomBy(2.5, at: p, layout) }
            case .orbit: break
            case .dragBegan: hover = nil
            case .dragEnded: if let pointer { hover = hit(pointer) }
            }
        }
    }

    // MARK: Selection and navigation (the Living Tree's semantics)

    private func selectionKey(_ model: LivingTreeModel) -> LivingTreeKey? {
        if let override = tree.focusOverride, model[override] != nil, override.restFolder == explorer.selection { return override }
        guard let id = explorer.selection else { return nil }
        return model.displayKey(forNode: id) { explorer.state.node($0)?.parentID }
    }

    /// Selects the entry (the Navigator, Atlas and Inspector follow). Grouped small items select their folder and open
    /// it in the Navigator, where every item is listed.
    private func choose(_ key: LivingTreeKey, model: LivingTreeModel) {
        let chain = model.ancestry(of: key).dropFirst().dropLast().compactMap { model[$0]?.node }
        switch key {
        case .node:
            guard let node = model[key]?.node else { return }
            tree.focusOverride = nil
            explorer.select(node, through: Array(chain))
        case .rest(let folder):
            guard let node = model[.node(folder)]?.node else { return }
            explorer.select(node, through: Array(chain.dropLast()), openTarget: true)
            tree.focusOverride = key
        }
    }

    /// Double-click or Return: the folder becomes the centre (the app's folder navigation); grouped items open their folder.
    private func open(_ key: LivingTreeKey, model: LivingTreeModel) {
        if state.isolatedRoot != nil, model[key]?.isFolder == true, key != state.isolatedRoot { isolate(key, model: model); return }
        switch key {
        case .node:
            guard let node = model[key]?.node, node.kind == .directory, key != model.rootKey else { return }
            browser.navigate(node)
        case .rest(let folder):
            guard .node(folder) != model.rootKey, let node = model[.node(folder)]?.node else { return }
            browser.navigate(node)
        }
    }

    private func goUp() {
        if let root = state.isolatedRoot, let model = tree.model {
            if root == model.rootKey { state.exitIsolation(); return }
            else if let parent = state.upIsolation(model: model) { choose(parent, model: model); return }
        }
        guard let folder = browser.directory, let parent = folder.parentID, let node = browser.breadcrumbs.first(where: { $0.id == parent }) else { return }
        browser.navigate(node)
    }

    /// Exploring grows the new centre out of the disc it was; going up starts enlarged around the folder you left. The
    /// camera returns to the fit, so the new folder's whole hierarchy is framed. Reduce Motion cross-fades.
    private func transition() {
        guard let model = tree.model else { return }
        defer { shownRoot = model.rootKey }
        guard let old = shownRoot, old != model.rootKey else { return }
        hover = nil
        let previous = state.drawnBeforeRootChange(from: old)
        state.camera = StructuredExplorerCamera()
        let size = state.viewport
        var start: AtlasZoom?
        if AtlasZoom.animates(reduceMotion: reduceMotion) {
            if let previous, previous.root == old, let node = previous.layout[model.rootKey] {
                // Entering: the new centre was this disc.
                let r = max(node.radius, 12) * previous.transform.scale
                let c = previous.transform.apply(node.point)
                start = AtlasZoom.start(entering: true, rect: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), in: size)
            } else {
                // Leaving: the folder left is a disc in the parent's layout.
                let layout = state.layout(model, revision: tree.revision, depth: depth, selection: nil)
                if let node = layout[old] {
                    let t = state.transform(layout), r = max(node.radius, 12) * t.scale, c = t.apply(node.point)
                    start = AtlasZoom.start(entering: false, rect: CGRect(x: c.x - r * 3, y: c.y - r * 3, width: r * 6, height: r * 6), in: size)
                }
            }
        }
        if let start {
            zoom = start; zoomProgress = 0; fade = 0.35
            withAnimation(.smooth(duration: 0.42)) { zoomProgress = 1; fade = 1 }
        } else {
            zoom = .identity; zoomProgress = 1; fade = 0.5
            withAnimation(.easeOut(duration: 0.18)) { fade = 1 }
        }
    }

    // MARK: Overlays

    /// Hovered element: name, size and notes, beside the pointer; never moves anything.
    @ViewBuilder private func lens(model: LivingTreeModel, size: CGSize) -> some View {
        if let hover, let pointer, let element = model[hover] {
            let lines = LivingTreeText.lens(element, model: model, glow: nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(lines.value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if let share = StructuredExplorerText.share(element, model: model) { Text(share).font(.caption).foregroundStyle(.secondary) }
                if let path = element.node?.path { Text(path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                ForEach(lines.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: 300, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .offset(x: min(max(4, pointer.x + 16), max(4, size.width - 310)), y: min(max(4, pointer.y + 18), max(4, size.height - 110)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Relative reference areas: the centre's size, a tenth and a hundredth. One bounded scale applies to all three,
    /// so zooming never independently clips a large reference and changes the ratios.
    private func sizeKey(model: LivingTreeModel, root: LivingTreeKey, transform t: StructuredExplorerTransform, palette: StructuredExplorerPalette) -> some View {
        let total = model[root]?.bytes
        let sizes = StructuredExplorerScale.keySizes(total)
        let keyScale = min(t.scale, 40 / StructuredExplorerScale.centerRadius)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(sizes, id: \.self) { bytes in
                let r = StructuredExplorerScale.radius(bytes, of: total) * keyScale
                VStack(spacing: 3) {
                    Circle().stroke(palette.secondary.opacity(0.8), lineWidth: 1).frame(width: max(3, 2 * r), height: max(3, 2 * r))
                    Text(AtlasText.bytes(bytes)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(palette.plate, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(sizes.isEmpty ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Size key: disc area is proportional to size")
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { pathBar; Spacer(minLength: 8); viewControls }
                VStack(alignment: .leading, spacing: 6) { HStack { pathBar; Spacer() }; HStack { Spacer(); viewControls } }
            }
            StructuredExplorerFilterControls(state: state, reviewItems: state.migrationTargets.count, canFocus: selectedFolder != nil,
                canIsolate: selectedFolder != nil && selectedFolder != (state.isolatedRoot ?? tree.model?.rootKey),
                isolate: { if let model = tree.model, let key = selectedFolder { isolate(key, model: model) } },
                showPath: { if let model = tree.model, let key = selectedFolder { pathFocus(key, model: model, mode: .path) } },
                clear: clearFocus, reset: resetFilters)
            if let key = state.isolatedRoot, let node = tree.model?[key]?.node {
                HStack(spacing: 8) {
                    Label("Isolated path: \(node.name)", systemImage: "scope").lineLimit(1).truncationMode(.middle).help("Only this folder and its descendants are shown. Exit Isolation restores the previous scope. " + node.path)
                    Spacer(minLength: 4)
                    Button("Exit Isolation", action: exitIsolation).accessibilityLabel("Exit isolation and restore previous selection")
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let model = tree.model, let layout = currentLayout,
               state.visibility(layout, model: model, selection: selectionKey(model)).selectedBelowThreshold {
                Label(selectionExceptionText, systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if showsSelectionContext, let model = tree.model, let key = selectionKey(model), let element = model[key] { selectionContext(element, key: key, model: model) }
        }
        .padding(.horizontal, StorageDesign.gutter).padding(.vertical, 7)
    }

    private var pathBar: some View {
        let trail = visualTrail
        let parent = trail.count > 1 ? trail[trail.count - 2] : nil
        return HStack(spacing: 6) {
            Button { goUp() } label: { Label("Up", systemImage: "chevron.up").font(.caption.weight(.medium)).frame(minHeight: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(parent == nil ? .tertiary : .secondary).disabled(parent == nil)
                .help(parent.map { "Up to \(browser.displayName($0)) (Esc)" } ?? "Already at the top folder")
                .accessibilityLabel("Up one level").accessibilityIdentifier("explorer.up")
            if trail.count > 4 { Text("…").foregroundStyle(.tertiary) }
            ForEach(Array(trail.suffix(4).enumerated()), id: \.element.id) { index, node in
                if index > 0 || trail.count > 4 { Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.tertiary) }
                let current = node.id == trail.last?.id
                Button(browser.displayName(node)) { if !current { navigateCrumb(node) } }
                    .buttonStyle(.plain).font(.caption.weight(current ? .semibold : .regular))
                    .foregroundStyle(current ? .primary : .secondary).lineLimit(1)
                    .help(current ? node.path : "Go to \(browser.displayName(node))")
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Folder path")
    }

    private var viewControls: some View {
        HStack(spacing: 6) {
            Stepper(value: Binding(get: { depth }, set: { depth = min(StructuredExplorerLayout.depthRange.upperBound, max(StructuredExplorerLayout.depthRange.lowerBound, $0)) }),
                    in: StructuredExplorerLayout.depthRange) {
                Text("Levels \(depth)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .controlSize(.small).fixedSize()
            .help("How many folder levels below the centre are shown")
            .accessibilityLabel("Levels shown").accessibilityValue("\(depth)")
            Divider().frame(height: 16)
            iconButton("minus.magnifyingglass", "Zoom Out (−)", disabled: state.camera.zoom <= StructuredExplorerCamera.zoomRange.lowerBound + 1e-6) { if let l = currentLayout { zoomBy(1 / 1.5, at: nil, l) } }
            Text(LivingTreeView.percent(state.camera.zoom)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38)
                .accessibilityLabel("Zoom \(LivingTreeView.percent(state.camera.zoom))")
            iconButton("plus.magnifyingglass", "Zoom In (+)", disabled: state.camera.zoom >= StructuredExplorerCamera.zoomRange.upperBound - 1e-6) { if let l = currentLayout { zoomBy(1.5, at: nil, l) } }
            Divider().frame(height: 16)
            Button("Fit") { if let model = tree.model, let l = currentLayout { frameSelection(l, model: model) } }
                .help("Frame the selected folder's branch, or everything shown (F)")
            Button("Reset View") { resetView() }.help("Default zoom and pan; keeps filters (0)").disabled(state.camera.isFit)
            Button { showingHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                .help("How to get around").accessibilityLabel("Help")
                .popover(isPresented: $showingHelp, arrowEdge: .top) { navigationHelp }
        }
        .buttonStyle(.borderless).controlSize(.small)
    }

    private var currentLayout: StructuredExplorerLayout? {
        tree.model.map { state.layout($0, revision: tree.revision, depth: depth, selection: selectionKey($0)) }
    }

    private func iconButton(_ symbol: String, _ help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 20).contentShape(Rectangle()) }
            .disabled(disabled).help(help).accessibilityLabel(String(help.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces))
    }

    private func selectionContext(_ element: LivingTreeElement, key: LivingTreeKey, model: LivingTreeModel) -> some View {
        HStack(spacing: StorageDesign.rowGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(element.role == .rest ? "Selected group" : "Selected \(element.isFolder ? "folder" : "item")").font(.caption).foregroundStyle(.secondary)
                Text(element.role == .rest ? "Other items in \(element.parent.flatMap { model[$0]?.name } ?? "this folder")" : element.name)
                    .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(StructuredExplorerText.size(element)).font(.callout.monospacedDigit()).lineLimit(1)
                if let share = StructuredExplorerText.share(element, model: model) { Text(share).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if element.isFolder, key != model.rootKey {
                Button("Explore Folder") { open(key, model: model) }.buttonStyle(.bordered).controlSize(.small).help("Make this folder the centre")
            }
        }
        .help(element.node?.path ?? element.name)
        .accessibilityIdentifier("explorer.selection")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(footerText + ". Counts cover real descendant folders placed by the current Levels/per-folder limits, excluding the centre, files and grouped remainders. Context is extra ancestry/selection, not a threshold match. Disc area is indexed size; arcs show share of the actual parent. This bounded loaded view is not the whole catalog.")
            Spacer(minLength: 12)
            Text("Click to select · double-click to explore · Esc goes up").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 5).frame(minHeight: 24)
        .accessibilityIdentifier("inventory.structuredExplorer.status")
    }

    private var footerText: String {
        guard let model = tree.model else { return " " }
        var parts = [String]()
        if let layout = currentLayout {
            parts.append(filterStatus(state.visibility(layout, model: model, selection: selectionKey(model))))
            let hidden = layout.nodes.reduce(0) { $0 + $1.hidden }
            if hidden > 0 { parts.append("\(hidden.formatted()) more items inside (+N)") }
        }
        if model.truncated { parts.append("some items left out to keep this fast") }
        return parts.joined(separator: " · ")
    }

    private func filterStatus(_ visibility: StructuredExplorerVisibility) -> String {
        var text = "Showing \(visibility.visibleFolders) of \(visibility.availableFolders) folders"
        // Match counts only mean something while a filter is narrowing the view.
        if visibility.matchingFolders < visibility.availableFolders { text += " · \(visibility.matchingFolders) match" }
        if visibility.contextFolders > 0 { text += " · \(visibility.contextFolders) shown for context" }
        if state.filter.migrationReview {
            text += visibility.reviewHighlights.isEmpty ? " · no migration review items under this folder" : " · \(visibility.reviewHighlights.count) on migration review paths"
        }
        return text
    }

    private var selectedFolder: LivingTreeKey? {
        guard let model = tree.model, let key = selectionKey(model), key.nodeID != nil, model[key]?.isFolder == true else { return nil }
        return key
    }

    private var selectionExceptionText: String {
        guard let model = tree.model, let key = selectionKey(model), let element = model[key] else { return "Selected path is retained." }
        if element.role == .rest { return "Selected group is retained as navigation context." }
        if element.bytes == nil { return "Selected item's size is unknown; its path is retained." }
        if state.filter.migrationReview { return "Selected item is not on a migration review path; its path is retained." }
        return "Selected item is below the size filter; its path is retained."
    }

    private var visualTrail: [InventoryNode] {
        var trail = browser.breadcrumbs.isEmpty ? (browser.directory.map { [$0] } ?? []) : browser.breadcrumbs
        if let root = state.isolatedRoot, let model = tree.model {
            for key in model.ancestry(of: root) {
                if let node = model[key]?.node, !trail.contains(where: { $0.id == node.id }) { trail.append(node) }
            }
        }
        return trail
    }

    private func navigateCrumb(_ node: InventoryNode) {
        if state.isolatedRoot != nil, let model = tree.model, model[.node(node.id)] != nil {
            if node.id == model.root.id { state.exitIsolation(); choose(.node(node.id), model: model) }
            else { isolate(.node(node.id), model: model) }
        } else { state.exitIsolation(); browser.navigate(node) }
    }

    private func isolate(_ key: LivingTreeKey, model: LivingTreeModel) {
        if state.isolate(key, model: model, selection: explorer.selection) { choose(key, model: model) }
    }

    private func exitIsolation() {
        guard state.isolatedRoot != nil else { return }
        restoreSelection(state.exitIsolation())
        revealSelection()
    }

    private func resetFilters() {
        let hadIsolation = state.isolatedRoot != nil
        let selection = state.resetFilters()
        if hadIsolation { restoreSelection(selection) }
    }

    private func restoreSelection(_ selection: Int64?) {
        if let selection, let model = tree.model, model[.node(selection)] != nil {
            choose(.node(selection), model: model)
        } else { explorer.selection = selection }
    }

    private func clearFocus() { state.filter.focus = .off; exitIsolation() }

    private func pathFocus(_ key: LivingTreeKey, model: LivingTreeModel, mode: StructuredExplorerFocus) {
        guard model[key]?.isFolder == true else { return }
        choose(key, model: model); state.filter.focus = mode
    }

    private func filteredHit(_ p: CGPoint, layout: StructuredExplorerLayout, transform: StructuredExplorerTransform,
                             labels: [StructuredExplorerLabel], visibility: StructuredExplorerVisibility) -> LivingTreeKey? {
        let strong = Set(visibility.visible.filter { visibility.opacity($0) >= 0.7 })
        return layout.hit(p, transform: transform, labels: labels.filter { strong.contains($0.key) }, allowed: strong)
            ?? layout.hit(p, transform: transform, labels: [], allowed: visibility.visible.subtracting(strong))
    }

    private func contextMenu(at p: CGPoint, model: LivingTreeModel, layout: StructuredExplorerLayout,
                             transform: StructuredExplorerTransform, labels: [StructuredExplorerLabel], visibility: StructuredExplorerVisibility) -> NSMenu {
        let key = filteredHit(p, layout: layout, transform: transform, labels: labels, visibility: visibility)
        let folder = key.flatMap { model[$0]?.isFolder == true && $0.nodeID != nil ? $0 : nil }
        let menu = NSMenu(title: "Structured Explorer")
        menu.autoenablesItems = false
        menu.addItem(StructuredExplorerMenuAction.item("Isolate This Path", enabled: folder != nil && folder != layout.rootKey) { if let folder { isolate(folder, model: model) } })
        menu.addItem(StructuredExplorerMenuAction.item("Show Path to Root", enabled: folder != nil) { if let folder { pathFocus(folder, model: model, mode: .path) } })
        menu.addItem(StructuredExplorerMenuAction.item("Focus on Selection", enabled: folder != nil) { if let folder { pathFocus(folder, model: model, mode: .subtree) } })
        menu.addItem(.separator())
        menu.addItem(StructuredExplorerMenuAction.item("Clear Focus / Isolation") { clearFocus() })
        menu.addItem(StructuredExplorerMenuAction.item("Fit") { frameSelection(layout, model: model) })
        menu.addItem(StructuredExplorerMenuAction.item("Reset Filters & View") { resetFilters() })
        return menu
    }

    private var navigationHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Getting around").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                helpRow("Read it", "The centre is the current folder. Each ring is one level further in. Bigger discs hold more; the arc around a disc is its share of the folder it is in.")
                helpRow("Select", "Click a disc or its label. Its details appear in the Inspector, and the Navigator follows.")
                helpRow("Explore a folder", "Double-click it, or select it and press Return. It becomes the centre.")
                helpRow("Go back up", "The Up button, a folder in the path, or Esc.")
                helpRow("Zoom", "Scroll (mouse wheel or trackpad), pinch, or the − and + buttons.")
                helpRow("Move around", "Drag, or hold ⇧ or ⌥ while scrolling.")
                helpRow("See more or less", "Levels sets how many rings are shown. +N marks contents not shown.")
                helpRow("Frame", "Fit frames the selected branch (F); Reset View restores zoom and pan (0). Geometry zoom keeps labels at a readable text size.")
            }
            Text("Prefer a list? The List and Atlas show the same folders.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 440)
        .onExitCommand { showingHelp = false }
    }

    private func helpRow(_ action: String, _ how: String) -> some View {
        GridRow {
            Text(action).font(.callout.weight(.medium))
            Text(how).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Draws one frame of the Structured Explorer into a SwiftUI canvas context.
struct StructuredExplorerPainter {
    let layout: StructuredExplorerLayout
    let model: LivingTreeModel
    let coloring: LivingTreeColoring
    let palette: StructuredExplorerPalette

    static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold), detailFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    @MainActor private static var widths = [String: CGFloat]()
    @MainActor static func width(_ text: String, detail: Bool) -> CGFloat {
        let key = (detail ? "d" : "t") + text
        if let w = widths[key] { return w }
        if widths.count > 4000 { widths.removeAll() }
        let w = ceil((text as NSString).size(withAttributes: [.font: detail ? detailFont : titleFont]).width)
        widths[key] = w
        return w
    }
    static let captionFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// A ring caption's text box, as drawn.
    @MainActor static func captionSize(_ text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: captionFont])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
    /// A label's plate: bold name, then size.
    @MainActor static func measure(_ title: String, _ detail: String) -> CGSize { CGSize(width: width(title, detail: false) + width(detail, detail: true) + 18, height: 18) }

    @MainActor func paint(_ ctx: inout GraphicsContext, transform t: StructuredExplorerTransform, size: CGSize, selected: LivingTreeKey?, exact: Bool, hovered: LivingTreeKey?, labels: [StructuredExplorerLabel], visibility: StructuredExplorerVisibility? = nil) {
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        let centre = t.apply(CGPoint.zero)
        let total = model[layout.rootKey]?.bytes
        // Rings: one per level, quiet. Captions go only where they clear the labels, discs and each other.
        if layout.rings > 0 {
            for ring in 1...layout.rings {
                let radius = CGFloat(ring) * StructuredExplorerScale.ringGap * t.scale
                let spur = ring > layout.depth
                ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)),
                           with: .color(palette.secondary.opacity(spur ? 0.08 : 0.16)), style: StrokeStyle(lineWidth: 0.75, dash: spur ? [3, 4] : []))
            }
            for caption in layout.ringCaptions(transform: t, size: size, labels: labels, measure: Self.captionSize) {
                ctx.draw(Text(caption.text).font(.system(size: 11, weight: .medium)).foregroundColor(palette.secondary.opacity(0.85)),
                         at: CGPoint(x: caption.rect.midX, y: caption.rect.midY))
            }
        }
        // Links, lightest first so heavy flows sit on top.
        let order = layout.nodes.indices.dropFirst().sorted { (model[layout.nodes[$0].key]?.bytes ?? 0) < (model[layout.nodes[$1].key]?.bytes ?? 0) }
        let path = Set(selected.map { model.ancestry(of: $0) } ?? [])
        for i in order {
            let node = layout.nodes[i]
            guard visibility?.visible.contains(node.key) != false else { continue }
            var ink = ctx; ink.opacity *= visibility?.opacity(node.key) ?? 1
            let (p0, c1, c2, p3) = layout.linkControls(i)
            let a = t.apply(p0), d = t.apply(p3)
            guard view.intersects(CGRect(x: min(a.x, d.x), y: min(a.y, d.y), width: abs(a.x - d.x), height: abs(a.y - d.y)).insetBy(dx: -30, dy: -30)) else { continue }
            var curve = Path(); curve.move(to: a); curve.addCurve(to: d, control1: t.apply(c1), control2: t.apply(c2))
            let width = StructuredExplorerScale.linkWidth(model[node.key]?.bytes, of: total) * min(1.6, max(0.6, t.scale))
            let onPath = path.contains(node.key)
            ink.stroke(curve, with: .color(onPath ? StructuredExplorerPalette.accent : palette.tone(node.key, coloring: coloring).opacity(0.42)),
                       style: StrokeStyle(lineWidth: onPath ? max(2.5, width) : width, lineCap: .round, dash: node.elided > 0 ? [4, 4] : []))
            if node.elided > 0 {
                let mid = layout.link(i, t)(0.5)
                ink.draw(Text("⋯ \(node.elided) level\(node.elided == 1 ? "" : "s")").font(.system(size: 9, weight: .semibold)).foregroundColor(palette.secondary), at: CGPoint(x: mid.x, y: mid.y - 9))
            }
        }
        // Discs, largest first so small ones stay on top and clickable.
        for node in layout.nodes.sorted(by: { $0.radius > $1.radius }) {
            guard visibility?.visible.contains(node.key) != false else { continue }
            var ink = ctx; ink.opacity *= visibility?.opacity(node.key) ?? 1
            let c = t.apply(node.point), r = layout.screenRadius(node, t)
            guard view.contains(c), let element = model[node.key] else { continue }
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            if node.ring == 0 {
                ink.fill(Path(ellipseIn: rect), with: .color(palette.dark ? Color(white: 0.86) : Color(white: 0.30)))
            } else if element.bytes == nil {
                ink.stroke(Path(ellipseIn: rect), with: .color(palette.secondary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            } else if element.role == .rest {
                ink.fill(Path(ellipseIn: rect), with: .color(palette.secondary.opacity(0.22)))
                ink.stroke(Path(ellipseIn: rect), with: .color(palette.secondary.opacity(0.6)), lineWidth: 0.75)
            } else if element.isFolder {
                ink.fill(Path(ellipseIn: rect), with: .color(palette.tone(node.key, coloring: coloring)))
            } else {
                ink.fill(Path(ellipseIn: rect), with: .color(palette.ground))
                ink.stroke(Path(ellipseIn: rect), with: .color(palette.tone(node.key, coloring: coloring)), lineWidth: max(1, min(2.5, r / 4)))
            }
            // Share of the folder it is in: an arc just outside the disc, from 12 o'clock.
            if node.ring > 0, r >= 4, let parent = element.parent, let share = StructuredExplorerScale.share(element.bytes, of: model[parent]?.bytes), share > 0 {
                var arc = Path()
                arc.addArc(center: c, radius: r + 2.5, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * share), clockwise: false)
                ink.stroke(arc, with: .color(palette.ink.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5))
            }
            // Contents not shown: "+N", outward.
            if node.hidden > 0, element.isFolder, node.ring > 0 {
                let out = CGPoint(x: sin(node.angle), y: -cos(node.angle))
                if r >= 6 || node.key == hovered || node.key == selected {
                    ink.draw(Text("+\(node.hidden)").font(.system(size: 8.5, weight: .semibold)).foregroundColor(palette.secondary),
                             at: CGPoint(x: c.x + out.x * (r + 10), y: c.y + out.y * (r + 10)))
                } else {
                    // More inside, too small to count here: a short outward tick (the count appears on hover or zoom).
                    var tick = Path(); tick.move(to: CGPoint(x: c.x + out.x * (r + 2), y: c.y + out.y * (r + 2))); tick.addLine(to: CGPoint(x: c.x + out.x * (r + 6), y: c.y + out.y * (r + 6)))
                    ink.stroke(tick, with: .color(palette.secondary.opacity(0.7)), lineWidth: 1)
                }
            }
        }
        // Migration Review: a dashed ring on each shown item (or nearest shown folder) leading to a detected item.
        for key in visibility?.reviewHighlights ?? [] {
            guard let node = layout[key] else { continue }
            let c = t.apply(node.point), r = layout.screenRadius(node, t) + 3.5
            guard view.contains(c) else { continue }
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(StructuredExplorerPalette.review),
                       style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
        }
        if let selected, let node = layout[selected] {
            let c = t.apply(node.point), r = layout.screenRadius(node, t) + 5
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(StructuredExplorerPalette.accent),
                       style: StrokeStyle(lineWidth: 2.5, dash: exact ? [] : [4, 3]))
        }
        if let hovered, hovered != selected, let node = layout[hovered] {
            let c = t.apply(node.point), r = layout.screenRadius(node, t) + 4
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(palette.ink.opacity(0.7)), lineWidth: 1)
        }
        for label in labels {
            var ink = ctx; ink.opacity *= visibility?.labelOpacity(label.key) ?? 1
            pill(&ink, label)
        }
    }

    @MainActor private func pill(_ ctx: inout GraphicsContext, _ label: StructuredExplorerLabel) {
        var c = ctx
        if label.angle != 0 { c.translateBy(x: label.anchor.x, y: label.anchor.y); c.rotate(by: .radians(label.angle)); c.translateBy(x: -label.anchor.x, y: -label.anchor.y) }
        let shape = Path(roundedRect: label.rect, cornerRadius: 5)
        c.fill(shape, with: .color(palette.plate))
        c.stroke(shape, with: .color(label.emphasized ? StructuredExplorerPalette.accent : palette.plateEdge), lineWidth: label.emphasized ? 1.5 : 0.5)
        let titleWidth = Self.width(label.title, detail: false)
        c.draw(Text(label.title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(palette.ink), at: CGPoint(x: label.rect.minX + 7, y: label.rect.midY), anchor: .leading)
        c.draw(Text(label.detail).font(.system(size: 11).monospacedDigit()).foregroundColor(palette.secondary), at: CGPoint(x: label.rect.minX + 11 + titleWidth, y: label.rect.midY), anchor: .leading)
    }
}
