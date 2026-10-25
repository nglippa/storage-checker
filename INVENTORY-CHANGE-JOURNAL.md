# Inventory change journal (Living Filesystem foundation)

Status, 2026-10-25: implemented and verified on isolated fixtures and APFS clones of a 2.96M-node catalog. Not installed. No production database, LaunchAgent or installed app was touched. The native viewer was not run in a window (see "Not verified").

The aim is a data foundation that lets a viewer refresh only the branches whose committed catalog state changed. The same foundation gives a future organic renderer durable growth and reduction signals. This pass builds no renderer, and Storage Atlas is unchanged visually.

## 1. How changes propagate today (audit)

- **Ingestion.** File events are replayed on each worker wake (`reconcileInventoryEvents`, `InventoryCommands.swift`). Each event becomes "relist the parent", plus a recursive gap for MustScanSubDirs. Event kinds (create, remove, rename, modify) are not distinguished. They land as `inventory_invalidations` rows next to the cursor acknowledgement, in one transaction.
- **Reconciliation.** `applyInventoryInvalidations` marks the folder `stale` and queues a job; no sizes change at that point. A relist (`persistInventoryBatchBody`) diffs the folder by `(parent, name)`:
  - **New names** are inserted.
  - **Same-object names** are updated: a file's totals are rewritten; a directory keeps its totals until its own listing.
  - **A directory found under a new parent or name** keeps its node id: an `UPDATE parent_id,name`, matched by device, inode and birth time.
  - **A file rename or move** becomes a new node, and the old node is pruned.
  - **Unseen names** become prune jobs, then tombstone claims, then leaf-up `DELETE`s, 256 per transaction.
- **Aggregates** are recomputed, not added as deltas. Each ancestor is re-summed from its direct children, once per commit (`coalescingAggregates`), in the same transaction.
- **Transactions.** Writes use the rollback journal with `synchronous=FULL` and `BEGIN IMMEDIATE`. There is a single writer (the worker), and node rows are written from 19 statements in seven code paths.
- **Viewer, before this change.**
  - It polled every 2 s while the worker was busy and every 30 s when idle.
  - Any change to `inventory_generations.updated_at` re-read **every expanded folder** at most every 5 s.
  - It dropped every collapsed folder's pages, and marked every nested Atlas region stale.
  - If a folder's re-read failed for any reason (a 100 ms busy timeout included), it could evict that folder.
  - Selection is by node id. A deleted selected row left a dangling id.
- **Gaps** relevant to incremental reads:
  - deleted rows leave no trace;
  - moves and size changes overwrite rows in place;
  - there was no viewer-visible commit sequence;
  - staleness is partly derived from other tables (`inventory_reconcile`, prune jobs, tombstones, pending invalidations).

| Change | Catalog today | Journal records |
|---|---|---|
| File created | invalidation → relist inserts node → ancestors re-summed | parent (insert), each ancestor (total changed) |
| File modified / grown / shrunk | relist rewrites file totals → ancestors re-summed | parent, ancestors; signal on file and ancestors |
| File deleted | prune → tombstone → leaf `DELETE` → ancestors re-summed | parent (delete), subtree marks while tombstoned, ancestors |
| File renamed | new node + old node pruned | parent (insert and delete) |
| Directory renamed / moved | `UPDATE parent_id,name`, id kept | old parent, new parent, the directory (listing + subtree) |
| Directory deleted | leaf-up deletes over many transactions | every emptied folder, the deleted directory itself, its parent |
| Directory size change | ancestor chain re-summed | every ancestor whose total changed |
| Gap / MustScanSubDirs | `inventory_reconcile` row, subtree marked stale | subtree mark on the reconcile root |
| Pending invalidations only | nothing yet (generation qualified stale) | nothing; `generationStale` flag on reads |

## 2. Design

### Chosen: trigger-maintained journal with a per-directory latest sequence

This combines evaluated options A and C.

- **One commit-ordered sequence.** A one-row clock (`inventory_change_clock`) holds the sequence, two retention floors, the signal generation and a random `journal_id`.
- **`inventory_changed_directories(directory_id PK, generation_id, sequence, subtree_sequence)`.** It holds one row per directory, upserted to the directory's latest change:
  - `sequence` is the latest change of any kind.
  - `subtree_sequence` is the latest change to state derived for everything beneath it.
