# Prototype B — Structured Hierarchical Explorer

**Implementation:** `Prototypes/LivingTree/StructuredExplorer.swift` (314 lines). It shares `PrototypeCore.swift` and `PrototypeExplorerView.swift` with A. It isn't compiled into the app. It runs headless through `scripts/prototype-living-tree.sh` and interactively in the showcase app.

## Visual encoding

- **Radial tidy tree centred on the folder being explored.** Each level has its own labelled ring. Children run **clockwise from 12 o'clock, largest first**, so position alone gives depth and size order. The layout is a direct port of d3-hierarchy's `tree()` (ISC): the Buchheim–Jünger–Leipert linear-time Walker algorithm (`firstWalk` / `apportion` / `executeShifts` / `secondWalk`), with d3's radial separation `(same parent ? 1 : 2) / depth` and `size([2π, R])`. It is deterministic: the same hierarchy always draws the same.
- **Size, encoded exactly twice.** Disc area ∝ bytes (relative to the centre). An **arc around each disc** shows its share of its parent. Link width follows the bytes flowing through it.
- **Colour** is the top-level branch, so "which part of the disk am I in" stays visible several levels down.
- **Kinds.** Folders are filled. Files are rings. Grouped items are grey. Unmeasured entries are dashed and are never drawn as zero.
- **Controlled depth.** "Levels" is 1–6, default 3. Each folder shows its largest 14 children. Hidden contents show as an outward **"+N"**; double-click re-centres there (zoom-to-folder). **Up** goes to the parent. The breadcrumb shows the full path. Selecting something beyond the shown levels (for example from the contents list) re-centres on its ancestor so it is always visible.
- **Selection.** An orange ring plus the orange link chain from the centre.
- **Labels.** First-ring labels are horizontal beside the disc. Outer rings are radial, flipped on the left half so they're never upside down. Discs block labels, so a label never hides a node. Repeated names read `parent › name`.

**Why 2D, not 2.5D or 3D:** the rings already encode depth. A camera that orbits would hide that encoding and cost interaction complexity (orbit vs pan) for no added information. The 3d-force-graph `radialout` DAG mode reviewed in `../REFERENCE-REPOSITORIES.md` produces the same concentric-rings-by-depth structure, non-deterministically and with a continuous simulation.

## Screenshots (`screenshots/`, 2880×1800)

| File | State |
|---|---|
| `B-structured-1-overview-{dark,light}` | Volume, 3 levels |
| `B-structured-2-large-selection-*` | `Users` selected (orange ring and path) |
| `B-structured-3-deep-selection-*` | Level-14 `155.0.8059.80`: re-centred on its ancestor `Google Chrome Framework`, with the breadcrumb showing the whole path |
| `B-structured-4-zoomed-in-*` / `-5-zoomed-out-*` | 4× / 0.5× |
| `B-structured-6-explored-*` | Double-clicked `Users`: re-centred one level down |
| `B-structured-7-repeated-name-dark` | A repeated "Resources" folder selected |

## Measurements (same method as A and the current tree; `../COMPARISON.md`)

| | |
|---|---|
| Layout p50 | **0.07 ms** (+1.91 ms model adapter) for 101 visible nodes |
| Drawn primitives, fit / 4× | 216 / 57 |
| Initial render readiness | ≈ 4.8 ms |
| Pan @1× p50 / p95 | 2.07 / 2.44 ms |
| Pan @4× p50 / p95 | 0.69 / 0.73 ms |
| Zoom p50 / p95 | 1.32 / 2.33 ms |
| Hit test p50 / p95 | 0.5 / 0.5 µs |
| Select + frame | 2.3 ms |
| Click accuracy (disc centres, every visible node) | **101/101 at fit, 101/101 at 4×** |
| Labels, fit / 4× | 28 / 6 (4× is mostly empty space between rings) |
| Memory Δ | 0.2 MB |
| Scale (8.3k–8.5k-element models) | layout 0.09–0.10 ms, frame 2.6–2.7 ms. Cost follows the visible set (~106 nodes), not the model size. |

## Known weaknesses

- Fewer things at once: 101 nodes at 3 levels. The depth control and re-centring are how you go deeper, so it's a different mental model from "see everything".
- Rotated outer-ring labels are harder to read than horizontal ones, and long names are middle-truncated (the full path is in the inspector).
- It looks more conventional than A.
- Re-centring isn't animated yet.
- Discs on a crowded ring can touch. There is no collision relaxation; the tidy layout spaces by leaf count, not disc size.
- Not yet built: change-journal light, memory or hysteresis across rebuilds, VoiceOver custom rotor.
