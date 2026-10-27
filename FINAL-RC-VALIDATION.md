# Native acceptance and performance follow-up — 2026-10-27

**NOT READY — packaging BLOCKED.** The current milestone is **PARTIALLY VERIFIED**. Native-window acceptance, actual Finder Put Back, first-run usability and native-resource measurements remain **UNVERIFIED**. Their execution is blocked by current GUI authorization and the read-only QA mode's intentional Trash guard. No native observations or operator restoration results arrived; none are inferred from models.

Full deliverable: [NATIVE-ACCEPTANCE-AND-PERFORMANCE.md](NATIVE-ACCEPTANCE-AND-PERFORMANCE.md). Exact manual launch, named-window identity checks and five disposable Finder targets: [operator procedure](build/native-acceptance/OPERATOR-CHECKS.md), [manifest](build/native-acceptance/finder-exact-targets.json). No app was launched, no desktop/Finder input sent, no new Trash move performed. Native Trash requires a separately safe existing fixture-only configuration; do not weaken the guard.

New verified evidence: five tiny **34-node** fixture catalogs with **eight freshly classified review candidates each**, actual worker/journal/reader/Queue/headless Inspector. **115 targeted assertions passed, zero failed**; final harness compile zero diagnostics. Median/P95 ms: first useful fresh candidate **6.952/12.278**, complete discovery **12.080/18.225**, forced evidence **5.828/6.081**, invalidation **2.209/2.353**, committed-journal Queue appearance **7.079/7.406**, disappearance **1.094/1.143**, explicit Inspector refresh **2.383/2.771**. Five samples for each except evidence n20; nearest-rank P95 for n5 is the maximum. Cached snapshot-only retrieval is separately **0.014/0.020 ms (n50)** and is not fresh discovery. [Raw results](build/native-acceptance/targeted-results.json).

Cancellation at a controlled real-observation boundary passed five times (**0.059/0.077 ms after barrier release**), not cancellation during an unbounded provider block or native use. Explicit refresh requests test real journal handling, not automatic FSEvents/native scheduling. Representative-scale fresh/journal/native gaps remain. Actual hardware re-read: **Mac14,2, Apple M2, 8 CPUs, 8,589,934,592 bytes RAM**. Headless whole-run `/usr/bin/time` peak RSS **18,743,296 bytes** is not native memory. Native resource runs: **0**, with no invented median/P95.

Both development applications freshly rebuilt: monitor **74.710 s**, viewer **73.687 s**, both zero warnings/errors; both strict signatures/plists verify. No product source changed. The previous broad regression campaign was **reused**, not rerun: all **109 tested source/artwork/script hashes** and **31 recorded log hashes/counts** match. Exact prior assertion counts per alias remain viewer **804**, inventory **349**, controller **67**, monitor **235** for each retention mode, supplemental **148**, Trash safety **131**, real API Trash **7/7**. Totals overlap. New compile/runtime harness failures, including two failed discovery assertions before fixture-local Python bytecode correction, remain recorded in the full deliverable and logs. No unresolved new assertion failure remains.

Preservation: **160/161** start-baseline files remain byte/mode identical; only this requested report update differs. The new deliverable is the only new nonignored task file. HEAD/index unchanged; representative catalog identity/size/timestamps/mode match preflight, no sidecars, no new copy/scan or production writer. No install/package/commit/push or permanent deletion occurred. Eight identified incorrectly redirected Python bytecode files were archived with matching hashes; broader import caches lacked a pre-run baseline, so absence of incidental writes there is not claimed. [Preservation/audit](build/native-acceptance/final-preservation.json).

## Current original release-gate criteria — unchanged

**6 PASS, 2 UNVERIFIED, 2 PARTIAL.**

