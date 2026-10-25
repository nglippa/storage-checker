# Inventory reconciliation correction

## Authorized QA worker upgrade — 2026-10-23, 01:23 UTC

After the correction pass, the user explicitly requested the newer code on the existing QA worker. That later authorization supersedes the previous prohibition on changing that QA worker/database for this upgrade only. Production remains excluded.

The old worker exited through supported cancellation, then its QA service was unloaded. Its old app and unchanged LaunchAgent configuration were preserved. A consistent 1,401,688,064-byte pre-upgrade SQLite backup passed `quick_check` and foreign keys. Only the QA executable was replaced with the verified lifecycle correction build and the QA bundle was re-signed. Supported resume cleared the pause intent; the same LaunchAgent was loaded without a new refresh request or new full-volume crawl.

The new worker is running, the additive lifecycle migration is present, and generation 1 was retained. At 01:23 UTC the catalog held 2,912,497 nodes and 389,450 completed directories. New completed-sequence/token metadata confirms listings committed under the corrected code. All 20 root children remain present. The seven historical tables match the pre-upgrade backup row for row; installed production binaries, production LaunchAgent and the original evidence snapshot hashes remain unchanged. No production migration or installation occurred.

Evidence: `build/inventory-correction/qa-upgrade-20261023T012028Z/` contains the old app/configuration, verified pre-upgrade database, before/after-start records and `validation.json`. An optional online post-upgrade validation copy was cancelled because ongoing writes repeatedly restarted copying; that incomplete copy is explicitly not evidence. Final history comparison used a short read-only transaction instead.

Legacy refresh work was retained conservatively: missing historical listing order cannot justify discarding it. Resuming this old contaminated catalog is not a clean first-index benchmark. Multi-day customer initialization is unacceptable; initial-index performance remains a release blocker. The bounded fixture timings do not establish customer-scale speed. No production-readiness claim is made.


## Pre-change state map (2026-10-22)

This map was recorded before implementation changes. The preserved snapshot is immutable; all mutation tests use disposable copies. The active QA worker, its database, installed applications and production services are outside this pass.

| Transition | Durable authority and transaction | Limitations before correction |
| --- | --- | --- |
| Start/resume | `prepareInventoryRoot` preserves the active generation for the same root identity, otherwise creates a new generation/root/job atomically. Worker file lock excludes another traversal worker. | SQL invalidation writers may run independently. |
| Select directory | Oldest pending/enumerating job; path derived from parent links. Job holds listing token and device/inode/birth/mtime/ctime checkpoint. | No durable ordering between a request and a successful own listing. |
| Enumerate | `lstat`, `opendir`, `readdir`, `fstatat`, final `fstat` outside SQL transactions. Reopening replays committed names, not an invalid saved directory cookie. | Filesystem observations are not a filesystem snapshot. Mutation checks and later events supply uncertainty/reconciliation. |
| Persist batch/discover | `BEGIN IMMEDIATE` writes objects/names, seen tokens, hard-link ownership and new directory jobs. First batch increments listing token. Bounded sibling listings may share one transaction. | Completed child jobs retain state when their parent sees them; `updated_at` is therefore not own-listing completion time. |
| Complete listing | Final batch marks the job complete, clears checkpoint, optionally creates prune marker and recomputes ancestors in the same transaction. | Unavailable jobs also use complete state with reason. No separate successful completed token/sequence. A newer listing with no missing children leaves an old prune marker behind. |
| Schedule cleanup | Marker stores parent, seen token, discovery cursor. Non-directory replacement uses token -1 to remove old descendants. | Marker has no parent object identity; recursive tombstones lose their originating authority. |
| Execute cleanup | After jobs/reconcile drain, SQL pages marker candidates into tombstones, expands descendant frontier, deletes leaves, repairs hard-link ownership and propagates aggregates in bounded transactions. | Authority is not rechecked inside deletion transactions. New parent observations can invalidate older tokens after tombstones were generated. |
| Request refresh | Immutable UUID request file has wall-clock request time. Worker consumes it into SQL invalidation, defaulting to root. | File request time is not used to order listings. Manual refresh uses `gap=true`. |
| Queue event evidence | Same coverage FSEvents replay, separate inventory cursor. Invalidations and cursor acknowledgement commit together. Root/subtree gaps use broad invalidation. | Applied event rows are removed; no per-directory last successful listing boundary. |
| Apply invalidation | Atomically marks target stale/pending, creates/restarts broad reconcile if needed, removes consumed invalidation. | Completed listings cannot satisfy a queued broad request reliably. |
| Expand refresh | Finite `end_node_id`, durable `last_node_id`; indexed bounded directory pages. A later gap resets the frontier and endpoint. | Every candidate is enqueued, even when listed since request. Legacy pass endpoint was captured much later than original request. |
| Interrupt/retry | Committed batches survive; changed snapshots restart tokens, unavailable listings retain unknown totals, absent/replaced children schedule parent repair. Watchdog persists blocked status separately. | Failed attempts cannot certify deletion authority. |
| Aggregate/read | Ancestor sums, ownership and coverage propagate with batch/cleanup transaction. Readers use read-only committed SQL; ancestor work/queued invalidation can qualify values stale. | `measured_at` may be aggregate time, not own listing time. Broad work and node counters differ. |

