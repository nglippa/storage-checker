> **Release follow-up, 2026-10-29:** Commit, local merge to master and 2.2.0 packaging are now authorized. See [the release record](../../STORAGE-MONITOR-2.2.0-RELEASE.md) for current verification and package status. The implementation-phase record below is historical; incomplete native acceptance remains documented.

> **2.2.0 release integration, 2026-10-29:** This work is now authorized for commit, merge to master and DMG packaging. The stabilization fixes and [latest native acceptance](stabilization/native-qa-20261029T172929/NATIVE-RESULTS.md) supersede the initial native-session findings below. Full native acceptance remains partial; see [the 2.2.0 release record](../../STORAGE-MONITOR-2.2.0-RELEASE.md). Earlier milestone/authorization statements are historical. Generated screenshots, logs, databases, preferences and other raw QA artifacts are retained locally and are not part of the source commit.

> **Native QA update, 2026-10-29:** the explicitly authorized session is complete (9m32.94s). QA PID 63381 is closed and QA preferences are restored exactly. Native acceptance is **BLOCKED** by delayed hierarchy replacement and incomplete hover/gesture/targeting verification. See [actual native results and the seven-check acceptance matrix](native-qa/NATIVE-RESULTS.md). Earlier headless-only statements below describe the pre-authorization phase; they are not the final native status.

# Prototype B — Structured Explorer integration

Implementation is available for review in `~/storage-checker-structured-explorer`, branch `integration/structured-explorer`, based on protected commit `873e069dc88788d24d620b4f9f6ff1904ea52f6a`. No commit, merge, push, package, installation or public release is authorized or performed. Native acceptance is blocked by the findings in the native QA update above; headless success does not complete that requirement. The launch record is in `verification/native-review-ready.json`; the authorized session used and closed the app, and its disposable catalog was removed after verification.

## Integration architecture

`InventoryBrowserModel` retains the existing `InventoryExplorerController` and `LivingTreeController`. Structured Explorer consumes that controller's bounded `LivingTreeModel`; it adds no catalog schema, duplicate catalog, independent filesystem scanner or cleanup pipeline.

- `SourcesShared/StructuredExplorer.swift`: platform-independent radial tidy layout, documented size scale, level limits, deep-selection spurs, labels, hit testing, keyboard movement and camera math.
- `SourcesGUI/StructuredExplorerView.swift`: SwiftUI Canvas painter and native AppKit input layer, shared explorer selection/navigation, controls, accessibility descriptions/actions, and retained camera/layout state.
- `SourcesGUI/InventoryView.swift`: one lazy `StructuredExplorerState` owned by the existing browser, retaining the camera through visualization changes.
- `SourcesGUI/InventoryExplorerView.swift`: Structured Explorer renders the Living Tree by default; classic remains behind `inventory.livingTree.renderer=classic`. The initial visualization is Living Tree when no saved visualization exists; an existing explicit Atlas preference remains respected.

Folder clicks call the existing shared selection controller, and folder exploration calls `InventoryBrowserModel.navigate`. Navigator and Inspector consume the same selected folder. Grouped remainder selection keeps the existing folder/group focus semantics and can expose the full folder in Navigator. External selections are mapped through the existing model; a deeper modeled item stays visible on a dashed, explicitly counted spur. Exploring still makes that folder the centre.

The existing controller handles journal refresh, bounded catalog reads, category colouring and data freshness. Layout is cached separately for the ordinary visible hierarchy and for a retained hidden/deep selection, so selecting an ordinary folder does not rebuild it, and a no-longer-selected deep spur disappears. The previous rendered root is retained for recenter transitions even if SwiftUI draws the new root before the transition callback. No continuous force simulation or new polling timer was introduced.

## Prototype components reused

The implementation promotes the actual selected `Prototypes/LivingTree/StructuredExplorer.swift`: the d3-hierarchy/Buchheim radial tidy arrangement, largest-first sibling order, concentric levels, radial cubic links, proportional discs, parent-share arcs, bounded levels, per-folder visible limit and rotated outer labels. Prototype A is not integrated. Research prototypes/showcase files are carried forward intact as reference files and are outside the application source globs.

