# Inventory first-pass completion lifecycle

Status: implemented and verified in development (2026-10-23). **Production readiness is NOT VERIFIED.**

The inventory engine now records, in SQLite, the moment an inventory generation finishes its first pass. The viewer reads that fact. It no longer infers completion from what happens to be queued, and no longer keeps its own record. Before this change, a finished inventory could look like "first indexing" whenever later updates queued folders that had never been listed (new folders, for example).

## 1. Completion invariant

A generation's first pass is complete when all of these hold at once:

1. The generation is active and its root node has a directory job.
2. **No directory job is waiting for, or partway through, its first listing.** That means no job in `pending` or `enumerating` with `completed_token = 0`. This covers:
   - pending first listings;
   - running listings with committed checkpoints;
   - newly discovered descendants;
   - interrupted listings awaiting recovery;
   - listings left unfinished by a pause.
3. **No unapplied invalidation** (change notice) remains for the generation. This is a precondition for the moment of recording only, not a standing "empty work queue" requirement. Applying a notice can re-queue a folder that has never been listed, for example one that was previously unreadable, so notices recorded before the check are applied first. The worker drains them within the same run, and once the milestone is recorded, later notices are never consulted.
4. **No traversable directory node lacks the work that would list it.** No directory node is `pending`/`enumerating` without an unfinished job, and no directory outside `unknown`/`excluded`/`inaccessible` has no job at all.

`completed_token` is set only when a listing ends successfully, and it is never cleared afterwards. Unavailable directories (permission denied, blocked I/O, absent, privacy-gated) finish as `complete` jobs with a reason, and their nodes stay `unknown` or `excluded`. A path not traversed under the consent gate gets an `unknown` node and no job.

So the milestone means: **every accessible directory in scope has been listed at least once, and every other directory is explicitly recorded as unavailable or excluded.** It does not mean every location was readable. Full Disk Access is not required, and inaccessible folders remain visible as partial or unavailable (`unknown_directories`, node status and reason).

These do **not** block completion, and never reset it:

- reconciliation passes (`inventory_reconcile`);
- refresh relistings of already-listed folders (`completed_token > 0`);
- deferred cleanup (`inventory_prune_jobs`, `inventory_tombstones`);
- failed incremental listings;
- event-history gaps.

All of these act on folders already listed, or record changes made after their listing. Folders created after a listing are new directories, not missed first-pass ones. Once recorded, the milestone is never cleared within a generation.

An empty queue is not treated as completion: clause 4 and the per-job token test are checked too.

## 2. Persisted schema

This is an additive, forward-only change. It goes through the existing atomic `lifecycleColumns` migration.

| Object | Definition | Meaning |
|---|---|---|
| `inventory_generations.initial_completion` | `TEXT NOT NULL DEFAULT 'unknown'` | `pending`: new generation, first pass not finished. `complete`: recorded. `unknown`: the generation predates the milestone. |
| `inventory_generations.initial_completed_at` | `REAL` (Unix seconds) | When the milestone was first recorded. Never rewritten. |
| `inventory_jobs_first_listing` | partial index on `inventory_jobs(generation_id) WHERE completed_token=0 AND state IN ('pending','enumerating')` | Keeps clause 2 O(1) even behind a large refresh backlog. |

New generations are inserted with `'pending'`. Rows that existed before the migration get the column default, `'unknown'`, never `'pending'`.

## 3. Generation and scope semantics

- The milestone lives on the generation row. A generation is bound to its root path, root device/inode/birth time and volume UUID, so the record is tied to exactly that scope.
- **Scope change** (a different `--root` or region): `prepareInventoryRoot` supersedes the active generation (`active=0`, `state='superseded'`) and inserts a new one as `'pending'`. The old row keeps its own record.
- **New generation** (root identity replaced, or a volume change): same as above. The new generation starts `'pending'`.
- **Access changes within a generation** (for example Full Disk Access granted later) do not reset the record. Folders that stay inaccessible remain recorded as `unknown`/`excluded`.

