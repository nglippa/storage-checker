import SwiftUI

/// Storage Atlas: the explorer's current folder as a lit, layered landscape of plates. Geometry is the
/// tested InventoryMapPlan (area proportional to indexed allocated size, exact Other items and residual);
/// this view only paints it. One Canvas draws every plate, so hundreds of regions stay cheap to redraw.
struct StorageAtlasView: View {
    @ObservedObject var browser: InventoryBrowserModel
    @ObservedObject var explorer: InventoryExplorerController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover: (hit: AtlasHit, location: CGPoint)?
    @State private var zoom = AtlasZoom.identity
    @State private var zoomProgress = 1.0
    @State private var fade = 1.0
    @State private var geometry = AtlasGeometryCache()

    static let nestedMinimum = CGSize(width: 150, height: 96)
    static let nestedFolders = 16
    static let stripHeight: CGFloat = 20
    static let gap: CGFloat = 3

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                let rect = CGRect(origin: .zero, size: proxy.size)
                content(in: rect)
                    .modifier(AtlasZoomEffect(zoom: zoom, progress: zoomProgress))
                    .opacity(fade)
                    .clipped()
            }
            .padding(.horizontal, 14).padding(.bottom, 6)
            footer
        }
        .background(ground)
        .accessibilityIdentifier("inventory.atlas")
        .onChange(of: folder?.id) { old, new in
            hover = nil
            transition(from: old, to: new)
        }
        .onChange(of: folder.map { explorer.mapStart($0.id) }) { _, _ in hover = nil }
    }

    private var dark: Bool { colorScheme == .dark }
    private var folder: InventoryNode? { explorer.state.rootID.flatMap { explorer.state.node($0) } }

    private var ground: some View {
        LinearGradient(colors: dark ? [Color(white: 0.10), Color(white: 0.075)] : [Color(white: 0.965), Color(white: 0.925)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func plan(in rect: CGRect) -> InventoryMapPlan? {
        guard let folder, let list = explorer.state.children[folder.id], explorer.mapReady(folder.id) else { return nil }
        return InventoryMapPlan(items: list.items, start: explorer.mapStart(folder.id), beyond: explorer.beyond(folder.id),
                                canLoadMore: explorer.state.canLoadMore(folder.id), in: rect)
    }

    // MARK: Content

    @ViewBuilder private func content(in rect: CGRect) -> some View {
        if let folder, let list = explorer.state.children[folder.id] {
            if list.items.isEmpty && list.next == nil && folder.status != .complete {
                placeholder("Contents not available · \(InventoryNodePresentation.coverage(folder))")
            } else if explorer.mapStart(folder.id) >= list.items.count && explorer.state.loading.contains(folder.id) {
                placeholder("Loading…", spinning: true)
            } else if let plan = plan(in: rect) {
                if plan.tiles.isEmpty {
                    if list.items.isEmpty && list.next == nil { placeholder("Empty folder") }
                    else if let other = plan.other, other.unmeasured < other.count {
                        placeholder(other.unmeasured == 0 ? "\(other.count.formatted()) items, none using allocated space"
                                    : "\(other.count.formatted()) items: \((other.count - other.unmeasured).formatted()) use no allocated space, \(other.unmeasured.formatted()) have no measured size")
                    } else { placeholder("Nothing here has a measured size yet.") }
                } else {
                    landscape(plan, folder: folder, size: rect.size)
                }
            } else {
                placeholder("Adding up the remaining items…", spinning: true)
            }
        } else if explorer.state.rootID != nil {
            placeholder("Loading…", spinning: true)
        }
    }

    private func placeholder(_ text: String, spinning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.small) }
            Text(text).foregroundStyle(.secondary)
        }.font(.callout).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The top-level plates that are large enough to show their own contents, in map order.
    static func regions(_ plan: InventoryMapPlan) -> [Int64] {
        plan.tiles.filter { tile in
            guard let node = tile.node, node.kind == .directory, node.status != .unknown, node.childCount > 0 else { return false }
            return tile.rect.width >= nestedMinimum.width && tile.rect.height >= nestedMinimum.height
        }.prefix(nestedFolders).map(\.id)
    }

    /// Inner plans of the regions whose contents are loaded, with each inner plan's origin in map space.
    private func innerPlans(_ plan: InventoryMapPlan, regions: [Int64]) -> [Int64: (plan: InventoryMapPlan, origin: CGPoint, content: InventoryNestedContent)] {
        var result = [Int64: (plan: InventoryMapPlan, origin: CGPoint, content: InventoryNestedContent)]()
        for tile in plan.tiles where regions.contains(tile.id) {
            guard let node = tile.node, let content = explorer.nested[node.id] else { continue }
            let plate = tile.rect.insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
            let inner = CGRect(x: 0, y: 0, width: max(0, plate.width - 8), height: max(0, plate.height - Self.stripHeight - 4))
            let childBytes = content.page.items.reduce(Int64(0)) { $0 + (InventoryMapPlan.weight($1) ?? 0) } + (content.remainder?.allocated ?? 0)
            let residual = max(0, (InventoryMapPlan.weight(node) ?? 0) - childBytes)
            let innerPlan = InventoryMapPlan(items: content.page.items, start: 0, beyond: content.remainder, canLoadMore: false, in: inner, maxTiles: 40, residual: residual)
            result[tile.id] = (innerPlan, CGPoint(x: plate.minX + 4, y: plate.minY + Self.stripHeight), content)
        }
        return result
    }

    private func landscape(_ plan: InventoryMapPlan, folder: InventoryNode, size: CGSize) -> some View {
        let regions = Self.regions(plan)
        let inner = innerPlans(plan, regions: regions)
        let hits = inner.mapValues { (plan: $0.plan, origin: $0.origin) }
        let selected = explorer.selection
        let highlighted = plan.tile(holding: selected) { explorer.state.node($0)?.parentID }
        geometry.record(folder: folder.id, plan: plan, inner: hits)
        // When most entries share an earlier-size state the footer states it once; plates then drop the
        // per-plate dashes (hover and the Inspector still give each item's exact state).
        let shared = explorer.state.children[folder.id].flatMap { InventoryNodePresentation.sharedFreshness($0.items) } != nil
        let painter = AtlasPainter(plan: plan, inner: inner, dark: dark, selected: selected, highlighted: highlighted, hovered: hover?.hit, quietEarlier: shared)
        return Canvas(rendersAsynchronously: false) { context, _ in painter.paint(&context) }
            .overlay(alignment: .topLeading) { lens(plan: plan, inner: inner, size: size) }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): hover = AtlasHitTest.hit(point, plan: plan, nested: hits).map { ($0, point) }
                case .ended: hover = nil
                }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                if let hit = AtlasHitTest.hit(value.location, plan: plan, nested: hits) { open(hit, plan: plan, inner: inner) }
            }.exclusively(before: SpatialTapGesture().onEnded { value in
                if let hit = AtlasHitTest.hit(value.location, plan: plan, nested: hits) { choose(hit, plan: plan, inner: inner, folder: folder) }
            }))
            .task(id: regions) { explorer.requestNested(regions) }
            .accessibilityElement(children: .contain)
            .accessibilityChildren {
                ForEach(plan.tiles) { tile in
                    Rectangle().frame(width: tile.rect.width, height: tile.rect.height).position(x: tile.rect.midX, y: tile.rect.midY)
                        .accessibilityLabel(AtlasText.detail(tile)).accessibilityAddTraits(.isButton)
                }
            }
    }

    // MARK: Interaction

    private func node(for hit: AtlasHit, plan: InventoryMapPlan, inner: [Int64: (plan: InventoryMapPlan, origin: CGPoint, content: InventoryNestedContent)]) -> (tile: InventoryMapPlan.Tile, region: InventoryNode?)? {
        if let region = hit.region, let entry = inner[region], let tile = entry.plan.tiles.first(where: { $0.id == hit.tile }) {
            return (tile, entry.content.chain.last ?? plan.tiles.first { $0.id == region }?.node)
        }
        return plan.tiles.first { $0.id == hit.tile }.map { ($0, nil) }
    }

    /// Single click: select (the Navigator and Inspector follow); Other items opens its next window.
    private func choose(_ hit: AtlasHit, plan: InventoryMapPlan, inner: [Int64: (plan: InventoryMapPlan, origin: CGPoint, content: InventoryNestedContent)], folder: InventoryNode) {
        guard let found = node(for: hit, plan: plan, inner: inner) else { return }
        switch found.tile.content {
        case .node(let node): explorer.select(node)
        case .other(let other):
            if found.region == nil, other.canDrill { withAnimation(motion) { explorer.drill(folder.id, to: other.nextStart) } }
            else if let region = found.region { explorer.select(region) }
        case .residual: if let region = found.region { explorer.select(region) }
        }
    }

    /// Double click: enter a folder (or the region holding a grouped plate).
    private func open(_ hit: AtlasHit, plan: InventoryMapPlan, inner: [Int64: (plan: InventoryMapPlan, origin: CGPoint, content: InventoryNestedContent)]) {
        guard let found = node(for: hit, plan: plan, inner: inner) else { return }
        switch found.tile.content {
        case .node(let node) where node.kind == .directory: browser.navigate(node)
        case .node: break
        case .other, .residual: if let region = found.region { browser.navigate(region) }
        }
    }

    private var motion: Animation? { reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38) }

    /// Folder entry and exit: the new view starts at the plate the folder occupied (entering) or enlarged so
    /// the folder you left fills the view (leaving), then settles. Uniform scaling only; Reduce Motion fades.
    private func transition(from old: Int64?, to new: Int64?) {
        guard let new else { return }
        let size = geometry.size
        var start: AtlasZoom?
        if AtlasZoom.animates(reduceMotion: reduceMotion), let old, size.width > 0 {
            if let rect = geometry.rect(of: new, in: old) { start = AtlasZoom.start(entering: true, rect: rect, in: size) }
            else if let rect = geometry.rect(of: old, in: new) { start = AtlasZoom.start(entering: false, rect: rect, in: size) }
        }
        if let start {
            zoom = start; zoomProgress = 0; fade = 0.35
            withAnimation(.smooth(duration: 0.38)) { zoomProgress = 1; fade = 1 }
        } else {
            zoom = .identity; zoomProgress = 1; fade = 0.6
            withAnimation(.easeOut(duration: 0.15)) { fade = 1 }
        }
    }

    // MARK: Lens, header, footer

    @ViewBuilder private func lens(plan: InventoryMapPlan, inner: [Int64: (plan: InventoryMapPlan, origin: CGPoint, content: InventoryNestedContent)], size: CGSize) -> some View {
        if let hover, let found = node(for: hover.hit, plan: plan, inner: inner) {
            let lines = AtlasText.lens(found.tile)
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(lines.value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if let note = lines.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: 260, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 8, y: 3)
            .offset(x: min(max(4, hover.location.x + 14), max(4, size.width - 270)), y: min(max(4, hover.location.y + 16), max(4, size.height - 70)))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let folder, let parent = folder.parentID, let parentNode = browser.breadcrumbs.first(where: { $0.id == parent }) {
                Button { browser.navigate(parentNode) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).help("Up to \(parentNode.parentID == nil ? "Startup Data" : parentNode.name)")
                    .accessibilityLabel("Enclosing folder")
            }
            Label("Showing indexed allocation · Shared APFS blocks may be counted more than once", systemImage: "info.circle")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help("Areas show each item's allocated size as indexed. APFS clones and snapshots share blocks, so the same physical space can appear in several places, and deleting an item frees only the blocks nothing else shares. This is not a measure of reclaimable space.")
                .accessibilityIdentifier("inventory.map.basis")
            if let folder, let start = explorer.mapWindows[folder.id]?.last {
                Text("·").foregroundStyle(.tertiary)
                Text("Other items from #\((start + 1).formatted())").font(.caption).foregroundStyle(.secondary)
                Button { withAnimation(motion) { explorer.mapBack(folder.id) } } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            Spacer()
            AtlasLegend(dark: dark)
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 7)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("Click to select · double-click to open").font(.caption).foregroundStyle(.tertiary)
        }.padding(.horizontal, 16).frame(height: 24).accessibilityIdentifier("inventory.map.status")
    }

    private var footerText: String {
        guard let folder, let plan = plan(in: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return " " }
        var parts = [String]()
        if let freshness = InventoryNodePresentation.sharedFreshnessText(explorer.state.children[folder.id].flatMap { InventoryNodePresentation.sharedFreshness($0.items) }) { parts.append(freshness) }
        if let other = plan.other, other.unmeasured > 0 {
            parts.append("\(other.unmeasured.formatted()) item\(other.unmeasured == 1 ? "" : "s") without a measured size are not drawn")
        }
        return parts.isEmpty ? "Area is proportional to indexed allocated size" : parts.joined(separator: " · ")
    }
}

