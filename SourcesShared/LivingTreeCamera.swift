import Foundation
import CoreGraphics

// Living Tree camera: a 2D view onto the tree. The tree is laid out once per rebuild in a fixed layout space
// (`LivingTreeCamera.layoutSize`, independent of the window), so a camera position means the same place in the tree
// across window resizes and incremental rebuilds. The camera frames the tree's actual extent (its tips and their
// light, not the nominal crown), then zooms and pans relative to that fit.
//
// Everything here is free of SwiftUI and AppKit so it can be tested: the transform, the fit, zoom about a point,
// pan limits, focus and reveal, the smoothed motion between camera positions, level of detail, label placement and
// the interpretation of pointer, scroll and pinch input.

// MARK: Transform

/// Maps layout space to the view: `view.x = layout.x × scale × stretch + translation.dx`, `view.y = layout.y × scale +
/// translation.dy`. Positions scale fully; stroke widths and tip light scale with the square root of `scale`
/// (`widthScale`), so zooming in separates fine branches without turning the trunk into a slab. Every width is
/// multiplied by the same factor, so thickness keeps encoding size. `stretch` (1…1.3) widens the crown sideways in
/// wide views; it moves branches, never widens them.
public struct LivingTreeTransform: Equatable, Sendable {
    public let scale: CGFloat
    public let stretch: CGFloat
    public let translation: CGVector

    public static let identity = LivingTreeTransform(scale: 1, translation: .zero)

    public init(scale: CGFloat, stretch: CGFloat = 1, translation: CGVector) { self.scale = scale; self.stretch = stretch; self.translation = translation }

    public var scaleX: CGFloat { scale * stretch }
    public var widthScale: CGFloat { min(4, max(0.45, scale.squareRoot())) }

    public func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scaleX + translation.dx, y: p.y * scale + translation.dy) }
    public func invert(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - translation.dx) / scaleX, y: (p.y - translation.dy) / scale) }
    public func apply(_ r: CGRect) -> CGRect {
        let o = apply(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * scaleX, height: r.height * scale)
    }
    public func invert(_ r: CGRect) -> CGRect {
        let o = invert(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width / scaleX, height: r.height / scale)
    }
    /// A layout-space direction as it appears on screen (unit length).
    public func direction(_ d: CGVector) -> CGVector {
        let x = d.dx * stretch, y = d.dy, l = max(1e-9, (x * x + y * y).squareRoot())
        return CGVector(dx: x / l, dy: y / l)
    }
}

// MARK: Framing

/// How the whole tree fits a viewport: the extent being framed, the margins kept clear (room for labels above and
/// at the sides), the scale at which the tree just fits, and the point of the view the camera centres on.
public struct LivingTreeFraming: Equatable, Sendable {
    public struct Margins: Equatable, Sendable {
        public var top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat
        public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
            self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
        }
        /// Room for a two-line label above the highest tips and beside the outermost ones.
        public static let standard = Margins(top: 30, leading: 22, bottom: 12, trailing: 22)
    }

    public let viewport: CGSize
    /// The framed extent in layout space (every branch, tip and tip light).
    public let bounds: CGRect
    public let margins: Margins
    /// The view area the fitted tree occupies.
    public let available: CGRect
    /// Layout units to view points when the whole tree just fits.
    public let fitScale: CGFloat
    /// The layout point shown at `anchor` when fitted.
    public let fitCenter: CGPoint
    /// The view point a camera centre is shown at: the middle of `available`.
    public let anchor: CGPoint
    /// Sideways stretch when the view has width to spare (a height-limited fit): at most `maximumStretch`.
    public let stretch: CGFloat
    public static let maximumStretch: CGFloat = 1.3

    /// - Parameter axis: the trunk's horizontal position. The fit centres halfway between the tree's extent and the
    ///   trunk, so a lopsided crown still uses the space while the trunk stays near the middle (balanced).
    public init(viewport: CGSize, bounds: CGRect, axis: CGFloat? = nil, margins: Margins = .standard) {
        let size = CGSize(width: max(1, viewport.width), height: max(1, viewport.height))
        var extent = bounds.isNull || bounds.isInfinite ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds.standardized
        if extent.width < 1 { extent = extent.insetBy(dx: (extent.width - 1) / 2, dy: 0) }
        if extent.height < 1 { extent = extent.insetBy(dx: 0, dy: (extent.height - 1) / 2) }
        let available = CGRect(x: margins.leading, y: margins.top,
                               width: max(1, size.width - margins.leading - margins.trailing), height: max(1, size.height - margins.top - margins.bottom))
        let middle = extent.midX
        let trunk = axis.map { min(max($0, extent.minX), extent.maxX) } ?? middle
        let centre = middle + 0.5 * (trunk - middle)
        let half = max(centre - extent.minX, extent.maxX - centre, 0.5)
        self.viewport = size; self.bounds = extent; self.margins = margins; self.available = available
        let fit = max(1e-4, min(available.width / (2 * half), available.height / extent.height))
        fitScale = fit
        stretch = min(Self.maximumStretch, max(1, available.width / (2 * half * fit)))
        fitCenter = CGPoint(x: centre, y: extent.midY)
        anchor = CGPoint(x: available.midX, y: available.midY)
    }

    /// Layout units to view points, horizontally and vertically, at a camera zoom.
    public func scales(_ zoom: Double) -> (x: CGFloat, y: CGFloat) { (fitScale * CGFloat(zoom) * stretch, fitScale * CGFloat(zoom)) }
}

