import SwiftUI

/// Owns the Living Tree of the explorer's current folder: builds it from one catalog snapshot, keeps it stable
/// across updates (per-trunk layout memory), rebuilds only when committed changes touch what is drawn, and turns
/// verified size signals into brief illumination. Bounded: one tree (about 3,000 elements), one previous tree for
/// transitions, layout memories for the last few trunks, and at most `LivingTreeIllumination.capacity` glows.
@MainActor final class LivingTreeController: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }

    @Published private(set) var model: LivingTreeModel?
    @Published private(set) var arrangement: LivingTreeArrangement?
    /// Bumped whenever a new tree is published.
    @Published private(set) var revision = 0
    @Published private(set) var phase = Phase.idle
    @Published private(set) var illumination = LivingTreeIllumination()
    /// A grouped remainder chosen in the tree; the shared selection then holds its folder.
    @Published var focusOverride: LivingTreeKey?

    /// The tree shown before the latest one, for the transition between trunks.
    private(set) var previousModel: LivingTreeModel?
    private(set) var previousGeometry: LivingTreeGeometry?
    private var cache: (revision: Int, size: CGSize, geometry: LivingTreeGeometry, hits: LivingTreeHitIndex)?

    let budget: LivingTreeBudget
    private let reader: InventoryReader
    private var trunk: Int64?
    private var ancestors = Set<Int64>()
    private var memories = [Int64: LivingTreeMemory]()
    private var memoryOrder = InventoryRecency(capacity: 6)
    private var reveal: Int64?
    private var changeCursor: InventoryChangeCursor?
    private var building = false, buildPending = false
    private var lastBuild = Date.distantPast
    private var polling = false, pollPending = false
    private var lastPoll = Date.distantPast, lastSignalRead = Date.distantPast
    private var deferred: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private(set) var statistics = LivingTreeStatistics()

    /// Shortest interval between two change reads, and between two rebuilds during rapid updates.
    static let pollInterval: TimeInterval = 1
    static let rebuildInterval: TimeInterval = 1.5

    init(database: String, budget: LivingTreeBudget = .standard) {
        reader = InventoryReader(path: database); self.budget = budget
    }

    /// Shows the tree of `root` (`trail`: breadcrumbs from the volume, `root` last).
    func show(root: InventoryNode, trail: [InventoryNode]) {
        ancestors = Set(trail.map(\.id)).subtracting([root.id])
        // Returning after a while: changes measured meanwhile are not replayed as new.
        if Date().timeIntervalSince(lastSignalRead) > LivingTreeIllumination.duration { illumination = LivingTreeIllumination() }
        guard root.id != trunk else { if model == nil { rebuild() } else { inventoryChanged() }; return }
        trunk = root.id
        reveal = nil; focusOverride = nil
        phase = .loading
        rebuild()
    }

    /// Draws `node` on its own even when it is small (a search result revealed in its folder).
    func reveal(_ node: Int64) {
        guard model?[.node(node)] == nil else { return }
        reveal = node
        rebuild()
    }

    /// Reads the change feed and size signals after the inventory reported a change. Throttled and coalesced:
    /// at most one read in flight and one per `pollInterval`; a change arriving meanwhile is re-checked, not dropped.
    func inventoryChanged() {
        guard trunk != nil else { return }
        guard !polling, Date().timeIntervalSince(lastPoll) >= Self.pollInterval else { pollPending = true; scheduleDeferred(); return }
        polling = true; pollPending = false; lastPoll = Date()
        let reader = reader, cursor = changeCursor
        Task {
            defer { polling = false; if pollPending { scheduleDeferred() } }
            statistics.polls += 1
            if let batch = try? await reader.changes(since: cursor), let model {
                if LivingTreeRefresh.needsRebuild(batch, model: model, ancestors: ancestors) {
                    statistics.rebuildsForChanges += 1
                    rebuild()
                } else {
                    statistics.rebuildsAvoided += 1
                    changeCursor = batch.next
                }
            }
            let signals = try? await reader.sizeSignals(since: illumination.cursor)
            lastSignalRead = Date()
            if case .illuminated = illumination.receive(signals, now: Date()) { scheduleExpiry() }
        }
    }

    private func scheduleDeferred() {
        guard deferred == nil else { return }
        deferred = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.deferred = nil
            if self.pollPending { self.inventoryChanged() }
        }
    }

    /// Rebuilds the tree from one snapshot. One build at a time; a request during a build runs once it ends, no
    /// sooner than `rebuildInterval` after the previous build (rapid inventory updates coalesce).
    private func rebuild() {
        guard let trunk else { return }
        if building { buildPending = true; return }
        // Without a change journal every notification would rebuild: then at most every five seconds.
        let interval = model != nil && model?.journalCursor == nil ? 5 : Self.rebuildInterval
        let wait = interval - Date().timeIntervalSince(lastBuild)
        if wait > 0, model?.root.id == trunk {
            buildPending = true
            building = true
            Task { try? await Task.sleep(for: .seconds(wait)); building = false; if buildPending { buildPending = false; rebuild() } }
            return
        }
        building = true; buildPending = false; lastBuild = Date()
        let reader = reader, budget = budget, memory = memories[trunk] ?? LivingTreeMemory(), reveal = reveal
        Task {
            defer { building = false; if buildPending { buildPending = false; rebuild() } }
            do {
                let started = Date()
                let built = try await reader.livingTree(rootID: trunk, budget: budget, memory: memory, reveal: reveal)
                guard trunk == self.trunk else { return }
                let (arrangement, remembered) = await Task.detached(priority: .userInitiated) { () -> (LivingTreeArrangement, LivingTreeMemory) in
                    var memory = memory
                    let arrangement = LivingTreeArranger.arrange(built, memory: &memory)
                    return (arrangement, memory)
                }.value
                guard trunk == self.trunk else { return }
                memories[trunk] = remembered
                for dropped in memoryOrder.use(trunk) { memories[dropped] = nil }
                if let current = model, current.root.id != built.root.id { previousModel = current; previousGeometry = cache?.geometry }
                // The change feed continues from the moment this tree was read.
                if let journal = built.journalCursor { changeCursor = journal }
                model = built; self.arrangement = arrangement; revision += 1; phase = .ready
                statistics.builds += 1; statistics.lastBuildSeconds = Date().timeIntervalSince(started); statistics.lastReads = built.reads
            } catch {
                guard trunk == self.trunk else { return }
                if model?.root.id == trunk { phase = .ready } else { model = nil; arrangement = nil; phase = .failed((error as? InventoryReaderError).map { "\($0)" } ?? error.localizedDescription) }
            }
        }
    }

    /// Clears expired light once the last glow has faded, so the view stops animating.
    private func scheduleExpiry() {
        expiry?.cancel()
        guard let latest = illumination.glows.values.map(\.observed).max() else { return }
        let delay = max(0.1, latest.addingTimeInterval(LivingTreeIllumination.duration + 0.1).timeIntervalSinceNow)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.illumination.expire(at: Date())
        }
    }

    /// Geometry and hit index for the current tree at `size`, computed once per tree and size.
    func layout(for size: CGSize) -> (geometry: LivingTreeGeometry, hits: LivingTreeHitIndex)? {
        guard let model, let arrangement, size.width > 1, size.height > 1 else { return nil }
        if let cache, cache.revision == revision, cache.size == size { return (cache.geometry, cache.hits) }
        let geometry = LivingTreeGeometer.layout(model, arrangement, in: size)
        let hits = LivingTreeHitIndex(geometry)
        cache = (revision, size, geometry, hits)
        return (geometry, hits)
    }

    /// The geometry last laid out (for transitions).
    var cachedGeometry: LivingTreeGeometry? { cache?.geometry }
}

