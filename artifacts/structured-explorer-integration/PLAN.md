# Structured Explorer integration — resumed 2026-10-29

Objective: complete the selected Prototype B integration for review, with no release operations.

## Protected starting point

- Integration: `integration/structured-explorer`, HEAD `873e069dc88788d24d620b4f9f6ff1904ea52f6a`, in `~/storage-checker-structured-explorer`.
- Release candidate: `v2.1-rc`, same HEAD, in `~/storage-checker`.
- Research: `research/living-tree-prototypes`, same HEAD, in `~/storage-checker-lt-research`; preserve all uncommitted research.
- Protected 2.1.0 (9) DMG SHA-256: `3484abea58524cd090808714e38672cc0f82a628d3b42b9c797c66674f774f0c` (confirmed at resume).
- No commit, push, merge, DMG build, installation, production scan, preference change, LaunchAgent change or background-worker operation.

## Integration architecture (already implemented at handoff)

Promote Prototype B's radial tidy hierarchy, concentric levels, proportional discs/links and parent-share arcs into `SourcesShared/StructuredExplorer.swift` and `SourcesGUI/StructuredExplorerView.swift`. Draw the existing `LivingTreeController.model`; retain `InventoryExplorerController` as the selection owner and `InventoryBrowserModel.navigate` as navigation. Keep `LivingTreeView` behind `inventory.livingTree.renderer=classic`; absent/unknown values use Structured Explorer. Carry forward research chart overlay and wheel routing fixes without changing catalog schemas or cleanup safety.

## Remaining execution

1. Reproduce the handoff state with model tests and offscreen production-view captures using a disposable APFS clone of the preserved verification catalog.
2. Harden selected/hovered/root label placement and rotated-label tests; check camera/layout cache selection transitions. Preserve the selected design.
3. Correct benchmark semantics: separate whole-page drawing from screenshot settling time; require geometry/hit-test checks and report performance limits honestly.
4. Build monitor and viewer, run model, inventory, browser, chart geometry and scroll-routing regressions. Use only bounded disposable fixtures. Serialize builds.
5. Inspect light/dark, selection, deep-selection, depth, minimum-window, explored-folder and fallback renders; produce an updated side-by-side board and measurements.
6. Write the requirement status matrix, architecture, changes, prototype provenance, performance, accessibility, native checklist and rollback instructions. Recheck RC/DMG and research integrity.

Native desktop input and VoiceOver checks require separate explicit permission under AGENTS.md. Offscreen hosted-view and model tests do not count as native interaction success.