/// Remembers where each folder was drawn, so entering and leaving can zoom from the right place. A
/// reference type: recording during drawing does not trigger another update.
final class AtlasGeometryCache {
    private var rects = [Int64: [Int64: CGRect]]()
    private(set) var size = CGSize.zero
    private var order = InventoryRecency(capacity: 32)

    func record(folder: Int64, plan: InventoryMapPlan, inner: [Int64: (plan: InventoryMapPlan, origin: CGPoint)]) {
        var map = [Int64: CGRect]()
        for tile in plan.tiles where tile.id >= 0 { map[tile.id] = tile.rect }
        for (_, entry) in inner {
            for tile in entry.plan.tiles where tile.id >= 0 { map[tile.id] = tile.rect.offsetBy(dx: entry.origin.x, dy: entry.origin.y) }
        }
        rects[folder] = map
        size = CGSize(width: plan.tiles.map(\.rect.maxX).max() ?? 0, height: plan.tiles.map(\.rect.maxY).max() ?? 0)
        for dropped in order.use(folder) { rects[dropped] = nil }
    }

    func rect(of child: Int64, in folder: Int64) -> CGRect? { rects[folder]?[child] }
}

/// Applies an AtlasZoom interpolated by `progress`, animatable so SwiftUI drives the frames.
private struct AtlasZoomEffect: ViewModifier, Animatable {
    var zoom: AtlasZoom
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let current = zoom.interpolated(progress)
        content.scaleEffect(current.scale, anchor: .topLeading).offset(current.offset)
    }
}

