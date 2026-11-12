# APFS snapshot acceptance review

Status: **Read-only acceptance evidence; remaining interactive gaps carried into the authorized 3.0.0 package.**

Later lifecycle-management work is recorded separately in
[Snapshot Management readiness](../apfs-snapshot-management/READINESS-REVIEW.md).
This document retains the earlier read-only acceptance evidence; it is not native
mutation or privileged-helper acceptance.

This follow-up evaluates the implementation report against actual source,
preserved test logs, a production-history clone and real read-only APFS evidence.
The independent report critique is saved in `INDEPENDENT-REPORT-REVIEW.json`.
That critique did not audit source; its recommendations were reviewed rather
than applied automatically.

## Confirmed defects and corrections

1. Catching an evidence INSERT error inside the required reading transaction was
   insufficient: SQLite can roll back the entire transaction. Required capacity
   and alert/session state now commit first; optional evidence uses a separate
   transaction which refuses to nest in a caller-owned transaction.
2. Optional evidence retention could still roll back a startup reading. Its
   cleanup and 32 MiB budget now run in the optional transaction; required
   capacity transactions exclude that cleanup. Failure and subsequent recovery
   are exercised with `RAISE(ROLLBACK)` fixtures.
3. Collection itself ran before the capacity commit. Startup collection now
   follows the required commit. External collection is a lazy callback invoked
   only after its capacity and required state are durable. This does not make
   synchronous Foundation calls cancellable, but a stalled probe can no longer
   prevent that capacity reading from being recorded.
4. The native event table retained an "Available" heading over physical-free
   values. It now says "Physical free".
5. An unavailable inventory displayed "0 snapshots" beside its unavailable
   status. It now says "Snapshot count unknown".
6. A secondary-change summary still described Data-volume allocation as files
   and apps growing/shrinking. It now describes Data-volume allocation.

The collection-order, cleanup-rollback and unknown-count fixtures failed before
their corresponding fixes. The earlier transaction-ending failure was reproduced
in a disposable SQLite fixture; Swift integration fixtures now cover both
startup and external persistence, ABORT/ROLLBACK, nesting refusal, byte-budget
cleanup and recovery.

## Current headless evidence

Latest readiness logs are under `/private/tmp/storage-apfs-acceptance-*.log`.
The initial implementation's separate `storage-snapshot-resume-*` logs remain
historical evidence rather than a claim that every suite was rerun after every
wording-only edit.

| Check | Actual result |
| --- | --- |
| Snapshot integration fixtures | 52 passed after the readiness corrections |
| Snapshot model suite | Passed |
| Rebuilt monitor self-tests | 282 passed |
| Rebuilt coverage self-tests | 63 passed |
| Rebuilt inventory self-tests | 14 passed |
| External capacity runtime | 25 passed |
| Inventory-browser model suite | 97 passed outside the sandbox |
| Development monitor and latest viewer builds | Passed |
| Development bundle validation | Both bundles passed strict codesign verification and Info.plist lint; no distribution-signing/notarization claim |
| Clone migration | All 23 existing tables retained identical row counts, typed-content SHA-256 fingerprints and schemas; only `storage_observations` added; `user_version` remained 0 |
| Baseline/current reader compatibility | The 2.4.2 reader from `307f31808e38cd1ab1b5b6e15014a090e5d86e49` and current reader returned identical capacity history and 902 events on the migrated clone |
| Real collector → persistence → viewer reader | Two actual observations persisted and decoded; continuity true; five volumes compared; zero identity changes |

The actual history had no snapshot-observation table before this test. It cannot
retrospectively establish historical snapshot changes. The source database was
opened read-only inside a SQLite shared read transaction while `cp -c` created
the disposable APFS clone; its journal mode was DELETE. No WAL-copy assumption
was made. Migration and fingerprinting ran only on that clone.

The live harness uses the production measurement, startup persistence, snapshot
collector and viewer reader functions. It does **not** execute the entire
scheduled `check()` path or establish launchd-context behavior. No snapshot was
created or removed. The missing Recovery inventory remains unavailable, with an
unknown count. Real snapshot appearance/disappearance remains fixture-tested.

`HEADLESS-ACCEPTANCE.json` records the migration and live results without copying
the user's individual capacity-history rows into the repository. The near-time
free-space comparison showed a 458,752-byte change over 2.90 seconds between
diskutil and statfs reads. Foundation ordinary, important and opportunistic
availability were separately recorded. This is observational agreement, not an
atomic equality guarantee; no purgeable-byte total was derived. Alert evaluation
continues to use the existing recorded diskutil capacity values and thresholds.

The restricted inventory-browser process trapped; the same compiled binary
passed all 97 checks unrestricted. Earlier restricted checkpoint failures also
passed unrestricted. A baseline A/B of those sandbox failures has not been run,
so their exact cause is not claimed proven.

## Native evidence and remaining acceptance

