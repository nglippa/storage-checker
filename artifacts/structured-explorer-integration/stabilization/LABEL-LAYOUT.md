# P1 — Ring captions and label density

> **Native update, 2026-10-29:** The authorized session is complete; full acceptance remains partial. See [native results](native-qa-20261029T172929/NATIVE-RESULTS.md) for measured outcomes, incomplete checks and verified cleanup. The original implementation-phase record below is retained. Automated suites were not rerun during native QA.

Status: **IMPLEMENTATION COMPLETE, model-verified; offscreen renders reviewed (see `REGRESSION-RESULTS.md`); native minimum-window review pending.**

## Cause

- **Ring captions ("Level N")** were drawn by the painter outside the label system. Each sat at its ring's widest empty arc whenever the ring radius exceeded 24 pt. They never checked labels, discs, links, the viewport edge or each other, and at a compressed canvas the rings are close together. That is NQ-2.
- **The secondary-label budget** was `22 + zoom term` regardless of canvas size, so a compact canvas tried to name as many folders as a large one.
- **Placement ran on every body evaluation.** `pointer` is `@State` and changes on every mouse move, so labels were re-placed on every move.

## Approach (Prototype B encodings unchanged)

Priority order:
1. selection;
2. hover;
3. current centre;
4. first-ring (major) folders;
5. remaining folders by size;
6. ring captions last.

This is the existing label order with captions now explicitly below it.

- `StructuredExplorerLayout.ringCaptions` (`SourcesShared/StructuredExplorer.swift`) runs after labels:
  - Each shown ring tries the middles of its six widest empty arcs, and the text must fit along the arc.
  - It takes the first spot that stays inside the view and clears every placed label footprint (+3 pt), every disc (+2 pt) and every other caption (+4 pt).
  - A ring with no such spot is left uncaptioned. Its ring line still draws, and the Inspector and spoken text give levels.
  - No captions at all when rings are drawn less than 30 pt apart (`captionRingSpacing`).
  - Text is measured with the real font (`StructuredExplorerPainter.captionSize`, 9.5 pt medium), not character counts.
- **Density.** The secondary-label budget scales with canvas area against a 1100×600 reference (minimum 6) and still grows with zoom. Selection, hover and centre are placed first regardless. No label is shrunk; plates keep the measured 11.5/10.5 pt text. Zooming reveals more, as before.
- **Caching.** `StructuredExplorerState.labels(...)` caches placement keyed by the layout returned, transform, canvas size, selection and hover. A pointer move that changes none of these reuses the placement. Hover changes, which happen only when crossing to another element, and camera or tree changes place again.

Unchanged: repeated names titled with their folder (`ComfyUI › models`), middle truncation with full path in Inspector and spoken text, labels as hit targets that return their own node, and selection labels clamped inside the viewport.

## Verification

| Check | Result |
|---|---|
| Captions inside view, clear of labels, discs and each other; none when rings < 30 pt apart. 72 cases: canvases 560×400 (≈ 1000×700 window with Navigator and Inspector), 760×480, 1100×600 × Levels 1–6 × zoom 40%, 100%, 250%, 600%, with a selection and a hover | PASS 72/72, 111 captions placed |
| Legacy placement on the same 72 cases | collided with a label/disc/caption or clipped **57 times** |
| Compact canvas names fewer secondary labels (7 incl. selection vs 16 at 1100×600); selection named; no plate shrunk | PASS |
| Existing: selection named first; no overlaps; inside view in edge/zoom/window cases (640×360 and 1000×640, 40%/100%/400%) | PASS (retained) |
| Existing: label interiors (horizontal and rotated) hit their own node at fit and zoom | PASS (retained) |
| Existing: largest top-level folder named at every Levels setting | PASS (retained) |
| Placement runs once per drawn state; pointer moves reuse it | PASS (hosted) |

Repeated names, long paths and dense siblings come from the existing fixtures (`ComfyUI › models` / `.ollama › models`, 40-folder crowd, 7-level chain) and the preserved snapshot used by the renders.

Visual review: offscreen renders from `scripts/benchmark-structured-explorer.sh` cover the minimum window, the overview, zoomed in and out, levels 1/2/4/6, and light and dark. They are listed in `REGRESSION-RESULTS.md`. Expanded-Inspector and native 1000×700 window checks remain for the native session.
