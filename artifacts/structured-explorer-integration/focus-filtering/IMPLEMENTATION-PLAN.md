# Structured Explorer filtering implementation plan

**Goal:** Add size thresholds, dim/hide, path isolation and focus to the existing radial renderer.
**Spec:** User's 2026-10-31 mission; this plan implements that authorized scope.
**Architecture:** Keep the immutable bounded LivingTreeModel, existing radial geometry and shared selection. Derive visibility separately; re-root layout in memory for isolation. Preserve physical identity, parent edges and indexed allocated byte values. Cache visibility by layout stamp, settings and selection. Do not reload the catalog for filters.
**Stack:** Existing SwiftUI/AppKit/Canvas and Foundation-only shared models; no dependencies.

## Boundaries and preservation

- Baseline: `/private/tmp/structured-filtering-baseline-20261031T111033Z` (448 files, HEAD/index/diff/status recorded).
- Preserve cleanup Inspector fix, tests and all pre-existing artifacts. No cleanup/Trash/accounting/schema changes.
- Other worktrees have retained QA artifacts; no matching active QA/stabilization process was observed. No editing those worktrees.
- No desktop launch/focus/input. No production preferences/databases/LaunchAgents, installed apps, protected release, DMG, package, commit, merge, push or release.
- Exact swiftui-patterns guidance found and read; no swift-reviewer agent is available. Use bounded repo-middle review instead and disclose that substitution.

## Tasks

1. **Shared visibility and geometry contract** (repo-middle, serialized writer): add `SourcesShared/StructuredExplorerFiltering.swift`, focused tests and runner. Add optional visual root/full-ancestry selection retention to StructuredExplorerLayout; optional visibility sets for labels, hit testing and keyboard moves. Defaults preserve existing renderer behavior. Observe failing tests, implement and run them. Preserve all bytes/parent links and avoid synthetic reparenting in filtered paths.
2. **State and native controls** (primary): add in-memory settings/isolation state to StructuredExplorerState, visibility cache, compact native controls/custom validation, count/exception/empty explanations, isolation breadcrumb/exit, focus/path actions and keyboard/AX actions. Reuse Levels. Extend pointer layer only with an optional menu provider; classic default stays unchanged.
3. **Existing painter integration** (primary): skip hidden primitives, apply restrained opacity to branches/discs/labels, prioritize emphasized hit targets, filter labels before collision placement. Preserve colors, scale, links, camera and Inspector/Navigator shared selection.
4. **Headless verification and artifacts** (primary, grunt for bounded command/render support): fresh builds; shared/view/controller/inventory/monitor/chart/scroll regression suites; existing structured/navigation benchmarks on disposable APFS clones; focused transition/read-count/dense/minimum-window measurements and comparison renders. Never infer physical interaction or VoiceOver from headless evidence.
5. **Review and reporting**: bounded Swift review, verify findings, inspect rendered PNGs, preservation manifest and protected release hash checks. Deliver requested reports and native QA plan. Stop without promotion or release.

## Review focus

- Selected node below size/depth limits: retain actual ancestor chain, explicit exception; never fabricate parent links.
- Unknown/partial sizes and hidden large children: no logical-size substitution, aggregation or redistribution.
- Isolation while navigation/selection/catalog changes: reconcile invalid roots, retain true paths, restore selection only on explicit exit/reset.
- Hidden/faded hit targets, labels and keyboard traversal: resolve from one visibility snapshot; no invisible targets stealing input.
- Root-relative depth, repeated names, deep chains and minimum windows: valid continuous hierarchy, bounded labels and truthful counts.

Each is covered by focused tests or explicitly listed as pending native verification.
