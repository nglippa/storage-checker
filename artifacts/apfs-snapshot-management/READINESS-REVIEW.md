# Snapshot management readiness review

Date: 2026-11-12. Status: **3.0.0 package authorized — full native lifecycle acceptance BLOCKED.**

3.0.1 follow-up: swap explanations/filtering and platform evidence are updated;
see [the release record](../../STORAGE-MONITOR-3.0.1-RELEASE.md) and
[interactive swap validation](SWAP-COUNTER-FOLLOWUP.md). Native lifecycle
acceptance remains blocked independently of this patch's publication.

The implementation is substantial and executable, but this is not a claim that
Storage Monitor can already manage real snapshots on this Mac. A properly
provisioned, Apple-entitled helper has not been established, registered or tested.
The current development build deliberately refuses privileged mutations. See
[APFS-SNAPSHOT-MANAGEMENT.md](../../APFS-SNAPSHOT-MANAGEMENT.md) for architecture,
volume support, security controls and comparison limitations.

## Delivered implementation

- Persistent root-owned management domain and snapshot identity journal, with
  pre-mutation durable intent, verified creation/deletion outcomes, quarantine,
  explicit protected recovery review and exclusive service locking.
- Manual named creation, protected/excluded snapshots, per-volume policies,
  age/count deletion previews and separately enabled automatic retention.
- Hourly/daily/weekly/custom elapsed schedules with persisted next-due times,
  coalesced missed runs, offline skips, pressure thresholds and serial execution.
- Fixed authenticated XPC protocol, separate administrator rights, same-Team
  exact-identifier code requirements and a narrowly scoped native C adapter.
- Read-only comparison lease mechanism; file comparison as the requesting user,
  bounded metadata/hash coverage, uncertain results, search and JSON export with
  source volume/snapshot UUIDs and limitations.
- Dedicated Snapshot Management UI with inventory/details, creation form,
  schedule/retention editor, protection, deletion review, recovery and activity.
  Existing storage browser and history remain separate and navigable.
- App-like helper bundling and optional operator-supplied profile/signing inputs.
  No helper registration, authorization-rule installation or production-state mutation was performed during implementation testing. Subsequent source/DMG publication is separately authorized and recorded in `STORAGE-MONITOR-3.0.0-RELEASE.md`.

## Actual validation scope

Final command results and log hashes are recorded in `VALIDATION.json` after the
last validation run. Full temporary logs are under `/private/tmp/storage-management-*`.

| Check | Evidence/scope |
| --- | --- |
| Lifecycle behavioral suite | Production policies/ownership/retention/ledger/engine with a deterministic native-operation fixture; actual private files and cold ledger loads |
| Comparison behavior | Actual disposable directories: added/removed/modified paths, symlinks, hash limits, incomplete presence, root validation and export round trip |
| Ownership and destructive safety | Unknown prefix-like snapshots, foreign users, stale UUID/name/XID, session/one-use preview binding, protection changes, active leases, corrupt leases/duplicates/policies and interrupted operations |
| Scheduling/retention | Coalesced missed periods, automatic age/count, protected/excluded/newest recovery points, foreign records, disconnected volume, offline disable, pressure skip and retention |
| Native disposable APFS image | Real mounted roleless image discovery, empty native inventory, descriptor UUID/capability/free-space checks, stale volume/container rejection, denied creation/deletion with unchanged inventory, and detached-image rejection |
| Existing APFS intelligence | Existing snapshot model and 52 integration fixtures |
| Existing viewer/history | 1163 GUI model/read-only checks passed on the final sources |
| Existing monitor | 282 self-tests passed on the final rebuilt monitor |
| Builds | Development viewer, monitor and app-like helper built successfully; strict development signing and plist lint passed |
| Distribution packaging | Shell syntax reviewed; provisioned/universal package, notarization and installation NOT VERIFIED |

The native tests do not actually call a privileged mutation syscall: the real
adapter's root/entitlement gate rejects the request first. Successful engine
creation/deletion is fixture-backed, not successful kernel snapshot mutation.
The disposable APFS image is detached and removed after testing. No real internal
or external drive's snapshots were created or deleted.

Early native tests exposed and corrected actual platform discovery assumptions:
`WritableVolume`/`WritableMedia` are the applicable properties on this OS, and
Foundation path standardization can turn `/private/tmp` into the `/tmp` symlink.
The no-follow descriptor path must preserve the canonical mountpoint. Earlier
builds invalidated by source changes during compilation were rerun; they do not
count as successful final builds. Deprecation warnings from hdiutil on this newer
OS are recorded, not treated as proof that the test failed.

## Native GUI and accessibility evidence

The real development app was exercised at 1000×640 content size with a clearly
synthetic, read-only QA fixture. Its three owned recovery points and one fake
Time Machine snapshot are not host snapshot history. All mutation and helper
registration buttons remain disabled in QA.

