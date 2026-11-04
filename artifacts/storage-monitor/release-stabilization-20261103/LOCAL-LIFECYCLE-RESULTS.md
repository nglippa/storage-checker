# Same-Mac lifecycle QA results

Branch `migration-readiness`, HEAD `6981c2da5ef1c4a1c528332eb0b1be1948721c39`, with uncommitted stabilization changes. Content fingerprint `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` binds 160 source, script, fixture and instruction files. Version remains **2.2.0 (10)**. This 160-file manifest covers the named compiler/test/tooling inputs, fixtures and root instructions/notices; historical151-file manifests had a narrower selection and are preserved separately. It is not a universal artifact checksum.

## Implemented test boundary

Previously, actual Enable/Repair selected default startup-volume roots. A data-directory override alone could not safely test it on this working Mac. The new typed `SourcesShared/LifecycleQAScope.swift` admits explicit development-only `--lifecycle-qa-root` before production defaults. No environment-only unrestricted override exists. Distribution builds refuse admission.

The root must exactly match the disposable source's baked `/private/tmp/.../build/lifecycle-qa/runtime`. An expiring private profile pins session UUID, uid, device/inode and immutable Installer/V1/V2 hashes and roles. Canonical, owned operational paths reject symlink/hardlink/mount escapes. Fixtures are bounded. Expiry allows owned status/uninstall but no new work or recovery re-registration.

`Sources/LifecycleQACommands.swift` dispatches only scoped commands. `InstallTransaction.swift` carries the typed layout through the real transaction and validates journal/recovery destinations. `StorageMonitor.swift`, `InventoryCommands.swift`, `InventoryRequests.swift` and `Attribution.swift` carry exact fixture/data roots and scoped wake labels. Fixture checks suppress notifications, broad diagnostics and process sampling; status is read-only. Defaults for ordinary production operation remain unchanged.

`StorageMonitorApp.swift`, `MonitoringSetup.swift` and `InventoryView.swift` use the scope with existing Enable/Disable/Repair and health controls. QA uses separate bundle identities/preferences; the failed QA launch caused by a nil preferences suite was corrected and retested. Existing strict native Trash QA remains separate.

Tools: `scripts/prepare-lifecycle-qa.py`, `verify-lifecycle-qa.py`, `lifecycle-qa-guard.py`, `test-lifecycle-qa.sh`; negative cases are in `tests/LifecycleQATests.swift`.

## Real lifecycle evidence — VERIFIED for recorded source

[The real-run receipt](evidence/local-lifecycle/lifecycle-results.json) contains **39 passing assertions**: actual V1 RunAtLoad capacity reading, fixture-only inventory generation and baseline, distinct V1-to-V2 update, rollback before registration, rollback after a committed V2 worker reading, killed/reaped interrupted installer and journal recovery, repair, disable and retained history. This was real launchd/worker execution, not registration alone.

[The deadline probe](evidence/local-lifecycle/deadline-probe.json) let the independent guard's deadline fire with test jobs active. All three owned jobs/workers were removed. Protected installed app and LaunchAgent fingerprints matched before/after. macOS retained **three enabled-override bookkeeping rows** for the unique labels; they are not loaded jobs. Production override rows were not changed.

These actual lifecycle receipts belong to source `02b14c83f377deb1610472eb7b93c8c4ec1ca51ba4efb7900def2c4a6c488349`. The later preferences and disabled-queue presentation fixes do not retroactively change those receipts. Current automated scope/model/build results use the final fingerprint in REGRESSION-RESULTS. [The exact CLI-input comparison](evidence/local-lifecycle/final-neutral-freshness/retained-live-cli-inputs.json) proves all CLI source inputs unchanged except InventoryPresentation.swift; no Sources caller uses either changed presentation type. The exact presentation delta is retained alongside it. No previous result is silently relabelled current. The final two neutral captions remove subsidiary claims of an active recheck and add two semantic assertions; they do not change accounting or worker behavior.

## Native Settings — VERIFIED for recorded source

[Session cases](evidence/local-lifecycle/native-session-2/session-cases.json) observed real Enable/consent, Repair restoring only its test inventory job/plist, health reflecting actual readings, Disable removing all jobs with six readings retained, Settings scrolling and a usable 1000×694 window. Forward Tab reached Search; complete reverse order was not tested.

