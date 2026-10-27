# Living Tree camera — interactive 2D exploration

Status, 2026-10-26: implemented; verified by model tests, headless controller tests and offscreen renders of an APFS clone of a 2.07M-node catalog. Uncommitted, not packaged or installed. No production database, LaunchAgent or installed app was touched; no full-volume scan was run; nothing was shown on screen. **Nothing was checked in a real window** (checklist in section 9). No 3D.

Evidence: `build/living-tree-camera/evidence/` (renders), `build/camera-pass/camera-bench.log` (measurements), `build/camera-pass/*.log` (test runs).

## 1. Files changed

| File | Change |
|---|---|
| `SourcesShared/LivingTreeCamera.swift` (new) | Pure camera model: transform, framing (fit), camera operations (zoom about a point, pan, pan limits, focus, reveal), smoothed motion, level of detail, projection, scale-aware hit testing entry points, collision-aware labels, pointer/scroll/pinch interpretation |
| `SourcesShared/LivingTree.swift` | Hit index: one scale-aware search (`nearest`) behind the old `hit(_:)` (unchanged results except the tip tie-break below); zoom-aware opacity; arranger absolute dead-band (1% of the parent's span) |
| `SourcesGUI/LivingTreeView.swift` | Controller: layout in a fixed space off the main thread, camera state and motion timer, per-trunk camera memory, fit extent with dead-band, label cache. View: projected drawing with culling, label layer, AppKit input layer, zoom controls, keyboard pan/zoom, context menu, accessibility zoom |
| `tests/LivingTreeTests.swift`, `tests/GUIModelTests.swift`, `scripts/test-gui.sh` | 30 camera, label and input tests |
| `tests/InventoryModelTests.swift` | 5 headless controller tests on a worker-built catalog |
| `scripts/camera-living-tree.swift`, `scripts/benchmark-living-tree-camera.sh` (new) | Offscreen renders and measurements on a `cp -c` clone under `/private/tmp` (removed on exit) |
| `scripts/render-living-tree.swift` | Updated to the camera API |

Atlas, Navigator, Inspector, search, the indexer, the worker, the schema, the change journal, the tree builder, arranger and geometer are unchanged.

## 2. Camera architecture

- **Fixed layout space.** Each tree is laid out once per rebuild at `LivingTreeCamera.layoutSize` (1400×900), together with its hit index, in the detached task that already arranged it. A position in that space names the same place in the tree through window resizes and incremental rebuilds, so the camera never has to be translated between layouts. (Before, geometry was laid out on the main thread for each canvas size.)
- **Framing.** `LivingTreeFraming` fits the tree's real extent (every branch, tip and tip light) into the canvas minus margins kept for labels (30 top, 22 sides, 12 bottom). It centres halfway between the extent and the trunk (balanced but space-efficient). When the canvas has width to spare, the crown is stretched sideways up to 1.3× (positions only; widths never stretch).
- **Camera.** `zoom` relative to the fit (0.5–32×) and the layout point at the framing's anchor; `nil` follows the fit, so an untouched view refits on resize. Positions scale fully; stroke widths and tip light scale with √scale, the same factor for every branch, so thickness still encodes size.
- **Fit stability.** The fit extent is kept across rebuilds of the same trunk while every edge stays within 3% (`stableExtent`): small journal updates never refit or shift the view.
- **Stability through rebuilds (two parts).** A rebuild could shift branches slightly: the arranger gives each sibling angular room half by bytes and half by elements drawn beneath it, so when a rebuild redistributes a few elements a small folder's room could cross its 15% dead-band, and sectors laid end to end nudged every later sibling (under 3 pt at the fit; up to 46 pt at 4× in measured runs). (1) The arranger now also keeps a remembered room or share whose change is under 1% of the parent's span (`absoluteDeadBand`), which stops those ripples at the source. (2) When the viewer has moved the camera, the controller records where up to 400 on-screen tips are before a rebuild and afterwards pans by the median of their movement: a shift shared by what is on screen is undone, while the few elements that really changed (a relisted folder re-shapes) do not move the view. An untouched (fitted) view is never adjusted.
- **Motion.** Animated moves (wheel steps, keys, fit, focus, reveal) are exponentially smoothed (τ = 70 ms): zoom geometric, centre exponential; a zoom about the pointer keeps that point exactly fixed throughout. Successive wheel steps accumulate from the target, so they blend into one movement. A main-run-loop timer runs only while the camera moves. Reduce Motion and direct manipulation (drag, trackpad pan, pinch) jump.
- **Pan limits.** At least 120 pt (or all, if smaller) of the tree's extent always stays on screen, at every zoom.
- **Per-level memory.** Leaving a trunk remembers its camera (last 6 trunks); returning (breadcrumb, Escape) restores it; a new trunk starts fitted. Reset View forgets them all.
- **Drawing.** The base canvas draws the projected geometry, skipping branches outside the canvas and deep branches shorter than 3 pt on screen (level of detail: they appear when zooming brings them out). Hover, selection and light stay on the overlay; labels have their own layer. Nothing redraws unless the tree, size or camera changes.
- **Hit testing.** Distances are measured on screen through the transform (tolerance 4 pt), so zooming makes targets more precise; elements left out by level of detail cannot be hit; neighbouring grid cells are searched when zoomed out. Where tips crowd, the nearest tip wins (previously the thinner one, which picked a neighbour in 107 of 404 sampled tips).

## 3. Interaction controls

| Input | Action |
|---|---|
| Trackpad two-finger scroll | Pan |
| Mouse wheel | Zoom about the pointer, animated (×1.2 per line) |
| ⌘- or ⌥-scroll (trackpad) | Zoom about the pointer, direct |
| Shift-wheel | Pan sideways |
| Pinch | Zoom about the pointer, direct |
| Smart zoom (two-finger double tap) | Zoom in 2.5× about the point, or back to the fit |
| Drag (more than 3 pt) | Pan (never selects; closed-hand cursor) |
| Click | Select (on release); Navigator and Inspector follow |
| Double-click folder or grouped items | Open as trunk (existing subtree navigation) |
| Double-click file; ⌥-double-click anything | Focus the camera on it |
| + / = and − | Zoom in / out about the centre |
| 0 | Reset View (fit, forget remembered views) |
| F | Focus the selection |
| ⌥ or Shift + arrows | Pan 14% of the canvas |
| Arrows, Return, Escape | Unchanged (move along branches, open, go up) |
| Controls (bottom right) | Zoom out, zoom % (click to fit), zoom in, Fit Tree, Focus Selection |
| Context menu | Zoom In, Zoom Out, Fit Tree, Focus Selection, Reset View |
| VoiceOver | Zoom value, zoom action, a Focus action on each accessible branch |

"Double-click branch to focus" and "double-click a folder preserves subtree navigation" conflict; folders keep navigation, focus is on files, ⌥-double-click, F and the Focus button.

Selection sync: a selection made in the Navigator (or by arrow keys) is brought on screen with the smallest animated pan (nothing moves if it is visible); a search result's "Show location" frames the result once per request.

## 4. Visual changes

- The fit fills the canvas: in a 1240×640 panel the tree covers 71% of the canvas (57% before); in tests 31→53%, 29→86%, 18→30%, 13→38% across four shapes.
- Labels: on dark plates, 11 pt semibold name (90% white) and 10 pt size; placed beside the limb for folders that fork (clear of the fork), beyond the tip for twigs and files; rejected where they would cover other branches (a thick limb counts three times a hairline) or other labels. 16 at the fit, more as you zoom (28 at 2×, up to 90); smaller branches become eligible (1.2% of the trunk at the fit, ÷ zoom²). Grouped items are labelled "N grouped items" at 2.5× and beyond, never as a file. The selection is always named, with an accent edge.
- Selection emphasis is quieter: path to the trunk at 34% white, the selection at 88% with a fine accent ring.
- Deeper structure fades less as you zoom in.

## 5. Tests

| Suite | Before | After |
|---|---|---|
| Viewer model (`scripts/test-gui.sh`) | 459 | 489 (+30); 505 with 3D |
| Headless inventory model (`scripts/test-inventory-model.sh`) | 22 | 28 (+6); 31 with 3D |
| Inventory (`scripts/test-inventory.sh`) | 345 | 345 |
| Monitor self-test | 233 | 233 |
| Viewer build | — | no errors or warnings |

New coverage: transforms and projection; fit (inside margins, reaches the limiting side, fills more than before, stretch limits, balance); zoom about the pointer (exact over a sequence) and zoom limits; pan limits at 0.5×, 1× and 8×; focus (framed, centred, limited) and reveal (no-op when visible, pan-only otherwise); resize (zoom and centre kept, untouched view refits); hit testing under 1–8× (404/404 tips), screen-point precision, level of detail, empty canvas; motion (anchored wheel zoom, exact arrival, monotone easing, jump); stability (a small change leaves every tip unmoved on screen at 4×; a real widening refits); labels (no overlaps, inside the view, clear of branches, budget, grouped wording, selection always named, Users › home once); input (click, drag threshold, drag never selects, double-click rules, scroll/wheel/pinch mapping). Controller (real catalog, no window): Reduce Motion jump and animated arrival, off-screen selection brought into view, a search reveal framed once, the zoom kept through a rebuild that refits the tree, nothing on screen moving after a small change elsewhere while zoomed in, per-level camera restore.

The headless inventory model suite needed `scripts/build.sh` first: the monitor in `build/` predated `inventory-work`.

## 6. Measurements

`scripts/benchmark-living-tree-camera.sh` on a clone of a 2.07M-node catalog, 3,000-element volume tree, canvas 1240×590 (log: `build/camera-pass/camera-bench.log`). Shared machine; indicative. "Model" is projection plus label placement when due; "with raster" adds drawing the base and label layers offscreen at 2×.

| Measure | Result |
|---|---|
| Fit | tree 970×548 pt, 72% of the canvas area (58% with the previous fixed crown) |
| Pan frame, 1× / 2× / 4× / 8× | model p50 0.04 ms (p95 5.7 / 4.9 / 1.9 / 0.6 ms, when labels are placed again); with raster p50 2.9 / 3.3 / 1.8 / 1.0 ms, p95 8.7 / 8.1 / 3.7 / 1.5 ms |
| Pinch frame (1.08× steps, 1–4.7×) | model p50 4.0 ms, p95 5.2 ms; with raster p50 6.8 ms, p95 8.3 ms |
| Animated wheel zoom (1.73×) | settles in 48 frames (0.40 s at 120 Hz); the point under the pointer moved 0.000 pt |
| Hit test (20,000 random points) | 1×: mean 0.5 µs, p99 6.9 µs; 4×: 0.2 / 1.1 µs; 16×: 0.2 / 1.1 µs. Every on-screen tip resolves to itself: 2,839/2,839 at 1×, 45/45 at 4× |
| Label placement (uncached) | 1×: 15 labels, 5.5 ms; 2×: 28, 4.0 ms; 4×: 13, 1.1 ms; 8×: 1, 0.5 ms; 0 overlaps |
| Resize (40 sizes) | refit + projection + labels p50 5.9 ms, max 8.8 ms; the fit reaches 0.99–1.00 of the limiting side; a 3× view through 20 resizes keeps its zoom and centre exactly |
| Journal update at 4× (6 folders elsewhere relisted, +8% each), 3 runs | rebuilt; 43–46 of 43–46 watched tips moved 0.00 pt in every run; the view hold was not needed (the arranger's absolute dead-band kept every sector) |
| Memory, 64 trunk changes (half of them zoomed) | bounded: +0.5 MB to +1.9 MB across runs (one run −17 MB as the system reclaimed memory); remembered cameras 6 (bound 6) |
| Idle 5 s after an animated zoom | 0.001 s CPU; no timer running |

Correction: an earlier version of this record reported "camera and transform unchanged; 45 of 45 tips unmoved". Repeat runs showed that depended on how the rebuild redistributed elements: some runs moved every watched tip 9–46 pt at 4× (camera unchanged, content shifted by the arranger's sector ripple). A first fix that pinned the single element nearest the centre was itself fragile (when that twig moved, it dragged the view). The final design is the arranger's absolute dead-band plus the median view hold (section 2); three consecutive runs then kept every watched tip in place, in 2D and in 3D. The harness also now positions the change feed and lets any rebuild that causes finish before recording "before".

A change to the viewed folder itself (+8% to the 98 GB home folder in an earlier run) legitimately widens its sector in the arranger and moves its subtree by about 4 pt at the fit; the camera still does not move. The existing benchmark (`scripts/benchmark-living-tree.sh`) runs unchanged on the new API: static draw p50 2.7 ms at 1400×860@2x, change stability 90.7% of tips unmoved, small change 3,000/3,000.

At 120 Hz the pinch path (labels placed again at each ~9% zoom step) is near the frame budget; at 60 Hz it fits. Real-window frame pacing was not measured.

## 7. Offscreen renders (`build/living-tree-camera/evidence/`, 2×)

`living-tree-camera-fit.png`, `-2x.png`, `-4x.png`, `-focused.png`, `-narrow.png` (640×640), `-wide.png` (1900×560), `-page.png` (full explorer, window never ordered in). Fit/zoom/focus renders are the tree panel at 1240×640.

## 8. Limitations

1. No real-window verification (section 9): trackpad and wheel feel, pinch, cursor, focus and key handling with the AppKit input layer, context menu, VoiceOver.
2. The scroll mapping is fixed (trackpad pans, wheel zooms); there is no preference.
3. The sideways stretch (≤1.3×) slightly flattens branch angles in wide views; widths and sizes are unaffected.
4. Labels are placed again when the zoom changes by more than ~9% or the view pans by more than 48 pt; between placements they stay attached to their tips and are not re-checked for collisions.
5. Level of detail hides only deep branches shorter than 3 pt; the element budget (about 3,000) is unchanged, so zooming in reveals what is already in the tree, not more of the catalog.
6. A cold first build on a large catalog can still stop at the read guard (existing limitation 2 in LIVING-TREE.md).

## 9. Real-window checklist (NOT VERIFIED)

- [ ] Trackpad: two-finger scroll pans, pinch zooms about the fingers, smart zoom toggles; momentum stops at the pan limit.
- [ ] Mouse: wheel zooms smoothly about the pointer; drag pans with a closed hand; a click without movement selects.
- [ ] Double-click a folder opens it; double-click a file focuses it; ⌥-double-click focuses a folder.
- [ ] Clicking the canvas gives it keyboard focus: + − 0 F, ⌥-arrows and plain arrows work; focus is not stolen from the Navigator otherwise.
- [ ] Controls and context menu work; zoom % updates.
- [ ] Navigator selection of an off-screen branch pans it into view; search "Show location" frames the result.
- [ ] Breadcrumb back restores the previous zoom; Reset View fits and forgets.
- [ ] Resizing the window or the divider keeps the zoom; an untouched tree refits.
- [ ] Reduce Motion: zoom steps and fit jump without animation.
- [ ] With the worker running, a journal update does not move the view.
- [ ] Activity Monitor shows the viewer idle after zooming stops.
- [ ] VoiceOver reads the zoom and offers Zoom/Focus actions.