| Existing gate (criteria retained) | Status | Current evidence / gap |
|---|---|---|
| 1 Full monitor suite | PASS | Prior 235 per alias, both retention modes; source/log audit matches |
| 2 Supplemental runner | PASS | Prior 148 per alias after recorded harness repair |
| 3 Finder Put Back | UNVERIFIED | No operator Finder action/restoration evidence |
| 4 Core native-window interactions | UNVERIFIED | No authorized native session; no interaction observations |
| 5 Representative performance complete | PARTIAL | Prior representative headless benchmark + new small-fixture results; native/fresh representative/journal scale gaps remain |
| 6 Single-item Trash safety/fixtures | PASS | Prior 131 safety checks and 7 actual API moves per alias; native workflow remains separate |
| 7 Protected-path enforcement | PASS | Prior hard-block regressions retained, sources unchanged |
| 8 Both application builds | PASS | Fresh development builds, zero diagnostics, signatures/plists verify |
| 9 All relevant regressions | PASS | All required suites' prior sources/logs validated; new targeted 115/115 |
| 10 No critical destructive-action defect remains | PARTIAL | No defect demonstrated in exercised scope; native destructive workflow unverified; accepted residual pathname race remains |

## Requested area mapping

This is a different grouping, not a weakened replacement: **7 PASS, 2 UNVERIFIED, 1 PARTIAL**.

| User-required area | Status | Evidence scope |
|---|---|---|
| Viewer correctness | PASS | 804 prior model assertions per alias; no native rendering claim |
| Inventory correctness | PASS | 349 prior assertions per alias |
| Controller correctness | PASS | 67 prior assertions per alias; new targeted headless checks |
| Monitor correctness | PASS | 235 prior assertions per alias and retention mode |
| Supplemental monitor correctness | PASS | 148 prior assertions per alias |
| Trash safety | PASS | 131 prior safety assertions per alias |
| Real Trash behavior | PASS | Prior 7/7 actual API fixture moves per alias; no native confirmation or Finder restoration claim |
| Finder Put Back | UNVERIFIED | Requires actual operator action + original-path/data verification |
| Native-window acceptance | UNVERIFIED | Execution BLOCKED under current GUI authorization/configuration |
| Representative performance coverage | PARTIAL | New small fixtures do not supply representative fresh/journal/native results |

Remaining blockers: actual Finder Put Back plus original data/native reconciliation; complete identity-checked native 1A–1E and five-minute workflow; safe native fixture-only Trash setup; actual native resource/latency measurements; representative fresh eligible/current-journal performance and previously missing applicable workloads. Small fixtures cannot close these gates. The residual pathname replacement race remains documented and accepted, not eliminated.

Next action: operator session using the exact checklist/targets, followed by original-path/checksum verification and actual native sampling; obtain a suitable existing representative current-journal/fresh-candidate catalog under safe conditions. No packaging is authorized. No packaging, installation, commit or push is part of this milestone.

---

The previous report is preserved verbatim below. Its “fresh” results and dates refer to that earlier validation campaign; this follow-up identifies what was newly run and what was reused.

# Storage Monitor final RC validation

Date: 2026-10-27. **PARTIALLY VERIFIED; automated validation complete; packaging BLOCKED.** No RC artifact has been produced. Completed automated evidence and unperformed release checks are separated below.

## Source and preservation baseline — VERIFIED

Primary checkout: `/Users/nicholaslippa/orca/projects/storage-checker`, branch `master`, HEAD `e3da2ebe3fa5416e78bf6775de2ae3bf8590dc00` plus existing dirty work. The active Orca workspace is a different older source copy and is not this application's provenance. Initial status contained **16 tracked modifications and 38 untracked paths**, with an empty index. **156 existing nonignored files** were hashed before edits. Baseline status, HEAD, index diff, tracked diff, hashes/modes and byte copies of the eight intended overlapping source/report files are under [baseline evidence](build/final-rc-validation/). Existing Living Tree 2D/3D, Navigator, Coverage/Inventory alias, Cleanup and database work is retained. No reset, clean, stash, commit or push was used.

The seven requested reports and `AGENTS.md` were read. The codebase-memory skill was applied; its recorded graph was old/partial and reported untracked/excluded paths, so material findings use current source and runtime evidence. Graft located relevant test spans and callers. Packaging infrastructure remains `scripts/build-dmg.sh` / `PACKAGING.md`; it was inspected and not run.

**Final preservation VERIFIED:** **148/156** original files remain byte/mode identical; the other **eight** are the five intended test-source edits and three requested report updates. No original is missing, no original mode changed, HEAD/index remain identical, and **all 109 source/artwork/script freeze hashes match** after tests/builds. The four new harness files and requested new report are the only new nonignored task files. [Final proof](build/final-rc-validation/final-preservation.json), [own harness diff](build/final-rc-validation/own-harness.diff). Historical report bodies are preserved below their new follow-up sections.