/// Text shown for plates (labels, lens, accessibility).
enum AtlasText {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    static func detail(_ tile: InventoryMapPlan.Tile) -> String {
        let lens = lens(tile)
        return ([lens.title, lens.value] + (lens.note.map { [$0] } ?? [])).joined(separator: " · ")
    }

    static func lens(_ tile: InventoryMapPlan.Tile) -> (title: String, value: String, note: String?) {
        switch tile.content {
        case .node(let node):
            let size = InventoryNodePresentation.compactSize(InventoryMapPlan.weight(node), node: node, formatter: bytes)
            let note = InventoryNodePresentation.explorerNote(node)
            let items = node.kind == .directory ? " · \(node.childCount.formatted()) items" : ""
            return (node.name, size + items, note)
        case .other(let other):
            var note = other.unmeasured > 0 ? "\(other.unmeasured.formatted()) without a measured size" : nil
            if other.canDrill { note = [note, "Click to show them"].compactMap { $0 }.joined(separator: " · ") }
            return ("Other items", "\(other.count.formatted()) · \(bytes(other.allocated))", note)
        case .residual:
            return ("Rest of folder", bytes(tile.bytes), "Other entries, folder metadata or items still being listed")
        }
    }

    /// The longest middle-truncated form of `text` whose rendered width fits `width`, measured with the
    /// font it is drawn in (not an estimated character width). Nil when even a short form does not fit.
    static func fitted(_ text: String, width: CGFloat, in context: GraphicsContext, style: (Text) -> Text) -> GraphicsContext.ResolvedText? {
        guard width > 12 else { return nil }
        func resolved(_ count: Int) -> GraphicsContext.ResolvedText { context.resolve(style(Text(atlasMiddleTruncated(text, keeping: count)))) }
        func fits(_ candidate: GraphicsContext.ResolvedText) -> Bool { candidate.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width <= width }
        let full = resolved(text.count)
        if fits(full) { return full }
        var low = 1, high = text.count - 1, best: GraphicsContext.ResolvedText?
        while low <= high {
            let middle = (low + high) / 2, candidate = resolved(middle)
            if fits(candidate) { best = candidate; low = middle + 1 } else { high = middle - 1 }
        }
        // Fewer than four visible characters is not a useful label.
        return low - 1 >= 4 ? best : nil
    }
}

