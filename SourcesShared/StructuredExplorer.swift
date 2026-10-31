import Foundation
import CoreGraphics

// Structured Explorer: the Living Tree's default presentation (promoted from research Prototype B). The current
// folder sits at the centre; each ring is one folder level below it; children run clockwise from 12 o'clock, largest
// first. Disc area and link width are proportional to indexed allocation, and an arc around each disc is its share of
// its folder. It draws the Living Tree controller's model (the same bounded catalog read, rebuilt from the change
// journal) and the explorer's shared selection; it keeps no hierarchy of its own.
//
// Layout: a port of d3-hierarchy's tree() (ISC, © 2010–2021 Mike Bostock) — the Buchheim–Jünger–Leipert linear-time
// Reingold–Tilford/Walker algorithm — with d3's radial separation (same parent ? 1 : 2) / depth and size([2π, R]).
// Everything here is free of SwiftUI so it can be tested.

/// Which Living Tree presentation is drawn. The classic branching tree stays available for QA as a fallback
/// (`defaults write <viewer preferences suite> inventory.livingTree.renderer classic`); unknown values fall back to the
/// Structured Explorer.
public enum LivingTreeRenderer: String, CaseIterable, Sendable {
    case structured, classic
    public init(preference: String?) { self = preference.flatMap(Self.init(rawValue:)) ?? .structured }
}

// MARK: Scale

/// The documented visual scale. Disc area ∝ bytes relative to the centre folder (the centre is 34 pt across its radius
/// at the fit), never smaller than 3.5 pt so every folder stays clickable — so areas are exact above about 1% of the
/// centre and small folders are drawn at the minimum. Link width follows the same square root, so the widths² of a
/// folder's children add up to its own (area-conserving flow), from 0.8 to 16 pt.
public enum StructuredExplorerScale {
    public static let centerRadius: CGFloat = 34
    public static let minimumRadius: CGFloat = 3.5
    public static let ringGap: CGFloat = 150
    public static let maximumLinkWidth: CGFloat = 16
    public static let minimumLinkWidth: CGFloat = 0.8

    public static func share(_ bytes: Int64?, of total: Int64?) -> Double? {
        guard let bytes, let total, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }
    public static func radius(_ bytes: Int64?, of total: Int64?) -> CGFloat {
        guard let share = share(bytes, of: total) else { return minimumRadius }
        return max(minimumRadius, centerRadius * CGFloat(share.squareRoot()))
    }
    public static func linkWidth(_ bytes: Int64?, of total: Int64?) -> CGFloat {
        guard let share = share(bytes, of: total) else { return minimumLinkWidth }
        return max(minimumLinkWidth, maximumLinkWidth * CGFloat(share.squareRoot()))
    }
    /// Reference sizes for the size key: the centre, a tenth and a hundredth of it.
    public static func keySizes(_ total: Int64?) -> [Int64] {
        guard let total, total > 0 else { return [] }
        return [total, total / 10, total / 100].filter { $0 > 0 }
    }
}

// MARK: Camera

/// Layout → view: `view = layout · scale + offset`.
public struct StructuredExplorerTransform: Equatable, Sendable {
    public var scale: CGFloat
    public var offset: CGPoint
    public init(scale: CGFloat, offset: CGPoint) { self.scale = scale; self.offset = offset }
    public func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
    public func invert(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }
    public func apply(_ r: CGRect) -> CGRect { CGRect(x: r.minX * scale + offset.x, y: r.minY * scale + offset.y, width: r.width * scale, height: r.height * scale) }
}

/// Zoom is relative to the fit (1 frames everything shown); `center` is the layout point at the middle of the view,
/// nil following the fit so an untouched view refits on resize.
public struct StructuredExplorerCamera: Equatable, Sendable {
    public static let zoomRange: ClosedRange<Double> = 0.4...24
    public static let margin: CGFloat = 24
    public var zoom = 1.0
    public var center: CGPoint?
    public init(zoom: Double = 1, center: CGPoint? = nil) { self.zoom = zoom; self.center = center }

