# Storage Monitor V2 Implementation Plan

> **For agentic workers:** Execute bounded passes using the repository's repo-middle/repo-grunt roles, one writer at a time. No commits.

**Goal:** Make existing storage exploration, careful cleanup review and storage-change explanation approachable and coherent.

**Architecture:** Preserve the shared browser/explorer selection, bounded Canvas renderer, camera and evidence controllers. Change presentation in the existing SwiftUI views. Use a small native typography/spacing vocabulary and reusable disclosure row; do not add a design framework or alter cleanup/diagnostic authority.

**Tech Stack:** SwiftUI, AppKit, Swift Charts, existing read-only SQLite models; macOS 14 deployment target, macOS 26.5 build SDK.

**Spec:** User's Storage Monitor V2 brief; prior visual evidence in `artifacts/visual-review/` and `UX-REFINEMENT-MILESTONE.md`.

## Global constraints

- Codex only, as clarified by the user. Preserve all pre-existing uncommitted changes.
- No desktop activation/input, strict QA launch, production/QA worker mutation, global settings, real-file cleanup, installation, packaging, commit or release.
- No changes to cleanup authority, evidence/provenance, process/protected-path checks, consent or recovery semantics. Diagnostic calculations and uncertainty remain intact.
- Keep native keyboard selection and repaired event-list focus behavior. Respect Reduce Motion.
- Minimum-window content is 1000×640 pt (1000×700 outer-window equivalent); assess both appearances and desktop sizes.
- Native interaction remains NOT VERIFIED without an authorized attended session. Offscreen views do not establish click/focus behavior.

## Design decisions

Keep Storage and Monitoring as the two primary destinations. In Storage, let the visualization lead, use the Navigator as its synchronized outline, and make the Inspector an explanation of the selection rather than a second audit screen. Retain the native table for sortable rankings and cleanup multi-selection, with fewer, better grouped columns.

Use system typography, 8/12/16/20/24 pt spacing, restrained separators and the system accent. Primary values use title typography; helper text uses readable secondary styles. Use color to encode categories and meaningful pressure/change, not to decorate every section. Detailed accounting and evidence start collapsed.

Living Tree retains its existing geometry, hit testing, bounded caches, camera, transitions and 2D/3D identity. Improve viewport allocation, major-label readability, selection context and explicit labelled controls. Branch width remains an approximate monotonic representation of indexed allocation, not physical reclaimable bytes; lengths and positions express hierarchy, not quantity. Never silently reinterpret those measurements.

Monitoring uses a compact capacity/latest-change summary, a useful fixed chart height and a reserved event-list area. Connect chart points to events by exact measurement ID only. Filtered-out events are not silently selected or filters silently changed. Preserve gaps and container boundaries. Technical provenance remains expandable.

## Review focus

- Long paths and stale/unknown measurements: do not truncate away uncertainty or invent zero bytes.
- A selected branch changes destination: shared selection/path and return navigation must stay aligned.
- Cleanup evidence is incomplete/protected/in use: presentation must never imply consent establishes safety.
- Chart points have no matching visible event: selection must explain/avoid the mismatch, never map approximately to a different event.
- Short windows and open inspectors: list, chart and controls must remain reachable without overlap; keyboard behavior remains intact.

## Passes

### A/B — Design vocabulary and Living Tree
Files: `SourcesGUI/StorageDesign.swift`, `SourcesGUI/LivingTreeView.swift`, `SourcesGUI/InventoryExplorerView.swift` (viewport sizing only).
- [ ] Add small spacing/typography/disclosure primitives.
- [ ] Put labelled view controls outside the branch canvas; make 2D/3D, Fit, Reset, selection, help and parent navigation discoverable.
- [ ] Give selection a name, actual qualified size, share of parent and explicit Explore action; improve labels and contrast without new continuous rendering work.
- [ ] Increase the useful visualization share. Tree defaults to a collapsed Navigator with a visible Show Navigator control, and reserves at least 160 pt of outline when expanded. Atlas retains its outline.
- [ ] Build, render isolated views, inspect, and run relevant camera/model checks.

### C — Storage and Cleanup
Files: `SourcesGUI/InventoryView.swift`, `SourcesGUI/InventoryNavigatorView.swift`, `SourcesGUI/CleanupReviewQueueView.swift`; UI portion of `CleanupInspectorView.swift` only if necessary.
- [ ] Compose the capacity/folder header with a clear primary Review Cleanup action.
- [ ] Lead Inspector with name, qualified size, location, parent share, Explore and relevant loaded contents; disclose accounting and cleanup/safety details progressively.
- [ ] Group cleanup into Item / Review status / Storage columns, preserving native selection, sorting/filter APIs, freshness and read-only plan behavior.
- [ ] Give empty review states direct next steps without changing eligibility or evidence.
- [ ] Build, model-check shared navigation, capture and inspect.

### D — Monitoring and explanations
Files: `SourcesGUI/OverviewView.swift`, `SourcesGUI/HistoryView.swift`, `SourcesGUI/EventDetailView.swift`, presentation-only chart mapping in `Models.swift` with tests in `tests/GUIModelTests.swift`.
- [ ] Compact the default summary and latest-change preview; keep technical status and baselines available on demand.
- [ ] Make recorded trend readable, distinguish meaningful loss/recovery and add exact-ID chart/list selection plus accessible alternatives.
- [ ] Keep filters secondary and event rows focused on time, change, description and capacity; preserve native focus/keyboard fixes.
- [ ] Use short, well-spaced explanation sections and fully clickable evidence disclosure. Preserve all existing summary text, offset accounting, uncertainty and technical content.
- [ ] Build, run targeted/regression tests, capture minimum/desktop appearances and inspect.

### E — Integrated verification and evidence
- [ ] Run viewer, inventory-controller, inventory integration and monitor suites as applicable using disposable fixtures; record failures honestly.
- [ ] Verify cleanup/calculation source hashes against preserved baseline and review the final diff.
- [ ] Reuse the prohibited-activation capture method with a disposable catalog clone. Native interaction checks remain NOT VERIFIED.
- [ ] Produce exactly two new high-resolution PNG collages under `artifacts/storage-monitor-v2/visual-review/`, retaining original screenshots and labelled before/after comparisons.
- [ ] Document VERIFIED / PARTIALLY VERIFIED / BLOCKED / NOT TESTED results and outstanding native release gates.

Baseline: 63 source/test files and original working-tree patch preserved under `artifacts/storage-monitor-v2/baseline/`; viewer suite freshly passed **847** assertions using isolated `/private/tmp` fixtures.