[Teardown](evidence/local-lifecycle/native-session-2/teardown.json) confirms all three labels absent, no owned process, protected files unchanged and no system-setting changes. This continuation launched no windows after the grant expired.

Native testing exposed queued work still labelled Updating after Disable. The current fix passes **20 new model regressions**: reliable off/disabled becomes waiting, unknown remains unknown, a currently running indexer remains active, completed/no-queue stays complete, errors and low-space/event-history qualifications survive, no-root and no-generation initial waiting stops its spinner. Counts/queue/results are retained. UI suppresses first-pass/manual progress and provides Open Settings. Its final native waiting/re-enable sequence is **VERIFIED** in the current source-pinned confirmation below.

## Remaining limits

Private plists were explicitly bootstrapped; real login persistence is NOT VERIFIED. Sleep/wake schedule behavior, actual notification/FDA prompts and delivery, default full startup-volume collection and downloaded/quarantined-helper behavior remain distinct checks. Fixture omissions cannot prove them. Physical Intel/macOS 14 needs a suitable system; this 8-GiB Apple silicon Mac cannot establish it. Distribution security remains excluded.

The waiting model adds constant-time presentation work and no process, timer, scan or disk write. It uses existing status refreshes (about 30 seconds plus explicit/activation refresh). The last sample may remain displayed until refresh. Existing app/Settings clocks are separate; each status request uses two read-only launchctl probes plus bounded worker-log tails. Full energy/peak-memory benchmarks remain pending.

## Final source-pinned native preparation

Build-only preparation and read-only admission/guard validation passed with no compiler warnings. [Readiness and exact commands](evidence/local-lifecycle/final-neutral-freshness/NATIVE-FINAL-READY.json), [three build receipts](evidence/local-lifecycle/final-neutral-freshness/qa-build-results.json), [scope inspection](evidence/local-lifecycle/final-neutral-freshness/qa-scope-inspection-details.json), [guard validation](evidence/local-lifecycle/final-neutral-freshness/qa-guard-validation.json). All160 content inputs match the final source; the absolute compilation prefix deliberately pins the new runtime. No GUI launch or launchctl mutation occurred. The independent guard is validated but **not armed**.

Temporary window: **Storage Monitor — Lifecycle QA — Disposable Fixtures**. Runtime: `/private/tmp/storage-monitor-lifecycle-l0xllynj/source/build/lifecycle-qa/runtime`. Profile expires **2026-11-04T11:00:10.131371+00:00**; latest start for a ten-minute session is **2026-11-04T10:50:10.131371+00:00**. After that, use the existing preparer and regenerate path/hash-bound readiness/guard; never bypass the lease by editing its expiry. Prior grants remain expired.

## Current native confirmation — VERIFIED, 2026-11-04

The final source `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` and pinned viewer were exercised under the approved app-only grant. Actual Enable registered all three fixture jobs and committed a capacity reading plus a five-node fixture generation. Actual Disable removed all three jobs while retaining the reading and **one naturally pending job**. No synthetic queue or catalog edit was used. The main window showed **Folder updates are waiting**, preserved the browseable tree, exposed Open Settings and showed no first-pass/manual activity indicator. That link opened its own Settings; actual re-enable registered the jobs, advanced recorded readings from one to two, and the main summary became **Inventory is up to date**. Final Disable and independent guard teardown completed by **09:16:17 UTC**, before the 09:17:30 input cutoff / 09:20 hard end. Guard 6502 exited; exact apps/workers and all three jobs are absent, protected files match and no system settings changed.

[Session results](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/session-results.json) · [waiting capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/waiting-main.png) · [recovered capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/re-enabled-main.png) · [teardown](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/teardown.json). Current missing-database setup also reached actual Enable. Empty-catalog/no-generation and disabled-before-root variants, accessibility/system/Trash/hardware limits remain separate.

The initial artifact launch recipe omitted scope-specific temporary directories and was correctly refused before a window. The corrected direct-executable recipe sets only process-local `TMPDIR=<root>/Temporary/` and `SQLITE_TMPDIR=<root>/Temporary`; no admission rule or source changed. Refused-attempt logs are preserved. [Corrected readiness](evidence/local-lifecycle/final-neutral-freshness/NATIVE-FINAL-READY.json) records the recipe and the now-consumed single-use guard.
