# Correctness fixes

## Current same-Mac lifecycle continuation

Branch `migration-readiness`, HEAD `6981c2da5ef1c4a1c528332eb0b1be1948721c39`, with uncommitted stabilization changes. Content fingerprint `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` binds 160 source, script, fixture and instruction files. Version remains **2.2.0 (10)**. This 160-file manifest covers the named compiler/test/tooling inputs, fixtures and root instructions/notices; historical151-file manifests had a narrower selection and are preserved separately. It is not a universal artifact checksum.

Current authority: [LOCAL-LIFECYCLE-RESULTS.md](LOCAL-LIFECYCLE-RESULTS.md), [REGRESSION-RESULTS.md](REGRESSION-RESULTS.md), [REMAINING-ISSUES.md](REMAINING-ISSUES.md) and [CHANGED-FILES.md](CHANGED-FILES.md). Same-Mac real setup/update/rollback are now supported and observed under bounded test identities. Historical blanket external-system requirements below no longer apply to those scoped transactions. Login persistence, permissions/notifications, physical Intel/macOS 14 remain separately pending; current waiting-state native confirmation is complete below.

The final continuation repairs disabled queued-work reporting: retains prior measurements/queue and coverage, reports waiting, stops progress claims, and offers Settings. Reliable disabled overrides are distinct from unknown; currently running indexers remain active. Errors, low-space pauses and unavailable event history take precedence. Twenty waiting/lifecycle regressions and two neutral freshness-caption assertions are included in the final viewer total. The subsidiary outline/Atlas notes now qualify prior measurements without claiming that a recheck is running. It adds no timer/process/write and uses existing status evidence, which can lag by about 30 seconds.

The selected source remains migration-readiness at `6981c2d`; Structured Explorer and Migration Readiness are preserved. Exact dirty source is bound by [the 160-file manifest](evidence/local-lifecycle/final-neutral-freshness/source-manifest.json), [tracked patch](evidence/local-lifecycle/final-neutral-freshness/source-diff.patch) and [new source copies](evidence/local-lifecycle/final-neutral-freshness/source-added/). Version remains 2.2.0 (10); 2.4.0 (12) is an owner recommendation, not a selection. No production install, release package/security changes or commit/push occurred.

## Historical detailed records

The material below retains its original source hashes and observation scope. Claims labelled current/final there refer to those earlier snapshots, not this continuation. Do not use them to override the current matrix linked above.


## Completed app-only native follow-up — 2026-11-04

Session3 used source `0b25faee39036550383783d115ba171953d94bdbe934759ed8e46257c0858229`, approved06:14:23–06:24:23UTC. Testing ended by06:19:07UTC; teardown verified06:20:12UTC, before the06:20:23new-case cutoff. No system settings actions or further desktop input. [Exact cases/evidence](evidence/remaining-closure/native-session-3/session-results.json), [teardown](evidence/remaining-closure/native-session-3/teardown.json).

- Actual product popover warning is readable on native light material, with orange decorative triangle and17.18GBlogical/ZeroKBallocated/17.18GBgap preserved. Representative core title/background contrast8.318:1 (spatially varying material; light only).
- Learn More expanded considerations/Hide Details; Reveal in Inspector selected the sparse image and showed readable warning/Review badge after scrolling. Finder was not invoked.
- Explicit simulated missing-database component showed Inventory has not started and Background monitoring is not configured. Open Settings opened its own QA Settings window. Sparse summary was unavailable(cannotopenmissingdatabase); no clean check or false completed result. Existing-database/no-generation waiting remains unverified.
- Explicit simulated exit0+fresh112GBcapacity+failedinventory showed inventory needs attention; selecting later inventory progress changed it to Recent background reading received. This is component-host evidence, not real service execution.
- Independent guard had an absent baseline and exact batch-owned PID identities. Both QA apps/workers were gone and lease available before the guard was stopped early; its finally/exit journal was confirmed. The scheduled deadline did not fire. Five effective flags and all eight preference values/presence match fresh originals. Existing user/production state was untouched.

Still NOT VERIFIED: existing-database/no-generation waiting, native stale-action/Trash confirmation/cancel, VoiceOver, Reduce Motion, actual system increased-contrast propagation, full-app dark/minimum/larger-text geometry, physical feel/energy/peakRSS, external real setup/lifecycle and actual Intel/macOS14 runtime. This is selected native acceptance, not complete release acceptance. Earlier statuses below retain their historical scope; this completed-session record supersedes their pending claims only for the cases above.


> Current source `0b25faee39036550383783d115ba171953d94bdbe934759ed8e46257c0858229`. The bounded Migration warning contrast correction is headlessly verified; session2 observed selected native workflows, followed by documented interrupted-session recovery at05:52UTC on2026-11-04. Both desktop approvals are expired. [Current results](REGRESSION-RESULTS.md), [remaining checks](REMAINING-ISSUES.md), and [continuation](HEADLESS-CONTINUATION.md) supersede historical status text below.

