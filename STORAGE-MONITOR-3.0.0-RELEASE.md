# Storage Monitor 3.0.0 (build 22)

Date: 2026-11-12. Production source branch: `master`. Universal macOS 14+ DMG.
This is an ad-hoc signed release, not Developer ID signed or notarized.

## Included

- Read-only APFS snapshot inventories attached to recorded capacity history,
  identity comparisons, Snapshot Changes filtering and name/UUID search.
- Measured, correlated, plausible and unknown evidence kept distinct. Missing
  inventory is never treated as proof that a snapshot disappeared.
- Physical-free capacity distinguished from macOS availability estimates;
  unavailable snapshot counts and application attribution remain unknown.
- Required capacity history commits before optional snapshot evidence collection
  or persistence. Optional evidence failure/retention cannot roll back readings.
- A dedicated Snapshots interface and lifecycle engine with persistent ownership,
  protected/excluded snapshots, scheduling/retention policies, one-use deletion
  previews, recovery journaling, bounded comparisons and export.

## Capability available in this release

**Privileged snapshot creation, deletion, mounting and automatic lifecycle policies
are unavailable in the shipped ad-hoc build.** The new service has no accepted
snapshot entitlement or provisioning profile and cannot be enabled by this build.
User/root access alone does not establish the required Apple capability. This
release must not be described as a validated full snapshot manager.

Native lifecycle targets are limited to mounted writable roleless local APFS
volumes. System/startup Data and other role-bearing volumes remain observation-only.
Foreign, Time Machine and system snapshots are not adopted or deleted. No vendor
snapshot engine was incorporated. Exact exclusive/reclaimable snapshot bytes and
complete arbitrary snapshot file-content comparisons are not promised.

The separately bundled snapshot service uses a fixed authenticated XPC protocol,
per-action administrator rights and an ownership ledger. Packaging does not
register it, install authorization rules or change any Time Machine policy.
Historical monitoring remains independent of that service.

## Artifact

- `Storage-Monitor-3.0.0.dmg`: 19702333 bytes.
- SHA-256: `28fb30bc7da431404a1261addcbb6951f075d772e393183b6371d6d7d7e8d268`.
- Viewer, monitor and snapshot-service bundles: version 3.0.0, build 22; each arm64 + x86_64.

## Validation

Final results: 40 DMG checks passed, including 282 bundled monitor self-tests from the read-only image; 1163 viewer/model checks, 52 snapshot integration checks, snapshot model tests and lifecycle/ownership/comparison tests passed.

The final results, artifact size/checksum and build command are recorded in
[`RELEASE-3.0.0-VALIDATION.json`](artifacts/apfs-snapshot-management/RELEASE-3.0.0-VALIDATION.json).
The packaging verifier inspects all three universal executables, version/build
metadata, system-only libraries, deployment targets, nested signatures and daemon
configuration. It mounts the DMG read-only without Finder and runs the bundled
monitor's isolated self-tests. It never launches or registers the snapshot service;
an unsupported CLI probe verifies rejection before service initialization.

Implementation checks include persistent ownership and corruption rejection,
protection, retention, missed schedules/pressure/offline behavior, interrupted
operations, stale identifiers, ordinary-directory comparisons and export, and
permission-denied tests on disposable APFS images. Native successful create/delete/
mount and deployed launchd behavior are not established by fixture-backed tests.

The real development GUI was checked using synthetic read-only QA data in light
and dark appearances at minimum size. Creation/policy forms, search, selection,
keyboard controls and labels were exercised. VoiceOver was enabled for label and
ordinary keyboard checks and restored off; spoken output/announcements remain
unverified. The public reports omit raw host history and private review metadata.

## Remaining acceptance

- Apple entitlement/provisioning approval, valid/invalid XPC peers and actual
  administrator authorization against an installed capable helper.
- Successful native lifecycle and read-only mounting on disposable APFS volumes,
  including native partial failures and interruption recovery.
- Real scheduling across sleep/restart, physical external SSD removal/reconnect,
  and spoken VoiceOver announcements.
- Intel execution, Developer ID distribution/notarization, and a real 3.0.0 upgrade
  of an installed background monitor. Automated upgrade tests use isolated homes.

No installed app, production database, LaunchAgent or user's drive snapshots were
modified during release preparation. Source publication and DMG distribution do
not install the app. See [PACKAGING.md](PACKAGING.md) for manual update instructions
and the ad-hoc Gatekeeper limitations. Never disable Gatekeeper globally.

The full architecture, safeguards and implementation limitations are in
[APFS-SNAPSHOT-MANAGEMENT.md](APFS-SNAPSHOT-MANAGEMENT.md); the earlier forensic
acceptance report is [here](APFS-SNAPSHOT-INTELLIGENCE.md).