// MARK: Camera

/// Where the view looks: a zoom relative to the fit (1 shows the whole tree) and the layout point at the framing's
/// anchor (nil follows the fit, so an untouched view refits on resize).
public struct LivingTreeCamera: Equatable, Sendable {
    public var zoom: Double
    public var center: CGPoint?

    public init(zoom: Double, center: CGPoint?) { self.zoom = zoom; self.center = center }

    public static let fit = LivingTreeCamera(zoom: 1, center: nil)
    /// Out to half the fit (the tree with room around it), in to 32 times: a deep twig a few layout units long then
    /// spans a usable part of the screen.
    public static let minimumZoom = 0.5, maximumZoom = 32.0
    /// Focusing on an element never zooms further than this (a single tip would otherwise fill the view).
    public static let focusZoomLimit = 10.0
    /// The fixed layout space every tree is laid out in.
    public static let layoutSize = CGSize(width: 1400, height: 900)
    /// How much of the tree's extent, in view points, always stays on screen when panning.
    public static let visibleMargin: CGFloat = 120

    public var isFit: Bool { center == nil && abs(zoom - 1) < 1e-9 }

    public static func clampZoom(_ zoom: Double) -> Double { min(maximumZoom, max(minimumZoom, zoom.isFinite ? zoom : 1)) }

    public func resolvedCenter(in framing: LivingTreeFraming) -> CGPoint { center ?? framing.fitCenter }

    public func transform(in framing: LivingTreeFraming) -> LivingTreeTransform {
        let s = framing.scales(zoom), c = resolvedCenter(in: framing)
        return LivingTreeTransform(scale: s.y, stretch: framing.stretch, translation: CGVector(dx: framing.anchor.x - c.x * s.x, dy: framing.anchor.y - c.y * s.y))
    }

    /// The camera at `zoom` that shows layout point `content` at view point `view`.
    public static func pinning(_ content: CGPoint, to view: CGPoint, zoom: Double, in framing: LivingTreeFraming) -> LivingTreeCamera {
        let s = framing.scales(zoom)
        return LivingTreeCamera(zoom: zoom, center: CGPoint(x: content.x - (view.x - framing.anchor.x) / s.x, y: content.y - (view.y - framing.anchor.y) / s.y))
    }

    /// Zooms by `factor` about a view point: what is under that point stays under it (unless the pan limit
    /// intervenes at the edge of the tree).
    public func zoomed(by factor: Double, around point: CGPoint, in framing: LivingTreeFraming) -> LivingTreeCamera {
        let zoom = Self.clampZoom(self.zoom * factor)
        guard zoom != self.zoom else { return clamped(in: framing) }
        let content = transform(in: framing).invert(point)
        return Self.pinning(content, to: point, zoom: zoom, in: framing).clamped(in: framing)
    }

