# P0 — Monitoring chart hover callout

> **Native update, 2026-10-29:** The authorized session is complete; full acceptance remains partial. See [native results](native-qa-20261029T172929/NATIVE-RESULTS.md) for measured outcomes, incomplete checks and verified cleanup. The original implementation-phase record below is retained. Automated suites were not rerun during native QA.

Status: **IMPLEMENTATION COMPLETE, headless-verified through real AppKit events; native pointer delivery NOT VERIFIED.**

## Reproduction and what could, and could not, be established

The native session (`native-qa/NATIVE-RESULTS.md`) saw no callout during automated pointer attempts. Eight dwell crops were pixel-identical (no flicker), but the run recorded **no pointer coordinates** (`native-qa/results.json`). It therefore cannot show whether the pointer was within the 14 pt hit radius of a plotted reading. The native cause is **not established** from that evidence, and this record does not claim one.

What was established in this session:

1. **The hover path had no functional test.** `CapacityChartGeometryTests` set `hovered` through the `inspectHoverAt` seam in `onAppear`. No test ever sent a pointer through `onContinuousHover`, the reading hit test, the hover state or the callout overlay. The 16 geometry checks prove no plot resize and no point movement, which is what flicker requires, but cannot notice a callout that never appears.
2. **SwiftUI hover cannot be exercised headlessly.** A probe (scratch only) hosted an `onContinuousHover` view in an offscreen, never-ordered-front window under `.prohibited` activation. It delivered synthetic `mouseMoved`/`mouseEntered` events by `window.sendEvent` and directly to the tracking-area owner (`NSHostingView`, options 0x283). The events resolved to the window (`event.window != nil`) and hit-tested to the hosting view, yet **no hover phase was ever called** (window `isVisible == false`). Driving SwiftUI hover would require showing a window, which AGENTS.md forbids without approval.
3. **The hover callout lacked change information** required by the acceptance criteria. It showed only time and available space.
4. **A callout edge defect.** The new visibility test found the first reading's callout drawn 6 pt outside the chart's left edge (`x = -6`): the rightward callout's offset was `anchor.x - 6` without a clamp.

## Corrective change (`SourcesGUI/OverviewView.swift`)

- **Pointer delivery.** `onContinuousHover` is replaced by `ChartPointerLayer`, an `NSViewRepresentable` whose `ChartPointerView` owns an `NSTrackingArea` (`.mouseMoved`, `.mouseEnteredAndExited`, `.activeInActiveApp`, `.inVisibleRect`). `hitTest` returns `nil` and the layer has `.allowsHitTesting(false)`, so clicks still reach the chart's `SpatialTapGesture`, and the `.help` tooltip is unaffected. This is the same AppKit tracking pattern as the Living Tree input layer. It makes the full path (real `NSEvent` → coordinate conversion → reading → state → callout) testable without showing a window, and removes the dependency on SwiftUI hover gating. Whether SwiftUI hover was the native failure is unknown; this change makes delivery deterministic either way.
- **Resolution.** `CapacityChartHover.nearest` is a pure function with the same semantics as before: the nearest drawn point within 14 pt, otherwise none. State changes only when the hovered reading changes, as in the flicker fix.
- **Callout text.** `CapacityChartHover.describe` gives *date · N available · ±change since previous reading*. The change is against the previous reading in the same joined segment and is omitted at a segment start, so it never compares across a gap or a container change.
- **Edges.** The callout's horizontal frame and offset are clamped to the chart bounds.
- **Flicker fix kept.** The callout remains in the overlay, outside the chart's layout; no `.annotation` was reintroduced, and no delay was added.

## Tests (`scripts/test-chart-geometry.sh` → `tests/CapacityChartGeometryTests.swift`)

The original **16/16 geometry checks are retained and pass.** New checks host the real `CapacityChart` offscreen at 640 pt compact light, 1100 pt regular dark and 1000 pt regular light. They find its `ChartPointerView` and deliver real `NSEvent` mouse moves (and a `mouseExited`) to it:

- a pointer 3–4 pt from **each of 47 readings**, including the last third, hovers that reading and draws its callout;
- every callout frame (reported from the drawn view in the overlay's coordinate space) is inside the chart, near both edges;
- a second move on the same reading leaves hover and callout frame unchanged, and the plot frame never changes;
- a point in empty plot (top of the plot, midway between readings, > 14 pt from every reading) shows no callout, and leaving the chart dismisses it;
- the callout text contains time, available space and the change since the previous reading, and the first reading has no change.

Results: before the edge clamp, the visibility check **failed** in all three configurations (callout at `x = -6`); after it, all pass. The final count is in `REGRESSION-RESULTS.md`.

Selected-event callouts keep their existing path and still yield to hover.

## Remaining native checks

The real pointer (physical mouse and trackpad) over the 30-day chart, including the last third, at the minimum and a normal window size, in light and dark. Expected: the callout appears within one move of reaching a reading, holds while dwelling, never resizes the plot, clears over empty plot and on exit, and a click still opens the reading's event. The native run must log pointer coordinates against reading positions so a miss can be attributed.
