import Foundation
import CoreGraphics

// Living Tree in three dimensions: the same tree (elements, sizes, stable arrangement) grown as a dome around the
// trunk instead of a fan in a plane. Each element's sector from the arranger becomes a range of directions around
// the trunk (azimuth), so sibling subtrees still never share a direction; depth lifts branches outward from the
// vertical. The dome is laid out once per rebuild; each frame it is projected for an orbit (yaw around the trunk,
// pitch above the horizon) onto a picture plane with mild perspective, far branches first and shaded by depth. The
// projection is an ordinary 2D `LivingTreeGeometry`, so drawing, hit testing, labels and the 2D camera (zoom about
// the pointer, pan, limits, focus) apply to it unchanged.

public typealias LivingTreeVector = SIMD3<Double>

/// Which way the tree is shown.
public enum LivingTreeDimension: String, CaseIterable, Sendable {
    case flat, depth
    public var title: String { self == .flat ? "2D" : "3D" }
}

// MARK: Layout

public struct LivingTreeLayout3D: Sendable {
    public struct Branch: Sendable, Equatable {
        public let key: LivingTreeKey
        public let role: LivingTreeElement.Role
        public let depth: Int
        /// A cubic curve in space (y up) from where the element leaves its parent to its tip.
        public let start: LivingTreeVector, control1: LivingTreeVector, control2: LivingTreeVector, end: LivingTreeVector
        public let startWidth: CGFloat, endWidth: CGFloat
        public let sizeKnown: Bool
        public let glow: CGFloat
        /// Direction of the tip around the trunk (radians; 0 is +x, π/2 is toward a viewer at yaw 0).
        public let azimuth: Double

        public func point(at t: Double) -> LivingTreeVector {
            let u = 1 - t
            return u * u * u * start + 3 * u * u * t * control1 + 3 * u * t * t * control2 + t * t * t * end
        }
        public func tangent(at t: Double) -> LivingTreeVector {
            let u = 1 - t
            let d = 3 * u * u * (control1 - start) + 6 * u * t * (control2 - control1) + 3 * t * t * (end - control2)
            let length = max(1e-9, (d * d).sum().squareRoot())
            return d / length
        }
    }

    public let branches: [Branch]
    public let index: [LivingTreeKey: Int]
    /// Where the trunk meets the ground, and the crown's centre at the top of the trunk.
    public let base: LivingTreeVector, crown: LivingTreeVector
    public let radius: Double
    public let trunkWidth: CGFloat
    /// The vertical extent: the projection turns about the trunk at mid-height.
    public let minY: Double, maxY: Double
    public subscript(key: LivingTreeKey) -> Branch? { index[key].map { branches[$0] } }
    public var pivot: LivingTreeVector { LivingTreeVector(0, (minY + maxY) / 2, 0) }
}

public enum LivingTreeGeometer3D {
    /// The crown radius in layout units (comparable to the 2D layout's).
    public static let radius = 620.0
    /// The trunk's height as a fraction of the crown radius.
    public static let trunkHeight = 0.3
    /// Directions from vertical: depth 1 leaves at about 30°, the deepest twigs reach about 60°, so the crown is an
    /// upright vase and fine twigs do not hang below their forks.
    public static func tilt(depth: Int) -> Double { 0.36 + 0.68 * LivingTreeGeometer.ring(depth) }