    /// Moves the view's contents by `delta` view points (as a drag would).
    public func panned(by delta: CGVector, in framing: LivingTreeFraming) -> LivingTreeCamera {
        let s = framing.scales(zoom), c = resolvedCenter(in: framing)
        return LivingTreeCamera(zoom: zoom, center: CGPoint(x: c.x - delta.dx / s.x, y: c.y - delta.dy / s.y)).clamped(in: framing)
    }

    /// Keeps the zoom in range and at least `visibleMargin` points of the tree's extent (all of it, when it is
    /// smaller) inside the view, so the tree can never be lost off screen.
    public func clamped(in framing: LivingTreeFraming) -> LivingTreeCamera {
        var camera = LivingTreeCamera(zoom: Self.clampZoom(zoom), center: center)
        guard camera.center != nil else { return camera }
        let view = framing.viewport
        let projected = camera.transform(in: framing).apply(framing.bounds)
        let keep = min(Self.visibleMargin, 0.3 * min(view.width, view.height))
        let keepX = min(keep, projected.width), keepY = min(keep, projected.height)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if projected.maxX < keepX { dx = keepX - projected.maxX } else if projected.minX > view.width - keepX { dx = view.width - keepX - projected.minX }
        if projected.maxY < keepY { dy = keepY - projected.maxY } else if projected.minY > view.height - keepY { dy = view.height - keepY - projected.minY }
        if dx != 0 || dy != 0, let c = camera.center {
            let s = framing.scales(camera.zoom)
            camera.center = CGPoint(x: c.x - dx / s.x, y: c.y - dy / s.y)
        }
        return camera
    }

    /// Frames `rect` (layout space): centred, as large as fits inside the margins and `padding`, never smaller than
    /// the fit and never closer than `limit`.
    public static func focusing(on rect: CGRect, in framing: LivingTreeFraming, padding: CGFloat = 36, limit: Double = focusZoomLimit) -> LivingTreeCamera {
        let area = framing.available.insetBy(dx: min(padding, framing.available.width / 4), dy: min(padding, framing.available.height / 4))
        let r = rect.standardized
        let s = min(area.width / max(r.width * framing.stretch, 1), area.height / max(r.height, 1))
        let zoom = clampZoom(min(max(1, Double(s / framing.fitScale)), limit))
        return LivingTreeCamera(zoom: zoom, center: CGPoint(x: r.midX, y: r.midY)).clamped(in: framing)
    }

    /// The smallest move that brings `rect` (layout space) inside the view with `margin` to spare. Nothing moves when
    /// it is already visible; a rect larger than the view is centred and the zoom reduced until it fits (never
    /// increased).
    public func revealing(_ rect: CGRect, in framing: LivingTreeFraming, margin: CGFloat = 28) -> LivingTreeCamera {
        let view = CGRect(origin: .zero, size: framing.viewport)
        let visible = view.insetBy(dx: min(margin, view.width / 4), dy: min(margin, view.height / 4))
        let p = transform(in: framing).apply(rect.standardized)
        if visible.contains(p) { return self }
        if p.width > visible.width || p.height > visible.height {
            let r = rect.standardized
            let s = min(visible.width / max(r.width * framing.stretch, 1), visible.height / max(r.height, 1))
            let zoom = Self.clampZoom(min(self.zoom, Double(s / framing.fitScale)))
            return LivingTreeCamera(zoom: zoom, center: CGPoint(x: r.midX, y: r.midY)).clamped(in: framing)
        }
        var dx: CGFloat = 0, dy: CGFloat = 0
        if p.minX < visible.minX { dx = visible.minX - p.minX } else if p.maxX > visible.maxX { dx = visible.maxX - p.maxX }
        if p.minY < visible.minY { dy = visible.minY - p.minY } else if p.maxY > visible.maxY { dy = visible.maxY - p.maxY }
        return panned(by: CGVector(dx: dx, dy: dy), in: framing)
    }
}

// MARK: Motion

/// Smoothed movement from the displayed camera to a target: zoom moves geometrically and the centre exponentially,
/// with a short time constant, so successive wheel steps or key presses blend into one continuous movement. A zoom
/// about a point keeps that point fixed on screen throughout. Direct manipulation and Reduce Motion jump instead.
public struct LivingTreeCameraMotion: Equatable, Sendable {
    public struct Anchor: Equatable, Sendable {
        public let view: CGPoint, content: CGPoint
        public init(view: CGPoint, content: CGPoint) { self.view = view; self.content = content }
    }