/// Work done by one Living Tree, for diagnostics and measurements.
struct LivingTreeStatistics: Equatable {
    var builds = 0, polls = 0, rebuildsForChanges = 0, rebuildsAvoided = 0
    var lastBuildSeconds = 0.0, lastReads = 0
}

// MARK: - View

/// The Living Tree: the explorer's current folder as an organic, luminous tree on a deep charcoal ground. The
/// trunk is the folder, branches are its folders, terminal elements are files and grouped small items. Shares
/// navigation and selection with the Navigator and Inspector; nothing moves unless something changed.
struct LivingTreeView: View {
    @ObservedObject var browser: InventoryBrowserModel
    @ObservedObject var explorer: InventoryExplorerController
    @ObservedObject var tree: LivingTreeController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover: (key: LivingTreeKey, location: CGPoint)?
    @State private var zoom = AtlasZoom.identity
    @State private var zoomProgress = 1.0
    @State private var fade = 1.0
    @State private var shownRoot: Int64?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                content(size: proxy.size)
                    .modifier(LivingTreeZoomEffect(zoom: zoom, progress: zoomProgress))
                    .opacity(fade)
                    .clipped()
            }
            footer
        }
        .background(LivingTreeGround())
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("inventory.livingTree")
        .onAppear(perform: sync)
        .onChange(of: browser.directory?.id) { _, _ in sync() }
        .onChange(of: browser.status?.updatedAt) { _, _ in tree.inventoryChanged() }
        .onChange(of: browser.revision) { _, _ in tree.inventoryChanged() }
        .onChange(of: explorer.revealRequest) { _, request in if let request { tree.reveal(request.node) } }
        .onChange(of: explorer.selection) { _, id in
            if let override = tree.focusOverride, override.restFolder != id { tree.focusOverride = nil }
        }
        .onChange(of: tree.revision) { _, _ in transition() }
    }

    private func sync() {
        guard let folder = browser.directory else { return }
        tree.show(root: folder, trail: browser.breadcrumbs)
        // A search result revealed while another visualization was showing is still drawn here.
        if let request = explorer.revealRequest, request.folder == folder.id { tree.reveal(request.node) }
    }

    // MARK: Content

    @ViewBuilder private func content(size: CGSize) -> some View {
        if let model = tree.model, let arrangement = tree.arrangement, let layout = tree.layout(for: size) {
            canvas(model: model, arrangement: arrangement, geometry: layout.geometry, hits: layout.hits, size: size)
        } else {
            switch tree.phase {
            case .failed(let message): placeholder("The tree could not be read · \(message)")
            default: placeholder("Growing the tree…", spinning: true)
            }
        }
    }

    private func placeholder(_ text: String, spinning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.small) }
            Text(text).foregroundStyle(.secondary)
        }.font(.callout).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canvas(model: LivingTreeModel, arrangement: LivingTreeArrangement, geometry: LivingTreeGeometry, hits: LivingTreeHitIndex, size: CGSize) -> some View {
        let focus = focusKey(model)
        let chain = focus.map { model.ancestry(of: $0) } ?? []
        let illumination = tree.illumination
        let animating = illumination.isActive(at: Date()) { model[.node($0)] != nil }
        return ZStack(alignment: .topLeading) {
            LivingTreeBaseCanvas(revision: tree.revision, size: size, geometry: geometry, model: model).equatable()
            TimelineView(.animation(minimumInterval: reduceMotion ? 4 : 1.0 / 30, paused: !animating)) { timeline in
                Canvas(rendersAsynchronously: false) { context, _ in
                    LivingTreePainter(geometry: geometry, model: model).paintOverlay(&context, now: timeline.date, illumination: illumination, reduceMotion: reduceMotion,
                                                                                    hovered: hover?.key, chain: chain, focus: focus)
                }
            }
            .allowsHitTesting(false)
            lens(model: model, size: size)
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): hover = hits.hit(point).map { ($0, point) }
            case .ended: hover = nil
            }
        }
        .gesture(SpatialTapGesture(count: 2).onEnded { value in
            if let key = hits.hit(value.location) { open(key, model: model) }
        }.exclusively(before: SpatialTapGesture().onEnded { value in
            focused = true
            if let key = hits.hit(value.location) { choose(key, model: model) }
        }))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(.towardTips, model: model, arrangement: arrangement) }
        .onKeyPress(.downArrow) { move(.towardTrunk, model: model, arrangement: arrangement) }
        .onKeyPress(.leftArrow) { move(.previousSibling, model: model, arrangement: arrangement) }
        .onKeyPress(.rightArrow) { move(.nextSibling, model: model, arrangement: arrangement) }
        .onKeyPress(.return) { if let focus { open(focus, model: model) }; return .handled }
        .onKeyPress(.escape) { goUp(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Living Tree of \(model.root.parentID == nil ? "Startup Data" : model.root.name)")
        .accessibilityHint("Arrow keys move between branches. Return opens a folder. Escape goes to the enclosing folder.")
        .accessibilityChildren {
            // The largest elements as buttons (bounded); every entry stays reachable in the Navigator below.
            ForEach(LivingTreeText.accessibleElements(model, limit: 48), id: \.self) { key in
                if let branch = geometry[key], let element = model[key] {
                    Rectangle().frame(width: 24, height: 24).position(branch.end)
                        .accessibilityLabel(LivingTreeText.spoken(element, glow: element.node.flatMap { illumination.glows[$0.id] }))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { choose(key, model: model) }
                        .accessibilityAction(named: "Open") { open(key, model: model) }
                }
            }
        }
    }

    // MARK: Selection and navigation

    /// The element that shows the shared selection: the entry itself, its folder's grouped items, or its nearest
    /// drawn folder.
    private func focusKey(_ model: LivingTreeModel) -> LivingTreeKey? {
        if let override = tree.focusOverride, model[override] != nil, override.restFolder == explorer.selection { return override }
        guard let id = explorer.selection else { return nil }
        return model.displayKey(forNode: id) { explorer.state.node($0)?.parentID }
    }

    /// Single click or keyboard: selects the entry (the Navigator and Inspector follow). Grouped small items
    /// select their folder and open it in the Navigator, where every item is listed: nothing requires hitting a
    /// tiny twig.
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

    /// Double click or Return: a folder becomes the trunk; grouped items open their folder.
    private func open(_ key: LivingTreeKey, model: LivingTreeModel) {
        switch key {
        case .node:
            guard let node = model[key]?.node, node.kind == .directory, key != model.rootKey else { return }
            browser.navigate(node)
        case .rest(let folder):
            guard .node(folder) != model.rootKey, let node = model[.node(folder)]?.node else { return }
            browser.navigate(node)
        }
    }

    private func move(_ move: LivingTreeNavigation.Move, model: LivingTreeModel, arrangement: LivingTreeArrangement) -> KeyPress.Result {
        guard let next = LivingTreeNavigation.move(move, from: focusKey(model), in: model, arrangement: arrangement) else { return .ignored }
        choose(next, model: model)
        return .handled
    }

    private func goUp() {
        guard let folder = browser.directory, let parent = folder.parentID, let node = browser.breadcrumbs.first(where: { $0.id == parent }) else { return }
        browser.navigate(node)
    }

    /// Entering a folder grows the new tree out of the branch it was; leaving starts from the parent enlarged
    /// around the folder you left. Uniform scaling only; Reduce Motion cross-fades.
    private func transition() {
        guard let model = tree.model else { return }
        defer { shownRoot = model.root.id }
        guard let old = shownRoot, old != model.root.id else { return }
        var start: AtlasZoom?
        if AtlasZoom.animates(reduceMotion: reduceMotion), let geometry = tree.cachedGeometry {
            let size = geometry.size
            if let previous = tree.previousModel, let previousGeometry = tree.previousGeometry, previous.root.id == old,
               let rect = previousGeometry.bounds(of: previous.subtree(of: .node(model.root.id))) {
                start = AtlasZoom.start(entering: true, rect: rect, in: size)
            } else if let rect = geometry.bounds(of: model.subtree(of: .node(old))) {
                start = AtlasZoom.start(entering: false, rect: rect, in: size)
            }
        }
        if let start {
            zoom = start; zoomProgress = 0; fade = 0.3
            withAnimation(.smooth(duration: 0.45)) { zoomProgress = 1; fade = 1 }
        } else {
            zoom = .identity; zoomProgress = 1; fade = 0.5
            withAnimation(.easeOut(duration: 0.18)) { fade = 1 }
        }
    }

    // MARK: Lens, header, footer

    @ViewBuilder private func lens(model: LivingTreeModel, size: CGSize) -> some View {
        if let hover, let element = model[hover.key] {
            let lines = LivingTreeText.lens(element, model: model, glow: element.node.flatMap { tree.illumination.glows[$0.id] })
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(lines.value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                ForEach(lines.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: 280, alignment: .leading)
            .background(Color(white: 0.11).opacity(0.94), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
            .offset(x: min(max(4, hover.location.x + 14), max(4, size.width - 290)), y: min(max(4, hover.location.y + 16), max(4, size.height - 90)))
            .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            let trail = browser.breadcrumbs.isEmpty ? (browser.directory.map { [$0] } ?? []) : browser.breadcrumbs
            if trail.count > 4 { Text("…").foregroundStyle(.tertiary) }
            ForEach(Array(trail.suffix(4).enumerated()), id: \.element.id) { index, node in
                if index > 0 || trail.count > 4 { Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.tertiary) }
                let current = node.id == trail.last?.id
                Button(browser.displayName(node)) { if !current { browser.navigate(node) } }
                    .buttonStyle(.plain).font(.caption.weight(current ? .semibold : .regular))
                    .foregroundStyle(current ? .primary : .secondary).lineLimit(1)
                    .help(current ? node.path : "Go to \(browser.displayName(node))")
            }
            Spacer(minLength: 12)
            LivingTreeLegend()
        }
        .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 4)
        .accessibilityElement(children: .contain).accessibilityLabel("Living Tree path")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("Click to select · double-click to open · arrow keys move").font(.caption).foregroundStyle(.tertiary)
        }.padding(.horizontal, 16).frame(height: 24).accessibilityIdentifier("inventory.livingTree.status")
    }

    private var footerText: String {
        guard let model = tree.model else { return " " }
        var parts = ["Thickness shows indexed allocation", "\(model.count.formatted()) elements"]
        let unmeasured = model.order.reduce(Int64(0)) { total, key in
            let element = model[key]!
            return total + (element.role == .unmeasured ? 1 : (element.role == .rest ? element.unmeasured : 0))
        }
        if unmeasured > 0 { parts.append("\(unmeasured.formatted()) without a measured size, never drawn as zero") }
        if model.truncated { parts.append("reduced to keep the read short") }
        return parts.joined(separator: " · ")
    }
}