    public static func layout(_ model: LivingTreeModel, _ arrangement: LivingTreeArrangement) -> LivingTreeLayout3D {
        let R = radius
        let base = LivingTreeVector(0, 0, 0), crown = LivingTreeVector(0, trunkHeight * R, 0)
        let trunkWidth = LivingTreeGeometer.maximumTrunkWidth
        let trunkBytes = model.trunkBytes
        let fan = LivingTreeArranger.fan
        let up = LivingTreeVector(0, 1, 0)
        func normalized(_ v: LivingTreeVector) -> LivingTreeVector { let l = (v * v).sum().squareRoot(); return l > 1e-9 ? v / l : up }

        var branches = [LivingTreeLayout3D.Branch](), index = [LivingTreeKey: Int]()
        branches.reserveCapacity(model.count)
        // The 2D geometer's narrowing of deep sectors (subtrees stay within their ancestors' range), as azimuth.
        let lateral = 1.6
        var angle = [LivingTreeKey: Double](), squeeze = [LivingTreeKey: Double](), lifts = [LivingTreeKey: Double]()
        angle[model.rootKey] = 0; squeeze[model.rootKey] = 1; lifts[model.rootKey] = 0
        var minY = 0.0, maxY = crown.y

        for key in model.order {
            let element = model[key]!
            guard let placement = arrangement.placements[key] else { continue }
            if element.role == .trunk {
                let lean = LivingTreeVector((key.noise(7) - 0.5) * R * 0.05, 0, (key.noise(8) - 0.5) * R * 0.05)
                let height = crown.y - base.y
                let trunk = LivingTreeLayout3D.Branch(key: key, role: .trunk, depth: 0, start: base,
                                                      control1: base + LivingTreeVector(0, height * 0.38, 0) + lean, control2: crown - LivingTreeVector(0, height * 0.36, 0) - lean, end: crown,
                                                      startWidth: element.sizeKnown ? trunkWidth * 1.35 : LivingTreeGeometer.minimumWidth * 2,
                                                      endWidth: element.sizeKnown ? trunkWidth * 0.9 : LivingTreeGeometer.minimumWidth * 2,
                                                      sizeKnown: element.sizeKnown, glow: element.children.isEmpty ? 6 : 0, azimuth: .pi / 2)
                index[key] = branches.count; branches.append(trunk)
                continue
            }
            guard let parentKey = element.parent, let parentIndex = index[parentKey], let parentPlacement = arrangement.placements[parentKey],
                  let parentAngle = angle[parentKey], let parentSqueeze = squeeze[parentKey], let parentTilt = lifts[parentKey] else { continue }
            let parent = branches[parentIndex]
            let ownAngle = parentAngle + (placement.angle - parentPlacement.angle) * parentSqueeze
            angle[key] = ownAngle
            if !element.children.isEmpty {
                let half = max(1e-6, (placement.upper - placement.lower) / 2)
                let band = LivingTreeGeometer.ring(element.depth + 1) - LivingTreeGeometer.ring(element.depth)
                let middle = (LivingTreeGeometer.ring(element.depth + 1) + LivingTreeGeometer.ring(element.depth)) / 2
                squeeze[key] = min(parentSqueeze, min(1, lateral * band / (middle * half)))
            }
            // Around the trunk: the fan's ±79° becomes almost a full turn.
            let azimuth = ownAngle / fan * .pi * 0.97
            // Up and out: heavy children keep close to their parent's lift (Users › home continues upward).
            // The arranger's smoothed share: a small measured change does not move the branch.
            let share = placement.share
            var lift = parentTilt + (tilt(depth: element.depth) - parentTilt) * (1 - 0.55 * min(1, max(0, share)))
            lift = min(1.5, max(0.05, lift + (key.noise(9) - 0.5) * 0.16))
            lifts[key] = lift
            let direction = LivingTreeVector(sin(lift) * cos(azimuth), cos(lift), sin(lift) * sin(azimuth))
            let t = placement.stagger
            let start = parent.point(at: t)
            let inner = LivingTreeGeometer.ring(element.depth - 1), outer = LivingTreeGeometer.ring(element.depth)
            let rho = (inner + (outer - inner) * placement.reach) * R
            let end = crown + direction * rho
            let chord = end - start
            let length = max(1, (chord * chord).sum().squareRoot())
            let along = chord / length
            let leave = normalized(0.4 * parent.tangent(at: t) + 0.6 * along)
            let outward = element.depth <= 2 ? 0.5 : 0.15
            let arrive = normalized(outward * direction + (1 - outward) * along)
            var normal = LivingTreeVector(along.y * up.z - along.z * up.y, along.z * up.x - along.x * up.z, along.x * up.y - along.y * up.x)
            normal = (normal * normal).sum() < 1e-12 ? LivingTreeVector(1, 0, 0) : normalized(normal)
            let bend = placement.bend * (element.depth <= 2 ? 0.06 : 0.03) * length
            let control1 = start + leave * (0.36 * length) + normal * bend
            let control2 = end - arrive * (0.32 * length) + normal * bend

            let width = LivingTreeGeometer.width(bytes: element.bytes, trunkBytes: trunkBytes, trunkWidth: trunkWidth)
            let startWidth = width ?? LivingTreeGeometer.minimumWidth
            let forks = !element.children.isEmpty
            let endWidth = forks ? startWidth * 0.8 : max(LivingTreeGeometer.minimumWidth * 0.5, startWidth * 0.36)
            var glow: CGFloat = 0
            if !forks {
                if let bytes = element.bytes, let trunk = trunkBytes, trunk > 0 {
                    glow = min(7, 1.4 + 5.5 * CGFloat(pow(min(1, max(0, Double(bytes) / Double(trunk))), 0.35)))
                } else { glow = 1.2 }
            }
            minY = min(minY, end.y, control1.y, control2.y); maxY = max(maxY, end.y, control1.y, control2.y)
            index[key] = branches.count
            branches.append(LivingTreeLayout3D.Branch(key: key, role: element.role, depth: element.depth, start: start, control1: control1, control2: control2, end: end,
                                                      startWidth: startWidth, endWidth: endWidth, sizeKnown: width != nil, glow: glow, azimuth: azimuth))
        }
        return LivingTreeLayout3D(branches: branches, index: index, base: base, crown: crown, radius: R, trunkWidth: trunkWidth, minY: minY, maxY: maxY)
    }
}

