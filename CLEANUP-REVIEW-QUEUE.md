# Cleanup Review Queue and single-item Trash validation

<!-- rc-current:start -->
## Release-candidate queue validation — current milestone (2026-10-27)

Latest authoritative ledger: [RELEASE-CANDIDATE-VALIDATION.md](RELEASE-CANDIDATE-VALIDATION.md).

Queue and multi-item plans remain **read-only**. Single-item Trash belongs only to explicit ordinary-Inspector selection/confirmation; a classification or plan never authorizes execution. The restored controller requests parent refresh on successful/uncertain outcomes and preserves newer selections. Final H controller passed **67/67 per alias**, including Queue/Inspector reconciliation; native post-action synchronization remains **UNVERIFIED**. Protected/active items and unknown mandatory boundaries remain hard blocks; the residual pathname race is accepted, not eliminated.

Representative legacy-catalog performance is **PARTIALLY VERIFIED**: 1,966,231 entries, unchanged read-only APFS clone, five bounded discovery runs. Initial eight steps median/P95 62.561/91.930 ms; 512-artifact cap after 74,240 rows in 19.108/20.816 s with incomplete coverage. No first eligible candidate is measured because the legacy journal is absent. At 512 legacy rows, five sorts combined were 41.770/42.137 ms, four filters combined 6.246/6.466 ms (50 samples each). Legacy plan exclusion 6.093/6.284 ms is not a usable overlap-plan measurement. Representative incremental updates/read-write contention and native memory/CPU/input remain **UNVERIFIED**; small synthetic fixtures are labelled separately.

Current viewer regressions passed **804 per alias** including Queue and 131 safety checks; inventory passed **349 per alias** after narrow missing-leaf invalidation and indexed-navigation alias fixes. Final pristine safety passed **131 per alias**, actual system Trash **7/7 per alias**, and both pristine development app builds passed. The unchanged full monitor suite stops at the unlink-specific event assertion under reversible fixture retention, so no full regression pass or RC readiness is claimed. Native checklists/Finder fixtures are ready, Finder Put Back remains **UNVERIFIED**, and packaging is **BLOCKED**.

All earlier stabilization/disabled-execution sections below are preserved historical evidence. Their old availability policy and counts do not override the current policy or establish current validation.
<!-- rc-current:end -->

## Filesystem safety and native QA follow-up (2026-10-27)

See [STORAGE-SAFETY-NATIVE-VALIDATION.md](STORAGE-SAFETY-NATIVE-VALIDATION.md) for the current alias fix, test ledger and limited native QA observations. Queue entries continue to deduplicate by filesystem identity, independent of display pathname. The alias regression now compares both existing paths canonically and tests `/tmp` against `/private/tmp`. A controlled development window showed populated candidates, explicit partial discovery, selection-driven Inspector evidence and a two-item plan with exact paths and unknown/APFS-qualified recovery. The session stopped when screenshot/focus evidence became inconsistent; sorting, reveal routes, narrow/wide layouts, VoiceOver and the full interaction matrix remain unverified. A scoped empty-state copy correction explains expired evidence; its rendered result has not been rechecked in a native window. No bulk action or production Trash execution was enabled.

## Stabilization continuation — current source

The queue and multi-item plan remain read-only. Ordinary Inspector Trash execution is disabled at the controller, token policy, legacy entry point and direct system adapter. Classification, advisory eligibility and hard protections remain; neither a review candidate nor warning acceptance authorizes a move. The examined APIs did not establish the required atomic reviewed-object-and-protection guarantee. This is a bounded evidence conclusion, not proof that every possible macOS API is incapable of it. See `CLEANUP-TRASH-SAFETY-AUDIT.md` for the execution boundary and primary API sources.

The current regression/build ledger is `CLEANUP-STABILIZATION-REPORT.md`. Historical successful Trash tests and prior suite counts below do not establish current mutation capability. No real Trash operation, restoration or permanent removal was performed in this continuation; the earlier 12 disposable Trash fixtures were left untouched. Finder Put Back, physical recovery, native layout, interaction, focus and VoiceOver remain **NOT VERIFIED**. Repository `AGENTS.md` prohibits native window launch/activation and input without explicit permission; none was granted for this continuation.