## 4. Transaction boundaries and concurrency

`recordInitialInventoryCompletionIfReady` in `Sources/Inventory.swift` works in three steps:

1. Returns at once if the generation is already `'complete'` (idempotent).
2. Evaluates clauses 1–3 (indexed, cheap) and then clause 4 (a scan of directory nodes, 0.43 s on a 2.96M-entry catalog). This runs outside the writer lock. Only the worker that holds `inventory.lock` creates nodes and jobs, and it is the caller.
3. Inside a `BEGIN IMMEDIATE` transaction, re-checks clauses 1–3. It then runs `UPDATE … SET initial_completion='complete', initial_completed_at=? WHERE id=? AND active=1 AND initial_completion<>'complete'`.

A peer writer, such as request intake or event invalidation, cannot interleave between the re-check and the write. A crash or rollback before `COMMIT` leaves the generation `'pending'`.

The worker calls the check:

- once at run start (this is also the legacy confirmation step);
- at most every 30 s inside a long slice, until it is recorded;
- once after the final flush, before any terminal state is written.

No new service, timer or polling subsystem was added.

## 5. Legacy migration behavior

- The migration adds both columns in one transaction. A rollback or crash leaves neither, and rerunning is idempotent.
- Existing rows become `unknown`.
- Inventory records, jobs, listing tokens, reconciliation, cleanup authority, monitoring history and configuration are untouched.
- No job is reset, so the migration does not cause a crawl.
- After migration, the worker's normal run-start check evaluates the same invariant from durable state, with no filesystem listing:
  - **Confidently established:** no job awaits a first listing and clause 4 holds. The generation becomes `complete` without listing anything.
  - **Ambiguous:** a catalog from before `completed_token` existed gets `completed_token=0` on every job, so a queued refresh job cannot prove its folder was listed before. The generation stays `unknown`, never `pending`. It is confirmed only after the worker's normal processing lists those queued folders. Pending legacy work can only delay confirmation, never make it premature.
- The new code never runs against the active QA catalog. A viewer reading a catalog that has never been migrated (no column) reports **`unsupported`**.

## 6. Unknown-state handling

`InventoryReader.status().initialCompletion` has five values:

| Value | Source |
|---|---|
| `notStarted` | no generation |
| `inProgress` | `'pending'` |
| `complete` | `'complete'` (with `initialCompletedAt`) |
| `unknown` | `'unknown'` |
| `unsupported` | column absent |

`unknown` and `unsupported` are never shown as first indexing or as complete. They get a neutral note. Only `unknown` says it will be confirmed automatically, because an `unsupported` catalog's worker cannot confirm it.

## 7. Viewer state mapping

| State | Condition | Display |
|---|---|---|
| A. Never started | `notStarted` | Existing empty state ("No disk inventory yet", Start indexing). |
| B. First pass | `inProgress` | Indeterminate bar, "Building your storage inventory", elapsed time from `created_at`, items / folders completed / listings queued, guidance. |
| C. First pass paused | `inProgress` and `inventory.cancel` present | Static track, "Inventory building paused", same counts and guidance; VoiceOver value "Paused; saved results remain available". |
| D. Complete | `complete`, nothing queued | No panel; "Inventory is up to date" (or partial-coverage wording). |
| E. Incremental | `complete` with queued work, including never-listed new folders | No panel; "Updating changed folders". |
| F. Event-history recheck | reconcile pass whose reason is not `manual refresh` | No panel; "Rechecking after missed file events". A manual full refresh shows "Reconciling filesystem changes". The milestone is unchanged in both cases. |
| G. Legacy | `unknown` / `unsupported` | No panel; ordinary phase wording plus the neutral note. |

There is no percentage and no ETA anywhere.

Guidance copy:

- "Storage Monitor is discovering files and folders across your disk. Large inventories may take some time — a disk with millions of files can take hours — but you can explore results as they're discovered."
- "After this first pass, updates normally revisit only changed areas. Gaps in filesystem event history can require a broader check."

