import SwiftUI
import AppKit

/// Owns the Living Tree of the explorer's current folder: builds it from one catalog snapshot, keeps it stable
/// across updates (per-trunk layout memory), rebuilds only when committed changes touch what is drawn, and turns
/// verified size signals into brief illumination. Bounded: one tree (about 3,000 elements), one previous tree for
/// transitions, layout memories and camera positions for the last few trunks, and at most
/// `LivingTreeIllumination.capacity` glows.
///
/// The camera: every tree is laid out (off the main thread) in one fixed layout space, so a camera position names
/// the same place in the tree through window resizes and incremental rebuilds. The view frames the tree's actual
/// extent; zoom is relative to that fit. Animated moves are stepped by a timer that runs only while the camera moves.
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

    /// The tree shown before the latest one, for the transition between trunks: its layout and how it was viewed.
    private(set) var previousModel: LivingTreeModel?
    private(set) var previousGeometry: LivingTreeGeometry?
    private(set) var previousTransform: LivingTreeTransform?
    /// The current tree in layout space, built with it: flat, and as a dome for 3D.
    private var laidOut: (revision: Int, geometry: LivingTreeGeometry, hits: LivingTreeHitIndex)?
    private var dome: (revision: Int, layout: LivingTreeLayout3D)?
    /// Color by type for the current tree (computed with it).
    private var colors: (revision: Int, coloring: LivingTreeColoring)?
    /// Everything outside the selection's subtree recedes (2D and 3D).
    @Published var isolating = false
    /// 3D: the dome projected for the displayed orbit, its hit index (built on demand) and the fit extent for a pitch.
    private var plane: (revision: Int, orbit: LivingTreeOrbit, geometry: LivingTreeGeometry)?
    private var planeHits: (revision: Int, orbit: LivingTreeOrbit, hits: LivingTreeHitIndex)?
    private var domeExtent: (revision: Int, trunk: Int64, pitch: Int, rect: CGRect)?
    private var projection: (revision: Int, dimension: LivingTreeDimension, orbit: LivingTreeOrbit, size: CGSize, transform: LivingTreeTransform, geometry: LivingTreeGeometry)?
    private var labelCache: (key: LabelKey, labels: [LivingTreeLabel])?

    // MARK: Camera state

    /// 2D or 3D (the view supplies the remembered choice).
    @Published private(set) var dimension = LivingTreeDimension.flat
    /// 3D: the viewing direction as displayed (moving toward `orbitMotion.target` during an animated turn).
    @Published private(set) var orbit = LivingTreeOrbit.standard
    private var orbitMotion = LivingTreeOrbitMotion()
    /// 3D: true while the tree is being turned by hand (labels then follow their tips and are placed again shortly
    /// after the turning stops).
    @Published private(set) var turning = false
    private var turningSettle: Task<Void, Never>?
    /// The camera as displayed (moving toward `motion.target` during an animated move).
    @Published private(set) var camera = LivingTreeCamera.fit
    private var motion = LivingTreeCameraMotion()
    private var motionTimer: Timer?
    private var lastStep = Date()
    /// Where the view was in recently shown trunks (per dimension): returning to a folder shows it as you left it.
    private var cameras = [Int64: LivingTreeCamera]()
    private var cameraOrder = InventoryRecency(capacity: 6)
    /// The extent the fit frames, kept through small rebuilds of the same trunk.
    private(set) var extent: CGRect?
    /// The canvas size and Reduce Motion, supplied by the view.
    var viewport = CGSize.zero
    /// The canvas size the tree was last drawn at (offscreen renders read it back).
    private(set) var lastCanvasSize: CGSize?
    var reduceMotion = false
    /// A revealed search result to frame once it is drawn, and the last reveal framed (a reveal is framed once).
    private var pendingFocus: Int64?
    private var focusedReveal: Int?

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
    private var throttle: Task<Void, Never>?
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

    /// Draws `node` on its own even when it is small (a search result revealed in its folder) and, for a new reveal
    /// request (`serial`), frames it once it is drawn.
    func reveal(_ node: Int64, serial: Int? = nil) {
        if let serial, serial != focusedReveal { focusedReveal = serial; pendingFocus = node }
        guard model?[.node(node)] == nil else { applyPendingFocus(); return }
        reveal = node
        rebuild()
    }

    private func applyPendingFocus() {
        guard let node = pendingFocus, model?[.node(node)] != nil else { return }
        pendingFocus = nil
        focus(on: .node(node), animated: true)
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
            // Coalesce rapid updates of the same folder. The wait is not a build: opening another folder meanwhile
            // cancels it and reads at once instead of queueing behind it.
            guard throttle == nil else { return }
            statistics.throttledRebuilds += 1
            throttle = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.throttle = nil
                self.rebuild()
            }
            return
        }
        throttle?.cancel(); throttle = nil
        building = true; buildPending = false; lastBuild = Date()
        let reader = reader, budget = budget, memory = memories[trunk] ?? LivingTreeMemory(), reveal = reveal
        Task {
            defer { building = false; if buildPending { buildPending = false; rebuild() } }
            do {
                let started = Date()
                let built = try await PerformanceTrace.measure("livingTree.read", "\(trunk)") { try await reader.livingTree(rootID: trunk, budget: budget, memory: memory, reveal: reveal) }
                guard trunk == self.trunk else { return }
                // Arrangement, layout-space geometry and hit index, off the main thread.
                let (arrangement, remembered, geometry, hits, dome, coloring) = await PerformanceTrace.measure("livingTree.layout") { await Task.detached(priority: .userInitiated) { () -> (LivingTreeArrangement, LivingTreeMemory, LivingTreeGeometry, LivingTreeHitIndex, LivingTreeLayout3D, LivingTreeColoring) in
                    var memory = memory
                    let arrangement = LivingTreeArranger.arrange(built, memory: &memory)
                    let geometry = LivingTreeGeometer.layout(built, arrangement, in: LivingTreeCamera.layoutSize)
                    return (arrangement, memory, geometry, LivingTreeHitIndex(geometry), LivingTreeGeometer3D.layout(built, arrangement), LivingTreeColoring.compute(built))
                }.value }
                guard trunk == self.trunk else { return }
                memories[trunk] = remembered
                for dropped in memoryOrder.use(trunk) { memories[dropped] = nil }
                let trunkChanged = model?.root.id != built.root.id
                if let current = model, trunkChanged {
                    previousModel = current; previousGeometry = planeGeometry(); previousTransform = transform(for: viewport)
                    // Remember where the view was in the tree being left.
                    let left = cameraKey(current.root.id)
                    cameras[left] = motion.target
                    for dropped in cameraOrder.use(left) { cameras[dropped] = nil }
                }
                // What the viewer is looking at, so it stays in place on screen through the rebuild.
                let held = trunkChanged ? nil : heldView()
                let fresh = geometry.extent ?? CGRect(origin: .zero, size: LivingTreeCamera.layoutSize)
                extent = trunkChanged ? fresh : LivingTreeGeometry.stableExtent(fresh, previous: extent)
                if trunkChanged {
                    // A trunk shown before returns as it was left; a new one starts fitted.
                    stopMotion()
                    let restored = cameras[cameraKey(built.root.id)] ?? .fit
                    motion.jump(to: restored); camera = restored
                }
                // The change feed continues from the moment this tree was read.
                if let journal = built.journalCursor { changeCursor = journal }
                laidOut = (revision + 1, geometry, hits)
                self.dome = (revision + 1, dome)
                colors = (revision + 1, coloring)
                model = built; self.arrangement = arrangement; revision += 1; phase = .ready
                if !trunkChanged, !camera.isFit, let framing = framing(for: viewport) {
                    // A rebuild can shift branches slightly (sector room follows what is drawn); a shift shared by what is
                    // on screen is undone, so a zoomed-in view does not drift.
                    var target = motion.target
                    if let held, let shift = heldShift(held, framing: framing), hypot(shift.dx, shift.dy) >= 0.25 {
                        target = target.panned(by: CGVector(dx: -shift.dx, dy: -shift.dy), in: framing)
                        statistics.viewsHeld += 1
                    }
                    target = target.clamped(in: framing)
                    if target != motion.target { setCamera(target, animated: false) }
                }
                applyPendingFocus()
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

    /// The current tree as the camera sees it before zoom and pan, with its hit index: the flat layout in 2D, the dome
    /// projected for the displayed orbit in 3D (its hit index is built on first use for that orbit).
    func layout() -> (geometry: LivingTreeGeometry, hits: LivingTreeHitIndex)? {
        guard model != nil else { return nil }
        switch dimension {
        case .flat:
            guard let laidOut, laidOut.revision == revision else { return nil }
            return (laidOut.geometry, laidOut.hits)
        case .depth:
            guard let geometry = planeGeometry() else { return nil }
            if let planeHits, planeHits.revision == revision, planeHits.orbit == orbit { return (geometry, planeHits.hits) }
            let hits = LivingTreeHitIndex(geometry)
            planeHits = (revision, orbit, hits)
            return (geometry, hits)
        }
    }

    /// Where the tips on screen are in a moved view (at most 400, nearest the centre first); nil for an untouched view
    /// or while the camera moves.
    private func heldView() -> [(key: LivingTreeKey, view: CGPoint)]? {
        guard !motion.target.isFit, !isMoving, !turning, let framing = framing(for: viewport), let plane = planeGeometry() else { return nil }
        let transform = camera.transform(in: framing), centre = framing.anchor
        let screen = CGRect(origin: .zero, size: viewport)
        let tips = plane.branches.filter { $0.depth >= 1 }.map { ($0.key, transform.apply($0.end)) }.filter { screen.contains($0.1) }
            .sorted { hypot($0.1.x - centre.x, $0.1.y - centre.y) < hypot($1.1.x - centre.x, $1.1.y - centre.y) }
        return tips.isEmpty ? nil : Array(tips.prefix(400))
    }

    /// The typical shift of the held tips after a rebuild: the median of their movements on screen, so the few
    /// elements that really changed (a relisted folder re-shapes) do not move the view, while a shift of everything
    /// (sectors nudged by a sibling's change) is undone.
    private func heldShift(_ held: [(key: LivingTreeKey, view: CGPoint)], framing: LivingTreeFraming) -> CGVector? {
        guard let plane = planeGeometry() else { return nil }
        let transform = motion.target.transform(in: framing)
        var dx = [CGFloat](), dy = [CGFloat]()
        for (key, before) in held {
            guard let tip = plane[key]?.end else { continue }
            let now = transform.apply(tip)
            dx.append(now.x - before.x); dy.append(now.y - before.y)
        }
        guard dx.count >= 3 else { return nil }
        dx.sort(); dy.sort()
        return CGVector(dx: dx[dx.count / 2], dy: dy[dy.count / 2])
    }

    /// The current tree as the camera sees it before zoom and pan (no hit index).
    func planeGeometry() -> LivingTreeGeometry? { planeGeometry(for: orbit) }

    private func planeGeometry(for orbit: LivingTreeOrbit) -> LivingTreeGeometry? {
        guard model != nil else { return nil }
        switch dimension {
        case .flat:
            guard let laidOut, laidOut.revision == revision else { return nil }
            return laidOut.geometry
        case .depth:
            guard let dome, dome.revision == revision else { return nil }
            if let plane, plane.revision == revision, plane.orbit == orbit { return plane.geometry }
            let geometry = LivingTreeProjection.geometry(dome.layout, orbit: orbit)
            if orbit == self.orbit { plane = (revision, orbit, geometry) }
            return geometry
        }
    }

    /// Color by type for the current tree.
    var coloring: LivingTreeColoring { colors.flatMap { $0.revision == revision ? $0.coloring : nil } ?? .empty }

    /// The 3D layout of the current tree (for measurements and tests).
    var domeLayout: LivingTreeLayout3D? { dome.flatMap { $0.revision == revision ? $0.layout : nil } }

    /// What the fit frames: the flat tree's extent, or the dome's extent over a full turn at this pitch (so orbiting
    /// never changes the zoom). Both are kept through small rebuilds of the same trunk.
    private func fitExtent(pitch: Double) -> CGRect? {
        switch dimension {
        case .flat: return extent
        case .depth:
            guard let dome, dome.revision == revision, let trunk else { return nil }
            let step = Int((pitch / 0.02).rounded())
            if let domeExtent, domeExtent.revision == revision, domeExtent.pitch == step, domeExtent.trunk == trunk { return domeExtent.rect }
            var rect = LivingTreeProjection.extent(dome.layout, pitch: Double(step) * 0.02)
            if let domeExtent, domeExtent.trunk == trunk, domeExtent.pitch == step { rect = LivingTreeGeometry.stableExtent(rect, previous: domeExtent.rect) }
            domeExtent = (revision, trunk, step, rect)
            return rect
        }
    }

    private func cameraKey(_ trunk: Int64) -> Int64 { trunk &* 2 &+ (dimension == .depth ? 1 : 0) }

    // MARK: Camera

    /// How the current tree fits a canvas of `size`.
    func framing(for size: CGSize) -> LivingTreeFraming? { framing(for: size, orbit: orbit) }

    private func framing(for size: CGSize, orbit: LivingTreeOrbit) -> LivingTreeFraming? {
        guard size.width > 1, size.height > 1, let bounds = fitExtent(pitch: orbit.pitch), let geometry = planeGeometry(for: orbit) else { return nil }
        return LivingTreeFraming(viewport: size, bounds: bounds, axis: geometry.base.x)
    }

    func transform(for size: CGSize) -> LivingTreeTransform? { framing(for: size).map { camera.transform(in: $0) } }

    /// The tree as drawn on a canvas of `size` through the displayed camera (cached for the latest camera).
    func projected(for size: CGSize) -> (geometry: LivingTreeGeometry, transform: LivingTreeTransform)? {
        lastCanvasSize = size
        guard let plane = planeGeometry(), let transform = transform(for: size) else { return nil }
        if let projection, projection.revision == revision, projection.dimension == dimension, projection.orbit == orbit, projection.size == size, projection.transform == transform {
            return (projection.geometry, transform)
        }
        let geometry = plane.projected(transform, viewport: size)
        projection = (revision, dimension, orbit, size, transform, geometry)
        return (geometry, transform)
    }

    /// The hit index for the displayed view (3D: built on first use after the orbit changes).
    func hitIndex() -> LivingTreeHitIndex? { layout()?.hits }

    // MARK: 2D / 3D and orbit

    /// Shows the tree flat or as a dome. Each keeps its own camera per folder; switching starts fitted the first time.
    func setDimension(_ value: LivingTreeDimension) {
        guard value != dimension else { return }
        if let trunk { cameras[cameraKey(trunk)] = motion.target; for dropped in cameraOrder.use(cameraKey(trunk)) { cameras[dropped] = nil } }
        stopMotion(); orbitMotion.jump(to: orbitMotion.target); orbit = orbitMotion.target
        dimension = value
        let restored = trunk.flatMap { cameras[cameraKey($0)] } ?? .fit
        motion.jump(to: restored); camera = restored
        labelCache = nil
    }

    /// Turns the tree (3D). Dragging turns directly; keys turn smoothly unless Reduce Motion is on. The zoom and the
    /// point at the centre of the view are kept.
    func turn(yaw: Double, pitch: Double, animated: Bool) {
        guard dimension == .depth else { return }
        if pivot == nil { capturePivot() }
        if !animated {
            if !turning { turning = true; turnSamples.removeAll() }
            turnSamples.append((Date(), yaw, pitch))
            if turnSamples.count > 12 { turnSamples.removeFirst(turnSamples.count - 12) }
            turningSettle?.cancel()
            turningSettle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                self.turning = false
                if !self.orbitMotion.isMoving { self.pivot = nil }
            }
        }
        setOrbit(orbitMotion.target.rotated(yaw: yaw, pitch: pitch), animated: animated)
        if !animated { applyPivot() }
    }

    /// The element the view orbits around: kept where it is on screen while the tree turns, so whatever you
    /// zoomed in on stays in view. The selection when it is on screen, otherwise the element nearest the centre.
    /// At the fit there is no pivot (the tree turns about its trunk).
    private var pivot: (point: LivingTreeVector, view: CGPoint)?
    /// Preferred pivot (the view's selection).
    var pivotPreference: LivingTreeKey?
    private var turnSamples = [(time: Date, yaw: Double, pitch: Double)]()

    private func capturePivot() {
        pivot = nil
        guard dimension == .depth, !motion.target.isFit, let framing = framing(for: viewport), let plane = planeGeometry(), let dome = domeLayout else { return }
        let transform = camera.transform(in: framing)
        let screen = CGRect(origin: .zero, size: viewport).insetBy(dx: 8, dy: 8)
        var chosen: LivingTreeKey?
        if let preferred = pivotPreference, let branch = plane[preferred], screen.contains(transform.apply(branch.end)) { chosen = preferred }
        if chosen == nil {
            var best = CGFloat.infinity
            for branch in plane.branches where branch.depth >= 1 {
                let p = transform.apply(branch.end)
                guard screen.contains(p) else { continue }
                let d = hypot(p.x - framing.anchor.x, p.y - framing.anchor.y)
                if d < best { best = d; chosen = branch.key }
            }
        }
        guard let key = chosen, let point = dome[key]?.end, let view = plane[key].map({ transform.apply($0.end) }) else { return }
        pivot = (point, view)
    }

    /// Re-centres the camera so the pivot stays where it was on screen for the displayed orbit.
    private func applyPivot() {
        guard let pivot, let dome = domeLayout, let framing = framing(for: viewport) else { return }
        let projected = LivingTreeProjection.project(pivot.point, orbit: orbit, pivot: dome.pivot, radius: dome.radius).point
        let target = LivingTreeCamera.pinning(projected, to: pivot.view, zoom: motion.target.zoom, in: framing).clamped(in: framing)
        motion.jump(to: target)
        if camera != target { camera = target }
    }

    /// A drag that ended while moving keeps turning briefly and slows down (not with Reduce Motion).
    func endTurn() {
        guard dimension == .depth, !reduceMotion else { turnSamples.removeAll(); return }
        let recent = turnSamples.filter { Date().timeIntervalSince($0.time) < 0.08 }
        turnSamples.removeAll()
        guard recent.count >= 2, let first = recent.first, let last = recent.last else { return }
        let span = max(0.016, last.time.timeIntervalSince(first.time))
        let yaw = recent.dropFirst().reduce(0) { $0 + $1.yaw } / span, pitch = recent.dropFirst().reduce(0) { $0 + $1.pitch } / span
        guard abs(yaw) + abs(pitch) > 0.6 else { return }
        // Glide about a quarter of a second's worth of the release speed, easing out.
        if pivot == nil { capturePivot() }
        setOrbit(orbitMotion.target.rotated(yaw: yaw * 0.22, pitch: pitch * 0.22), animated: true)
    }

    func setOrbit(_ target: LivingTreeOrbit, animated: Bool) {
        if animated && !reduceMotion {
            orbitMotion.move(to: target)
            if orbitMotion.isMoving { startMotion() }
        } else {
            orbitMotion.jump(to: target)
            if orbit != target { orbit = target }
            if !motion.isMoving { stopMotion() }
        }
    }

    /// Where the orbit is heading.
    var orbitTarget: LivingTreeOrbit { orbitMotion.target }

    /// Whether an animated camera move is in progress.
    var isMoving: Bool { motionTimer != nil }
    /// Trunks whose camera is remembered (bounded).
    var rememberedCameraCount: Int { cameras.count }
    /// Where the camera is heading (the displayed camera when nothing moves).
    var cameraTarget: LivingTreeCamera { motion.target }

    /// Moves the camera. Animated moves are smoothed unless Reduce Motion is on; direct manipulation jumps.
    func setCamera(_ target: LivingTreeCamera, animated: Bool, anchor: LivingTreeCameraMotion.Anchor? = nil) {
        guard animated, !reduceMotion, let framing = framing(for: viewport) else {
            stopMotion(); motion.jump(to: target)
            if camera != target { camera = target }
            return
        }
        motion.move(to: target, anchor: anchor, in: framing)
        if motion.isMoving { startMotion() } else { stopMotion() }
    }

    /// Zooms by `factor` about a canvas point (the centre of the framed area when nil). What is under the point
    /// stays under it. Successive animated steps accumulate from where the camera is heading.
    func zoom(by factor: Double, at point: CGPoint?, animated: Bool) {
        guard let framing = framing(for: viewport) else { return }
        pivot = nil
        let point = point ?? framing.anchor
        let content = camera.transform(in: framing).invert(point)
        let zoom = LivingTreeCamera.clampZoom((animated ? motion.target : camera).zoom * factor)
        let target = LivingTreeCamera.pinning(content, to: point, zoom: zoom, in: framing).clamped(in: framing)
        setCamera(target, animated: animated, anchor: LivingTreeCameraMotion.Anchor(view: point, content: content))
    }

    /// Moves the tree by `delta` canvas points (a drag or trackpad scroll): immediate.
    func pan(by delta: CGVector) {
        guard let framing = framing(for: viewport) else { return }
        pivot = nil
        setCamera(camera.panned(by: delta, in: framing), animated: false)
    }

    /// Keyboard panning: a fraction of the canvas, animated.
    func pan(byFraction fraction: CGVector) {
        guard let framing = framing(for: viewport) else { return }
        let delta = CGVector(dx: fraction.dx * viewport.width, dy: fraction.dy * viewport.height)
        setCamera(motion.target.panned(by: delta, in: framing), animated: true)
    }

    /// Frames the whole tree.
    func fitTree(animated: Bool = true) { setCamera(.fit, animated: animated) }

    /// Frames the whole tree, returns 3D to its standard orientation, and forgets the remembered views of other
    /// folders (each is shown fitted next time).
    func resetView() {
        cameras.removeAll(); cameraOrder = InventoryRecency(capacity: 6)
        if dimension == .depth { setOrbit(.standard, animated: true) }
        fitTree()
    }

    /// The trackpad's smart zoom: in toward the point, or back to the fit when zoomed in.
    func toggleZoom(at point: CGPoint) {
        if motion.target.zoom > 1.05 { fitTree() } else { zoom(by: 2.5, at: point, animated: true) }
    }

    /// Frames an element and what is drawn beneath it. In 3D the tree also turns so the element is seen side-on.
    func focus(on key: LivingTreeKey, animated: Bool = true) {
        pivot = nil
        if dimension == .depth, let branch = domeLayout?[key], key != model?.rootKey {
            let facing = LivingTreeOrbit(yaw: LivingTreeOrbit.yaw(profile: branch.azimuth, from: orbitMotion.target.yaw), pitch: orbitMotion.target.pitch)
            guard let framing = framing(for: viewport, orbit: facing), let rect = focusRect(key, orbit: facing) else { return }
            setOrbit(facing, animated: animated)
            setCamera(LivingTreeCamera.focusing(on: rect, in: framing), animated: animated)
            return
        }
        guard let framing = framing(for: viewport), let rect = focusRect(key) else { return }
        setCamera(LivingTreeCamera.focusing(on: rect, in: framing), animated: animated)
    }

    /// Brings an element on screen with the smallest move (nothing moves when it is already visible).
    func bringIntoView(_ key: LivingTreeKey) {
        guard let framing = framing(for: viewport), let branch = planeGeometry()?[key] else { return }
        let target = motion.target.revealing(branch.bounds, in: framing)
        if target != motion.target { setCamera(target, animated: true) }
    }

    /// The canvas was resized: an untouched view refits by itself; a zoomed one keeps its zoom and centre, kept
    /// within the pan limit.
    func viewportChanged(_ size: CGSize) {
        viewport = size
        guard !motion.target.isFit, let framing = framing(for: size) else { return }
        let clamped = motion.target.clamped(in: framing)
        if clamped != motion.target { setCamera(clamped, animated: false) }
    }

    /// An element's subtree in layout space, at least a small square around it (a single tip would otherwise zoom in
    /// to the limit).
    func focusRect(_ key: LivingTreeKey) -> CGRect? { focusRect(key, orbit: orbit) }

    private func focusRect(_ key: LivingTreeKey, orbit: LivingTreeOrbit) -> CGRect? {
        guard let model, let geometry = planeGeometry(for: orbit), var rect = geometry.bounds(of: model.subtree(of: key)) else { return nil }
        let minimum: CGFloat = 90
        if rect.width < minimum { rect = rect.insetBy(dx: (rect.width - minimum) / 2, dy: 0) }
        if rect.height < minimum { rect = rect.insetBy(dx: 0, dy: (rect.height - minimum) / 2) }
        return rect
    }

    private func startMotion() {
        guard motionTimer == nil else { return }
        lastStep = Date()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.stepMotion() } }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func stopMotion() { motionTimer?.invalidate(); motionTimer = nil }

    /// One animation frame: advances the displayed orbit and camera; the timer stops when both arrive.
    func stepMotion(_ seconds: Double? = nil) {
        let now = Date(), elapsed = seconds ?? min(0.05, now.timeIntervalSince(lastStep))
        lastStep = now
        let turning = orbitMotion.step(elapsed)
        if orbit != orbitMotion.displayed { orbit = orbitMotion.displayed; if pivot != nil { applyPivot() } }
        if !turning && !self.turning { pivot = nil }
        guard let framing = framing(for: viewport) else { motion.jump(to: motion.target); camera = motion.target; if !turning { stopMotion() }; return }
        let moving = motion.step(elapsed, in: framing)
        camera = motion.displayed
        if !moving && !turning { stopMotion() }
    }

    // MARK: Labels

    private struct LabelKey: Equatable {
        let revision: Int, size: CGSize, focus: LivingTreeKey?, scale: Int, x: Int, y: Int
        let dimension: LivingTreeDimension, yaw: Int, pitch: Int
    }

    /// Branch names for the displayed camera. Placed again when the zoom changes by more than a small step or the
    /// view pans by more than 48 points; in between, labels stay attached to their tips.
    func labels(for size: CGSize, focus: LivingTreeKey?, measure: (String, Bool) -> CGSize) -> [LivingTreeLabel] {
        guard let model, let layout = layout(), let transform = transform(for: size) else { return [] }
        // In 3D labels are placed again every ~7° of turn; in between they follow their tips.
        let key = LabelKey(revision: revision, size: size, focus: focus, scale: Int((log2(transform.scale) * 8).rounded()),
                           x: Int((transform.translation.dx / 48).rounded()), y: Int((transform.translation.dy / 48).rounded()),
                           dimension: dimension, yaw: dimension == .depth ? Int((orbit.yaw / 0.12).rounded()) : 0, pitch: dimension == .depth ? Int((orbit.pitch / 0.12).rounded()) : 0)
        if let labelCache, labelCache.key == key { return labelCache.labels }
        // 3D: while the tree turns, the labels placed last follow their tips; placing them again waits for it to stop.
        if dimension == .depth, turning || isMoving, let labelCache, labelCache.key.revision == revision, labelCache.key.size == size,
           labelCache.key.dimension == dimension, labelCache.key.focus == focus { return labelCache.labels }
        let started = Date()
        let labels = LivingTreeLabeler.layout(model: model, geometry: layout.geometry, hits: layout.hits, transform: transform, viewport: size,
                                              zoom: camera.zoom, focus: focus, measure: measure)
        statistics.labelPlacements += 1; statistics.lastLabelSeconds = Date().timeIntervalSince(started)
        labelCache = (key, labels)
        return labels
    }
}