Production refinements reuse the application's existing category colouring, size/status text, input interpreter, explorer controller, Inspector, Navigator, preference domain routing and AtlasZoom transition machinery. The translated d3 algorithm carries attribution and the complete ISC notice in `THIRD-PARTY-NOTICES.md`. Development and future packaging scripts copy that notice into app resources; the packaging script was syntax-checked but not executed.

## Visual and interaction refinements

- Disc **area** follows indexed allocation above minimum-visible sizes; link width follows the square root of allocation with bounded minimum/screen widths. Arcs show the fraction of the actual modeled parent. This is not a reclaimable-space estimate.
- Every ring is a level below the current folder. A deep external selection uses a dashed spur with a skipped-level count instead of presenting an invented direct parent relationship.
- Levels are bounded to 1–6, default 3; each folder shows its largest 14 modeled children, retaining a selection when necessary. `+N` counts hidden direct modeled children, not recursive file count or bytes. Existing grouped remainders retain their distinct semantics.
- First-ring labels try four positions; major first-level folders retain label priority even at high depth. Selection/hover labels stay inside the viewport and cannot overlap other labels. Ordinary labels avoid discs and sampled heavy-link geometry; when no geometry-clear position exists a selection, hover or major-folder priority label may cover underlying geometry while still respecting label collisions. Offscreen nodes do not leave orphan labels.
- Repeated names include the parent name; long names are middle-truncated, with full paths in Inspector and spoken descriptions. Horizontal and rotated label interiors are actual hit targets.
- Small collapsed-folder markers use quiet ticks until the count is readable. Ring captions use the widest empty arc. Size-key circles share one bounded scale, preserving their relative areas at high zoom.
- The rendering adapts to light/dark appearance; the old classic fallback deliberately keeps its existing dark canvas. Navigation help and tooltips explain click, exploration, zoom, pan, levels and framing.

| Input | Implemented behavior | Evidence boundary |
|---|---|---|
| Click disc/label | Select through shared explorer; Inspector/Navigator follow | Model, hit-test, offscreen production-handler and render evidence |
| Drag | Pan after the existing drag threshold; never select on release after dragging | Pure gesture and hosted production-handler checks |
| Line wheel | Zoom about pointer, using bounded wheel increments | AppKit synthetic NSEvents, pure gesture matrix, hosted handler |
| Pixel wheel / smooth mouse / trackpad vertical scroll | Direct pointer-anchored zoom; zoom momentum ignored | Synthetic/pure/hosted checks; physical device feel pending |
| Shift/Option scroll; mostly sideways precise scroll | Pan; no orbiting | Gesture matrix/AppKit routing |
| Pinch / smart magnify | Pointer-anchored zoom / toggle zoom | Pinch hosted; smart-magnify route inspected, physical behavior pending |
| Double-click / Explore Folder | Use application folder navigation and recenter | Double-click hosted, direct navigation measurements, renders |
| Return / Escape / Up / breadcrumb | Explore / enclosing folder | Implemented and inspected; native keyboard/control acceptance pending |
| Arrow keys | Up to largest shown child, down to parent, left/right among siblings | Movement model tests; native keyboard routing pending |
| Modified arrows; +/-; F; 0 | Pan; zoom; frame selection; reset | Math/reset hosted; native shortcut routing pending |
| Reduce Motion | Recenter uses a cross-fade rather than spatial zoom | Source/state review only; real animation pending |

## Monitoring and wheel fixes preserved

The integration copies of `SourcesGUI/OverviewView.swift`, `SourcesShared/LivingTreeCamera.swift` and `SourcesGUI/LivingTreeView.swift` compare byte-for-byte equal to the research checkout. The chart callout is drawn in an overlay, avoiding Charts annotation-driven scale padding. Hover state changes only when the reading changes. The selected-event callout remains supported.

The wheel fix preserves the distinction between line/pixel animation while refusing to treat precise deltas as proof of a trackpad. Vertical scrolling zooms in both renderers; Shift/Option and sideways precise scrolling pan. Momentum flags reach the gesture interpreter. The classic fallback keeps these repairs.

## Verification

Final counts and measurements are recorded below. Commands use the integration worktree's `build/`, isolated fixtures, and APFS clones of the preserved verification catalog. No production catalog is opened by the benchmark. Its disposable clone may clear reconciliation queues; the preserved source is not modified.