- **SQLite triggers write it in the writer's own transaction.** They fire on `inventory_nodes` insert, delete and update; the update trigger fires only when a displayed column actually changed. They also fire on `inventory_objects` updates, and on `inventory_reconcile`, `inventory_prune_jobs` and `inventory_tombstones` inserts and deletes.
  - All 19 node write paths are covered without editing any of them.
  - A rollback removes the journal rows too (tested).
- **Generation-wide staleness is not journaled.** That covers pending invalidations and unavailable file events. It is returned as a flag on every read, and a viewer re-reads what it shows when the flag flips.
- **Size signals (`inventory_size_signals`)** are kept by the node update trigger, at most one row per node:
  - A *baseline* is captured when a settled value starts being remeasured. It does not change the row's sequence, so starting a remeasurement never re-publishes an earlier comparison.
  - A *comparison* is recorded when it settles again, or directly when one settled value replaces another.
  - "Settled" means status `complete` or `partial`, with a value.
  - Comparisons are recorded only for the generation whose first pass completed. The worker copies that generation id into the clock when it records completion, so the triggers depend on no other table's schema.

Why this is the smallest reliable option:

- **Atomic.** It writes in the same transaction as the catalog change, with no application code at the 19 write sites.
- **No duplicates, nothing missed.** Readers read the clock and the rows in one read transaction. Because rows are upserted to their latest sequence, a directory appears once per read. Paging continues strictly after a sequence, and a page never splits rows that share one.
- **Bounded.** There is at most one row per directory ever changed, and retention caps it below that.
- **Deletions and moves stay observable** after their rows disappear: the journal has no foreign keys to `inventory_nodes`.

### Rejected

- **B. Dirty-parent journal (a set of dirty ids, cleared by the reader).** It has a single consumer. It can't tell a reader that it fell behind, and clearing it races with writers.
- **C alone. Append-only journal of every change with affected ids.** Each commit re-sums a whole ancestor chain, so an append-only log grows with every commit, not with every directory. It needs separate compaction and gives no dedup per read.
- **A alone. A sequence column on `inventory_nodes`.** It rewrites hot pages of a 3M-row table for every ancestor, needs an index on that column, and loses the sequence when the row is deleted.
- **Application-level journal writes at each write site.** Every new write path would have to remember them. Triggers cannot be forgotten.

## 3. Schema and migration

The tables are new; no existing table or row is altered:

```
inventory_change_clock(id=1, journal_id TEXT, version, sequence, retained_after, signals_retained_after, created_at, signals_generation)
inventory_changed_directories(directory_id PK, generation_id, sequence, subtree_sequence) + index(sequence)
inventory_size_signals(node_id PK, generation_id, sequence, baseline_allocated/status/measured_at,
                       previous_allocated/status/measured_at, allocated, status, measured_at) + index(sequence)
```

There are 10 triggers, all named `inventory_change_*` (`Sources/InventoryChangeJournal.swift`):

- **`inventory_nodes`:** insert, delete, and one update trigger. The update trigger also maintains size signals.
- **`inventory_objects`:** update. A shared object's size, modified date or link count is shown on every name of the object, so each of its folders is journaled, hard-link aliases included.
- **`inventory_reconcile`, `inventory_prune_jobs`, `inventory_tombstones`:** insert and delete.

The node update trigger watches the displayed columns: `parent_id`, `name`, `object_id`, `kind`, `status`, `reason`, both totals, `child_count` and the three descendant counts. It fires only when one of them actually changed. `measured_at` is deliberately not watched: every re-sum refreshes it, and watching it would journal every ancestor on every commit.

`initializeInventorySchema` installs everything in one `BEGIN IMMEDIATE` transaction when the clock is missing, its `version` differs, or a trigger is missing. Triggers are dropped and recreated in that same transaction.

Migration safety:

- **No rewrite.** Migration creates tables, indexes and triggers only (tested: identical node count, byte and token sums; at most 12 new pages).
- **Readers start without a cursor.** A fresh journal makes them resynchronize once.
- **Retention.** A cursor older than `retained_after`, or one from another `journal_id` (a recreated database), returns `mustResynchronize`.
- **Old viewer, new catalog:** the old viewer ignores the tables.
- **New viewer, old catalog:** `available=false`, and the viewer falls back to re-reading what it shows.
- **Old worker binary on a migrated catalog:** the triggers keep working, because they live in the database.

**Retention.** The worker prunes the journal every 10 s (next to its progress sample) and at the end of each run:

- It keeps 65,536 directories and 65,536 signal rows, and starts pruning only above 125% of that.
- It deletes 16,384 rows per transaction.
- It raises the floor to the newest pruned sequence.

## 4. Read API (`InventoryReader`, read-only connection, existing 100 ms busy and 0.25 s deadlines)

- `changes(since:limit:) -> InventoryChangeBatch` returns:
  - `latestSequence`;
  - changed directories (id, sequence, subtree flag), each once;
  - `next` cursor;
  - `complete`;
  - `mustResynchronize`;
  - `generationStale`;
  - `available`.
  
  At most 4,096 rows per read, from one index range scan.
- `sizeSignals(since:limit:)` and `sizeSignals(nodeIDs:)` (up to 512 ids) return `InventorySizeSignal`. Each signal has:
  - previous and new allocated bytes;
  - a signed `deltaBytes`;
  - both measurement times;
  - a `trend` (growth, reduction or unchanged);
  - a `confidence`: `complete`, or `observedLowerBound` when either side is `partial`.

Raw file events never appear. A directory enters the feed only when the worker commits new catalog state for it, and an invalidation alone only raises `generationStale` (tested). Signals are differences in *indexed allocation*. They are documented as never meaning physical space consumed or reclaimed, because of APFS clones, shared extents, snapshots and purgeable space.

## 5. Viewer integration

`InventoryChangeTracker` (shared, pure) holds the cursor, the last generation-staleness flag and at most 512 folder ids to retry. It plans one of three things:

- **`none`.**
- **`folders(listing, subtrees)`:** only loaded folders that changed, plus loaded folders at or beneath a changed subtree.
- **`everything(reason)`:** used for no journal, a first read, history pruned past the cursor, a backlog beyond one read, or a flip in generation staleness.

The plan is committed only once it has been carried out, so a throttled plan loses nothing.

`InventoryExplorerController.inventoryChanged()` now:

1. **Reads** the feed, at most once a second. Full re-reads keep the old 5 s throttle.
2. **Drops** cached pages only for collapsed folders that changed. Unchanged collapsed folders reopen without a read.
3. **Re-reads** only the affected visible folders, each for the span it had loaded (`InventoryVisibleRefresh.perform`). It tells a deleted folder (a successful lookup that finds nothing) apart from a failed read (kept as shown, then retried). This fixes the old transient-failure eviction.
4. **Applies** the result in place: expansion and selection are kept by id, and the scroll anchor is stable because row ids do not change. A deleted selection moves to its nearest remaining folder. A deleted expanded folder is removed with everything beneath it.
5. **Marks** nested Atlas regions stale only when their folder, or their single-child chain, changed.

Pages that leave a reloaded span now release their cached node rows, so a busy folder's churn does not accumulate.

## 6. Verification

The tests run with `scripts/test-inventory.sh`. The 41 new checks are in `tests/InventoryChangeJournalTests.swift`. They use synthetic trees under `/private/tmp` and real worker runs; changes enter through the same invalidation path that file events use.