/// The deep charcoal ground, a little lighter around the crown.
struct LivingTreeGround: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.082, green: 0.088, blue: 0.098), Color(red: 0.047, green: 0.051, blue: 0.058)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.035), .clear], center: UnitPoint(x: 0.5, y: 0.55), startRadius: 0, endRadius: 520)
        }
    }
}

/// Applies an AtlasZoom interpolated by `progress`, animatable so SwiftUI drives the frames.
private struct LivingTreeZoomEffect: ViewModifier, Animatable {
    var zoom: AtlasZoom
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let current = zoom.interpolated(progress)
        content.scaleEffect(current.scale, anchor: .topLeading).offset(current.offset)
    }
}

/// The static tree. Redrawn only when the tree or the canvas size changes (hover, selection and light are drawn
/// on a separate overlay), so a 3,000-element tree is not repainted on every pointer move or animation frame.
struct LivingTreeBaseCanvas: View, Equatable {
    let revision: Int
    let size: CGSize
    let geometry: LivingTreeGeometry
    let model: LivingTreeModel
    static func == (a: Self, b: Self) -> Bool { a.revision == b.revision && a.size == b.size }
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in LivingTreePainter(geometry: geometry, model: model).paintBase(&context) }
            .accessibilityHidden(true)
    }
}