Historical record follows; exact earlier hashes and limits are preserved.

> Current continuation: [HEADLESS-CONTINUATION.md](HEADLESS-CONTINUATION.md) records the later native session, corrected helper/readiness/contrast changes and fresh verification receipts. The earlier fingerprint/results below remain historical evidence for their stated inputs; they are not current-source acceptance. Desktop authorization expired at 16:37:09 UTC on 2026-11-03.

Overall: **PARTIALLY VERIFIED**. Deterministic model/controller checks and unsigned compilation are recorded in [regression results](REGRESSION-RESULTS.md). Actual native first use, Settings delivery and monitoring lifecycle remain **NOT VERIFIED** until the user completes [native QA](MANUAL-NATIVE-QA.md).

## P0: first-launch Explorer dependency

Original audit: the default Explorer bypassed the table-only no-inventory placeholder and waited forever for a root that did not exist.

Changes: `SourcesShared/InventoryPresentation.swift` introduces `InventoryLifecyclePresentation`, resolved by `InventoryBrowserModel` and `DiskInventoryView` in `SourcesGUI/InventoryView.swift` before selecting Explorer, tables or Review. It distinguishes checking, unconfigured monitoring, no inventory, genuine indexing, available, temporarily unavailable, failed and stale results. A missing database clears old selection/accounting and becomes setup; completed catalogs missing their root offer reload rather than pretend to be indexing. An observed nonresumable inventory-job failure ends first-index waiting even before a root exists. Available prior results remain usable on a transient read failure.

Setup offers Enable Monitoring… and Open Settings…; both deliberately reach the existing consent flow rather than install anything silently. Configured/no-generation state offers user-requested indexing. Permission and first-pass duration guidance is explicit; no percentage is invented.

Tests: `tests/CorrectnessPresentationTests.swift` covers lifecycle states, missing database during periodic reload, unknown configuration, indexing request, completed/no-root recovery, job failure before creation, stale/failed/prior results. `tests/InventoryModelTests.swift` exercises the actual default Explorer model against a nonexistent disposable database, catalog creation and later disappearance.

Limit: no native app was launched. A hung database read with no returned error is still an actual in-flight operation; this fix does not invent worker progress.

## P0: capacity freshness

Original audit: last-known-good readings survived refresh failure but Storage labelled every retained value Available now.

Changes: `SourcesGUI/LiveCapacity.swift` defines one `CapacityPresentation` shared by Storage (`InventoryView.swift`) and Monitoring (`OverviewView.swift`). It distinguishes current success, retained recording, refreshing, failure, stale and no data. Values and original timestamps remain available after failure; missing values stay nil. Failed same-tick attempts and future-dated values cannot be current. `LiveCapacityMonitor` publishes refreshing state before its detached read and accepts an injected clock. Both screens age retained readings on a 15-second visible presentation clock without new disk reads.

Policy: live display freshness retains the existing 180-second threshold. Scheduled background health uses a separate, explicitly named 75-minute schedule/sleep tolerance; this is not a competing definition of live capacity. Recorded history is always identified as recorded, even when recent.

Tests: new deterministic states/age180–181/timestamp/repeated-failure/recovery/no-data/accounting assertions and published-start/completion checks; existing injected live-source tests verify failure after success, overlapping requests, recovery and byte-identical recorded history. Both views consume the same pure model; native view-switch presentation remains NOT VERIFIED.

Limit: age labels update on the 15-second presentation cadence; this does not create or record measurements. Native failed-probe injection requires a dedicated fixture host, not changes to the real volume or production permissions.

## P0: monitoring registration versus health

Original audit: the launchd parser discarded last exits, reporting background monitoring on for registered jobs with exit 78.

Changes: `SourcesGUI/MonitoringSetup.swift` preserves registration, running PID and last exit separately; malformed list output is unknown. Configuration is evaluated independently from execution. `MonitoringHealthPresentation` distinguishes disabled/partial setup, unknown, awaiting evidence, running, recent success, failed, stale, waking and resumable indexing. Capacity success cannot clear a different indexer's failure. An observed old capacity failure can be superseded only by a later persisted successful capacity reading; failure observation time is explicitly not the attempt time. Running tasks do not claim a new successful reading.

Baseline and inventory exit 75 are resumable worker outcomes, as confirmed by `StorageMonitor.swift` and `InventoryCommands.swift`; capacity exit 75 remains an error. Recent success uses a 75-minute tolerance, wake has a bounded ten-minute grace, and a stale gap alone is not diagnosed as task failure. Future-dated success is unknown.

`ViewerStore` owns shared evidence/status for Settings and Monitoring; Settings periodically reloads read-only status. Each refresh runs two read-only launchctl subprocesses; the active visible-app clock and the shown Settings scene each request updates about every 30 seconds, with in-flight coalescing. This new polling cost is disclosed, not benchmarked. The UI presents enabled/configured separately from actual health, last successful capacity reading, genuinely unknown attempt time, recovery guidance and secondary execution details. User-facing failure title avoids raw service terminology. Last attempt is not fabricated from file dates, registration or polling time.

