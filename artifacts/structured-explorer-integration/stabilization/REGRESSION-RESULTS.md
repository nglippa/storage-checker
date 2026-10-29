# Regression results — stabilization (2026-10-29)

> **Native update, 2026-10-29:** The authorized session is complete; full acceptance remains partial. See [native results](native-qa-20261029T172929/NATIVE-RESULTS.md) for measured outcomes, incomplete checks and verified cleanup. The original implementation-phase record below is retained. Automated suites were not rerun during native QA.

Worktree `~/storage-checker-structured-explorer`, branch `integration/structured-explorer`, base `873e069`, uncommitted. Host Mac16,11 (M4 Pro, 24 GiB), macOS 27.0, macOS 26.5 SDK (`STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`). Both apps were rebuilt first, and all suites ran serially against those builds in one pass. Logs are in `logs/`.

| # | Command | Exit | Result | Previous |
|---|---|---:|---|---:|
| 1 | `scripts/build.sh` (monitor) | 0 | built, ad-hoc signed | — |
| 2 | `scripts/build-gui.sh` (viewer) | 0 | built, ad-hoc signed | — |
| 3 | `"build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor" self-test` | 0 | **235** passed | 235 |
| 4 | `scripts/test-gui.sh` (viewer model, Structured Explorer, labels, captions, gestures) | 0 | **937** passed | 934 |
| 5 | `scripts/test-inventory.sh` (inventory integration) | 0 | **350** passed | 350 |
| 6 | `scripts/test-inventory-model.sh` (inventory browser, navigation throttle) | 0 | **68** passed, 0 failed | 67 |
| 7 | `scripts/test-chart-geometry.sh` (chart geometry + functional hover + scroll + state) | 0 | **42 of 42** | 24 |
| 8 | `scripts/benchmark-structured-explorer.sh <snapshot>` (renders, hosted input, frame budget) | 0 | **43** checks, 0 failures (`measurements.json`) | 43 |
| 9 | `scripts/benchmark-navigation.sh <snapshot> … after-final` (new) | 0 | 0 failures, 0 renderer-switch tree builds | new |

`<snapshot>` = APFS clone (`cp -c`) of the preserved `build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3`. Its SHA-256 was compared before and after all runs: **unchanged**.

Compiler warnings: only the pre-existing `CleanupInspectorView.swift:174` weak/strong capture warning. It was left unchanged because cleanup is out of scope.

## New tests (all failed, or could not detect the defect, before the change)

| Defect | Test | Before | After |
|---|---|---|---|
| P0 navigation blocked by same-folder throttle | `InventoryModelTests`: folder opened while a rebuild is throttled | FAIL 256 / 274 ms (`logs/navigation-throttle-red.log`) | PASS 21–25 ms ×3 |
| P0 hover callout | `CapacityChartGeometryTests` functional hover ×3 configs, 47 readings each; text; empty plot; exit | path untestable (SwiftUI hover); visibility FAIL at left edge `x = -6` (`logs/hover-edge-red.log`) | PASS |
| P1 captions crowded | `LivingTreeTests` ring captions, 72 cases | legacy placement: 57 collisions/clips | PASS 72/72 |
| P1 label density | `LivingTreeTests` compact vs typical canvas | no size dependence | PASS (7 vs 16) |
| P1 double-click | `LivingTreeTests` first-click target, triple click | FAIL: opened neighbour, triple opened again (`logs/double-click-red.log`) | PASS |
| P1 reverse scroll | `LivingTreeScrollRoutingTests` end-to-end wheel/pixel/momentum/limits/pan | not covered end to end | PASS |
| Label recalculation per pointer move | `LivingTreeScrollRoutingTests` placement cache | not covered | PASS |

## Navigation benchmark, final rebuilt binaries (`measurements/navigation-after-final-rebuild.json`)

| Operation (ms) | n | p50 | p95 | max |
|---|---:|---:|---:|---:|
| Folder enter (first visit) | 6 | 111.4 | — | 133.1 |
| Folder enter (warm) | 8 | 100.9 | — | 122.8 |
| Folder revisit | 8 | 100.0 | — | 123.5 |
| Parent (Up) | 22 | 110.2 | 122.2 | 127.4 |
| Tree read wait after show | 22 | 73.5 | 95.8 | 111.0 |
| Layout + labels + captions | 22 | 0.9 | 1.6 | 5.4 |
| Selection → frame (computation) | 24 | 0.3 | 0.5 | 0.5 |
| Levels change | 12 | 1.4 | 2.3 | 3.0 |
| Mount classic / structured | 6 / 6 | 66.5 / 29.7 | — | 151.1 / 50.1 |

This run followed several reads of the same snapshot, so the OS page cache was warm. "First visit" is cold for the controller, not for the disk. The earlier post-fix run, with a colder cache, measured first visits at p50 328 ms and max 563 ms (`measurements/navigation-after.json`). Both are reported; neither is substituted for the other. Memory footprint across a full run varied 65–91 MiB between runs (offscreen hosting windows included), against 77 MiB for the pre-fix run, so no growth attributable to the change was observed.

## Classic fallback

Verified headlessly:
- The classic renderer still mounts and renders over the same controller (6/6 mounts in each navigation run, plus the classic renders `old-*.png` from the structured benchmark).
- Switching between classic and structured caused **0** catalog tree builds.
- Each renderer keeps its own camera: the structured camera lives in `StructuredExplorerState`, the classic in `LivingTreeController`; neither changed.
- The classic tree shares the corrected gesture interpreter (double-click/triple-click fix) and the navigation throttle fix.
- No production preference was written: benchmarks register defaults in memory only.

Native fallback switching remains a native check.

## Renders (`renders/`)

The minimum window light and dark, the overview light and dark, zoomed out and in, levels 6 and repeated names, all from this run's rebuilt sources. In the minimum-window render, the three "Level N" captions sit in empty arcs clear of every label and disc. The selection, centre and four major folders stay named.

## Skips

Nothing was skipped among the suites listed. Not run: universal/Intel builds and `scripts/build-dmg.sh` (packaging not authorized). No native GUI check ran in this phase; see `NATIVE-QA.md`.

## Protected state (checked after all runs)

- `~/storage-checker` HEAD `873e069dc88788d24d620b4f9f6ff1904ea52f6a`; status unchanged (`?? .DS_Store`, `?? artifacts/`, `?? docs/`). `master` not touched.
- `build/release-artifacts/2.1.0-9-20261029T063406Z/Storage-Monitor-2.1.0.dmg` SHA-256 `3484abea…74f0c`, unchanged.
- Research checkout status unchanged from `verification/protected-state.json`.
- No commit, push, merge, tag, package, install or LaunchAgent/preference/Full Disk Access change. No cleanup, Trash, storage-accounting or schema change.
