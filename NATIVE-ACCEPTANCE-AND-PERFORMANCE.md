# Storage Monitor — native acceptance and targeted performance

2026-10-27. **NOT READY — mandatory native/Finder/performance gaps remain. PARTIALLY VERIFIED overall; packaging BLOCKED.**

## Source baseline and scope — VERIFIED

Primary checkout: `/Users/nicholaslippa/orca/projects/storage-checker`, branch `master`, HEAD `e3da2ebe3fa5416e78bf6775de2ae3bf8590dc00`, plus all pre-existing dirty work. The Orca workspace is a different checkout and was not used as product provenance. The milestone baseline at `2026-10-27T13:47:33.300927+00:00` records **161 existing files**, 20 tracked modifications, existing untracked work and an empty index in [baseline.json](build/native-acceptance/baseline.json). This pass changes no product source, tests, artwork or build script. The requested new report and a prefixed update to `FINAL-RC-VALIDATION.md` are the only nonignored report changes; the previous final report body is preserved verbatim. [Final preservation proof](build/native-acceptance/final-preservation.json) records 160/161 baseline files byte/mode identical, the one intended report update, unchanged HEAD/index and all 109 tested source/artwork/script hashes matching.

Recovered the previous run's completed artifacts rather than rerunning the campaign. Current source and compiled manifest hashes were checked; extracted Inspector/Queue controller files are exact prefixes of current view sources. [Compile manifest](build/native-acceptance/targeted-compiled-source-hashes.json), [compile metadata](build/native-acceptance/targeted-compile.json), [driver](build/native-acceptance/targeted.swift), [run metadata](build/native-acceptance/targeted-run.json), [raw samples/assertions](build/native-acceptance/targeted-results.json).

No production database, production LaunchAgent, active protected QA worker/supervisor, installed app or preserved snapshot was changed by this milestone. No full-volume scan, new large catalog, packaging, installation, commit or push occurred. No desktop activation, input, window manipulation, Finder automation or privacy-permission change occurred. No permanent deletion or Trash emptying occurred. The fixture-generator cache exception and its evidence limit are documented below; unrelated-cache preservation is not claimed.

Actual hardware read during this follow-up: **Mac14,2; Apple M2; 8 logical CPUs; 8,589,934,592 bytes unified memory**. This is the requested MacBook Air M2/8 GB hardware class. Shared machine; uncontrolled warm OS/filesystem caches. [Hardware and audit record](build/native-acceptance/completion-audit.json).

The existing representative catalog remains `/private/tmp/stabilization-benchmark-633f8e21-84de-49b0-bac8-b784d46a8207/catalog.sqlite3`: prior verified **1,966,231 entries**, **1,018,322,944 bytes**, static legacy generation, no current change journal. No catalog benchmark was repeated and no catalog copy was created. Current device/inode/size/mode/mtime/ctime equal this milestone's preflight and no WAL/SHM/rollback journal exists. Count and full SHA remain explicitly prior evidence; this pass checks metadata, not a fresh full hash. No production catalog was opened for writing.

## Native-window acceptance — UNVERIFIED; execution BLOCKED

[AGENTS.md](AGENTS.md) forbids launching/activating/focusing windows and all desktop keyboard, mouse or Accessibility actions without specific authorization. It requires naming the window and duration for a focused session. No such authorization or operator observation arrived. Existing privacy permissions do not authorize actions prohibited by the repository. No new GUI-automation permission probe, app launch or native screenshot was used.

The prior ambiguous-recipient screenshot/input session is not accepted as evidence. The dedicated configuration is prepared but **not launched**: [native-qa-config.json](build/native-acceptance/native-qa-config.json), exact expected title `Storage Monitor — QA: NativeAcceptance-3a1e9b12-19a7-4237-9d85-920fa0bd378f.sqlite3`. Its unique symlink points to the existing read-only representative catalog. This `--database-path` mode deliberately disables Trash. A safe existing fixture-only native mutation configuration is **not established**; do not weaken the QA guard or redirect to production to fill that gap.

The [operator procedure](build/native-acceptance/OPERATOR-CHECKS.md) supplies the exact launch command and identity checks. Before every operator interaction verify app PID/executable/catalog, exact window, foreground owner, expected state and intended control; stop on ambiguity. No blind coordinate clicks, forced focus or unrelated-window actions.