Tests: parser PID/exit 78/unknown output, configured recent success, no success, failure/repeated observation/recovery, running with old exit, disabled/missing/partial setup, 75-minute and wake boundaries, worker and baseline75, unrelated indexer failure and future timestamps. Existing isolated setup fixtures cover missing jobs and disabled tasks.

Limit: real sleep/login/registration/recovery acceptance is NOT VERIFIED; last attempts are unknown because the available launchd output has no execution timestamps.

## P1: immediate Settings request

Original audit: a Settings-titled window appearing during the first three seconds was closed as presumed restored state, including deliberate Command-comma.

Changes: `SourcesGUI/StorageMonitorApp.swift` removes launch-time/title-based closing. `SettingsWindowSetup` configures restoration only on its own scene window (`isRestorable=false`, snapshot restoration disabled), with no search for other windows and no closing or activation. SwiftUI still owns scene/window reuse.

Tests: `tests/InventoryModelTests.swift` repeatedly configures an unshown host and verifies restoration disabled without visibility/key-window changes. Those checks prove scoped, idempotent configuration only; their timing labels do not simulate actual Command-comma, scene restoration or focus.

Limit: immediate/one-second/three-second/later Command-comma, restored Settings, activation and duplicate-window behavior all remain native acceptance items. No native outcome is claimed solely from the host test.

## Current continuation acceptance

See [HEADLESS-CONTINUATION.md](HEADLESS-CONTINUATION.md) for the final94eac source and truthful intermediate failures. Confirmed fixes now include trusted worker-image identity, exact fixture-region spelling, actual persisted-generation bootstrap gate, no-inventory readiness, semantic capacity warning text and inventory-failure monitoring health. Focused correctness64PASS and real product bootstrap22PASS. Default FileManager Trash backend fixture/RENAME_EXCL restoration is VERIFIED; native confirmation-panel interaction is not. Original Settings/capacity/health native observations are qualified historical evidence. Final matching QA bundles/data are ready (`FINAL-READY-FOR-NATIVE.json`), without a desktop launch. Final broad/ABI receipts remain pending until their runners complete.

Desktop approval expired16:37:09UTC; no new native launch/input/system-setting action occurred. Native populated Explorer/navigation/TTL/Migration, current contrast/readiness, Reduce Motion, VoiceOver, larger text/minimum size/dark remain NOT VERIFIED. Production setup/permissions/login require an isolated account. Actual Intel/macOS14 requires another host. Version remains2.2.0(10), with no chosen release package.

## Final headless source and acceptance

Final source `4e55114b25c77818dbcc01a2dbe40ba9b764b6dae67c8c2b86777a0fc699a560`;151files,31modified tracked files and one new test source, all uncommitted. Final affected tests/builds and unchanged-input retained receipts PASS; exact results/limits are consolidated in [REGRESSION-RESULTS.md](REGRESSION-RESULTS.md) and [REMAINING-ISSUES.md](REMAINING-ISSUES.md). Physical log order now uses optional file identity/byte-offset evidence to reject ambiguous same-second recovery while accepting proven later same-stream progress. Matching QA assets are headlessly verified only. The prior desktop approval expired; current native checks and real external-system setup/compatibility requirements remain explicit, not silently passed. Historical reports/logs remain preserved.

## Current native confirmation — VERIFIED, 2026-11-04

The final source `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` and pinned viewer were exercised under the approved app-only grant. Actual Enable registered all three fixture jobs and committed a capacity reading plus a five-node fixture generation. Actual Disable removed all three jobs while retaining the reading and **one naturally pending job**. No synthetic queue or catalog edit was used. The main window showed **Folder updates are waiting**, preserved the browseable tree, exposed Open Settings and showed no first-pass/manual activity indicator. That link opened its own Settings; actual re-enable registered the jobs, advanced recorded readings from one to two, and the main summary became **Inventory is up to date**. Final Disable and independent guard teardown completed by **09:16:17 UTC**, before the 09:17:30 input cutoff / 09:20 hard end. Guard 6502 exited; exact apps/workers and all three jobs are absent, protected files match and no system settings changed.

[Session results](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/session-results.json) · [waiting capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/waiting-main.png) · [recovered capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/re-enabled-main.png) · [teardown](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/teardown.json). Current missing-database setup also reached actual Enable. Empty-catalog/no-generation and disabled-before-root variants, accessibility/system/Trash/hardware limits remain separate.

The initial artifact launch recipe omitted scope-specific temporary directories and was correctly refused before a window. The corrected direct-executable recipe sets only process-local `TMPDIR=<root>/Temporary/` and `SQLITE_TMPDIR=<root>/Temporary`; no admission rule or source changed. Refused-attempt logs are preserved. [Corrected readiness](evidence/local-lifecycle/final-neutral-freshness/NATIVE-FINAL-READY.json) records the recipe and the now-consumed single-use guard.
