import SwiftUI

// PROTOTYPE B — Structured Hierarchical Explorer.
//
// A radial tidy tree centred on the folder being explored, with a controlled depth (1–6 levels, default 3). Every
// level sits on its own ring, children run clockwise from 12 o'clock largest first, and links run from parent to
// child along the ring structure, so position alone tells depth and order. Size is encoded twice and exactly: a node's
// disc area ∝ bytes, and the arc around it is its share of its parent. Link width follows the bytes that flow through
// it, and colour follows the top-level branch, so "where am I" stays visible deep in the tree. Folders with contents
// that are not shown carry an outward "+N" marker; double-click re-centres there.
//
// Layout: a port of d3-hierarchy's tree() (ISC, © 2010–2021 Mike Bostock), the Buchheim–Jünger–Leipert linear-time
// Reingold–Tilford/Walker algorithm (firstWalk / apportion / secondWalk), with d3's radial separation
// (a.parent == b.parent ? 1 : 2) / a.depth and size([2π, R]). Deterministic: the same hierarchy always draws the same.

@MainActor final class StructuredExplorerScene: ProtoScene {
    struct Placed {
        let node: Int
        let angle: CGFloat
        let ring: Int
        let point: CGPoint
        let radius: CGFloat
        let hidden: Int
        let category: Int
    }

    let tree: ProtoTree
    let focus: Int
    let depthLimit: Int
    let title = "Structured Explorer"
    private(set) var bounds: CGRect = .zero
    private(set) var placed: [Placed] = []
    private var placedOf: [Int: Int] = [:]
    private var children: [[Int]] = []      // indices into `placed`
    private var parentOf: [Int] = []
    private var subtreeBounds: [Int: CGRect] = [:]
    var laidOut: Int { placed.count }

    static let ringGap: CGFloat = 150, focusRadius: CGFloat = 30, perFolder = 14

    var legend: [String] { [
        "Rings are levels below \(ProtoText.short(focus == 0 ? tree.rootName : tree[focus].name, limit: 30)); children run clockwise from 12 o'clock, largest first",
        "Disc area ∝ bytes · the arc around a disc is its share of its parent · link width follows size · colour: top-level branch",
        "+N: contents not shown — double-click to explore there; Up returns to the parent",
    ] }