/// Draws the landscape: raised plates with light from above, recessed regions holding their contents, and
/// the state cues. Values are precomputed so drawing does no lookups.
private struct AtlasPainter {
    let plan: InventoryMapPlan
    let inner: [Int64: (plan: InventoryMapPlan, origin: CGPoint, content: InventoryNestedContent)]
    let dark: Bool
    let selected: Int64?
    let highlighted: Int64?
    let hovered: AtlasHit?
    let quietEarlier: Bool

    func paint(_ context: inout GraphicsContext) {
        for (index, tile) in plan.tiles.enumerated() {
            let hue = AtlasPalette.regionHue(index)
            let rect = tile.rect.insetBy(dx: StorageAtlasView.gap / 2, dy: StorageAtlasView.gap / 2)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let isHovered = hovered?.tile == tile.id && hovered?.region == nil
            if let entry = inner[tile.id], let node = tile.node {
                region(&context, rect: rect, node: node, regionID: tile.id, entry: entry, hue: hue, selected: tile.id == highlighted, hovered: isHovered)
            } else {
                plate(&context, tile: tile, rect: rect, hue: hue, depth: 0, selected: tile.id == highlighted, hovered: isHovered)
            }
        }
    }

    private func tone(_ tile: InventoryMapPlan.Tile, hue: Double, depth: Int) -> (AtlasTone, AtlasPalette.Treatment, Bool) {
        switch tile.content {
        case .node(let node):
            let treatment = AtlasPalette.treatment(node)
            return (AtlasPalette.tone(hue: hue, isFolder: node.kind == .directory, depth: depth, treatment: treatment, dark: dark), treatment, node.kind == .directory)
        case .other: return (AtlasPalette.tone(hue: hue, isFolder: false, depth: depth, treatment: .other, dark: dark), .other, false)
        case .residual: return (AtlasPalette.tone(hue: hue, isFolder: false, depth: depth, treatment: .residual, dark: dark), .residual, false)
        }
    }

