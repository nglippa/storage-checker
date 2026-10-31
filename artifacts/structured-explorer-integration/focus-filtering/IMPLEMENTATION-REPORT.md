# Structured Explorer focus filtering — implementation report

Implemented in the existing renderer. **Native acceptance is pending; this is not a release-readiness claim.** No application was installed, packaged, promoted or released.

## Inspection and preservation

Read project `AGENTS.md`, inspected worktrees/status, and reviewed the hierarchy, layout, painter, input, explorer controller and acceptance records before implementation. Baseline: `/private/tmp/structured-filtering-baseline-20261031T111033Z` (448 existing files, HEAD/index/diff and protected artifact fingerprints). No matching active stabilization/native-QA process was found; other worktrees and their retained QA artifacts were left alone.

Existing cleanup Inspector changes, their controller/test edits and all prior artifacts are preserved. Final preservation evidence is in `preservation.json`. The staged diff and HEAD remain unchanged. Protected DMGs, preserved catalog and `v2.1-rc` remain unchanged. No production preferences, database, installed app or LaunchAgent was operated on.

## Existing implementation reviewed

| Area | Existing contract retained |
|---|---|
| Hierarchy / identity | `LivingTreeModel` is a bounded catalog snapshot; `LivingTreeKey.node(id)` and `.rest(folder)` are stable keys. Original nodes retain inventory IDs, true paths, parents, indexed bytes and coverage state. Grouped remainder elements remain aggregate navigation geometry. |
| Scale / accounting | `StructuredExplorerScale` uses square-root radius/width from indexed allocation relative to the visual root, with existing minimum sizes for tiny/unknown nodes. Share arcs use actual parent totals. Hidden storage is never redistributed. Index/accounting/cleanup/Trash code is unchanged by this task. |
| Selection | `InventoryExplorerController` owns the selection shared with Navigator/Inspector. Canvas actions use its existing `select(_:through:)` route; restoration reopens true ancestor rows and requests scrolling. |
| Navigation | Ordinary double-click/Return uses existing folder navigation; Up/Escape and breadcrumbs remain available. Isolation handles nested re-rooting/Up in memory and leaves browser navigation context intact until ordinary folder navigation is requested. |
| Depth / camera | Existing Levels 1…6 is reused relative to the visual root. Existing fit, reset-view, pointer zoom, pan, scroll/pinch interpretation and navigation transitions remain. A selected exception can retain its complete real chain beyond Levels. |
| Labels / hits | Existing measured horizontal/rotated plates, collision checks, viewport containment, label budget and ring captions remain. Matching/focused candidates get priority within that budget. Hidden nodes are excluded from labels/hits/arrows/virtual accessibility children; strong targets precede faded discs. |
| Performance | Existing bounded catalog/controller work, radial/label caches, text-width cache, culling and change-feed throttling remain. Current visibility is a separate bounded derived snapshot keyed by layout stamp/settings/selection. No new multi-layout cache or filesystem/catalog rebuild is introduced for size/focus changes. |
| Fallback | `LivingTreeRenderer.classic` remains selectable through the existing preference. The input layer's optional context-menu provider defaults to nil, preserving the classic menu. |
| Native status before this task | The 2026-10-29 stabilization record is **native acceptance blocked/partial**: sampled navigation/labels/keyboard/fallback evidence exists; physical input, complete hover matrix, VoiceOver and visible-frame timing remain open. This task does not supersede that record with headless claims. |

## Changes

- `SourcesShared/StructuredExplorerFiltering.swift`: exact decimal MB/GB presets and validated custom threshold; immutable derived matching/context/exception/visibility/focus sets and counts.
- `SourcesShared/StructuredExplorer.swift`: optional real visual root, full real ancestor retention for filtered selections, allowed hit/keyboard/label sets and prioritized label candidates. Defaults retain the existing behavior.
- `SourcesGUI/StructuredExplorerView.swift`: filter/isolation state, cached visibility, painter opacity, empty/selection explanations, breadcrumb/exit/Up/reset, folder path menus and accessibility actions. A 120 ms canvas cross-fade respects Reduce Motion. Node sizes, colors and storage totals retain their existing semantics.
- `SourcesGUI/StructuredExplorerFilterControls.swift`: compact Size, Dim/Hide, Focus, path actions and Reset; custom decimal entry with explicit units and validation. Root isolation is disabled rather than exposing a no-op action.
- `SourcesGUI/LivingTreeView.swift`: optional per-canvas menu closure; the classic default remains intact.
- Focused shared/state/hosted tests and reproducible benchmark/render scripts. Existing GUI suite runs the new shared tests.

Precedence, count definitions, interaction exceptions and catalog-read boundaries are specified in `FILTER-SEMANTICS.md`.

## Verification and review

See `REGRESSION-RESULTS.md` for exact commands, exit codes, initial failures/retries and skips; `PERFORMANCE-RESULTS.md` for raw measured costs and limits. The final focus-filtering harness passes 45/45 checks and produces 24 comparison images indexed in `SCREENSHOTS.md`.

Applied the available SwiftUI identity/data-flow/layout guidance and the located `swiftui-patterns.md` guidance during the initial implementation. No callable `swift-reviewer` agent exists in this running session; a read-only `repo-middle` Swift review was used instead. Findings were checked against source: redundant root isolation/Up fall-through and no-op root accessibility isolation action were corrected, label priority was bounded, and Navigator restoration evidence was strengthened. The final deep restoration case must fail rather than silently skip when its required target is absent.

The reports separate computed/rendered behavior from native acceptance. All native filter controls/context menus/keyboard use, physical mouse/trackpad interaction, minimum-window desktop rendering, transition pacing and VoiceOver are **NOT VERIFIED** for this implementation. The prepared isolated-bundle/disposable-catalog plan is `NATIVE-QA-PLAN.md`. No desktop QA window was launched or focused.