// MARK: Orbit and projection

/// The viewing direction: `yaw` turns the tree about its trunk, `pitch` raises the eye above the horizon.
public struct LivingTreeOrbit: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public init(yaw: Double, pitch: Double) { self.yaw = Self.wrap(yaw); self.pitch = min(Self.pitchRange.upperBound, max(Self.pitchRange.lowerBound, pitch)) }

    /// A three-quarter view from a little above.
    public static let standard = LivingTreeOrbit(yaw: 0.45, pitch: 0.24)
    /// From slightly below the horizon to nearly straight down.
    public static let pitchRange: ClosedRange<Double> = -0.2...1.35

    public static func wrap(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi } else if a <= -.pi { a += 2 * .pi }
        return a
    }

    public func rotated(yaw: Double, pitch: Double) -> LivingTreeOrbit { LivingTreeOrbit(yaw: self.yaw + yaw, pitch: self.pitch + pitch) }

    /// The yaw that turns a direction around the trunk toward the viewer.
    public static func yaw(facing azimuth: Double) -> Double { wrap(.pi / 2 - azimuth) }

    /// The yaw that shows a direction around the trunk in profile: pointing to the left or right of the view
    /// (whichever is the smaller turn from `current`), angled 20° toward the viewer, so a focused branch and what
    /// grows from it are seen side-on rather than foreshortened.
    public static func yaw(profile azimuth: Double, from current: Double) -> Double {
        let lean = 0.35
        let right = wrap(lean - azimuth), left = wrap(.pi - lean - azimuth)
        return abs(wrap(right - current)) <= abs(wrap(left - current)) ? right : left
    }

    /// Shortest-way interpolation (yaw never spins the long way round).
    public func interpolated(to other: LivingTreeOrbit, _ a: Double) -> LivingTreeOrbit {
        LivingTreeOrbit(yaw: yaw + Self.wrap(other.yaw - yaw) * a, pitch: pitch + (other.pitch - pitch) * a)
    }
}

public enum LivingTreeProjection {
    /// The eye's distance from the pivot, in crown radii: mild perspective (the near side of the crown is drawn about
    /// a third larger than the far side, which makes turning read as depth).
    public static let distance = 3.0
    /// Far branches are drawn this much dimmer than near ones.
    public static let depthShade = 0.4

    /// A point in the picture plane (layout units, y down, the pivot at the origin), its depth toward the viewer, and
    /// its perspective scale.
    public static func project(_ p: LivingTreeVector, orbit: LivingTreeOrbit, pivot: LivingTreeVector, radius: Double) -> (point: CGPoint, depth: Double, scale: Double) {
        let q = p - pivot
        let cy = cos(orbit.yaw), sy = sin(orbit.yaw)
        let x = q.x * cy - q.z * sy, z = q.x * sy + q.z * cy, y = q.y
        let cp = cos(orbit.pitch), sp = sin(orbit.pitch)
        let up = y * cp - z * sp, depth = y * sp + z * cp
        let d = distance * radius
        let f = d / max(d * 0.2, d - depth)
        return (CGPoint(x: x * f, y: -up * f), depth, f)
    }