Native desktop checks are recorded in `native-qa/NATIVE-RESULTS.md`; some passed and the overall acceptance is BLOCKED. See `NATIVE-QA.md` for remaining unverified checks. Browser verification is not applicable to this native macOS application; the actual SwiftUI/AppKit hierarchy is rendered offscreen instead.

### Accessibility

The canvas supplies a named hierarchy group, level/zoom state, spoken size/status/share/path descriptions, selected/button traits, selection/Explore/Up actions and zoom actions. Keyboard navigation is specified in the hint and exercised at the model level. The virtual canvas tree is bounded to 160 children plus the current selection; Navigator remains available for all other items. Hierarchy, ring position, filled/file/dashed/grouped shapes, selection outline and text carry information beyond colour alone.

VoiceOver traversal/action delivery, contrast in accessibility modes, larger system text, localization/RTL and real keyboard focus are **NOT VERIFIED**. No accessibility tree count from an invisible window is presented as VoiceOver acceptance.

## Requirement classification

`PARTIALLY VERIFIED` means implemented with useful evidence but still requiring the listed native/target check. `NOT TESTED` is not a pass. No requirement was removed because desktop testing was unsafe.

| Major requirement | Status | Evidence / remaining work |
|---|---|---|
| 1. Integrate selected Prototype B | VERIFIED | Actual tidy-tree algorithm and visual encodings promoted into application source |
| 2. Structured Explorer is the default hierarchy | VERIFIED | Default initial visualization is tree; absent/unknown renderer selects structured; explicit saved Atlas choice respected |
| 3. Existing inventory remains source of truth | VERIFIED | Same controller/model and shared reader; no schema/scanner changes |
| 4. Selection synchronizes with Inspector/Navigator | VERIFIED | Native Users/Applications selections matched canvas, Navigator and Inspector; see native QA evidence |
| 5. Relationships and storage sizes are clear | PARTIALLY VERIFIED | Parent/ring/order/scale/accounting tests and render review; human interpretation/native review pending |
| 6. Readable, collision-managed labels | PARTIALLY VERIFIED | Label-plate tests pass; native minimum-window ring captions crowd/overlap (NQ-2); larger text/RTL unverified |
| 7. Mouse wheel zoom works | PARTIALLY VERIFIED | Native scroll-in changed 100% to 102%; reverse attempt showed 100%; physical wheel/trackpad and pinch still unverified |
| 8. Pan/click/double-click/recenter predictable | PARTIALLY VERIFIED | Native pan/Fit/Reset/Up passed; precise double-click targeting and Return need controlled retest; hierarchy replacement delay observed |
| 9. Monitoring flicker eliminated | BLOCKED | Headless geometry passes, but native hover callout was not observed; stable non-hover dwell is not a flicker pass |
| 10. Cleanup safety unchanged | VERIFIED | Cleanup sources unchanged; viewer safety, inventory and browser regressions pass |
| 11. Established V2 performance | BLOCKED | Native first frames 43–77 ms, but tree-read completion lagged navigation 1.52–2.72 s in the tested pending-reconciliation state |
| 12. Accessibility preserved/improved | PARTIALLY VERIFIED | Virtual descriptions/actions and keyboard movement implemented; VoiceOver, focus and display-mode checks pending |
| 13. Prior tree reversible fallback | VERIFIED | Classic retained with both fixes; native fallback and return to Structured Explorer verified in QA domain |
| 14. Relevant regressions pass | VERIFIED | Final suite counts, signature checks and benchmark assertions pass as recorded below |
| 15. Native interactions verified where authorized | PARTIALLY VERIFIED | Authorized 9m32.94s session completed; detailed per-check matrix in native-qa/NATIVE-RESULTS.md; physical gestures and VoiceOver remain unverified |
| 16. Updated comparison evidence | VERIFIED | `visual-comparison/integration-board.png` and full-resolution offscreen originals |
| 17. RC and DMG protected | VERIFIED | Final RC/status/DMG and research-source checks recorded in protected-state.json |

## Files changed