/// Work done by one Living Tree, for diagnostics and measurements.
struct LivingTreeStatistics: Equatable {
    var builds = 0, polls = 0, rebuildsForChanges = 0, rebuildsAvoided = 0
    var lastBuildSeconds = 0.0, lastReads = 0
    var labelPlacements = 0, lastLabelSeconds = 0.0
    /// Rebuilds after which the camera was adjusted to keep the viewed element in place.
    var viewsHeld = 0
    /// Same-folder rebuilds that waited for `rebuildInterval` (coalescing rapid updates).
    var throttledRebuilds = 0
}

// MARK: - View

/// The Living Tree: the explorer's current folder as an organic, luminous tree on a deep charcoal ground. The
/// trunk is the folder, branches are its folders, terminal elements are files and grouped small items. Shares
/// navigation and selection with the Navigator and Inspector; nothing moves unless something changed or the
/// viewer moves the camera (drag, scroll, pinch, keys or the zoom controls).
struct LivingTreeView: View {
    @ObservedObject var browser: InventoryBrowserModel
    @ObservedObject var explorer: InventoryExplorerController
    @ObservedObject var tree: LivingTreeController
    var showsSelectionContext = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.livingTreeInteractive) private var interactive
    @State private var hover: (key: LivingTreeKey, location: CGPoint)?
    /// The pointer over the canvas (hover is re-resolved there when the camera moves under a still pointer).
    @State private var pointer: CGPoint?
    @State private var gesture = LivingTreeGesture()
    /// A category picked in the color key: other branches recede.
    @State private var highlight: LivingTreeCategory?
    @State private var zoom = AtlasZoom.identity
    @State private var zoomProgress = 1.0
    @State private var showingHelp = false
    @State private var fade = 1.0
    @State private var shownRoot: Int64?
    @FocusState private var focused: Bool
    /// 2D or 3D, remembered.
    @AppStorage("inventory.livingTree.dimension", store: ViewerStore.viewPreferences) private var dimensionSetting = LivingTreeDimension.flat.rawValue

    var body: some View {
        VStack(spacing: 0) {
            header
            if tree.model != nil { controls }
            GeometryReader { proxy in
                content(size: proxy.size)
                    .modifier(LivingTreeZoomEffect(zoom: zoom, progress: zoomProgress))
                    .opacity(fade)
                .clipped()
                .onAppear { tree.viewportChanged(proxy.size) }
                .onChange(of: proxy.size) { _, size in tree.viewportChanged(size) }
            }
            footer
        }
        .background(LivingTreeGround())
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("inventory.livingTree")
        .onAppear { tree.reduceMotion = reduceMotion; tree.setDimension(LivingTreeDimension(rawValue: dimensionSetting) ?? .flat); sync() }
        .onChange(of: dimensionSetting) { _, value in
            tree.setDimension(LivingTreeDimension(rawValue: value) ?? .flat)
            // A short cross-fade between the flat and the 3D tree (also under Reduce Motion: no movement).
            fade = 0.4
            withAnimation(.easeOut(duration: 0.2)) { fade = 1 }
        }
        .onChange(of: reduceMotion) { _, value in tree.reduceMotion = value }
        .onChange(of: browser.directory?.id) { _, _ in sync() }
        .onChange(of: browser.status?.updatedAt) { _, _ in tree.inventoryChanged() }
        .onChange(of: browser.revision) { _, _ in tree.inventoryChanged() }
        .onChange(of: explorer.revealRequest) { _, request in if let request { tree.reveal(request.node, serial: request.serial) } }
        .onChange(of: explorer.selection) { _, id in
            if let override = tree.focusOverride, override.restFolder != id { tree.focusOverride = nil }
            // A selection made in the Navigator (or by the keyboard) is brought on screen; one made by clicking a
            // visible branch is already there and nothing moves.
            if let model = tree.model, let key = focusKey(model) { tree.bringIntoView(key) }
        }
        .onChange(of: tree.revision) { _, _ in transition() }
        .onChange(of: tree.camera) { _, _ in rehover() }
        .onChange(of: tree.orbit) { _, _ in rehover() }
    }

    private func sync() {
        guard let folder = browser.directory else { return }
        tree.show(root: folder, trail: browser.breadcrumbs)
        // A search result revealed while another visualization was showing is still drawn here.
        if let request = explorer.revealRequest, request.folder == folder.id { tree.reveal(request.node, serial: request.serial) }
    }

    // MARK: Content

    @ViewBuilder private func content(size: CGSize) -> some View {
        if let model = tree.model, let arrangement = tree.arrangement, let projected = tree.projected(for: size) {
            canvas(model: model, arrangement: arrangement, geometry: projected.geometry, transform: projected.transform, size: size)
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

    /// - Parameters:
    ///   - geometry: the tree as drawn on this canvas (projected through the camera). Pointer input queries the
    ///     controller's hit index through `transform` (in 3D it is built on first use after a turn).
    private func canvas(model: LivingTreeModel, arrangement: LivingTreeArrangement, geometry: LivingTreeGeometry,
                        transform: LivingTreeTransform, size: CGSize) -> some View {
        let focus = focusKey(model)
        let _ = { tree.pivotPreference = focus }()
        let chain = focus.map { model.ancestry(of: $0) } ?? []
        let illumination = tree.illumination
        let animating = illumination.isActive(at: Date()) { model[.node($0)] != nil }
        let labels = tree.labels(for: size, focus: focus, measure: LivingTreeLabelMetrics.measure)
        let tips = labels.map { geometry[$0.key]?.end ?? transform.apply($0.tip) }
        return ZStack(alignment: .topLeading) {
            LivingTreeBaseCanvas(revision: tree.revision, size: size, transform: transform, zoom: tree.camera.zoom, orbit: tree.dimension == .depth ? tree.orbit : nil,
                                 geometry: geometry, model: model, coloring: tree.coloring, highlight: highlight,
                                 isolate: tree.isolating ? (focus ?? model.rootKey) : nil).equatable()
            TimelineView(.animation(minimumInterval: reduceMotion ? 4 : 1.0 / 30, paused: !animating)) { timeline in
                Canvas(rendersAsynchronously: false) { context, _ in
                    LivingTreePainter(geometry: geometry, model: model).paintOverlay(&context, now: timeline.date, illumination: illumination, reduceMotion: reduceMotion,
                                                                                    hovered: hover?.key, chain: chain, focus: focus)
                }
            }
            .allowsHitTesting(false)
            // Labels stay attached to their tips as drawn now (in 3D, also between placements while turning).
            LivingTreeLabelCanvas(labels: labels, tips: tips, size: size).equatable().allowsHitTesting(false)
            if interactive {
                LivingTreeInputLayer { event in handle(event, model: model, transform: transform, labels: labels, tips: tips) }
            }
            lens(model: model, size: size)
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            // 3D: Command with an arrow turns the tree.
            if press.modifiers.contains(.command), tree.dimension == .depth {
                let step = 0.35
                switch press.key {
                case .upArrow: tree.turn(yaw: 0, pitch: step / 2, animated: true)
                case .downArrow: tree.turn(yaw: 0, pitch: -step / 2, animated: true)
                case .leftArrow: tree.turn(yaw: step, pitch: 0, animated: true)
                default: tree.turn(yaw: -step, pitch: 0, animated: true)
                }
                return .handled
            }
            // Option or Shift with an arrow pans the view; a plain arrow moves along the branches.
            if press.modifiers.contains(.option) || press.modifiers.contains(.shift) {
                let step: CGFloat = 0.14
                switch press.key {
                case .upArrow: tree.pan(byFraction: CGVector(dx: 0, dy: step))
                case .downArrow: tree.pan(byFraction: CGVector(dx: 0, dy: -step))
                case .leftArrow: tree.pan(byFraction: CGVector(dx: step, dy: 0))
                default: tree.pan(byFraction: CGVector(dx: -step, dy: 0))
                }
                return .handled
            }
            switch press.key {
            case .upArrow: return move(.towardTips, model: model, arrangement: arrangement)
            case .downArrow: return move(.towardTrunk, model: model, arrangement: arrangement)
            case .leftArrow: return move(.previousSibling, model: model, arrangement: arrangement)
            default: return move(.nextSibling, model: model, arrangement: arrangement)
            }
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-_0fFiI")) { press in
            switch press.characters {
            case "i", "I": tree.isolating.toggle()
            case "+", "=": tree.zoom(by: 1.5, at: nil, animated: true)
            case "-", "_": tree.zoom(by: 1 / 1.5, at: nil, animated: true)
            case "0": tree.resetView()
            default: guard let focus else { return .ignored }; tree.focus(on: focus)
            }
            return .handled
        }
        .onKeyPress(.return) { if let focus { open(focus, model: model) }; return .handled }
        .onKeyPress(.escape) { if showingHelp { showingHelp = false } else { goUp() }; return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Living Tree of \(model.root.parentID == nil ? "Startup Data" : model.root.name)")
        .accessibilityValue("\(tree.dimension.title), zoom \(Self.percent(tree.camera.zoom))")
        .accessibilityHint("Arrow keys move between branches; Option-arrow keys pan\(tree.dimension == .depth ? "; Command-arrow keys turn the tree" : ""). Plus and minus zoom, F focuses the selection, 0 resets the view. Return opens a folder. Escape goes to the enclosing folder.")
        .accessibilityZoomAction { action in
            switch action.direction {
            case .zoomIn: tree.zoom(by: 1.5, at: nil, animated: true)
            case .zoomOut: tree.zoom(by: 1 / 1.5, at: nil, animated: true)
            @unknown default: break
            }
        }
        .accessibilityChildren {
            // The largest elements as buttons (bounded); every entry stays reachable in the Navigator below.
            ForEach(LivingTreeText.accessibleElements(model, limit: 48), id: \.self) { key in
                if let branch = geometry[key], let element = model[key] {
                    Rectangle().frame(width: 24, height: 24).position(branch.end)
                        .accessibilityLabel(LivingTreeText.spoken(element, glow: element.node.flatMap { illumination.glows[$0.id] }))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { choose(key, model: model) }
                        .accessibilityAction(named: "Open") { open(key, model: model) }
                        .accessibilityAction(named: "Focus") { tree.focus(on: key) }
                }
            }
        }
    }

    // MARK: Input

    /// - Parameters: `labels`, `tips`: the labels as drawn; a label is a target for its element like the branch itself.
    private func handle(_ event: LivingTreeInputView.Event, model: LivingTreeModel, transform: LivingTreeTransform, labels: [LivingTreeLabel], tips: [CGPoint]) {
        let hit = { (point: CGPoint) in LivingTreeLabel.hit(point, labels: labels, tips: tips) ?? tree.hitIndex()?.hit(point, transform: transform) }
        let opens = { (key: LivingTreeKey) -> Bool in
            guard key != model.rootKey, let element = model[key] else { return false }
            return element.role == .rest || element.node?.kind == .directory
        }
        switch event {
        case .down(let point, let clicks, let modifiers):
            focused = true
            apply(gesture.down(at: point, clickCount: clicks, modifiers: modifiers, target: hit(point), orbits: tree.dimension == .depth, opens: opens), model: model)
        case .dragged(let point):
            apply(gesture.dragged(to: point), model: model)
        case .up(let point, let clicks):
            apply(gesture.up(at: point, clickCount: clicks, target: gesture.isDragging ? nil : hit(point)), model: model)
        case .moved(let point):
            pointer = point
            guard !gesture.isDragging else { return }
            hover = point.flatMap { p in hit(p).map { ($0, p) } }
        case .scroll(let delta, let precise, let momentum, let modifiers, let point):
            if let action = LivingTreeGesture.scroll(delta, precise: precise, modifiers: modifiers, at: point, momentum: momentum) { apply([action], model: model) }
        case .magnify(let magnification, let point):
            if let action = LivingTreeGesture.magnify(magnification, at: point) { apply([action], model: model) }
        case .smartMagnify(let point):
            apply([.toggleZoom(at: point)], model: model)
        case .rotate(let degrees):
            if tree.dimension == .depth, let action = LivingTreeGesture.rotate(degrees) { apply([action], model: model) }
        case .command(let command):
            switch command {
            case .zoomIn: tree.zoom(by: 1.5, at: nil, animated: true)
            case .zoomOut: tree.zoom(by: 1 / 1.5, at: nil, animated: true)
            case .fit: tree.fitTree()
            case .reset: tree.resetView()
            case .focusSelection: if let key = focusKey(model) { tree.focus(on: key) }
            }
        }
    }

    private func apply(_ actions: [LivingTreeGesture.Action], model: LivingTreeModel) {
        for action in actions {
            switch action {
            case .select(let key): choose(key, model: model)
            case .open(let key): open(key, model: model)
            case .focus(let key): choose(key, model: model); tree.focus(on: key)
            case .pan(let delta): tree.pan(by: delta)
            case .zoom(let factor, let point, let animated): tree.zoom(by: factor, at: point, animated: animated)
            case .toggleZoom(let point): tree.toggleZoom(at: point)
            case .orbit(let yaw, let pitch): tree.turn(yaw: yaw, pitch: pitch, animated: false)
            case .dragBegan: hover = nil
            case .dragEnded: tree.endTurn(); rehover()
            }
        }
    }

    /// The camera moved under a still pointer: the hover follows what is now under it.
    private func rehover() {
        guard let pointer, !gesture.isDragging, !tree.isMoving, let hits = tree.hitIndex(), let transform = tree.transform(for: tree.viewport) else { return }
        hover = hits.hit(pointer, transform: transform).map { ($0, pointer) }
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

    /// Entering a folder grows the new tree out of the branch it was (as it was on screen); leaving starts from the
    /// parent enlarged around the folder you left (as the parent is now viewed). Uniform scaling only; Reduce
    /// Motion cross-fades.
    private func transition() {
        guard let model = tree.model else { return }
        defer { shownRoot = model.root.id }
        guard let old = shownRoot, old != model.root.id else { return }
        let size = tree.viewport
        var start: AtlasZoom?
        if AtlasZoom.animates(reduceMotion: reduceMotion), let geometry = tree.planeGeometry(), let transform = tree.transform(for: size) {
            if let previous = tree.previousModel, let previousGeometry = tree.previousGeometry, let previousTransform = tree.previousTransform, previous.root.id == old,
               let rect = previousGeometry.bounds(of: previous.subtree(of: .node(model.root.id))) {
                start = AtlasZoom.start(entering: true, rect: previousTransform.apply(rect), in: size)
            } else if let rect = geometry.bounds(of: model.subtree(of: .node(old))) {
                start = AtlasZoom.start(entering: false, rect: transform.apply(rect), in: size)
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

    // MARK: Lens, controls, header, footer

    @ViewBuilder private func lens(model: LivingTreeModel, size: CGSize) -> some View {
        if let hover, let element = model[hover.key] {
            let lines = LivingTreeText.lens(element, model: model, glow: element.node.flatMap { tree.illumination.glows[$0.id] })
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(lines.value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if let hue = tree.coloring[hover.key], LivingTreePainter.strength(hue.purity) > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(LivingTreePainter.color(hue.category.tone, opacity: 1)).frame(width: 7, height: 7)
                        Text(hue.purity >= 0.95 || element.role == .file ? hue.category.title : "Mostly \(hue.category.title.lowercased())").font(.caption2).foregroundStyle(.secondary)
                    }
                }
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

    /// The color key: the types present in this tree, largest first. Clicking one makes the others recede.
    @ViewBuilder private var colorKey: some View {
        let present = Array(tree.coloring.present.prefix(8))
        if !present.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                ForEach(present, id: \.self) { category in
                    Button {
                        highlight = highlight == category ? nil : category
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(LivingTreePainter.color(category.tone, opacity: highlight == nil || highlight == category ? 1 : 0.35)).frame(width: 7, height: 7)
                            Text(category.title).font(.caption.weight(highlight == category ? .semibold : .regular))
                                .foregroundStyle(highlight == nil || highlight == category ? .secondary : .tertiary)
                        }
                        .padding(.vertical, 3).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(highlight == category ? "Show every type" : "Highlight \(category.title.lowercased())")
                    .accessibilityLabel("\(category.title)\(highlight == category ? ", highlighted" : "")")
                }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .contain).accessibilityLabel("Color by type")
        }
    }

    static func percent(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }

    /// Persistent controls sit outside the drawing so they never cover or intercept a branch.
    private var controls: some View {
        return VStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    dimensionControl
                    Divider().frame(height: 18)
                    zoomControls
                    Divider().frame(height: 18)
                    framingControls
                    selectionControls
                }
                .padding(.horizontal, StorageDesign.gutter)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        dimensionControl
                        Divider().frame(height: 18)
                        zoomControls
                        Divider().frame(height: 18)
                        framingControls
                    }
                    HStack(spacing: 8) {
                        selectionControls
                    }
                }
                .padding(.horizontal, StorageDesign.gutter)
            }
            colorKey.padding(.horizontal, StorageDesign.gutter)
        }
        .padding(.vertical, 6)
        .background(Color(white: 0.085).opacity(0.94))
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.08)) }
        .accessibilityElement(children: .contain).accessibilityLabel("Living Tree view controls")
    }

    private var dimensionControl: some View {
        Picker("Dimension", selection: $dimensionSetting) {
            Text("2D").tag(LivingTreeDimension.flat.rawValue)
            Text("3D").tag(LivingTreeDimension.depth.rawValue)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 84).controlSize(.small)
        .help("Show a flat tree or a tree that can be turned in depth")
        .accessibilityLabel("Tree dimension")
    }

    private var zoomControls: some View {
        let target = tree.cameraTarget
        return HStack(spacing: 2) {
            Text("Zoom").font(.caption).foregroundStyle(.secondary)
            controlButton("minus", "Zoom Out (−)", disabled: target.zoom <= LivingTreeCamera.minimumZoom + 1e-6) { tree.zoom(by: 1 / 1.5, at: nil, animated: true) }
            Text(Self.percent(tree.camera.zoom)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 40)
                .accessibilityLabel("Zoom \(Self.percent(tree.camera.zoom))")
            controlButton("plus", "Zoom In (+)", disabled: target.zoom >= LivingTreeCamera.maximumZoom - 1e-6) { tree.zoom(by: 1.5, at: nil, animated: true) }
        }
    }

    private var framingControls: some View {
        let target = tree.cameraTarget
        return HStack(spacing: 8) {
            namedControl("Fit", symbol: "arrow.up.left.and.arrow.down.right", help: "Fit the whole tree", disabled: target.isFit) { tree.fitTree() }
            namedControl("Reset", symbol: "arrow.counterclockwise", help: "Reset view and turning (0)", disabled: target.isFit && (tree.dimension == .flat || tree.orbit == .standard)) { tree.resetView() }
            namedControl("Help", symbol: "questionmark.circle", help: "Living Tree navigation help", disabled: false) { showingHelp.toggle() }
                .popover(isPresented: $showingHelp, arrowEdge: .top) { navigationHelp }
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 8) {
            namedControl("View Selection", symbol: "scope", help: "Frame the selected branch (F)", disabled: explorer.selection == nil) {
                if let model = tree.model, let key = focusKey(model) { tree.focus(on: key) }
            }
            namedControl(tree.isolating ? "Show All" : "Isolate", symbol: tree.isolating ? "circle.inset.filled" : "circle.dashed",
                         help: tree.isolating ? "Show every branch (I)" : "Show only the selected branch and its path (I)", disabled: explorer.selection == nil && !tree.isolating) {
                tree.isolating.toggle()
            }
        }
    }

    private func controlButton(_ symbol: String, _ help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(disabled ? .tertiary : .secondary).disabled(disabled)
        .help(help).accessibilityLabel(String(help.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces))
    }

    private func namedControl(_ title: String, symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).frame(minHeight: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(disabled ? .tertiary : .secondary).disabled(disabled)
        .help(help).accessibilityLabel(title).accessibilityHint(help)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
            let trail = browser.breadcrumbs.isEmpty ? (browser.directory.map { [$0] } ?? []) : browser.breadcrumbs
            let parent = trail.count > 1 ? trail[trail.count - 2] : nil
            Button { goUp() } label: { Label("Up", systemImage: "chevron.up").font(.caption.weight(.medium)).frame(minHeight: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(parent == nil ? .tertiary : .secondary).disabled(parent == nil)
                .help(parent.map { "Up to \(browser.displayName($0)) (Esc)" } ?? "Already at the top folder")
                .accessibilityLabel("Up one level").accessibilityIdentifier("tree.up")
            if trail.count > 4 { Text("…").foregroundStyle(.tertiary) }
            ForEach(Array(trail.suffix(4).enumerated()), id: \.element.id) { index, node in
                if index > 0 || trail.count > 4 { Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.tertiary) }
                let current = node.id == trail.last?.id
                Button(browser.displayName(node)) { if !current { browser.navigate(node) } }
                    .buttonStyle(.plain).font(.caption.weight(current ? .semibold : .regular))
                    .foregroundStyle(current ? .primary : .secondary).lineLimit(1)
                    .help(current ? node.path : "Go to \(browser.displayName(node))")
            }
            Spacer(minLength: 8)
            LivingTreeLegend()
            }
            if showsSelectionContext, let model = tree.model, let key = focusKey(model), let element = model[key] {
                selectionContext(element, key: key, model: model)
            }
        }
        .padding(.horizontal, StorageDesign.gutter).padding(.top, 9).padding(.bottom, 7)
        .accessibilityElement(children: .contain).accessibilityLabel("Living Tree path")
    }

    private func selectionContext(_ element: LivingTreeElement, key: LivingTreeKey, model: LivingTreeModel) -> some View {
        HStack(spacing: StorageDesign.rowGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(element.role == .rest ? "Selected group" : "Selected \(element.isFolder ? "folder" : "item")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(element.role == .rest ? "Other items in \(element.parent.flatMap { model[$0]?.name } ?? "this folder")" : element.name)
                    .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(selectionSize(element)).font(.callout.monospacedDigit()).lineLimit(1)
                if let share = parentShare(element, model: model) { Text(share).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if element.isFolder, key != model.rootKey {
                Button("Explore Folder") { open(key, model: model) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Make this folder the root of the Living Tree")
            }
        }
        .help(element.node?.path ?? element.name)
        .accessibilityIdentifier("tree.selection")
    }

    private func selectionSize(_ element: LivingTreeElement) -> String {
        if let node = element.node {
            return InventoryNodePresentation.size(element.bytes, node: node, formatter: AtlasText.bytes)
        }
        return element.bytes.map(AtlasText.bytes) ?? "Size not measured"
    }

    private func parentShare(_ element: LivingTreeElement, model: LivingTreeModel) -> String? {
        guard let node = element.node, let parent = element.parent.flatMap({ model[$0]?.node }) else { return nil }
        return InventoryInspectorPresentation(node: node, parent: parent, formatter: AtlasText.bytes).shareText
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(footerText)
            Spacer(minLength: 12)
            Text("Click a branch to select it · double-click to open · Esc goes up").font(.caption).foregroundStyle(.tertiary).lineLimit(2).multilineTextAlignment(.trailing).frame(maxWidth: 260, alignment: .trailing)
        }.padding(.horizontal, 16).padding(.vertical, 4).frame(minHeight: 24).accessibilityIdentifier("inventory.livingTree.status")
    }

    /// Every way to move around, in plain words. Each has a visible button as well; none is gesture-only.
    private var navigationHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Getting around the Living Tree").font(.headline).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                helpRow("Select a folder or file", "Click its branch. Its details appear in the Inspector.")
                helpRow("Open a folder", "Double-click it, or select it and press Return.")
                helpRow("Go back up", "The Up button, a folder name in the path, or Esc.")
                helpRow("Zoom", "Scroll (mouse wheel or trackpad), pinch, or the − and + buttons.")
                helpRow(tree.dimension == .depth ? "Turn and move" : "Move around", tree.dimension == .depth ? "Drag to turn. Hold ⇧ while dragging or scrolling to move." : "Drag, or hold ⇧ or ⌥ while scrolling.")
                helpRow("See everything", "Fit frames the whole tree. Reset (0) also undoes turning.")
                helpRow("Find the selection", "View Selection (F) frames it; Isolate (I) hides the rest.")
            }
            Text("Prefer a list? Choose Atlas, or use the Navigator below. They show the same folders.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 420)
        .onExitCommand { showingHelp = false }
    }

    private func helpRow(_ action: String, _ how: String) -> some View {
        GridRow {
            Text(action).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text(how).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footerText: String {
        guard let model = tree.model else { return " " }
        var parts = ["Width ≈ indexed allocation; length and position show hierarchy, not bytes", "not reclaimable storage", "\(model.count.formatted()) elements"]
        let unmeasured = model.order.reduce(Int64(0)) { total, key in
            let element = model[key]!
            return total + (element.role == .unmeasured ? 1 : (element.role == .rest ? element.unmeasured : 0))
        }
        if unmeasured > 0 { parts.append("\(unmeasured.formatted()) without a measured size, never drawn as zero") }
        if model.truncated { parts.append("reduced to keep the read short") }
        return parts.joined(separator: " · ")
    }
}

/// Whether the canvas takes pointer input (false for offscreen renders, which cannot draw AppKit views).
private struct LivingTreeInteractiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var livingTreeInteractive: Bool {
        get { self[LivingTreeInteractiveKey.self] }
        set { self[LivingTreeInteractiveKey.self] = newValue }
    }
}

// MARK: - Pointer input

/// The canvas's pointer, scroll and pinch input in canvas coordinates (top-left origin). Transparent: it draws
/// nothing and is not an accessibility element; the SwiftUI container keeps focus, keys and the accessible elements.
struct LivingTreeInputLayer: NSViewRepresentable {
    let handle: (LivingTreeInputView.Event) -> Void
    func makeNSView(context: Context) -> LivingTreeInputView { let view = LivingTreeInputView(); view.handle = handle; return view }
    func updateNSView(_ view: LivingTreeInputView, context: Context) { view.handle = handle }
}

final class LivingTreeInputView: NSView {
    enum Command { case zoomIn, zoomOut, fit, reset, focusSelection }
    enum Event {
        case down(CGPoint, clicks: Int, LivingTreeGesture.Modifiers)
        case dragged(CGPoint)
        case up(CGPoint, clicks: Int)
        /// Nil: the pointer left the canvas.
        case moved(CGPoint?)
        case scroll(CGVector, precise: Bool, momentum: Bool, LivingTreeGesture.Modifiers, CGPoint)
        case magnify(Double, CGPoint)
        case smartMagnify(CGPoint)
        /// Trackpad rotation, degrees counter-clockwise.
        case rotate(Double)
        case command(Command)
    }

    var handle: ((Event) -> Void)?
    private var tracking: NSTrackingArea?
    private var grabbing = false

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private static func modifiers(_ event: NSEvent) -> LivingTreeGesture.Modifiers {
        var result = LivingTreeGesture.Modifiers()
        if event.modifierFlags.contains(.command) { result.insert(.command) }
        if event.modifierFlags.contains(.option) { result.insert(.option) }
        if event.modifierFlags.contains(.shift) { result.insert(.shift) }
        return result
    }

    override func mouseDown(with event: NSEvent) { handle?(.down(point(event), clicks: event.clickCount, Self.modifiers(event))) }
    override func mouseDragged(with event: NSEvent) {
        if !grabbing { grabbing = true; NSCursor.closedHand.push() }
        handle?(.dragged(point(event)))
    }
    override func mouseUp(with event: NSEvent) {
        if grabbing { grabbing = false; NSCursor.pop() }
        handle?(.up(point(event), clicks: event.clickCount))
    }
    override func mouseMoved(with event: NSEvent) { handle?(.moved(point(event))) }
    override func mouseEntered(with event: NSEvent) { handle?(.moved(point(event))) }
    override func mouseExited(with event: NSEvent) { handle?(.moved(nil)) }
    override func scrollWheel(with event: NSEvent) {
        handle?(.scroll(CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas, momentum: !event.momentumPhase.isEmpty, Self.modifiers(event), point(event)))
    }
    override func magnify(with event: NSEvent) { handle?(.magnify(Double(event.magnification), point(event))) }
    override func smartMagnify(with event: NSEvent) { handle?(.smartMagnify(point(event))) }
    override func rotate(with event: NSEvent) { handle?(.rotate(Double(event.rotation))) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Living Tree")
        for (title, command) in [("Zoom In", Command.zoomIn), ("Zoom Out", .zoomOut), ("Fit Tree", .fit), ("Focus Selection", .focusSelection), ("Reset View", .reset)] {
            if command == .reset { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command
            menu.addItem(item)
        }
        return menu
    }
    @objc private func runCommand(_ item: NSMenuItem) { if let command = item.representedObject as? Command { handle?(.command(command)) } }
}

/// Text sizes for label placement, matching the fonts the labels are drawn with (bounded cache).
@MainActor enum LivingTreeLabelMetrics {
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    private static var cache = [String: CGSize]()
    static func measure(_ text: String, title: Bool) -> CGSize {
        let key = (title ? "t" : "d") + text
        if let size = cache[key] { return size }
        if cache.count > 4_096 { cache.removeAll() }
        let raw = (text as NSString).size(withAttributes: [.font: title ? titleFont : detailFont])
        let size = CGSize(width: ceil(raw.width), height: ceil(raw.height))
        cache[key] = size
        return size
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

/// The static tree. Redrawn only when the tree, the canvas size or the camera changes (hover, selection and light
/// are drawn on a separate overlay), so a 3,000-element tree is not repainted on every pointer move or animation
/// frame. Only what is on screen and large enough to see at this scale is drawn.
struct LivingTreeBaseCanvas: View, Equatable {
    let revision: Int
    let size: CGSize
    let transform: LivingTreeTransform
    let zoom: Double
    /// 3D: the orbit the geometry was projected for (nil in 2D).
    var orbit: LivingTreeOrbit? = nil
    /// Projected through `transform`.
    let geometry: LivingTreeGeometry
    let model: LivingTreeModel
    var coloring: LivingTreeColoring = .empty
    /// A category picked in the legend: other branches recede.
    var highlight: LivingTreeCategory? = nil
    /// Isolation: everything outside this element's subtree (and its path to the trunk) recedes.
    var isolate: LivingTreeKey? = nil
    static func == (a: Self, b: Self) -> Bool {
        a.revision == b.revision && a.size == b.size && a.transform == b.transform && a.zoom == b.zoom && a.orbit == b.orbit && a.highlight == b.highlight && a.isolate == b.isolate
    }
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            LivingTreePainter(geometry: geometry, model: model, zoom: zoom, coloring: coloring, highlight: highlight,
                              isolated: isolate.map { Set(model.subtree(of: $0) + model.ancestry(of: $0)) }).paintBase(&context)
        }
        .accessibilityHidden(true)
    }
}

/// Branch names on small dark plates, attached to their tips. Redrawn when the labels or the camera change.
struct LivingTreeLabelCanvas: View, Equatable {
    let labels: [LivingTreeLabel]
    /// Each label's tip as drawn now.
    let tips: [CGPoint]
    let size: CGSize
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in LivingTreePainter.paintLabels(&context, labels: labels, tips: tips, size: size) }
            .accessibilityHidden(true)
    }
}

