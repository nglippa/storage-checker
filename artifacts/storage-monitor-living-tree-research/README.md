# Storage Monitor — Living Tree research milestone (2026-10-29)

Work branch `research/living-tree-prototypes` in the worktree `~/storage-checker-lt-research`, based on `873e069`. Uncommitted; nothing pushed, merged, tagged, packaged or installed.

## Protected and unchanged

- The release candidate `873e069` on `v2.1-rc`.
- The 2.1.0 DMG, `build/release-artifacts/2.1.0-9-20261029T063406Z/Storage-Monitor-2.1.0.dmg`, SHA-256 `3484abea58524cd090808714e38672cc0f82a628d3b42b9c797c66674f774f0c`. Its checksum was re-checked at the end; see `verification/rc-integrity.txt`.
- The main checkout's untracked files.
- The running dev viewer (PID 85896, built from the main checkout).
- All work ran in the worktree, which has its own `build/`.

No production database, preference, LaunchAgent, installed app or Full Disk Access setting was touched. The catalog was read only through `cp -c` clones under `/private/tmp`.

## Deliverables

| | |
|---|---|
| `REFERENCE-REPOSITORIES.md` | What `~/ref-repos` actually contains (npm packages, not clones; `web-gl-tree` absent), algorithms, licenses |
| `MONITORING-FLICKER-REPORT.md` | P0: hover annotation → Charts pads the x scale → point leaves the pointer → oscillation. Fixed; 8/16 → 16/16 |
| `CAMERA-INPUT-REPORT.md` | P0: pixel-precise mice were treated as trackpads (pan or orbit). Scrolling now zooms on every device |
| `PROTOTYPE-A/` | Organic Storage Tree: README, measurements, screenshots |
| `PROTOTYPE-B/` | Structured Explorer: README, measurements, screenshots |
| `COMPARISON.md` | Side-by-side scores, measurements, **recommendation (B)**, risks, next steps |
| `visual-comparison/` | `comparison-board.png` (3×3), `comparison-closeups.png`, `full-resolution/` (all 34 captures) |
| `monitoring-evidence/` | Chart before and after renders |
| `verification/` | `SUMMARY.txt` and per-suite logs, chart geometry before and after, `measurements.json` and `.log`, `NATIVE-QA.md` |

## Code (prototype code is isolated; nothing is wired into the app)

- **Fixes:**
  - `SourcesGUI/OverviewView.swift` (chart);
  - `SourcesShared/LivingTreeCamera.swift`, `SourcesGUI/LivingTreeView.swift` (scroll mapping, momentum flag, Help text);
  - `LIVING-TREE-CAMERA.md`, `LIVING-TREE-3D.md` (input tables).
- **Tests:**
  - `tests/LivingTreeTests.swift` (updated, plus an 80-case regression);
  - `tests/CapacityChartGeometryTests.swift`, `tests/LivingTreeScrollRoutingTests.swift`, run by `scripts/test-chart-geometry.sh`.
- **Prototypes:**
  - `Prototypes/LivingTree/*` and the harness `scripts/prototype-living-tree.sh`;
  - `Prototypes/Showcase/ShowcaseApp.swift`, built by `scripts/build-prototype-showcase.sh` (QA app, bundle ID `local.macbook.storage-monitor.prototype-showcase`, never launched by the agent).
