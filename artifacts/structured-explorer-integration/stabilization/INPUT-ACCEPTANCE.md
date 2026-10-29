# P1 — Wheel, trackpad, double-click and keyboard

> **Native update, 2026-10-29:** The authorized session is complete; full acceptance remains partial. See [native results](native-qa-20261029T172929/NATIVE-RESULTS.md) for measured outcomes, incomplete checks and verified cleanup. The original implementation-phase record below is retained. Automated suites were not rerun during native QA.

No physical device was used in this session. Every result below is headless (real `NSEvent`/`CGEvent` objects handed to the app's own AppKit view in-process, never posted to the system) or model-level, unless marked otherwise.

## Wheel and trackpad routing

Path: `LivingTreeInputView.scrollWheel` (AppKit, receives only events whose pointer is over the canvas) → `LivingTreeGesture.scroll` → `StructuredExplorerCamera.zoom/pan`, as the view applies them.

**Finding on "reverse scroll did not zoom out".** The camera's range is 40%–2400%, so 100% is not a floor. A pixel scroll zooms by `exp(dy × 0.012)`. The native run's 100% → 102% step corresponds to dy ≈ 1.65, and an equal reverse step gives 1.02 × 0.98 ≈ 0.9996, which displays as "100%". The native observation is consistent with working zoom-out from 102%. Headless end-to-end checks now prove both directions:

| Check (new, `tests/LivingTreeScrollRoutingTests.swift`) | Result |
|---|---|
| Line wheel forward ×2 → 1.44×; same reverse → exactly 1.00×; further reverse → 0.69×; the canvas point under the pointer stays fixed (< 0.01 pt) | PASS |
| Pixel (smooth mouse / Magic Mouse / trackpad vertical) forward → 1.43×, reverse → 1.00×; a momentum-phase event after the gesture does not zoom | PASS |
| Repeated wheel stops exactly at 2400% and at 40% | PASS |
| Sideways precise scroll, Shift-scroll and Option-scroll pan without zooming; no scroll event selects, opens or focuses a folder | PASS |
| Existing: line and pixel events in both directions route to animated/direct zoom; no wheel/pixel event orbits | PASS (retained) |

Natural-scrolling preference is respected because `scrollingDeltaX/Y` already carries the user's direction setting; the app does not re-invert it. No global event monitor exists. Scroll reaches the canvas only through its own `NSView`, so scrolling over the Inspector scrolls the Inspector. That last point is by construction and was inspected, not natively tested.

Pinch (`magnify`) → pointer-anchored zoom, and smart magnify → toggle zoom, are unchanged and covered by existing pure checks.

## Double-click

**Defect found and fixed** (`SourcesShared/LivingTreeCamera.swift`, `LivingTreeGesture`, shared with the classic fallback):

1. **Wrong adjacent folder.** The first click selects. Selecting re-places labels (the selection's label takes priority and others move) and can move the camera (`revealSelection`) before the second press arrives. The second press was hit-tested against that new geometry and could land on a neighbour's label. Now a double-click acts on what its first click selected, provided the second press is within 6 pt (`doubleClickSlop`). Otherwise it uses its own target.
2. **Navigation twice.** `down` opened on `clickCount >= 2`, so a triple click opened again, hit-testing the third press against the folder just opened. Now only `clickCount == 2` acts.

Regression test (`tests/LivingTreeTests.swift`): select folder 132 → second press on neighbour's label → opens 132; third press → nothing; a separate double-click elsewhere → opens its own target.
- Before the fix: **FAIL** (second opened 144/86/33 depending on fixture order; third opened again).
- After: **PASS**. The existing double-click semantics test (open folder, focus file, Option-focus) still passes.

Label and node identity: `StructuredExplorerLayout.hit` checks labels first and returns the label's own key. The existing label-interior hit test (horizontal and rotated, at fit and 4×) passes. Disc-centre hits at 1×, 4× and 12× pass.

## Keyboard (Return, Escape, Up, arrows)

Implementation (unchanged): the canvas is a SwiftUI `.focusable()` region. A click on it sets `@FocusState focused = true` (in `handle(.down)`). `.onKeyPress(.return)` opens the shown selection once via `browser.navigate`, Escape closes help or goes up, and Up/breadcrumbs navigate. A selection made in the Navigator or Search leaves focus there, so Return goes to that control, which respects intentional focus.

Native QA sent Return while a folder navigation was still pending, inside the 1.5–2.7 s window caused by the P0 throttle defect, so its result was indeterminate. With P0 fixed, that confound is gone. No code change was made to the key path because no defect was demonstrated.

**Not testable headlessly:** SwiftUI keyboard focus and `onKeyPress` dispatch in an unshown window. The same gating was demonstrated for SwiftUI hover; a key-window requirement applies to keyboard focus as well. **NOT VERIFIED.**

## Remaining physical-input gaps (native session required)

| Input | Status |
|---|---|
| Physical mouse wheel forward / reverse | NOT TESTED (headless both directions PASS) |
| Smooth-scrolling mouse | NOT TESTED (pixel path PASS) |
| Trackpad vertical scroll, sideways, inertia | NOT TESTED (pixel/momentum path PASS) |
| Trackpad pinch, smart magnify | NOT TESTED |
| Pointer-centred zoom near viewport edges | PARTIALLY VERIFIED (math PASS; native feel pending) |
| Double-click on node and on label, at 1× and zoomed | PARTIALLY VERIFIED (gesture + hit tests PASS) |
| Return after canvas click; Return with Search/Inspector focused | NOT VERIFIED |
| Escape / Up / breadcrumb | PARTIALLY VERIFIED (native Up passed earlier; navigation now fast) |
| Scroll over Inspector scrolls Inspector only | NOT TESTED (by construction) |
