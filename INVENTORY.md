# Disk Inventory foundation

## Architecture decision — before implementation (2026-10-22)

The installed comprehensive monitor is the production baseline. Inventory work is developed and verified against isolated databases; this phase does not authorize installation or production migration.

`coverage_units` is a partition of disjoint aggregate measurement areas, not a full filesystem catalog. A `tree` unit can contain thousands of unrecorded directories and files; a `split` unit stores its own file totals and links to child areas. It cannot supply immediate children, file search, or largest-file queries. Its inode and aggregate values must not be invented into file records or expanded proportionally.

Reuse the startup Data volume identity, firmlink canonicalization (`CoverageRegion`, `dataRelative`, `displayPath`), consent gate, filesystem/device and cloud-placeholder boundaries, `lstat` allocation semantics (`st_blocks * 512`), observational I/O policy, and existing device-relative FSEvents replay. Do not change the attribution engine's measurement meaning or notification behavior.

Inventory requires a streaming metadata extension: persist actual directory entries and their parent relationships. Enumerate one directory in bounded batches, without recursively opening children in the same batch. This is necessary because the existing FTS aggregate walker discards entry records, checkpoints coarse areas, and can materialize sibling lists. Share the filesystem metadata/safety layer with comprehensive traversal; avoid a separate independent recursive scanner or resident event watcher. Initial inventory enrichment necessarily reads metadata absent from coverage records once. Ordinary updates enumerate only affected directories, using the existing event replay contract.

Additive inventory tables live in the existing SQLite database. Separate inventory connections use a short busy timeout and transactions limited to metadata batches; filesystem I/O occurs outside write transactions. Never acquire the monitor's attribution/check locks for inventory traversal. Scheduled checks save APFS capacity first, hand off bounded invalidation information, and do not run inventory indexing inline. A one-shot background inventory worker resumes persistent jobs; viewer launch never initiates a crawl.

Keep namespace entries distinct from filesystem objects: canonical volume-relative paths prevent firmlink duplicates, and volume/device/inode/birth metadata supplies stable identity. Hard-link names remain navigable, but only one canonical link contributes bytes globally. Symlinks are recorded and never followed. Directory totals sum direct counted content and disjoint child aggregates; incomplete descendants propagate uncertainty, and known lower bounds are labeled. Allocated sizes are file allocation, not uniquely reclaimable APFS physical storage; clones, compression, snapshots, shared extents, and open-but-deleted files preclude physical reconciliation.

Persistent generation and directory jobs support cancellation, bounded resumable enumeration, stale states, deletion and move reconciliation. Interrupted listings cannot prune unseen children or be labeled complete. Event gaps invalidate affected inventory and enqueue bounded reconciliation; the existing FSEvents history is replayed with a separately acknowledged consumer cursor only when necessary to avoid losing events during an interrupted inventory update. No second continuous event stream is introduced.

The viewer reads paginated snapshots off the main actor. Its new Disk Inventory section offers children, breadcrumbs, largest directories/files, indexed search, explicit coverage states, and an explicit background refresh request. Existing history UI stays intact. Query DTOs expose stable identity, parent, counts, qualified aggregates, measurement/generation data, and pagination independently of SwiftUI or future tree rendering. Historical growth is optional and unavailable unless trustworthy evidence can be associated; no renderer is implemented.

## Verification plan

Use synthetic filesystem fixtures and real SQLite for hierarchy, accounting, hard links, symlinks, firmlinks, mutation/moves, interruption/resume, permission gaps, stale history, pagination/search, large directories, and competing writers. Run existing monitor/viewer suites. Rehearse migration on a verified read-only production backup copy, preserving all existing tables. Measure a real Data-volume inventory in a separate private QA directory, monitor impact, and native QA browser behavior. Report actual counts, duration, peak memory, database growth and query/update latency, distinguishing implementation from behavior verified on this Mac mini; the M2 Air is unavailable.

## Implemented components

