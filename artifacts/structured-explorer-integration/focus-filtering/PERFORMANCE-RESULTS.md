# Performance results — 2026-10-31

Measured targets, not release acceptance. All commands exited **0** for the final recorded runs.

## Method and data

- Command: `STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/benchmark-structured-filtering.sh /private/tmp/structured-filtering-baseline-20261031T111033Z/catalog.sqlite3 artifacts/structured-explorer-integration/focus-filtering`.
- Disposable APFS clone of the preserved 2,959,505-node catalog. Pending reconciliation/prune rows were cleared only on this benchmark clone to compare settled indexed sizes. The separate navigation benchmark retains pending reconciliation.
- Final real bounded model: 2,717 elements; baseline layout: 101 primitives. Dense QA fixture: 2,995 elements, 2,958 placed primitives at Levels 6. Deep QA: same fixture with a 40-level selected chain at Levels 2 (212 baseline primitives).
- Each operation: 24 samples, derived state + labels + actual Canvas raster at 2×. Real/dense standard canvas 1100×560; minimum/deep canvas 600×300. This is warm synchronous computation/raster cost, not full SwiftUI invalidation, display pacing, physical input, or a first-visible-pixel measurement. Isolation samples include in-memory radial re-layout; they do not include ordinary database navigation.
- No new multi-layout cache was added. Existing radial caches are reused; visibility and label snapshots are bounded to the current key. The hosted test confirms threshold, presentation and focus changes do not increase radial builds or tree catalog-build/poll counts.

## Operation costs

Milliseconds: **p50 / p95 / max**. Quantiles use the nearest observed sample (`round((n−1)×q)`, upper median for 24 samples); maxima and raw samples are also retained. Selection samples explicitly enable the 1 GB Hide filter before selecting a real node. Every observed sample is below the 100 ms target; the largest was 22.04 ms on dense isolation exit.

| Operation | Real standard | Real minimum | Dense QA | Deep QA |
|---|---|---|---|---|
| Threshold | 1.25 / 1.34 / 1.34 | 0.85 / 0.92 / 1.02 | 15.56 / 17.17 / 19.02 | 2.03 / 2.11 / 5.89 |
| Dim / Hide | 1.17 / 1.23 / 1.38 | 0.89 / 0.96 / 1.03 | 16.26 / 17.44 / 18.16 | 2.04 / 2.12 / 2.16 |
| Focus / path | 1.38 / 1.43 / 1.55 | 0.91 / 0.92 / 1.00 | 16.57 / 17.15 / 18.26 | 2.10 / 2.14 / 2.34 |
| Enter isolation | 1.61 / 1.70 / 2.25 | 1.70 / 1.74 / 1.86 | 2.62 / 2.77 / 2.94 | 2.23 / 2.38 / 2.59 |
| Exit isolation | 2.06 / 2.13 / 2.44 | 1.60 / 1.63 / 1.72 | 20.69 / 21.61 / 22.04 | 8.43 / 8.70 / 9.60 |
| Reset | 1.20 / 1.40 / 1.42 | 0.92 / 0.93 / 0.95 | 17.36 / 18.55 / 19.47 | 4.72 / 4.89 / 4.95 |
| Selection with Hide active | 1.26 / 1.39 / 1.43 | 0.88 / 0.89 / 0.91 | 14.39 / 14.89 / 14.93 | 5.25 / 5.37 / 5.58 |

## Navigation with pending reconciliation

Command: `STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/benchmark-navigation.sh /private/tmp/structured-filtering-baseline-20261031T111033Z/catalog.sqlite3 artifacts/structured-explorer-integration/focus-filtering/navigation.json focus-filtering`.

This existing benchmark measures app navigation request → catalog tree read → layout/labels ready, with a 2-second inventory refresh, one pending reconciliation row and no change journal. No visible window is created. Zero failures; zero tree builds during renderer switching.

| Operation | Samples | p50 ms | p95 ms | Max ms |
|---|---:|---:|---:|---:|
| Cold entry | 6 | 305.19 | — | 358.06 |
| Warm entry | 8 | 82.63 | — | 106.88 |
| Revisit | 8 | 81.13 | — | 103.04 |
| Up | 22 | 102.54 | 112.59 | 113.93 |

Cold entry still costs hundreds of milliseconds; no repeated 1–3-second delays appeared in this run. Native stabilization's stricter Up target and first-visible-frame acceptance are not re-certified by this measurement.

## Memory and limits

Process physical footprint (MiB), sampled after cycles 1, 6, 12, 18 and 24:

- deep-QA: 294.33 → 297.13 → 297.14 → 297.14 → 297.14.
- dense-QA: 296.00 → 296.88 → 291.30 → 291.31 → 291.31.
- real-minimum: 294.67 → 287.55 → 287.55 → 287.58 → 287.58.
- real-standard: 289.05 → 289.06 → 289.06 → 289.06 → 289.06.

The short sample series levels off or falls after warm-up; it does not establish long-duration leak freedom or a total memory budget. The process had already captured many offscreen pages before these samples. Navigation's separate process grew from 7.4 to 111.9 MiB while loading/warming the catalog/UI; that is not a filtering leak measurement.

Machine load, warmed filesystem/cache state and offscreen rendering limit generalization. Physical trackpad/wheel feel, native transitions, minimum-window display pacing and VoiceOver are **NOT VERIFIED**. See `NATIVE-QA-PLAN.md`.

Raw samples: `measurements.json`, `navigation.json`; final command logs are retained in `logs/`.