### Current freshness, continuation and accounting behavior

- Every status, filter, candidate count and plan uses the current evidence time. Process observations expire after 20 seconds even without filesystem events. The visible queue reevaluates retained evidence once per second without process, Git, filesystem or catalog collection. Expired rows become Insufficient evidence and expose no recovery estimate; the reused Inspector receives the same invalidated assessment.
- The journal cursor records the last consumed change batch. A discovery page carrying a newer journal stamp does not silently acknowledge intervening changes. Missing, replaced, regressed, incomplete or over-budget history requests explicit resynchronization. Discovery/selection reads suspended across cancellation, reset or journal invalidation cannot overwrite the newer state when they return.
- Changed listings use bounded name/ID continuation. A new change for the currently paged directory restarts that listing cursor, so an inserted child sorting before the old cursor is reconsidered. Retained identities deduplicate results. Discovery requests are serialized across actor suspension; cancellation and artifact/row budget continuation preserve explicit bounded progress.
- Unknown indexed allocation remains Unknown. Logical size is never substituted into indexed allocation, its sort or the plan total. Any unknown selected allocation or overflow makes that total unknown. Stale evidence cannot support estimated recovery. Duplicate identities and parent/child overlap are excluded; multi-item physical recovery is not summed.

Targeted queue regressions were recovered as **83/83** in `/private/tmp/stabilization-benchmark-633f8e21-84de-49b0-bac8-b784d46a8207/bounded-benchmark.log`. These are included in the integrated viewer suite, not additional tests. Exact final combined totals and failures belong in the stabilization ledger.

### Current bounded representative benchmark — partial verification

An APFS clone at `/private/tmp/stabilization-benchmark-633f8e21-84de-49b0-bac8-b784d46a8207/catalog.sqlite3` contains **1,966,231 legacy catalog nodes**, with no change journal. `provenance.json` records `clonefile` with no full-copy fallback, no WAL/SHM/journal sidecars, and unchanged source metadata. Its 1,018,322,944-byte logical file size is not exclusive APFS allocation. Only the disposable clone was queried; it was not migrated or written. Evidence and process classification read the current filesystem under existing bounds.

Measurements below are from `bounded-benchmark.json` and `.log` in that same directory, on the shared M2/8 GB host; cache state was uncontrolled.

| Bounded headless measurement | Result |
|---|---|
| 32 metadata pages of 128 rows, 4,096 rows total | p50 **1.094 ms**, p95 **4.198 ms**, maximum **9.667 ms**; zero read errors |
| 16 live evidence/process/classification samples | p50 **5.709 ms**, p95 **7.511 ms**, maximum **9.216 ms**; 12 classified artifacts |
| First classified evidence | **7.260 ms**; eligibility was not established |
| Eight bounded actor steps (128-row pages, 2 inspections/step) | **50.580 ms**, 512 rows examined, 11 retained, **0 eligible review candidates** |
| Five sorts plus filtering over 12 retained sample rows | p50 **0.213 ms**, p95 **0.228 ms** |
| Multi-selection plan over the same invalidated sample | p50 **0.024 ms**, p95 **0.028 ms**; no eligible recovery plan established |
| Four concurrent readers, five batches | batch p50 **0.669 ms**, p95 **0.694 ms**; zero read errors |
| Cancellation / headless idle / peak RSS | cancellation **0.044 ms** observed; **0.106 ms CPU / 1.065 s wall** idle; **16,285,696 bytes** peak process RSS |

The RSS unit is bytes on Darwin (`getrusage(RUSAGE_SELF).ru_maxrss`). It is the high-water mark for the entire headless process, including its earlier targeted regressions and benchmark work; it is not incremental queue memory or native app RSS.

These are bounded samples, not complete discovery, cold-query, native rendering or production throughput results. The legacy clone cannot verify incremental journal behavior or first eligible candidate latency without an authorized migration, which was not performed. Concurrent reader timing does not test read/write contention; the clone was static. The small invalidated plan/sort sample and one headless Inspector refresh (6.868 ms) do not establish interactive table, large selection, navigation, application memory growth or native idle behavior. Those remain **NOT VERIFIED**. Deterministic fixture regressions cover journal interleavings separately.

