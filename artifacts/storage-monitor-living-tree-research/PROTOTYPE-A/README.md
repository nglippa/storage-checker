# Prototype A — Organic Storage Tree

**Implementation:** `Prototypes/LivingTree/OrganicTree.swift` (333 lines). It shares `PrototypeCore.swift` (model adapter, camera, labels) and `PrototypeExplorerView.swift` (shell, inspector, production input layer) with B. It isn't compiled into the app. It runs headless through `scripts/prototype-living-tree.sh` and interactively in `scripts/build-prototype-showcase.sh` → `build/prototypes/Living Tree Prototypes.app`.

## Visual encoding

- **Pipe model (Leonardo's rule).** A limb's cross-section area ∝ the bytes it carries. Laterals leave along the parent limb, largest lowest, and after each one the parent's radius drops to that of what it still carries. The trunk is exactly as thick as the folder, and you can see how much storage leaves at each fork. This replaces EZ-Tree's constant taper factor with a data-exact taper.
- **Folders are limbs; files are leaves.** Leaf area ∝ size, arranged in a golden-angle sunflower at the limb tip. Grouped small items form a pale clump. A folder whose contents aren't drawn ends in a dark **bud** marked "+": double-click to explore it.
- **Shape.** Taken from EZ-Tree (MIT), made deterministic:
  - per-level length decay (×0.76);
  - a growth force that bends thin limbs toward vertical more than thick ones (strength / radius);
  - gnarliness ∝ 1/√radius, from per-key noise;
  - siblings share the parent's angular sector by √share and leaf count, largest in the middle (apical dominance);
  - a fan is never narrower than its limbs' thickness needs.
- **Selection.** An orange outline along the whole chain from the trunk; the selected limb is filled. Hover gets a thin ink outline.
- **Labels.** "name size" pills by size priority: 16 at the fit, more when zoomed. Repeated names read `parent › name`, so 96 folders called "Resources" stay distinguishable.

## Screenshots (`screenshots/`, 2880×1800, a 1440×900 window at 2×)

| File | State |
|---|---|
| `A-organic-1-overview-{dark,light}` | Whole volume (463 GB, 3,000 elements) |
| `A-organic-2-large-selection-*` | `Users` (323.88 GB, 70%) selected |
| `A-organic-3-deep-selection-*` | Level-14 `…/Versions/155.0.8059.80` (751.5 MB), framed |
| `A-organic-4-zoomed-in-*` | 4× on `Users` |
| `A-organic-5-zoomed-out-*` | 0.5× |
| `A-organic-7-repeated-name-dark` | A repeated "Resources" folder selected |

Every page shows the breadcrumb and Up button, the inspector (path, size, share of parent and of the volume, contents list), the legend and the zoom controls.

## Measurements

From `../verification/measurements.json`: the same model, a 1140×780 canvas, the canvas rasterized at 2× by `ImageRenderer`, the same camera sequences as the current tree. See `../COMPARISON.md` for all three side by side.

| | |
|---|---|
| Layout (scene construction), p50 of 5 | 3.67 ms (+2.08 ms model adapter) |
| Elements laid out | 4,550 (limbs and leaves) |
| Drawn primitives, fit / 4× | 4,552 / 151 (culling and level of detail) |
| Initial render readiness (adapter + layout + first frame) | ≈ 10.6 ms |
| Pan frame @1× p50 / p95 | 4.34 / 4.59 ms |
| Pan frame @4× p50 / p95 | 1.03 / 1.59 ms |
| Zoom frame (1.08× steps) p50 / p95 | 3.81 / 5.13 ms |
| Hit test p50 / p95 | 10.9 / 14.5 µs (linear scan; no index needed at this size) |
| Select + frame | 4.8 ms |
| Click accuracy (¾ along a limb or a leaf centre; 600 sampled) | **405/600 at fit, 493/600 at 4×** (was 235 / 378 before the minimum-spread fix) |
| Labels, fit / 4× | 16 / 6 |
| Memory Δ for the scene and first frame | 4.7 MB |
| Scale: 8,462 / 8,308 elements (budgets 10k/20k; the builder's read guard truncated both) | layout 9.0 / 8.6 ms, frame 9.6 / 9.5 ms |

The view redraws only when state changes; there is no animation timer.

## Known weaknesses (measured or seen in renders)

- **Overlap.** A botanical layout can't guarantee siblings don't cross. In long runs of near-equal folders (Chrome `Versions/*`) limbs still crowd and labels stack. About 1 in 3 elements isn't the hit at the fit, about 1 in 6 at 4×.
- **Area perception.** Precise size comparison relies on judging area and thickness, which people do less accurately than length or position. The inspector carries the exact numbers.
- **Not yet built:** Explore animation, a rebuild that keeps memory or hysteresis, change-journal light, 3D.
