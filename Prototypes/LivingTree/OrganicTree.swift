import SwiftUI

// PROTOTYPE A — Organic Storage Tree.
//
// A side-elevation tree that grows up from the ground. Geometry follows the botanical pipe model (Leonardo's rule):
// a limb's cross-section area is proportional to the bytes it carries, so a limb thins by exactly the storage that
// branches off it, and the trunk is as thick as the whole folder. Folders are limbs, files are leaves (area ∝ bytes),
// a folder's grouped small items are a pale foliage clump and a folder whose contents are not drawn ends in a bud.
//
// Techniques adapted from EZ-Tree (MIT, © 2024 Daniel Greenheck; see REFERENCE-REPOSITORIES.md): per-level length
// decay, laterals spawned along the parent limb, a growth force that bends thin limbs toward the light more than thick
// ones (strength / radius), and gnarliness scaled by 1/√radius. Unlike EZ-Tree, nothing is random: every angle,
// length and radius comes from the data, and per-element variation is deterministic noise of the element's key.
// Siblings divide their parent's angular sector by size and leaf count, largest in the middle (apical dominance),
// so subtrees fan apart instead of crossing.

@MainActor final class OrganicTreeScene: ProtoScene {
    struct Limb {
        let node: Int
        let samples: [CGPoint]
        let radii: [CGFloat]
        let bounds: CGRect
        let length: CGFloat
        let unmeasured: Bool
    }
    struct Leaf {
        enum Kind { case file, grouped, bud }
        let node: Int
        let center: CGPoint
        let radius: CGFloat
        let kind: Kind
    }

    let tree: ProtoTree
    let title = "Organic Storage Tree"
    private(set) var bounds: CGRect = .zero
    private(set) var limbs: [Limb] = []
    private(set) var leaves: [Leaf] = []
    private var limbOf: [Int: Int] = [:]
    private var leafOf: [Int: Int] = [:]
    private var budOf: [Int: Int] = [:]
    private var subtreeBounds: [Int: CGRect] = [:]
    /// Limbs ordered thin-to-thick for drawing (thick limbs on top).
    private var drawOrder: [Int] = []
    var laidOut: Int { limbs.count + leaves.count }

    static let trunkRadius: CGFloat = 15, trunkLength: CGFloat = 175, samples = 9

    let legend = [
        "Limb thickness: cross-section area ∝ bytes — a limb thins by exactly what branches off it",
        "Leaves are files (area ∝ size) · pale clumps: grouped small items · dark buds: folders not yet opened (double-click to explore)",
        "Orange: the path from the trunk to the selection",
    ]

