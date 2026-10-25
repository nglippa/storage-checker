# Living Tree — the Living Filesystem visualization (first functional version)

Status, 2026-10-25: implemented; verified by model, catalog and headless controller tests, and by offscreen renders of an APFS clone of the 2.96M-node catalog. Uncommitted, not packaged or installed. No production database, monitoring history, LaunchAgent or installed app was touched; no full-volume scan was run. **Nothing was checked in a real window** (checklist in section 11).

Evidence: `build/living-tree-1/evidence/` (renders), `build/living-tree-bench.log` (benchmark), `build/living-tree-render.log` (render timing), `build/living-tree-*-tests.log`.

## 1. Files changed

| File | Change |
|---|---|
| `SourcesShared/LivingTree.swift` (new) | The pure model: keys and elements, budget, best-first builder, arranger (sectors, stable sibling order, hysteresis), geometer (curves, widths, crown fit), hit index, keyboard movement, illumination from size signals, palette, rebuild planning |
| `SourcesShared/InventoryModels.swift` | `InventoryReader.livingTree(rootID:budget:memory:reveal:)`: the whole tree from one read transaction, using the explorer's own child queries and exact remainder; optional per-connection read deadline (default unchanged, 0.25 s) |
| `SourcesGUI/LivingTreeView.swift` (new) | `LivingTreeController` (build, coalescing, change feed, signals, layout cache) and `LivingTreeView` (static base canvas, animated overlay, lens, breadcrumbs, legend, keyboard, accessibility) |
| `SourcesGUI/InventoryExplorerView.swift` | Atlas \| Living Tree picker (remembered); `select(_:through:openTarget:)` opens a tree selection's folders in the Navigator and closes the ones it opened before; `reveal` for search results |
| `SourcesGUI/InventoryView.swift` | `livingTree` controller (created on first use); a search result's "Show location" is selected and revealed in its folder |
| `tests/LivingTreeTests.swift` (new), `tests/GUIModelTests.swift`, `scripts/test-gui.sh` | 39 model tests |
| `tests/LivingTreeCatalogTests.swift` (new), `tests/InventoryIntegrationTests.swift`, `scripts/test-inventory.sh` | 14 tests on real worker-built catalogs |
| `tests/InventoryModelTests.swift` | 4 headless controller tests (no window) |
| `scripts/benchmark-living-tree.sh`, `scripts/benchmark-living-tree.swift`, `scripts/render-living-tree.swift` (new) | Benchmark and offscreen renders against a `cp -c` clone under `/private/tmp`, removed on exit |

Storage Atlas, the Navigator, the Inspector, search and rankings, the indexer, the worker, the schema and the change journal are unchanged. There is no second indexing engine and no filesystem watcher: the tree reads the catalog and the committed change journal only.

## 2. Tree model and layout architecture

**Mapping.** The current folder (the volume at the top) is the trunk; its folders are primary branches; nested folders are progressively shorter and thinner branches; files are terminal elements; each folder's small items are one grouped terminal element ("Other items") with exact totals. Every element is keyed by its stable inventory node id (`LivingTreeKey.node`), the grouped remainder by its folder (`.rest(folder)`).

**Building (bounded, one snapshot).** `LivingTreeBuilder` expands best-first: the largest folder not yet opened is read next, until about 3,000 elements (`LivingTreeBudget`: 3,000 elements, 24 drawn children per folder plus 8 slack, depth 40, minimum share 1/100,000 of the trunk). Each read is the explorer's keyset page (largest first) plus `explorerRemainder` over the covering index, so a folder's drawn children plus its grouped remainder equal its indexed children **exactly** (bytes, item count, items without a measured size). The reader runs the whole build in one read transaction (`BEGIN … COMMIT`), so every folder in the tree describes the same committed moment, and records the change journal's position in that snapshot. A guard stops adding folders at 60% of a 0.5 s deadline (the worker's commits wait at most that long; its busy timeout is 30 s); a stopped tree is marked `truncated` and says so in the footer.