Observed results:

- Inventory labels distinguish managed, protected and foreign snapshots; creation
  times and exclusive sizes remain appropriately qualified/unknown.
- Snapshot name/label search works. A hidden selected snapshot initially retained
  its details; the fix clears selection/details when search removes that row.
- Creation form accepts a name, explains ownership prefixes and backup limits,
  and cancels with Escape. Native creation cannot be submitted in QA.
- Schedule editor lists Hourly/Daily/Weekly/Custom, shows custom minutes and count,
  age and pressure controls, and defaults both automatic creation and deletion off.
- A native Form initially clipped long labels. A bounded label/field layout fixed
  this; the corrected custom sheet was inspected in light appearance at 620 px.
- Main dark inventory and corrected light inventory were inspected at minimum
  size; the final corrected dark policy sheet also fits without clipping. Comparison instructions and navigation back to History & Monitoring work.
- Search and form controls expose labels/states; Cmd-F selects search text, Tab
  advances numeric fields, and Escape dismisses sheets while VoiceOver is enabled.
  VoiceOver was confirmed enabled using NSWorkspace and restored off afterward.

VoiceOver speech, reading order and announcements remain **NOT VERIFIED**: tools
cannot observe spoken output/captions. Actual authorized create/delete/protection,
policy-save confirmations, mounted comparison/export and populated root activity
were not exercised interactively because a capable helper is unavailable. QA
fixtures do not establish those privileged workflows. The final dark-sheet check passed; an actual provisioned-helper capability/authorization flow remains unverified. See `VALIDATION.json`.

## Review findings corrected

The read-only reviewer inspected the platform interfaces, management core and
privileged boundary. Findings were checked against source before fixes:

- Hash availability no longer masquerades as metadata changes; per-side budgets
  prevent one scan consuming the entire content budget. Incomplete one-sided
  entries are unverified rather than asserted additions/removals.
- Persistent leases, native ownership uniqueness and saved policy bounds are
  validated before cleanup/scheduling. Directory fsync failures fail closed.
- Both lease sides receive cleanup attempts; confirmed absence is idempotent.
  Active leases block deletion. Session close, expiry, restart and termination
  attempt cleanup without force-unmounting.
- Protection batches prevalidate before mutation; disconnected policies can be
  disabled; count retention chooses eligible entries around protected records.
- Interrupted ownership has an explicit fresh-authorization recovery path,
  protecting any recovered existing snapshot.
- The signing requirement is tested with Apple's parser. The helper now uses a
  profile-bearing app-like bundle, and permanent capability failures do not enter
  an unsuccessful-exit restart loop.
- Native GUI clipping and hidden-selection issues were reproduced interactively
  and corrected, rather than inferred from source. Free-space threshold input is
  bounded before integer conversion, and helper-unavailable inventories label
  ownership unverified rather than inferring that snapshots are foreign.

## Required before full acceptance or release

1. Establish a supported capability/authorization route accepted by the target
   kernel and code-signing policy. Validate the implementation's helper identity
   and any required profile; distribution signing/notarization are separate
   checks, not universal prerequisites for local APFS calls. See the
   [direct local capability investigation](../../APFS-LOCAL-CAPABILITY-INVESTIGATION.md).
   Do not replace these checks with a private entitlement, root shell or Time
   Machine workaround.
2. Explicitly authorize a separate helper installation/registration test. Exercise
   code-signing rejection, valid/denied/cancelled administrator rights, multiple
   users and replay/connection failure against the real XPC daemon.
3. On disposable APFS volumes only, prove successful create → identity readback →
   protect → compare/mount → unmount → preview → delete → absence confirmation.
   Include crash boundaries, partial mount failures and real creation/deletion
   errors, case-sensitive/encrypted images and concurrent external-tool activity.
4. Verify actual launchd scheduling across sleep/restart and a physical external
   SSD disconnect/reconnect. The user has no idle SSD available; a detached disk
   image and operation fixtures cover only part of that behavior.
5. Verify spoken VoiceOver navigation/announcements and the actual authorization,
   deletion confirmation, comparison export and populated activity UI with the
   capable helper. Keep destructive tests confined to disposable images.
6. Validate universal distribution packaging, profile placement, nested signing
   and notarization. Commit/install/release require separate authorization.

The 3.0.0 distribution keeps privileged management unavailable. Until these gates pass, the full native management mission success criterion remains **NOT MET**.
The existing read-only forensic capability remains usable independently.

Public evidence note: raw host-specific JSON, logs and independent-review metadata remain local and are not included in the public source commit. Aggregate 3.0.0 release checks are recorded in `artifacts/apfs-snapshot-management/RELEASE-3.0.0-VALIDATION.json`. Local paths in this report are redacted.