    public var isFit: Bool { abs(zoom - 1) < 1e-6 && center == nil }
    public static func fitScale(_ bounds: CGRect, in size: CGSize) -> CGFloat {
        let w = max(1, size.width - 2 * margin), h = max(1, size.height - 2 * margin)
        return min(w / max(bounds.width, 1), h / max(bounds.height, 1))
    }
    public func transform(bounds: CGRect, size: CGSize) -> StructuredExplorerTransform {
        let scale = Self.fitScale(bounds, in: size) * zoom
        let c = center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        return StructuredExplorerTransform(scale: scale, offset: CGPoint(x: size.width / 2 - c.x * scale, y: size.height / 2 - c.y * scale))
    }
    /// Zooms about a view point (the view centre when nil), which stays exactly where it is.
    public mutating func zoom(by factor: Double, at point: CGPoint?, bounds: CGRect, size: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let anchor = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let layoutPoint = transform(bounds: bounds, size: size).invert(anchor)
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        let scale = Self.fitScale(bounds, in: size) * zoom
        center = CGPoint(x: layoutPoint.x - (anchor.x - size.width / 2) / scale, y: layoutPoint.y - (anchor.y - size.height / 2) / scale)
        clamp(bounds)
    }
    public mutating func pan(by delta: CGVector, bounds: CGRect, size: CGSize) {
        let scale = transform(bounds: bounds, size: size).scale
        let c = center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        center = CGPoint(x: c.x - delta.dx / scale, y: c.y - delta.dy / scale)
        clamp(bounds)
    }
    /// Frames `rect` (a branch), never zooming out past the fit or in past the range.
    public mutating func frame(_ rect: CGRect, bounds: CGRect, size: CGSize) {
        let fit = Self.fitScale(bounds, in: size)
        zoom = min(Self.zoomRange.upperBound, max(1, Self.fitScale(rect.insetBy(dx: -16, dy: -16), in: size) / fit))
        center = CGPoint(x: rect.midX, y: rect.midY)
        clamp(bounds)
    }
    /// Pans only as far as needed to bring `rect` inside the view (with a margin); nothing moves when it is visible.
    public mutating func reveal(_ rect: CGRect, bounds: CGRect, size: CGSize) {
        let t = transform(bounds: bounds, size: size), shown = t.apply(rect), view = CGRect(origin: .zero, size: size).insetBy(dx: 30, dy: 30)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if shown.minX < view.minX { dx = view.minX - shown.minX } else if shown.maxX > view.maxX { dx = view.maxX - shown.maxX }
        if shown.minY < view.minY { dy = view.minY - shown.minY } else if shown.maxY > view.maxY { dy = view.maxY - shown.maxY }
        if dx != 0 || dy != 0 { pan(by: CGVector(dx: dx, dy: dy), bounds: bounds, size: size) }
    }
    /// The centre of the view always stays over the hierarchy, so it cannot be panned out of sight.
    private mutating func clamp(_ bounds: CGRect) {
        guard var c = center else { return }
        c.x = min(bounds.maxX, max(bounds.minX, c.x)); c.y = min(bounds.maxY, max(bounds.minY, c.y))
        center = c
    }
}

// MARK: Layout

public struct StructuredExplorerLayout: Sendable {
    public struct Node: Sendable, Equatable {
        public let key: LivingTreeKey
        /// Index of the parent node (-1 for the centre).
        public let parent: Int
        public let ring: Int
        /// Clockwise from 12 o'clock, radians.
        public let angle: CGFloat
        public let point: CGPoint
        public let radius: CGFloat
        /// Direct children not shown (beyond the shown levels or the per-folder limit).
        public let hidden: Int
        /// Levels skipped between this node and its parent: a selection deeper than the shown levels hangs off its
        /// shown ancestor on a dashed spur, one ring further out (its true level is `ring + elided`).
        public let elided: Int
    }

    public static let defaultDepth = 3, depthRange = 1...6, perFolder = 14

    public let rootKey: LivingTreeKey
    public let depth: Int
    public private(set) var nodes: [Node] = []
    public private(set) var children: [[Int]] = []
    public private(set) var index: [LivingTreeKey: Int] = [:]
    public private(set) var bounds: CGRect = .zero
    /// Rings drawn (the shown levels, one more for a spur).
    public private(set) var rings = 0
    /// Names used by more than one element of the tree: titled with their folder.
    public let repeatedNames: Set<String>

