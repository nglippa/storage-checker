import SwiftUI
import AppKit

// The interactive shell shared by both prototypes: breadcrumb and Up, the canvas with the production Living Tree
// input layer and gesture interpretation (so wheel/pinch/drag/click/double-click behave exactly as in the app after
// the wheel fix), zoom controls, a legend, and an inspector whose contents list is the accessible, keyboard-navigable
// representation of the hierarchy (the canvas never has to be used).

@MainActor final class ProtoExplorer: ObservableObject {
    enum Kind: String, CaseIterable { case organic = "Organic Storage Tree", structured = "Structured Explorer" }
    let kind: Kind
    @Published private(set) var scene: (any ProtoScene)?
    @Published var camera = ProtoCamera()
    @Published private(set) var selected: Int?
    @Published var hovered: Int?
    @Published private(set) var depth = 3
    @Published private(set) var focus = 0
    private(set) var tree: ProtoTree?
    var viewport = CGSize(width: 900, height: 600)
    /// Rebuilds the hierarchy at a folder (the same catalog read as the app) / at the parent of the current root.
    var navigateInto: ((InventoryNode) -> Void)?
    var navigateUp: (() -> Void)?
    /// Seconds spent in the last layout (scene construction).
    private(set) var lastLayoutSeconds = 0.0

    init(kind: Kind) { self.kind = kind }

    func load(_ model: LivingTreeModel) {
        tree = ProtoTree(model); focus = 0; selected = nil; hovered = nil; camera = ProtoCamera()
        rebuild()
    }
    private func rebuild() {
        guard let tree else { scene = nil; return }
        let started = Date()
        scene = kind == .organic ? OrganicTreeScene(tree: tree) : StructuredExplorerScene(tree: tree, focus: focus, depth: depth, keep: selected)
        lastLayoutSeconds = Date().timeIntervalSince(started)
    }

    func transform(_ size: CGSize) -> ProtoTransform? { scene.map { camera.transform(bounds: $0.bounds, size: size) } }
    var state: ProtoViewState { ProtoViewState(selected: selected, hovered: hovered) }

    func select(_ node: Int?) {
        selected = node
        guard kind == .structured, let node, let tree, let s = scene as? StructuredExplorerScene, !s.isPlaced(node) else { return }
        // Beyond the per-folder limit the selection is simply kept visible; beyond the shown levels (or outside the
        // centre's branch) the explorer re-centres on the ancestor that puts it one ring inside the edge.
        let chain = tree.ancestry(node)
        if !chain.contains(focus) || tree[node].depth - tree[focus].depth >= depth {
            focus = chain[max(0, chain.count - depth)]
            camera = ProtoCamera()
        }
        rebuild()
    }
    func setDepth(_ value: Int) { depth = max(1, min(6, value)); rebuild(); camera = ProtoCamera() }

    /// Double-click / Explore: the explorer re-centres on a folder it holds; otherwise (or in the organic tree, for a
    /// folder whose contents are not drawn) the hierarchy is rebuilt there. An open organic limb is framed instead.
    func explore(_ node: Int) {
        guard let tree, tree[node].isFolder, tree[node].role != .rest else { return }
        let hasChildren = !tree[node].children.isEmpty
        switch kind {
        case .structured where hasChildren:
            focus = node; selected = node; rebuild(); camera = ProtoCamera()
        case .organic where hasChildren && node != 0:
            selected = node; focusOn(node)
        default:
            if node != 0, let catalog = tree[node].node { navigateInto?(catalog) }
        }
    }
    func up() {
        if kind == .structured, let tree, focus != 0 { let previous = focus; focus = tree[focus].parent; selected = previous; rebuild(); camera = ProtoCamera() }
        else { navigateUp?() }
    }
    func focusOn(_ node: Int) {
        guard let scene, let rect = scene.focusRect(node) else { return }
        camera.focus(rect, bounds: scene.bounds, size: viewport)
    }
    /// Fit: frames the selection's subtree when there is one, otherwise everything shown.
    func fit() { if let selected, selected != focus { focusOn(selected) } else { camera = ProtoCamera() } }
    /// Reset: the known default — whole hierarchy, explorer centred on the root at three levels.
    func reset() {
        camera = ProtoCamera()
        if kind == .structured && (focus != 0 || depth != 3) { focus = 0; depth = 3; rebuild() }
    }
    func zoom(by factor: Double, at point: CGPoint?) { if let scene { camera.zoom(by: factor, at: point, bounds: scene.bounds, size: viewport) } }
    func pan(by delta: CGVector) { if let scene { camera.pan(by: delta, bounds: scene.bounds, size: viewport) } }
}

