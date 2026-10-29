import AppKit

/// AppKit edge of the Living Tree wheel fix: real `NSEvent` scroll events, built from `CGEvent`s in-process and handed
/// straight to `LivingTreeInputView.scrollWheel` (never posted to the system, so the desktop is untouched), must reach
/// the gesture interpreter as zoom — line-unit wheels animated, pixel-unit devices (trackpad, Magic Mouse, smooth-
/// scrolling mice) direct — and never as a turn of the tree.
@MainActor func livingTreeScrollRoutingChecks(_ check: (Bool, String) -> Void) {
    let view = LivingTreeInputView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    var received: [LivingTreeInputView.Event] = []
    view.handle = { received.append($0) }
    func deliver(_ units: CGScrollEventUnit, dy: Int32, dx: Int32 = 0, flags: CGEventFlags = []) -> LivingTreeGesture.Action? {
        received.removeAll()
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return nil }
        cg.flags = flags
        cg.location = CGPoint(x: 300, y: 200)
        guard let event = NSEvent(cgEvent: cg) else { return nil }
        view.scrollWheel(with: event)
        guard case .scroll(let delta, let precise, let momentum, let modifiers, let point)? = received.first else { return nil }
        return LivingTreeGesture.scroll(delta, precise: precise, modifiers: modifiers, at: point, momentum: momentum)
    }
    func isZoom(_ action: LivingTreeGesture.Action?, animated: Bool, inward: Bool) -> Bool {
        if case .zoom(let factor, _, let a)? = action { return a == animated && (factor > 1) == inward } else { return false }
    }
    let wheelUp = deliver(.line, dy: 1), wheelDown = deliver(.line, dy: -1)
    let smoothUp = deliver(.pixel, dy: 12), smoothDown = deliver(.pixel, dy: -12)
    check(isZoom(wheelUp, animated: true, inward: true) && isZoom(wheelDown, animated: true, inward: false),
          "living tree AppKit routing: a line-unit mouse wheel event zooms in and out (animated) — got \(String(describing: wheelUp)), \(String(describing: wheelDown))")
    check(isZoom(smoothUp, animated: false, inward: true) && isZoom(smoothDown, animated: false, inward: false),
          "living tree AppKit routing: a pixel-unit (smooth-scrolling mouse / Magic Mouse / trackpad) scroll zooms in and out directly — got \(String(describing: smoothUp)), \(String(describing: smoothDown))")
    let shifted = deliver(.pixel, dy: 12, flags: .maskShift)
    check({ if case .pan? = shifted { return true } else { return false } }(), "living tree AppKit routing: Shift-scroll pans — got \(String(describing: shifted))")
    var turned = 0
    for units in [CGScrollEventUnit.line, .pixel] { for (dy, dx) in [(Int32(3), Int32(0)), (-8, 2), (1, 9), (0, -5)] {
        if case .orbit? = deliver(units, dy: dy, dx: dx) { turned += 1 }
    } }
    check(turned == 0, "living tree AppKit routing: no wheel or pixel scroll event turns the tree (\(turned) of 8 did)")
}