| Requirement | Test |
|---|---|
| File creation | Folder and every ancestor reported, no unrelated branch; growth equals the new file's allocation along the chain |
| File deletion | Folder reported after the row is gone; the file's signal is removed; reduction at the folder |
| File growth / shrinkage | Signed delta on the file and ancestors; previous value is the last settled measurement |
| Directory rename | Identity kept; parent listing plus subtree mark |
| Cross-directory move | Old and new parents; identity kept; growth at the destination, reduction at the source |
| Ancestor propagation | `est → er → deep → a → root` all reported |
| Multiple changes per transaction | All reported once each |
| Directory deletion | Directory itself and its parent reported; subtree rows gone |
| Atomicity | Sequence advances inside the transaction; rollback leaves no journal rows |
| Concurrent reader/writer | A reader polling every 2 ms during six worker runs: no duplicate, no regression, journal ⊆ observed |
| Retention overflow | Old cursor (changes and signals) must resynchronize; current cursor continues; tracker plans `everything` |
| Reconnect after missed updates | Pages of 8 rejoin to exactly the full set, no repeats |
| Protected / unmeasured | Access-restricted folder never gets a signal |
| Event is not a measurement | Invalidation alone: empty feed, `generationStale` only |
| Selection preservation | Change in another branch keeps selection and expansion |
| Unchanged branches avoid reload | Targets ⊆ feed; unchanged expanded branches are not read; no change means no read |
| Deleted selection / folder | Selection moves to the folder; deleted expanded folder removed with its subtree |
| Collapsed folders | Keep pages until their own branch changes |
| Migration | Pre-journal copy: `available=false` before; rows unchanged after; new journal id |
| Tracker rules | First read, backlog, staleness flip, bounded retries, sequence-safe truncation, signal sign and confidence |

New regression checks from an independent review (each confirmed to fail when its fix is reverted):

| Requirement | Test |
|---|---|
| Hard links | Re-listing unchanged hard links records no growth or reduction; a shared object's growth journals the alias's folder too |
| Remeasurement in progress | A started remeasurement keeps its baseline and does not re-publish its last comparison |
| Refresh during "Show more" | A folder whose span changed during a re-read is not overwritten; it is refreshed again |
| Page invalidation | Dropping a collapsed folder's pages releases their cached rows |

Results, 2026-10-25 (all on this Mac, isolated fixtures):

| Suite | Result |
|---|---|
| `scripts/test-inventory.sh` | **331 passed** (290 before this change + 41 new), 0 failed |
| `StorageMonitor self-test` (after `scripts/build.sh`) | 233 passed |
| `scripts/test-gui.sh` | 422 checks passed |
| `scripts/test-inventory-model.sh` (headless explorer re-reads, built viewer sources) | 18 passed, 0 failed |
| `scripts/build-gui.sh` (SDK 26.5) | built |
| Journal tests repeated | 6+ consecutive runs green; concurrency check ≈95 interleaved reads per run |

Two existing tests needed attention:

- **`statsTriggerMigrationTest`** counts every row SQLite changes during one status update, to prove the stats trigger's guard. It now drops the journal triggers in its own fixture first, because the journal's own row writes are verified separately.
- **The completion tests' legacy simulation** drops `initial_completion`. That forced the signal triggers to stop referencing the generations table. They read `signals_generation` from the journal clock instead, which the worker sets where it records first-pass completion.

## 7. Performance

`scripts/benchmark-change-journal.sh <catalog>` clones the catalog with `cp -c` into `/private/tmp`, runs `scripts/benchmark-change-journal.swift` and deletes the clones. The source was the preserved 2.96M-node, 440k-directory catalog. Ranges below cover the runs after the final changes. The machine was shared and one run was heavily contended, so single figures are indicative.

**Worker write cost.** These are real worker runs on a synthetic 50,211-entry tree, A/B alternated (journal off/on), with warm caches. That makes the write share far higher than a real crawl, which is dominated by filesystem I/O.

| Workload | Journal off | Journal on | Overhead |
|---|---|---|---|
| First pass (50,211 inserts) | 0.76–0.80 s | 0.91–1.04 s | +15–25% |
| Incremental round (5 folders: 15 rewrites, 25 creations, 25 deletions) | 30–34 ms | 35–37 ms | +12–17% (≈4–5 ms) |
| Large round (50 folders, each with one file grown) | 226–250 ms | 270–280 ms | +14–24% |
| Per-run schema check | 0.61 ms | 0.78 ms | +0.17 ms |

The same pass made the worker skip rewriting re-seen entries and objects whose values did not change. Before that, a 50-folder round took 340 ms without the journal; it now takes 270–280 ms *with* it.

