# Database lifecycle follow-up — review queue milestone

2026-10-26: documentation review only. `DATABASE-LIFECYCLE.md` was read; no production catalog, backup, retained scratch catalog or installed application storage was modified. Its size/private-allocation figures are historical measurements from that audit and were not remeasured in this milestone.

The recommendations remain applicable:

| Recommendation | Current conclusion and next evidence |
|---|---|
| Bounded migration-backup retention | Keep the existing one-file count bound. Consider an age/health-based expiry only in a separately authorized lifecycle change, after verified monitoring and inventory success and with documented rollback expectations. A clone's private cost can grow as the live catalog diverges. No backup was deleted here. |
| Exclusive APFS allocation display | Still useful: show indexed/allocated and exclusive/private storage separately where available. Clone-backed backups cannot be presented as fully additional physical usage. Private size remains a qualified estimate because snapshots and sharing affect recovery. No production allocation measurements were taken here. |
| Potentially redundant approximately 68 MB `inventory_nodes_parent` index | Still an evaluation candidate, not an approved removal. Compare every affected query's `EXPLAIN QUERY PLAN` and timing on disposable catalog clones, including child listing, counts, breadcrumbs, folder search and journal reads. Review Queue uses existing schema and bounded keyset discovery; it does not justify dropping an index. The prior 68 MB is not a new measurement. |
| Avoid unnecessary compaction | Still valid. The prior audit found a small freelist already handled by incremental vacuum. A full rewrite/`VACUUM` adds temporary storage and I/O without demonstrated value. No compaction was performed. |

These are **VERIFIED documentation/source-consistency conclusions**, with savings and current live allocation **UNVERIFIED in this pass**. They are follow-up recommendations, not implementation changes. Preserve the retained scratch catalog and backup until an explicit user decision authorizes otherwise.