**Truthful states.**
- An entry without a measured size (protected, unreadable, not yet listed) is an `unmeasured` stub: a dashed hairline with a hollow tip, never a width derived from zero; its count also appears in the footer. A grouped remainder made only of such items has no size (`bytes == nil`).
- Earlier (stale) sizes keep their state and are drawn quieter; partial (lower-bound) sizes are slightly quieter with a hollow tip ring.
- Hover, accessibility and the Inspector always give the exact state and size.

**Arrangement (independent of the canvas size).** `LivingTreeArranger` gives each element an angular sector nested inside its parent's (a radial tidy-tree), so sibling subtrees never share directions. Within a folder:
- *Order:* sibling slots are remembered for as long as an element exists; new elements are placed centre-out by size (the heaviest continues near the parent's direction). Folders that swap size ranks keep their places.
- *Room:* half the share of visible elements beneath, half the share of bytes, with a floor; smoothed with a 15% dead-band.
- *Direction and reach:* the sector centre with deterministic per-key variation, pulled toward the parent for heavy children; reach follows the smoothed share.
All variation comes from a SplitMix64 hash of the node id, so the same catalog always gives the same tree.

**Hysteresis.** Elements drawn last time stay drawn with a 40% lower threshold and 8 places of rank slack; folders opened last time keep 1.5× priority; room and share keep their previous values inside a 15% dead-band. Sector totals are summed in the stable slot order (so a rank swap cannot shift anything by rounding). Memory is per trunk, bounded to its elements and kept for the six most recent trunks.

**Geometry.** `LivingTreeGeometer` fits a fixed crown to the canvas (not to the content, so nothing rescales when the tree changes): trunk from the ground to the crown centre, depth bands shrinking by 0.7 per level, crown fan ±79°. Each element is a cubic curve from a point near its parent's tip (lower for light branches near the trunk) to its tip; it leaves along its parent's direction and arrives turning outward. Deep in the crown a folder's children are drawn at most 1.6 times as far sideways as their band is deep (the factor never grows going down, so subtrees stay disjoint); this turns rows of parallel twigs along the rim into tufts.

**Thickness.** Width is proportional to the square root of the share of the trunk: cross-sectional area is proportional to indexed allocated size, and a folder's children together are never thicker than it (da Vinci's rule). Below 0.6 pt widths clamp to a hairline (tested separately from proportionality).

## 3. Visual design decisions

- **Ground:** deep charcoal with a faint lift around the crown and a soft pool of light at the trunk's base. The tree keeps this ground in both appearances (it is a lit object, not chrome); the surrounding app follows the system appearance.
- **Branches:** warm neutral white. Thick branches are opaque colours pre-mixed with the ground (forks join without brighter seams) with a finer, brighter core; thin branches are translucent hairlines batched by width and opacity. Opacity falls gently with depth.
- **Tips:** soft light at the tips of terminal elements and unopened folders (radial falloff, at most 400 gradient tips; smaller tips are single points). Grouped small items are a fine tuft of three sprigs.
- **Change light:** amber for growth, cool blue for reduction, added as light (`plusLighter`) at 50% at most on thick branches, with a tinted glow at the tip; it rises for 0.6 s and fades over 36 s. Nothing else moves.
- **Labels:** at most 16, for main branches of at least 2% (depth 1) or 6% (depth 2), beside the tip with a dark halo, never overlapping; a folder that is nearly all of a labelled parent (Users › home) is not labelled twice.
- **Avoided:** straight node-link lines, circles, leaves, bark, particles, constant animation, bloom.

## 4. Navigation and interaction