| File | Responsibility |
| --- | --- |
| `Sources/Inventory.swift` | Additive schema, persistent directory jobs, bounded metadata batches, identity and hard-link accounting, aggregates, invalidations, reconciliation and deferred pruning. |
| `Sources/InventoryCommands.swift` | Explicit initialization/update/query commands, existing FSEvents replay, independent consumer acknowledgement, request consumption, background LaunchAgent definition and pre-migration backup guard. |
| `SourcesShared/InventoryMetadata.swift` | Shared `lstat`/`fstatat` metadata and `st_blocks * 512` allocation semantics. |
| `SourcesShared/InventoryModels.swift` | Rendering-independent, read-only actor query API and qualified node/page/status DTOs. |
| `SourcesShared/InventoryRequests.swift` | Private immutable UUID request files; persistent pause/resume intent. |
| `SourcesGUI/InventoryView.swift` | Native paginated table, navigation, breadcrumbs, search, largest items, measurement details and background requests. |
| `SourcesGUI/StorageMonitorApp.swift` | Separate Monitoring / Disk Inventory navigation and isolated QA configuration. |
| `Sources/Coverage.swift` | Shared allocation helper and optional callback on the existing event replay. |
| `Sources/StorageMonitor.swift` | Inventory commands and installer support; wake inventory only after an existing scheduled check has recorded its results. |
| `scripts/build.sh`, `scripts/build-gui.sh` | Include the shared inventory sources in both binaries. |
| `tests/InventoryTests.swift`, `tests/InventoryIntegrationTests.swift`, `scripts/test-inventory.sh` | Synthetic fixtures, independent accounting oracle, migrations, interruption, permissions, identity, stale history and concurrent writes. |
| `scripts/benchmark-inventory.py` | Read-only status/count/query benchmark against an explicitly selected database. |

No luminous-tree renderer, attribution rewrite, notification behavior change, periodic full-disk timer, or production installation is part of this change.

## Persistence and accounting

The worker adds ten `inventory_*` tables: `generations`, `objects`, `nodes`, `stats`, `jobs`, `invalidations`, `reconcile`, `event_cursor`, `tombstones`, and `prune_jobs`. Existing monitor tables and historical records are retained. Schema setup uses the repository's idempotent creation convention, with introspected additive columns for earlier development databases; it does not replace the monitor schema or global version metadata.

Parent/name relationships and an absolute generation root define paths. Moves preserve directory and descendant IDs without updating every descendant path. Volume UUID plus inode and birth time form the public stable identity where available; a device-based fallback is explicit. Filesystem-object rows retain actual metadata independently of namespace entries' contributions to aggregates. Hard-link aliases therefore expose actual object sizes while contributing zero duplicate bytes. Largest-item ranking uses counted allocation. Direct sizes cover immediate non-directory content; aggregates omit directory-inode overhead and count each observed non-directory object once. Descendant file counts follow the same ownership rule; child counts include every indexed name.

Unreadable regions keep unknown totals. Partial sums describe observed logical content and reported file allocation. They are **not** lower bounds on uniquely occupied APFS blocks. Clones/shared extents can make summed allocation exceed unique physical usage; sparse/compressed files can have logical size above allocation. Snapshots, filesystem metadata, purgeable storage and open-but-deleted files also prevent reconciliation with container capacity. No adjustment is fabricated.

Metadata enumeration uses one live directory handle, at most 256 entries per batch, and filesystem I/O outside transactions. Committed listing tokens and directory identity/change timestamps survive interruption. A reopened unfinished directory replays committed names instead of reusing invalid POSIX directory cookies. Cancellation is checked during replay. Replay time is charged separately from new-work time so a large committed prefix cannot exhaust every retry budget without making progress.

Inventory also reuses the coverage walk watchdog. A filesystem batch with no enumeration progress for 60 seconds (plus up to five seconds of watchdog sampling) is recorded as an unknown `blocked` region through a separate database connection; the process exits for background resumption. Productive prefix replay refreshes this inactivity deadline. This bounds otherwise uninterruptible directory opens without holding a database writer transaction. Manual refresh can retry the region. Failure to persist the marker is logged before exit; such a failure may require another retry.

Transactions yield an unlocked interval to competing monitoring writes. Completed small sibling listings without directory relocations can share a commit: at most four listings and 256 total entries, with a 100 ms flush target checked between reads and directory snapshot revalidation before the write lock. Large/unfinished listings keep their existing per-batch commits, and all filesystem I/O remains outside transactions. Counters advance only after a successful commit; failed commits leave durable jobs resumable. Large deletions use a persistent frontier and bounded leaf batches rather than a cascading subtree delete. Removed descendants and ancestor totals remain stale until pruning finishes. Root replacement creates a new active generation; readers hide superseded nodes. Superseded generations are retained, so repeated manual root replacement can grow the database; automatic generation compaction is outside this phase.

## Incremental execution

