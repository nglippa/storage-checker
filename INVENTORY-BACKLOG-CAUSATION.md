# QA inventory backlog causation

Investigation date: 2026-10-22. Scope: explain the existing QA run without restarting it, changing its implementation, or modifying production.

## Finding

The outstanding refresh pass is an agent-initiated **manual full-root refresh**, not evidence that hundreds of thousands of directories changed. It was requested during QA at **06:40:26 UTC** while initialization was still running. The implementation routes manual refresh through the same broad reconciliation mechanism used for an event-history gap, and that mechanism schedules every directory in its range, including directories with completed listings.

This is substantial repeat work created by refresh policy. It is not explained merely by an interrupted crawl. Interruption can justify resuming unfinished listings; it does not by itself justify relisting all completed directories.

There is also a confirmed cleanup correctness defect: obsolete prune markers survive newer successful listings. Under the current deletion code, these markers can select current inventory entries for deletion. This affects the QA catalog, not actual filesystem contents or historical monitoring tables.

## Preserved evidence

A consistent APFS copy-on-write database snapshot was taken at **20:33:40 UTC**:

- `build/inventory-verification/backlog-snapshot-20261022T203340Z.sqlite3`
- `build/inventory-verification/backlog-evidence-snapshot.json`
- `build/inventory-verification/backlog-causation-evidence.json`
- `build/inventory-verification/backlog-causation-extra.json`

The source database was opened read-only. A SQLite read transaction protected the rollback-journal database while cloning; the read-lock/clone/release interval was approximately **0.80 ms**. Snapshot `PRAGMA quick_check` returned `ok`. Heavy classification queries ran against the snapshot rather than holding locks on the active database. The worker was not restarted, paused, or reconfigured by this investigation. An earlier online-backup attempt did not converge against the active writer; `backlog-evidence-20261022T203141Z.sqlite3` is an incomplete artifact and is not used for these findings.

Counts below refer to this single snapshot, not the earlier 337,927-directory observation. The worker had continued making progress in the intervening time.

## Work breakdown

The snapshot contains **2,888,851 inventory entries**, generation 1 in `building` state.

| Work category | Count | What it does |
| --- | ---: | --- |
| Directories still beyond the refresh frontier | 313,351 | SQL discovers candidates, then schedules filesystem measurement |
| Of those, successful completed own listings already exist | 311,552 | Repeats filesystem enumeration; no change test is required for selection |
| Of those, last own listing ended unavailable | 1,799 | Retries metadata/access; may fail without enumeration or enumerate if accessible |
| Already queued directory jobs | 229 | All carry `manual refresh`; require filesystem work when processed |
| Queued event invalidations | 0 | No unprocessed event-invalidations at snapshot time |
| Cleanup markers with obsolete listing tokens | 26,911 | Database-only work, but their deletion selection is incorrect |
| Cleanup markers matching latest completed listing | 223 | Database-only discovery/pruning of entries absent from that listing |
| Already queued tombstones | 0 | No tombstone deletion queue at snapshot time |

Thus, **313,580 directory jobs remain represented by the manual refresh mechanism**, counting its unexpanded range and already queued jobs. These are separate from the 27,134 cleanup markers. A node-status counter of zero `pending` directories does not mean there are no pending jobs or unexpanded reconciliation candidates.

Cleanup does not invoke filesystem traversal or delete user files. It selects catalog rows, expands catalog descendant relationships, deletes inventory rows, repairs object ownership, and recomputes aggregates in bounded transactions. Database-only work still consumes I/O and CPU; one marker can represent a large subtree.

## Why the refresh became so large

1. A QA refresh request without explicit paths defaults to the inventory root (`Sources/InventoryCommands.swift:62-82`). This run's outstanding reconciliation record explicitly says `manual refresh`, created at 06:40:26 UTC.
2. `requestInventoryRefresh` submits an invalidation with `gap: true`, including for a manual request (`Sources/Inventory.swift:885-887`). This is broad-refresh policy, not proof that FSEvents lost history.
3. `expandInventoryReconcile` selects directories by generation and node-ID range, then overwrites their jobs to `pending`. It does not skip completed listings or compare their freshness with the request (`Sources/Inventory.swift:996-1025`).
4. The earlier implementation had no finite endpoint. A root refresh could therefore sweep directories newly discovered while it was progressing. The earlier fix added a finite horizon, but the already-running pass conservatively adopted the then-current maximum node ID, **2,638,771**, around 19:44 UTC. That preserves a very large repeat-work range accumulated during initialization.
5. At the snapshot the frontier was **380,422**, with that same endpoint. The remaining range contains the 313,351 directories above. Directories discovered beyond the endpoint are excluded from this pass.