| Required native area | Status | Explicitly unperformed checks |
|---|---|---|
| 1A Core navigation | UNVERIFIED | Launch; main render; Navigator population; Atlas; Living Tree 2D/3D; selection synchronization; Inspector update; resize; state retained across views |
| 1B Inspector | UNVERIFIED | Ordinary file/directory; historical artifact; review candidate; Preserve; Protected; insufficient evidence; expansion; recovery uncertainty; long paths; scrolling; rapid selection; stale-evidence empty-state correction; clear explanation without uncertain safety implication |
| 1C Queue | UNVERIFIED | Loading; partial-discovery scope; populated/empty states; sorting; filters; pagination; selection/Inspector sync; evidence refresh; source navigation; cancellation |
| 1D Read-only plan | UNVERIFIED | Add/remove; count; exact paths; parent/child overlap; unknown estimates; APFS warnings; evidence refresh; updates; read-only behavior in actual window |
| 1E Single-item Trash | UNVERIFIED | File/directory/candidate confirmation; insufficient warning; protected and active-dependency hard blocks; exact path; cancel; disposable success; Inspector/Queue reconciliation; failure messaging |

Model assertions below do not upgrade any native cell. No ordinary-user workflow, responsive layout, real queue scroll, graphics rendering or native event latency has been observed in this pass.

## Finder Put Back — UNVERIFIED; operator action required

No Finder interaction was performed or reported. Five exact previously API-moved disposable targets were identified, without enumerating unrelated Trash: ordinary text/known checksum, spaces, Unicode, ordinary multi-file directory and nested directory. At the recorded preflight all original paths were absent and all target descendant checksums matched. See [exact original and returned Trash paths, checksums and identities](build/native-acceptance/finder-exact-targets.json). This is preservation evidence, not Put Back evidence. The prior prepared six-type Finder fixture tree also remains baseline evidence; no new Trash move was attempted.

Use the exact table in [OPERATOR-CHECKS.md](build/native-acceptance/OPERATOR-CHECKS.md): select only one listed target in Finder Trash, choose actual **Put Back**, record command availability/errors/outcome, and leave unrelated contents untouched. If unavailable, disabled or errored, record that result and stop on that item; dragging it to the original directory does not verify Put Back. All recorded descendant file checksums for these five targets are `ae326efe0fc3947acc1323ec1ec4f64f316cd385628c6ccd1a5e21941c24949b`. After the operator reports an action, run the exact original-path verifier `python3 -B build/native-acceptance/verify-finder.py` and compare content/structure. The verifier has not been run here because no action was reported. Original-path presence alone cannot establish the Finder command.

| Fixture | Actual Finder Put Back | Restored path/checksum | Native reconciliation |
|---|---|---|---|
| Small text / known checksum | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| Filename with spaces | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| Unicode filename | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| Directory with multiple files | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| Nested directory | UNVERIFIED | UNVERIFIED | UNVERIFIED |

These targets establish only the previous real Storage Monitor policy/token/API move; they do not supply native-app confirmation evidence. Full end-to-end acceptance still requires the safe native move/confirmation/reconciliation workflow. Never empty Trash, permanently delete a fixture, touch unrelated Trash or use a Finder-origin move as a substitute. The residual pathname replacement race remains an accepted documented limitation and is not eliminated.

## Fresh-candidate performance — VERIFIED small-fixture measurements; representative coverage PARTIAL

Five independent generated filesystem/catalog rounds, each initially **34 indexed nodes and eight actual Python bytecode cache artifacts**, fresh queue and fresh actual evidence. Each round's SQLite database was **249,856 bytes** after the workload. All five initially classified all eight artifacts as review candidates. These are newly generated files and newly classified candidates, not the static catalog's cached/legacy rows. Production worker, journal, reader, Queue actor and headless Inspector controller were used. `ArtifactEnvironment.current` performed actual process observations (587–588 processes inspected; three unreadable per recorded observation); no native window was created. Bytecode generation and initial indexing are excluded from discovery timing and listed separately. Fixtures remain retained under `/private/tmp/storage-monitor-native-targeted-0D51BD66-FE41-4F84-A629-7F9650CB6B92`.