    init(tree: ProtoTree) {
        self.tree = tree
        let total = max(tree.root.weight, 1)
        func radius(_ w: Double) -> CGFloat { max(0.45, Self.trunkRadius * CGFloat(sqrt(max(w, 0) / total))) }
        func dir(_ a: CGFloat) -> CGPoint { CGPoint(x: sin(a), y: -cos(a)) }
        func noise(_ i: Int, _ salt: UInt64) -> CGFloat { CGFloat(tree[i].key.noise(salt)) }

        /// Grows element `i` from `base`, heading `angle` (0 = straight up), within the angular `sector`.
        @discardableResult func grow(_ i: Int, base: CGPoint, angle: CGFloat, from parentAngle: CGFloat, sector: ClosedRange<CGFloat>, length: CGFloat) -> CGRect {
            let node = tree[i]
            let r0 = node.bytes == nil ? 0.6 : radius(node.weight)
            // Growth force: thin limbs turn toward vertical more than thick ones; gnarliness ∝ 1/√radius.
            let lift = min(0.45, 0.5 / (r0 + 0.6))
            let gnarl = (noise(i, 7) - 0.5) * min(0.22, 0.16 / sqrt(max(r0, 0.3)))
            let tipAngle = angle * (1 - lift) + gnarl
            let startAngle = angle * 0.55 + parentAngle * 0.45
            let p0 = base, p3 = base + dir(angle) * (length * 0.62) + dir(tipAngle) * (length * 0.38)
            let p1 = p0 + dir(startAngle) * (length * 0.38), p2 = p3 - dir(tipAngle) * (length * 0.32)
            func bezier(_ t: CGFloat) -> CGPoint {
                let u = 1 - t
                return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
            }
            var points = (0..<Self.samples).map { bezier(CGFloat($0) / CGFloat(Self.samples - 1)) }

            let folders = node.children.filter { tree[$0].isFolder && tree[$0].role != .rest }
            let terminals = node.children.filter { !(tree[$0].isFolder && tree[$0].role != .rest) }
            let leader = folders.first.flatMap { c in node.weight > 0 && tree[c].weight / node.weight >= 0.25 ? c : nil }
            let laterals = folders.filter { $0 != leader }
            // Laterals leave along the upper part of the limb, the largest lowest (as in a real tree).
            var attach = [Int: CGFloat]()
            for (k, c) in laterals.enumerated() { attach[c] = 0.42 + 0.5 * CGFloat(k + 1) / CGFloat(laterals.count + 1) }
            // Pipe model: the radius at t is that of the bytes still carried past t.
            var radii = [CGFloat]()
            for s in 0..<Self.samples {
                let t = CGFloat(s) / CGFloat(Self.samples - 1)
                let carried = node.weight - laterals.reduce(0.0) { attach[$1]! < t ? $0 + tree[$1].weight : $0 }
                radii.append(node.bytes == nil ? 0.6 : radius(carried))
            }
            if node.bytes == nil { points = [p0, p0 + dir(angle) * min(length, 12)]; radii = [0.6, 0.6] }
            var box = CGRect(origin: points[0], size: .zero)
            for (p, r) in zip(points, radii) { box = box.union(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
            limbOf[i] = limbs.count
            limbs.append(Limb(node: i, samples: points, radii: radii, bounds: box, length: length, unmeasured: node.bytes == nil))
            var subtree = box
            let tip = points.last!

            // Siblings share the sector by size (√ share) and structure (leaf count), arranged middle-out by size.
            if !folders.isEmpty && node.expanded {
                let leafTotal = Double(folders.reduce(0) { $0 + tree[$1].leaves })
                let scores = folders.map { c -> Double in
                    let share = node.weight > 0 ? tree[c].weight / node.weight : 0
                    return 0.65 * sqrt(share) + 0.35 * Double(tree[c].leaves) / max(leafTotal, 1) + 0.01
                }
                let sum = scores.reduce(0, +)
                var left = [Int](), right = [Int]()
                for k in folders.indices where k > 0 { if k % 2 == 1 { right.append(k) } else { left.append(k) } }
                let arranged = left.reversed() + [0] + right
                func childLength(_ c: Int) -> CGFloat {
                    let share = node.weight > 0 ? tree[c].weight / node.weight : 0
                    return max(16, Self.trunkLength * pow(0.76, CGFloat(node.depth + 1)) * CGFloat(0.55 + 0.45 * sqrt(share)))
                }
                // Deeper sectors narrow a little so the crown stays compact — but never below the angle the limbs'
                // own thickness needs at their length (deep runs of equal-sized siblings otherwise fuse into a mass).
                let need = folders.reduce(CGFloat(0)) { $0 + (2 * radius(tree[$1].weight) + 1.5) / childLength($1) }
                let width = min(2.4, max((sector.upperBound - sector.lowerBound) * (node.depth == 0 ? 1 : 0.92), need))
                var cursor = (sector.lowerBound + sector.upperBound) / 2 - width / 2
                for k in arranged {
                    let c = folders[k], w = width * CGFloat(scores[k] / sum)
                    let sub = cursor...(cursor + w)
                    cursor += w
                    var childAngle = (sub.lowerBound + sub.upperBound) / 2
                    if c == leader { childAngle = childAngle * 0.5 + tipAngle * 0.5 }
                    let childLength = childLength(c)
                    let t = attach[c] ?? 1
                    let index = min(points.count - 1, Int((t * CGFloat(Self.samples - 1)).rounded()))
                    let childBase = c == leader ? tip : points[index]
                    subtree = subtree.union(grow(c, base: childBase, angle: childAngle, from: c == leader ? tipAngle : angle, sector: sub, length: childLength))
                }
            }
            // Leaves at the tip: files and grouped items as a sunflower (golden-angle) cluster; an unopened folder as a bud.
            var clusterItems = node.expanded ? terminals : []
            if !node.expanded && node.isFolder && node.role != .rest && node.bytes != nil && i != 0 { clusterItems = [i] }
            if !clusterItems.isEmpty {
                let leafRadii = clusterItems.map { tree[$0].bytes == nil ? 1.0 : max(0.9, 2.1 * radius(tree[$0].weight)) }
                let spacing = 1.05 * (leafRadii.reduce(0, +) / CGFloat(leafRadii.count)) + 0.6
                let center = tip + dir(tipAngle) * (leafRadii[0] * 0.8)
                for (k, c) in clusterItems.enumerated() {
                    let a = CGFloat(k) * 2.399963 + noise(c, 3)
                    let d = k == 0 ? 0 : spacing * sqrt(CGFloat(k) + 0.5) * 1.15
                    let kind: Leaf.Kind = c == i ? .bud : (tree[c].role == .rest ? .grouped : .file)
                    let leaf = Leaf(node: c, center: center + CGPoint(x: cos(a) * d, y: sin(a) * d), radius: leafRadii[k], kind: kind)
                    if kind == .bud { budOf[c] = leaves.count } else { leafOf[c] = leaves.count }
                    leaves.append(leaf)
                    subtree = subtree.union(CGRect(x: leaf.center.x - leaf.radius, y: leaf.center.y - leaf.radius, width: 2 * leaf.radius, height: 2 * leaf.radius))
                }
            }
            subtreeBounds[i] = subtree
            return subtree
        }

        let full = grow(0, base: .zero, angle: 0, from: 0, sector: -1.32...1.32, length: Self.trunkLength)
        bounds = full.union(CGRect(x: -20, y: -2, width: 40, height: 10)).insetBy(dx: -8, dy: -8)
        drawOrder = limbs.indices.sorted { (limbs[$0].radii.first ?? 0) < (limbs[$1].radii.first ?? 0) }
    }

    func focusRect(_ node: Int) -> CGRect? { subtreeBounds[node] ?? leafOf[node].map { l in CGRect(x: leaves[l].center.x - 20, y: leaves[l].center.y - 20, width: 40, height: 40) } }

    // MARK: Colours

    private func bark(_ depth: Int, dark: Bool) -> Color {
        let t = min(1, Double(depth) / 7)
        return dark ? Color(red: 0.66 - 0.16 * t, green: 0.56 - 0.02 * t, blue: 0.46 - 0.04 * t)
                    : Color(red: 0.37 + 0.08 * t, green: 0.29 + 0.21 * t, blue: 0.22 + 0.13 * t)
    }
    private func leafColor(_ leaf: Leaf, dark: Bool) -> Color {
        let n = tree[leaf.node].key.noise(11)
        switch leaf.kind {
        case .file: return Color(hue: 0.27 + 0.08 * n, saturation: dark ? 0.55 : 0.6, brightness: dark ? 0.72 : 0.6).opacity(0.9)
        case .grouped: return Color(hue: 0.22, saturation: 0.25, brightness: dark ? 0.62 : 0.72).opacity(0.6)
        case .bud: return Color(hue: 0.36, saturation: 0.45, brightness: dark ? 0.45 : 0.42).opacity(0.85)
        }
    }

    // MARK: Drawing

    private func zoom(_ t: ProtoTransform, _ size: CGSize) -> CGFloat { t.scale / ProtoCamera.fitScale(bounds, in: size) }
    private func screenRect(_ r: CGRect, _ t: ProtoTransform) -> CGRect {
        CGRect(x: r.minX * t.scale + t.offset.x, y: r.minY * t.scale + t.offset.y, width: r.width * t.scale, height: r.height * t.scale)
    }
    /// Level of detail and culling: limbs thinner than a fifth of a point and shorter than 1.5 pt are left out.
    private func visible(_ limb: Limb, _ t: ProtoTransform, view: CGRect) -> Bool {
        guard (limb.radii.first ?? 0) * t.scale >= 0.2 || limb.length * t.scale >= 1.5 else { return false }
        return screenRect(limb.bounds, t).intersects(view)
    }

    private func limbPath(_ limb: Limb, _ t: ProtoTransform, widen: CGFloat = 0) -> Path {
        let pts = limb.samples.map(t.apply)
        var left = [CGPoint](), right = [CGPoint]()
        for k in pts.indices {
            let a = pts[max(0, k - 1)], b = pts[min(pts.count - 1, k + 1)]
            let d = b - a, len = max(d.length, 0.0001)
            let n = CGPoint(x: -d.y / len, y: d.x / len)
            let half = max(0.35, limb.radii[k] * t.scale) + widen
            left.append(pts[k] + n * half); right.append(pts[k] - n * half)
        }
        let end = pts[pts.count - 1], before = pts[pts.count - 2], step = max((end - before).length, 0.0001)
        let cap = end + (end - before) * ((max(0.35, limb.radii.last! * t.scale) + widen) / step)
        var path = Path()
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        path.addQuadCurve(to: right.last!, control: cap)
        for p in right.reversed().dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }
    private func disc(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

    func draw(_ ctx: inout GraphicsContext, _ t: ProtoTransform, size: CGSize, state: ProtoViewState, labels: [ProtoLabel], palette: ProtoPalette) -> ProtoDrawStats {
        var stats = ProtoDrawStats()
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.background))
        // Ground: a horizon line and soft soil under the trunk.
        let ground = t.apply(.zero)
        if ground.y < size.height + 20 {
            ctx.fill(Path(CGRect(x: 0, y: ground.y, width: size.width, height: max(0, size.height - ground.y))), with: .color(palette.dark ? Color.white.opacity(0.025) : Color(red: 0.55, green: 0.45, blue: 0.3).opacity(0.06)))
            var line = Path(); line.move(to: CGPoint(x: 0, y: ground.y)); line.addLine(to: CGPoint(x: size.width, y: ground.y))
            ctx.stroke(line, with: .color(palette.secondaryInk.opacity(0.35)), lineWidth: 0.75)
            stats.primitives += 2
        }
        // Buds and grouped clumps behind the limbs; files in front.
        for leaf in leaves where leaf.kind != .file {
            let c = t.apply(leaf.center), r = leaf.radius * t.scale
            guard r >= 0.5, view.contains(c) else { continue }
            ctx.fill(disc(c, r), with: .color(leafColor(leaf, dark: palette.dark)))
            if leaf.kind == .bud && r >= 7 {
                ctx.stroke(disc(c, r), with: .color(palette.ink.opacity(0.25)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
                var plus = Path(); plus.move(to: CGPoint(x: c.x - 3, y: c.y)); plus.addLine(to: CGPoint(x: c.x + 3, y: c.y)); plus.move(to: CGPoint(x: c.x, y: c.y - 3)); plus.addLine(to: CGPoint(x: c.x, y: c.y + 3))
                ctx.stroke(plus, with: .color(palette.ink.opacity(0.55)), lineWidth: 1.2)
            }
            stats.primitives += 1; stats.nodesDrawn += 1
        }
        for l in drawOrder {
            let limb = limbs[l]
            guard visible(limb, t, view: view) else { continue }
            let shape = limbPath(limb, t)
            if limb.unmeasured { ctx.stroke(shape, with: .color(palette.secondaryInk.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2])) }
            else { ctx.fill(shape, with: .color(bark(tree[limb.node].depth, dark: palette.dark))) }
            stats.primitives += 1; stats.nodesDrawn += 1
        }
        for leaf in leaves where leaf.kind == .file {
            let c = t.apply(leaf.center), r = leaf.radius * t.scale
            guard r >= 0.5, view.contains(c) else { continue }
            ctx.fill(disc(c, r), with: .color(leafColor(leaf, dark: palette.dark)))
            stats.primitives += 1; stats.nodesDrawn += 1
        }
        // Selection: the whole chain from the trunk, outlined in the accent; the selected element filled.
        for node in state.selected.map(tree.ancestry) ?? [] {
            if let l = limbOf[node] {
                ctx.stroke(limbPath(limbs[l], t, widen: 1.5), with: .color(palette.accent), lineWidth: node == state.selected ? 2.5 : 1.5)
                if node == state.selected { ctx.fill(limbPath(limbs[l], t), with: .color(palette.accent.opacity(0.85))) }
            }
            if let l = leafOf[node] ?? (node == state.selected ? budOf[node] : nil) {
                let c = t.apply(leaves[l].center), r = max(4, leaves[l].radius * t.scale)
                ctx.stroke(disc(c, r + 2), with: .color(palette.accent), lineWidth: 2.5)
            }
        }
        if let hovered = state.hovered, hovered != state.selected {
            if let l = limbOf[hovered] { ctx.stroke(limbPath(limbs[l], t, widen: 1), with: .color(palette.ink.opacity(0.7)), lineWidth: 1) }
            else if let l = leafOf[hovered] { ctx.stroke(disc(t.apply(leaves[l].center), max(3, leaves[l].radius * t.scale) + 1.5), with: .color(palette.ink.opacity(0.7)), lineWidth: 1) }
        }
        for label in labels { ProtoText.drawPill(&ctx, label, palette: palette) }
        stats.labels = labels.count
        return stats
    }

    // MARK: Labels

    func labels(_ t: ProtoTransform, size: CGSize, state: ProtoViewState) -> [ProtoLabel] {
        var placer = ProtoLabelPlacer(size: size)
        let budget = 16 + Int(10 * log2(max(1, zoom(t, size))))
        func make(_ node: Int, emphasized: Bool) -> ProtoLabel? {
            let n = tree[node]
            let title = tree.label(node), detail = ProtoFormat.bytes(n.bytes)
            let pill = ProtoText.pill(title, detail)
            if let l = limbOf[node] {
                let limb = limbs[l], mid = limb.samples.count / 2
                let p = t.apply(limb.samples[mid]), half = limb.radii[mid] * t.scale
                let lean = limb.samples.last!.x - limb.samples.first!.x
                let x = lean >= 0 ? p.x + half + 6 : p.x - half - 6 - pill.width
                return ProtoLabel(node: node, title: title, detail: detail, rect: CGRect(x: x, y: p.y - pill.height / 2, width: pill.width, height: pill.height), emphasized: emphasized)
            }
            if let l = leafOf[node] {
                let c = t.apply(leaves[l].center), r = leaves[l].radius * t.scale
                return ProtoLabel(node: node, title: title, detail: detail, rect: CGRect(x: c.x + r + 5, y: c.y - pill.height / 2, width: pill.width, height: pill.height), emphasized: emphasized)
            }
            return nil
        }
        if let s = state.selected, let label = make(s, emphasized: true) { placer.place(label, force: true) }
        // Candidates: limbs wide enough on screen and large leaves, by size.
        let view = CGRect(origin: .zero, size: size)
        var candidates = [(Int, Double)]()
        for limb in limbs where !limb.unmeasured && (limb.radii.first ?? 0) * t.scale * 2 >= 2.2 && view.intersects(screenRect(limb.bounds, t)) { candidates.append((limb.node, tree[limb.node].weight)) }
        for leaf in leaves where leaf.kind == .file && leaf.radius * t.scale >= 6 && view.contains(t.apply(leaf.center)) { candidates.append((leaf.node, tree[leaf.node].weight)) }
        candidates.sort { $0.1 > $1.1 }
        for (node, _) in candidates where node != state.selected {
            if placer.placed.count >= budget { break }
            if let label = make(node, emphasized: false) { placer.place(label) }
        }
        return placer.placed
    }

    // MARK: Hit testing

    /// Labels first; then the element whose outline is nearest relative to its size (a point inside a limb scores
    /// below 1), with at least 6 pt of reach so thin twigs and small leaves stay clickable; ties go to the smaller.
    func hit(_ p: CGPoint, _ t: ProtoTransform, labels: [ProtoLabel]) -> Int? {
        if let label = labels.last(where: { $0.contains(p) }) { return label.node }
        let lp = t.invert(p), tolerance = 6 / t.scale
        var best: (score: CGFloat, weight: Double, node: Int)?
        func consider(_ score: CGFloat, _ node: Int) {
            let w = tree[node].weight
            if best == nil || score < best!.score - 0.05 || (abs(score - best!.score) <= 0.05 && w < best!.weight) { best = (score, w, node) }
        }
        for leaf in leaves where leaf.radius * t.scale >= 0.5 {
            let reach = max(leaf.radius, tolerance), d = (lp - leaf.center).length
            if d <= reach { consider(d / reach * 0.9, leaf.node) }
        }
        for limb in limbs where (limb.radii.first ?? 0) * t.scale >= 0.2 || limb.length * t.scale >= 1.5 {
            guard limb.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(lp) else { continue }
            for k in 1..<limb.samples.count {
                let (d, u) = protoSegmentDistance(lp, limb.samples[k - 1], limb.samples[k])
                let r = limb.radii[k - 1] + (limb.radii[k] - limb.radii[k - 1]) * u
                let reach = max(r, tolerance)
                if d <= reach { consider(d / reach, limb.node) }
            }
        }
        return best?.node
    }
}
