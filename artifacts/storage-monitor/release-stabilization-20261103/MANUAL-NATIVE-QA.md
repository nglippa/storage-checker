# Manual native QA handoff

Branch `migration-readiness`, HEAD `6981c2da5ef1c4a1c528332eb0b1be1948721c39`, with uncommitted stabilization changes. Content fingerprint `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` binds 160 source, script, fixture and instruction files. Version remains **2.2.0 (10)**. This 160-file manifest covers the named compiler/test/tooling inputs, fixtures and root instructions/notices; historical151-file manifests had a narrower selection and are preserved separately. It is not a universal artifact checksum.

Completed same-Mac lifecycle/native cases are in [LOCAL-LIFECYCLE-RESULTS.md](LOCAL-LIFECYCLE-RESULTS.md). Previous desktop approvals are expired. Arm a source/image-pinned independent deadline guard and announce the exact QA window and end time before a fresh authorized pass. Do not modify production state to inject failures.

## Completed short app-only confirmation — disposable lifecycle runtime

- [x] Use final source-pinned Lifecycle QA assets and guard readiness receipt, not an old installed app. Enable through Settings; observe a real fixture reading and inventory generation.
- [x] Disabled monitoring with one naturally pending job and observed the refreshed status. No manual recheck request, synthetic queue or catalog edit was needed. Prior results remain browseable; Folder updates are waiting / Indexing is waiting replaces activity. No moving first-pass/manual indicator claims progress. Open Settings is reachable.
- [x] Re-enabled monitoring; actual test jobs and committed progress replaced waiting. A genuinely running indexer remains active while draining even if disabled for future starts.
- [ ] Completed/no-queue does not invent waiting. Low-space pause, missing event history and read/worker failures remain visible.
- [x] Disable, close only test apps and let the guard finish. Verify all exact test labels/processes absent, history retained, protected files/settings unchanged.

## Additional fixture cases

- [ ] Missing database, existing empty catalog, no readable root, requested initial work, worker failure and recovery each show an honest state/action, no perpetual absence spinner.
- [ ] Capacity first failure, retained-last-good, repeated failure, refreshing, stale threshold, clock transition and recovery; switch Storage/Monitoring. Never show failed/stale as current or fabricate zero.
- [ ] Monitoring exit 78, unknown/missing/disabled/partial job, exit-zero inventory failure, later committed recovery, stale/wake grace and unknown last-attempt time.
- [ ] Selected cleanup row beyond TTL remains Needs recheck. Stale Trash is blocked; successful/failed/uncertain rechecks, fresh protection, missing entry and identity change preserve context or invalidate authority appropriately.
- [ ] Separate strict Trash QA only: disposable conventional .venv, inspect confirmation and cancel first, then separately authorized Trash and own-entry restore. Record unchanged outside interpreter/sentinel. Lifecycle QA does not allow Trash.

## Interaction and accessibility

- [ ] Immediate/repeated Command-comma/restoration opens one intended Settings window. Earlier timed native evidence exists, but final build acceptance remains explicit.
- [ ] Tab/Shift-Tab, arrows, Return/Escape and zoom distinguish focus/selection and preserve Inspector synchronization; Navigator, filters, search and icon actions have useful order/names.
- [ ] Browse ranked files/folders, History & Monitoring, Focus/Isolation and Reset View versus Reset Filters & View remain understandable. Classic Living Tree remains available.
- [ ] Migration Readiness keeps logical requirements separate from allocated usage; sparse Inspector/reveal/filter agree. Physical capacity, inventory coverage and reclaimability remain qualified.
- [ ] Light/dark, increased contrast, larger text and compact window: labels/errors/long paths are readable and controls remain reachable. Selected 1000×694 and warning captures do not cover the full matrix.
- [ ] With separate temporary-setting authority, capture originals and perform each Reduce Motion/Increase Contrast check transactionally with restoration. VoiceOver needs real labels/order/status testing; source semantics are not compliance evidence.

## Separately scheduled system/hardware checks

Login/logout and sleep/wake disrupt the current account; do not run during an app-only grant. Notification/FDA prompts alter permissions and need specific component authority. Default startup-volume scanning is distinct from bounded fixtures. Real Intel/macOS 14 requires suitable hardware/system. Distribution security and release actions remain excluded.

Record source/executable hashes, OS/hardware, exact fixture, observation, result and teardown in new receipts. Do not overwrite or relabel previous evidence.

## Final source-pinned native preparation

Build-only preparation and read-only admission/guard validation passed with no compiler warnings. [Readiness and exact commands](evidence/local-lifecycle/final-neutral-freshness/NATIVE-FINAL-READY.json), [three build receipts](evidence/local-lifecycle/final-neutral-freshness/qa-build-results.json), [scope inspection](evidence/local-lifecycle/final-neutral-freshness/qa-scope-inspection-details.json), [guard validation](evidence/local-lifecycle/final-neutral-freshness/qa-guard-validation.json). All160 content inputs match the final source; the absolute compilation prefix deliberately pins the new runtime. No GUI launch or launchctl mutation occurred. The independent guard is validated but **not armed**.

Temporary window: **Storage Monitor — Lifecycle QA — Disposable Fixtures**. Runtime: `/private/tmp/storage-monitor-lifecycle-l0xllynj/source/build/lifecycle-qa/runtime`. Profile expires **2026-11-04T11:00:10.131371+00:00**; latest start for a ten-minute session is **2026-11-04T10:50:10.131371+00:00**. After that, use the existing preparer and regenerate path/hash-bound readiness/guard; never bypass the lease by editing its expiry. Prior grants remain expired.

## Current native confirmation — VERIFIED, 2026-11-04

The final source `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` and pinned viewer were exercised under the approved app-only grant. Actual Enable registered all three fixture jobs and committed a capacity reading plus a five-node fixture generation. Actual Disable removed all three jobs while retaining the reading and **one naturally pending job**. No synthetic queue or catalog edit was used. The main window showed **Folder updates are waiting**, preserved the browseable tree, exposed Open Settings and showed no first-pass/manual activity indicator. That link opened its own Settings; actual re-enable registered the jobs, advanced recorded readings from one to two, and the main summary became **Inventory is up to date**. Final Disable and independent guard teardown completed by **09:16:17 UTC**, before the 09:17:30 input cutoff / 09:20 hard end. Guard 6502 exited; exact apps/workers and all three jobs are absent, protected files match and no system settings changed.

[Session results](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/session-results.json) · [waiting capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/waiting-main.png) · [recovered capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/re-enabled-main.png) · [teardown](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/teardown.json). Current missing-database setup also reached actual Enable. Empty-catalog/no-generation and disabled-before-root variants, accessibility/system/Trash/hardware limits remain separate.

The initial artifact launch recipe omitted scope-specific temporary directories and was correctly refused before a window. The corrected direct-executable recipe sets only process-local `TMPDIR=<root>/Temporary/` and `SQLITE_TMPDIR=<root>/Temporary`; no admission rule or source changed. Refused-attempt logs are preserved. [Corrected readiness](evidence/local-lifecycle/final-neutral-freshness/NATIVE-FINAL-READY.json) records the recipe and the now-consumed single-use guard.