The user renewed authorization for GUI and VoiceOver testing. The latest rebuilt
development viewer was exercised using only disposable QA databases. Application
text entry used app-bound paste; setting the search field through AX alone did
not reliably commit its binding, so search results were rechecked using actual
text-entry events. No application source change was needed in this pass.

| Scenario | Actual result | Status |
| --- | --- | --- |
| Current snapshot UI | Two real observations show the boot snapshot, five comparable inventories and zero identity changes; Recovery says “Snapshot count unknown” | PASS |
| Filters/search | Snapshot Changes plus committed fixture-name or UUID search returns 1 of 16 events; unmatched text returns 0 of 16 and clears stale details; Clear Filters resets the controls | PASS |
| Details and copy | Synthetic identity appearance is explicitly synthetic; creation/private size remain unknown. Real evidence and raw output copy correctly (7,775 and 5,089 characters); no exact reclaimable attribution is invented | PASS |
| Layout | Light synthetic and dark live-evidence windows at 1000×640 content size were inspected; details scroll and table heading says Physical free | PASS for exercised states |
| Actual history | Last 30 Days loads 902 of 902 events; Down Arrow moves event selection and updates details. Legacy events state snapshot evidence was not recorded; secondary text says Data volume allocation grew | PASS |
| Accessibility labels and keyboard | With VoiceOver enabled, Cmd-F focuses the labeled search field, Tab reaches labeled Filters, Space opens the filter popover, and event arrows update selection. Evidence/disclosure/copy controls expose labels and states | PASS for AX and ordinary keyboard navigation |
| VoiceOver speech and announcements | Enabled state confirmed using NSWorkspace.isVoiceOverEnabled; global VoiceOver navigation commands attempted. Tools could not observe speech or the caption panel; CUA separately rejected VoiceOver Utility access. User confirmation was requested but not received during this pass | NOT VERIFIED; no claim of a complete VoiceOver audit |
| Permission transparency | Actual copied inventory reports 20,753 partial/unavailable folders and unknown protected sizes. Settings explains optional Full Disk Access and inaccessible locations; QA monitoring setup is disabled | PASS for explanations; runtime denial and first-launch consent NOT VERIFIED |
| Physical SSD disconnect/reconnect | User has no SSD available | NOT VERIFIED |

The separate result record is `GUI-ACCEPTANCE.json`. These are live native-app
checks, not headless or browser substitutes. Screenshot observations were made
through the desktop tools; screenshot files were not archived.

Disposable databases used:

- `<disposable-acceptance-directory>/actual-history.sqlite3`
- `<disposable-acceptance-directory>/synthetic-snapshot-changes.sqlite3`
- `<disposable-acceptance-directory>/live-readings-final.sqlite3`

VoiceOver was confirmed off at cleanup, restoring its pre-test state. The caption
panel shortcut was toggled a second time to undo the test toggle; its final
visual state could not be independently captured. The test-opened VoiceOver
Utility and all QA viewer instances were closed. No TCC grant, production helper
installation or LaunchAgent change was made. Actual runtime permission denial,
physical disconnect/reconnect, scheduled launchd behavior and real snapshot
creation/removal remain unverified. Keep privileged snapshot management unavailable in the authorized 3.0.0 distribution.

The earlier pass had one global text-entry focus loss to Terminal; later text
entry uses app-bound actions. That earlier pass is historical evidence only.

## DeltaSnap disposition

`DELTASNAP-PROVENANCE.json` records retrieval details and SHA-256 hashes. The
pinned complete repository tree is archived in `deltasnap-tree.json`; it contains
plugin metadata, README and skill files, with no snapshot-manager implementation
or license file. The vendor EULA archive is kept under the disposable acceptance
directory, outside app resources. No embedding/reuse grant was verified.

A word-boundary search for DeltaSnap/dsnap in `Sources`, `SourcesShared`,
`SourcesGUI` and `scripts` found no runtime integration or compatibility branding.
The added collector calls only the existing bounded runner for diskutil info and
listSnapshots, plus Foundation/sysctl/Mach observations. No vendor dependency,
helper, executable or snapshot-management command was added. This is a source and
dependency-surface check, not a legal certification or proof of all provenance.

## Commit and candidate disposition

The original acceptance pass did not commit, install or release. The user subsequently authorized the 3.0.0 source/DMG release with native management unavailable; see `STORAGE-MONITOR-3.0.0-RELEASE.md`. Stage only the reviewed
implementation, tests, scripts and acceptance records explicitly by path; review
the staged diff before the requested commit. An installable RC still needs its
packaging/signature checks and explicit notes carrying every remaining
NOT VERIFIED item. The development bundle build alone is not an RC release.

Public evidence note: raw host-specific JSON, logs and independent-review metadata remain local and are not included in the public source commit. Aggregate 3.0.0 release checks are recorded in `artifacts/apfs-snapshot-management/RELEASE-3.0.0-VALIDATION.json`. Local paths in this report are redacted.