**Large-catalog writes.** These are worker-shaped SQL workloads on the 3M clones, identical with and without the journal and alternated:

| Workload | Off | On | Overhead |
|---|---|---|---|
| Relist 2,000 folders (stale → five files grown → settle → ancestor chain re-summed), 32 per transaction | 3.78–3.91 s | 4.27–4.61 s | +12–18% |
| Insert 20,000 files, 2,048 per transaction | 1.36–1.40 s | 1.46–1.56 s | +8–13% |
| Delete 20,000 files leaf by leaf, 256 per transaction | 1.96–2.16 s | 2.42–2.53 s | +17–25% |

**Write amplification.**

- About 147k trigger events wrote 6,519 journal directories for the workloads above, because rows are upserted to their latest sequence.
- The first pass of 50k entries journaled 211 directories.
- Pages added for two rounds of those workloads: 2,348 with the journal against 2,008 without (+17%).
- Catalog file pages on the synthetic tree: +0.3%.

**Change-read latency** on the 3M catalog. The read deadline is 250 ms.

| Read | p50 | p95 | max |
|---|---|---|---|
| No change since cursor | 0.28 ms | 0.36 ms | 0.66 ms |
| After 10 folders relisted (≈79 changed directories) | 0.40 ms | 0.46 ms | 0.56 ms |
| Backlog page (2,048 directories, incomplete) | 0.67 ms | 0.69 ms | 0.73 ms |
| Size signals for 512 nodes | 0.59 ms | 0.67 ms | 0.73 ms |
| Signal feed page | 0.74 ms | 0.79 ms | 0.88 ms |

**Visible-branch refresh** on the 3M catalog. The explorer showed the root, its 12 largest folders and the largest folder inside each: 21 loaded visible folders. The test then ran 40 single-folder changes, half anywhere in the catalog and half inside a shown folder.

- **Folders re-read:** 116 instead of 840, so **724 reloads avoided (86%)**. There were no full-refresh plans.
- **A change inside a shown branch** re-read 2–3 folders (that folder, its parent and the root). A change elsewhere re-read only the shown ancestors whose totals changed.
- **Refresh time:** incremental p50 2.2 ms (p95 2.5 ms), against 15.6 ms for the previous behavior of re-reading every visible folder.

**Viewer memory.** After 600 polls with a change every 20 polls, the process footprint was 21,072 KB before and after (delta 0 KB). Cached rows stayed at 326 and the retry set at 0. The tracker holds a cursor and at most 512 ids; a feed read holds at most 4,096 ids transiently.

**Migration** of the 3M catalog took 1.1–1.6 s in total, including older lifecycle-column migrations this catalog also needed. The journal itself added 9 pages (36 KB).

**Database growth and retention.**

- **Before pruning:** 94,712 directories and 105,234 signal rows journaled after 90,000 folders flipped stale and back.
- **The prune:** 68,874 rows removed in 35 ms, leaving exactly 65,536 + 65,536. An old cursor then had to resynchronize.
- **Retained journal size:** about 7.3 MB on disk: directories 1.0 MB plus a 1.0 MB index; signals 4.3 MB plus a 0.9 MB index.
- **The whole clone** grew by 5.98 MB (1,474,424,832 − 1,468,448,768 bytes), which includes the 90k-folder workload.

## 8. Remaining risks

- **Write overhead.** It is about +12–25% on the worker's database write time, depending on the workload. The worst case is the first pass, where every insert journals its parent. A real first pass is dominated by filesystem reads, so wall-clock impact should be smaller. That is not measured on a full-volume first pass (no full-volume scans were run).
- **`measured_at` is not journaled.** A "measured at" time refreshes in the viewer only when another value of that folder changes, or on a full re-read.
- **Generation-wide staleness is a flag, not per-directory.** When pending invalidations appear or drain, the viewer re-reads every visible folder: bounded to visible folders, throttled to once per 5 s. This matches today's behavior for that case.
- **Retention.** Retention is 65,536 directories. After a volume-wide reconciliation (440k folders), a reader behind the floor resynchronizes, which re-reads its visible folders. That is correct, but the incremental benefit is lost for that one refresh.
- **Signal semantics.** Signals are indexed-allocation comparisons:
  - A hard-link owner reassignment moves allocation between folders.
  - A protected subfolder becoming readable raises its ancestors' observed allocation, marked `observedLowerBound`.
  
  Neither means disk space changed. The renderer must keep the confidence and wording rules: no "space reclaimed".