Clock: monotonic `DispatchTime`, milliseconds. Percentiles are nearest-rank `ceil(n*p)`, one-based (including the lower middle for even-n reported median); **P95 at n=5 is the maximum of five**, not a stable tail estimate. Bounds: 10-second worker budget, 256 discovery steps, drain 20 seconds and 256 MiB RSS guard. Actual completion used two initial fresh-discovery steps per round, eight fresh candidates per round. Shared warm cache, tiny topology, no throughput extrapolation to the representative catalog. No optimization was justified from these timings.

| Operation, headless small-fixture scope | n | Median ms | P95 ms |
|---|---:|---:|---:|
| Initial isolated worker inventory (outside discovery clock) | 5 | 33.354 | 48.029 |
| First freshly eligible candidate, new queue | 5 | 6.952 | 12.278 |
| Complete discovery of eight fixture artifacts | 5 | 12.080 | 18.225 |
| Individual initial fresh-discovery step | 10 | 5.947 | 12.227 |
| Explicit fresh evidence refresh of one candidate | 20 | 5.828 | 6.081 |
| Previously classified snapshot retrieval only | 50 | 0.014 | 0.020 |
| Explicit headless Inspector selection to publication | 5 | 2.161 | 2.750 |
| Cancellation after releasing controlled observation barrier | 5 | 0.059 | 0.077 |

Derived classification throughput, eight artifacts divided by complete initial discovery duration: **662.256 artifacts/s median, 664.769 P95**, five rounds, nearest rank. This is discovery/classification throughput over already indexed tiny fixtures; it excludes Python generation and inventory creation and is not scan throughput. Cached snapshot measurements contain no new discovery/evidence work. Fresh evidence explicitly calls Queue refresh and does not reuse that snapshot-only timing.

Queue responsiveness **during discovery in the native app is UNVERIFIED**. Individual actor step durations are component work timings, not concurrent UI responsiveness. The cancellation test first starts a real metadata read and real process observation, then holds a controlled barrier. It measures cancel-to-completion only **after cancellation and barrier release**, observes `CancellationError` in all five rounds and verifies no candidate publication. It does not measure cancellation during an unbounded observation/provider block, native cancellation or arbitrary worker preemption.

## Journal-dependent performance — VERIFIED small-fixture behavior; representative scale UNVERIFIED

Each round explicitly requests an owned parent refresh via `requestInventoryRefresh`, reads actual journal changes, applies invalidation, and runs the real worker against only its small isolated database. It creates a new cache for appearance, then renames an existing cache outside the indexed tree into a retained diagnostic archive for disappearance. No unlink/permanent removal is needed. All five rounds verified advice invalidation, appearing candidate, disappeared-candidate removal, advancing consumed cursor, refreshed Inspector evidence, clearing stale Inspector state, foreign-cursor resynchronization stop and explicit reset/rebuild. Final recorded journal sequence is **93 in every round**, with cursor-advance assertions passing.

| Operation, headless small-fixture scope | n | Median ms | P95 ms |
|---|---:|---:|---:|
| Explicit refresh request through reader to queue invalidation | 5 | 2.209 | 2.353 |
| Worker processes new-cache parent refresh | 5 | 14.869 | 15.392 |
| Read/apply committed journal and drain to appearing candidate | 5 | 7.079 | 7.406 |
| Explicit Inspector refresh call to evidence publication | 5 | 2.383 | 2.771 |
| Refresh request + worker processes renamed-away cache | 5 | 22.559 | 22.925 |
| Read/apply journal + explicit vanished-node refresh | 5 | 1.094 | 1.143 |
| Foreign journal cursor detection and queue stop state | 5 | 0.472 | 0.477 |
| Explicit queue reset + bounded rediscovery | 5 | 11.904 | 13.231 |

These timings separate worker processing from the subsequent read/apply/discovery stages; medians must not be summed into an observed end-to-end latency. Appearance and disappearance are real worker/journal outcomes, but refreshes are **explicit harness requests**, not FSEvents scheduling. Inspector refresh/clear are **explicit controller calls**, not observed automatic native notification delivery. Resynchronization recovery is an explicit reset+drain, not automatic background recovery evidence. Large backlogs, retained journal pruning, current-journal representative catalogs and UI refresh scheduling remain unmeasured. The static 1.966M catalog has no journal; it was not migrated or written. These small-fixture results do not satisfy representative-scale performance.

## Resources — headless measured; native UNVERIFIED