// MARK: - Painting

/// Draws the tree: tapered, translucent branches, soft light at the tips, and a few labels; the overlay draws
/// hover, the selection's path to the trunk and the amber or blue light of measured changes.
struct LivingTreePainter {
    let geometry: LivingTreeGeometry
    let model: LivingTreeModel

    static func color(_ tone: AtlasTone, opacity: Double) -> Color {
        Color(hue: tone.hue, saturation: tone.saturation, brightness: tone.brightness, opacity: opacity)
    }

    /// The branch tone at `opacity` pre-mixed with the charcoal ground into an opaque colour: overlapping branches
    /// (every fork) then join seamlessly instead of stacking into brighter seams.
    static func solid(_ opacity: Double) -> Color {
        let ground = (r: 0.066, g: 0.071, b: 0.08), tone = (r: 0.95, g: 0.935, b: 0.905)
        let a = min(1, max(0, opacity))
        return Color(red: ground.r + (tone.r - ground.r) * a, green: ground.g + (tone.g - ground.g) * a, blue: ground.b + (tone.b - ground.b) * a)
    }

    func paintBase(_ context: inout GraphicsContext) {
        // A faint pool of light where the trunk meets the ground.
        let base = geometry.base, glow = geometry.trunkWidth * 5
        context.fill(Path(ellipseIn: CGRect(x: base.x - glow * 2, y: base.y - glow * 0.35, width: glow * 4, height: glow * 0.7)),
                     with: .radialGradient(Gradient(colors: [Color.white.opacity(0.07), .clear]), center: base, startRadius: 0, endRadius: glow * 2))
        // Thin branches are batched into a few strokes by width and opacity; thick ones are filled tapered ribbons.
        var thin = [Int: Path](), dots = [Int: Path](), cores = [Int: Path]()
        var tips = [(CGPoint, CGFloat, Double)]()
        for branch in geometry.branches {
            guard let element = model[branch.key] else { continue }
            let opacity = LivingTreePalette.opacity(depth: branch.depth, status: element.status, sizeKnown: branch.sizeKnown)
            if !branch.sizeKnown {
                context.stroke(Self.curve(branch), with: .color(Self.color(LivingTreePalette.branch, opacity: opacity)), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, dash: [2, 2.5]))
                context.stroke(Path(ellipseIn: CGRect(x: branch.end.x - 1.8, y: branch.end.y - 1.8, width: 3.6, height: 3.6)), with: .color(Self.color(LivingTreePalette.branch, opacity: opacity)), lineWidth: 0.6)
                continue
            }
            if branch.role == .rest {
                // Grouped small items: a fine tuft of three sprigs ending in one point of light.
                for sprig in Self.sprigs(branch) {
                    thin[Self.bucket(width: max(0.5, branch.startWidth * 0.55), opacity: opacity * 0.8), default: Path()].addPath(sprig)
                }
            } else if branch.startWidth < 1.6 {
                thin[Self.bucket(width: (branch.startWidth + branch.endWidth) / 2, opacity: opacity), default: Path()].addPath(Self.curve(branch))
            } else {
                // A soft body with a finer, brighter core: light carried along the branch.
                context.fill(Self.ribbon(branch), with: .color(Self.solid(opacity * 0.62)))
                cores[Self.bucket(width: max(0.6, min(2.2, branch.startWidth * 0.22)), opacity: min(1, opacity * 0.75)), default: Path()].addPath(Self.curve(branch))
            }
            if branch.glow > 0 {
                if branch.glow >= 2.6 && tips.count < 400 { tips.append((branch.end, branch.glow, opacity)) }
                else {
                    let r = max(0.7, branch.glow * 0.42)
                    dots[Self.bucket(width: 1, opacity: min(1, opacity * 1.25)), default: Path()].addEllipse(in: CGRect(x: branch.end.x - r, y: branch.end.y - r, width: 2 * r, height: 2 * r))
                }
            }
            if element.status == .lowerBound && branch.glow > 0 {
                context.stroke(Path(ellipseIn: CGRect(x: branch.end.x - 2.6, y: branch.end.y - 2.6, width: 5.2, height: 5.2)), with: .color(Self.color(LivingTreePalette.branch, opacity: opacity)), lineWidth: 0.7)
            }
        }
        for (key, path) in thin.sorted(by: { $0.key < $1.key }) {
            let (width, opacity) = Self.unbucket(key)
            context.stroke(path, with: .color(Self.color(LivingTreePalette.branch, opacity: opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        for (key, path) in cores.sorted(by: { $0.key < $1.key }) {
            let (width, opacity) = Self.unbucket(key)
            context.stroke(path, with: .color(Self.color(LivingTreePalette.tip, opacity: opacity * 0.55)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        for (key, path) in dots.sorted(by: { $0.key < $1.key }) { context.fill(path, with: .color(Self.color(LivingTreePalette.tip, opacity: Self.unbucket(key).opacity))) }
        // Soft light at the larger tips.
        for (point, radius, opacity) in tips {
            let r = radius * 2.6
            context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
                         with: .radialGradient(Gradient(colors: [Self.color(LivingTreePalette.tip, opacity: 0.28 * opacity), .clear]), center: point, startRadius: 0, endRadius: r))
            let core = max(0.8, radius * 0.34)
            context.fill(Path(ellipseIn: CGRect(x: point.x - core, y: point.y - core, width: 2 * core, height: 2 * core)), with: .color(Self.color(LivingTreePalette.tip, opacity: min(1, 0.55 + opacity * 0.4))))
        }
        labels(&context)
    }

    /// Names of the main branches, placed beyond their tips where they do not collide.
    private func labels(_ context: inout GraphicsContext) {
        guard let trunk = model.trunkBytes, trunk > 0 else { return }
        var placed = [CGRect]()
        let candidates = geometry.branches.filter { $0.depth >= 1 && $0.depth <= 2 && $0.role != .rest && $0.sizeKnown }
            .compactMap { branch -> (LivingTreeGeometry.Branch, LivingTreeElement)? in model[branch.key].map { (branch, $0) } }
            .filter { Double($0.1.bytes ?? 0) / Double(trunk) >= ($0.0.depth == 1 ? 0.02 : 0.06) }
            .sorted { ($0.1.bytes ?? 0) != ($1.1.bytes ?? 0) ? ($0.1.bytes ?? 0) > ($1.1.bytes ?? 0) : $0.0.key < $1.0.key }
        var labelled = [LivingTreeKey: Int64]()
        var halo = context
        halo.addFilter(.shadow(color: .black.opacity(0.95), radius: 2.5))
        halo.addFilter(.shadow(color: .black.opacity(0.8), radius: 6))
        for (branch, element) in candidates.prefix(16) {
            // A folder that is nearly all of its labelled parent (Users › your home) is named once, by the parent.
            if let parent = element.parent, let parentBytes = labelled[parent], Double(element.bytes ?? 0) >= 0.9 * Double(parentBytes) { continue }
            let name = context.resolve(Text(atlasMiddleTruncated(element.name, keeping: 22)).font(.system(size: 10.5, weight: .medium)).foregroundColor(.white.opacity(0.66)))
            let size = context.resolve(Text(AtlasText.bytes(element.bytes ?? 0)).font(.system(size: 9.5).monospacedDigit()).foregroundColor(.white.opacity(0.4)))
            let a = name.measure(in: CGSize(width: 400, height: 40)), b = size.measure(in: CGSize(width: 400, height: 40))
            // Beside the tip, on the side the branch leans to, clear of its own stroke.
            let leftSide = branch.end.x < geometry.crown.x - 2
            let anchor = CGPoint(x: branch.end.x + (leftSide ? -9 : 9), y: branch.end.y)
            let width = max(a.width, b.width), height = a.height + b.height
            var rect = CGRect(x: leftSide ? anchor.x - width : anchor.x, y: anchor.y - height / 2, width: width, height: height)
            rect.origin.x = min(max(4, rect.origin.x), geometry.size.width - width - 4)
            rect.origin.y = min(max(2, rect.origin.y), geometry.size.height - height - 2)
            guard !placed.contains(where: { $0.insetBy(dx: -6, dy: -3).intersects(rect) }) else { continue }
            placed.append(rect)
            labelled[branch.key] = element.bytes ?? 0
            halo.draw(name, at: CGPoint(x: leftSide ? rect.maxX : rect.minX, y: rect.minY), anchor: leftSide ? .topTrailing : .topLeading)
            halo.draw(size, at: CGPoint(x: leftSide ? rect.maxX : rect.minX, y: rect.minY + a.height), anchor: leftSide ? .topTrailing : .topLeading)
        }
    }

    func paintOverlay(_ context: inout GraphicsContext, now: Date, illumination: LivingTreeIllumination, reduceMotion: Bool, hovered: LivingTreeKey?, chain: [LivingTreeKey], focus: LivingTreeKey?) {
        // Measured changes: amber for growth, cool blue for reduction, added as light and fading.
        var lit = context
        lit.blendMode = .plusLighter
        for (node, _) in illumination.glows {
            guard let branch = geometry[.node(node)], let light = illumination.intensity(of: node, at: now, reduceMotion: reduceMotion) else { continue }
            let tone = LivingTreePalette.tone(for: light.trend)
            if branch.startWidth >= 1.6 { lit.fill(Self.ribbon(branch), with: .color(Self.color(tone, opacity: 0.5 * light.value))) }
            else { lit.stroke(Self.curve(branch), with: .color(Self.color(tone, opacity: 0.8 * light.value)), style: StrokeStyle(lineWidth: max(1, branch.startWidth + 0.6), lineCap: .round)) }
            let r = (max(branch.glow, 2.5) + 4) * (1 + light.value)
            lit.fill(Path(ellipseIn: CGRect(x: branch.end.x - r, y: branch.end.y - r, width: 2 * r, height: 2 * r)),
                     with: .radialGradient(Gradient(colors: [Self.color(tone, opacity: 0.5 * light.value), .clear]), center: branch.end, startRadius: 0, endRadius: r))
        }
        // The selection's path back to the trunk, then the selection itself.
        for key in chain.dropLast() {
            guard let branch = geometry[key] else { continue }
            context.stroke(Self.curve(branch), with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: max(0.9, min(3, branch.startWidth * 0.3)), lineCap: .round))
        }
        if let focus, let branch = geometry[focus] {
            context.stroke(Self.curve(branch), with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: max(1.4, min(4, branch.startWidth * 0.45)), lineCap: .round))
            context.stroke(Path(ellipseIn: CGRect(x: branch.end.x - 5, y: branch.end.y - 5, width: 10, height: 10)), with: .color(.accentColor), lineWidth: 1.6)
        }
        if let hovered, hovered != focus, let branch = geometry[hovered] {
            context.stroke(Self.curve(branch), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: max(1.2, min(3.5, branch.startWidth * 0.4)), lineCap: .round))
        }
    }

    // MARK: Shapes

    static func curve(_ branch: LivingTreeGeometry.Branch) -> Path {
        var path = Path()
        path.move(to: branch.start)
        path.addCurve(to: branch.end, control1: branch.control1, control2: branch.control2)
        return path
    }

    /// A tapered ribbon along the curve with a rounded tip.
    static func ribbon(_ branch: LivingTreeGeometry.Branch) -> Path {
        let samples = branch.startWidth > 6 ? 14 : 9
        var left = [CGPoint](), right = [CGPoint]()
        left.reserveCapacity(samples + 1); right.reserveCapacity(samples + 1)
        for step in 0...samples {
            let t = CGFloat(step) / CGFloat(samples)
            let p = branch.point(at: t), d = branch.tangent(at: t), half = branch.width(at: t) / 2
            left.append(CGPoint(x: p.x - d.dy * half, y: p.y + d.dx * half))
            right.append(CGPoint(x: p.x + d.dy * half, y: p.y - d.dx * half))
        }
        var path = Path()
        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        let d = branch.tangent(at: 1), half = branch.endWidth / 2
        path.addQuadCurve(to: right[samples], control: CGPoint(x: branch.end.x + d.dx * half * 1.4, y: branch.end.y + d.dy * half * 1.4))
        for point in right.reversed().dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// Three short sprigs fanning from a grouped remainder's stem (deterministic).
    static func sprigs(_ branch: LivingTreeGeometry.Branch) -> [Path] {
        let stem = branch.point(at: 0.55), d = branch.tangent(at: 0.55)
        let length = hypot(branch.end.x - stem.x, branch.end.y - stem.y)
        var result = [curveFromStart(branch, to: 0.55)]
        for spread in [-0.42, 0.0, 0.42] {
            let angle = atan2(Double(d.dy), Double(d.dx)) + spread
            var sprig = Path()
            sprig.move(to: stem)
            let end = CGPoint(x: stem.x + CGFloat(cos(angle)) * length * (spread == 0 ? 1 : 0.8), y: stem.y + CGFloat(sin(angle)) * length * (spread == 0 ? 1 : 0.8))
            sprig.addQuadCurve(to: end, control: CGPoint(x: stem.x + d.dx * length * 0.5, y: stem.y + d.dy * length * 0.5))
            result.append(sprig)
        }
        return result
    }

    private static func curveFromStart(_ branch: LivingTreeGeometry.Branch, to t: CGFloat) -> Path {
        var path = Path()
        path.move(to: branch.start)
        for step in 1...6 { path.addLine(to: branch.point(at: t * CGFloat(step) / 6)) }
        return path
    }

    /// Width in quarter points and opacity in 5% steps, packed into one key for batching.
    static func bucket(width: CGFloat, opacity: Double) -> Int { Int((width * 4).rounded()) * 100 + Int((opacity * 20).rounded()) }
    static func unbucket(_ key: Int) -> (width: CGFloat, opacity: Double) { (CGFloat(key / 100) / 4, Double(key % 100) / 20) }
}

/// A small key to the illumination and states.
private struct LivingTreeLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            item("Growth") { Circle().fill(LivingTreePainter.color(LivingTreePalette.growth, opacity: 0.95)) }
            item("Reduction") { Circle().fill(LivingTreePainter.color(LivingTreePalette.reduction, opacity: 0.95)) }
            item("Size unknown") { Circle().strokeBorder(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5])) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .help("Branches light briefly when the inventory measures a folder or file larger (amber) or smaller (blue) than its previous complete measurement. Changes are in indexed allocation, not space freed or consumed on disk.")
    }
    private func item<S: View>(_ label: String, @ViewBuilder _ swatch: () -> S) -> some View {
        HStack(spacing: 4) { swatch().frame(width: 8, height: 8); Text(label) }
    }
}