The previous round's per-viewer UserDefaults record was removed; its one leftover key in the QA preferences domain was deleted.

## 8. Regression evidence

| Suite | Result | Log |
|---|---|---|
| Inventory integration | **185 passed** (145 prior + 40 new milestone checks) | `build/completion-inventory-tests.log` |
| Monitor self-test | **192 passed** | `build/completion-monitor-tests.log` |
| Viewer model | **305 passed** (284 baseline + 21 initial-progress/lifecycle checks) | `build/completion-gui-tests.log` |
| Total | **682** | |

New engine checks (`tests/InventoryCompletionTests.swift`) cover:

- fresh database;
- pending, running and newly discovered first listings;
- pause;
- completion;
- inaccessible folder;
- deferred cleanup;
- unrelated incremental and reconciliation work;
- each invariant clause individually;
- 2,000 later folders at viewer launch;
- viewer and worker restarts, with `initial_completed_at` unchanged;
- manual full refresh;
- event-history gap;
- interrupted completion transaction;
- a concurrent writer holding uncommitted discovery;
- scope change;
- root replacement;
- legacy ambiguous, legacy confident (zero listings, identical tokens);
- migration interruption and recovery;
- integrity checks.

Viewer checks cover states A–G and the VoiceOver label/value strings.

A mutation run that disabled clause 2 failed the suite at its first in-progress assertion; the source was restored byte-for-byte.

Other evidence:

- **Crash recovery** (`build/inventory-completion/crash-recovery.json`): SIGKILL of the CLI worker during a first listing left `pending` with no timestamp, and the resume recorded `complete`. SIGKILL during a later 1,500-folder update kept the original timestamp. Final `integrity_check` ok, 0 foreign-key violations. The earlier progressive SIGKILL probe was rerun and passes (3,002 entries; `build/inventory-completion/progressive-crash-recovery.json`).
- **Real legacy formats**, on APFS clones only, with the originals never opened (`build/inventory-completion/legacy-migration.json`):
  - The pre-inventory monitor copy migrates to `not_started`.
  - The 2.89M-node backlog snapshot (no lifecycle columns) migrates to `unknown`: 229 queued jobs cannot prove a prior listing.
  - The 2.96M-entry previous QA catalog migrates to `unknown`, then the bounded check confirms `complete` in 0.43 s with no listing. Its 334 queued jobs are relistings (`completed_token > 0`).
  - All three keep record counts and listing tokens identical, pass `integrity_check`, and have 0 foreign-key violations.
- **Builds:** CLI (`build/completion-cli-build.log`) and viewer with the 26.5 SDK (`build/completion-gui-build.log`) succeed; the progressive verification harness compiles.

## 9. Native verification

Only partly done.

- With the separately identified dev viewer (`local.macbook.storage-monitor.viewer.initial-progress-dev`) at 780×620, against a fresh disposable catalog, the new empty-state copy rendered correctly (scenario: fresh installation).
- Native checks then **stopped**. Bringing the dev window forward captured keystrokes the user was typing in another application, and every launch of this app activates it.
- Scenario catalogs remain staged in the session scratchpad for a later run: fresh, a large update at launch (completion recorded, 388 listings queued with never-listed folders), legacy `unknown`, and legacy `unsupported`.
- The scenarios below are **verified only by model/reader tests on real worker-produced catalogs, not in the native app**: active, paused, completed, relaunch, incremental, large-update-at-launch, event recheck, and legacy.
- The previous round's native checks covered the panel layout at minimum width and its accessibility exposure. The view structure is unchanged, but its copy, and the conditions that show the panel, are new.

Remaining native checks for this lifecycle, all **NOT VERIFIED**, need the user's explicit permission under `AGENTS.md`:

- panel visible during an active first pass;
- static track while paused;
- panel gone after completion and after relaunch;
- "Updating changed folders" during a large later update at launch;
- "Rechecking after missed file events";
- legacy neutral notes;
- 780×620 wrapping and VoiceOver reading of each state.