// MARK: - Painting

/// Draws the tree as projected on the canvas: tapered branches colored by type (each limb blends from its parent's
/// color into its own), soft colored light at the tips; labels on their own layer; the overlay draws hover, the
/// selection's path to the trunk and the amber or blue light of measured changes.
struct LivingTreePainter {
    let geometry: LivingTreeGeometry
    let model: LivingTreeModel
    /// The camera's zoom relative to the fit: deeper structure fades less when inspected closely.
    var zoom: Double = 1
    var coloring: LivingTreeColoring = .empty
    var highlight: LivingTreeCategory? = nil
    var isolated: Set<LivingTreeKey>? = nil

    static func color(_ tone: AtlasTone, opacity: Double) -> Color {
        Color(hue: tone.hue, saturation: tone.saturation, brightness: tone.brightness, opacity: opacity)
    }

    static let ground = (r: 0.066, g: 0.071, b: 0.08)

    static func rgb(_ tone: AtlasTone) -> (r: Double, g: Double, b: Double) {
        let h = (tone.hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6, s = tone.saturation, v = tone.brightness
        let i = Int(h) % 6, f = h - Double(Int(h)), p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i { case 0: return (v, t, p); case 1: return (q, v, p); case 2: return (p, v, t); case 3: return (p, q, v); case 4: return (t, p, v); default: return (v, p, q) }
    }

    /// A tone at `opacity` pre-mixed with the charcoal ground into an opaque colour: overlapping branches (every fork)
    /// then join seamlessly instead of stacking into brighter seams.
    static func solid(_ tone: AtlasTone, _ opacity: Double) -> Color {
        let c = rgb(tone), g = ground, a = min(1, max(0, opacity))
        return Color(red: g.r + (c.r - g.r) * a, green: g.g + (c.g - g.g) * a, blue: g.b + (c.b - g.b) * a)
    }

    static func solid(_ opacity: Double) -> Color { solid(AtlasTone(hue: 0.11, saturation: 0.047, brightness: 0.95), opacity) }

    /// How strongly a category colors an element: none for mixed folders, full for clear ones.
    static func strength(_ purity: Double) -> Double { let t = min(1, max(0, (purity - 0.35) / 0.5)); return t * t * (3 - 2 * t) }

    /// The element's tone: its category's hue, as saturated as it clearly belongs to it.
    func tone(_ key: LivingTreeKey?) -> AtlasTone {
        let neutral = LivingTreePalette.branch
        guard let key, let hue = coloring[key] else { return neutral }
        let c = hue.category.tone, t = Self.strength(hue.purity)
        return AtlasTone(hue: c.hue, saturation: neutral.saturation + (c.saturation - neutral.saturation) * t, brightness: neutral.brightness + (c.brightness - neutral.brightness) * t)
    }

    /// Recession for the legend highlight and isolation (1: unchanged).
    func emphasis(_ key: LivingTreeKey) -> Double {
        var value = 1.0
        if let highlight { value *= coloring[key].map { $0.category == highlight && $0.purity >= 0.35 } == true ? 1.1 : 0.2 }
        if let isolated, !isolated.contains(key) { value *= 0.13 }
        return value
    }

    /// Whether any of a branch (with its width and tip light) is inside `rect`. Cheap: control points only.
    static func touches(_ branch: LivingTreeGeometry.Branch, _ rect: CGRect) -> Bool {
        let pad = max(branch.startWidth, branch.endWidth) / 2 + branch.glow * 2.6
        let minX = min(branch.start.x, branch.control1.x, branch.control2.x, branch.end.x) - pad, maxX = max(branch.start.x, branch.control1.x, branch.control2.x, branch.end.x) + pad
        let minY = min(branch.start.y, branch.control1.y, branch.control2.y, branch.end.y) - pad, maxY = max(branch.start.y, branch.control1.y, branch.control2.y, branch.end.y) + pad
        return maxX >= rect.minX && minX <= rect.maxX && maxY >= rect.minY && minY <= rect.maxY
    }

    /// Batched strokes and fills share width, opacity and color.
    struct Batch: Hashable, Comparable {
        let width: Int, opacity: Int, color: Int
        static func < (a: Self, b: Self) -> Bool { (a.color, a.width, a.opacity) < (b.color, b.width, b.opacity) }
    }

    /// A small palette index for batching: the category and four strengths, or neutral.
    func colorIndex(_ key: LivingTreeKey) -> Int {
        guard let hue = coloring[key] else { return -1 }
        let level = Int((Self.strength(hue.purity) * 3).rounded())
        return level == 0 ? -1 : hue.category.rawValue * 4 + level
    }

    func tone(index: Int) -> AtlasTone {
        guard index >= 0 else { return LivingTreePalette.branch }
        let neutral = LivingTreePalette.branch, c = LivingTreeCategory(rawValue: index / 4)!.tone, t = Double(index % 4) / 3
        return AtlasTone(hue: c.hue, saturation: neutral.saturation + (c.saturation - neutral.saturation) * t, brightness: neutral.brightness + (c.brightness - neutral.brightness) * t)
    }

    func paintBase(_ context: inout GraphicsContext) {
        let visible = CGRect(origin: .zero, size: geometry.size).insetBy(dx: -4, dy: -4)
        // 3D: a faint ring on the ground under the crown shows how the tree is turned and tilted.
        if geometry.ground.count > 2 {
            var ring = Path(); ring.addLines(geometry.ground); ring.closeSubpath()
            context.stroke(ring, with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        }
        // A faint pool of light where the trunk meets the ground.
        let base = geometry.base, glow = geometry.trunkWidth * 5
        context.fill(Path(ellipseIn: CGRect(x: base.x - glow * 2, y: base.y - glow * 0.35, width: glow * 4, height: glow * 0.7)),
                     with: .radialGradient(Gradient(colors: [Color.white.opacity(0.07), .clear]), center: base, startRadius: 0, endRadius: glow * 2))
        // Thin branches are batched into a few strokes by width, opacity and color; thick ones are filled ribbons that
        // blend from the parent's color into their own.
        var thin = [Batch: Path](), dots = [Batch: Path](), cores = [Batch: Path]()
        var tips = [(CGPoint, CGFloat, Double, AtlasTone)]()
        func batch(_ width: CGFloat, _ opacity: Double, _ color: Int) -> Batch { Batch(width: Int((width * 4).rounded()), opacity: Int((min(1, opacity) * 20).rounded()), color: color) }
        for branch in geometry.branches {
            guard let element = model[branch.key], Self.touches(branch, visible), LivingTreeDetail.isDrawn(branch) else { continue }
            // Depth shading in 3D (1 in 2D): far branches are dimmer, and drawn first so near ones cover them.
            let opacity = LivingTreePalette.opacity(depth: branch.depth, status: element.status, sizeKnown: branch.sizeKnown, zoom: zoom) * Double(branch.shade) * emphasis(branch.key)
            let own = tone(branch.key), index = colorIndex(branch.key)
            if !branch.sizeKnown {
                context.stroke(Self.curve(branch), with: .color(Self.color(LivingTreePalette.branch, opacity: opacity)), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, dash: [2, 2.5]))
                context.stroke(Path(ellipseIn: CGRect(x: branch.end.x - 1.8, y: branch.end.y - 1.8, width: 3.6, height: 3.6)), with: .color(Self.color(LivingTreePalette.branch, opacity: opacity)), lineWidth: 0.6)
                continue
            }
            if branch.role == .rest {
                // Grouped small items: a fine tuft of three sprigs ending in one point of light.
                for sprig in Self.sprigs(branch) { thin[batch(max(0.5, branch.startWidth * 0.55), opacity * 0.8, index), default: Path()].addPath(sprig) }
            } else if branch.startWidth < 1.6 {
                thin[batch(max(0.55, (branch.startWidth + branch.endWidth) / 2), opacity, index), default: Path()].addPath(Self.curve(branch))
            } else {
                // A soft body whose color flows from the parent into this branch, with a finer, brighter core.
                let from = tone(element.parent)
                context.fill(Self.ribbon(branch), with: .linearGradient(Gradient(colors: [Self.solid(from, opacity * 0.72), Self.solid(own, opacity * 0.72)]),
                                                                        startPoint: branch.start, endPoint: branch.end))
                cores[batch(max(0.6, min(2.2, branch.startWidth * 0.22)), min(1, opacity * 0.9), index), default: Path()].addPath(Self.curve(branch))
            }
            if branch.glow > 0 {
                if branch.glow >= 2.6 && tips.count < 400 { tips.append((branch.end, branch.glow, opacity, own)) }
                else {
                    let r = max(0.7, branch.glow * 0.42)
                    dots[batch(1, min(1, opacity * 1.25), index), default: Path()].addEllipse(in: CGRect(x: branch.end.x - r, y: branch.end.y - r, width: 2 * r, height: 2 * r))
                }
            }
            if element.status == .lowerBound && branch.glow > 0 {
                context.stroke(Path(ellipseIn: CGRect(x: branch.end.x - 2.6, y: branch.end.y - 2.6, width: 5.2, height: 5.2)), with: .color(Self.color(LivingTreePalette.branch, opacity: opacity)), lineWidth: 0.7)
            }
        }
        for (key, path) in thin.sorted(by: { $0.key < $1.key }) {
            context.stroke(path, with: .color(Self.color(tone(index: key.color), opacity: Double(key.opacity) / 20)), style: StrokeStyle(lineWidth: CGFloat(key.width) / 4, lineCap: .round))
        }
        for (key, path) in cores.sorted(by: { $0.key < $1.key }) {
            let t = tone(index: key.color)
            context.stroke(path, with: .color(Self.color(AtlasTone(hue: t.hue, saturation: t.saturation * 0.5, brightness: 1), opacity: Double(key.opacity) / 20 * 0.55)), style: StrokeStyle(lineWidth: CGFloat(key.width) / 4, lineCap: .round))
        }
        for (key, path) in dots.sorted(by: { $0.key < $1.key }) {
            let t = tone(index: key.color)
            context.fill(path, with: .color(Self.color(AtlasTone(hue: t.hue, saturation: min(1, t.saturation * 1.15), brightness: 1), opacity: Double(key.opacity) / 20)))
        }
        // Soft light at the larger tips, in their own color.
        for (point, radius, opacity, t) in tips {
            let r = radius * 2.8
            let glowTone = AtlasTone(hue: t.hue, saturation: min(1, t.saturation * 1.2), brightness: 1)
            context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
                         with: .radialGradient(Gradient(colors: [Self.color(glowTone, opacity: 0.34 * opacity), .clear]), center: point, startRadius: 0, endRadius: r))
            let core = max(0.8, radius * 0.34)
            context.fill(Path(ellipseIn: CGRect(x: point.x - core, y: point.y - core, width: 2 * core, height: 2 * core)),
                         with: .color(Self.color(AtlasTone(hue: t.hue, saturation: t.saturation * 0.45, brightness: 1), opacity: min(1, 0.55 + opacity * 0.4))))
        }
    }