// MARK: - Text

/// Words for elements: the hover lens, accessibility labels.
enum LivingTreeText {
    static func lens(_ element: LivingTreeElement, model: LivingTreeModel, glow: LivingTreeIllumination.Glow?) -> (title: String, value: String, notes: [String]) {
        var notes = [String]()
        let title: String, value: String
        switch element.role {
        case .rest:
            let folder = element.parent.flatMap { model[$0]?.name } ?? "this folder"
            title = "Other items in \(folder)"
            value = "\(element.count.formatted()) items" + (element.bytes.map { " · \(AtlasText.bytes($0))" } ?? "")
            if element.unmeasured > 0 { notes.append("\(element.unmeasured.formatted()) without a measured size, not counted as zero") }
            notes.append("Click to list them in the Navigator")
        case .unmeasured:
            title = element.name
            value = "Size unknown"
            if let node = element.node { notes.append(InventoryNodePresentation.coverage(node)) }
            notes.append("Not drawn by size: its size was not measured")
        default:
            title = element.name
            if let node = element.node {
                let size = InventoryNodePresentation.compactSize(InventoryMapPlan.weight(node), node: node, formatter: AtlasText.bytes)
                value = size + (node.kind == .directory ? " · \(node.childCount.formatted()) items" : "")
                if let note = InventoryNodePresentation.explorerNote(node) { notes.append(note) }
            } else { value = element.bytes.map(AtlasText.bytes) ?? "Size unknown" }
        }
        if let glow { notes.append(change(glow)) }
        return (title, value, notes)
    }