The worker replays the existing device-relative FSEvents implementation and history. Its separately acknowledged cursor is necessary because a monitor check cannot certify inventory work that has not committed. Acknowledgement and invalidation are committed together. Committed invalidations are visible as stale before a worker applies them. Directory creation/deletion/rename/movement, file/allocation changes and missing history enqueue affected listings or bounded subtree reconciliation. Bounded invalidation pages are serviced between directory jobs even during initialization, so the initial queue cannot starve file events. The moved-directory lookup explicitly uses the selective object index; relying on SQLite’s default plan caused catalog-size-dependent scans in real verification. A newer gap restarts an existing reconciliation frontier so already visited directories cannot be certified against an older gap boundary.

Unavailable event identity queues one reconciliation, then reaches a terminal stale state instead of repeatedly crawling. Recovery schedules one reconciliation and restores ordinary replay. Final replay persists changes arriving during a pass before the worker goes idle. Filesystem activity can prevent a stable complete snapshot on a busy volume; this remains visible as pending/stale work.

`inventory-work` is a one-shot job. LaunchAgent retries continue durable unfinished work; successful idle jobs stop. Refresh requests wake the worker through `WatchPaths`, and an existing scheduled monitor check can wake it after saving its readings. The viewer only queries SQLite and writes operational request files. It does not scan on launch and adds no polling loop. The LaunchAgent definition uses background process type, low-priority I/O and nice 15. No production LaunchAgent was installed during development.

## Query and visualization contract

`InventoryReader` exposes `root()`, `node(id:)`, `children(parentID:offset:limit:sort:)`, `largest(kind:under:offset:limit:)`, `search(text:under:offset:limit:)`, `breadcrumbs(id:)` and `status()`. Pages are capped at 256 entries; the browser requests 100. Queries run off the main actor with a 250 ms SQLite execution deadline and a short busy timeout. Large subtree largest-item queries walk the size index and test ancestry; smaller subtrees use direct recursive selection. Very broad or deep paginated searches can reach the deadline and return an explicit error for retry rather than freeze the UI.

Nodes carry stable object identity, namespace ID, parent, absolute path, kind, counted and actual object sizes, direct/descendant counts, generation, modification/measurement times, coverage and reasons. Historical growth is currently `nil`; coverage-area history is not projected into individual files. This API can supply a future tree without a database dependency on SwiftUI or a rendering engine.

Search is case-insensitive name-prefix or absolute-path-prefix search, as labeled in the browser. Search and largest-item results open their folder or enclosing folder. File data is observed metadata, not a filesystem-wide atomic snapshot. When stale, byte totals are withheld by the public reader; unrelated current branches remain usable when only a sibling's aggregate is stale.

## Developer operations

Use the explicit new build while production remains installed: `bin/storage-monitor` prefers the installed binary.

```sh
scripts/build.sh
scripts/build-gui.sh
scripts/test-inventory.sh
scripts/test-gui.sh

# Read-only queries of the existing isolated QA catalog:
'build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor' inventory-status \
  --data-dir /Users/nicholaslippa/storage-checker/build/inventory-verification/data

python3 scripts/benchmark-inventory.py \
  --data-dir /Users/nicholaslippa/storage-checker/build/inventory-verification/data
```

The same binary supports `inventory-children`, `inventory-largest files|directories|all`, `inventory-search prefix`, `inventory-request [--path /absolute/path]`, `inventory-cancel` and `inventory-resume`. Query options include `--limit`, `--offset` and `--under node-id`. Explicit worker commands are `inventory-initialize`, `inventory-update` and `inventory-work`, with `--budget` and `--batch`. A scoped `--root` is allowed only with isolated data and must also be passed to later scoped updates.

Pause retains committed entries. Resume needs the worker to run: the QA LaunchAgent is separate from production. Do not run the installer or any inventory mutation against the production directory without authorization. The production migration path verifies a SQLite backup before the first inventory schema change; development used a separately verified backup copy.

See `INVENTORY-VERIFICATION.md` for measured behavior, evidence paths, limitations and acceptance status.

Reconciliation passes persist an `end_node_id` endpoint so an older refresh cannot chase newly discovered catalog entries. New gaps reset both endpoint and frontier. Commit fairness uses a monotonic cadence checked after transactions; it avoids a coalesced background sleep after every tiny commit. Counter triggers skip unchanged kind/status updates and upgrade atomically without changing existing counter values.
