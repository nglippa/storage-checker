# APFS snapshot lifecycle management — implementation

Date: 2026-11-12. Status: **IMPLEMENTED, CAPABILITY-GATED; bundled in 3.0.0 with privileged mutations unavailable. The full native success criterion is not yet established.**

This extends the existing read-only APFS Snapshot Intelligence without replacing
its capacity history, evidence classes, timeline or permission disclosures. The
new lifecycle engine, native adapter, privileged-service boundary and GUI are
implemented. The development app deliberately cannot perform privileged snapshot
mutations. Successful native create/delete/mount and deployed background behavior
remain blocked on establishing an Apple-accepted snapshot entitlement and testing
a correctly provisioned helper. Do not describe this build as a validated full
snapshot manager.

## Platform decisions

The installed `fs_snapshot_create(2)` manual and the public SDK
`usr/include/sys/snapshot.h` describe creation, deletion and read-only mounting.
The manual describes root and additional entitlement requirements; public kernel
source distinguishes entitlement checks from root/device-write authorization.
Neither is the same as paid membership, Developer ID signing or notarization.
The follow-up [local capability investigation](APFS-LOCAL-CAPABILITY-INVESTIGATION.md)
records actual direct-call and AMFI results, source limitations and the pending
root-only probe. The installed
`diskutil apfs` supports listing and deleting snapshots, but exposes no general
creation verb. `tmutil localsnapshot` is not used: Time Machine does not provide
the requested per-volume ownership domain or arbitrary management policy.

The native adapter calls `fs_snapshot_create`, `fs_snapshot_delete` and
`fs_snapshot_mount` through a small C shim, and `unmount` for cleanup. Diskutil is
used only for bounded read-only APFS discovery, inventories and role/container
cross-checks. No private ioctl, unrestricted root shell, sudo, Time Machine
configuration, snapshot revert or vendor engine is used.

