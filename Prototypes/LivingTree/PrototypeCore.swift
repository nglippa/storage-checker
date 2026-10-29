import SwiftUI
import AppKit

// Living Tree visualization prototypes (research milestone; not compiled into the app). Both prototypes read the
// controller's `LivingTreeModel` — the same bounded catalog read, element budget and byte values as the production
// Living Tree — and only draw it differently. Nothing here writes to the catalog or touches cleanup.

// MARK: Model adapter

/// One drawable element of the tree, flattened for fast layout and hit testing.
struct ProtoNode {
    let key: LivingTreeKey
    let parent: Int
    var children: [Int] = []
    /// The catalog row (nil for a grouped remainder): what "explore" navigates to.
    let node: InventoryNode?
    let name: String
    /// Full path, so repeated folder names are distinguishable.
    let path: String
    let bytes: Int64?
    /// Bytes, or 0 when the size is not measured (drawn as a stub, never as a size).
    let weight: Double
    let count: Int64
    let role: LivingTreeElement.Role
    let depth: Int
    let expanded: Bool
    let isFolder: Bool
    /// Leaves beneath this element as drawn (1 for a leaf).
    var leaves = 1
}

struct ProtoTree {
    private(set) var nodes: [ProtoNode] = []
    private(set) var index: [LivingTreeKey: Int] = [:]
    let rootName: String
    var root: ProtoNode { nodes[0] }

    init(_ model: LivingTreeModel) {
        rootName = model[model.rootKey]?.name ?? "Folder"
        var paths = [LivingTreeKey: String]()
        for key in model.order {
            guard let element = model[key] else { continue }
            let parent = element.parent.flatMap { index[$0] } ?? -1
            let parentPath = element.parent.flatMap { paths[$0] } ?? ""
            let path: String
            switch element.role {
            case .rest: path = "\(parentPath)/(\(element.count) grouped items)"
            default: path = element.node?.path ?? "\(parentPath)/\(element.name)"
            }
            paths[key] = path
            index[key] = nodes.count
            nodes.append(ProtoNode(key: key, parent: parent, node: element.node, name: element.role == .rest ? "\(element.count) grouped items" : element.name, path: path,
                                   bytes: element.bytes, weight: Double(max(0, element.bytes ?? 0)), count: element.count, role: element.role,
                                   depth: element.depth, expanded: element.expanded, isFolder: element.isFolder))
        }
        for i in nodes.indices.dropFirst() where nodes[i].parent >= 0 { nodes[nodes[i].parent].children.append(i) }
        // Largest first; grouped remainders and unmeasured entries last, then by name for stable order.
        let all = nodes
        for i in nodes.indices {
            nodes[i].children.sort { a, b in
                let ra = all[a].role == .rest || all[a].bytes == nil, rb = all[b].role == .rest || all[b].bytes == nil
                if ra != rb { return !ra }
                if all[a].weight != all[b].weight { return all[a].weight > all[b].weight }
                return all[a].name < all[b].name
            }
        }
        for i in nodes.indices.reversed() where !nodes[i].children.isEmpty { nodes[i].leaves = nodes[i].children.reduce(0) { $0 + nodes[$1].leaves } }
        var seen = [String: Int]()
        for node in nodes where node.role != .rest { seen[node.name, default: 0] += 1 }
        repeatedNames = Set(seen.filter { $0.value > 1 }.keys)
    }

    /// Names used by more than one element (e.g. 96 folders called "Resources"): labelled with their parent.
    private(set) var repeatedNames = Set<String>()
    /// The on-canvas title: the name, or "parent › name" when the name alone is ambiguous.
    func label(_ i: Int) -> String {
        let node = nodes[i]
        if i == 0 { return rootName }
        guard repeatedNames.contains(node.name), node.parent > 0 else { return ProtoText.short(node.name) }
        return ProtoText.short(nodes[node.parent].name, limit: 16) + " › " + ProtoText.short(node.name, limit: 20)
    }

    subscript(i: Int) -> ProtoNode { nodes[i] }
    var count: Int { nodes.count }

    /// From the root to `i`, both included.
    func ancestry(_ i: Int) -> [Int] {
        var chain = [Int](), current = i
        while current >= 0 { chain.append(current); current = nodes[current].parent }
        return chain.reversed()
    }
    /// Share of the parent's bytes (nil for the root or when either size is unknown).
    func shareOfParent(_ i: Int) -> Double? {
        let node = nodes[i]
        guard node.parent >= 0, node.bytes != nil, nodes[node.parent].weight > 0 else { return nil }
        return node.weight / nodes[node.parent].weight
    }
    func shareOfRoot(_ i: Int) -> Double? { nodes[i].bytes == nil || root.weight <= 0 ? nil : nodes[i].weight / root.weight }
}