struct ProtoExplorerView: View {
    @ObservedObject var explorer: ProtoExplorer
    /// Folder names from the volume to the current root (the app's breadcrumb), and how to go to one of them.
    var trail: [String] = []
    var openTrail: ((Int) -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var gesture = LivingTreeGesture()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                canvas
                Divider()
                legend
            }
            Divider()
            ProtoInspector(explorer: explorer).frame(width: 300)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { explorer.up() } label: { Label("Up One Level", systemImage: "arrow.up") }
                .help("Go to the parent folder").keyboardShortcut(.upArrow, modifiers: .command)
            breadcrumb
            Spacer(minLength: 8)
            if explorer.kind == .structured {
                Stepper(value: Binding(get: { explorer.depth }, set: { explorer.setDepth($0) }), in: 1...6) { Text("Levels: \(explorer.depth)").monospacedDigit() }
                    .fixedSize().help("How many levels below the centre are shown")
            }
            Text(explorer.kind.rawValue).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var breadcrumb: some View {
        let inner: [Int] = {
            guard let tree = explorer.tree else { return [] }
            return Array(tree.ancestry(explorer.focus).dropFirst())
        }()
        return HStack(spacing: 3) {
            ForEach(Array(trail.enumerated()), id: \.offset) { index, name in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(name) { openTrail?(index) }.buttonStyle(.plain).foregroundStyle(index == trail.count - 1 && inner.isEmpty ? .primary : .secondary).lineLimit(1)
            }
            ForEach(inner, id: \.self) { node in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Text(explorer.tree?[node].name ?? "").foregroundStyle(node == inner.last ? .primary : .secondary).lineLimit(1)
            }
        }.font(.callout).truncationMode(.middle)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if let scene = explorer.scene, let t = explorer.transform(size) {
                let state = explorer.state
                let labels = scene.labels(t, size: size, state: state)
                let palette = ProtoPalette(dark: scheme == .dark)
                ZStack {
                    Canvas { context, _ in _ = scene.draw(&context, t, size: size, state: state, labels: labels, palette: palette) }
                        .accessibilityElement()
                        .accessibilityLabel("\(scene.title) of \(scene.tree.rootName). Use the contents list in the inspector to move through folders.")
                    LivingTreeInputLayer { event in handle(event, scene: scene, transform: t, labels: labels) }
                }
                .onAppear { explorer.viewport = size }
                .onChange(of: size) { _, new in explorer.viewport = new }
            } else {
                ProgressView("Building tree…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottomTrailing) { controls.padding(12) }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button { explorer.zoom(by: 1 / 1.5, at: nil) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
            Text("\(Int((explorer.camera.zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 44).font(.caption)
            Button { explorer.zoom(by: 1.5, at: nil) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
            Divider().frame(height: 16)
            Button("Fit") { explorer.fit() }.help("Frame the selection's branch, or everything")
            Button("Reset") { explorer.reset() }.help("Restore the default view")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(explorer.scene?.legend ?? [], id: \.self) { Text($0) }
            Text("Scroll or pinch to zoom · drag to pan · click to select · double-click to explore").foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    // MARK: Input (the production gesture interpretation)

    private func handle(_ event: LivingTreeInputView.Event, scene: any ProtoScene, transform t: ProtoTransform, labels: [ProtoLabel]) {
        let tree = scene.tree
        func target(_ p: CGPoint) -> LivingTreeKey? { scene.hit(p, t, labels: labels).map { tree[$0].key } }
        let opens = { (key: LivingTreeKey) -> Bool in tree.index[key].map { tree[$0].isFolder && tree[$0].role != .rest } ?? false }
        var actions = [LivingTreeGesture.Action]()
        switch event {
        case .down(let p, let clicks, let modifiers): actions = gesture.down(at: p, clickCount: clicks, modifiers: modifiers, target: target(p), opens: opens)
        case .dragged(let p): actions = gesture.dragged(to: p)
        case .up(let p, let clicks): actions = gesture.up(at: p, clickCount: clicks, target: gesture.isDragging ? nil : target(p))
        case .moved(let p): if !gesture.isDragging { explorer.hovered = p.flatMap { scene.hit($0, t, labels: labels) } }
        case .scroll(let delta, let precise, let momentum, let modifiers, let p):
            if let action = LivingTreeGesture.scroll(delta, precise: precise, modifiers: modifiers, at: p, momentum: momentum) { actions = [action] }
        case .magnify(let m, let p): if let action = LivingTreeGesture.magnify(m, at: p) { actions = [action] }
        case .smartMagnify(let p): actions = [.toggleZoom(at: p)]
        case .rotate: break
        case .command(let command):
            switch command {
            case .zoomIn: explorer.zoom(by: 1.5, at: nil)
            case .zoomOut: explorer.zoom(by: 1 / 1.5, at: nil)
            case .fit: explorer.fit()
            case .reset: explorer.reset()
            case .focusSelection: if let s = explorer.selected { explorer.focusOn(s) }
            }
        }
        for action in actions {
            switch action {
            case .select(let key): explorer.select(tree.index[key])
            case .open(let key): if let i = tree.index[key] { explorer.explore(i) }
            case .focus(let key): if let i = tree.index[key] { explorer.select(i); explorer.focusOn(i) }
            case .pan(let d): explorer.pan(by: d)
            case .zoom(let factor, let p, _): explorer.zoom(by: factor, at: p)
            case .toggleZoom(let p): if explorer.camera.zoom > 1.05 { explorer.camera = ProtoCamera() } else { explorer.zoom(by: 2.5, at: p) }
            case .orbit: break
            case .dragBegan: explorer.hovered = nil
            case .dragEnded: break
            }
        }
    }
}

/// Details of the selection (or the centre), and its contents as a list: the accessible way through the hierarchy.
struct ProtoInspector: View {
    @ObservedObject var explorer: ProtoExplorer

    var body: some View {
        if let tree = explorer.tree {
            let current = explorer.selected ?? explorer.focus
            let node = tree[current]
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(current == 0 ? tree.rootName : node.name).font(.title3.weight(.semibold)).lineLimit(2)
                        Text(node.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                    }
                    Text(ProtoFormat.bytes(node.bytes)).font(.system(size: 26, weight: .semibold).monospacedDigit())
                    VStack(alignment: .leading, spacing: 6) {
                        if node.parent >= 0 { ShareRow(title: "Share of \(ProtoText.short(node.parent == 0 ? tree.rootName : tree[node.parent].name, limit: 22))", share: tree.shareOfParent(current)) }
                        if current != 0 { ShareRow(title: "Share of \(ProtoText.short(tree.rootName, limit: 22))", share: tree.shareOfRoot(current)) }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        GridRow { Text("Kind").foregroundStyle(.secondary); Text(kind(node)) }
                        if node.role == .rest { GridRow { Text("Items").foregroundStyle(.secondary); Text("\(node.count)") } }
                        GridRow { Text("Level").foregroundStyle(.secondary); Text("\(node.depth)") }
                    }.font(.callout)
                    HStack {
                        if node.isFolder && node.role != .rest && current != explorer.focus { Button("Explore") { explorer.explore(current) } }
                        Button("Up One Level") { explorer.up() }
                    }.controlSize(.small)
                    Divider()
                    if !node.children.isEmpty {
                        Text("Contents").font(.headline)
                        ForEach(node.children.prefix(40), id: \.self) { child in ContentRow(explorer: explorer, tree: tree, node: child, of: node) }
                        if node.children.count > 40 { Text("\(node.children.count - 40) more").font(.caption).foregroundStyle(.secondary) }
                    } else if node.isFolder && node.role != .rest {
                        Text("Contents not loaded in this tree. Explore to read them.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else { Color.clear }
    }
    private func kind(_ node: ProtoNode) -> String {
        switch node.role {
        case .trunk: return "Current folder"
        case .branch: return node.expanded ? "Folder" : "Folder (contents not drawn)"
        case .file: return "File"
        case .rest: return "Grouped small items"
        case .unmeasured: return "Size not measured"
        }
    }
}

private struct ShareRow: View {
    let title: String
    let share: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(ProtoFormat.percent(share)).monospacedDigit() }.font(.callout)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(Color.accentColor).frame(width: max(2, g.size.width * CGFloat(share ?? 0)))
                }
            }.frame(height: 5).accessibilityHidden(true)
        }
    }
}

private struct ContentRow: View {
    @ObservedObject var explorer: ProtoExplorer
    let tree: ProtoTree
    let node: Int
    let of: ProtoNode
    var body: some View {
        let n = tree[node], share = tree.shareOfParent(node)
        Button { explorer.select(node) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: n.role == .rest ? "square.stack.3d.up" : (n.isFolder ? "folder" : "doc")).foregroundStyle(.secondary).frame(width: 16)
                    Text(n.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ProtoFormat.bytes(n.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { g in Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: max(1, g.size.width * CGFloat(share ?? 0))) }.frame(height: 3)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).font(.callout)
        .accessibilityLabel("\(n.name), \(ProtoFormat.bytes(n.bytes)), \(ProtoFormat.percent(share)) of \(of.name)")
        .accessibilityAction(named: "Explore") { explorer.explore(node) }
    }
}