Everything under the prior milestone heading below is historical, including its test counts, executable Trash behavior, synthetic benchmark and remaining-work recommendations. It must not be used as a current release-readiness claim.

## Prior milestone record

Status: implementation staged in the isolated workspace copy; all four standard headless regression suites and both application builds passed against the final reviewed source. Final real macOS Trash validation passed four disposable cases. Native-window behavior and Finder Put Back remain unverified. This document separates source-verified behavior, exercised fixture behavior, and checks that require a real application window. No label here implies that an artifact is safe to delete.

## Scope and provenance

Work is in `/Users/nicholaslippa/orca/workspaces/storage monitor check/catshark/storage-checker`. `~/storage-checker` was absent; the application source was found at `/Users/nicholaslippa/orca/projects/storage-checker`. That checkout contained pre-existing uncommitted Inspector and Living Tree changes. An allowlisted source-only copy preserved current `Sources`, `SourcesGUI`, `SourcesShared`, `scripts`, `tests`, `Assets`, `bin` and root documentation/configuration, excluding `.git`, builds, catalogs, backups and retained scratch databases. Changes in this milestone are confined to the isolated copy and disposable test fixtures.

Final source-preservation verification compared all 138 original source/artwork hashes, the original dirty git status and tracked diff: all were unchanged (`build/cleanup-review-validation/source-preservation.json`). No production database was opened for this check. No production catalog storage, production LaunchAgent, retained scratch catalog, backup or installed application was modified. No full-volume scan, automatic cleanup, scheduled cleanup, bulk Trash, permanent removal, Trash emptying, installation, packaging, commit or push is part of this milestone. Native GUI automation was not authorized and was not performed.

## Verification vocabulary

- **VERIFIED:** exercised by the cited fixture/log or directly inspected in current source; the evidence type is stated.
- **PARTIALLY VERIFIED:** implemented and bounded fixture/source evidence exists, with production, filesystem or rendering limits explicitly listed.
- **UNVERIFIED:** not exercised in this pass. Historical reports are not substituted for current evidence.

## Safety audit before modification

The existing implementation was read before changes. Source audit findings:

| Question | Existing behavior and gap |
|---|---|
| Filesystem identity | Inspector compared inode and optional birth time, omitted device, and accepted a subject with no indexed identity as verified. |
| Protection | `ArtifactProtection` provided lexical protected paths; the advisory policy added broad absolute/home roots and hard-link aliases. Execution did not independently repeat all those policy boundaries. |
| Active executable references | Detectors used process and PATH/current-version evidence, but execution did not refresh it. Open-file observations were limited to coding-agent processes. |
| Symlinks | Probe used `lstat`, bounded no-follow reads and canonical references. Trash addressed the lexical path without a complete ancestor-link/identity snapshot. |
| Descendants | There was no bounded check that removal of a directory included a hard-blocked descendant or protected root. |
| Trash mechanism | Supported single-item `FileManager.trashItem`; no permanent-delete fallback. |
| Errors | The Inspector distinguished moved/refused/failed outcomes, but success wording asserted Finder Put Back without a real restoration test. |
| Inventory refresh | A move requested a refresh of its parent, but request-write errors were discarded. |
| Confirmation bypass | Preserve could be overridden even when it represented a running/current executable, active database, or dirty/untracked/potentially-unmerged worktree. Execution accepted a caller-supplied decision. |
| Races | Identity was read before path-based execution without an immutable pre-confirmation snapshot, descendant/parent fingerprint, or fresh process/Git checks. |

These are **VERIFIED source findings**, not evidence that real user files were endangered or that old tests covered production safety.

## Explicit Trash policy

**Hard blocks:** protected/system-managed paths; credentials and sensitive authentication stores; active Storage Monitor data; home and critical home roots; ancestors containing protected roots; running executables and verified active references; active databases; Git work with uncommitted/untracked/potentially unmerged state; hard-blocked descendants; unverifiable identity; or required protection/use checks that cannot finish reliably. User acknowledgment cannot override a hard block.