    static func change(_ glow: LivingTreeIllumination.Glow) -> String {
        let amount = AtlasText.bytes(abs(glow.deltaBytes))
        let words = glow.trend == .growth ? "Grew by \(amount)" : "Shrank by \(amount)"
        let basis = glow.trend == .reduction ? " of indexed allocation (not necessarily space freed)" : " of indexed allocation"
        return words + basis + (glow.confidence == .observedLowerBound ? " · compared on the readable part only" : "")
    }

    static func spoken(_ element: LivingTreeElement, glow: LivingTreeIllumination.Glow?) -> String {
        let kind: String
        switch element.role {
        case .trunk: kind = "current folder"
        case .branch: kind = "folder"
        case .file: kind = "file"
        case .rest: kind = "\(element.count.formatted()) grouped items"
        case .unmeasured: kind = "size unknown"
        }
        var parts = [element.role == .rest ? "Other items" : element.name, kind]
        if let bytes = element.bytes { parts.append(AtlasText.bytes(bytes)) }
        if let glow { parts.append(change(glow)) }
        return parts.joined(separator: ", ")
    }

    /// The largest elements, for accessibility (bounded).
    static func accessibleElements(_ model: LivingTreeModel, limit: Int) -> [LivingTreeKey] {
        Array(model.order.dropFirst().sorted { a, b in
            let x = model[a]!.bytes ?? -1, y = model[b]!.bytes ?? -1
            return x != y ? x > y : a < b
        }.prefix(limit))
    }
}
