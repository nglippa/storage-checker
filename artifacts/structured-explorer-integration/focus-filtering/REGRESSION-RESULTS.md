# Regression results — 2026-10-31

Final automated checks pass. Native acceptance is **PENDING / NOT VERIFIED**, not inferred from these results.

## Final commands and outcomes

Run from `/Users/nicholaslippa/storage-checker`. In the table, **SDK** means the exact environment prefix `STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. Builds/tests use isolated fixtures under `/private/tmp`; no desktop input or visible app launch was used. Structured command arguments, timestamps where collected, and exit codes are retained in `logs/final-commands.json`.

| Exact command | Exit | Result / log |
|---|---:|---|
| `scripts/build.sh` | 0 | Fresh monitor bundle built; `logs/monitor-build.log` |
| `'build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor' self-test --data-dir /private/tmp/structured-filter-final-monitor-data.gyttMl` | 0 | **235 tests passed**; `logs/monitor-self-test.log` |
| SDK `scripts/test-structured-filtering.sh` | 0 | **23 focused shared checks passed**; `logs/shared.log` |
| SDK `scripts/test-gui.sh` | 0 | **960 GUI model/read-only checks passed**, plus existing notification/read-only binary checks; `logs/gui.log` |
| SDK `scripts/build-gui.sh` | 0 | Fresh development viewer built/signed; `logs/viewer-build.log` |
| SDK `scripts/test-inventory-model.sh` | 0 | **69 inventory/controller tests passed, 0 failed**; `logs/inventory-model.log` |
| `build/InventoryIntegrationTests` | 0 | **350 inventory tests passed** using the freshly compiled integration binary; `logs/inventory-integration.log`. Compilation came from the earlier worker invocation of `scripts/test-inventory.sh`; its failed first runtime is recorded below. |
| SDK `scripts/test-chart-geometry.sh` | 0 | **52/52 hosted chart geometry, input routing and explorer-state checks passed**; `logs/chart-input.log` |
| `/bin/sh scripts/test-native-qa.sh` | 0 | **211 native-QA-runtime / existing Trash-safety assertions passed**, not a native desktop session; `logs/native-runtime.log` |
| SDK `scripts/test-cleanup-inspector-scroll.sh` | 0 | **10 PASS results**, including preserved cleanup Inspector scroll regression; `logs/cleanup-scroll.log` |
| SDK `scripts/benchmark-structured-filtering.sh /private/tmp/structured-filtering-baseline-20261031T111033Z/catalog.sqlite3 artifacts/structured-explorer-integration/focus-filtering` | 0 | **45/45 checks:** 24 PNG output checks and 21 hosted behavior/invariant checks; `logs/focus-filter-benchmark.log`, `measurements.json` |
| SDK `scripts/benchmark-navigation.sh /private/tmp/structured-filtering-baseline-20261031T111033Z/catalog.sqlite3 artifacts/structured-explorer-integration/focus-filtering/navigation.json focus-filtering` | 0 | **0 failures**, no renderer-switch catalog tree builds; `logs/navigation-benchmark.log`, `navigation.json` |
| `/usr/bin/codesign --verify --deep --strict 'build/Storage Monitor.app'` | 0 | Development signature valid; `logs/codesign.log` |
| `/usr/bin/plutil -extract CFBundleIdentifier raw -o - 'build/Storage Monitor.app/Contents/Info.plist'` | 0 | `local.macbook.storage-monitor.viewer.dev`; `build-evidence.json` |
| `git diff --check` | 0 | No whitespace errors; `logs/diff-check.log` |

The freshly built inventory-model suite confirms existing Inspector/review-queue/Trash synchronization and safety. This task does not change their implementation. The standalone shared checks also run inside the GUI model suite; those counts overlap and must not be summed as unique tests.

## Focused requirement coverage

| Requested regression | Automated evidence |
|---|---|
| 1. Threshold boundaries | Decimal byte/unit checks, one-byte custom minimum, fractional-byte flooring, invalid/overflow rejection and 500 MB ±1-byte comparisons |
| 2. Exact matches | Inclusive `>=` comparison includes exactly 500,000,000 bytes |
| 3. Empty results | Impossible threshold retains visual root, reports zero eligible descendant folders and `noMatches`; UI provides Show All |
| 4. Ancestors | Hide retains real ancestor paths; every retained deep node's displayed parent equals its actual model parent |
| 5. Selected exceptions | Below-threshold selection remains visible/emphasized; unknown/group context is distinguished; All never claims below-filter selection |
| 6. Isolation | Valid folder becomes visual root; inventory ID, absolute path and allocated size remain unchanged |
| 7. Reset | State returns All/Dim/focus-off/isolation-off and returns the entry selection; UI restoration uses the same tested shared-selection route |
| 8. Nested isolation | State retains first entry selection; hosted double-click nests isolation without changing browser root; Up follows actual parents |
| 9. Dim/Hide precedence | Dim preserves geometry; Hide applies before subtree focus; hidden descendants do not reappear merely because Focus is active |
| 10. Totals | Original IDs/bytes remain unchanged across thresholds, isolation and repeated real/dense/deep render cycles; original parent totals remain the scale/share inputs |
| 11. Repeated names | Same-name folders retain distinct IDs; one may match while the other is hidden |
| 12. Deep hierarchy | 40-level synthetic selected chain retains every direct parent, including beyond Levels |
| 13. Selection / Inspector / Navigator | Hosted click and path/isolation actions preserve shared ID, true path/size; exit restores a deep entry's expanded ancestors, visible row and scroll request. The request is checked before the Navigator consumes it. |
| 14. Filter during navigation | Ordinary browser navigation while filtered clears stale isolation while retaining the threshold |
| 15. Stable identities | Derived sets reference original `LivingTreeKey` values; ordinary threshold/focus changes preserve radial nodes/radii; duplicate/deep identity assertions pass |
| 16. No unnecessary catalog work | State/visibility have no reader; hosted threshold/Dim/Focus changes leave radial builds and tree catalog-build/poll counts unchanged. Normal selection may load needed Navigator pages. |
| 17. Minimum labels | Small-viewport shared label/collision/allowed-target checks; minimum light/dark panel/page renders; minimum and deep canvas timings |
| 18. Classic fallback | Default input menu unchanged; classic panel/page renders; renderer-switch benchmark records zero tree builds; no classic renderer deletion |

Headless input tests deliver `CGEvent`-derived `NSEvent` scrolls directly to the input view and invoke production closures in process. They never post input to the desktop. They cover line/pixel zoom both directions and limits, modifier/sideways pan, no accidental selection/orbit, hidden targets, keyboard movement calculations, context-menu action callbacks and nested double-click behavior. Real keyboard delivery, physical devices and menu operation remain pending.

## Initial failures and retries (retained, not concealed)

| Attempt | Exit / observation | Disposition |
|---|---|---|
| Initial hosted state compilation / red tests | 1; missing filter-state APIs, then a SwiftUI expression too complex to type-check | Added state and split accessibility construction. `logs/initial-shared-state-red.log`, `logs/initial-hosted-compile.log`; final build/chart checks pass. |
| Earlier hosted chart run | 1; 48/49, compact/light hover callout extended one point beyond chart | No chart code was changed. Final 52/52 run passes; this does not certify the pending native chart matrix. `logs/initial-chart-one-point-failure.log` |
| Initial new benchmark compilation | 1; optional fixture direct-byte values required unwrapping | Corrected deterministic fixture initialization; final harness compiles/runs. `logs/initial-benchmark-compile.log` |
| Initial new benchmark behavior run | 1; 31/33, two restoration assertions checked scroll request after Navigator consumed it | Captured route immediately, retained row/selection/ancestor assertions, and made required deep-target absence fail explicitly. Final 45/45 passes. `logs/initial-benchmark-scroll-assertion.log` |
| Intermediate timing harness | 0; 45/45, but selection timing followed Reset | Corrected measurement to enable 1 GB Hide before selecting, then rebuilt/reran all 45 checks. `logs/intermediate-benchmark.log`; final data is `measurements.json`. |
| Worker monitor self-test, twice | 1; live swap-usage check failed in worker context (49 PASS before failure) | Unrestricted root rerun passed all 235; fresh final build/self-test also passes235. Worker logs retained. No monitor/accounting test was weakened. |
| Worker inventory-model suite | 133; `Trace/BPT trap: 5` before test results | Same binary rerun at root passed69; final fresh root script also passed69. `logs/worker-inventory-model.log` |
| Worker `scripts/test-inventory.sh` | 1; entry-limit checkpoint reported interrupted/0 entries | Freshly compiled binary rerun at root passes all350. `logs/worker-inventory-integration.log` |
| Worker `scripts/test-native-qa.sh` | 126; existing script is not executable | Invoked the unchanged script with `/bin/sh`; 211/211 assertions pass. `logs/worker-native-script-permission.log` |

The existing cleanup Inspector weak-capture compiler warning remains visible in build logs. No unrelated warning-suppression or storage-engine edits were made.

## Native skips — each is NOT VERIFIED

No native QA window was launched, activated, focused or operated. Pending: actual Size/Dim/Hide/custom popover operation; native Focus/transition pacing; path/isolation/exit/Reset controls; right-click menu delivery; real click/double-click/Return/Escape/Tab/arrows; Inspector/Navigator scrolling in a displayed window; minimum-window desktop rendering in both appearances; real wheel, trackpad pinch/scroll/inertia/drag; native classic fallback switching; VoiceOver and control announcements. See `NATIVE-QA-PLAN.md` for the isolated-bundle/disposable-catalog procedure.

Comparison images are offscreen implementation evidence, indexed in `SCREENSHOTS.md`. Black/blank AppKit List regions in full-page captures are disclosed there. Headless passes do not establish release readiness.