**Overridable warnings:** ordinary files/folders, unknown artifacts, insufficient evidence without a hard block, unresolved historical references and other nonprotected user content. The sheet explicitly says Storage Monitor has not established whether removal is safe.

**Review candidates:** a single-item confirmation remains mandatory. The exact target, classification, supporting evidence, risks, indexed allocation and uncertain physical recovery are shown. The product never labels an action “Safe to delete.”

`CleanupTrashPolicy.prepare` produces an immutable one-use token for the validated object before the sheet appears. The token expires after 60 seconds and is invalidated on cancel. Before execution, bounded descendant/ancestor snapshots, identity, protection, active process/file references and relevant Git state are checked again. Changed evidence or incomplete required checks refuses the operation. The normal Inspector uses the token; queue rows and the queue's reused Inspector contain no Trash action. A hardened legacy entry point remains for existing test callers and independently performs safety validation.

**Residual race:** the supported macOS Trash mechanism accepts a path, not an expected inode. Final validation reduces replacement opportunities but cannot promise an atomic compare-and-trash operation. Concurrent uncooperative filesystem writers can still change a path between the final check and the system call. This is **PARTIALLY VERIFIED safety**, with a material production limitation.

The final independent source review also strengthened Git output collection through child exit and complete pipe EOF, refuses malformed/truncated status data, protects `.git` internals, bare/separate Git metadata and repositories supporting external registered worktrees, and extends credential protection to Git credential and Kubernetes stores. Whole-repository removal cannot treat another local reference inside the same target as surviving preservation; remote preservation evidence must cover its local commits. These reviewed cases have dedicated fixture regressions; the review is not an exhaustive production certification.

Successful Trash requests reconciliation of the enclosing folder. A request failure is shown without changing a successful move into a failed move. Nothing reports reclaimed bytes merely because an item entered Trash. `FileManager.trashItem` returning success does not establish Finder Put Back support or physical recovery.

## Queue architecture

Shared implementation lives in `SourcesShared/CleanupReviewQueue.swift`; paginated catalog reads extend `InventoryReader` in `InventoryModels.swift`. No new database schema or persistent queue table is required. `CleanupReviewQueue` is an actor with a bounded retained entry set, a discovery cursor, change-journal cursor, generation, pending page and progress record. It calls the existing `ArtifactInspector`, detectors, `ArtifactProbe` and assessment policy. There is no LLM dependency or second classification engine.

`InventoryReader.cleanupDiscoveryPage` visits indexed metadata in keyset pages and returns potential matches for bounded evidence collection. A name/path hint is not a verified artifact. Detector validation must establish a recognized layout with Strong or Confirmed confidence and verified identity before an entry becomes a verified artifact. Tentative classifications remain potential matches with insufficient evidence; unclassified false positives are discarded. Assessment distinguishes Review candidate, Preserve, Insufficient evidence and Protected. No full-volume recursive filesystem scan is used for discovery.

Default budgets: at most 128 examined index rows per discovery page, four inspections per step, 100,000 examined rows per scan tranche and 512 retained entries per artifact page. Each evidence probe permits 1,000 entries, 24 reads and 0.35 seconds. The UI requests at most eight steps per activation/Continue action and publishes progress after each step. Entry/page/tranche limits, cancellation and incomplete coverage are explicit. Continue grants another bounded scan tranche without revisiting earlier rows. At the retained artifact limit, Next artifact page releases the previous bounded page and its selection, preserving the pending candidate and keyset cursor. Counts of paged-out artifacts explain the omitted earlier entries; no full queue accumulates in memory. Sorting operates only on the retained bounded set. There is no eager materialization of a multi-million-row inventory.

## Supported discovery categories