    /// Labels on dark plates: the name, then the size. The selection's own label is brighter, with a fine accent edge.
    static func paintLabels(_ context: inout GraphicsContext, labels: [LivingTreeLabel], tips: [CGPoint], size: CGSize) {
        let visible = CGRect(origin: .zero, size: size)
        for (label, tip) in zip(labels, tips) {
            let rect = label.frame.offsetBy(dx: tip.x, dy: tip.y)
            guard visible.intersects(rect) else { continue }
            let plate = Path(roundedRect: rect, cornerRadius: 4, style: .continuous)
            context.fill(plate, with: .color(Color(red: 0.035, green: 0.04, blue: 0.045).opacity(label.emphasized ? 0.94 : 0.86)))
            context.stroke(plate, with: .color(label.emphasized ? Color.accentColor.opacity(0.82) : Color.white.opacity(0.13)), lineWidth: label.emphasized ? 1 : 0.5)
            let title = context.resolve(Text(label.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(label.emphasized ? 1 : 0.96)))
            let detail = context.resolve(Text(label.detail).font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.76)))
            let origin = CGPoint(x: rect.minX + LivingTreeLabeler.paddingX, y: rect.minY + LivingTreeLabeler.paddingY)
            context.draw(title, at: origin, anchor: .topLeading)
            context.draw(detail, at: CGPoint(x: origin.x, y: origin.y + title.measure(in: CGSize(width: 1_000, height: 100)).height), anchor: .topLeading)
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
        // The selection's path back to the trunk (a quiet thread), then the selection itself: a brighter core and a
        // fine accent ring at its tip.
        for key in chain.dropLast() {
            guard let branch = geometry[key] else { continue }
            context.stroke(Self.curve(branch), with: .color(.white.opacity(0.34)), style: StrokeStyle(lineWidth: max(0.8, min(2.4, branch.startWidth * 0.26)), lineCap: .round))
        }
        if let focus, let branch = geometry[focus] {
            context.stroke(Self.curve(branch), with: .color(.white.opacity(0.88)), style: StrokeStyle(lineWidth: max(1.3, min(3.5, branch.startWidth * 0.4)), lineCap: .round))
            let r = max(4, min(7, branch.glow + 2.5))
            context.stroke(Path(ellipseIn: CGRect(x: branch.end.x - r, y: branch.end.y - r, width: 2 * r, height: 2 * r)), with: .color(Color.accentColor.opacity(0.85)), lineWidth: 1.3)
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