After the audit fix, the suites stand at 189 inventory, 209 monitor and 314 viewer checks.

## 9a. Lifecycle audit (2026-10-23, later)

The invariant was re-audited against every place that creates, resets or finishes a directory job (`persistInventoryBatchBody`, `restartInventoryJob`, `finishUnavailableInventoryJob`, `applyInventoryInvalidations`, `expandInventoryReconcile`, the cleanup authority checks).

**Defect found and fixed.** When a folder was replaced at the same name by a different directory object (new inode and birth time), its job was reset to `pending` but kept the replaced object's `completed_token`. A first pass could therefore be recorded complete while that replacement's contents had never been listed. A brand-new folder at a different name correctly blocked completion, so the two cases were inconsistent.

- **Fix:** the replacement reset now also sets `completed_token=0`. This is safe for cleanup because every cleanup-authority check reads `completed_token` only on jobs in state `complete`, and the next completed listing sets a fresh token.
- **Regression test:** "a folder replaced by a new directory object needs its own first listing before completion is recorded". It fails with the fix removed and passes with it.

**Confirmed, no change needed:**

| Concern | Finding |
|---|---|
| Initial discovery vs incremental work | Only never-listed jobs (`completed_token=0`), change notices awaiting application at the moment of recording, and traversable folders without listing work block recording. Refresh relistings, reconciliation, cleanup and gaps do not. |
| Inaccessible folders | They finish as `complete` jobs with a reason and `unknown`/`excluded` nodes. Re-queuing one by a change notice before recording blocks until it is retried (new test). |
| Newly created folders | Before recording they are part of the pass and block it. After recording they are ordinary updates. |
| Interrupted jobs | `restartInventoryJob` keeps the token, so an interrupted first listing stays never-listed. |
| Premature recording | The check is re-verified inside the write transaction. SIGKILL and interrupted-transaction tests leave `pending`. |
| Generation and scope | The marker lives on the generation row; scope and root changes create a new `pending` generation. |
| Restarts, later updates, event gaps | Recording is a one-way `UPDATE … WHERE initial_completion<>'complete'`; nothing writes the column back. |
| Ambiguous legacy | `unknown` until conclusive. Entry counts are never consulted. |
| Concurrent workers | `inventory.lock` admits one worker per data directory, and the recheck runs under `BEGIN IMMEDIATE`. |

Note: the marker reflects observed state. Changes on disk that the catalog has not yet seen through events or relistings cannot block it, just as for any later change.

## 10. Remaining limitations

- The QA catalog's running worker predates the milestone, so a viewer reading it shows `unsupported`. The fresh QA run will not get a recorded milestone unless a milestone-aware worker later runs on it, which this task does not authorize.
- Ambiguous legacy catalogs stay `unknown` until their queued folders are relisted. A catalog whose old worker never runs again stays `unknown` (shown neutrally).
- After the first pass drains, recording can lag by up to 30 s inside a long slice. The panel keeps showing the first pass until then.
- Clause 4's node scan costs about 0.4 s on about 3M entries. It runs at most every 30 s, and only until recorded.
- "Rechecking after missed file events" also covers the event-overflow case (more than 4,096 paths), where events were coalesced rather than lost.
- Pause state is still read from `inventory.cancel`. A first pass whose worker is not running shows an animated bar, as before.

## 11. Production readiness implications

- The migration is additive, atomic and conservative, and verified on clones of two real large catalogs.
- Installing it would migrate the production catalog on the worker's next run. Whether that catalog confirms immediately or stays `unknown` depends on its queued jobs.
- Not verified: native interaction for the new states, a full-volume first pass recording its milestone end-to-end, smaller machines, and steady-state impact of the 30 s check during a multi-hour first pass.
- Nothing was installed, committed, pushed or deployed. The active QA worker, its supervisor, configuration and database, the preserved snapshots, production databases, apps and LaunchAgents were not modified.