| Potential family | Verification reuses |
|---|---|
| Claude Code releases/installations | Existing version layout, executable header, PATH/current/running evidence |
| Codex releases/installations | Existing channel/release metadata, executable layout, current pointer and process evidence |
| Historical coding-agent sessions | Existing Claude/Codex session layout and timestamp/open-file observations; no conversation reads |
| Node dependencies | Existing package manifest/lock/install-layout evidence |
| Generated build output | Existing generated-output detector and project evidence; ordinary folders named build/dist are not proof |
| Python environments and caches | Existing `pyvenv.cfg`, project/tool links, bytecode-only/cache layouts |
| Git linked worktrees | Existing verified pointer/registration and bounded Git-state inspection |
| Package-manager caches | Existing npm/pnpm/Yarn/Bun/pip/uv layout checks |

The queue covers indexed metadata under recognized layouts, not every artifact on a volume. Unindexed, inaccessible, unsupported or over-budget entries remain outside verified coverage.

## Evidence freshness

Every entry retains its indexed node and stable filesystem identity, canonical path, inventory generation, journal cursor, evidence/assessment/measurement timestamps, process observation, classification confidence and unresolved uncertainty. Journal changes, generation changes, resynchronization and incomplete/stale measurements invalidate retained evidence conservatively. Changed-directory records also feed bounded parent/name-keyset listing discovery, including new artifacts added after a complete initial pass. The changed-listing backlog is capped at 256 directories; an oversized backlog, missing journal or resynchronization requirement stops incremental discovery explicitly until Restart indexed review. No unknown change history is silently acknowledged as fresh. The queue refreshes current indexed identity and relevant live evidence when an entry is selected. Disappeared entries are removed rather than keeping recommendations.

Process observations become stale after 20 seconds for freshness reporting. The filesystem journal does not observe process launches, exits or file handles. Earlier “not observed” process evidence is never treated as continuing proof of inactivity. The queue refresh result is adopted into the existing Cleanup Inspector controller; it is not independently reclassified by a second Inspector. Previously reviewed assessments remain timestamped historical evidence, while freshness and revalidation requirements are displayed explicitly. Stale evidence cannot establish a recovery estimate.

## Native UI and selection

Disk Inventory's Browse picker gains **Review Candidates**. It is contextual navigation inside the filesystem explorer, not a dashboard. Initial filtering shows Review candidates. Assessment, artifact-type and tool filters and recovery/allocation/type/confidence/last-verification sorting act on retained entries. Tentative potential matches appear under Insufficient evidence, or can be included explicitly under All assessments; they are labeled as potential, never as cleanup opportunities.

Rows show artifact/tool/type, assessment and confidence, indexed allocation, estimated recoverable amount or Unknown, evidence age and a relevant uncertainty/risk. Progress distinguishes checked indexed entries from verified artifacts and Review candidates. Cancel preserves bounded progress; Continue resumes at the catalog cursor. Reaching a budget explains incomplete coverage and offers another bounded tranche or artifact page. Sorting and filtering cover the retained page, not a global materialized list.

The existing `InventoryInspectorView`, `CleanupInspectorSection` and preview are reused. At wider widths the Inspector sits beside the table; at compact widths Review evidence opens it in a native sheet. Queue context hides Trash. Evidence expansion, risks, related versions, exact path, measurement and APFS limitations use the existing Inspector. Reveal in Navigator/Atlas/Living Tree uses the browser's enclosing-folder/pending-reveal path and existing selection synchronization. Finder actions in the ordinary Inspector remain user-invoked only; no such action was executed during testing.

## Read-only multi-item plan and APFS accounting

Multiple table selections feed `CleanupReviewPlan`, which exposes no execution or Trash capability. It includes only Review candidates and lists excluded noncandidates. The plan shows exact paths, tools, indexed allocations, per-item estimates/Unknown, dependencies, risks, required revalidation and protected related artifacts. Identity duplicates and parent/child overlap are excluded from counted items and reported explicitly. A parent's indexed subtree is not added again for its selected child.

Indexed allocation is a qualified catalog quantity, not physical recovery. Multi-item APFS sharing prevents a defensible aggregate recovery sum, so the plan says **“Total recoverable storage cannot be determined.”** Unknown amounts are counted explicitly. A single-item defensible estimate remains an estimate, qualified by freshness, hard links, clones and snapshots. Trash does not imply that available disk space increased.

## Historical validation ledger