    /// - Parameters:
    ///   - depth: levels shown below the centre (clamped to `depthRange`).
    ///   - keep: an element that must be shown (the selection): its whole chain is kept past the per-folder limit,
    ///     and when it is deeper than `depth` it is shown on a spur from its deepest shown ancestor.
    public init(model: LivingTreeModel, depth: Int = defaultDepth, keep: LivingTreeKey? = nil, perFolder: Int = perFolder,
                root: LivingTreeKey? = nil, keepFullAncestry: Bool = false) {
        let requestedRoot = root.flatMap { key -> LivingTreeKey? in
            guard key.nodeID != nil, model[key]?.isFolder == true else { return nil }
            return model.ancestry(of: key).contains(model.rootKey) ? key : nil
        }
        rootKey = requestedRoot ?? model.rootKey
        self.depth = min(Self.depthRange.upperBound, max(Self.depthRange.lowerBound, depth))
        let rootSubtree = Set(model.subtree(of: rootKey))
        var seen = [String: Int]()
        for key in model.order where key.nodeID != nil && rootSubtree.contains(key) { seen[model[key]!.name, default: 0] += 1 }
        repeatedNames = Set(seen.filter { $0.value > 1 }.keys)
        let rootDepth = model[rootKey]?.depth ?? 0
        let candidateChain = keep.map { model.ancestry(of: $0) } ?? []
        let chain = candidateChain.firstIndex(of: rootKey).map { Array(candidateChain[$0...]) } ?? []
        let keepSet = Set(chain)
        let retained = chain.last == keep ? keep : nil
        let keepRing = retained.flatMap { model[$0] }.map { $0.depth - rootDepth } ?? 0

        // Visible set, breadth-first: each folder's largest `perFolder` children (and the selection's chain).
        var order = [rootKey], parentOf = [-1], elided = [0], hidden = [Int]()
        var kids = [[Int]()]
        var head = 0
        while head < order.count {
            let v = head, key = order[v]
            head += 1
            let ring = (model[key]?.depth ?? rootDepth) - rootDepth
            let all = Self.sortedChildren(of: key, in: model)
            if ring >= self.depth {
                var shown = 0
                if keepFullAncestry, let retained, keepSet.contains(key), retained != key,
                   let direct = all.first(where: { keepSet.contains($0) }) {
                    let index = order.count
                    order.append(direct); parentOf.append(v); kids.append([]); kids[v].append(index); elided.append(0)
                    shown = 1
                } else if let retained, keepRing > self.depth, keepSet.contains(key), ring == self.depth, retained != key {
                    // Default behavior preserves the compact dashed selection spur.
                    let index = order.count
                    order.append(retained); parentOf.append(v); kids.append([]); kids[v].append(index); elided.append(keepRing - ring - 1)
                    shown = all.contains(retained) ? 1 : 0
                }
                hidden.append(all.count - shown)
                continue
            }
            var shown = 0, extra = 0
            for c in all {
                if shown < perFolder || keepSet.contains(c) {
                    shown += 1
                    let index = order.count
                    order.append(c); parentOf.append(v); kids.append([]); kids[v].append(index); elided.append(0)
                } else { extra += 1 }
            }
            hidden.append(extra)
        }

        // Tidy tree (d3-hierarchy tree.js): prelim z, modifier m, change c, shift s, thread, ancestor a, default A.
        let n = order.count, superRoot = n
        var ringOfIndex = [Int](repeating: 0, count: n)
        for v in 1..<max(1, n) { ringOfIndex[v] = ringOfIndex[parentOf[v]] + 1 }
        func ringOf(_ v: Int) -> Int { v == superRoot ? -1 : ringOfIndex[v] }
        var z = [CGFloat](repeating: 0, count: n + 1), m = z, c = z, s = z
        var thread = [Int](repeating: -1, count: n + 1), ancestor = Array(0...n), defaultAncestor = [Int](repeating: -1, count: n + 1)
        let tk = kids + [[0]]
        var parent = parentOf + [-1]
        parent[0] = superRoot
        var sibling = [Int](repeating: 0, count: n + 1)
        for v in 0...n { for (k, w) in tk[v].enumerated() { sibling[w] = k } }
        func separation(_ a: Int, _ b: Int) -> CGFloat { (parent[a] == parent[b] ? 1 : 2) / CGFloat(max(1, ringOf(a))) }
        func nextLeft(_ v: Int) -> Int { tk[v].first ?? thread[v] }
        func nextRight(_ v: Int) -> Int { tk[v].last ?? thread[v] }
        func moveSubtree(_ wm: Int, _ wp: Int, _ shift: CGFloat) {
            let change = shift / CGFloat(sibling[wp] - sibling[wm])
            c[wp] -= change; s[wp] += shift; c[wm] += change; z[wp] += shift; m[wp] += shift
        }
        func executeShifts(_ v: Int) {
            var shift: CGFloat = 0, change: CGFloat = 0
            for w in tk[v].reversed() { z[w] += shift; m[w] += shift; change += c[w]; shift += s[w] + change }
        }
        func nextAncestor(_ vim: Int, _ v: Int, _ a: Int) -> Int { parent[ancestor[vim]] == parent[v] ? ancestor[vim] : a }
        func apportion(_ v: Int, _ w: Int?, _ a0: Int) -> Int {
            guard let w else { return a0 }
            var a = a0, vip = v, vop = v, vim = w, vom = tk[parent[v]][0]
            var sip = m[vip], sop = m[vop], sim = m[vim], som = m[vom]
            while true {
                let nr = nextRight(vim), nl = nextLeft(vip)
                guard nr >= 0, nl >= 0 else { break }
                vim = nr; vip = nl; vom = nextLeft(vom); vop = nextRight(vop)
                ancestor[vop] = v
                let shift = z[vim] + sim - z[vip] - sip + separation(vim, vip)
                if shift > 0 { moveSubtree(nextAncestor(vim, v, a), v, shift); sip += shift; sop += shift }
                sim += m[vim]; sip += m[vip]; som += m[vom]; sop += m[vop]
            }
            if nextRight(vim) >= 0 && nextRight(vop) < 0 { thread[vop] = nextRight(vim); m[vop] += sim - sop }
            if nextLeft(vip) >= 0 && nextLeft(vom) < 0 { thread[vom] = nextLeft(vip); m[vom] += sip - som; a = v }
            return a
        }
        func firstWalk(_ v: Int) {
            let p = parent[v], k = sibling[v], w: Int? = k > 0 ? tk[p][k - 1] : nil
            if let first = tk[v].first, let last = tk[v].last {
                executeShifts(v)
                let midpoint = (z[first] + z[last]) / 2
                if let w { z[v] = z[w] + separation(v, w); m[v] = z[v] - midpoint } else { z[v] = midpoint }
            } else if let w { z[v] = z[w] + separation(v, w) }
            defaultAncestor[p] = apportion(v, w, defaultAncestor[p] >= 0 ? defaultAncestor[p] : tk[p][0])
        }
        // Post-order (children left to right before their parent); its reverse visits every parent before its children.
        var post = [Int](), walk = [(0, false)]
        while let (v, done) = walk.popLast() {
            if done { post.append(v); continue }
            walk.append((v, true)); for w in tk[v].reversed() { walk.append((w, false)) }
        }
        for v in post { firstWalk(v) }
        m[superRoot] = -z[0]
        var x = [CGFloat](repeating: 0, count: n)
        for v in post.reversed() { let p = parent[v]; x[v] = z[v] + m[p]; m[v] += m[p] }
        let left = (0..<n).min { x[$0] < x[$1] } ?? 0, right = (0..<n).max { x[$0] < x[$1] } ?? 0
        let sep = left == right ? 1 : separation(left, right) / 2, tx = sep - x[left], kx = 2 * CGFloat.pi / max(x[right] + sep + tx, 0.0001)

        let total = model[rootKey]?.bytes
        for v in 0..<n {
            let key = order[v], ring = ringOf(v)
            let angle = n == 1 ? 0 : (x[v] + tx) * kx
            let point = CGPoint(x: sin(angle) * CGFloat(ring) * StructuredExplorerScale.ringGap, y: -cos(angle) * CGFloat(ring) * StructuredExplorerScale.ringGap)
            index[key] = nodes.count
            nodes.append(Node(key: key, parent: parentOf[v], ring: ring, angle: angle, point: point,
                              radius: StructuredExplorerScale.radius(model[key]?.bytes, of: total), hidden: hidden[v], elided: elided[v]))
        }
        children = kids
        rings = nodes.map(\.ring).max() ?? 0
        let extent = CGFloat(rings) * StructuredExplorerScale.ringGap + StructuredExplorerScale.centerRadius + 40
        bounds = CGRect(x: -extent, y: -extent, width: 2 * extent, height: 2 * extent)
    }