enum ProtoFormat {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "Size not measured" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    static func percent(_ share: Double?) -> String {
        guard let share else { return "—" }
        if share > 0 && share < 0.001 { return "<0.1%" }
        return share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)))
    }
}

// MARK: Camera

/// Layout → view: `view = layout * scale + offset`.
struct ProtoTransform: Equatable {
    var scale: CGFloat
    var offset: CGPoint
    func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
    func invert(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }
}

/// Zoom is relative to the fit (1 = whole hierarchy framed); `center` is the layout point at the middle of the view
/// (nil follows the fit, so an untouched view refits on resize).
struct ProtoCamera: Equatable {
    static let zoomRange: ClosedRange<Double> = 0.35...40
    static let margin: CGFloat = 28
    var zoom = 1.0
    var center: CGPoint?

    static func fitScale(_ bounds: CGRect, in size: CGSize) -> CGFloat {
        let w = max(1, size.width - 2 * margin), h = max(1, size.height - 2 * margin)
        return min(w / max(bounds.width, 1), h / max(bounds.height, 1))
    }
    func transform(bounds: CGRect, size: CGSize) -> ProtoTransform {
        let scale = Self.fitScale(bounds, in: size) * zoom
        let c = center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        return ProtoTransform(scale: scale, offset: CGPoint(x: size.width / 2 - c.x * scale, y: size.height / 2 - c.y * scale))
    }
    /// Zoom about a view point, which stays exactly where it is.
    mutating func zoom(by factor: Double, at point: CGPoint?, bounds: CGRect, size: CGSize) {
        let before = transform(bounds: bounds, size: size)
        let anchor = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let layoutPoint = before.invert(anchor)
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        let scale = Self.fitScale(bounds, in: size) * zoom
        center = CGPoint(x: layoutPoint.x - (anchor.x - size.width / 2) / scale, y: layoutPoint.y - (anchor.y - size.height / 2) / scale)
        clamp(bounds: bounds)
    }
    mutating func pan(by delta: CGVector, bounds: CGRect, size: CGSize) {
        let t = transform(bounds: bounds, size: size)
        let c = center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        center = CGPoint(x: c.x - delta.dx / t.scale, y: c.y - delta.dy / t.scale)
        clamp(bounds: bounds)
    }
    /// Frames `rect` (a subtree), zooming no further than the range allows.
    mutating func focus(_ rect: CGRect, bounds: CGRect, size: CGSize) {
        let fit = Self.fitScale(bounds, in: size)
        zoom = min(Self.zoomRange.upperBound, max(1, Self.fitScale(rect.insetBy(dx: -12, dy: -12), in: size) / fit))
        center = CGPoint(x: rect.midX, y: rect.midY)
        clamp(bounds: bounds)
    }
    /// The view centre stays over the hierarchy, so it can never be panned out of sight.
    private mutating func clamp(bounds: CGRect) {
        guard var c = center else { return }
        c.x = min(bounds.maxX, max(bounds.minX, c.x)); c.y = min(bounds.maxY, max(bounds.minY, c.y))
        center = c
    }
}

// MARK: Shared drawing support

struct ProtoPalette {
    let dark: Bool
    var background: Color { dark ? Color(red: 0.075, green: 0.082, blue: 0.09) : Color(red: 0.972, green: 0.965, blue: 0.948) }
    var ink: Color { dark ? Color(white: 0.93) : Color(white: 0.12) }
    var secondaryInk: Color { dark ? Color(white: 0.66) : Color(white: 0.38) }
    var plate: Color { dark ? Color(white: 0.11).opacity(0.86) : Color.white.opacity(0.88) }
    var plateEdge: Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10) }
    var accent: Color { Color(red: 0.98, green: 0.62, blue: 0.16) }
}

/// A placed label. `rect` is in view coordinates (before rotation about `anchor` by `angle`).
struct ProtoLabel {
    let node: Int
    let title: String
    let detail: String
    let rect: CGRect
    var angle: Double = 0
    var anchor: CGPoint = .zero
    var emphasized = false

    /// The label's footprint on screen (rotated labels: their rotated bounding box).
    var footprint: CGRect {
        guard angle != 0 else { return rect }
        return rect.applying(CGAffineTransform(translationX: -anchor.x, y: -anchor.y).concatenating(CGAffineTransform(rotationAngle: angle)).concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y)))
    }
    func contains(_ p: CGPoint) -> Bool {
        guard angle != 0 else { return rect.insetBy(dx: -2, dy: -2).contains(p) }
        let s = sin(-angle), c = cos(-angle), d = CGPoint(x: p.x - anchor.x, y: p.y - anchor.y)
        let local = CGPoint(x: anchor.x + d.x * c - d.y * s, y: anchor.y + d.x * s + d.y * c)
        return rect.insetBy(dx: -2, dy: -2).contains(local)
    }
}