    /// The tree as seen from `orbit`: a 2D geometry in the picture plane, far branches first, each shaded by depth.
    public static func geometry(_ layout: LivingTreeLayout3D, orbit: LivingTreeOrbit) -> LivingTreeGeometry {
        let pivot = layout.pivot, R = layout.radius
        var drawn = [(branch: LivingTreeGeometry.Branch, depth: Double, order: Int)]()
        drawn.reserveCapacity(layout.branches.count)
        for (order, b) in layout.branches.enumerated() {
            let s = project(b.start, orbit: orbit, pivot: pivot, radius: R), c1 = project(b.control1, orbit: orbit, pivot: pivot, radius: R)
            let c2 = project(b.control2, orbit: orbit, pivot: pivot, radius: R), e = project(b.end, orbit: orbit, pivot: pivot, radius: R)
            let depth = (s.depth + e.depth) / 2
            let shade = CGFloat(1 - depthShade * (1 - min(1, max(0, (depth / R + 1) / 2))))
            drawn.append((LivingTreeGeometry.Branch(key: b.key, role: b.role, depth: b.depth, start: s.point, control1: c1.point, control2: c2.point, end: e.point,
                                                    startWidth: b.startWidth * CGFloat(s.scale), endWidth: b.endWidth * CGFloat(e.scale), sizeKnown: b.sizeKnown,
                                                    glow: b.glow * CGFloat(e.scale), shade: shade), depth, order))
        }
        drawn.sort { $0.depth != $1.depth ? $0.depth < $1.depth : $0.order < $1.order }
        var index = [LivingTreeKey: Int]()
        for (i, item) in drawn.enumerated() { index[item.branch.key] = i }
        let base = project(layout.base, orbit: orbit, pivot: pivot, radius: R).point, crown = project(layout.crown, orbit: orbit, pivot: pivot, radius: R).point
        let branches = drawn.map(\.branch)
        let size = CGSize(width: 2 * R, height: 2 * R)
        let ring = (0..<48).map { i -> CGPoint in
            let a = Double(i) / 48 * 2 * .pi
            return project(layout.base + LivingTreeVector(cos(a) * R * 0.6, 0, sin(a) * R * 0.6), orbit: orbit, pivot: pivot, radius: R).point
        }
        return LivingTreeGeometry(size: size, base: base, crown: crown, radius: CGFloat(R), trunkWidth: layout.trunkWidth, branches: branches, index: index, ground: ring)
    }

    /// What the fit frames at a pitch: the union of the tree's projected extent over a full turn of yaw, so the fit
    /// (and the zoom) does not change while orbiting and the tree is never clipped at any yaw.
    public static func extent(_ layout: LivingTreeLayout3D, pitch: Double, samples: Int = 16) -> CGRect {
        let pivot = layout.pivot, R = layout.radius
        var x0 = Double.infinity, x1 = -Double.infinity, y0 = Double.infinity, y1 = -Double.infinity
        for i in 0..<samples {
            let orbit = LivingTreeOrbit(yaw: Double(i) / Double(samples) * 2 * .pi, pitch: pitch)
            for b in layout.branches {
                let pad = Double(max(b.startWidth, b.endWidth)) / 2 + Double(b.glow)
                for p in [b.start, b.end, b.control1, b.control2] {
                    let q = project(p, orbit: orbit, pivot: pivot, radius: R)
                    let r = pad * q.scale
                    x0 = min(x0, q.point.x - r); x1 = max(x1, q.point.x + r); y0 = min(y0, q.point.y - r); y1 = max(y1, q.point.y + r)
                }
            }
        }
        guard x0.isFinite else { return CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R) }
        // The extent between yaw samples can exceed the samples slightly: a little room.
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -0.01 * R, dy: -0.01 * R)
    }
}

/// Smoothed orbit movement (keys, focus); dragging and Reduce Motion jump. Same time constant as the camera.
public struct LivingTreeOrbitMotion: Equatable, Sendable {
    public private(set) var displayed: LivingTreeOrbit
    public private(set) var target: LivingTreeOrbit
    public init(_ orbit: LivingTreeOrbit = .standard) { displayed = orbit; target = orbit }
    public var isMoving: Bool { displayed != target }
    public mutating func jump(to orbit: LivingTreeOrbit) { displayed = orbit; target = orbit }
    public mutating func move(to orbit: LivingTreeOrbit) { target = orbit }
    @discardableResult
    public mutating func step(_ seconds: Double) -> Bool {
        guard displayed != target else { return false }
        let a = 1 - exp(-max(0, seconds) / LivingTreeCameraMotion.timeConstant)
        let next = displayed.interpolated(to: target, a)
        if abs(LivingTreeOrbit.wrap(target.yaw - next.yaw)) < 0.0005 && abs(target.pitch - next.pitch) < 0.0005 { displayed = target; return false }
        displayed = next
        return true
    }
}
