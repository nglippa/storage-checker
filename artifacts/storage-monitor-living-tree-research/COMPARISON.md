# Living Tree — current vs. Organic Storage Tree (A) vs. Structured Explorer (B)

**Recommendation: B, the Structured Explorer**, with A's strongest idea carried into it (see the end of this document). Nothing has been promoted into production; the operator chooses.

## Fair-comparison setup

- **Data.** One APFS clone of a preserved 2.96M-node catalog (`build/inventory-verification/data/history.sqlite3`, read only via `cp -c`). The production `LivingTreeController` built one model for all three views: 3,000 elements, 583 expanded folders, max depth 15, trunk 463.11 GB. It includes:
  - a very large `Users` (323.88 GB, 70%);
  - medium branches (`private` 98 GB, `Applications` 29 GB);
  - deep nesting (a 751.5 MB folder at level 14);
  - 433 grouped remainders and 28 unmeasured entries;
  - a 96× repeated name ("Resources");
  - long paths (Chrome code-sign clones);
  - a highly unbalanced tree.
  
  Byte values are the catalog's.
- **Pipeline.** Each frame is the model work (projection/transform plus label placement), then the canvas rasterized by `ImageRenderer` at 2×. That's what `scripts/benchmark-living-tree-camera.sh` already measures for the current tree.
- **Sequences.** Canvas 1140×780. Identical camera sequences: 40 pan frames at 1× and 4×, and 40 zoom frames in 1.08× steps. 2,000 random hit tests.
- **Click accuracy.** One method for all three: click a point ¾ along each element (limbs and branches) or its centre (leaves and discs), 600 sampled, at the fit and zoomed 4× about it.
- **Environment.** Mac mini M4 Pro, 24 GB. Shared machine, with other apps (and possibly Command Center or local AI) running, so the numbers are indicative. Run: `scripts/prototype-living-tree.sh`. Raw data: `verification/measurements.json` and `.log`.

## Measured

| | Current | A · Organic | B · Structured |
|---|---|---|---|
| Layout | 6.89 ms (arrange 4.85, geometry 1.00, hit index 1.05) | 3.67 ms + 2.08 ms adapter | **0.07 ms** + 1.91 ms adapter |
| Elements laid out | 3,000 branches | 4,550 limbs and leaves | 101 (3 levels × top 14) |
| Initial render readiness (layout + first frame) | ≈ 12.7 ms | ≈ 10.6 ms | **≈ 4.8 ms** |
| Pan @1× p50 / p95 | 2.20 / 5.08 ms | 4.34 / 4.59 ms | **2.07 / 2.44 ms** |
| Pan @4× p50 / p95 | 0.76 / 1.19 ms | 1.03 / 1.59 ms | **0.69 / 0.73 ms** |
| Zoom p50 / p95 | 2.15 / 5.27 ms | 3.81 / 5.13 ms | **1.32 / 2.33 ms** |
| Hit test p50 / p95 | **0.0 / 1.5 µs** (grid index) | 10.9 / 14.5 µs | 0.5 / 0.5 µs |
| Select → frame | not measured | 4.8 ms | 2.3 ms |
| Click accuracy, fit | 166/600 (28%) | 405/600 (68%) | **101/101 (100%)** |
| Click accuracy, 4× | 330/600 (55%) | 493/600 (82%) | **101/101 (100%)** |
| Labels, fit / 4× | 10 / 2 | 16 / 6 | **28** / 6 |
| Drawn primitives, fit / 4× | — | 4,552 / 151 | 216 / 57 |
| Memory Δ (scene + first frame) | — | 4.7 MB | 0.2 MB |
| ~8.4k-element model: layout / frame | 14.2 ms / — | 9.0 / 9.6 ms | 0.09 / 2.6 ms |

**Notes on the numbers.**
- Every frame time is far inside a 120 Hz budget (8.3 ms). Performance doesn't decide between them; it does show B's cost is bounded by what is visible, not by model size.
- The current tree's 28% click accuracy on this anchor isn't a regression. Its own test clicks branch **tips** (404/404, `LIVING-TREE-CAMERA.md`). A point ¾ along a branch is often inside a crowd of thinner neighbours. The shared method is the fair one for "click where you see the element".
- The 10k/20k budgets were cut to about 8.3–8.5k elements by the builder's existing read guard, on a cold clone.
- No continuous rendering in any view: all redraw on state change only.
- Process footprint of the whole headless harness was about 1 GB because of 34 retained 2880×1800 captures. That isn't a per-view cost; the per-scene deltas are above.