Relevant code before changes: `Sources/Inventory.swift`, `Sources/InventoryCommands.swift`, `SourcesShared/InventoryModels.swift`, `SourcesShared/InventoryRequests.swift`, and `Sources/Coverage.swift` (`CoverageActivity`, replay, mount/firmlink gates and I/O policy).

Lost information cannot be recovered by migration: exact historic own-listing completion times, consumed invalidation history, and original endpoint of the pre-endpoint QA request. Legacy completed listings must not be retroactively certified as newer than an old request.

## Correction and verification

### Executive summary

The development implementation now rejects obsolete cleanup authority inside the deletion transaction and orders refresh requests against directory listing starts with a durable sequence. A refresh has a fixed catalog endpoint and skips successful listings that satisfy its boundary. Later events and gaps still require newer observation. No active QA or production state was changed.

The preserved snapshot reproduced the unsafe root selection: the old marker selected all 20 current root children. Corrected cleanup retained all 20, retired 256 additional obsolete markers without deleting current records, and still removed a genuinely absent entry under valid authority. All 114 inventory checks, 192 monitor checks and 273 viewer checks pass. A real process-kill/recovery test also passes.

This is a correction of lifecycle correctness with bounded performance evidence. It is **not production acceptance**: no clean full-volume benchmark or full-volume steady-state verification has been completed with this code. The still-running QA worker uses its existing executable, including its old lifecycle behavior; its output cannot validate this correction.

### Root causes and work classification

The 06:40 UTC manual full-root refresh was consumed without retaining a reliable ordering boundary against own-directory listings. `updated_at` and aggregate `measured_at` could not substitute for that boundary. A directory successfully listed later could therefore be queued again. Earlier scheduling also allowed the request to grow as the catalog grew. These candidates require filesystem enumeration when actually queued; they are not database-only size recomputation.

Cleanup markers survived newer listings, and recursive tombstones lost their originating listing authority. Candidate selection outside a delete transaction did not prove that its token remained current. Cleanup itself operates on SQLite inventory records, **not user files**, but corrupting that catalog can invalidate navigation, ownership and totals. Retiring obsolete markers is database-only work; valid recursive cleanup is also database-only. Ambiguous legacy tombstones require directory reobservation before they can safely authorize deletion.

The snapshot contained 313,351 unexpanded refresh candidates: 311,552 previously successful listings and 1,799 unavailable listings, plus 229 already queued manual-refresh jobs. “Previously successful” does **not** mean “provably satisfied after the request.” Historic own-listing order and consumed events were not retained. Migration therefore certifies **zero** legacy candidates as already satisfied. Skipping all 311,552 would manufacture evidence. The new metadata prevents that ambiguity for future requests.

### Exact invariants and corrected transitions

