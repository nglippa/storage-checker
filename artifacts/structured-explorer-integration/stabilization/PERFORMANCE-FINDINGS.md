# P0 — Structured Explorer navigation latency

> **Native update, 2026-10-29:** The authorized session is complete; full acceptance remains partial. See [native results](native-qa-20261029T172929/NATIVE-RESULTS.md) for measured outcomes, incomplete checks and verified cleanup. The original implementation-phase record below is retained. Automated suites were not rerun during native QA.

Status: **root cause demonstrated and repaired; headless end-to-end measurements pass; native acceptance pending.**

## Root cause

`LivingTreeController.rebuild()` (`SourcesGUI/LivingTreeView.swift`) throttles same-folder rebuilds so rapid inventory updates coalesce. The throttle was implemented by setting `building = true` and sleeping for the rest of the interval: **1.5 s** with a change journal, **5 s** without one. `building` is the same flag that means "a catalog read is in flight". When the user opened another folder during that sleep, `show(root:)` → `rebuild()` saw `building == true`, recorded `buildPending` and returned. The new folder's read therefore waited for the old folder's throttle sleep to end.

The native QA catalog had pending reconciliation work and no change journal. The inventory reloaded every ~2 s (`inventory.load` cadence in `native-qa/native-performance.log`), and every change notice requested a same-folder rebuild, so a 5 s throttle sleep was almost always in progress. That matches the native evidence exactly:

| Native event (log) | Frame committed | New tree read finished | Read work |
|---|---:|---:|---:|
| open 115 at 241.79 s | +77 ms | 243.97 s (+2177 ms) | 40.4 ms |
| Up to 15 | +43 ms | +1522 ms | 195.5 ms |
| Up to 1 | +46 ms | +2723 ms | 74.4 ms |

Reads for folder 115 then recur exactly every ~5.0 s (243.97, 249.10, 254.12, 259.35 …), which is the throttle cadence. The delay was **waiting, not CPU work**: the read itself took 40 ms.

Offscreen benchmarks missed it for two reasons. `benchmark-structured-explorer.swift` deletes `inventory_reconcile`/`inventory_prune_jobs` in its clone, which removes the churn. And its pan/zoom/frame metrics start after the tree is already loaded.

## Repair

The same-folder throttle is now a separate, cancellable `throttle` task that does not hold `building`. A rebuild for a **different** folder cancels it and reads at once. Same-folder coalescing is unchanged: there is at most one pending throttle and at most one build in flight, and a change during a build is still re-checked. No caching, preloading, polling or storage-accounting change was made. Stale data is never shown: the existing `guard trunk == self.trunk` still discards a superseded read.

Diagnostic counter added: `LivingTreeStatistics.throttledRebuilds`.

## Instrumentation

Two causally ordered measurements were used. Neither uses screenshots or concurrent input.

1. **Regression test** (`tests/InventoryModelTests.swift`, run by `scripts/test-inventory-model.sh`). It waits until the controller reports a throttled same-folder rebuild (`statistics.throttledRebuilds` increments), then opens a child folder and its parent, timing `show()` until `model.root` is the new folder.
   - Before the fix: **FAIL**, 256 ms and 274 ms on two runs (the remaining throttle wait; the fixture read takes ~20 ms).
   - After the fix: **PASS** on three consecutive runs, 21 / 25 / 25 ms into the folder and 23–25 ms back up.
2. **End-to-end navigation benchmark** (`scripts/benchmark-navigation.sh` + `.swift`, new). It uses an APFS clone of the preserved QA snapshot `build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3` (1.46 GB; SHA-256 checked unchanged before and after). Reconciliation rows are kept, and the inventory reloads plus sends a change notice every 2 s, as natively.
   - Each sample runs in the app's order: `browser.navigate` → page load → `tree.show` → tree read → Structured Explorer layout, labels and ring captions for a 900×520 canvas. Timing uses monotonic `DispatchTime` per operation, and operations are strictly sequential.
   - Navigation starts at varied offsets inside the 2 s refresh cycle.
   - Before/after uses the same benchmark, catalog and binary sources. The only difference is the throttle block in `LivingTreeView.swift`, compiled from a derived pre-fix copy via `LIVING_TREE_VIEW`.