- **Mode:** a segmented Atlas | Living Tree control beside the Navigator/Table switch (remembered); the existing show/hide toggle hides either.
- **Hover:** the element under the pointer brightens; a lens gives its name, size, item count, measurement state and, when lit, the measured change ("Grew by 1.2 GB of indexed allocation"; reductions add "not necessarily space freed"). Tips win over a thicker branch passing beneath them.
- **Click:** selects the entry. The Navigator opens every folder between the trunk and it and scrolls to it; the Inspector follows. Folders opened only for this reveal are closed on the next one, so revealing never accumulates expanded folders. Clicking a grouped tuft selects its folder and opens it in the Navigator, where every item is listed: no tiny twig ever has to be hit.
- **Double-click / Return:** a folder becomes the trunk; the new tree grows out of the branch it was (uniform zoom), and leaving zooms back out around the folder you left. Reduce Motion: a short cross-fade.
- **Breadcrumbs** in the tree's header (last four levels) and the app's own header; **Escape** goes to the enclosing folder.
- **Keyboard:** ↑ toward the tips (largest child), ↓ toward the trunk, ← → between siblings in drawn order, Return opens, Escape goes up. The canvas is focusable.
- **Selection made elsewhere:** a Navigator selection shows on its own element, on its folder's tuft when grouped, or on its nearest drawn folder; the path back to the trunk is lit.
- **Search reveal:** "Show location" on a search result opens its folder, selects it, and the tree draws it even when small (pinned in the same snapshot; the folder's grouped total stays exact). A reveal made while the Atlas is showing is applied when the tree appears; revealing the same entry again is delivered again.
- **Accessibility:** the canvas is a container labelled "Living Tree of …" with a hint; the 48 largest elements are buttons with spoken size, state and change, and an Open action.

## 5. Change-journal integration

- The controller polls only when the inventory reports a change (the viewer's existing status refresh), at most once a second, one read in flight; changes arriving meanwhile are re-checked, not dropped.
- `changes(since:)` continues from the journal position recorded in the tree's own snapshot. The tree is rebuilt only when a drawn folder's listing changed, the trunk's own listing changed (an empty folder gaining its first entry), a subtree change touches a drawn folder or the trunk's ancestors, generation-wide staleness differs from the snapshot's (recorded in the same read), the backlog exceeds one read, or the reader must resynchronize; otherwise the cursor simply advances. Rebuilds are coalesced and at most every 1.5 s (5 s without a journal).
- `sizeSignals(since:)` feeds `LivingTreeIllumination`:
  - only comparisons of two settled measurements light anything; raw file events never do (a node mid-reconciliation records no comparison, so it stays dark);
  - the first read, a cursor outside retention and a recreated journal resynchronize silently (no history replayed); a recreated journal also clears existing light;
  - comparisons at or before the cursor, or measured more than five minutes ago, are not shown as new; a backlog beyond one read is skipped;
  - strength is logarithmic in the change relative to the earlier size (≥ about 3% is full; 4 KB of 500 GB is nothing); lower-bound comparisons are multiplied by 0.45;
  - light lives in the controller (keyed by node id), so it survives rebuilds and redraws; at most 2,048 glows;
  - returning to the tree after more than 36 s resynchronizes instead of replaying what happened meanwhile.
- **Reduce Motion:** light does not fade continuously: it holds and steps down in thirds (redrawn every 4 s) and then disappears; trunk changes cross-fade.
- **No idle animation:** the overlay's timeline is paused unless something *drawn* is lit (light on entries outside the tree never keeps it running), and a scheduled expiry stops it when the last light fades.

## 6. Performance (APFS clone of the 2.96M-node, 440k-folder catalog)

Run: `scripts/benchmark-living-tree.sh build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3` (the source is only cloned). The machine was shared; figures are indicative.

| Measure | Result |
|---|---|
| Volume tree (3,000 elements, 583 folder reads), warm | 70–75 ms per build, one snapshot |
| Volume tree, first build after cloning (cold cache) | 272–300 ms; two of four runs stopped at the 300 ms guard with 2,959–2,963 elements, marked truncated |
| Folder read (page + exact remainder) | mean 0.09 ms; slowest single read p95 0.17–0.29 ms, max 1.8 ms warm, 29 ms cold |
| 16 trunks of decreasing size | snapshot p50 0.5 ms, p95 2.3–2.6 ms |
| Arrangement / geometry / hit index (3,000 elements) | 3.2–4.0 ms / 0.6–1.3 ms / 1.0–1.2 ms |
| Elements drawn | 3,000 at the volume and in Users (budget); fewer in smaller folders |
| Offscreen draw of the static tree (1400×860 @2x) | p50 1.7–1.9 ms |
| Illumination overlay, one animation frame | 0.02–0.03 ms with 7 glows |
| Memory, 60 rebuilds over 16 trunks | +1.4 to +5 MB footprint; 6 trunk memories, ≤ 13.4k entries |
| Change update: 24 drawn folders relisted (+80 MB each) | changes read 0.5 ms, rebuild 70–77 ms, arrangement 3.6–4.0 ms, signals read 0.5 ms (143 comparisons, 91 drawn elements lit) |
| Stability after that change | 2,994 of 3,000 elements kept; 93% of tips did not move at all; 6 moved 0.5 pt or more (median 0.7, max 2.3 pt) |
| Stability after one 4 KB change | 3,000 of 3,000 tips unmoved |
| Rapid updates: a separate writer process commits every 100 ms for 15 s | writer commit p95 21.6 ms (alone 20.6 ms), worst 91–105 ms (waited for one tree snapshot); viewer 14 change reads, 9 rebuilds (p50 75–91 ms), 0 failed reads, 0.82–0.91 s CPU (5–6% of one core), footprint +1–3 MB |

Rendering uses SwiftUI `Canvas` (no 3D engine): a static base canvas that redraws only when the tree or size changes, and an overlay for hover, selection and light, so pointer moves and animation frames never repaint 3,000 branches.

## 7. Tests

| Suite | Result |
|---|---|
| Viewer model (`scripts/test-gui.sh`) | 459 passed (420 before + 39 Living Tree) |
| Inventory (`scripts/test-inventory.sh`) | 345 passed (331 before + 14 Living Tree) |
| Headless inventory model (`scripts/test-inventory-model.sh`) | 22 of 22 (18 before + 4) |
| Monitor self-test | 233 passed |
| Builds | viewer and monitor, no errors or warnings |

Coverage by requirement:
- **Hierarchy:** synthetic and real catalogs (parent, name, depth, order).
- **Thickness:** area proportional to bytes; children never thicker than their folder.
- **Grouped accounting:** exact against the synthetic catalog and against SQL sums on a worker-built catalog, including after a reveal.
- **Determinism:** identical model, arrangement, geometry and memory.
- **Stability:** no movement for a 3% change; only the changed folder re-shapes for a 30% change; remembered sibling order; membership hysteresis; separate direction ranges per subtree.
- **Selection and navigation:** keyboard moves, display of grouped and hidden selections, the chain opened in the Navigator, controller-level reveal that closes earlier reveals.
- **Hit testing**, **pinned reveal**, a **200,000-entry folder** (one read), a **virtual catalog of billions of entries** (bounded to 3,000 elements and bounded memory over 10 updates).
- **Light:** growth amber, reduction blue, unchanged dark, fade and stop, Reduce Motion, lower-bound softening, threshold, replay protection, resynchronization (synthetic and after real journal pruning), recreated journal, backlog, no journal, capacity.
- **Real catalogs:** growth after writing a file and reduction after deleting one (worker relists), an unchanged relist outside the drawn branches not rebuilding, an unreadable folder never zero.

## 8. Independent review

A read-only Codex review (high reasoning) of the model, reader, controller and Navigator integration reported six issues; five were fixed with regression tests:
1. an empty trunk never rebuilt when it gained its first child (trunk listing changes now always rebuild);
2. a folder opened for a reveal and then selected itself lost its tracking, so expanded folders could accumulate (it stays tracked);
3. generation-wide staleness was compared with the previous poll rather than the drawn snapshot (it is now read in the tree's own transaction);
4. a reveal requested while the Atlas was showing was lost, and repeating the same reveal did nothing (requests are applied when the tree appears and are distinct);
5. light on entries outside the drawn tree kept the overlay animating (activity now counts drawn elements only).

The sixth (a revealed entry beyond the Navigator's loaded pages has no row to scroll to) is the explorer's existing paging and is documented as limitation 9.

## 9. Offscreen renders (`build/living-tree-1/evidence/`, 2× scale)

Drawn by `ImageRenderer` (the tree panel) and by an `NSHostingView` in a borderless window that is never ordered in (the full page); the render process may not activate.

- `living-tree-volume.png` — the volume (3,000 elements).
- `living-tree-volume-earlier-sizes.png` — the catalog as preserved: a pending reconciliation qualifies every size as earlier, drawn quieter.
- `living-tree-selection.png` — a selection three levels deep, its path to the trunk lit.
- `living-tree-signals.png`, `living-tree-signals-fading.png` — growth (amber) and reduction (blue) from size changes committed to the clone, about 1 s and 21 s after they were read.
- `living-tree-folder.png` — a top-level folder as the trunk (the harness picks the largest folder with a current measurement: Library in the final run).
- `living-tree-page-dark.png`, `living-tree-page-light.png` — the full explorer with the Inspector. **Capture artefacts, not app behaviour:** AppKit segmented controls render as white boxes and the Navigator's rows are blank in the light capture; the Navigator also shows sizes from before the committed test changes because the harness does not forward change notifications to it.

Before the renders the harness clears the clone's pending reconciliation (as a finished reconciliation would) so that later renders show the settled state; folders mid-reconciliation still record no comparisons and stay dark.

## 10. Known limitations

1. **No real-window verification** (section 11): hover feel, click and double-click targeting, focus and key handling, the zoom transition, Reduce Motion in practice, scroll-to-row in the Navigator, VoiceOver.
2. **Cold first build** can take ~0.3 s on a 3M-node catalog and may stop at the read guard (marked, smaller tree); the next rebuild is warm.
3. **Radial crown, not a free-form tree:** subtrees stay in nested sectors; very deep, narrow branches end in compact tufts. Single-child chains (Users › home) draw as one long limb.
4. **Rebuild granularity:** any drawn folder's change rebuilds the whole (bounded) tree, ~70–110 ms off the main thread; positions are kept by memory, not by incremental patching.
5. **Light is per node:** an ancestor lights only if it has its own settled comparison; folders mid-reconciliation and grouped items never light.
6. **Labels** are limited to a few main branches; everything else is named in the lens, the Navigator and the Inspector.
7. **Accessibility** exposes the 48 largest elements; the Navigator remains the complete accessible list.
8. **The tree's ground is always dark** (intentional); this was not checked against a light-appearance window.
9. **Navigator row for a deep reveal:** selecting an entry opens its folders in the Navigator, but its row appears only once its page is loaded (the Navigator pages 200 at a time, up to 5,000 per folder). An entry ranked beyond the loaded pages is selected (Inspector shows it) without a visible row until "Show more" reaches it. This is the explorer's existing paging, shared with the Atlas.

## 11. Real-window verification checklist (NOT VERIFIED)

- [ ] Disk Inventory → the Atlas | Living Tree control switches the visualization above the Navigator and is remembered.
- [ ] The volume tree appears within a moment; the footer reports elements and unmeasured items.
- [ ] Hover: a branch brightens and the lens follows the pointer with name, size, state; tips are easy to hit.
- [ ] Click: the Navigator opens to the entry and scrolls to it; the Inspector follows; clicking a tuft opens its folder in the Navigator.
- [ ] Double-click / Return on a folder: it becomes the trunk, growing out of its branch; a breadcrumb or Escape returns, zooming out around it.
- [ ] Arrow keys move along branches after clicking into the tree; focus is not lost to other panes.
- [ ] With the worker running, a file written or deleted in a visible folder lights its branch amber or blue after the next update, then fades over ~36 s; nothing animates afterwards (Activity Monitor shows the viewer idle).
- [ ] Reduce Motion on: light holds and steps down instead of fading; trunk changes cross-fade.
- [ ] Search → Show location: the folder opens, the result is selected and drawn in the tree.
- [ ] Light appearance: the app is light, the tree keeps its charcoal ground, text is legible.
- [ ] Resize the window and the visualization divider: the tree refits without jumping.
- [ ] VoiceOver reads the tree container and its largest branches.
- [ ] Memory in Activity Monitor stays bounded while switching trunks repeatedly.