Fresh harness `/usr/bin/time -l`: **1.14 s wall, 0.45 s user, 0.39 s system**, **18,743,296 bytes maximum RSS**. The in-process `getrusage` reading before exit was **18,284,544 bytes**; final sampled resident size **18,022,400 bytes**, round-end samples **17,727,488–18,022,400 bytes**. These are different sampling points/methods; neither is the application's native memory. The timing wrapper's resource log is [targeted-run.log](build/native-acceptance/targeted-run.log). Whole headless run CPU is not idle/active native CPU. Native steady-state memory was not measured.

| Required actual-app metric | Runs | Median / P95 / peak | Status |
|---|---:|---|---|
| Idle CPU | 0 | No samples | UNVERIFIED |
| Active CPU | 0 | No samples | UNVERIFIED |
| Native peak and steady-state memory | 0 | No samples | UNVERIFIED |
| UI responsiveness / Queue scrolling | 0 | No samples | UNVERIFIED |
| Inspector selection latency | 0 | No samples | UNVERIFIED |
| View-switching latency | 0 | No samples | UNVERIFIED |
| Native cancellation latency | 0 | No samples | UNVERIFIED |

A read-only bounded sampler is prepared in [sample-native-resources.py](build/native-acceptance/sample-native-resources.py), with the exact command in the operator procedure. It requires confirmed operator use and checks UID/executable/exact database argument and process start identity. It has **not run**. Its eventual ~1 Hz RSS and CPU deltas can miss transient peaks and do not establish UI latency; the operator must exercise and record the named workflow. Only measurements taken during actual accepted native use may upgrade these cells.

## Five-minute first-run usability — UNVERIFIED

No new-user or operator session was observed; elapsed time, initial clarity, useful information, navigation discoverability, Inspector comprehension, classification comprehension, Trash confidence/aftermath, visual hierarchy and real loading/empty/error states cannot be scored. No reproducible native usability defect was demonstrated, no subjective preference is reported as a defect, and no product/UI change was made.

The focused operator procedure starts a five-minute timer, records prior familiarity, opens the named QA window, identifies storage consumption, selects from Atlas, compares Inspector explanation/classification, switches 2D/3D/Navigator views and records actual obstacles and timings. Every unavailable state must remain UNVERIFIED. The legacy catalog may lack fresh eligible candidates, and the safe read-only QA launch blocks Trash. Those are concrete **validation-setup limitations**, not observed ordinary-user defects. The full fifth/sixth/seventh workflow steps (review decision, safe native disposable Trash, understood aftermath) still need a safe fixture-only native session. No onboarding infrastructure, Atlas/Tree/Trash redesign or new product feature was added.

## Corrected harness defects and all failed attempts

No product defect was established or corrected in this milestone. Three test-only issues were corrected and their logs preserved:

1. [Initial compile](build/native-acceptance/targeted-compile-before-fix.json): exit 1, private `InventoryConnection` access error and captured mutable environment warning. The harness now uses its own read-only count query and immutable environment value.
2. [Intermediate compile](build/native-acceptance/targeted-compile-before-capture-fix.json): exit 0 but one captured `cancelEnvironment` mutation warning. Immutable construction removed it. The final compile exits 0 with **zero diagnostics**, empty compiler log.
3. [First runtime](build/native-acceptance/targeted-run-before-generator-fix.json): exit -5 after **three PASS lines**, **two failed assertions** (eight artifacts and eight candidates absent), then a fatal missing-artifact error. Apple's Python redirected default bytecode into its normal user cache. Corrected generator uses `-B` and explicit `cfile` under each owned `__pycache__`. The failed run is not counted among the successful five rounds.

Eight identified generated bytecode files were moved by same-filesystem rename from only the unique failed-fixture cache subtree into its retained archive, with all eight SHA-256 values matching after relocation. No cache entry was permanently deleted. [Erratum and hashes](build/native-acceptance/fixture-generator-erratum.json). There was no baseline of broader Python import caches, so absence of other incidental cache writes is **UNVERIFIED**; the report does not claim all unrelated filesystem state was untouched. Corrected runs keep bytecode output fixture-local.

## Exact regression and build results

Broad completed campaigns were not repeated: no product/path behavior changed. All **109** source/artwork/script freeze hashes match, and **31** prior stage-record log hashes and PASS-line counts were audited. [Audit](build/native-acceptance/baseline-regression-reuse.json). These are **reused prior results**, not fresh runs. Prior failed harness attempts and expected refusal exits remain in that audit; they are not newly successful tests or new product failures. Assertion totals overlap and must not be added.