Final results below are **VERIFIED** in the stated scope. Standalone safety and queue counts are included in the integrated viewer count, not added a second time. All final suite/build compilations emitted **zero compiler warnings and zero compiler errors**.

| Standard suite or build | Final result | Evidence under `build/cleanup-review-validation/` |
|---|---|---|
| Viewer models / read-only regressions | **724 passed**; includes 73 Trash safety and 70 review-queue checks | `test-gui-final-reviewed.log` |
| Inventory integration | **345 passed** | `test-inventory-final-reviewed.log` |
| Headless inventory/controller | **50 passed, 0 failed**; includes exact-target confirmation, shared Inspector selection, escaped paths, reveal synchronization and real fixture-worker reconciliation | `test-inventory-model-final.log` |
| Monitor self-test | **233 passed** | `test-monitor-final-reviewed.log` |
| Background monitor target | **Build passed**, SDK 26.5, arm64, macOS 14 deployment target | `build-monitor-final.log` |
| Native viewer target | **Build passed**, SDK 26.5, arm64, macOS 14 deployment target | `build-viewer-final.log` |

Additional source/linkage checks passed: the final viewer does not link UserNotifications; live-capacity code launches no process and writes no SQL. Both development app signatures verified with `codesign --verify --strict`, and both Info.plists passed lint. These checks do not establish native interaction or distribution readiness. No DMG, installer, installation, commit or push was created.

Targeted standalone evidence: `build/cleanup-review-evidence/trash-safety-final-reviewed.log` (**73/73**) and `build/cleanup-review-queue/evidence/queue-tests.log` (**70/70**). Coverage includes ordinary file/folder warnings, cancellation, unknown/insufficient evidence, hard protections and descendants, running/active references, dirty/untracked/unmerged Git work, Git output completeness and metadata/common-repository dependencies, changed identity, final-check replacement, failed permission/Trash/post-result verification, pagination, false positives, deduplication, bounded memory, cancellation, stale/journal/process evidence, incremental new-candidate discovery, actor interleavings, sorting/filtering, selection/plan overlap, unknown allocation and APFS uncertainty. Model evidence is not a production-safety certification.

**Final real Trash: VERIFIED, 4/4.** The final reviewed implementation moved only a disposable ordinary file, ordinary directory, recognized Node dependency candidate and symlink itself. Returned device/inode identity matched, original entries were absent, and the symlink referent remained. A separate disposable running executable was observed through the real kernel process table and hard-blocked. Evidence: `build/cleanup-review-evidence/real-trash-validation-final-reviewed.log` and `real-trash-results-final-reviewed.json`. The final fixture root is `/private/tmp/storage-monitor-trash-validation-7BA9E33C-D824-4BA4-9AD5-61F2FA2F7ADD`. Three successful four-item runs left **12 disposable items in Trash** across the milestone; none of those real-Trash fixtures was restored, emptied or permanently removed. Finder Put Back is **UNVERIFIED**. Physical storage recovery was **NOT MEASURED**, and no reclaimed amount is reported.

**Earlier attempts, not final passes:** sandboxed Trash attempts returned four permission failures; scoped approved runs later passed. A sandboxed monitor self-test stopped at a live VM/swap counter assertion, and an inventory run stopped before enumerating fixture entries; authorized fixture-only reruns passed. An initial viewer run failed an existing test that fingerprinted the concurrently written production monitoring folder; the harness now requires byte/metadata stability of controlled isolated history/log/lock fixtures and does not open production monitoring data. The first added headless reconciliation attempt encountered an older synthetic stand-in request outside that catalog root; the new workflow has its own disposable tree/catalog and now verifies the real worker removes the vanished indexed target. An existing semaphore wait in an async inventory test emitted one warning; replacing it with an asynchronous continuation gate preserved deterministic cancellation and removed the warning. Final results above include these corrections; failed/inconclusive attempts were not counted as passing.