    private func color(_ tone: AtlasTone, brightness delta: Double = 0, opacity: Double? = nil) -> Color {
        Color(hue: tone.hue, saturation: tone.saturation, brightness: min(1, max(0, tone.brightness + delta)), opacity: opacity ?? tone.opacity)
    }

    /// A raised plate: soft shadow (top level), light falling from above, a highlight along the top edge.
    private func plate(_ context: inout GraphicsContext, tile: InventoryMapPlan.Tile, rect: CGRect, hue: Double, depth: Int, selected: Bool, hovered: Bool) {
        let (tone, treatment, isFolder) = tone(tile, hue: hue, depth: depth)
        let radius: CGFloat = min(depth == 0 ? 6 : 4, rect.width / 2, rect.height / 2)
        let shape = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        let lift = hovered ? 0.06 : 0
        if treatment != .residual {
            var shadowed = context
            if depth == 0 || selected {
                shadowed.addFilter(.shadow(color: selected ? Color.accentColor.opacity(0.55) : .black.opacity(dark ? 0.45 : 0.16),
                                           radius: selected ? 7 : (depth == 0 ? 5 : 2), x: 0, y: selected ? 0 : (depth == 0 ? 2.5 : 1)))
            }
            shadowed.fill(shape, with: .linearGradient(Gradient(colors: [color(tone, brightness: 0.06 + lift), color(tone, brightness: -0.05 + lift)]),
                                                      startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        } else {
            context.fill(shape, with: .color(color(tone)))
        }
        // Light catching the top edge.
        if treatment != .residual && rect.height > 6 && rect.width > radius * 2 + 2 {
            var edge = Path()
            edge.move(to: CGPoint(x: rect.minX + radius, y: rect.minY + 0.75)); edge.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY + 0.75))
            context.stroke(edge, with: .color(.white.opacity(dark ? 0.16 : 0.55)), lineWidth: 1)
        }
        hatch(&context, shape: shape, rect: rect, when: treatment == .partial)
        if selected { context.stroke(shape, with: .color(.accentColor), lineWidth: 2) }
        else if hovered { context.stroke(shape, with: .color(.primary.opacity(0.35)), lineWidth: 1) }
        else if (treatment == .earlier && !quietEarlier) || treatment == .other {
            context.stroke(shape, with: .color(color(tone, brightness: dark ? 0.22 : -0.25, opacity: 0.8)), style: StrokeStyle(lineWidth: 1, dash: treatment == .other ? [1.5, 2.5] : [4, 2.5]))
        }
        label(&context, tile: tile, rect: rect, depth: depth, emphasis: isFolder)
    }