| Suite | `/private/tmp` prior result | `/tmp` prior result | This milestone |
|---|---|---|---|
| Viewer models | 804 passed | 804 passed | Reused unchanged source/log evidence; private script also emitted 2 linkage/capacity PASS lines |
| Inventory integration | 349 passed | 349 passed | Reused; existing alias preparation unchanged |
| Controller/inventory models | 67 passed, 0 failed | 67 passed, 0 failed | Reused; standard script also 67/67 |
| Monitor, retention ON | 235 passed | 235 passed | Reused |
| Monitor, retention OFF | 235 passed | 235 passed | Reused |
| Supplemental monitor | 148 passed | 148 passed | Reused; overlaps monitor |
| Standalone Trash safety | 131 passed, 0 failed | 131 passed, 0 failed | Reused; included in viewer total |
| Real API Trash fixtures | 7/7 moves | 7/7 moves | Reused; no new moves or restoration |
| Fixture retention lifecycle | 8 assertions | 8 assertions | Reused; 4 per keep flag |
| Targeted fresh/journal harness | 115 passed, 0 failed total across 5 rounds | Not rerun | Fresh; fixtures rooted only in `/private/tmp`; no path behavior changed |

The successful new run is **115 targeted assertions passed; zero failed**, 23 per round, one process over five distinct small fixtures; no hidden retries counted as passes. It validates components, not all native acceptance states. The new harness was compiled against current sources with `-O`, `-swift-version 5`, arm64 macOS14 target and SDK26.5; command and hashes are recorded. No change to application Swift settings occurred.

| Fresh development build/check | Result | Duration / diagnostics |
|---|---|---|
| `scripts/build.sh` monitor app | VERIFIED PASS | **74.710 s**, zero warnings/errors |
| `STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-gui.sh` viewer | VERIFIED PASS | **73.687 s**, zero warnings/errors |
| Targeted harness final compile | VERIFIED PASS | Zero warnings/errors |
| Both bundles strict codesign and plist lint | VERIFIED PASS | All four checks exit 0 |

[Build monitor](build/native-acceptance/build-monitor.json), [build viewer](build/native-acceptance/build-viewer.json), [bundle verification](build/native-acceptance/build-bundle-verification.json). These are development builds, not packaged/installed release artifacts. No native GUI was launched to verify them.

## Release gates — NOT READY

The original criteria are retained. **6 PASS, 2 UNVERIFIED, 2 PARTIAL.** Small-fixture evidence improves coverage without upgrading a mandatory native or representative gate.

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

The requested area mapping uses a different grouping (**7 PASS, 2 UNVERIFIED, 1 PARTIAL**); it does not replace or weaken the original ten criteria:

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

## Exact blockers and next action

1. **Finder Put Back UNVERIFIED**: operator must perform actual Put Back on each exact disposable case, then verify original paths/data/structure and restored-item app reconciliation. Existing API moves alone are insufficient.
2. **Native acceptance UNVERIFIED / execution BLOCKED**: no accepted identity-checked native session for all 1A–1E states. Current read-only QA guard blocks native Trash; establish a separately safe existing fixture-only setup without changing production data or weakening that guard. First-run five-minute workflow is unobserved.
3. **Native resources UNVERIFIED**: actual native idle/active CPU, peak/steady memory, scrolling, selection/view switching/cancellation latency require measured, operator-exercised use with recorded runs/median/P95/limitations.
4. **Representative fresh/current-journal performance PARTIAL**: obtain a suitable existing safe read-only representative catalog with fresh candidates/current journal, or retain this limitation. No new large database, full scan, migration or production writer. Controlled cancellation here does not establish blocking-provider/native behavior; no representative fresh eligible large/overlap/permission-denied workload was measured.

Recommended next action: use [OPERATOR-CHECKS.md](build/native-acceptance/OPERATOR-CHECKS.md) for the bounded operator session and exact Finder targets. If automated GUI assistance is desired, first explicitly authorize the exact named QA window and time span per AGENTS.md; current permission remains unchanged. Record observations before any gate upgrade. Reassess all original mandatory gates after real evidence. **Do not package, install, commit or push in this milestone.**