    public private(set) var displayed: LivingTreeCamera
    public private(set) var target: LivingTreeCamera
    public private(set) var anchor: Anchor?

    /// Seconds for about 63% of the remaining movement; settled in about a third of a second.
    public static let timeConstant = 0.07

    public init(_ camera: LivingTreeCamera = .fit) { displayed = camera; target = camera }

    public var isMoving: Bool { displayed != target }

    public mutating func jump(to camera: LivingTreeCamera) { displayed = camera; target = camera; anchor = nil }

    /// Starts moving toward `camera`. The anchor is kept only when the target really pins it (the pan limit can
    /// move a target away from its anchor; the centre then moves on its own).
    public mutating func move(to camera: LivingTreeCamera, anchor: Anchor?, in framing: LivingTreeFraming) {
        target = camera
        if let anchor {
            let pinned = LivingTreeCamera.pinning(anchor.content, to: anchor.view, zoom: camera.zoom, in: framing).resolvedCenter(in: framing)
            let goal = camera.resolvedCenter(in: framing)
            let s = framing.scales(camera.zoom)
            self.anchor = hypot((pinned.x - goal.x) * s.x, (pinned.y - goal.y) * s.y) < 0.5 ? anchor : nil
        } else { self.anchor = nil }
    }

    /// Advances by `seconds`. Returns true while still moving.
    @discardableResult
    public mutating func step(_ seconds: Double, in framing: LivingTreeFraming) -> Bool {
        guard displayed != target else { return false }
        let a = 1 - exp(-max(0, seconds) / Self.timeConstant)
        let from = log(displayed.zoom), to = log(target.zoom)
        let zoom = exp(from + (to - from) * a)
        let c0 = displayed.resolvedCenter(in: framing), c1 = target.resolvedCenter(in: framing)
        let centre: CGPoint
        if let anchor { centre = LivingTreeCamera.pinning(anchor.content, to: anchor.view, zoom: zoom, in: framing).resolvedCenter(in: framing) }
        else { centre = CGPoint(x: c0.x + (c1.x - c0.x) * CGFloat(a), y: c0.y + (c1.y - c0.y) * CGFloat(a)) }
        let s = framing.scales(target.zoom)
        if abs(log(zoom) - to) < 0.002 && hypot((centre.x - c1.x) * s.x, (centre.y - c1.y) * s.y) < 0.3 {
            displayed = target; anchor = nil
            return false
        }
        displayed = LivingTreeCamera(zoom: zoom, center: centre)
        return true
    }
}

// MARK: Level of detail

public enum LivingTreeDetail {
    /// Deep elements shorter than this on screen are left out until zooming in brings them out: a hairline of a
    /// point or two is noise, not structure. The first two levels are always drawn.
    public static let minimumLength: CGFloat = 3

    public static func isDrawn(_ branch: LivingTreeGeometry.Branch, through transform: LivingTreeTransform = .identity) -> Bool {
        guard branch.depth > 2 else { return true }
        let dx = (branch.end.x - branch.start.x) * transform.scaleX, dy = (branch.end.y - branch.start.y) * transform.scale
        return (dx * dx + dy * dy).squareRoot() >= minimumLength
    }
}

extension LivingTreeGeometry {
    /// This geometry as drawn through `transform` in a view of `viewport` points.
    public func projected(_ transform: LivingTreeTransform, viewport: CGSize) -> LivingTreeGeometry {
        let ws = transform.widthScale
        let mapped = branches.map { b in
            Branch(key: b.key, role: b.role, depth: b.depth, start: transform.apply(b.start), control1: transform.apply(b.control1), control2: transform.apply(b.control2),
                   end: transform.apply(b.end), startWidth: b.startWidth * ws, endWidth: b.endWidth * ws, sizeKnown: b.sizeKnown, glow: b.glow * ws, shade: b.shade)
        }
        return LivingTreeGeometry(size: viewport, base: transform.apply(base), crown: transform.apply(crown), radius: radius * transform.scale,
                                  trunkWidth: trunkWidth * ws, branches: mapped, index: index, ground: ground.map(transform.apply))
    }