    /// A recessed basin holding a folder's contents, with its name on a strip along the top.
    private func region(_ context: inout GraphicsContext, rect: CGRect, node: InventoryNode, regionID: Int64, entry: (plan: InventoryMapPlan, origin: CGPoint, content: InventoryNestedContent), hue: Double, selected: Bool, hovered: Bool) {
        let treatment = AtlasPalette.treatment(node)
        let tone = AtlasPalette.tone(hue: hue, isFolder: true, depth: 0, treatment: treatment, dark: dark)
        let shape = Path(roundedRect: rect, cornerRadius: 7, style: .continuous)
        var shadowed = context
        shadowed.addFilter(.shadow(color: selected ? Color.accentColor.opacity(0.55) : .black.opacity(dark ? 0.5 : 0.18), radius: selected ? 8 : 6, x: 0, y: selected ? 0 : 3))
        shadowed.fill(shape, with: .color(color(tone, brightness: dark ? -0.16 : -0.08)))
        // The strip: the region's name and size, lit like a plate.
        let strip = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: StorageAtlasView.stripHeight)
        context.fill(Path(roundedRect: strip, cornerRadii: RectangleCornerRadii(topLeading: 7, topTrailing: 7), style: .continuous),
                     with: .linearGradient(Gradient(colors: [color(tone, brightness: 0.04), color(tone, brightness: -0.04)]), startPoint: CGPoint(x: strip.midX, y: strip.minY), endPoint: CGPoint(x: strip.midX, y: strip.maxY)))
        let title = ([node.name] + entry.content.chain.map(\.name)).joined(separator: " › ")
        let size = InventoryNodePresentation.compactSize(InventoryMapPlan.weight(node), node: node, formatter: AtlasText.bytes)
        if rect.width >= 84 {
            let sizeText = context.resolve(Text(size).font(.system(size: 10.5).monospacedDigit()).foregroundColor(.secondary))
            let sizeWidth = sizeText.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
            context.draw(sizeText, at: CGPoint(x: strip.maxX - 8, y: strip.midY), anchor: .trailing)
            if let titleText = AtlasText.fitted(title, width: rect.width - 16 - sizeWidth - 10, in: context, style: { $0.font(.system(size: 11, weight: .semibold)).foregroundColor(.primary.opacity(0.9)) }) {
                context.draw(titleText, at: CGPoint(x: strip.minX + 8, y: strip.midY), anchor: .leading)
            }
        }
        // Contents: smaller raised plates in the same hue, a step lighter.
        for tile in entry.plan.tiles {
            let local = tile.rect.offsetBy(dx: entry.origin.x, dy: entry.origin.y).insetBy(dx: 1, dy: 1)
            guard local.width > 0.5, local.height > 0.5 else { continue }
            let isHovered = self.hovered?.tile == tile.id && self.hovered?.region == regionID
            plate(&context, tile: tile, rect: local, hue: hue, depth: 1, selected: tile.id == self.selected, hovered: isHovered)
        }
        hatch(&context, shape: shape, rect: rect, when: treatment == .partial)
        if selected { context.stroke(shape, with: .color(.accentColor), lineWidth: 2) }
        else if hovered { context.stroke(shape, with: .color(.primary.opacity(0.35)), lineWidth: 1) }
        else if treatment == .earlier && !quietEarlier { context.stroke(shape, with: .color(color(tone, brightness: dark ? 0.2 : -0.25, opacity: 0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 2.5])) }
    }

    /// Partial measurements are hatched; nothing else changes the plate's meaning.
    private func hatch(_ context: inout GraphicsContext, shape: Path, rect: CGRect, when partial: Bool) {
        guard partial else { return }
        var lines = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX { lines.move(to: CGPoint(x: x, y: rect.maxY)); lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY)); x += 7 }
        var clipped = context
        clipped.clip(to: shape)
        clipped.stroke(lines, with: .color(.white.opacity(dark ? 0.12 : 0.45)), lineWidth: 1)
    }

    /// Name and size, only where they stay legible: 84 × 40 pt at the top level, 96 × 42 pt inside regions.
    private func label(_ context: inout GraphicsContext, tile: InventoryMapPlan.Tile, rect: CGRect, depth: Int, emphasis: Bool) {
        let fits = depth == 0 ? rect.width >= 84 && rect.height >= 40 : rect.width >= 96 && rect.height >= 42
        guard fits else { return }
        let lens = AtlasText.lens(tile)
        let value: String
        switch tile.content {
        case .node(let node): value = InventoryNodePresentation.compactSize(InventoryMapPlan.weight(node), node: node, formatter: AtlasText.bytes)
        default: value = lens.value
        }
        let origin = CGPoint(x: rect.minX + 8, y: rect.minY + 7)
        // Measured against the rendered font; a label that cannot show at least a few characters is omitted.
        guard let title = AtlasText.fitted(lens.title, width: rect.width - 16, in: context, style: { $0.font(.system(size: depth == 0 ? 12 : 11, weight: emphasis ? .semibold : .medium)).foregroundColor(.primary.opacity(0.92)) }) else { return }
        context.draw(title, at: origin, anchor: .topLeading)
        if let valueText = AtlasText.fitted(value, width: rect.width - 16, in: context, style: { $0.font(.system(size: 10.5).monospacedDigit()).foregroundColor(.secondary) }) {
            context.draw(valueText, at: CGPoint(x: origin.x, y: origin.y + (depth == 0 ? 16 : 15)), anchor: .topLeading)
        }
    }
}