/// Camera/layout cache checks use a tiny in-memory hierarchy, no catalog or desktop events.
@MainActor func structuredExplorerStateChecks(_ check: (Bool, String) -> Void) {
    func node(_ id: Int64, parent: Int64?, children: Int64) -> InventoryNode {
        InventoryNode(id: id, parentID: parent, identity: InventoryIdentity(device: 1, inode: UInt64(id), birthNanoseconds: 1), path: "/fixture/\(id)", name: "folder\(id)",
                      kind: .directory, logicalBytes: 100, allocatedBytes: 100, previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil,
                      directLogicalBytes: 0, directAllocatedBytes: 0, childCount: children, descendantFiles: 0, descendantDirectories: 0, status: .complete,
                      coverageState: "complete", listingState: nil, statusReason: nil, measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
    }
    let nodes = [node(1, parent: nil, children: 2), node(2, parent: 1, children: 1), node(3, parent: 2, children: 1), node(4, parent: 3, children: 0), node(5, parent: 1, children: 0)]
    func model(_ root: InventoryNode) -> LivingTreeModel {
        LivingTreeBuilder.build(root: root, budget: LivingTreeBudget(elements: 100, perFolder: 20, minimumShare: 0)) { parent, _ in
            (InventoryChildPage(items: nodes.filter { $0.parentID == parent }, next: nil), nil)
        }
    }
    let tree = model(nodes[0]), state = StructuredExplorerState()
    let base = state.layout(tree, revision: 1, depth: 1, selection: nil)
    let count = state.layouts
    let ordinary = state.layout(tree, revision: 1, depth: 1, selection: .node(2))
    check(ordinary.nodes == base.nodes && state.layouts == count, "structured explorer cache: selecting an already shown folder does not rebuild layout")
    let deep = state.layout(tree, revision: 1, depth: 1, selection: .node(4))
    check(deep[.node(4)]?.elided == 1, "structured explorer cache: a deep selection is retained on a counted spur")
    let cleared = state.layout(tree, revision: 1, depth: 1, selection: nil)
    let normal = state.layout(tree, revision: 1, depth: 1, selection: .node(5))
    check(cleared.nodes == base.nodes && normal.nodes == base.nodes, "structured explorer cache: clearing or replacing a deep selection restores the baseline hierarchy and hidden counts")
    let transform = state.transform(base)
    state.noteDrawn(base, transform)
    let child = state.layout(model(nodes[1]), revision: 2, depth: 1, selection: nil)
    state.noteDrawn(child, state.transform(child))
    check(state.drawnBeforeRootChange(from: tree.rootKey)?.layout.rootKey == tree.rootKey,
          "structured explorer transition: rendering the new root preserves the previous root geometry for its transition")
    // Label placement runs once per drawn state: a redraw for a pointer move that changes nothing labelled (the body
    // re-evaluates on every move) reuses it; a new hover, camera or tree places them again.
    let size = CGSize(width: 800, height: 500)
    let shown = state.layout(tree, revision: 3, depth: 2, selection: nil)
    let t = StructuredExplorerCamera().transform(bounds: shown.bounds, size: size)
    let before = state.labelPlacements
    let a = state.labels(shown, model: tree, transform: t, size: size, selected: nil, hovered: nil)
    let b = state.labels(shown, model: tree, transform: t, size: size, selected: nil, hovered: nil)
    let afterRepeat = state.labelPlacements
    _ = state.labels(shown, model: tree, transform: t, size: size, selected: nil, hovered: .node(5))
    let afterHover = state.labelPlacements
    let next = state.layout(tree, revision: 4, depth: 2, selection: nil)
    _ = state.labels(next, model: tree, transform: t, size: size, selected: nil, hovered: .node(5))
    check(a == b && afterRepeat == before + 1 && afterHover == before + 2 && state.labelPlacements == before + 3,
          "structured explorer labels: placed once per drawn state; pointer moves that change nothing reuse them; hover and a new tree place again (\(state.labelPlacements - before) placements)")

    // Both scroll directions end to end: real NSEvent scroll events → LivingTreeInputView → gesture interpreter →
    // the Structured Explorer camera, applied as the view applies them (native QA saw only scroll-in change the zoom).
    let input = LivingTreeInputView(frame: CGRect(origin: .zero, size: size))
    var camera = StructuredExplorerCamera(), selections = 0
    let anchor = CGPoint(x: 560, y: 180)
    input.handle = { event in
        // A view without a window reports the event's screen location, so the pointer is taken to be at `anchor` on the
        // canvas, as a real pointer over it would be; delta, precision, momentum and modifiers come from the event.
        guard case .scroll(let delta, let precise, let momentum, let modifiers, _) = event,
              let action = LivingTreeGesture.scroll(delta, precise: precise, modifiers: modifiers, at: anchor, momentum: momentum) else { return }
        switch action {
        case .zoom(let factor, let at, _): camera.zoom(by: factor, at: at, bounds: shown.bounds, size: size)
        case .pan(let d): camera.pan(by: d, bounds: shown.bounds, size: size)
        case .select, .open, .focus: selections += 1
        default: break
        }
    }
    func scroll(_ units: CGScrollEventUnit, dy: Int32, dx: Int32 = 0, flags: CGEventFlags = [], momentum: Bool = false) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        cg.flags = flags
        if momentum { cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2) }
        if let event = NSEvent(cgEvent: cg) { input.scrollWheel(with: event) }
    }
    func under(_ c: StructuredExplorerCamera) -> CGPoint { c.transform(bounds: shown.bounds, size: size).invert(anchor) }
    let start = under(camera)
    scroll(.line, dy: 2); let zoomedIn = camera.zoom
    scroll(.line, dy: -2); let zoomedBack = camera.zoom
    scroll(.line, dy: -2); let zoomedOut = camera.zoom
    let held = under(camera)
    check(zoomedIn > 1.3 && abs(zoomedBack - 1) < 1e-6 && zoomedOut < 0.8 && hypot(held.x - start.x, held.y - start.y) < 0.01,
          "structured explorer wheel: forward zooms in, the same reverse returns exactly, further reverse zooms out below 100%, about the pointer (in \(zoomedIn), back \(zoomedBack), out \(zoomedOut))")
    camera = StructuredExplorerCamera()
    scroll(.pixel, dy: 30); let pixelIn = camera.zoom
    scroll(.pixel, dy: -30); let pixelBack = camera.zoom
    scroll(.pixel, dy: -30, momentum: true); let afterMomentum = camera.zoom
    check(pixelIn > 1.2 && abs(pixelBack - 1) < 1e-6 && afterMomentum == pixelBack,
          "structured explorer smooth/trackpad scroll: both directions zoom directly; inertia after the fingers lift does not zoom (in \(pixelIn), back \(pixelBack))")
    camera = StructuredExplorerCamera()
    for _ in 0..<60 { scroll(.line, dy: 3) }
    let maximum = camera.zoom
    for _ in 0..<120 { scroll(.line, dy: -3) }
    check(maximum == StructuredExplorerCamera.zoomRange.upperBound && camera.zoom == StructuredExplorerCamera.zoomRange.lowerBound,
          "structured explorer wheel: zoom stops at \(Int(StructuredExplorerCamera.zoomRange.upperBound * 100))% and \(Int(StructuredExplorerCamera.zoomRange.lowerBound * 100))% in either direction")
    camera = StructuredExplorerCamera(zoom: 3)
    let zoomBefore = camera.zoom, centreBefore = under(camera)
    scroll(.pixel, dy: 0, dx: 25); let sideways = under(camera)
    scroll(.pixel, dy: 25, flags: .maskShift); let shifted = under(camera)
    scroll(.pixel, dy: 25, flags: .maskAlternate); let optioned = under(camera)
    check(camera.zoom == zoomBefore && sideways != centreBefore && shifted != sideways && optioned != shifted && selections == 0,
          "structured explorer scroll: sideways, Shift- and Option-scroll pan without zooming, and no scroll ever selects a folder (\(selections) selections)")
}
