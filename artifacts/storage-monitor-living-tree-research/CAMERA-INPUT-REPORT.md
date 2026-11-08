# Living Tree camera input — report

Status: **fixed; mapping and AppKit routing verified headlessly. Real mouse, Magic Mouse and trackpad feel NOT VERIFIED** (see the native verification section).

## Existing event routing

1. `LivingTreeInputView` (`SourcesGUI/LivingTreeView.swift`) is an `NSView` layered over the tree canvas through `LivingTreeInputLayer`. It overrides `scrollWheel(with:)`, `magnify`, `smartMagnify`, `rotate` and the mouse methods, and doesn't call `super`, so scroll events over the canvas stop there. Scroll events over the inspector, Navigator or other panels never reach it; those panels keep scrolling normally. There is no other scroll or magnify handler on the canvas, so nothing is handled twice.
2. `scrollWheel` passed `scrollingDeltaX/Y`, `hasPreciseScrollingDeltas` and the modifiers to `LivingTreeView.handle`, which called `LivingTreeGesture.scroll(...)` (`SourcesShared/LivingTreeCamera.swift`).
3. The old `LivingTreeGesture.scroll` treated **`precise == true` as "trackpad"**: unmodified scrolling **panned in 2D and orbited in 3D**. Only line-stepped (`precise == false`) wheels zoomed.

**Root cause.** `hasPreciseScrollingDeltas` is also true for a Magic Mouse and for high-resolution or smooth-scrolling mice, such as Logitech MX with Logi Options+ smooth scrolling. AppKit gives no reliable device type. On a Mac mini with no built-in trackpad, an ordinary mouse wheel can therefore move or turn the camera instead of zooming, which matches the report. (The exact device on the Mac mini was not inspected; this is the only code path that turns a wheel into camera movement.)

## Corrected behaviour

| Input | 2D | 3D |
|---|---|---|
| Mouse wheel (line steps) | Zoom about the pointer, animated, ×1.2 per line | same |
| Pixel scrolling (trackpad, Magic Mouse, smooth mice), mostly vertical | Zoom about the pointer, direct, `exp(0.012·dy)` | same, **never orbits** |
| Pixel scrolling, mostly sideways | Pan horizontally | Pan horizontally |
| Momentum after the fingers lift | Pans continue; zoom ignores momentum (no drifting zoom) | same |
| ⇧- or ⌥-scroll | Pan (a wheel pans sideways) | Pan |
| ⌘-scroll | Zoom (as before) | Zoom |
| Pinch | Zoom about the fingers, direct (unchanged) | same |
| Smart zoom | 2.5× or back to the fit (unchanged) | same |
| Click / drag / double-click | Select on release / pan, never selects / explore (unchanged) | select / orbit / explore |
| Trackpad rotation, ⌘-arrows | — | Turn (unchanged) |
| Fit, Reset, Up, keyboard | Unchanged | Unchanged |

- **Zoom direction.** Scrolling with dy > 0 zooms in on every device, the same sign the line wheel always used. Both follow the system's natural-scrolling setting, so wheel and trackpad agree.
- **Zoom limits.** Unchanged: 0.5–32× of the fit.
- **Folder selection.** A camera move never changes the selection. A unit test checks that no scroll input produces `.select`, `.open` or `.focus`.

**Files.**
- `SourcesShared/LivingTreeCamera.swift`: `LivingTreeGesture.scroll` takes `momentum:` instead of `orbits:`; `scrollOrbitRate` is removed.
- `SourcesGUI/LivingTreeView.swift`: `Event.scroll` carries `momentum` from `!event.momentumPhase.isEmpty`; the Help rows now describe the new mapping.
- `LIVING-TREE-CAMERA.md`, `LIVING-TREE-3D.md`: input tables and checklists updated.

## Tests

- `tests/LivingTreeTests.swift` (in `scripts/test-gui.sh`):
  - The mapping test is rewritten to the new contract.
  - The 3D input test no longer expects scroll-to-orbit.
  - A new regression covers 80 combinations of precise, wheel, momentum, five modifier sets and four deltas: none orbits or selects, and a small precise vertical scroll zooms.
- `tests/LivingTreeScrollRoutingTests.swift` (in `scripts/test-chart-geometry.sh`): the AppKit edge. It builds **real `NSEvent` scroll events from `CGEvent`** in-process and calls `LivingTreeInputView.scrollWheel` directly. The events are never posted to the system, so the desktop is untouched. It checks that:
  - line units zoom in and out, animated;
  - pixel units zoom in and out, direct;
  - Shift-scroll pans;
  - 0 of 8 line or pixel events orbit.

Results are in `verification/SUMMARY.txt` and the per-suite logs.

## Native verification

**NOT VERIFIED.** AGENTS.md (desktop safety rules 1, 2 and 8) forbids focusing windows or sending pointer or scroll input to the desktop without explicit permission. Synthetic `NSEvent`s prove the routing and interpretation, but not how a physical wheel or trackpad feels. To verify, about 2 minutes with the dev viewer, or the showcase app on a copied catalog, in front:

- [ ] Mouse wheel over the tree zooms in and out about the pointer in 2D and 3D, and never turns the 3D tree.
- [ ] The Mac mini's actual mouse (Magic Mouse or a smooth-scrolling mouse) zooms rather than pans.
- [ ] Trackpad (if any): two-finger vertical scroll zooms, a sideways swipe pans, pinch zooms, momentum doesn't keep zooming.
- [ ] Scrolling the Inspector or Navigator next to the tree scrolls those panels.
- [ ] Drag pans (2D) or turns (3D); a drag that starts on a label never selects.

The trade-off: trackpad users lose "two-finger scroll pans" without a modifier. They pan with drag, ⇧-scroll or a sideways swipe. The brief says wheel movement must never unintentionally move the camera, and a trackpad can't be told apart from a Magic Mouse, so the conservative mapping is the correct one.