@MainActor enum ProtoText {
    static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private static var cache = [String: CGFloat]()
    static func width(_ text: String, detail: Bool = false) -> CGFloat {
        let key = (detail ? "d|" : "t|") + text
        if let w = cache[key] { return w }
        if cache.count > 4000 { cache.removeAll() }
        let w = ceil((text as NSString).size(withAttributes: [.font: detail ? detailFont : titleFont]).width)
        cache[key] = w
        return w
    }
    /// Middle-truncates long names so labels stay compact; the full path is in the inspector.
    nonisolated static func short(_ name: String, limit: Int = 26) -> String {
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 9)) + "…" + String(name.suffix(8))
    }
    /// One-line pill: bold name, then size. Height 18.
    static func pill(_ title: String, _ detail: String) -> CGSize { CGSize(width: width(title) + width(detail, detail: true) + 18, height: 18) }

    static func drawPill(_ ctx: inout GraphicsContext, _ label: ProtoLabel, palette: ProtoPalette) {
        var c = ctx
        if label.angle != 0 { c.translateBy(x: label.anchor.x, y: label.anchor.y); c.rotate(by: .radians(label.angle)); c.translateBy(x: -label.anchor.x, y: -label.anchor.y) }
        let shape = Path(roundedRect: label.rect, cornerRadius: 5)
        c.fill(shape, with: .color(palette.plate))
        c.stroke(shape, with: .color(label.emphasized ? palette.accent : palette.plateEdge), lineWidth: label.emphasized ? 1.5 : 0.5)
        let titleWidth = width(label.title)
        c.draw(Text(label.title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(palette.ink), at: CGPoint(x: label.rect.minX + 7, y: label.rect.midY), anchor: .leading)
        c.draw(Text(label.detail).font(.system(size: 10.5).monospacedDigit()).foregroundColor(palette.secondaryInk), at: CGPoint(x: label.rect.minX + 11 + titleWidth, y: label.rect.midY), anchor: .leading)
    }
}

/// Greedy label placement: candidates in priority order, each kept only if it overlaps no kept label (or blocked
/// region) and lies inside the view.
struct ProtoLabelPlacer {
    let bounds: CGRect
    private(set) var placed: [ProtoLabel] = []
    var blocked: [CGRect] = []
    init(size: CGSize) { bounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4) }
    @discardableResult mutating func place(_ label: ProtoLabel, force: Bool = false) -> Bool {
        let r = label.footprint
        if !force {
            guard bounds.contains(r) else { return false }
            for other in placed where other.footprint.insetBy(dx: -3, dy: -2).intersects(r) { return false }
            for region in blocked where region.intersects(r) { return false }
        }
        placed.append(label)
        return true
    }
}

/// What a frame drew: for geometry and label counts in the measurements.
struct ProtoDrawStats { var primitives = 0; var nodesDrawn = 0; var labels = 0 }

/// State shared by both prototypes' drawing.
struct ProtoViewState {
    var selected: Int?
    var hovered: Int?
}

/// A prototype scene: a laid-out hierarchy that can draw itself, place labels and hit-test, all in view coordinates
/// through the camera transform. Layout happens once per hierarchy (or focus/depth change in the explorer).
@MainActor protocol ProtoScene: AnyObject {
    var tree: ProtoTree { get }
    var bounds: CGRect { get }
    var title: String { get }
    /// Elements the scene lays out (its visible set), for measurements.
    var laidOut: Int { get }
    func labels(_ t: ProtoTransform, size: CGSize, state: ProtoViewState) -> [ProtoLabel]
    func draw(_ ctx: inout GraphicsContext, _ t: ProtoTransform, size: CGSize, state: ProtoViewState, labels: [ProtoLabel], palette: ProtoPalette) -> ProtoDrawStats
    func hit(_ p: CGPoint, _ t: ProtoTransform, labels: [ProtoLabel]) -> Int?
    /// The region to frame when focusing an element (its drawn subtree).
    func focusRect(_ node: Int) -> CGRect?
    /// A plain-language explanation of the encoding for the legend.
    var legend: [String] { get }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var length: CGFloat { hypot(x, y) }
}

/// Distance from `p` to segment `a`–`b`, and the parameter (0…1) of the nearest point.
func protoSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGFloat, CGFloat) {
    let d = b - a, len2 = d.x * d.x + d.y * d.y
    guard len2 > 0 else { return ((p - a).length, 0) }
    let t = max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / len2))
    return ((p - (a + d * t)).length, t)
}