## Monitor failure, repair and supplemental runner

**VERIFIED reproduction:** the previous retained-source binary again passed **70 assertions**, then exited 1 at **“deletion and rename flagged in file activity”**, [Attribution.swift:811](Sources/Attribution.swift#L811). [Before-run command/result](build/final-rc-validation/monitor-before.json), [raw failure](build/final-rc-validation/monitor-before.log).

The old validation-copy adapter rewrote every `removeItem` to `rcRetainItem`, including in-test mutations. That adapter used same-volume rename to archive. The selected path disappeared and measured shrinkage correctly, but the real FSEvents event was a rename, not the required removed-entry event. A later open-but-deleted-file test also needs an actual unlink; renaming preserves the link and does not exercise it. This is **A + B: harness lifecycle defect and incorrect retention assumption**. No production monitoring regression was demonstrated.

The narrow repair adds `MonitorSelfTestFixtures.swift` and changes only top-level fixture creation/teardown in **six self-test suites** (main, attribution, baseline, coverage, inventory, install). `STORAGE_MONITOR_KEEP_TEST_FIXTURES=1` preserves final diagnostic trees; unset/0 retains normal teardown. `STORAGE_MONITOR_TEST_FIXTURE_PARENT=/tmp` selects that alias; otherwise `/private/tmp` is used. In-test removals and all existing assertion conditions remain intact. Only freshly generated disposable monitor fixtures are unlinked. Prepared Finder fixtures and all existing Trash contents are preserved. Coverage's disposable image attach adds `-noautoopen` to `-nobrowse` to prevent Finder opening.

**VERIFIED:** full monitor **235/235** with retained fixtures in each alias; default teardown also passed **235/235 in each alias**. Focused lifecycle tests passed **4 assertions × two aliases × two retention modes = 16**, verifying real in-test absence, optional final-tree retention and preserved diagnostic bytes. [Retention verification](build/final-rc-validation/retention-verification.json) confirms all reported artifacts exist and both removed-event/open-deleted assertions passed. Both retention modes and alias spellings are now exercised.

The old supplemental entrypoint ignored its `stress-state-writes` subprocess command and recursively reran itself. The new reproducible `scripts/test-monitor-supplement.sh` uses the existing dispatcher for exact generated-fixture helper routes. The first new attempt admitted only that writer and passed **145**, then failed install D10 because install self-tests also invoke `inventory-work`. This wrapper defect is preserved in [failed result](build/final-rc-validation/supplement-private-tmp-before-dispatch-fix.json), with the raw log adjacent. The corrected wrapper allows only the actual writer (`init-UUID/shared.sqlite3`, 400 writes) and install startup workers (same `install-UUID` root/state, exact flags and optional budget 30); no default data directory or unrelated command can dispatch. Checks are lexical validation for generated owned fixtures, not a hostile-symlink security boundary. Source assertions and production command dispatch were not weakened.

**VERIFIED:** corrected supplemental **148/148 per alias**, including the real SQLite concurrent child and contended worker/failure-log checks. These overlap the full suite and are not additive. The original 70-pass failure and intermediate 145-pass failure are fixed harness failures, not hidden or counted as passes.

Reproduce the focused lifecycle checks by compiling actual `Sources/MonitorSelfTestFixtures.swift` plus `tests/MonitorFixtureLifecycleTests.swift` with `xcrun swiftc -parse-as-library`, then running that binary for each parent `/tmp`, `/private/tmp` and keep flag `0`, `1`. Run full tests with the normal built monitor, explicit isolated `--data-dir` and `self-test`. Run the supplement with `scripts/test-monitor-supplement.sh`; its second alias run may reuse `build/MonitorSupplement`. Exact argv, environment, duration, source freeze and log hashes are saved in `build/final-rc-validation/`. The first six pilot metadata records mislabeled completion UTC as `started_utc`; [metadata errata](build/final-rc-validation/metadata-errata.json) identifies them. Their monotonic durations/counts/log hashes are unchanged; no start time is inferred. Later runs record start UTC correctly.

## Finder Put Back — UNVERIFIED

The six existing prepared target types at `/private/tmp/storage-monitor-rc-finder-qa-15A8E41C-3B8A-4125-98F7-67077A89321E` remain untouched: small text, multi-file directory, nested directory, spaces, Unicode and known-checksum binary. All **seven descendant file checksums** match their previous manifest. The refreshed [original-path/content/type/metadata manifest](build/final-rc-validation/manual-qa/finder-fixtures.json) includes exact original bytes (hex), checksums, modes, timestamps and identities. Their presence is preservation evidence, not restoration evidence.

No Finder action was performed. `AGENTS.md:7` says “Never activate, focus, raise or bring forward any application window”; line 8 prohibits desktop keyboard/mouse/AX actions; [line 14](AGENTS.md#L14) requires specific window/duration permission; line 18 applies it to launching this app. The user explicitly permits manual fallback. No GUI authorization or system privacy permission was bypassed or changed.

[Exact manual instructions](build/final-rc-validation/manual-qa/FINDER-MANUAL-QA.md) require the Storage Monitor operation first, followed by actual Finder **Put Back** and exact original path/content checks. Finder-origin Move to Trash is not substituted for the application operation. The `--database-path` QA viewer deliberately blocks Trash; this guard remains. A safe native mutation test path is still required. Fresh headless token/API fixture moves are recorded separately and do not establish native confirmation, Finder appearance, Put Back or restored-item reconciliation. No fixture is permanently deleted or Trash emptied.

| Required Finder fixture | App-native move | Finder appearance / Put Back | Original path/data / native reconciliation |
|---|---|---|---|
| Small text | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| Directory with multiple files | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| Nested directory | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| Spaces | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| Unicode | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| Known checksum | UNVERIFIED | UNVERIFIED | UNVERIFIED |

## Native-window QA and UI corrections — UNVERIFIED

No app launch/activation, desktop input, focus/window manipulation or screenshot exercise occurred. The prior ambiguous screenshot/click session is historical; it was not reused as current evidence. No new reproducible UI defect was observed, and no UI redesign or source change was made.

Every item below remains **UNVERIFIED in the native app**. The [operator checklist](build/final-rc-validation/manual-qa/NATIVE-WINDOW-MANUAL-QA.md) requires PID/executable/catalog, exact unique window, foreground owner, expected state and intended control before every interaction. Stop on any ambiguity; never force focus or use blind coordinates.

| Required native area | Explicit unperformed checks |
|---|---|
| 3A Inspector — UNVERIFIED | Ordinary file/directory; historical artifact; review candidate; Preserve; Protected; insufficient evidence; evidence expansion; preview; long filenames/paths; scroll preservation; rapid selection; freshness; stale-evidence empty-state fix; Trash availability messaging |
| 3B Queue — UNVERIFIED | Loading; partial discovery and truthful scope; candidate discovery; populated/empty states; sorting/filtering; pagination; selection/Inspector synchronization; refresh; disappearance; cancellation; navigation to source |
| 3C Read-only plan — UNVERIFIED | Add/remove; count; exact paths; parent/child overlap; Unknown estimates; APFS warnings; refresh/updates; persistence; absence of bulk/automatic mutation controls |
| 3D Confirmation — UNVERIFIED | Ordinary file/directory and candidate; insufficient warning; protected/active dependency hard blocks; exact path; cancellation/error/success; disposable move; Inspector/Queue aftermath |
| 3E Visual/accessibility — UNVERIFIED | Narrow/standard/wide; typography/spacing; panels/resizing/scrolling; keyboard; focus; accessibility/VoiceOver; consistency and interaction with Atlas, Living Tree 2D/3D and Navigator |

Headless checks cover many underlying models, but do not establish native rendering, focus or interaction. Successful Trash through the QA viewer is additionally blocked by its intentional QA guard. The accepted residual pathname replacement race remains documented and is not eliminated.

## Representative catalog performance — PARTIALLY VERIFIED

**Fresh measurements, not the historical figures.** Existing isolated clone: `/private/tmp/stabilization-benchmark-633f8e21-84de-49b0-bac8-b784d46a8207/catalog.sqlite3`. Recount **1,966,231 entries**, including 249,623 directories, 1,658,481 files, 58,083 symlinks and 44 other objects. Logical SQLite size **1,018,322,944 bytes**; exclusive APFS allocation was not measured. Provenance records prior Darwin `clonefile CLONE_NOFOLLOW`, no full-copy fallback, from the dated preserved `history.pre-update-2026-10-26T105101Z.sqlite3`. This pass made **no catalog copy or full-volume scan** and did not open that production backup as a benchmark source.

The existing approximately 1.966M catalog is the requested representative scale; its count is not an arbitrary target failure. Its active generation is legacy `building` with initial completion recorded, and it has **no change journal**. The clone was opened mechanically read-only (`SQLITE_OPEN_READONLY` / `mode=ro`, `query_only=ON`), without migration, checkpoint, VACUUM or writer. Before/after SHA-256, device/inode/size/mode/mtime/ctime are identical; WAL/SHM/rollback sidecars remain absent. SHA-256 **`2b8a5c3c9a94dba2fee7614ac3f1b9472e5c323c8f0183f8bddc4c8ac116c92e`**. [Provenance/recount](build/final-rc-validation/benchmarks/catalog-validation.json), [preservation](build/final-rc-validation/benchmarks/catalog-preservation.json).

Actual hardware: **Mac14,2, Apple M2, 8 logical CPUs, 8,589,934,592 bytes unified memory** (the requested M2/8 GB class). Shared machine; cache uncontrolled and warmed by preflight hashing/counting. No cold-cache claim. Current reader/queue sources and the **exact current controller prefix** were compiled into a headless harness: no NSApplication/NSWindow/SwiftUI App instance, native input or rendering. No synthetic fixture constructor or generated benchmark database was used. [Driver/compile provenance](build/final-rc-validation/benchmarks/compiled-source-manifest.json), [raw samples](build/final-rc-validation/benchmarks/results.json), [command/resources](build/final-rc-validation/benchmark.json).

Percentiles use nearest rank `ceil(n*p)`, one-based; P95 for five repetitions is the maximum. Latencies below are milliseconds and exclude native rendering/input. The production bounds remain 128 rows/page, four inspections/step, eight UI-requested steps/activation, 100,000 examined rows/tranche, 512 retained artifacts and a 0.35-second evidence budget. Harness guards were 90 seconds/round and 512 MiB resident memory; no production bound was relaxed.

| Requested metric / actual scope | n | Median ms | P95 ms | Coverage |
|---|---:|---:|---:|---|
| 1 Queue initial work, eight steps | 5 | 64.296 | 69.323 | VERIFIED headless bounded work |
| Initial 128-row metadata page | 5 | 0.651 | 1.812 | VERIFIED |
| 2 First useful eligible candidate | — | — | — | UNVERIFIED; actual zero eligible legacy rows |
| First classified artifact, **not eligible** | 5 | 5.826 | 7.457 | VERIFIED classification only |
| 3 Discovery to retained-artifact bound | 5 | 19449.850 | 20490.889 | VERIFIED bounded partial discovery |
| 4 Pagination, 128-row pages across four ID regions | 40 | 0.349 | 1.510 | VERIFIED; 5,120 sampled rows |
| 5 Five sorts combined, 512 legacy rows | 50 | 41.725 | 43.544 | VERIFIED headless model; individual sorts below |
| 6 Four status filters combined, 512 legacy rows | 50 | 6.302 | 6.602 | VERIFIED headless model; individual filters below |
| Rapid 20-filter batch over legacy rows | 50 | 44.795 | 45.674 | VERIFIED headless submission/work |
| 7 Inspector selection to published evidence | 10 | 2.196 | 61.444 | VERIFIED headless controller |
| 8 Actual process observation + cleanup evidence | 20 | 4.469 | 8.302 | VERIFIED bounded live read-only probes |
| 9 Plan evaluation, all stale legacy rows excluded | 50 | 6.082 | 6.395 | PARTIALLY VERIFIED; **zero usable plan**, no eligible-overlap timing |
| Repeated Inspector controller construction | 10 | 2.153 | 2.191 | VERIFIED headless, not native opening |
| Rapid 30-selection submission batch | 5 | 2.856 | 3.551 | VERIFIED headless; final-selection result True, 0 timeouts |
| 10 Already-cancelled reader response | 20 | 0.019 | 0.024 | PARTIALLY VERIFIED; 20/20 CancellationError; no in-flight evidence cancellation |
| 11 Peak memory | — | — | — | PARTIALLY VERIFIED: **75,563,008 bytes peak headless process RSS**; native app unmeasured |
| 12 Steady memory, five idle samples | 5 | — | — | PARTIALLY VERIFIED: **64,028,672 bytes headless RSS in every sample** |
| 13 Idle CPU, five ~1-second samples | 5 | 0.170 CPU ms | 5.438 CPU ms | PARTIALLY VERIFIED headless; wall 1014.426–1065.326 ms/sample |
| 14 Four concurrent SQLite readers, batch | 10 | 0.551 | 0.781 | VERIFIED read/read scope; 0 errors; no writer induced |
| 15 Incremental updates | — | — | — | UNVERIFIED at representative scale; legacy journal absent, no writes/migration |

All five discovery rounds checked **74,240 rows in 2,937 steps**, retained **512 artifacts and zero eligible candidates**, and explicitly stopped with incomplete coverage at the existing artifact budget. Observed bounded throughput was median **3,817.0 rows/s**, P95 **3,887.0 rows/s** (five rounds, nearest rank; cumulative work, not one UI activation). This is not complete catalog discovery or a fresh-candidate workflow.

| Individual headless operation over 512 legacy rows | n | Median ms | P95 ms |
|---|---:|---:|---:|
| Sort: Artifact type | 50 | 8.415 | 8.675 |
| Sort: Estimated recoverable storage | 50 | 13.471 | 13.733 |
| Sort: Evidence confidence | 50 | 9.192 | 9.664 |
| Sort: Indexed allocated size | 50 | 5.711 | 6.032 |
| Sort: Last verification | 50 | 4.889 | 5.144 |
| Filter: insufficientEvidence | 50 | 5.845 | 6.125 |
| Filter: preserve | 50 | 0.157 | 0.164 |
| Filter: protected | 50 | 0.144 | 0.152 |
| Filter: reviewCandidate | 50 | 0.145 | 0.169 |

| Required test condition | Actual coverage |
|---|---|
| Small eligible candidate set | UNVERIFIED on representative catalog: zero eligible legacy rows |
| Large eligible candidate set | UNVERIFIED: 512 retained artifacts are not 512 fresh candidates |
| Empty results | PARTIALLY VERIFIED: stale legacy default filter is empty; not a truly empty native catalog/workflow |
| Rapid filters | VERIFIED headless 50 batches ×20 changes over retained legacy rows; native unverified |
| Rapid selections | VERIFIED headless five batches ×30 selections; native unverified |
| Repeated Inspector opening | VERIFIED ten controller constructions; native opening/rendering unverified |
| Overlapping plan selections | UNVERIFIED usable representative overlap; legacy plan has no eligible entries |
| Stale evidence | VERIFIED conservative legacy exclusion; current-journal/native expiry workflow unverified |
| Permission denied | UNVERIFIED controlled representative performance condition; disposable regressions are separate correctness evidence |
| Partial discovery | VERIFIED in every measured round; incomplete coverage surfaced explicitly |
| Cancellation | PARTIALLY VERIFIED already-cancelled reads only; in-flight evidence/native cancellation unverified |

Whole harness `/usr/bin/time -l`: **111.04 s wall, 67.21 s user, 37.71 s system**, about 94.5% of one CPU during the workload. These are whole-process headless values, not application idle or native graphics resources. Host memory/pressure readouts are preserved separately; the shared host prevents attributing its VM activity to this harness. No critical bottleneck was demonstrated in the exercised scopes, but missing workflows prevent a complete performance gate PASS. No speculative optimization or architectural rewrite was made. The static legacy clone cannot establish first-useful-candidate latency, fresh usable/overlapping plans, current-journal incremental performance or native resources. Synthetic tests were not substituted for representative evidence.

## Final regressions and builds — VERIFIED in automated scope

All final requested automated suites passed against current sources. These are fresh runs; historical counts are not substituted.

| Suite/build | `/private/tmp` | `/tmp` | Scope/evidence |
|---|---|---|---|
| Viewer model/read-only | **804 passed** | **804 passed** | Includes safety/Queue/Living Tree models; standard script also passed two separate linkage/live-capacity checks |
| Inventory integration | **349 passed** | **349 passed** | Pristine current production sources; alias fixture preparation described below |
| Inventory-model/controller | **67 passed, 0 failed** | **67 passed, 0 failed** | Direct alias runs plus unchanged standard script 67/67; real isolated worker, stand-in moves, journal/Inspector/Queue reconciliation |
| Full monitor | **235 passed** | **235 passed** | Both retention ON and normal teardown for each alias |
| Supplemental monitor | **148 passed** | **148 passed** | Baseline, coverage, inventory, install; exact real child dispatch |
| Standalone pristine Trash safety | **131 passed, 0 failed** | **131 passed, 0 failed** | Protected/active/identity/Git/alias/SQLite-family and confirmation hard protections |
| Real disposable Trash | **7/7 moves** | **7/7 moves** | Original absence, returned identity, type/content/checksum and non-target referent checks; no Put Back |
| Fixture lifecycle | **8 assertions** | **8 assertions** | Four per keep flag 0/1; total 16 |
| Monitor app build | **PASS, zero warnings/errors** | same build | Existing build script, current source |
| Viewer app build | **PASS, zero warnings/errors** | same build | Existing build script, SDK 26.5 argument; emitted SDK metadata saved |

Counts are not additive: 131 safety checks are included in 804 Viewer checks, and supplemental checks overlap the full monitor. Three malformed/unowned supplemental helper probes additionally produced the expected refusal/exit1 before dispatcher entry. No rejected probe is mislabeled a failed product regression.

`/tmp` inventory integration uses eleven tiny test-source copies with **35 fresh-fixture initializer literals** redirected from `/private/tmp/storage-monitor-…` to `/tmp/storage-monitor-…`. Assertion expressions and all production source are unchanged; no global deletion/retention rewrite exists. The simple inventory self-test also uses the explicit parent selector. [Exact alias-copy hashes/delta provenance](build/final-rc-validation/inventory-tmp-tests/source-provenance.json) and compile argv are preserved. Viewer and controller accept explicit fixture paths directly. All fixture mutation/unlink remains within newly owned disposable trees.

Both app builds and final test/benchmark compiles emitted **zero compiler warnings/errors**. The automated coverage includes Atlas/Living Tree 2D/3D/camera, Navigator/reader, Inspector, Review Queue/read-only plan, inventory journal, monitoring, single-item Trash and hard protections within their model/fixture scopes. Native interaction/rendering remains unverified. No bulk/automatic deletion or privileged fallback was added; no production behavior was weakened.

**Fresh actual API moves:** seven UUID-named fixtures per alias (ordinary text/checksum, spaces, Unicode, multi-file directory, nested directory, Node dependency directory and symlink leaf). The restored `CleanupTrashPolicy.prepare`/one-use token/execution route invokes the actual supported API; no injected stand-in is used in these 14 moves. Every result was VERIFIED, source absent and expected contents/checksums preserved. The operation verifies returned device/inode/birth identity. A real kernel-observed disposable running executable was hard-blocked separately in each run. The unrelated fixture referent retained its identity and hash. Only exact newly returned destinations were read; the harness never enumerated/selected existing unrelated Trash items, emptied Trash, permanently removed or restored a moved fixture. All 14 new fixtures remain at recorded destinations; earlier fixtures were not touched by this agent. [Private results](build/final-rc-validation/trash-private-tmp-results.json), [tmp results](build/final-rc-validation/trash-tmp-results.json), with adjacent original-content manifests and raw logs. These are API/fixture evidence, not native sheet or Finder evidence.

All intermediate failures remain recorded: old retention harness 70-pass removed-event failure, and first new supplemental 145-pass omitted-inventory-dispatch failure. Both were corrected narrowly and rerun; no unresolved automated failure remains. Source/test command metadata, raw logs, durations, diagnostics and SHA-256 are under `build/final-rc-validation/`.

## Mandatory release gates — packaging BLOCKED

The current user's ten gates supersede the prior report's criterion treating Put Back as a documented nonblocking limitation. **Actual representative Finder Put Back is mandatory. Every mandatory gate must PASS; PARTIAL also prevents packaging.**

| Gate | Status | Evidence or remaining work |
|---|---|---|
| 1 Full monitor suite | PASS | 235 per alias; retention lifecycle repaired |
| 2 Supplemental runner | PASS | 148 per alias after exact child dispatch repair |
| 3 Finder Put Back | UNVERIFIED | No actual Finder restore |
| 4 Core native-window interactions | UNVERIFIED | No authorized safe session; complete matrix unperformed |
| 5 Representative performance complete | PARTIAL | Fresh bounded headless measurements completed; eligible/live-journal/native coverage remains incomplete |
| 6 Single-item Trash safety/fixtures | PASS | Fresh 131 safety assertions and 7 actual API moves per alias |
| 7 Protected-path enforcement | PASS | Fresh hard-block regressions, including active executables/dependencies/SQLite families, protected descendants and fail-closed incomplete checks |
| 8 Both application builds | PASS | Both current development builds passed, zero warnings/errors; signatures and plists verify |
| 9 All relevant regressions | PASS | All requested automated suites pass; native workflows are separately gated and unverified |
| 10 No critical destructive-action defect remains | PARTIAL | No known critical defect surfaced in exercised safety/API/model scope; destructive native workflow remains unverified. Accepted residual race is not eliminated or reclassified as a new blocker |

## Packaging and remaining limitations

**BLOCKED.** No local RC app/DMG was assembled, signed for release, installed, automatically launched, uploaded or published. Existing development app builds are not RC packages. No new signing credentials or notarization request was created. Production databases, LaunchAgents, installed apps, configuration, active QA worker and preserved snapshots were not modified. Monitoring/installation tests use isolated databases/roots and recording fake launch control. No bulk deletion, automatic cleanup, privileged removal or permanent fallback was added.

No RC artifact path/checksum/release signing status, install or rollback action exists. Existing packaging infrastructure remains available after all gates pass; both development apps are version **1.0.0 (1)**, arm64 and ad-hoc signed. Their strict signatures and plists verify; [development binary checksums and metadata](build/final-rc-validation/development-build-artifacts.json) distinguish these outputs from a package. The monitor build took **74.620 seconds**, viewer **73.801 seconds**, both with zero warnings/errors. The monitor uses the default SDK; the viewer receives the required SDK 26.5 compilation argument, while emitted load commands record SDK 27.0 for both binaries. No notarization was performed. No package should be installed. Until an artifact exists, rollback for this milestone is unnecessary because no installed app/configuration/database was replaced.

Remaining release blockers:

1. **Finder Put Back UNVERIFIED** for representative disposable files/directories, exact restored paths/data and restored-item application reconciliation. The supported Trash API does not establish this behavior.
2. **Core native-window QA UNVERIFIED**, including the current empty-state fix, scrolling/long paths, Queue/plan interactions and confirmation/focus/error/aftermath matrix. No specific safe window session was authorized. The read-only QA catalog intentionally disables Trash; a safe existing native mutation setup is also needed, without production redirection or guard weakening.
3. **Representative performance PARTIALLY VERIFIED**: no fresh eligible candidate/usable large or overlap plan, current-journal incremental workflow, in-flight evidence cancellation, controlled permission-denied representative workload or native app memory/idle/render/input measurement. The unchanged static legacy clone cannot supply these cases. No known critical data-loss defect was demonstrated in exercised scope, but the unperformed destructive native workflow keeps gate 10 partial.

Recommended next action: arrange a bounded, specifically authorized named-window operator session with reliable identity/foreground evidence. Use a safe existing read-only QA setup for the nonmutating matrix, and perform native Trash/actual Finder Put Back only when a separately safe existing fixture-only path is available; do not invent a QA mode, point at production data or weaken the guard. Identify a suitable **existing** representative current-journal/eligible-candidate catalog under safe read-only conditions, then measure the missing workloads; no new multi-million database or full-volume scan. A checklist alone does not close these gates. Reassess every mandatory gate after actual evidence; package locally only if all PASS.