1. **Cleanup authority is checked inside `BEGIN IMMEDIATE` before deletion.** A listing marker must match the parent's current and successfully completed listing tokens, with complete job state and no failure reason. Replacement cleanup must still match its recorded replacement object. Each recursive claim carries its epoch, originating parent and root edge. Current ancestry, leafness and newer descendant observations are checked again before deletion. A competing listing commit either precedes this transaction and invalidates its authority, or waits until after this bounded transaction.
2. **Newer listings supersede old cleanup.** Successful EOF publishes its completed token/sequence and retires or replaces earlier prune authority atomically. Claims from obsolete epochs cannot delete records. Orphan claims are retired in bounded pages. Overlapping claims have a composite epoch/node identity; one retired claim cannot erase another's authority.
3. **Known newer evidence wins.** Queued invalidations prevent leaf deletion until applied. A newer descendant observation invalidates the origin and schedules parent repair; moved entries and their descendants cannot be deleted through an old edge. A filesystem mutation not yet observed remains an eventual-consistency limitation: later FSEvents/relisting repairs it. SQLite and the filesystem do not form a single atomic snapshot.
4. **Successful listing means stable identity and directory metadata through EOF, all observed entries committed, and no unavailable/change outcome.** Merely reaching terminal job state, propagating aggregates, or seeing the directory in its parent's listing does not qualify. Mutation, failed access, a new event/gap, or replacement removes current authority. Uncertainty propagates to ancestors.
5. **Requests and listings use a generation-local monotonic sequence, not wall-clock timestamps.** A listing receives its sequence before filesystem I/O. Successful EOF persists it. A request captures the next sequence and a finite maximum node ID in one read snapshot; its immutable request file carries the generation identity and endpoint until consumed. An earlier in-flight listing cannot satisfy that boundary. With no committed checkpoint, recovery allocates a new listing start; committed-prefix recovery preserves the original attempt's boundary.
6. **Refresh satisfaction is conditional.** A successful own listing with completed sequence at or beyond the request satisfies it only while the job remains complete without a failure reason. A newer event or gap receives a newer boundary and requeues it. An unavailable job does not count as success. A later refresh cannot be satisfied by an earlier listing. Two requests captured before the same later listing may legitimately share satisfaction.
7. **Reconciliation remains bounded and durable.** Each pass retains request sequence, endpoint and frontier. Newly discovered nodes beyond that endpoint are handled by initial discovery, not appended to the old pass. A newer overlapping gap resets the frontier and can extend the endpoint to its own receipt boundary. A delayed older request cannot roll back newer authority. A page revalidates its sequence/frontier/endpoint inside its write transaction before advancing.
8. **Publication is atomic.** Entry changes, hard-link owning-name repair, affected ancestor totals and cleanup checkpoints commit together in bounded transactions. Readers never see half a deletion batch. Queued invalidations and outstanding reconciliation qualify reader completeness immediately. Missing or inaccessible content remains unknown, not zero.

Durable state now includes listing start/completion sequence and token, request sequence/endpoint, reconcile frontier, cleanup epoch/provenance and claims. Paths, aggregate coverage and reader state are derived from committed relationships/work. Individual consumed events and old listing history still are not retained permanently; this change deliberately adds directory-level authority rather than a per-file event log.

### Files and forward-only migration

The correction touches `Sources/Inventory.swift`, `Sources/InventoryCommands.swift`, new `Sources/InventoryProfile.swift`, `SourcesShared/InventoryRequests.swift`, `SourcesShared/InventoryModels.swift`, and the existing `SourcesGUI/InventoryView.swift`. Regression coverage is in `tests/InventoryLifecycleTests.swift`, `tests/InventoryBoundaryTests.swift`, and `tests/InventoryIntegrationTests.swift`, integrated through `scripts/test-inventory.sh`. New bounded tooling is `scripts/inventory-verification.swift`, `scripts/build-inventory-verification.sh`, and `scripts/benchmark-inventory-initial.py`. `scripts/build-gui.sh` accepts an explicit existing SDK path for the build issue below. Existing uncommitted inventory-foundation files remain part of the broader worktree; no unrelated screen redesign was made.

The additive, introspected migration adds:

| Table | Added authority |
| --- | --- |
| `inventory_generations` | `inventory_sequence`, `cleanup_sequence` |
| `inventory_jobs` | `listing_sequence`, `completed_sequence`, `completed_token` |
| `inventory_invalidations` | `request_sequence`, `end_node_id` |
| `inventory_reconcile` | `request_sequence`; preserve existing endpoint/frontier |
| `inventory_prune_jobs` | `cleanup_epoch`, `authority_kind`, `authority_object_id`, `authority_sequence` |
| New `inventory_tombstone_claims` | Composite epoch/node key, origin root/parent, generation, bounded-work indexes |

Lifecycle ALTERs and legacy adoption are transactional and restart-safe. Rollback/retry is tested. No catalog reset, history rewrite or table drop is used. Existing tombstones remain compatible with the reader. Legacy successful listings retain sequence zero; they are not assigned fictional historical ordering. A locally matching legacy completed token can establish cleanup authority, while mismatched markers are retired. Legacy recursive tombstones lacking provenance never authorize deletion: they schedule bounded parent reobservation instead. Legacy requests are adopted before allocating a later invalidation so an old marker cannot leapfrog a new gap.

### Snapshot regression evidence

Immutable source: `build/inventory-verification/backlog-snapshot-20261022T203340Z.sqlite3` (2,888,851 nodes). SHA-256 before and after:

`c0fa9524d9e62c095af35abeadf0d69fe3ed5f0ba0307f2d4524a6096f4b91f2`

Only disposable `build/inventory-correction/snapshot-copy.sqlite3` was migrated and mutated. The earlier disposable trial is retained separately. The harness enforces the disposable snapshot path.

| Check | Result |
| --- | --- |
| Old root selection reproduced | 20 current children selected by obsolete token |
| Corrected obsolete root cleanup | All 20 current children retained |
| Other stale markers exercised | 256; no current record loss |
| Authoritative cleanup | One genuinely absent seed removed in five maintenance steps; observed siblings retained |
| Historical tables | All seven original tables equal the immutable source row for row |
| Refresh endpoint | Preserved at 2,638,771; no expansion |
| Remaining legacy candidates | 313,351; zero safely certifiable as satisfied from legacy metadata |
| SQLite validation | `quick_check=ok`; no foreign-key violations |
| Profiled cleanup | 262 SQL-only steps, 0.257 s cumulative; entire validation 2.522 s |

The historical causation report separately counts all 26,911 obsolete markers and their 258,362 exposed direct selections. This regression executes the root plus 256 other obsolete markers, not every marker. Synthetic tests exercise the complete authority/interruption lifecycle. Neither the sample nor the benchmark proves that all historical filesystem regions were unchanged.

### Tests, interruption and builds

| Validation | Result and evidence under `build/inventory-correction/` |
| --- | --- |
| Inventory suite | **114 PASS**, exit 0; `root-inventory-final.log` |
| Monitor suite | **192 PASS**, exit 0; `monitor-host.log` |
| Viewer suite | **273 PASS**, exit 0; `gui-host-tests.log`; notification linkage/read-only checks also pass |
| Backend build | PASS, `scripts/build.sh` |
| Viewer build | PASS using installed macOS 26.5 SDK, `gui-sdk26-build.log` |
| Snapshot regression | PASS; `verification.stdout.log`, stderr empty |
| Actual crash recovery | PASS; `crash-recovery.json`, `crash-probe.log` |
| Native progressive browsing | PASS on separate interrupted synthetic index; `native-qa-config.json`, `native-partial-largest-files.png` |
| Preservation | PASS; `preservation-final.json` |

Coverage includes obsolete tokens after newer listings, root protection, concurrent listing commit versus cleanup, repeated/interrupted cleanup, legitimate pruning/hard links/ancestor sums, unknown permissions, overlapping requests, fixed endpoints, manual refresh during indexing, later gaps, unavailable retries, delayed request-file receipt, events during enumeration, reader invalidation, selected-folder priority, and identity replacement while cleanup is pending. The pre-fix root regression failed by retaining zero of the 20 observed children; the corrected case retains all 20.

