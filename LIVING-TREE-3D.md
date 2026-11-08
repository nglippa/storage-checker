# Living Tree 3D — orbiting the tree

Status, 2026-10-26: implemented as an opt-in mode (the 3D/2D button in the tree's controls, remembered; 2D stays the default). Verified by model tests, headless controller tests and offscreen renders of an APFS clone of a 2.07M-node catalog. Uncommitted, not packaged or installed; nothing production was touched; nothing was shown on screen. **Not checked in a real window** (section 7). Builds on `LIVING-TREE-CAMERA.md`.

Evidence: `build/living-tree-camera/evidence/living-tree-3d*.png`, `build/camera-pass/camera-bench.log`.

## 1. Approach

The tree is still the same tree (elements, sizes, the arranger's stable sibling order and sectors, hysteresis). In 3D it grows as an upright dome around the trunk instead of a fan in a plane:

- **Directions around the trunk.** Each element's 2D sector angle (±79°) becomes an azimuth around the trunk (almost a full turn), after the 2D geometer's narrowing of deep sectors. Sectors stay nested, so each top-level subtree keeps its own range of directions; nothing interleaves.
- **Up and out.** Depth sets the lean from vertical (about 30° for top-level folders, about 60° for the deepest twigs), so the crown is an upright vase and twigs never hang below their forks. Heavy children keep close to their parent's lean (Users › home continues upward). The lean uses the arranger's smoothed share, so a small measured change moves nothing.
- **Same widths.** Every branch has exactly its 2D width (√ of its share of the trunk); unknown sizes stay marked hairlines; tips, tufts and states are unchanged.
- **Built once.** The dome is laid out in the same off-main-thread task as the 2D layout (~10 ms for 3,000 elements), so switching is instant.

Each frame the dome is **projected** for an orbit (yaw around the trunk, pitch above the horizon, −11° to 77°) onto a picture plane with mild perspective (the near side about 25% larger than the far side), far branches first and up to 40% dimmer with distance. The projection is an ordinary 2D tree geometry, so the 2D painter, hit testing, labels, level of detail and the whole 2D camera (zoom about the pointer, pan, pan limits, focus, reveal, smoothed motion) apply unchanged. Where branches overlap on screen, the nearer one is hit.

**Fit.** The fit frames the union of the tree's projected extent over a full turn at the current pitch: turning never changes the zoom and never clips the tree. It changes only with pitch (a tree seen from above is a disc).

## 2. Controls (3D)

| Input | Action |
|---|---|
| Drag | Turn the tree (yaw and pitch) |
| Shift- or Option-drag, ⇧- or ⌥-scroll | Pan (scrolling never turns the tree) |
| Trackpad rotation | Turn about the trunk |
| ⌘-arrows | Turn 20° / tilt 10°, animated |
| Wheel, trackpad or mouse scroll, pinch, +/−, smart zoom | Zoom, as in 2D |
| F, Option-double-click, double-click a file, Focus button | Turn the element side-on (to the nearer side, 20° toward the viewer) and frame it |
| 0 / Reset View | Fit, standard orientation, forget remembered views |
| Everything else | As in 2D (click selects, double-click opens a folder, arrows, Return, Escape) |

2D and 3D keep their own camera per folder. Through journal rebuilds the element at the centre of a moved view stays in place on screen in 3D as in 2D (`LIVING-TREE-CAMERA.md`, view hold), and the orbit never changes. Reduce Motion: key turns and focus jump; dragging is direct in both. While the tree is being turned by hand, labels stay attached to their tips and are placed again 0.15 s after turning stops.

## 3. Files

| File | Change |
|---|---|
| `SourcesShared/LivingTree3D.swift` (new) | Dimension, dome layout, orbit, projection (depth order, shading, perspective), yaw-independent fit extent, orbit motion |
| `SourcesShared/LivingTree.swift` | `Branch.shade` (1 in 2D); hit testing prefers the nearer branch; `Placement.share` (the smoothed share); arranger absolute dead-band (found through 3D stability measurements; applies to 2D too) |
| `SourcesShared/LivingTreeCamera.swift` | Orbit gesture actions (drag, trackpad rotation); projection carries shade |
| `SourcesGUI/LivingTreeView.swift` | Controller: dome, orbit state and motion, per-dimension cameras, plane geometry and lazy hit index, label deferral while turning. View: 3D/2D control, ⌘-arrows, rotation, hints, depth shading |
| `tests/LivingTreeTests.swift`, `tests/InventoryModelTests.swift`, `tests/GUIModelTests.swift`, `scripts/test-gui.sh` | 15 model tests, 3 controller tests |
| `scripts/camera-living-tree.swift` | 3D renders and measurements |

## 4. Tests

| Suite | Before 3D | After |
|---|---|---|
| Viewer model | 489 | 505 (+16) |
| Headless inventory model | 28 | 31 (+3) |
| Inventory | 345 | 345 |
| Monitor self-test | 233 | 233 |
| Viewer and monitor builds | — | no errors or warnings |

Coverage: the dome holds every element once and is deterministic; widths equal 2D; the trunk is vertical and every tip grows up and out (≤ ~66° from vertical, above ground); top-level subtrees keep separate directions; projection (pivot plane, perspective, yaw); far-to-near order and shading; turning to an element brings it to the front; focus turns a branch side-on by the smaller turn; the fit frames the tree at 3 pitches × 36 yaws; pitch limits and short-way yaw; orbit motion and jump; hit testing at 3 orbits × 3× zoom (147/147 tips); nearer branch wins; drag turns, Shift-drag pans, rotation turns; labels in 3 orientations (inside, no overlaps); a small change leaves the dome exactly in place. Controller (real catalog): dome ready with the tree; drag turns at once; Reduce Motion jumps; animated turns glide and stop; 2D and 3D keep separate cameras; focus turns the element side-on and frames it.

## 5. Measurements

`scripts/benchmark-living-tree-camera.sh`, same clone and canvas as the 2D camera measurements (1240×590, 3,000 elements). Indicative (shared machine).

| Measure | Result |
|---|---|
| Dome layout (off the main thread, with the 2D layout) | 3–13 ms |
| Projection for one orbit | p50 0.6–0.7 ms, p95 0.8–1.6 ms |
| Hit index for a new orbit (built on first hover or click after turning) | 1.6–1.9 ms |
| Fit extent over a full turn (per pitch step) | 0.8–1.2 ms |
| Turn frame (dragging, 0.02 rad steps) | model p50 2.3 ms, p95 2.9 ms; with raster @2x p50 5.2 ms, p95 5.8 ms (labels deferred while turning; p95 was 14.7 ms before) |
| Full turn at the fit (72 yaws) | 1 fit scale, 0 clipped views |
| Hit test at the fit | 2,969 of 2,969 on-screen tips resolve to themselves; mean 5 µs |
| Labels at the fit | 9–11 placed, about 15 ms (when turning stops) |
| Animated turn (20°) | settles in 56 frames |
| Journal update at 2× (4 folders elsewhere relisted), 3 runs | orbit and camera kept; 895–902 of 895–902 watched tips unmoved in every run (one earlier run, before the arranger's absolute dead-band, moved most tips up to 27 pt) |
| Idle 5 s after an animated turn | 0.002 s CPU; no timer running |

## 6. Limitations

1. Not checked in a real window (section 7), including how dragging to turn feels and whether the depth reads well on a real display.
2. The perspective is applied to curve control points: curves are very close to, not exactly, the perspective image of the 3D curves (invisible at this field of view).
3. Overlap in 3D makes the crown denser on screen than in 2D; fewer labels fit at the fit (about 11 vs 15) and label placement costs more (about 13 ms, deferred while turning).
4. Panning is in screen space: a panned view turns about the trunk, so the point at the centre drifts while turning; Focus re-centres.
5. No lighting or shadows: depth is conveyed by order, perspective and shading only. No GPU renderer; Canvas draws the projected tree (about 5 ms per turn frame at 2×).
6. Accessibility in 3D is the same element list as 2D; spatial position is not spoken.

## 7. Real-window checklist (NOT VERIFIED)

- [ ] 3D/2D button switches with a short cross-fade and is remembered.
- [ ] Dragging turns smoothly; Shift-drag and ⇧-scroll pan; scrolling (wheel or trackpad) zooms and never turns; trackpad rotation turns; pinch zooms about the fingers.
- [ ] ⌘-arrows turn; Reduce Motion makes them jump.
- [ ] F / Option-double-click turns the selection to the front and frames it.
- [ ] Hover and click hit the nearer branch where branches cross.
- [ ] Labels reappear correctly shortly after turning stops.
- [ ] Turning never changes the zoom or clips the tree.
- [ ] Activity Monitor shows the viewer idle when not turning.
