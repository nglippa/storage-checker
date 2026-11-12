# APFS snapshot intelligence — implementation and validation

Date: 2026-11-11. Scope: the existing Storage Monitor monitor/viewer; no install,
production migration, LaunchAgent change, snapshot mutation or Time Machine change.

Snapshot lifecycle extension (2026-11-12): [APFS-SNAPSHOT-MANAGEMENT.md](APFS-SNAPSHOT-MANAGEMENT.md).
Its management engine/UI/native adapter are implemented but privileged lifecycle
success remains entitlement-gated and unverified. This earlier report describes
the read-only forensic scope; its statements that management was unimplemented
refer to that earlier stage.

Follow-up readiness review: [READINESS-REVIEW.md](artifacts/apfs-snapshot-acceptance/READINESS-REVIEW.md).
It records additional transaction/collection fixes, 52 integration fixtures,
real-history clone migration, a two-observation live round trip and authorized
native GUI acceptance results. The original
validation table below is the earlier implementation baseline. Native acceptance
and release remain separate. The authorized 3.0.0 distribution is recorded in `STORAGE-MONITOR-3.0.0-RELEASE.md`; native management remains gated.

## Existing implementation audit

The working tree was clean before this work. Repository AGENTS.md and CLAUDE.md
apply. Production apps/databases, the active QA worker and preserved snapshots
were left untouched. The initial audit was headless; later explicitly authorized
QA-window interaction is recorded in the follow-up review.

| Area | Before this change | Reuse / extension |
| --- | --- | --- |
| APFS enumeration/accounting | Implemented: `measure()` verifies startup container UUID/internal physical stores and parses complete `diskutil` plists; free/used and per-volume allocation are recorded. | Reused container readings and UUID matching; snapshot metadata is a separate evidence stream, never another allocation total. |
| Internal inventory | Implemented: resumable SQLite inventory, progressive discovery, change journal, bounds, reconciliation, logical/allocated file sizes and coverage states. | Preserved; no second filesystem index. |
| External volumes | Implemented: explicit enrollment, verified UUID/backing identity, mount leases, APFS shared capacity scopes, isolated inventory/catalog publication, offline sessions and reconnect baselines. | Reused enrollment/leases and one history per container. Only selected external volumes have snapshot inventories; startup VM counters are excluded. Device-number changes now reset external capacity sessions as well. |
| FSEvents | Implemented: device-relative markers, bounded replay, coalesced activity groups, gaps, changed-unit remeasurement and file metadata reconciliation. | Reused interval IDs, partial coverage and file-activity evidence. Snapshot identity changes coexist with file events without assigning them byte amounts. |
| SQLite/history | Implemented: readings, alerts, diagnostics, interval evidence and state; age/count retention; read-only viewer. | Additive `storage_observations` table keyed by reading ID and timestamp. Missing/corrupt evidence leaves capacity history readable. No historical observations are fabricated. |
| VM/swap | Partially implemented for ongoing attribution: sysctl swap allocation/usage and Mach VM counters existed in alert-triggered diagnostics. | Reused collectors at each scheduled startup reading when a VM-role volume is present, including recoveries and quiet checks. |
| Attribution | Implemented: per-volume APFS deltas, reconciliation, folder changes, process correlations and unknown remainder; file sizes already qualified for clones/snapshots/compression. | Added snapshot identity comparisons and four explicit signal classes. Corrected plain-language Data/VM summaries that previously implied file growth or swap alone explained allocation. |
| Full Disk Access | Implemented: protected-directory probe, consent-gated holes, inaccessible/deferred/excluded/stale states, path examples and coverage detail; graceful operation without FDA. | First-launch consent now explains inspected metadata, continued functionality, incomplete coverage and limits. Existing permission detail and inaccessible-area reporting remain. Probe results are indirect evidence, not an authoritative TCC authorization API. |
| Background work | Implemented: per-user supervisor, half-hourly/login capacity work, execution lock, bounded worker slices and wakeups. | Snapshot collection is observational work in the existing check; no new scheduler, daemon or launch label. |
| Native APFS snapshots | Missing in monitor history; existing uses of “snapshot” referred to diagnostics or immutable SQLite catalog copies. | New independent read-only APFS inventory, comparison, history and timeline evidence. |

Baseline passed: monitor build; 282 monitor self-tests; 63 coverage checks;
14 inventory self-tests; 1,161 GUI model/read-only tests. An initial sandboxed
self-test failed the sysctl swap check; the unrestricted baseline passed it.
Logs: `/private/tmp/storage-snapshot-baseline-*`.

## DeltaSnap investigation and decision