The real crash probe killed only its own isolated fixture process with SIGKILL after 290 committed entries and one enumerating job. A rollback journal remained. Resume preserved generation 1 and a sentinel history value, finished 3,002 nodes with exact 3,072,000 logical bytes, passed `integrity_check` and foreign keys, and took 3.363 s. This supplements cooperative cancellation tests.

Failures were investigated, not silently skipped. A worker-context monitor test failed its host swap-allocation check; rerunning the same build with host access passed all 192. The default installed macOS 27 SDK fails the SwiftUI build because its `StateMacro` plugin is absent; a minimal independent SwiftUI reproduction fails too. The existing macOS 26.5 SDK builds the same source successfully. Use:

```sh
STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-gui.sh
```

No SDK, permissions or system settings were installed or changed. A worker-context benchmark also failed its resource-limit pre-exec setup; the root host rerun completed all three trials with those limits enforced.

### Performance instrumentation and bounded measurements

Opt-in synchronous profiling records monotonic time for directory enumeration/open, metadata calls, SQL statements/exec, transaction commit, aggregates, cleanup, FSEvents reconciliation, lock acquisition, scheduling sleeps and retry/prefix replay. It records committed discovered names, remeasurements/pruning, listing attempts/completions/repeats, event/gap retries, satisfied skips and bounded throughput windows. Failed transaction counts do not masquerade as committed discoveries. Timers overlap: aggregate/cleanup work includes SQL. Do not sum the categories. No per-file paths or file contents are logged by profiling. A forced watchdog process exit cannot emit a final in-memory profile; its operational timeout evidence remains separate.

Hardware: Mac mini M4 Pro, 24 GiB; M2 Air/8 GiB unavailable. Benchmark: three fresh synthetic databases, warm accessible APFS temporary scope, background task policy, nice 15, 90 s CPU / 180 s wall limits. The active QA crawler remained running. Each initial pass was clean and separate from the deliberate partial-index test.

| Measurement | Latest three-trial result |
| --- | --- |
| Entries | 4,089 nodes: 86 directories, 4,002 regular-file names, one symlink |
| Initial elapsed | 1.037 / 1.264 / 1.437 s; median 1.264 s |
| Directory listings | 86 attempted and completed per trial; zero repeats/retries/unavailable |
| Discovered names | 4,088 excluding pre-created root; no remeasurements |
| Discovery throughput | 2,845–3,943 names/s; 60–83 directory completions/s |
| First browsable commit | 48–78 ms |
| Useful partial (1,000 committed names) | 181–441 ms |
| Peak process-reported RSS | 17,481,728 bytes (17.5 MB) |
| Peak sampled CPU | 67.0–79.3%; sampled across driver including partial/update work, not a precise initial-only peak |
| Database | 1,708,032 bytes; growth 1,654,784 bytes; DELETE journal, WAL zero |
| Real FSEvents incremental | Nine complete runs, median 0.702 s, range 0.601–0.784 s; one requested directory listing per run |
| Competing capacity-like writes | 90/90 insert/rollback probes passed; median 0.477 ms, maximum 219.274 ms |
| Independent metadata enumerator | 10.4–11.3 ms; matching node counts/logical/allocated totals |

The independent enumerator respects the same device, does not follow symlinks, and counts hard-link allocation once. It has no SQLite, aggregates, checkpoints, event replay or permissions gaps. Its timing isolates raw metadata traversal; it is not an equivalent inventory product or evidence of parity with Disk Inventory X. Synthetic totals include sparse-file and hard-link behavior; allocation still is not uniquely reclaimable APFS storage.

Median initial category times: enumeration 12.8 ms, metadata 27.1 ms, SQL statements 505.4 ms, SQL exec 317.7 ms, commit 179.8 ms, aggregates 41.5 ms, lock acquisition 78.7 ms, scheduling delays 351.2 ms. Fresh initialization has zero retry/prefix overhead and no event replay; incremental FSEvents replay accounts for most of those update runs. These measurements identify persistence and background scheduling as the remaining costs in this workload, not raw enumeration. Per trial there are 13,685 SQL reads, 21,223 writes and 111 commits; reducing per-entry SQL may warrant a later bounded experiment, but this pass does not speculatively rewrite it.