The helper checks `com.apple.developer.vfs.snapshot`. Its actual availability to
this product is unresolved; root or a self-assigned entitlement is insufficient.
No entitlement grant, provisioned identity or notarized mutation capability was
established during this work. Apple explains why restricted-entitlement daemons
need a profile-bearing app-like bundle in
[Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
and [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

The helper is packaged as `Storage Monitor Snapshot Service.app` with its own
Info.plist and executable. Development builds are ad-hoc signed without an
entitlement or profile. Distribution packaging accepts operator-supplied
`STORAGE_MONITOR_SNAPSHOT_PROFILE` and `STORAGE_MONITOR_SNAPSHOT_ENTITLEMENTS`
with a real signing identity; it does not manufacture Apple authorization. The
profile, kernel acceptance and daemon context still need acceptance testing.
The implementation handoff preceded release authorization. Subsequent 3.0.0 packaging and publication are recorded in `STORAGE-MONITOR-3.0.0-RELEASE.md`.

## Supported scope

| Volume/state | Lifecycle policy |
| --- | --- |
| Mounted, writable, roleless local APFS base volume | Implemented target, conditional on native privilege/entitlement checks |
| Disposable roleless APFS disk image | Used for actual discovery, identity/capacity and denied-operation tests |
| System, Data, Preboot, Recovery, VM, Update, Backup or any other role-bearing volume | Observation-only; no management mutations, including startup Data |
| Sealed/system snapshot mount, `/`, `/System/*` | Management refused |
| Locked, unmounted, disconnected, read-only, non-APFS or network filesystem | Management refused/skipped |
| Time Machine/system/other tools' snapshots | Not adopted or deleted; name-prefix similarity is never ownership |

Roleless case-sensitive/encrypted volumes are subject to the same checks, but
native lifecycle success on them is not verified. The GUI reports unsupported
volumes rather than pretending their snapshot counts are zero. Existing history
continues to support its prior observational scope.
Excluding role-bearing volumes, including startup Data, is a conservative product
policy; it does not establish that macOS forbids every third-party Data snapshot.

## Ownership and deletion safeguards

The daemon alone owns `/Library/Application Support/Storage Monitor Snapshots`.
Its `Ledger/ownership.json` is root-owned mode 0600 under a private directory. A
no-follow, exclusive process lock prevents overlapping service instances. Writes
use an exclusive temporary file, file fsync, atomic rename and directory fsync.
Unsafe ownership, type, hard links, permissions, schema, duplicate identities,
malformed leases or write failures stop management. The viewer cannot supply a
ledger path or edit ownership through ordinary preferences.

Each record persists the management-domain UUID, helper-generated operation UUID,
requesting UID, volume UUID, container UUID, native snapshot UUID, native name,
XID, label, creation request time, protection/exclusion flags and operation state.
Native names contain an unpredictable ownership identifier plus the user's
validated label (at most 80 UTF-8 bytes). Names are not parsed to invent dates or
ownership. Labels and native names remain separate from native UUID identity.

Creation commits a `creating` intent before the syscall. It becomes `managed`
only after a unique UUID/name/XID is read back on the same volume/container.
Deletion commits `deleting` before its syscall and confirms native absence before
success. Interrupted/uncertain operations become quarantined and are excluded
from retention. Fresh administrator-authorized recovery review checks the durable
intent and current exact identity; a recovered existing snapshot becomes
protected. Missing recovery states are finalized absent. Nothing is automatically
adopted because its name resembles Storage Monitor's prefix.

Manual deletion requires a server-produced preview, an explicit permanent-delete
confirmation and administrator authorization. The opaque one-use preview is
bound to effective UID, XPC session, exact records, ledger revision and a two-minute
expiry. Before each mutation the service resolves the current volume again,
re-lists and verifies UUID/name/XID, checks protection and active comparison
leases, and holds a no-follow volume-root descriptor. The C adapter verifies APFS,
volume UUID, snapshot capability, mount/device identity and writable state from
that descriptor, and rechecks current role/container metadata. Client paths and
BSD device numbers are never mutation authority.

The platform cannot make diskutil role inspection and the snapshot syscall one
atomic transaction. A concurrent privileged administrator remains a residual
race. Any observed identity disagreement fails closed. Externally renamed snapshots
are not silently re-adopted; name/identity mismatch can require separate repair
outside this version's supported workflow. Native deletion takes a
name because that is the public syscall interface; it is derived from a freshly
verified UUID tuple, never accepted as a client deletion selector.

## Privilege and scheduling model

The separately registered `SMAppService` LaunchDaemon exposes a fixed typed XPC
protocol, not a root command runner. Both endpoints pin Apple-anchored code to the
same signing Team and exact bundle identifiers; debug entitlement claims are
refused. The protocol is versioned and request sizes/counts are bounded. The
service captures effective UID from the connection. Mutation/configuration/mount
requests require exact custom administrator rights for create, delete, configure
or compare. The GUI preauthorizes and transfers a temporary external form; the
service rechecks without interaction/extension and destroys the rights. Tokens
are never persisted or logged. Existing administrator-customized rules are not
overwritten. Registration and volume-policy enabling are distinct explicit UI
steps. The current ad-hoc app cannot register a capable service.

The root service serializes requests, schedule ticks and cleanup. A launchd
RunAtLoad service with a 60-second timer evaluates persisted per-volume policies.
Crash restart is configured; permanent configuration exits are not endlessly
restarted. SIGTERM/SIGINT cleanup attempts to release comparison leases, leaving
failed cleanup durably recorded for the next start. It does not force-unmount.

Hourly, daily and weekly use elapsed intervals; custom intervals range from 15
minutes to one year. `nextDue` commits before an attempt. Sleep/missed periods
coalesce to one attempt rather than a backlog. Disconnected volumes are skipped,
and a saved policy can be disabled while offline. All policies default off.
Snapshot creation requires at least 16 MiB physical free space and fewer than
4096 active management records per volume. An optional physical-free threshold
pauses creation. Failed attempts and pressure skips are recorded.

Automatic retention is separately enabled by the user and runs after a scheduled
attempt, including a failed creation. Its only candidates are this user's verified
owned snapshots on this volume/container. It combines age and eligible oldest-first
count rules; protected snapshots, manual exclusions, unresolved comparison leases,
quarantined records and the newest recovery point are retained. These safeguards
may prevent reaching the count/age target. Pressure does not authorize extra
unbounded deletion. The GUI can preview retention independently of executing it.
The ledger retains up to 2000 recent activity entries and 2000 deleted tombstones;
active ownership is never discarded merely to meet a history budget.

## Comparisons and accounting

The helper can lease two verified owned snapshots of the same volume and mount
them read-only with noexec/nosuid/nodev/dontbrowse/nofollow flags. Mount directories
are fixed, root-owned and non-writable to users, with traversal ACLs only for the
requesting UID. The helper does not inspect or copy snapshot file contents. The
GUI scans as the logged-in user, holds roots open, and verifies read-only state
and stable root/filesystem identity. Lease release is session-bound; disconnect,
expiry, restart and graceful termination trigger non-forced cleanup attempts.
Leased snapshots cannot be deletion candidates.

Comparisons report added, removed, modified, metadata and unverified-presence
paths, including directories and symlink destination changes. They do not follow
symlinks or traverse other mounted filesystems. Scans are capped at 100,000 entries
per side and 30 seconds, with 16 MiB per-file and 256 MiB total content-hash limits
split between the two sides. Unreadable/over-budget contents remain unverified.
Incomplete scans do not emit definite additions/removals for one-sided entries.
Equal metadata without two hashes does not establish equal contents. ACLs, extended
attributes, resource forks, clone extents and every platform metadata field are
not comprehensively compared. Results can be searched and exported as JSON.
Native snapshot mounting itself is not yet verified; ordinary disposable-directory
comparison behavior is tested.

Exclusive/private/reclaimable snapshot bytes remain **Unknown**. Creation/deletion
activity captures nearby physical free-space readings when available and reports
their difference as a shared-container observation, never bytes guaranteed recovered
by a particular snapshot. Block release can be delayed and unrelated file activity
can overlap. File logical sizes and hashes are not physical APFS accounting.
The measurement source is statfs f_bfree × f_bsize; per-volume quotas can limit
that view of shared-container free space. Management activity has its own history; the existing forensic timeline remains
independent and read-only.

## Files changed for this extension

- `SourcesShared/SnapshotLifecycle.swift`: models, policies, ownership verification, retention.
- `SourcesShared/SnapshotLifecycleEngine.swift`: durable ledger, operation journal, previews, schedules, leases and recovery.
- `SourcesShared/SnapshotLifecycleComparison.swift`: bounded user-permission file comparisons.
- `SourcesShared/SnapshotLifecycleIPC.swift`, `SnapshotLifecycleSecurity.swift`, `SnapshotLifecyclePlatform.swift`: fixed protocol, authorization/signing and read-only discovery.
- `SourcesSnapshotService/SnapshotNative.h`, `SnapshotNative.c`, `SnapshotNativeBackend.swift`, `SnapshotServiceMain.swift`: native calls, privileged adapter and service.
- `SourcesGUI/SnapshotManagementModel.swift`, `SnapshotManagementView.swift`: native management UI and service client.
- `SourcesGUI/InventoryView.swift`, `StorageMonitorApp.swift`: dedicated Snapshots section and QA launch option.
- `Sources/SnapshotObservation.swift`: clarify that the historical collector remains read-only while management activity is separate.
- `scripts/build-snapshot-service.sh`, `build-gui.sh`, `build-dmg.sh`: helper compilation/bundling/signing support, without registration.
- `scripts/test-snapshot-management.sh`, `test-snapshot-native-disposable.sh`; `tests/SnapshotManagementTests.swift`, `SnapshotLifecycleEngineTests.swift`, `SnapshotNativeDisposableTests.swift`: behavioral and disposable-platform checks.
- This report and `artifacts/apfs-snapshot-management/READINESS-REVIEW.md`.

The pre-existing uncommitted APFS intelligence implementation and unrelated working
tree changes were preserved. The implementation phase did not register a helper or install the app. The separately authorized 3.0.0 source/DMG release is recorded in `STORAGE-MONITOR-3.0.0-RELEASE.md`; native capability gates remain unchanged. See the readiness report for actual results and outstanding gates.

Public evidence note: raw host-specific JSON, logs and independent-review metadata remain local and are not included in the public source commit. Aggregate 3.0.0 release checks are recorded in `artifacts/apfs-snapshot-management/RELEASE-3.0.0-VALIDATION.json`. Local paths in this report are redacted.