    /// Largest first; grouped remainders and entries without a measured size last; then by name and key.
    public static func sortedChildren(of key: LivingTreeKey, in model: LivingTreeModel) -> [LivingTreeKey] {
        (model[key]?.children ?? []).sorted { a, b in
            let x = model[a]!, y = model[b]!
            let ra = x.role == .rest || x.bytes == nil, rb = y.role == .rest || y.bytes == nil
            if ra != rb { return !ra }
            if (x.bytes ?? 0) != (y.bytes ?? 0) { return (x.bytes ?? 0) > (y.bytes ?? 0) }
            return x.name != y.name ? x.name < y.name : a < b
        }
    }

    public subscript(key: LivingTreeKey) -> Node? { index[key].map { nodes[$0] } }

    /// A node and everything shown beneath it, in layout space.
    public func subtreeBounds(_ key: LivingTreeKey) -> CGRect? {
        guard let start = index[key] else { return nil }
        var box = CGRect.null, stack = [start]
        while let i = stack.popLast() {
            let n = nodes[i]
            box = box.union(CGRect(x: n.point.x - n.radius, y: n.point.y - n.radius, width: 2 * n.radius, height: 2 * n.radius))
            stack += children[i]
        }
        return box
    }

    /// The element shown for `key`: itself when placed, otherwise its nearest shown ancestor.
    public func shownKey(for key: LivingTreeKey, in model: LivingTreeModel) -> LivingTreeKey? {
        for k in model.ancestry(of: key).reversed() where index[k] != nil { return k }
        return nil
    }

    /// Its name, or "folder › name" when the name alone is ambiguous in this tree.
    public func title(_ key: LivingTreeKey, in model: LivingTreeModel) -> String {
        guard let element = model[key] else { return "" }
        if key == rootKey { return element.name }
        if element.role == .rest { return "Other items" }
        guard repeatedNames.contains(element.name), let parent = element.parent, let folder = model[parent] else { return element.name }
        return "\(folder.name) › \(element.name)"
    }