The one measured scheduling optimization checks for the unlocked fairness yield every 200 ms instead of every 50 ms. Requested sleeps remain short, transactions remain bounded and SQLite FULL durability is unchanged. Before trials were 1.84–1.99 s with 1.03–1.13 s of measured sleep; final trials above were faster, with all competing writers succeeding. Cache state and concurrent host load were not controlled, so this is evidence for the bottleneck and local change, not a universal speedup claim.

On a disposable clone of the corrected 2.89-million-node catalog, five-run query medians including process startup/JSON were 9.11 ms navigation, 13.47 ms largest directories, 15.37 ms largest files and 13.48 ms indexed prefix search. The first cold largest-item query was slower (about 85 ms). Evidence: `query-benchmark.json`.

### Progressive browser and scheduling

The distinct development app `Inventory Correction QA.app` was opened against a separate interrupted fixture: 1,001 indexed items, 67 queued listings, one coverage gap, Building. Folder navigation displayed its 50 observed files, breadcrumbs returned to root, indexed search advanced to page 2 of 100 results, and largest-files browsing showed available allocation without implying completion. The header now separates queued jobs and broad reconciliation from node-state counts. No UI redesign or visualization was introduced.

A selected-directory manual refresh uses the existing queue's head, and an active worker services immutable request files at existing batch boundaries. Regression tests verify that priority and live request consumption. Native background controls remain disabled in this isolated app because it has no installed worker; those controls were not manually exercised by installing a service. Read-only committed reader behavior during invalidation and concurrent writes is covered by integration tests.

### Preservation and remaining acceptance gaps

Final source-snapshot, installed backend/viewer and production LaunchAgent hashes match the pre-pass baseline. Production contains zero inventory tables. Seven original historical tables in the migrated evidence copy match the source row for row. Production may continue recording its own measurements normally; preservation does not mean freezing that live history. The active QA service was observed running and was never restarted, stopped, replaced or pointed at another database by this pass. No active QA database writes, production migrations, installation, commit, push or settings changes occurred. Only disposable synthetic fixture data was mutated/deleted.

A clean **bounded** benchmark harness is ready:

```sh
sh scripts/build-inventory-verification.sh
python3 scripts/benchmark-inventory-initial.py --files 4000 --directories 80 --trials 3 --output build/inventory-correction/benchmark.json
```

It deliberately does not offer an unrestricted full-volume mode. A future full-volume driver must use the instrumented pipeline with an isolated DB and enforced limits, only after the competing QA crawl ends and the user explicitly authorizes it. No second full-volume crawl was launched. Full-volume duration, final footprint, true peak CPU/RSS, repeated steady-state behavior, a controlled full monitoring-check comparison and M2/8 GiB performance remain unverified. Capacity-like SQL probes are not a full attribution-check benchmark. The old contaminated QA run cannot close those gaps.

### Final status

PASS means the scoped implementation behavior was exercised, not merely compiled. NOT VERIFIED means the broader acceptance evidence is still missing.

| Area | Status | Basis / remaining limit |
| --- | --- | --- |
| Cleanup correctness | PASS | Snapshot root/obsolete sample, legitimate pruning, concurrent and interruption regressions |
| Refresh correctness | PASS | Durable boundaries, satisfied skips, endpoints and later invalidation tests |
| Crash recovery | PASS | Actual SIGKILL, same-generation resume, integrity and exact totals |
| Event-gap recovery | PASS | Later-gap/identity transitions and interrupted reconciliation tests; full-volume gap performance unmeasured |
| Database migration | PASS | Additive disposable snapshot migration and rollback/retry tests |
| Historical data preservation | PASS | Seven tables equal; original evidence/production hashes unchanged; production unmigrated |
| Native browser | PASS | Actual partial navigation/search/pagination/largest files; uninstalled worker controls not manually exercised |
| Initial indexing performance | NOT VERIFIED | Bounded clean measurements pass; no clean full-volume benchmark |
| Incremental performance | NOT VERIFIED | Nine bounded real FSEvents updates pass; full-volume steady state not established |
| Production readiness | NOT VERIFIED | Not ready for installation; clean full-volume and steady-state acceptance required |

