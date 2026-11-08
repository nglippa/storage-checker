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