    /// Everything drawn: every branch with its width and tip light. Nil for an empty geometry.
    public var extent: CGRect? {
        guard var x0 = branches.first?.start.x else { return nil }
        var x1 = x0, y0 = branches[0].start.y, y1 = y0
        for b in branches {
            let pad = max(b.startWidth, b.endWidth) / 2 + b.glow
            for p in [b.start, b.control1, b.control2, b.end] {
                x0 = min(x0, p.x - pad); x1 = max(x1, p.x + pad); y0 = min(y0, p.y - pad); y1 = max(y1, p.y + pad)
            }
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The fit extent, kept from the previous tree of the same trunk while every edge stays within `deadBand` of the
    /// larger side: small rebuilds then never refit (nothing shifts under an untouched view).
    public static func stableExtent(_ new: CGRect, previous: CGRect?, deadBand: CGFloat = 0.03) -> CGRect {
        guard let previous else { return new }
        let tolerance = deadBand * max(previous.width, previous.height)
        let close = abs(new.minX - previous.minX) <= tolerance && abs(new.maxX - previous.maxX) <= tolerance
            && abs(new.minY - previous.minY) <= tolerance && abs(new.maxY - previous.maxY) <= tolerance
        return close ? previous : new
    }
}

// MARK: Hit testing through a camera

extension LivingTreeHitIndex {
    /// The element under view point `point` when the tree is drawn through `transform`: the tolerance is in view
    /// points (so zooming in makes targets more precise), widths are the drawn widths, and elements left out at this
    /// scale (level of detail) cannot be hit.
    public func hit(_ point: CGPoint, transform: LivingTreeTransform, tolerance: CGFloat = 4) -> LivingTreeKey? {
        nearest(point, transform: transform, tolerance: tolerance, detail: true, tips: true)?.key
    }

    /// The widest drawn element within `radius` view points of `point`, with its drawn width (labels avoid them).
    public func occupant(_ point: CGPoint, transform: LivingTreeTransform, radius: CGFloat) -> (key: LivingTreeKey, width: CGFloat)? {
        nearest(point, transform: transform, tolerance: radius, detail: true, tips: false, widest: true)
    }
}

// MARK: Labels

/// A branch name placed on screen, attached to the element's tip: it moves with the tree while the view pans.
public struct LivingTreeLabel: Equatable, Sendable {
    public let key: LivingTreeKey
    public let title: String
    public let detail: String
    /// The element's tip in layout space.
    public let tip: CGPoint
    /// The label's frame relative to the tip's position on screen.
    public let frame: CGRect
    /// The selection's own label.
    public let emphasized: Bool

    public func rect(_ transform: LivingTreeTransform) -> CGRect {
        let tip = transform.apply(self.tip)
        return frame.offsetBy(dx: tip.x, dy: tip.y)
    }

    /// The element whose drawn label contains `point`; `tips` are the screen positions the labels are drawn at (one
    /// per label). Labels are painted in order over the branches, so the last one containing the point wins.
    public static func hit(_ point: CGPoint, labels: [LivingTreeLabel], tips: [CGPoint]) -> LivingTreeKey? {
        for (label, tip) in zip(labels, tips).reversed() where label.frame.offsetBy(dx: tip.x, dy: tip.y).contains(point) { return label.key }
        return nil
    }
}

/// Places branch names without collisions: important branches first, each beside its own branch where neither
/// other labels nor other branches (forks, thick limbs) are underneath, and more of them as the view zooms in.
public enum LivingTreeLabeler {
    public static let paddingX: CGFloat = 5, paddingY: CGFloat = 2.5, gap: CGFloat = 6

    /// Labels shown at a zoom (relative to the fit).
    public static func budget(zoom: Double) -> Int { min(90, max(12, Int((16 * pow(max(zoom, 0.5), 0.8)).rounded()))) }

    /// Smallest share of the trunk named at a zoom: 1.2% at the fit, a quarter of that at twice the zoom.
    public static func minimumShare(zoom: Double) -> Double { 0.012 / pow(max(1, zoom), 2) }

    /// Most characters of a name shown in a label.
    public static let nameLength = 26

    /// - Parameter share: the element's share of the folder the tree shows, the same ratio its width encodes. Shown
    ///   rounded to a whole percent ("<1%" below one), so the label states proportion without implying precision.
    public static func text(_ element: LivingTreeElement, zoom: Double, share: Double? = nil) -> (title: String, detail: String) {
        // The same formatting as the Atlas and the lens.
        var size = element.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unknown"
        if element.bytes != nil, let share { size += " · " + percent(share) }
        if element.role == .rest { return ("\(element.count.formatted()) grouped items", size) }
        return (atlasMiddleTruncated(element.name, keeping: nameLength), size)
    }

    public static func percent(_ share: Double) -> String {
        let value = min(1, max(0, share)) * 100
        return value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }

    /// - Parameters:
    ///   - geometry: layout-space geometry; `hits`: its hit index.
    ///   - measure: the size of one line of text (`true`: the title line).
    public static func layout(model: LivingTreeModel, geometry: LivingTreeGeometry, hits: LivingTreeHitIndex, transform: LivingTreeTransform, viewport: CGSize,
                              zoom: Double, focus: LivingTreeKey?, measure: (String, Bool) -> CGSize) -> [LivingTreeLabel] {
        guard let trunk = model.trunkBytes, trunk > 0 else { return [] }
        let screen = CGRect(origin: .zero, size: viewport)
        let threshold = minimumShare(zoom: zoom)
        struct Candidate { let branch: LivingTreeGeometry.Branch; let element: LivingTreeElement; let share: Double }
        var candidates = [Candidate]()
        for branch in geometry.branches where branch.depth >= 1 {
            guard let element = model[branch.key], let bytes = element.bytes, branch.sizeKnown else { continue }
            let isFocus = branch.key == focus
            let share = Double(bytes) / Double(trunk)
            let need: Double
            switch element.role {
            case .branch: need = threshold
            case .file: need = threshold * 2
            case .rest: need = zoom >= 2.5 ? threshold * 3 : .infinity
            default: continue
            }
            guard isFocus || share >= need else { continue }
            guard LivingTreeDetail.isDrawn(branch, through: transform) || isFocus else { continue }
            let tip = transform.apply(branch.end)
            guard screen.insetBy(dx: -40, dy: -40).contains(tip) else { continue }
            let start = transform.apply(branch.start)
            guard isFocus || branch.depth == 1 || hypot(tip.x - start.x, tip.y - start.y) >= 18 else { continue }
            candidates.append(Candidate(branch: branch, element: element, share: share))
        }
        candidates.sort { a, b in
            if (a.branch.key == focus) != (b.branch.key == focus) { return a.branch.key == focus }
            return a.share != b.share ? a.share > b.share : a.branch.key < b.branch.key
        }

        let budget = budget(zoom: zoom)
        let bounds = screen.insetBy(dx: 3, dy: 3)
        var placed = [CGRect](), result = [LivingTreeLabel]()
        var labelled = [LivingTreeKey: Int64]()
        for candidate in candidates {
            guard result.count < budget else { break }
            let branch = candidate.branch, element = candidate.element, isFocus = branch.key == focus
            // A folder that is nearly all of its labelled parent (Users › your home) is named once, by the parent.
            if !isFocus, let parent = element.parent, let parentBytes = labelled[parent], Double(element.bytes ?? 0) >= 0.9 * Double(parentBytes) { continue }
            let words = text(element, zoom: zoom, share: candidate.share)
            let a = measure(words.title, true), b = measure(words.detail, false)
            let size = CGSize(width: max(a.width, b.width) + 2 * paddingX, height: a.height + b.height + 2 * paddingY)
            var best: (rect: CGRect, cost: Int)?
            for rect in positions(for: branch, element: element, size: size, transform: transform) {
                guard bounds.contains(rect), !placed.contains(where: { $0.insetBy(dx: -3, dy: -2).intersects(rect) }) else { continue }
                let cost = Self.cost(of: rect, excluding: branch.key, hits: hits, transform: transform)
                if best == nil || cost < best!.cost { best = (rect, cost) }
                if cost == 0 { break }
            }
            guard let chosen = best, isFocus || chosen.cost <= 2 else { continue }
            placed.append(chosen.rect)
            labelled[branch.key] = element.bytes ?? 0
            let tip = transform.apply(branch.end)
            result.append(LivingTreeLabel(key: branch.key, title: words.title, detail: words.detail, tip: branch.end,
                                          frame: chosen.rect.offsetBy(dx: -tip.x, dy: -tip.y), emphasized: isFocus))
        }
        return result
    }

    /// Where a label may go, in order of preference. A folder whose children are drawn forks at its tip, so its name
    /// goes beside the limb, clear of the fork; a twig or file is named just beyond its tip.
    static func positions(for branch: LivingTreeGeometry.Branch, element: LivingTreeElement, size: CGSize, transform: LivingTreeTransform) -> [CGRect] {
        let ws = transform.widthScale
        func place(_ q: CGPoint, toward d: CGVector) -> CGRect {
            if abs(d.dx) >= 0.45 { return CGRect(x: d.dx > 0 ? q.x : q.x - size.width, y: q.y - size.height / 2, width: size.width, height: size.height) }
            return CGRect(x: q.x - size.width / 2, y: d.dy < 0 ? q.y - size.height : q.y, width: size.width, height: size.height)
        }
        let tip = transform.apply(branch.end), d = transform.direction(branch.tangent(at: 1))
        let reach = branch.endWidth * ws / 2 + min(branch.glow * ws, 6) + gap
        let beyond = place(CGPoint(x: tip.x + d.dx * reach, y: tip.y + d.dy * reach), toward: d)
        var sides = [CGRect]()
        for t in [0.6, 0.82] as [CGFloat] {
            let m = transform.apply(branch.point(at: t)), tangent = transform.direction(branch.tangent(at: t))
            let offset = branch.width(at: t) * ws / 2 + gap
            for sign in [1, -1] as [CGFloat] {
                let n = CGVector(dx: -tangent.dy * sign, dy: tangent.dx * sign)
                sides.append(place(CGPoint(x: m.x + n.dx * offset, y: m.y + n.dy * offset), toward: n))
            }
        }
        let beside = [CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0)].map { place(CGPoint(x: tip.x + $0.dx * reach, y: tip.y), toward: $0) }
        return element.expanded ? sides + [beyond] + beside : [beyond] + beside + sides
    }

    /// How much drawn structure a label would cover: sample points over its rect, a thick limb counting three times a
    /// hairline. The labelled element itself does not count.
    static func cost(of rect: CGRect, excluding key: LivingTreeKey, hits: LivingTreeHitIndex, transform: LivingTreeTransform) -> Int {
        let columns = max(3, Int(rect.width / 22) + 1), rows = 3
        var cost = 0
        for i in 0..<columns {
            for j in 0..<rows {
                let p = CGPoint(x: rect.minX + 1 + (rect.width - 2) * CGFloat(i) / CGFloat(columns - 1), y: rect.minY + 1 + (rect.height - 2) * CGFloat(j) / CGFloat(rows - 1))
                guard let occupant = hits.occupant(p, transform: transform, radius: 1.5), occupant.key != key else { continue }
                cost += occupant.width >= 2 ? 3 : 1
            }
        }
        return cost
    }
}

// MARK: Pointer, scroll and pinch

/// Interprets pointer, scroll and pinch input as tree actions. A press that moves more than `dragThreshold` pans
/// and never selects; a click selects on release; a double click opens a folder (the existing subtree navigation)
/// or, on a file or with Option, focuses the camera on the element. Scrolling (wheel, mouse or trackpad) and pinching
/// zoom about the pointer; Shift- or Option-scrolling pans.
public struct LivingTreeGesture: Sendable {
    public enum Action: Equatable, Sendable {
        case select(LivingTreeKey)
        case open(LivingTreeKey)
        case focus(LivingTreeKey)
        case pan(CGVector)
        case zoom(factor: Double, at: CGPoint, animated: Bool)
        /// The trackpad's smart zoom (two-finger double tap): in toward the point, or back to the fit.
        case toggleZoom(at: CGPoint)
        /// 3D: turn the tree (radians of yaw and pitch).
        case orbit(yaw: Double, pitch: Double)
        case dragBegan, dragEnded
    }
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1), option = Modifiers(rawValue: 2), shift = Modifiers(rawValue: 4)
    }

    public static let dragThreshold: CGFloat = 3
    /// Zoom per mouse-wheel line; per trackpad point when Command- or Option-scrolling.
    public static let wheelStep = 1.2, preciseZoomRate = 0.012
    /// 3D: radians of turn per point dragged.
    public static let orbitRate = 0.0085

    private var pressed: CGPoint?
    private var last: CGPoint?
    private var orbiting = false
    public private(set) var isDragging = false

    public init() {}

    /// - Parameters:
    ///   - target: the element under the press; `opens`: whether double-clicking it navigates into it.
    /// - Parameter orbits: 3D: a drag turns the tree (Shift- or Option-drag pans).
    public mutating func down(at point: CGPoint, clickCount: Int, modifiers: Modifiers, target: LivingTreeKey?, orbits: Bool = false, opens: (LivingTreeKey) -> Bool) -> [Action] {
        pressed = point; last = point; isDragging = false
        orbiting = orbits && !modifiers.contains(.shift) && !modifiers.contains(.option)
        guard clickCount >= 2, let target else { return [] }
        return [opens(target) && !modifiers.contains(.option) ? .open(target) : .focus(target)]
    }

    public mutating func dragged(to point: CGPoint) -> [Action] {
        guard let pressed, let last else { return [] }
        var actions = [Action]()
        if !isDragging {
            guard hypot(point.x - pressed.x, point.y - pressed.y) >= Self.dragThreshold else { return [] }
            isDragging = true
            actions.append(.dragBegan)
        }
        let delta = CGVector(dx: point.x - last.x, dy: point.y - last.y)
        actions.append(orbiting ? .orbit(yaw: Double(delta.dx) * Self.orbitRate, pitch: Double(delta.dy) * Self.orbitRate) : .pan(delta))
        self.last = point
        return actions
    }

    public mutating func up(at point: CGPoint, clickCount: Int, target: LivingTreeKey?) -> [Action] {
        defer { pressed = nil; last = nil; isDragging = false }
        if isDragging { return [.dragEnded] }
        guard pressed != nil, clickCount <= 1, let target else { return [] }
        return [.select(target)]
    }

    /// Vertical scrolling zooms about the pointer in 2D and 3D, whatever the device: `precise` cannot tell a trackpad
    /// from a Magic Mouse or a smooth-scrolling wheel, so it only chooses between direct (pixel) and animated (line)
    /// zoom. Scrolling never turns the tree; dragging, the trackpad's rotation and the arrow keys do. Shift- or
    /// Option-scrolling pans, as does a mostly sideways swipe. Momentum after the fingers lift pans but does not zoom.
    /// - Parameters:
    ///   - precise: pixel deltas (trackpad, Magic Mouse, smooth-scrolling mice) rather than mouse-wheel lines.
    ///   - momentum: an inertial event that follows a precise scroll gesture.
    public static func scroll(_ delta: CGVector, precise: Bool, modifiers: Modifiers, at point: CGPoint, momentum: Bool = false) -> Action? {
        guard delta.dx != 0 || delta.dy != 0 else { return nil }
        let pans = modifiers.contains(.shift) || (modifiers.contains(.option) && !modifiers.contains(.command))
        if precise {
            if pans { return .pan(delta) }
            if abs(delta.dx) > abs(delta.dy) { return .pan(CGVector(dx: delta.dx, dy: 0)) }
            return momentum ? nil : .zoom(factor: exp(Double(delta.dy) * preciseZoomRate), at: point, animated: false)
        }
        if delta.dy != 0 && !pans {
            return .zoom(factor: pow(wheelStep, min(3, max(-3, Double(delta.dy)))), at: point, animated: true)
        }
        // Shift with a wheel scrolls sideways (AppKit reports it horizontally).
        return .pan(CGVector(dx: (delta.dx != 0 ? delta.dx : delta.dy) * 16, dy: 0))
    }

    /// The trackpad's two-finger rotation (degrees, counter-clockwise) turns the tree the same way.
    public static func rotate(_ degrees: Double) -> Action? {
        guard degrees != 0, degrees.isFinite else { return nil }
        return .orbit(yaw: -degrees * .pi / 180, pitch: 0)
    }

    public static func magnify(_ magnification: Double, at point: CGPoint) -> Action? {
        guard magnification != 0, magnification.isFinite else { return nil }
        return .zoom(factor: max(0.2, 1 + magnification), at: point, animated: false)
    }
}