The actual vendor is ScaleNinja. Its public
[scaleninja/deltasnap repository](https://github.com/scaleninja/deltasnap) at
`c5742f1e61fcedc39742a4ca1ce1c5f959954bfb` contains plugin manifests, a README and an
agent skill requiring the separately installed helper/`dsnap` CLI. Its recursive
GitHub tree has no snapshot-manager implementation or LICENSE file.

The downloadable commercial product and helper are governed by the vendor's
[EULA](https://scaleninja.com/EULA.txt), updated October 10, 2026. It grants
personal/internal use and restricts redistribution, modification and reverse
engineering; it does not establish an embedding/reuse grant for Storage Monitor.
No manager source or license permitting incorporation was verified. No DeltaSnap
binary, helper, skill or code was copied, installed, executed or reverse engineered.
Integration would require a separately verified agreement/source license.

The vendor documents [snapshot comparisons](https://scaleninja.com/docs/deltasnap/compare-snapshots/)
using indexed metadata or direct scans of mounted states, with path changes and
qualified move detection. This implementation independently compares native
snapshot identities between observations using Apple's documented interfaces.
It neither replicates the proprietary engine nor promises snapshot file diffs.
The vendor's [storage documentation](https://scaleninja.com/docs/deltasnap/snapshot-storage/)
also distinguishes private and shared snapshot blocks; no per-snapshot size from
that product is available to this implementation.

## Supported-interface decision

- Disk Arbitration supplies disk descriptions and mount/media notifications;
  [Apple's guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ManipulatingDisks/ManipulatingDisks.html)
  documents this role. It is not used as a snapshot-listing API. The existing
  mount-discovery/lease system is retained rather than adding another monitor.
- `fs_snapshot_list` is in the public SDK and works like `getattrlistbulk`.
  The installed `fs_snapshot_create(2)` manual says snapshot functions require
  superuser privileges and an additional entitlement. No entitlement workaround,
  privileged helper or private APFS ioctl is introduced.
- The installed `diskutil(8)` manual documents `apfs listSnapshots -plist` and
  accepts the three-part device of a mounted boot snapshot. Inventory uses that
  interface with UUID/unlocked-state verification before and after each listing.
  Sealed boot snapshots are resolved to the verified parent System volume;
  unmounted volumes remain unavailable. No volume is mounted by this feature.
- Foundation ordinary, important-use and opportunistic-use capacity keys are
  separate observations, following Apple's
  [capacity guidance](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity).
  New URLs avoid reusing cached resource values.

## Behavior and measurement contract

Each ordinary startup check records capacity, then observes snapshot inventories
and system signals nearby. Explicitly enrolled external APFS scopes do the same
without global VM/swap signals. Internal UUIDs and external `apfs:<UUID>` scopes
retain their existing identity contracts.

Snapshot UUID, name, optional XID and purgeable **flag** come from complete plist
output. Per-snapshot creation time and exclusive bytes remain null/Unknown:
the verified command output on this Mac does not expose them. Snapshot XIDs and
names are not converted into dates, ages or sizes. A purgeable flag is not a
reclaimable byte measurement.

The runner has bounded capture, timeout, concurrent stream draining and child
reaping. Snapshot commands have a 2 s deadline within a 12 s collection budget
(termination grace can add time). Foundation capacity queries are synchronous
OS calls and have no separately enforceable deadline. Bounds: 32 volume outcomes,
512 KiB command output, 4,096 total snapshot records and less than 1 MB JSON per
observation. Over-limit/invalid reads are unavailable or skipped, never complete
partial inventories. The table follows reading age/count retention and a separate
32 MiB newest-evidence budget. Pruned evidence becomes a comparison gap.

Comparisons require adjacent recorded readings of the same container, a stable
capacity ceiling, observations within 120 s of their readings, no known session
boundary/reboot/uptime reversal and an interval of at most 75 minutes. Inventories
are compared only for the same UUID with complete, increasing-time endpoints.
Failed/missing/locked/disconnected volumes never imply snapshot deletion. New or
reconnected volume inventories form baselines. There is no additive recovery
calculation for snapshots, swap or file totals.

| Signal class | Meaning |
| --- | --- |
| Measured fact | Recorded capacity/volume allocation, a snapshot identity present at only one comparable endpoint, coalesced file activity, or a sysctl allocation change. |
| Strong correlation | A nearby swap-allocation delta agrees in direction and magnitude with VM-role APFS allocation (within 1 MiB or 5%). These can describe the same blocks. It does not identify the application. |
| Plausible explanation | Snapshot disappearance near recovery, or a change in an OS-update-prefixed snapshot name. These are qualified clues, not proven causes or assigned byte amounts. |
| Unknown cause | Exact physical cause, unmeasured/private snapshot bytes, unavailable inventory, incomplete intervals or unresolved capacity recovery. |

The existing timeline receives the evidence on its existing capacity event,
without duplicate events. “Snapshot Changes” filters comparable identity changes.
Search includes snapshot names and UUIDs. Details expose inventory outcomes,
measurement timestamps/sources, capacity types and VM counters. Copy exports
preserve this evidence. Legacy events explicitly state that snapshot/system
evidence was not recorded or could not be read.

Live headline capacity now means physical free blocks (`statfs.f_bfree`), with
macOS-reported availability shown separately. Recorded physical free remains
`diskutil.CapacityFree`; allocation is ceiling minus free. Ordinary available,
important-use and opportunistic-use values may differ and be rounded. Their
difference from free is not reported as exact purgeable storage. Logical file
length and filesystem-allocated file blocks remain in the existing inventory
with clone, sparse-file, compression and coverage qualifications. APFS siblings
share container capacity and are not summed as independent disks.

## Safety, limitations and remaining gaps

- No snapshot creation, deletion, retention, mounting, revert or Time Machine
  control exists. These advanced operations remain disabled/unimplemented. Any
  future management feature requires separate explicit authorization and
  privilege/entitlement evaluation. Current observation uses no sudo/admin helper.
- Listings and capacity reads are sequential, not atomic. Snapshot block release
  can be asynchronous. The UI describes nearby observations and retains unknown
  causes; it never reports “this snapshot freed X bytes.”
- Scheduled polling can miss snapshots created and removed between checks. A
  physical drive may disconnect, change elsewhere and reconnect between polls
  without a detectable identity change. Observed absence is still not proof of
  local deletion or of a capacity cause. Current lease checks detect changes
  during a read; existing offline-gap/backing/device sessions reset baselines.
- Snapshot private/cumulative sizes and exact reclaimable/purgeable bytes are not
  available through the chosen supported measurement interface. No numeric
  substitute is invented. No exact snapshot file-content diff is implemented.
- OS-update naming/volume roles are clues, not update-process provenance. APFS
  metadata, clone extents, delayed frees and open-but-deleted data can remain
  unresolved. Existing process correlation is still observational.
- External snapshot collection occurs only during the existing enrolled-drive
  capacity work. Periodic metadata access may wake a drive; physical HDD sleep
  effects have not been measured.
- FDA remains optional and cannot override all permissions, SIP or snapshot
  entitlement requirements. Inaccessible, excluded, stale and deferred coverage
  stays visible. A partial filesystem scan is not called complete.
- Authorized native GUI checks subsequently passed for the exercised search,
  filter, disclosure/copy, actual-history and light/dark minimum-window states.
  VoiceOver speech/announcements and runtime permission/first-launch dialogs
  remain **NOT VERIFIED**. See the follow-up review for exact scope. No browser
  verification applies to this native app.

## Validation record

New fixture suites cover appearances/disappearances, UUID casing, malformed and
duplicate metadata, retention safeguards, per-volume identity, skipped/failed
reads, permission failures, shared APFS accounting, growth/contraction,
concurrent files/snapshots, recovery without file evidence, session boundaries,
reboots, timeline filtering/search, exports, additive migration and legacy reads.
Destructive scenarios use synthetic inventories and disposable SQLite fixtures;
no real user snapshots are created or removed.

Real read-only verification found the existing boot snapshot and verified that
the unmounted Recovery volume was reported unavailable. Six volume outcomes,
five complete inventories, one existing snapshot and four Foundation capacity
observations were recorded. This validates actual metadata acquisition, not
destructive lifecycle operations or exact per-snapshot size measurement.

### Final review corrections

- Optional external snapshot/system evidence now has the same failure isolation
  as startup evidence. Invalid evidence or a failed evidence INSERT is logged;
  the capacity reading remains committed. Disposable fixtures reproduce the
  original rollback and exercise an SQLite trigger that rejects evidence writes.
- Decoding rejects inventory and Foundation capacity timestamps outside the
  parent observation's collection window. The round-trip fixture now uses an
  inventory timestamp inside that window; before/after-window cases are rejected.
- Timeline search includes names and UUIDs from comparable snapshot changes, so
  a disappeared snapshot remains searchable on its event. Empty searches return
  before constructing snapshot search text.
- The broad viewer fixture predates snapshot collection. Its new filter test
  verifies zero snapshot matches for legacy history and a positive match for an
  event with comparable snapshot identities, while preserving all existing
  event-filter assertions.

The timestamp-window, external-reading rollback and disappeared-name search
fixtures failed before their corresponding fixes and passed afterward.

### Final command results

All builds are development artifacts under `build/`. All database/filesystem
writes in tests are disposable fixtures. Live snapshot checks only read metadata.
Results below are from the final source on 2026-11-11; logs use the prefix
`/private/tmp/storage-snapshot-resume-`.

| Command | Actual result | Log suffix |
| --- | --- | --- |
| `scripts/build.sh` | PASS | `monitor-build.log` |
| Development monitor `self-test` (outside sandbox) | 282 passed | `monitor-final.log` |
| Development monitor `self-test --coverage` (outside sandbox) | 63 passed | `coverage-final.log` |
| Development monitor `self-test --inventory` (outside sandbox) | 14 passed | `inventory-self-final.log` |
| `scripts/test-snapshot-model.sh` | PASS, all eight model test groups | `model-final.log` |
| `scripts/test-snapshot-integration.sh --live` (outside sandbox) | 43 passed; six volume outcomes, five complete, one existing snapshot, four Foundation observations | `integration-final.log` |
| `scripts/test-gui.sh` | 1,163 model/read-only checks passed, plus both process/notification safeguards | `gui-final.log` |
| `scripts/test-external-runtime.sh` | 25 passed | `external-runtime.log` |
| `scripts/test-external-controls.sh` | 13 passed | `external-controls.log` |
| `scripts/build-gui.sh`, macOS 26.5 SDK | PASS | `viewer-build-final.log` |
| `scripts/test-inventory.sh` compilation; compiled `build/InventoryIntegrationTests` outside sandbox | 379 passed | `inventory-final.log` |
| `scripts/test-chart-geometry.sh`, macOS 26.5 SDK | 52 of 52 offscreen chart geometry and scroll routing checks passed | `chart.log` |

The sandbox blocked live `diskutil` and the existing swap-counter self-test.
Sandboxed coverage/inventory runs also failed their event-checkpoint assertions
(no carried initializer values / zero entries before interruption); the same
compiled monitor's unrestricted coverage and inventory self-tests passed, as
did the full compiled inventory suite outside the sandbox. The
unrestricted runs above, rather than the restricted failures, establish those
host-dependent results. No test expectation was weakened to accommodate sandbox
restrictions. The first broad viewer run exposed the legacy-filter fixture
assumption described above; its final run passed in full.

### Changed files

- Collection/persistence: `Sources/SnapshotObservation.swift` (new),
  `Sources/StorageMonitor.swift`, `Sources/ExternalVolumeMonitoring.swift`.
- Shared snapshot metadata, validation and comparisons:
  `SourcesShared/APFSSnapshotIntelligence.swift` (new).
- Viewer model/read-only history and explanations: `SourcesGUI/Models.swift`,
  `SourcesGUI/HistoryReader.swift`, `SourcesGUI/DiagnosticAnalysis.swift`,
  `SourcesGUI/EventPanelText.swift`.
- Native presentation and permission explanation: `SourcesGUI/EventDetailView.swift`,
  `SourcesGUI/LiveCapacity.swift`, `SourcesGUI/OverviewView.swift`,
  `SourcesGUI/InventoryView.swift`, `SourcesGUI/MonitoringSetup.swift`.
- Tests/scripts: new `tests/APFSSnapshotModelTests.swift`,
  `tests/APFSSnapshotIntegrationTests.swift`, `scripts/test-snapshot-model.sh`,
  `scripts/test-snapshot-integration.sh`; updated `tests/GUIModelTests.swift` and
  `tests/CapacityChartGeometryTests.swift`.
- Implementation/validation record: this document.

### Native acceptance follow-up

The authorized live GUI pass verified snapshot-name/UUID searches, Snapshot
Changes filtering, empty results/reset, detail disclosure and copied evidence,
light/dark minimum-window layout, and navigation through 902 actual events.
VoiceOver was enabled while accessibility labels and ordinary keyboard focus
were checked, then restored off. Spoken output/state announcements remain
**NOT VERIFIED**, as do runtime permission-denial/first-launch dialogs and a
physical SSD disconnect/reconnect. Full results and limits are in
[READINESS-REVIEW.md](artifacts/apfs-snapshot-acceptance/READINESS-REVIEW.md) and
`GUI-ACCEPTANCE.json` (local evidence).
No installed app, production database, LaunchAgent or preserved snapshot was
modified in that acceptance pass. Subsequent source/DMG publication is recorded separately in `STORAGE-MONITOR-3.0.0-RELEASE.md`.

Public evidence note: raw host-specific JSON, logs and independent-review metadata remain local and are not included in the public source commit. Aggregate 3.0.0 release checks are recorded in `artifacts/apfs-snapshot-management/RELEASE-3.0.0-VALIDATION.json`. Local paths in this report are redacted.