    /// Keyboard movement over what is shown: outward to the largest child, inward to the parent, around the ring.
    public enum Move: Sendable { case outward, inward, previousSibling, nextSibling }
    public func move(_ move: Move, from key: LivingTreeKey?, allowed: Set<LivingTreeKey>? = nil) -> LivingTreeKey? {
        func permits(_ key: LivingTreeKey) -> Bool { allowed?.contains(key) ?? true }
        guard let key, let i = index[key], permits(key) else { return nodes.first(where: { permits($0.key) })?.key }
        let node = nodes[i]
        switch move {
        case .outward: return children[i].map { nodes[$0].key }.first(where: permits)
        case .inward:
            var parent = node.parent
            while parent >= 0 {
                let candidate = nodes[parent].key
                if permits(candidate) { return candidate }
                parent = nodes[parent].parent
            }
            return nil
        case .previousSibling, .nextSibling:
            guard node.parent >= 0 else { return nil }
            let siblings = children[node.parent].filter { permits(nodes[$0].key) }
            guard let k = siblings.firstIndex(of: i), siblings.count > 1 else { return nil }
            let next = move == .nextSibling ? (k + 1) % siblings.count : (k - 1 + siblings.count) % siblings.count
            return nodes[siblings[next]].key
        }
    }

    // MARK: Hit testing

    /// Labels first, then the disc whose centre is nearest relative to its size, with at least 6 pt of reach so small
    /// discs stay clickable; ties go to the smaller disc. Empty space selects nothing.
    public func hit(_ p: CGPoint, transform t: StructuredExplorerTransform, labels: [StructuredExplorerLabel],
                    allowed: Set<LivingTreeKey>? = nil) -> LivingTreeKey? {
        func permits(_ key: LivingTreeKey) -> Bool { allowed?.contains(key) ?? true }
        if let label = labels.last(where: { permits($0.key) && $0.contains(p) }) { return label.key }
        var best: (score: CGFloat, radius: CGFloat, key: LivingTreeKey)?
        for node in nodes where permits(node.key) {
            let r = screenRadius(node, t), reach = max(r, 6)
            let c = t.apply(node.point), d = hypot(c.x - p.x, c.y - p.y)
            guard d <= reach else { continue }
            let score = d / reach
            if best == nil || score < best!.score - 0.05 || (abs(score - best!.score) <= 0.05 && r < best!.radius) { best = (score, r, node.key) }
        }
        return best?.key
    }

    /// The disc as drawn (never below the minimum radius on screen).
    public func screenRadius(_ node: Node, _ t: StructuredExplorerTransform) -> CGFloat { max(StructuredExplorerScale.minimumRadius, node.radius * t.scale) }

    // MARK: Labels