## Scores (1–5; subjective unless marked "measured")

| Criterion | Current | A | B |
|---|---|---|---|
| 1. Immediate comprehensibility | 2 | 3 | **4** |
| 2. Storage-size readability | 2 | 4 (exact pipe model) | **4** (disc + share arc + sizes on 28 labels) |
| 3. Hierarchy clarity | 2 | 3 (deep runs crowd) | **5** (ring = level) |
| 4. Folder-selection accuracy (measured) | 2 | 3 | **5** |
| 5. Navigation intuitiveness | 3 | 3 | **4** (Levels, re-centre, Up, breadcrumb) |
| 6. Label readability | 2 | 3 | **4** (outer labels are rotated) |
| 7. Visual attractiveness | 3 | **4** (most distinctive; the light overview especially) | 3 |
| 8. Accessibility | 3 (VoiceOver zoom and focus actions) | 4 | 4 (same inspector contents list, labelled rows, Explore action; **VoiceOver NOT TESTED**) |
| 9. Rendering performance (measured) | 4 | 3 | **5** |
| 10. Integration and maintenance simplicity | 2 (≈3,500 lines across view, camera, tree, 3D) | 3 | **4** (≈310 lines; a textbook algorithm) |
| **Total** | 25 | 33 | **42** |

## Which is best at what

- **Explains storage usage best:** B for "what is inside this folder and how big"; A for "where does the disk's mass flow". A's trunk visibly shedding `private` (98 GB) and the 94.7 GB Chrome code-sign clone limb is the single most striking insight in any render.
- **Easiest to navigate:** B.
- **Looks best:** A.
- **Performs best:** B.
- **Easiest to integrate safely:** B. It needs no camera motion system, no hysteresis to stay stable (the layout is deterministic per focus), and it's bounded by its visible set.

**Not chosen automatically for looks.** A is the most visually elaborate, but it loses on comprehension, accuracy and maintenance, and its measured overlap problem is inherent to botanical layouts.

## Recommendation

Adopt **B** as the direction for the next Living Tree iteration, folding in A's pipe-model insight: make B's link width exactly ∝ √bytes, as an area-conserving flow, and label the heaviest flow path. Keep A's organic rendering only as an optional "overview poster" if the product wants an emotive view. It shouldn't be the primary navigator.

## Integration risks (B into production)

1. **Feature parity with the shipping view:**
   - change-journal growth/reduction light;
   - stable memory and hysteresis across rebuilds (B's layout reshuffles when sizes change rank);
   - Navigator/Inspector selection sync through `InventoryExplorerModel`;
   - Isolate, View Selection and 3D (it would be dropped).
2. **Rank changes** reorder siblings clockwise. It needs the same hysteresis the current arranger has, or animated transitions, to avoid jumping during live updates.
3. **Per-folder cap.** B's cap of 14 versus the builder's `perFolder` of 24: the "+N" and grouped semantics must stay exact. The model already has exact remainders; the prototype's "+N" counts hidden siblings, not bytes.
4. Re-centre and Up need animation, with Reduce Motion respected.
5. Rotated labels: localisation, right-to-left text and VoiceOver order.
6. Real-window input feel is unverified. The production input layer is reused, which lowers the risk.

## Suggested next steps

1. Operator review in the showcase app, about 15 minutes with a copied catalog: `scripts/build-prototype-showcase.sh`, then `open -n "build/prototypes/Living Tree Prototypes.app" --args <clone>`. Check the input checklist in `CAMERA-INPUT-REPORT.md` at the same time.
2. If B is chosen, plan a milestone:
   - port the arranger's hysteresis to the tidy tree;
   - add an animated re-centre;
   - drive selection through `InventoryExplorerModel`;
   - add a change-journal tint;
   - add VoiceOver checks;
   - make it an opt-in mode before replacing the default.
3. Whatever is chosen, keep this milestone's two fixes (chart flicker, wheel zoom). They are independent of the visualization decision.