- **Node id reuse.** SQLite can reuse the largest rowid after its row is deleted. The viewer always re-reads the folder and node rows it refreshes, so a reused id shows its current row. Stale cursors do not depend on node ids.
- **The worker hot-path change.** The worker now skips rewriting unchanged re-seen entries and objects. Final row values are identical, and the 331 inventory tests cover these paths. Still, it changes the write pattern of the existing hot path.
- **The journal lives in the database.** Older viewers ignore it. If the clock row were deleted, readers report the journal unavailable and fall back to full visible refreshes, and the next worker start reinstalls it with a new journal id.
- **NOT VERIFIED in a real window:**
  - incremental refresh in the native viewer;
  - scroll stability;
  - nested Atlas redraw;
  - the inspector on a deleted selection.
  
  All were exercised only through the same state and refresh code in headless tests.

## 9. Recommended renderer architecture (next pass)

The renderer can be built on this foundation without changing the change-tracking architecture:

1. **A bounded crown model (shared, pure, testable like `InventoryExplorerState`).**
   - The tree shows a budget of branches (say 2,000–4,000), chosen largest-first from the root with `explorerSpan`.
   - Each folder's "rest" becomes one terminal *group* from `InventoryChildRemainder`, so small files are file groups, not thousands of twigs.
   - Branch identity is the node id. Thickness comes from indexed allocated bytes, compressed (√ or log) so the trunk does not swamp fine branches.
2. **Updates through the same feed.**
   - The crown keeps its own `InventoryChangeTracker`.
   - `folders(listing, subtrees)` re-reads only crown branches that changed; `everything`/`mustResynchronize` rebuilds the crown.
   - Deleted branches retract and moved branches re-attach, because ids are stable for moves.
3. **Light from signals, not events.**
   - The tracker polls `sizeSignals(since:)` with its own cursor; `sizeSignals(nodeIDs:)` seeds the crown on open.
   - Growth is amber, reduction cool blue, unchanged or no signal neutral white.
   - Intensity follows |delta| relative to the branch size and fades with `measuredAt` age.
   - `observedLowerBound` is dimmer, and stale or unknown branches are drawn neutral and thin.
   - No light without a comparison. A signal for a node outside the crown lights its nearest visible ancestor only if that ancestor has its own signal.
4. **Stable, incremental layout.**
   - Angles are allocated by cumulative allocated size with hysteresis, keyed by id, so a few-kilobyte change does not reflow the crown.
   - Only subtrees whose sizes changed past a threshold are re-laid out, off the main thread.
   - Layout output is immutable `CGPath` segments per branch.
5. **Drawing.**
   - One layer per major branch (top-level folder) with cached paths, or one Metal layer if the branch count demands it.
   - Charcoal ground; fine curved white strokes; colored light as a stroke tint plus a soft glow only on signaled branches.
   - Transitions animate only on change (about 0.8–1.2 s ease), with no idle animation. Respect Reduce Motion.
6. **Interaction.**
   - Hit testing through a quadtree rebuilt per layout.
   - Selection shares `InventoryExplorerState`, so the outline, Storage Atlas and the tree stay in sync.
7. **Bounds.** The crown budget, signals cached only for crown ids, one feed read per poll, and no per-event queue.

## Not verified

- **The native viewer in a real window.** Per AGENTS.md, no window was launched or focused. The controller path is covered by the headless model tests and by `InventoryVisibleRefresh` tests against real catalogs. Real-window behavior is NOT VERIFIED:
  - scroll position after an incremental refresh;
  - Atlas nested-region redraw;
  - inspector behavior on a deleted selection.
- **A live FSEvents stream driving the journal on the startup volume.** Fixtures inject invalidations, the path replayed events use. The live replay path itself is unchanged and is covered by the existing reconciliation scenarios.
- **The journal under the active QA worker.** That worker was not touched.
