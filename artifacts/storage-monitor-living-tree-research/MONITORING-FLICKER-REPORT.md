# Monitoring chart hover flicker — report

Branch `research/living-tree-prototypes` (worktree `~/storage-checker-lt-research`, from `873e069`). Status: **root cause demonstrated; fixed; regression test passes 16/16 headlessly. Real-pointer verification NOT VERIFIED** (needs a focused window; see the end of this report).

## Reproduction

The real `CapacityChart` (`SourcesGUI/OverviewView.swift`) was hosted offscreen: an `NSHostingView` in a borderless window that is never ordered in, in a process with activation policy `.prohibited`. The fixture had 47 half-hourly readings over 24 h, reaching the top of the y-domain and both x edges, with ≥ 1 GB jumps. The test set the chart to "hovering reading N" for every reading and recorded the plot frame and the on-screen position of every point after layout. It ran at 640 pt and 1100 pt, compact and regular, light and dark, with and without a selected event.

**Interaction sequence that triggers it:** move the pointer onto a reading near the **right side of the plot**. At 1100 pt that was readings #39–47, the last ~4.5 h. At 640 pt it was readings #32–47, about the last third.

| | Before (`873e069` + inert seams) | After |
|---|---|---|
| Plot frame changed by hovering | 0 of 47 (every configuration) | 0 of 47 |
| Hovered point moved out from under the pointer (14 pt hit radius) | **16/47 at 640 pt, 9/47 at 1100 pt**, every appearance, with or without a selection | **0/47** |
| Checks passed | 8 of 16 | 16 of 16 |

Logs: `verification/chart-geometry-BEFORE.log`, `verification/chart-geometry-AFTER.log`. Images: `monitoring-evidence/`:
- `before-1100-no-hover.png` vs `before-1100-hover-reading-42.png`: the whole trace compresses leftwards and the x-axis ticks change from 06/09/12/… to 09/15/21/03.
- `after-1100-hover-reading-42.png`: the axis is unchanged, and the callout flips to the left of the point.

## Root cause

The hover tooltip and the selected-event label were Swift Charts `.annotation`s attached to marks inside the `Chart`. An annotation that would overflow the plot is resolved by the default `AnnotationOverflowResolution.automatic`. The SDK interface also exposes `.padScale`, `.fit(to:)` and `.disabled`. On the right side of the plot, the leading-aligned hover annotation made Charts **pad the x scale** to fit it. The plot frame stays the same size, but every point is re-projected, so the hovered point slides left, away from the pointer. Then:

1. `onContinuousHover` hit-tests against the new positions and finds nothing within 14 pt, so `hovered = nil`.
2. The annotation disappears, so the scale returns and the point slides back under the pointer.
3. The next mouse-moved event hovers it again, and the cycle repeats.

That is the reported truncate/expand/flicker. It only happens where the label overflows, which is why it appeared only "at particular locations". The selected-event label had the same coupling: its content went empty while hovering. The first version of the probe compared only the plot frame and passed. The bug is in the scale, not the frame, which is why the final test compares point positions.

## Change (`SourcesGUI/OverviewView.swift`)

- Both labels moved out of the chart into the existing `chartOverlay` layer as a `ChartCallout`. The overlay cannot change the chart's scales or layout. The callout is anchored to the point through `ChartProxy`, extends away from the nearer horizontal edge, sits above the point unless that would leave the top, has hit testing off and is hidden from accessibility. It needs no measurement, so it can't feed back.
- `hovered` is assigned only when the hovered reading's identity changes, not on every mouse-moved event.
- The hover marks (the rule and the larger point) stay in the chart. They use values already inside the domain, so they can't rescale it.
- No delays or debouncing were added.
- Two test seams were added: `inspectHoverAt` and `onPlotLayout`. They default to nil, are unused by the app and are documented in place.

## Regression test

`scripts/test-chart-geometry.sh` → `tests/CapacityChartGeometryTests.swift`. It hosts the real chart and asserts that, for every reading and every configuration above, the plot frame is unchanged and the hovered reading stays under the pointer after the hover's own layout. It fails on the old code (8/16) and passes on the fix (16/16). Set `CHART_GEOMETRY_SNAPSHOTS=<folder>` to write a PNG of every hosted layout.

## Acceptance

| Criterion | Status |
|---|---|
| No chart-height oscillation; plot frame stable | VERIFIED (headless, 4 sizes × 2 appearances × selection) |
| No selection changes from shifting hit regions; no enter/exit oscillation | VERIFIED (headless geometry) |
| Tooltip doesn't move layout; labels inside the chart at edges | VERIFIED (geometry and renders) |
| Chart ↔ event list synchronisation preserved | PARTIALLY VERIFIED: the tap path is unchanged and the viewer model tests pass; not exercised by a real click |
| Minimum and normal window sizes; light and dark | VERIFIED headlessly at 640 and 1100 pt |
| Smooth real-pointer movement across the whole chart | **NOT VERIFIED.** AGENTS.md forbids moving the user's pointer or focusing a window without permission. It needs about 1 minute with the dev viewer window in front. |