    /// - Parameters: `focus`: the centre; `selected`: kept visible even beyond the per-folder limit.
    init(tree: ProtoTree, focus: Int = 0, depth: Int = 3, keep selected: Int? = nil) {
        self.tree = tree; self.focus = focus; self.depthLimit = max(1, min(6, depth))
        let keep = Set(selected.map(tree.ancestry) ?? [])
        let focusWeight = max(tree[focus].weight, 1)

        // Visible set: breadth-first from the focus, the largest `perFolder` children of each folder (and anything on
        // the selection's path), down to the depth limit.
        var order = [focus], hiddenCount = [Int: Int]()
        parentOf = [-1]; children = [[]]
        var head = 0
        while head < order.count {
            let v = head, node = order[v]
            head += 1
            let ring = tree[node].depth - tree[focus].depth
            let all = tree[node].children
            guard ring < depthLimit else { hiddenCount[node] = all.count; continue }
            var shown = 0, hidden = 0
            for c in all {
                if shown < Self.perFolder || keep.contains(c) {
                    shown += 1
                    let index = order.count
                    order.append(c); parentOf.append(v); children.append([]); children[v].append(index)
                } else { hidden += 1 }
            }
            hiddenCount[node] = hidden
        }

        // Tidy tree (d3-hierarchy tree.js): prelim z, modifier m, change c, shift s, thread, ancestor a, default A.
        let n = order.count, superRoot = n
        var z = [CGFloat](repeating: 0, count: n + 1), m = z, c = z, s = z
        var thread = [Int](repeating: -1, count: n + 1), ancestor = Array(0...n), defaultAncestor = [Int](repeating: -1, count: n + 1)
        let kids = children + [[0]]
        var parent = parentOf + [-1]
        parent[0] = superRoot
        var sibling = [Int](repeating: 0, count: n + 1)
        for v in 0...n { for (k, w) in kids[v].enumerated() { sibling[w] = k } }
        func ring(_ v: Int) -> Int { v == superRoot ? -1 : tree[order[v]].depth - tree[focus].depth }
        func separation(_ a: Int, _ b: Int) -> CGFloat { (parent[a] == parent[b] ? 1 : 2) / CGFloat(max(1, ring(a))) }
        func nextLeft(_ v: Int) -> Int { kids[v].first ?? thread[v] }
        func nextRight(_ v: Int) -> Int { kids[v].last ?? thread[v] }
        func moveSubtree(_ wm: Int, _ wp: Int, _ shift: CGFloat) {
            let change = shift / CGFloat(sibling[wp] - sibling[wm])
            c[wp] -= change; s[wp] += shift; c[wm] += change; z[wp] += shift; m[wp] += shift
        }
        func executeShifts(_ v: Int) {
            var shift: CGFloat = 0, change: CGFloat = 0
            for w in kids[v].reversed() { z[w] += shift; m[w] += shift; change += c[w]; shift += s[w] + change }
        }
        func nextAncestor(_ vim: Int, _ v: Int, _ a: Int) -> Int { parent[ancestor[vim]] == parent[v] ? ancestor[vim] : a }
        func apportion(_ v: Int, _ w: Int?, _ a0: Int) -> Int {
            guard let w else { return a0 }
            var a = a0
            var vip = v, vop = v, vim = w, vom = kids[parent[v]][0]
            var sip = m[vip], sop = m[vop], sim = m[vim], som = m[vom]
            while true {
                let nr = nextRight(vim), nl = nextLeft(vip)
                guard nr >= 0, nl >= 0 else { break }
                vim = nr; vip = nl
                vom = nextLeft(vom); vop = nextRight(vop)
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
            let p = parent[v], k = sibling[v], w: Int? = k > 0 ? kids[p][k - 1] : nil
            if let first = kids[v].first, let last = kids[v].last {
                executeShifts(v)
                let midpoint = (z[first] + z[last]) / 2
                if let w { z[v] = z[w] + separation(v, w); m[v] = z[v] - midpoint } else { z[v] = midpoint }
            } else if let w { z[v] = z[w] + separation(v, w) }
            defaultAncestor[p] = apportion(v, w, defaultAncestor[p] >= 0 ? defaultAncestor[p] : kids[p][0])
        }
        // Pre-order list; post-order is its reverse with children visited right to left, which d3's eachAfter matches
        // in what matters (every child before its parent, siblings left to right).
        var pre = [Int](), stack = [0]
        while let v = stack.popLast() { pre.append(v); stack += kids[v].reversed() }
        var post = [Int](), walk = [(0, false)]
        while let (v, expanded) = walk.popLast() {
            if expanded { post.append(v); continue }
            walk.append((v, true)); for w in kids[v].reversed() { walk.append((w, false)) }
        }
        for v in post { firstWalk(v) }
        m[superRoot] = -z[0]
        var x = [CGFloat](repeating: 0, count: n)
        for v in pre { let p = parent[v]; x[v] = z[v] + m[p]; m[v] += m[p] }
        // size([2π, R]): spread the extremes over the full turn with half a separation at each end.
        let left = (0..<n).min { x[$0] < x[$1] } ?? 0, right = (0..<n).max { x[$0] < x[$1] } ?? 0
        let sep = left == right ? 1 : separation(left, right) / 2, tx = sep - x[left], kx = 2 * CGFloat.pi / max(x[right] + sep + tx, 0.0001)

        // Top-level branch of every visible node, for colour.
        var category = [Int](repeating: -1, count: n)
        for v in pre where v != 0 { category[v] = parentOf[v] == 0 ? children[0].firstIndex(of: v)! : category[parentOf[v]] }
        for v in 0..<n {
            let node = order[v], r = ring(v)
            let angle = n == 1 ? 0 : (x[v] + tx) * kx
            let point = CGPoint(x: sin(angle) * CGFloat(r) * Self.ringGap, y: -cos(angle) * CGFloat(r) * Self.ringGap)
            let radius = tree[node].bytes == nil ? 2.5 : max(2.5, Self.focusRadius * CGFloat(sqrt(tree[node].weight / focusWeight)))
            placedOf[node] = placed.count
            placed.append(Placed(node: node, angle: angle, ring: r, point: point, radius: radius, hidden: hiddenCount[node] ?? 0, category: category[v]))
        }
        for v in post {
            var box = CGRect(x: placed[v].point.x - placed[v].radius, y: placed[v].point.y - placed[v].radius, width: 2 * placed[v].radius, height: 2 * placed[v].radius)
            for w in children[v] { box = box.union(subtreeBounds[order[w]]!) }
            subtreeBounds[order[v]] = box
        }
        let extent = CGFloat(placed.map(\.ring).max() ?? 0) * Self.ringGap + 60
        bounds = CGRect(x: -extent, y: -extent, width: 2 * extent, height: 2 * extent)
    }

    func focusRect(_ node: Int) -> CGRect? { subtreeBounds[node] }
    func isPlaced(_ node: Int) -> Bool { placedOf[node] != nil }

    // MARK: Colours

    private static let hues: [Double] = [0.58, 0.08, 0.33, 0.83, 0.13, 0.48, 0.0, 0.70]
    private func color(_ p: Placed, dark: Bool) -> Color {
        guard p.category >= 0 else { return dark ? Color(white: 0.85) : Color(white: 0.25) }
        return Color(hue: Self.hues[p.category % Self.hues.count], saturation: dark ? 0.45 : 0.55, brightness: dark ? 0.82 : 0.62)
    }

    // MARK: Drawing

    private func zoom(_ t: ProtoTransform, _ size: CGSize) -> CGFloat { t.scale / ProtoCamera.fitScale(bounds, in: size) }

    private func link(_ from: Placed, _ to: Placed, _ t: ProtoTransform) -> Path {
        // d3.linkRadial: control points at the mid radius, on each end's angle.
        let mid = (CGFloat(from.ring) + CGFloat(to.ring)) / 2 * Self.ringGap
        let c1 = from.ring == 0 ? from.point : CGPoint(x: sin(from.angle) * mid, y: -cos(from.angle) * mid)
        let c2 = CGPoint(x: sin(to.angle) * mid, y: -cos(to.angle) * mid)
        var path = Path()
        path.move(to: t.apply(from.point)); path.addCurve(to: t.apply(to.point), control1: t.apply(c1), control2: t.apply(c2))
        return path
    }

    func draw(_ ctx: inout GraphicsContext, _ t: ProtoTransform, size: CGSize, state: ProtoViewState, labels: [ProtoLabel], palette: ProtoPalette) -> ProtoDrawStats {
        var stats = ProtoDrawStats()
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -30, dy: -30)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.background))
        let centre = t.apply(.zero)
        let deepest = placed.map(\.ring).max() ?? 0
        if deepest > 0 {
            for r in 1...deepest {
                let radius = CGFloat(r) * Self.ringGap * t.scale
                ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)), with: .color(palette.secondaryInk.opacity(0.14)), lineWidth: 0.75)
                ctx.draw(Text("Level \(r)").font(.system(size: 9.5, weight: .medium)).foregroundColor(palette.secondaryInk.opacity(0.7)), at: CGPoint(x: centre.x + 4, y: centre.y - radius - 7), anchor: .leading)
                stats.primitives += 2
            }
        }
        let focusWeight = max(tree[focus].weight, 1)
        // Links, thinnest first so heavy flows sit on top.
        let linkOrder = placed.indices.dropFirst().sorted { tree[placed[$0].node].weight < tree[placed[$1].node].weight }
        for v in linkOrder {
            let child = placed[v], from = placed[parentOf[v]]
            let a = t.apply(from.point), b = t.apply(child.point)
            guard view.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -40, dy: -40)) else { continue }
            let width = max(0.6, (0.8 + 9 * CGFloat(sqrt(tree[child.node].weight / focusWeight))) * min(1.6, t.scale))
            ctx.stroke(link(from, child, t), with: .color(color(child, dark: palette.dark).opacity(0.45)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            stats.primitives += 1
        }
        // Selection path from the centre, in the accent.
        for node in state.selected.map(tree.ancestry) ?? [] where node != focus {
            guard let v = placedOf[node], parentOf[v] >= 0 else { continue }
            ctx.stroke(link(placed[parentOf[v]], placed[v], t), with: .color(palette.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        // Discs, largest first so small ones stay on top and clickable.
        for p in placed.sorted(by: { $0.radius > $1.radius }) {
            let c = t.apply(p.point), r = max(2.2, p.radius * t.scale)
            guard view.contains(c) else { continue }
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            let node = tree[p.node]
            if node.bytes == nil {
                ctx.stroke(Path(ellipseIn: rect), with: .color(palette.secondaryInk), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            } else if node.role == .rest {
                ctx.fill(Path(ellipseIn: rect), with: .color(palette.secondaryInk.opacity(0.25)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(palette.secondaryInk.opacity(0.6)), lineWidth: 0.75)
            } else if node.isFolder {
                ctx.fill(Path(ellipseIn: rect), with: .color(color(p, dark: palette.dark)))
            } else {
                ctx.fill(Path(ellipseIn: rect), with: .color(palette.background))
                ctx.stroke(Path(ellipseIn: rect), with: .color(color(p, dark: palette.dark)), lineWidth: max(1, min(2.5, r / 4)))
            }
            // Share of parent, as an arc just outside the disc.
            if let share = tree.shareOfParent(p.node), r >= 4 {
                var arc = Path()
                arc.addArc(center: c, radius: r + 2.5, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * share), clockwise: false)
                ctx.stroke(arc, with: .color(palette.ink.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
            }
            // Contents not shown: a small outward "+N".
            if p.hidden > 0 && node.isFolder && r >= 3 && zoom(t, size) >= 0.8 {
                let out = p.ring == 0 ? CGPoint(x: 0, y: 1) : CGPoint(x: sin(p.angle), y: -cos(p.angle))
                ctx.draw(Text("+\(p.hidden)").font(.system(size: 8.5, weight: .semibold)).foregroundColor(palette.secondaryInk), at: c + out * (r + 9))
                stats.primitives += 1
            }
            stats.primitives += 1; stats.nodesDrawn += 1
        }
        if let s = state.selected, let v = placedOf[s] {
            let c = t.apply(placed[v].point), r = max(4, placed[v].radius * t.scale) + 5
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(palette.accent), lineWidth: 2.5)
        }
        if let h = state.hovered, h != state.selected, let v = placedOf[h] {
            let c = t.apply(placed[v].point), r = max(4, placed[v].radius * t.scale) + 4
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(palette.ink.opacity(0.7)), lineWidth: 1)
        }
        for label in labels { ProtoText.drawPill(&ctx, label, palette: palette) }
        stats.labels = labels.count
        return stats
    }

    // MARK: Labels

    func labels(_ t: ProtoTransform, size: CGSize, state: ProtoViewState) -> [ProtoLabel] {
        var placer = ProtoLabelPlacer(size: size)
        let budget = 30 + Int(12 * log2(max(1, zoom(t, size))))
        // Discs block labels, so a label never hides a node.
        placer.blocked = placed.filter { $0.radius * t.scale >= 3 }.map { p in let c = t.apply(p.point), r = p.radius * t.scale; return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }
        func make(_ v: Int, emphasized: Bool) -> ProtoLabel {
            let p = placed[v], node = tree[p.node]
            let title = tree.label(p.node), detail = ProtoFormat.bytes(node.bytes)
            let pill = ProtoText.pill(title, detail)
            let c = t.apply(p.point), r = max(2.2, p.radius * t.scale)
            if p.ring == 0 { return ProtoLabel(node: p.node, title: title, detail: detail, rect: CGRect(x: c.x - pill.width / 2, y: c.y + r + 8, width: pill.width, height: pill.height), emphasized: emphasized) }
            if p.ring == 1 {
                // First ring: horizontal, beside the disc on its outer side.
                let right = sin(p.angle) >= -0.05
                return ProtoLabel(node: p.node, title: title, detail: detail, rect: CGRect(x: right ? c.x + r + 6 : c.x - r - 6 - pill.width, y: c.y - pill.height / 2, width: pill.width, height: pill.height), emphasized: emphasized)
            }
            // Outer rings: along the radius, outside the disc, flipped on the left half so text is never upside down.
            let anchor = c + CGPoint(x: sin(p.angle), y: -cos(p.angle)) * (r + 5)
            let rightHalf = sin(p.angle) >= 0
            let angle = Double(rightHalf ? p.angle - .pi / 2 : p.angle + .pi / 2)
            let rect = CGRect(x: rightHalf ? anchor.x : anchor.x - pill.width, y: anchor.y - pill.height / 2, width: pill.width, height: pill.height)
            return ProtoLabel(node: p.node, title: title, detail: detail, rect: rect, angle: angle, anchor: anchor, emphasized: emphasized)
        }
        let selectedPlaced = state.selected.flatMap { placedOf[$0] }
        if let v = selectedPlaced { placer.place(make(v, emphasized: true), force: true) }
        if selectedPlaced != 0 { placer.place(make(0, emphasized: false), force: true) }
        let view = CGRect(origin: .zero, size: size)
        let candidates = placed.indices.dropFirst().filter { $0 != selectedPlaced && view.contains(t.apply(placed[$0].point)) }
            .sorted { (placed[$0].ring, -tree[placed[$0].node].weight) < (placed[$1].ring, -tree[placed[$1].node].weight) }
        for v in candidates {
            if placer.placed.count >= budget { break }
            placer.place(make(v, emphasized: false))
        }
        return placer.placed
    }

    // MARK: Hit testing

    /// Labels first, then the disc whose centre is nearest relative to its size, with at least 6 pt of reach so small
    /// discs stay clickable; ties go to the smaller.
    func hit(_ p: CGPoint, _ t: ProtoTransform, labels: [ProtoLabel]) -> Int? {
        if let label = labels.last(where: { $0.contains(p) }) { return label.node }
        var best: (score: CGFloat, radius: CGFloat, node: Int)?
        for q in placed {
            let r = max(2.2, q.radius * t.scale), reach = max(r, 6), d = (t.apply(q.point) - p).length
            guard d <= reach else { continue }
            let score = d / reach
            if best == nil || score < best!.score - 0.05 || (abs(score - best!.score) <= 0.05 && r < best!.radius) { best = (score, r, q.node) }
        }
        return best?.node
    }
}
