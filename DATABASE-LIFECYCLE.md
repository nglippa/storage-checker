# Storage Monitor's own storage — database lifecycle audit and recommendation

Status, 2026-10-26: measured, read-only. Nothing in the production data folder was modified, vacuumed, migrated or deleted. The live database was examined through an instant APFS clone (`cp -c`, taken while no `-journal`/`-wal` file existed; `PRAGMA quick_check` = ok), analysed in a scratch folder and then removed. Allocation figures come from `stat` and APFS private size (`ATTR_CMNEXT_PRIVATESIZE`, the bytes a file does not share with clones).

## 1. What is there (`~/Library/Application Support/MacBook Storage Monitor`)

| File | Size | Exclusively its own (APFS private size) |
|---|---|---|
| `history.sqlite3` (live) | 1,020 MB | 1,004 MB |
| `history.pre-update-2026-10-24T062919Z.sqlite3` | 993 MB | 54 MB |
| `monitor.log`, lock files, `inventory-requests/` | < 0.1 MB | — |

The ~2 GB a file listing suggests is not 2 GB of disk: the backup was created as an APFS clone. **On this Mac today** it shares 16 MB with the live database and about 939 MB with a database copy left in an earlier test session's scratch folder (`…/b17a3ced-…/scratchpad/post.sqlite3`, same timestamp, 54 MB private). Removing the backup alone would currently free about 54 MB. **On a normal installation without such a copy** the backup shares only what the live database has not rewritten since the update, and its exclusive cost grows toward its full size as the live database changes (here it would be about 977 MB).

## 2. What fills the live database (dbstat on the clone)

`page_size` 4,096 · `page_count` 249,126 (1,020 MB) · free pages 5,090 (21 MB) · `journal_mode=DELETE` · `auto_vacuum=INCREMENTAL`.

| Object | Size | Rows |
|---|---|---|
| `inventory_nodes` (table) | 184 MB | 1.97M |
| 11 indexes on `inventory_nodes` | 539 MB | — |
| `inventory_objects` (table + unique index) | 127 + 65 MB | 2.2M |
| `inventory_jobs` (table + 2 indexes) | 21 + 13 MB | 249k (one per folder; 81 pending) |
| Monitoring history (`readings`, `interval_evidence`, `coverage_units`, `diagnostics`, `state`) | ≈ 4 MB | 136 readings over 2.4 days |
| Free pages | 21 MB | — |

- **The inventory catalog is about 99% of the database.** Monitoring history is negligible.
- **Indexes dominate:** about 617 MB of index against 332 MB of table data. The 11 `inventory_nodes` indexes are 2.9× the table.
- **One inventory generation** is stored (no old generations accumulate). Job rows are per folder and are reused, not appended.
- **WAL plays no part** (`journal_mode=DELETE`; no `-wal` file).
- **Free space is small and already reclaimed:** the monitor runs `PRAGMA incremental_vacuum(256)` at each check (up to 1 MB per check); 21 MB is free now.

Size is therefore governed by the number of indexed entries (about 510 bytes per entry including indexes). Incremental indexing updates rows in place: the database grows with the filesystem, not with time.

## 3. Backup retention (code: `Sources/InstallTransaction.swift`, `commit`)

- A pre-update snapshot is taken (an APFS clone) before an update; if the update **did not change the schema** it is deleted at commit; if it **did**, it is kept as `history.pre-update-<timestamp>.sqlite3` and **every older one is removed** (self-test: "keeps exactly one pre-update snapshot").
- Retention is therefore **bounded to one file**, but **it never expires**: it stays until the next schema-changing update, and its exclusive cost grows as the live database diverges.
- Repeated migrations do not accumulate backups.

## 4. Index redundancy candidates (measured, not changed)

| Candidate | Size | Evidence | Status |
|---|---|---|---|
| `inventory_nodes_parent (generation_id, parent_id, name NOCASE)` | 68 MB | `inventory_nodes_children (parent_id, name NOCASE, id)` starts with the same lookup (a node id belongs to exactly one generation); the planner currently uses `inventory_nodes_parent` for ordered child listings and counts (EXPLAIN QUERY PLAN on the clone) | Candidate: confirm every query's plan and timing with it removed on a clone |
| UNIQUE `(generation_id, parent_id, name)` autoindex | 68 MB | enforces uniqueness (BINARY name); needed unless the constraint is redefined | Keep |
| `inventory_nodes_largest_all` | 35 MB | the file/folder partial indexes cover the kind-specific rankings | Candidate for "all entries" rankings only; measure first |

A related performance finding: `children(parentID:sort:.allocated)` (`InventoryReader`, `WHERE n.parent_id=? AND n.generation_id=? ORDER BY total_allocated`) is planned on `inventory_nodes_largest_all (generation_id=?)` — a scan of the whole generation by size until enough children are found — while the explorer's equivalent query uses `+n.generation_id` to stay on `inventory_nodes_children_allocated`. Worth checking where `children(sort: .allocated)` is still used.

## 5. Recommendations

1. **Expire the pre-update snapshot once the update has proven itself** (for example after 7 days and at least one successful monitoring check and inventory pass on the new version), and say so in the update notes. Expected saving on a typical installation: up to ~0.95 GB once the live database has diverged. Today on this Mac: ~54 MB (because a test copy shares the rest). Keep the current one-file bound.
2. **Report the backup honestly in the app:** Storage Monitor's own-data figure should show allocated *and* exclusive (private) sizes, so a clone-backed backup is not presented as 1 GB of extra disk.
3. **Evaluate removing `inventory_nodes_parent` (−68 MB, ~6.6%)** on a catalog clone: run EXPLAIN QUERY PLAN for every query touching `parent_id`, benchmark child listing, breadcrumbs, search-in-folder and change-journal reads, then decide. Do not change production schemas without that evidence.
4. **No compaction or VACUUM is warranted:** free pages are 2% and already trickle back through incremental vacuum; a full VACUUM would rewrite 1 GB for at most 21 MB.
5. **No history retention change is needed:** monitoring history is about 4 MB.
6. **Housekeeping on this Mac (user decision, not done):** the scratch copy `…/scratchpad/post.sqlite3` from an earlier test session is a 993 MB test artefact (54 MB exclusive while the backup exists). It is also the benchmark source used in this pass.

## 6. Verified vs assumed

- Verified: file sizes, private sizes, page and freelist counts, journal mode, auto-vacuum mode, per-object sizes, row counts, generation count, query plans for the listed queries (all on the clone), the retention code path and its self-test.
- Assumed (not measured): the growth of the backup's exclusive cost over time on other installations (it depends on how much of the database each inventory pass rewrites); the effect of removing an index on query timing.