The finite horizon prevents this pass from continually growing, but it does not remove repeat work already included in it.

## Genuine changes versus history gaps versus policy

**Confirmed current scheduling cause:** the surviving broad pass and all 229 active directory jobs are labeled `manual refresh`. There is no separate active reconcile record labeled as an event-history gap in this snapshot. Event identity is available and an acknowledgement cursor exists.

**Genuine changes:** some directories can certainly have changed during this long run. The database does not retain sufficient evidence to count that overlap accurately. Applied invalidations are deleted; job reasons are overwritten; reconciliation records are coalesced. Zero queued invalidations does not mean zero historical changes.

**History gaps:** actual gaps, invalid replay, and collector overflow can legitimately schedule broader reconciliation. Their historical contribution cannot be reconstructed precisely from the surviving state. The current manual record must not be presented as proof of a gap, nor can earlier gaps be ruled out from the absence of remaining records.

**Previously completed listings:** 311,552 remaining candidates have successful own-listing job records. They are repeat enumeration, but the exact unnecessary fraction cannot be established: there is no durable timestamp for the completion of each directory's own listing. Node `measured_at` changes during ancestor aggregation, and job `updated_at` can change when the parent rediscovers a completed child. Neither is a trustworthy own-listing completion timestamp.

Consequently, the evidence supports removing the assumption that the entire backlog is necessary. It does not support inventing an exact number of unchanged directories or safely dropping the entire backlog without a correctness plan.

## Cleanup defect

At successful listing completion, `persistInventoryBatchBody` creates or updates a prune marker only when it finds children with a different `seen_token` (`Sources/Inventory.swift:758-763`). When a newer listing observes every child, it does **not** clear an older marker.

Later, `processInventoryTombstones` selects children whose token differs from the saved marker and recursively removes their inventory records. It does not validate the marker against the latest completed parent listing before selection, or revalidate membership at final deletion (`Sources/Inventory.swift:1032-1088`).

Snapshot evidence:

- **26,911 of 27,134 markers** refer to an older listing than their parent's completed job.
- These obsolete markers would select **258,362 direct child records**. Every one of those records was seen in its parent's latest completed listing. These counts are direct rows, not a sum of disjoint recursive subtrees.
- The root itself has marker token **1**, latest completed listing token **4**, and **20 children**, all seen under token 4. Its obsolete marker would select all 20 current children, making the catalog beneath them vulnerable to recursive deletion.
- The other **223 markers** match their completed parent listing. They select **931 direct records** absent from that listing. Their deduplicated recursive closure contains **91,391 catalog records**: 18,433 directories, 58,896 files, 14,058 symbolic links, and 4 other entries. These are plausible pruning candidates, not proof of 91,391 physical deletions: moves and historical replacement evidence are not fully reconstructable.

Most cleanup markers therefore cannot be accepted as valid harmless housekeeping. Allowing this cleanup code to drain unchanged can corrupt the apparent inventory hierarchy even if filesystem enumeration finishes. No deletion was exercised against the snapshot or live QA database during this investigation; the selection was verified with read-only SQL and source inspection.

## What is and is not resolved

The backlog's current scheduling cause and filesystem/database distinction are established. The run and a consistent snapshot are preserved. Source code, production data, installed applications, and worker configuration were not changed.

The exact proportion of genuinely changed directories remains unmeasurable from the retained audit data. A complete initial-index duration or normal-user indexing estimate cannot be inferred from this QA run, which includes an overlapping full-root refresh and multiple implementation iterations.

Before further optimization or deployment, address stale prune-marker validation and define how refresh requests during initialization avoid indiscriminately relisting completed directories while retaining event correctness. Preserve the snapshot as the before-state regression fixture. These are next steps, not changes made in this investigation.