    /// Label priority: the selection and the hovered element always; then the centre, then the first ring by size,
    /// then everything else by size — each only where it fits without covering another label, a disc or a heavy link.
    /// Outer-ring labels need a clear slot along their ring (so they appear as zooming opens space), and the budget
    /// grows with zoom. `measure` gives a label's size for its title and detail.
    public func labels(model: LivingTreeModel, transform t: StructuredExplorerTransform, size: CGSize, selected: LivingTreeKey?, hovered: LivingTreeKey?,
                       detail: (LivingTreeElement) -> String, measure: (String, String) -> CGSize,
                       allowed: Set<LivingTreeKey>? = nil, preferred: Set<LivingTreeKey>? = nil) -> [StructuredExplorerLabel] {
        func permits(_ key: LivingTreeKey) -> Bool { allowed?.contains(key) ?? true }
        let view = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let fit = StructuredExplorerCamera.fitScale(bounds, in: size), zoom = t.scale / max(fit, 0.0001)
        // Secondary labels scale with the canvas area (a compact window names fewer), and grow with zoom. The selection,
        // hover and centre are placed first regardless.
        let room = min(1, size.width * size.height / Self.labelReferenceArea)
        let budget = max(6, Int((22 * room).rounded())) + Int(14 * log2(max(1, zoom)))
        var placed = [StructuredExplorerLabel]()
        var blocked: [CGRect] = nodes.compactMap { n -> CGRect? in
            guard permits(n.key) else { return nil }
            let r = screenRadius(n, t); guard r >= 3 else { return nil }
            let c = t.apply(n.point); return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
        // Heavy links (≥ 3 pt on screen) block labels along their length.
        let total = model[rootKey]?.bytes
        var heavy = [CGRect]()
        for (i, n) in nodes.enumerated() where n.parent >= 0 && permits(n.key) && permits(nodes[n.parent].key) {
            let width = StructuredExplorerScale.linkWidth(model[n.key]?.bytes, of: total) * min(1.6, max(0.6, t.scale))
            guard width >= 3 else { continue }
            let curve = link(i, t), clearance = max(3, width / 2 + 2)
            for k in 1...15 {
                let p = curve(CGFloat(k) / 16)
                heavy.append(CGRect(x: p.x - clearance, y: p.y - clearance, width: 2 * clearance, height: 2 * clearance))
            }
        }
        blocked += heavy
        /// `slot` for a horizontal label: 0 beside the disc on its outer side, 1 on the inner side, 2 below, 3 above.
        func make(_ i: Int, emphasized: Bool, horizontal: Bool, slot: Int = 0) -> StructuredExplorerLabel? {
            let n = nodes[i]
            guard let element = model[n.key] else { return nil }
            let text = Self.shortened(title(n.key, in: model)), sub = detail(element)
            let size = measure(text, sub)
            let c = t.apply(n.point), r = screenRadius(n, t)
            if n.ring == 0 {
                let rect: CGRect
                switch slot {
                case 1: rect = CGRect(x: c.x + r + 8, y: c.y - size.height / 2, width: size.width, height: size.height)
                case 2: rect = CGRect(x: c.x - r - 8 - size.width, y: c.y - size.height / 2, width: size.width, height: size.height)
                case 3: rect = CGRect(x: c.x - size.width / 2, y: c.y - r - 8 - size.height, width: size.width, height: size.height)
                default: rect = CGRect(x: c.x - size.width / 2, y: c.y + r + 8, width: size.width, height: size.height)
                }
                return StructuredExplorerLabel(key: n.key, title: text, detail: sub, rect: rect, emphasized: emphasized)
            }
            if n.ring == 1 || horizontal {
                let outer = sin(n.angle) >= -0.05, right = slot == 1 ? !outer : outer
                let rect: CGRect
                switch slot {
                case 2: rect = CGRect(x: c.x - size.width / 2, y: c.y + r + 5, width: size.width, height: size.height)
                case 3: rect = CGRect(x: c.x - size.width / 2, y: c.y - r - 5 - size.height, width: size.width, height: size.height)
                default: rect = CGRect(x: right ? c.x + r + 6 : c.x - r - 6 - size.width, y: c.y - size.height / 2, width: size.width, height: size.height)
                }
                return StructuredExplorerLabel(key: n.key, title: text, detail: sub, rect: rect, emphasized: emphasized)
            }
            // Outer rings: along the radius, outside the disc, turned on the left half so text is never upside down.
            let anchor = CGPoint(x: c.x + sin(n.angle) * (r + 5), y: c.y - cos(n.angle) * (r + 5))
            let rightHalf = sin(n.angle) >= 0
            return StructuredExplorerLabel(key: n.key, title: text, detail: sub,
                                           rect: CGRect(x: rightHalf ? anchor.x : anchor.x - size.width, y: anchor.y - size.height / 2, width: size.width, height: size.height),
                                           angle: Double(rightHalf ? n.angle - .pi / 2 : n.angle + .pi / 2), anchor: anchor, emphasized: emphasized)
        }
        // Major branches (the first ring) may cover small discs (under 7 pt) — those stay reachable by zooming in — but
        // never a large disc, a heavy link or another label.
        let large = blocked.filter { $0.width >= 14 } + heavy
        @discardableResult func place(_ label: StructuredExplorerLabel?, ignoresGeometry: Bool = false) -> Bool {
            guard let label, !placed.contains(where: { $0.key == label.key }) else { return false }
            let r = label.footprint
            guard view.contains(r) else { return false }
            if placed.contains(where: { $0.footprint.insetBy(dx: -3, dy: -2).intersects(r) }) { return false }
            if !ignoresGeometry {
                let ring = index[label.key].map { nodes[$0].ring } ?? 0
                if (ring <= 1 ? large : blocked).contains(where: { $0.intersects(r) }) { return false }
            }
            placed.append(label)
            return true
        }
        /// The first of a label's positions that fits (first ring: beside, other side, below, above).
        func placeAnywhere(_ i: Int) {
            let slots = nodes[i].ring <= 1 ? [0, 1, 2, 3] : [0]
            for slot in slots where place(make(i, emphasized: false, horizontal: false, slot: slot)) { return }
        }
        /// Selection is named before anything else. Clamp its horizontal plate at viewport edges; hover and centre
        /// obey the same mutual collision rules. Offscreen nodes are described by the Inspector, never orphan labels.
        func priority(_ i: Int, emphasized: Bool) {
            guard view.insetBy(dx: -4, dy: -4).contains(t.apply(nodes[i].point)) else { return }
            for ignoresGeometry in [false, true] {
                for slot in 0..<4 {
                    guard let label = make(i, emphasized: emphasized, horizontal: true, slot: slot),
                          label.rect.width <= view.width, label.rect.height <= view.height else { continue }
                    let rect = CGRect(x: min(max(label.rect.minX, view.minX), view.maxX - label.rect.width),
                                      y: min(max(label.rect.minY, view.minY), view.maxY - label.rect.height),
                                      width: label.rect.width, height: label.rect.height)
                    if place(StructuredExplorerLabel(key: label.key, title: label.title, detail: label.detail, rect: rect, emphasized: emphasized),
                             ignoresGeometry: ignoresGeometry) { return }
                }
            }
        }
        if let selected, permits(selected), let i = index[selected] { priority(i, emphasized: true) }
        if let hovered, hovered != selected, permits(hovered), let i = index[hovered] { priority(i, emphasized: false) }
        if !nodes.isEmpty, permits(rootKey), selected != rootKey { placeAnywhere(0) }
        // Room along the ring: the angular gap to the nearest neighbour on the same ring, on screen.
        var ringAngles = [Int: [CGFloat]]()
        for n in nodes where n.ring > 0 && permits(n.key) { ringAngles[n.ring, default: []].append(n.angle) }
        for k in ringAngles.keys { ringAngles[k]!.sort() }
        func slot(_ n: Node) -> CGFloat {
            guard let angles = ringAngles[n.ring], angles.count > 1, let k = angles.firstIndex(of: n.angle) else { return .infinity }
            let before = angles[(k - 1 + angles.count) % angles.count], after = angles[(k + 1) % angles.count]
            let gap = min(abs(n.angle - before), abs(after - n.angle))
            return min(gap, 2 * .pi - gap) * CGFloat(n.ring) * StructuredExplorerScale.ringGap * t.scale
        }
        let candidates = nodes.indices.dropFirst().filter { i in
            let n = nodes[i]
            return permits(n.key) && n.key != selected && n.key != hovered
                && view.contains(t.apply(n.point)) && (n.ring <= 1 || slot(n) >= 15)
        }.sorted { a, b in
            let x = nodes[a], y = nodes[b]
            let px = preferred?.contains(x.key) ?? false, py = preferred?.contains(y.key) ?? false
            if px != py { return px }
            if (x.ring <= 1) != (y.ring <= 1) { return x.ring <= 1 }
            let bx = model[x.key]?.bytes ?? -1, by = model[y.key]?.bytes ?? -1
            return bx != by ? bx > by : x.key < y.key
        }
        for i in candidates {
            if placed.count >= budget { break }
            // Keep the major first-level folders named even in dense high-depth overviews. As with the selection,
            // the final fallback may cover geometry, but never another label.
            if nodes[i].ring == 1, let share = StructuredExplorerScale.share(model[nodes[i].key]?.bytes, of: total), share >= 0.01 {
                priority(i, emphasized: false)
            } else { placeAnywhere(i) }
        }
        return placed
    }

    /// The link from a node's parent to it (d3.linkRadial: control points at the mid radius, on each end's angle), as
    /// a parametric curve in view coordinates.
    public func link(_ i: Int, _ t: StructuredExplorerTransform) -> (CGFloat) -> CGPoint {
        let (p0, c1, c2, p3) = linkControls(i)
        let a = t.apply(p0), b = t.apply(c1), c = t.apply(c2), d = t.apply(p3)
        return { s in
            let u = 1 - s
            return CGPoint(x: u * u * u * a.x + 3 * u * u * s * b.x + 3 * u * s * s * c.x + s * s * s * d.x,
                           y: u * u * u * a.y + 3 * u * u * s * b.y + 3 * u * s * s * c.y + s * s * s * d.y)
        }
    }
    public func linkControls(_ i: Int) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let to = nodes[i], from = nodes[to.parent]
        let mid = (CGFloat(from.ring) + CGFloat(to.ring)) / 2 * StructuredExplorerScale.ringGap
        let c1 = from.ring == 0 ? from.point : CGPoint(x: sin(from.angle) * mid, y: -cos(from.angle) * mid)
        let c2 = CGPoint(x: sin(to.angle) * mid, y: -cos(to.angle) * mid)
        return (from.point, c1, c2, to.point)
    }