Application: `SourcesShared/StructuredExplorer.swift` (new), `SourcesGUI/StructuredExplorerView.swift` (new), `SourcesGUI/InventoryExplorerView.swift`, `SourcesGUI/InventoryView.swift`. Research fixes: `SourcesGUI/OverviewView.swift`, `SourcesShared/LivingTreeCamera.swift`, `SourcesGUI/LivingTreeView.swift`, `LIVING-TREE-CAMERA.md`, `LIVING-TREE-3D.md`, and an integration addendum in `VERIFICATION.md`.

Validation: `tests/LivingTreeTests.swift`, `tests/GUIModelTests.swift`, `tests/CapacityChartGeometryTests.swift` (new), `tests/LivingTreeScrollRoutingTests.swift` (new), `scripts/test-chart-geometry.sh` (new), `scripts/benchmark-structured-explorer.{sh,swift}` (new). `scripts/test-inventory-model.sh` puts its isolated scratch fixture under `/private/tmp`.

Provenance/resources: `THIRD-PARTY-NOTICES.md` (new), notice copying in `scripts/build.sh`, `scripts/build-gui.sh`, `scripts/build-dmg.sh`. No DMG was built. Research reference files carried forward: `Prototypes/`, `scripts/build-prototype-showcase.sh`, `scripts/prototype-living-tree.sh`. Evidence and this report: `artifacts/structured-explorer-integration/`.

## Rollback and review

Nothing is committed or installed. The protected release worktree still contains the original shipping implementation. To review or continue, use this integration worktree, not `v2.1-rc` or the research checkout.

The reversible renderer preference is `inventory.livingTree.renderer`: `classic` selects the previous Living Tree; `structured`, absent or unknown values select Structured Explorer. Use the **development/QA domain only** (`local.macbook.storage-monitor.viewer.qa` when a development viewer reads a copied database), or a launch-only defaults argument. Never change production preferences for this review. For a QA viewer, a launch-only `-inventory.livingTree.renderer classic` selects fallback without a persistent preference change; omit it to return. The ordinary Atlas/Living Tree picker still works.

The one explicitly authorized native session has finished; a further launch/focus session requires fresh permission. Do not run any launch command merely to switch the renderer. No source rollback command that discards uncommitted work is necessary or recommended; preserve the integration and research changes.

## Remaining limitations

Native acceptance is blocked by the recorded navigation delay and outstanding native tests. Offscreen timings are measured on the current host, with warm caches, and do not prove cold launch, compositor frame pacing, target physical-device feel or section-switch latency. High-depth views expose more nodes; the ordinary default intentionally shows only three levels. Crowded small discs can touch, and minimum-visible sizes mean tiny-item areas are not exact. Priority labels may cover geometry when no clear position fits. Very long and repeated parent names can still require the Inspector's full path. Layout ordering changes when actual size order changes during refresh; no claim of full refresh hysteresis is made.

The selected design is implemented; release readiness and native acceptance are separate remaining decisions.

## Final recorded results

Host: `Mac16,11`, Apple M4 Pro, 24 GiB RAM; macOS 27.0 (26A428), macOS 26.5 SDK, arm64 macOS 14 deployment target. Builds and tests were serialized. This headless run preceded the separately authorized native session documented above.

| Suite | Passed |
|---|---:|
| Viewer model/read-only | 934 |
| Monitor self-test | 235 |
| Inventory integration | 350 |
| Inventory browser model | 67 |
| Hosted chart/input/state | 24 |

The benchmark completed 43 required checks with zero failures, including the offscreen production input bridge, saved renders, disc/label hit accuracy, same-root comparison and the 16.67 ms offscreen frame budget. This count includes artifact-existence assertions and is not a count of independent native interactions. Both development builds and strict code-signature checks passed; bundled notices match the source notice.

### Same-pipeline before/after

The classic fallback and integrated Structured Explorer use the same restored bounded controller model and cloned catalog, 1100×600 pt canvas, 2× rasterization and warm caches. The Structured Explorer intentionally displays fewer elements at its three-level default. Layout/first-frame figures are computational/offscreen costs, not cold launch or first visible compositor frame. The original prototype timing used a different canvas and adapter and is not substituted for these measurements.