| Remaining harness or behavior | Verification status and reason |
|---|---|
| `tests/verify-launchd-notification.sh` | **NOT RUN:** starts an installed helper with launchd and sends a user notification; outside this milestone's service/desktop authorization. Notification behavior has simulated headless coverage, not a real delivery claim. |
| `GUIAXTests` / native queue, Inspector, confirmation, keyboard/focus/VoiceOver and reveal interaction | **UNVERIFIED:** AX actions, focusing and desktop input require separate GUI authorization. No application window was launched or activated. |
| Existing offscreen Inspector scroll probe | **NOT RUN:** its launcher contains recursive removal and its selector hard-codes real Claude versions. No real tool/catalog fixture was substituted. Headless controller tests cover preview preservation; native/offscreen rendering remains unverified. |
| DMG verification / packaging | **NOT RUN:** packaging was expressly excluded; no DMG was produced or mounted. |
| Finder Put Back | **UNVERIFIED:** a successful Trash API response and a test adapter's ordinary rename are not Finder restoration evidence. |
| Representative multi-million-node catalog performance | **UNVERIFIED:** only the bounded synthetic benchmark below was run; production catalogs and retained scratch catalogs were not used. |

## Historical performance benchmarks

The queue benchmark used a synthetic 100,000-row disposable catalog. **VERIFIED synthetic measurements** reported by the benchmark runner: total discovery 80.75 ms; 256-row page p95 0.213 ms; five sorts plus filtering over 512 retained rows p95 3.635 ms; cancellation 0.074 ms; RSS approximately 15.5 MB. The query plan used the rowid primary-key search. Evidence: `build/cleanup-review-validation/benchmark-synthetic.log`. The 100,000-row catalog occupied 3,420,160 bytes. Page p50 was 0.183 ms (maximum 0.532 ms); a cheap bytecode-cache fixture classified at p50 0.036 ms / p95 0.041 ms, approximately 9,438 inspections/s. This is not process/Git-heavy evidence throughput. A 250 ms idle interval consumed 0.175 ms process CPU in the headless benchmark; it does not measure native viewer idle behavior.

**VERIFIED hardware context:** read-only `sysctl` returned `Mac14,2`, `Apple M2` and `8,589,934,592` bytes memory (`build/cleanup-review-validation/hardware-context-authorized.txt`). [Apple identifies Mac14,2 as MacBook Air (M2, 2022)](https://support.apple.com/en-us/102869). The synthetic measurements therefore ran on the target hardware class, on a shared working machine. This does not turn them into representative application measurements.

**UNVERIFIED:** native queue/Inspector experience on that hardware, production multi-million-node latency, cold-query behavior, native Inspector navigation/render latency and application idle CPU. Historical Inspector measurements are context only. Synthetic fixture throughput cannot establish production query or evidence latency.

## Historical limitations and next-milestone recommendation

1. Path-based Trash retains the final TOCTOU interval; bounded checks do not turn it into an atomic object operation.
2. Required incomplete safety checks fail closed, so some legitimate large, unreadable, linked or actively changing directories cannot be trashed from the app.
3. Discovery has explicit row/entry/evidence limits and covers indexed recognized layouts only; it does not claim complete volume coverage.
4. Journal invalidation is conservative for the bounded retained set, rather than a minimal per-ancestor dependency graph. Sorting/filtering and identity deduplication apply within a retained artifact page; earlier released pages are not kept as an unbounded duplicate set.
5. Process observations cover current-user executables, working directories and observable open file descriptors. They do not establish global inactivity: other UIDs, libraries/memory-mapped files after descriptors close, shared memory and future process starts are not completely observed. Required observation failures fail closed; a completed scoped observation still means “not observed in this scope,” never “not in use.” Processes can change independently of journal events, and historical observations are never a deletion authorization.
6. APFS clones, hard links and local snapshots prevent general recovery totals. Physical recovery after Trash is unmeasured unless specifically recorded otherwise.
7. Finder Put Back, native interaction/rendering and the representative 8 GB application experience require separate validation.

Recommended next milestone: authorized real-window queue/Inspector/confirmation and Finder restoration validation using disposable fixtures, plus a bounded queue performance pass on an isolated representative multi-million-node catalog and the target M2/8 GB machine. Keep the queue and plans read-only. Database lifecycle recommendations are recorded separately in `DATABASE-LIFECYCLE-FOLLOWUP.md`.