    /// Where to caption each ring: the middle of its widest empty arc, so the caption never sits on a node.
    public func ringCaptionAngles() -> [Int: CGFloat] {
        var angles = [Int: [CGFloat]]()
        for n in nodes where n.ring > 0 { angles[n.ring, default: []].append(n.angle) }
        var result = [Int: CGFloat]()
        for ring in 1...max(1, rings) {
            guard let list = angles[ring]?.sorted(), !list.isEmpty else { result[ring] = 0; continue }
            var best = (gap: 2 * CGFloat.pi - (list.last! - list.first!), mid: (list.last! + list.first! + 2 * CGFloat.pi) / 2)
            for (a, b) in zip(list, list.dropFirst()) where b - a > best.gap { best = (b - a, (a + b) / 2) }
            result[ring] = best.mid.truncatingRemainder(dividingBy: 2 * CGFloat.pi)
        }
        return result
    }

    /// The canvas area (pt²) at which the full secondary-label budget applies: a typical desktop window's canvas.
    public static let labelReferenceArea: CGFloat = 1100 * 600

    /// Rings closer together on screen than this carry no captions: their captions would read as a stack.
    public static let captionRingSpacing: CGFloat = 30

    /// Ring captions ("Level N"), placed after the labels, which keep priority. Each ring's caption tries the middles
    /// of its widest empty arcs and takes the first spot where the text fits along the arc, stays inside the view and
    /// clears every label, disc and other caption; a ring with no such spot is left uncaptioned (the rings themselves
    /// stay drawn). Shown levels only; none at all when the rings are drawn closer than `captionRingSpacing`.
    public func ringCaptions(transform t: StructuredExplorerTransform, size: CGSize, labels: [StructuredExplorerLabel],
                             measure: (String) -> CGSize) -> [StructuredExplorerRingCaption] {
        let spacing = StructuredExplorerScale.ringGap * t.scale
        guard rings > 0, depth > 0, spacing >= Self.captionRingSpacing else { return [] }
        let view = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4), centre = t.apply(CGPoint.zero)
        let taken = labels.map { $0.footprint.insetBy(dx: -3, dy: -3) } + nodes.compactMap { n -> CGRect? in
            let r = screenRadius(n, t); guard r >= 2 else { return nil }
            let c = t.apply(n.point); return CGRect(x: c.x - r - 2, y: c.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)
        }
        var angles = [Int: [CGFloat]]()
        for n in nodes where n.ring > 0 { angles[n.ring, default: []].append(n.angle) }
        var placed = [StructuredExplorerRingCaption]()
        for ring in 1...min(rings, depth) {
            let radius = CGFloat(ring) * spacing, text = "Level \(ring)", box = measure(text)
            // Empty arcs on this ring, widest first: (width in radians, middle angle).
            let list = (angles[ring] ?? []).sorted()
            var gaps: [(CGFloat, CGFloat)] = list.isEmpty ? [(2 * .pi, 0)] : [(2 * .pi - (list.last! - list.first!), (list.last! + list.first! + 2 * .pi) / 2)]
            for (a, b) in zip(list, list.dropFirst()) { gaps.append((b - a, (a + b) / 2)) }
            for (gap, middle) in gaps.sorted(by: { $0.0 > $1.0 }).prefix(6) where gap * radius >= box.width + 12 {
                let p = CGPoint(x: centre.x + sin(middle) * radius, y: centre.y - cos(middle) * radius)
                let rect = CGRect(x: p.x - box.width / 2, y: p.y - box.height / 2, width: box.width, height: box.height)
                guard view.contains(rect), !taken.contains(where: { $0.intersects(rect) }),
                      !placed.contains(where: { $0.rect.insetBy(dx: -4, dy: -4).intersects(rect) }) else { continue }
                placed.append(StructuredExplorerRingCaption(ring: ring, text: text, rect: rect))
                break
            }
        }
        return placed
    }

    /// Middle-truncates long names so labels stay compact; the full path is in the Inspector and spoken text.
    public static func shortened(_ name: String, limit: Int = 28) -> String {
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 10)) + "…" + String(name.suffix(9))
    }
}

/// A placed ring caption, drawn centred in `rect` (view coordinates).
public struct StructuredExplorerRingCaption: Sendable, Equatable {
    public let ring: Int
    public let text: String
    public let rect: CGRect
}

/// A placed label. `rect` is in view coordinates before rotation about `anchor` by `angle`.
public struct StructuredExplorerLabel: Sendable, Equatable {
    public let key: LivingTreeKey
    public let title: String
    public let detail: String
    public let rect: CGRect
    public var angle: Double = 0
    public var anchor: CGPoint = .zero
    public var emphasized = false

    public var footprint: CGRect {
        guard angle != 0 else { return rect }
        return rect.applying(CGAffineTransform(translationX: -anchor.x, y: -anchor.y).concatenating(CGAffineTransform(rotationAngle: angle)).concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y)))
    }
    public func contains(_ p: CGPoint) -> Bool {
        guard angle != 0 else { return rect.insetBy(dx: -2, dy: -2).contains(p) }
        let s = sin(-angle), c = cos(-angle), d = CGPoint(x: p.x - anchor.x, y: p.y - anchor.y)
        return rect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: anchor.x + d.x * c - d.y * s, y: anchor.y + d.x * s + d.y * c))
    }
}