| Metric | Classic fallback | Integrated Structured Explorer |
|---|---:|---:|
| Displayed elements | 3000 | 101 |
| Layout, ms (classic sample / structured median) | 4.95 | 0.49 |
| Layout + first offscreen canvas frame, ms | 10.12 | 2.90 |
| Pan p50 / p95, ms | 1.90 / 4.53 | 1.91 / 2.18 |
| Zoom p50 / p95, ms | 2.55 / 5.01 | 1.35 / 1.99 |
| Labels at fit | 6 | 18 |
| Offscreen host + initial layout + bitmap median, ms | 149.38 | 103.98 |

Structured pan at 4× p50/p95: 0.91/1.01 ms. Selection-to-offscreen-frame p50/p95: 1.93/2.15 ms, with 1 relayout(s) over 21 selection samples. Explore read+layout median: 98.25 ms; Up median: 96.55 ms. Warm incremental footprint delta: 0.08 MiB; this is not total application memory.

Disc-centre hits: 101/101 at fit, 101/101 at 4×. Label-centre hits: 18/18 at fit, 8/8 at 4×. Hit tests cover synthetic/offscreen geometry, not a physical mouse.

The page-cost callback excludes fixed screenshot settling waits and deferred work during those waits. It is useful for a rendering comparison but does not establish the V2 500 ms native section-switch target. Real display pacing, cold navigation and target-device input remain pending.

| Larger/skewed case | Result |
|---|---|
| Budget 10,000; actual 7,583 model elements | Truncated=True; L3 104 shown, layout 1.16 ms; L6 1,843 shown, layout 2.05 ms |
| Budget 20,000; actual 8,451 model elements | Truncated=True; L3 106 shown, layout 1.07 ms; L6 1,966 shown, layout 2.15 ms |
| Synthetic skew: 3,111 elements, 40-level chain, 1,500 small folders | 56 shown; layout 0.67 ms; raster 1.72 ms; spur explicitly skips 33 levels |

Larger-model reads remain bounded and can stop before their requested element budgets; these are actual returned counts, not claims of 10k/20k fully rendered nodes. High-depth layout timings do not establish high-depth pan/frame pacing.

### Regression diagnosis and integrity

The initial edge-label regression failed 83 of 108 cases before the placement repair; the final fixture passes 108/108. A later assertion incorrectly expected root-centred zoom to always introduce a new label even as outer rings left the viewport. Diagnostics showed all label hits correct and 11 rotated labels present. The fixture now zooms into an unlabelled branch, retains the new-detail assertion and checks rotated label interiors; the focused run finds 13 rotated labels. The failed and diagnostic runs remain in `verification/labels-red.log`, `labels-zoom-red.log` and `label-zoom-diagnosis.log`. No native requirement was weakened.

The source freeze check covers 125 source/test/script files with no changes. `protected-state.json` confirms RC HEAD `873e069dc88788d24d620b4f9f6ff1904ea52f6a`, the unchanged DMG SHA-256 `3484abea58524cd090808714e38672cc0f82a628d3b42b9c797c66674f774f0c`, unchanged release-checkout status, exact research fix-source matches and all six research prototype files carried forward intact. No release action was taken.

The compiler emits the pre-existing `CleanupInspectorView.swift:174` weak/strong capture warning. It was left unchanged because cleanup implementation is outside this visualization change. Universal/Intel and distribution-DMG builds were not run.

Screenshots: `headless-renders/` (28 full-resolution captures); comparison board: `visual-comparison/integration-board.png`; full machine-readable metrics: `measurements.json`; commands/results: `verification/`. Final native outcomes and blockers are recorded in `native-qa/NATIVE-RESULTS.md` and `NATIVE-QA.md`.

## Native QA conclusion

The QA app was closed after 572.94 seconds, before the ten-minute limit, with no focus-safety stop. The original three-key QA preference domain was restored and compared equal. No production preferences, protected RC/DMG, installed app, background worker or system accessibility setting changed. No Trash operation occurred. Implementation code and the prior regression results are unchanged.

Acceptance is **BLOCKED**. The hierarchy lag, minimum-window caption crowding and outstanding hover/reverse-scroll/double-click-targeting/Return checks are documented in [NATIVE-RESULTS.md](native-qa/NATIVE-RESULTS.md). The disposable native-review catalog and its isolated inventory-request queue were removed after the app exited; evidence is preserved. No fixes or further milestone were automatically started.