/// A compact key to the plate treatments.
private struct AtlasLegend: View {
    let dark: Bool
    var body: some View {
        HStack(spacing: 12) {
            item("Folder") { RoundedRectangle(cornerRadius: 2.5).fill(Color(hue: AtlasPalette.regionHue(0), saturation: dark ? 0.42 : 0.3, brightness: dark ? 0.46 : 0.78)) }
            item("File") { RoundedRectangle(cornerRadius: 2.5).fill(Color(hue: AtlasPalette.regionHue(0), saturation: 0.1, brightness: dark ? 0.38 : 0.86)) }
            item("Partial") {
                ZStack {
                    RoundedRectangle(cornerRadius: 2.5).fill(Color(hue: AtlasPalette.regionHue(0), saturation: 0.35, brightness: dark ? 0.44 : 0.78))
                    Path { p in p.move(to: CGPoint(x: 0, y: 10)); p.addLine(to: CGPoint(x: 10, y: 0)); p.move(to: CGPoint(x: -4, y: 6)); p.addLine(to: CGPoint(x: 6, y: -4)); p.move(to: CGPoint(x: 4, y: 14)); p.addLine(to: CGPoint(x: 14, y: 4)) }
                        .stroke(.white.opacity(0.45), lineWidth: 1).clipShape(RoundedRectangle(cornerRadius: 2.5))
                }
            }
            item("Earlier size") { RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2.5, 1.5])) }
        }.font(.caption).foregroundStyle(.secondary)
    }
    private func item<S: View>(_ label: String, @ViewBuilder _ swatch: () -> S) -> some View {
        HStack(spacing: 4) { swatch().frame(width: 10, height: 10); Text(label) }
    }
}