The benchmark confirmed the native condition: tree without change journal = **true** (5 s throttle), 1 pending reconcile row, and 15–17 throttled same-folder rebuilds during each run.

## Before / after (same catalog, same machine: Mac16,11, M4 Pro, macOS 27.0)

| Operation (ms) | n | Before p50 | Before p95 | Before max | After p50 | After p95 | After max |
|---|---:|---:|---:|---:|---:|---:|---:|
| Folder enter, cold (first visit) | 6 | 4098.6 | — | 4591.9 | 328.3 | — | 562.9 |
| Folder enter, warm | 8 | 3306.7 | — | 4124.7 | 139.2 | — | 326.2 |
| Folder revisit | 8 | 100.1 | — | 3263.9 | 82.0 | — | 108.2 |
| Parent (Up) | 22 | 111.6 | 4508.3 | 4719.2 | 103.0 | 114.1 | 220.2 |
| Tree read wait after `show` | 22 | 275.3 | 4202.6 | 4575.1 | 89.4 | 313.8 | 335.6 |
| Layout + labels + captions (first frame computation) | 22 | 1.2 | 2.0 | 160.3 | 0.9 | 1.9 | 26.1 |
| Selection → laid-out, labelled frame | 24 | 0.3 | 0.4 | 0.5 | 0.3 | 0.3 | 0.3 |
| Levels change → laid-out, labelled frame | 12 | 1.0 | 1.5 | 1.7 | 0.9 | 1.7 | 1.8 |
| Mount classic renderer + first offscreen frame | 6 | 71.2 | — | 350.2 | 70.8 | — | 315.5 |
| Mount Structured Explorer + first offscreen frame | 6 | 33.0 | — | 76.2 | 31.2 | — | 107.6 |

p95 is reported only for n ≥ 10. The final rebuilt-binary run is recorded in `REGRESSION-RESULTS.md`.

### Against the targets

| Target | Result | Status |
|---|---|---|
| Warm view navigation < 300 ms | warm enter p50 139 ms, max 326 ms; revisit max 108 ms | PARTIALLY VERIFIED: 1 of 8 warm samples exceeded the target by 26 ms (see limits) |
| Ordinary node selection < 100 ms | 0.3 ms computational | VERIFIED headless (computation); native frame timing pending |
| Parent navigation < 200 ms | p50 103, p95 114, max 220 ms | PARTIALLY VERIFIED: p95 met; 1 of 22 samples at 220 ms |
| First useful frame < 300 ms with data loaded | layout + labels p95 1.9 ms after the read | VERIFIED headless (computation) |
| No routine 1–3 s blocking transitions | max 563 ms (cold), was 4.7 s | VERIFIED headless |
| No disproportionate memory | footprint 7.0 → 65.0 MiB after the full run (before: 7.1 → 76.8 MiB) | No increase observed |

**Cold first visits are bounded by the catalog read itself.** The largest top-level folders take ~300–560 ms to read on first visit; native `livingTree.read` was 300 ms for the root. Those samples are real database work, not waiting, and they were not hidden by preloading.

The remaining warm outliers (≤ 326 ms) occur when a navigation lands while a same-folder read is already in flight. The new folder's read starts as soon as that read ends (≤ one read, ~90–300 ms). Cancelling an in-flight SQLite read was not attempted: the reader exposes no safe mid-query cancellation, and the superseded result is already discarded.

The renderer-switch mounts caused **0** catalog tree builds.

## Limits

- The figures are headless, computational and offscreen. They do not include compositor frame pacing or the native first visible frame. Native acceptance must re-measure with the app's existing performance trace (`folder.open` → `frame.committed` → `livingTree.read` lines, as in `native-qa/native-performance.log`).
- The "Storage → Structured Explorer" and "Monitoring → Storage" section switches were not separately timed in this headless run. The mount figures above cover the explorer canvas only. The full section switch needs the native session.
- One pre-fix benchmark attempt stopped before navigation because the initial tree did not build within 8 s; the immediate rerun completed. It was not reproduced and is not counted.
