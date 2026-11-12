# Storage Monitor 3.0.1 (build 23)

Date: 2026-11-12. Production source branch: `master`. Universal macOS 14+ DMG.
Ad-hoc signed; not Developer ID signed or notarized. This patch follows 3.0.0.

## Changes

- VM growth/recovery explanations and copied likely-cause evidence show recorded
  swap allocation and swap usage as separate before/after pairs and signed deltas.
- Swap Changes includes usage changes within unchanged allocated swap space.
  Per-reading comparisons reject mismatched container/timestamp endpoints and
  interrupted intervals. Existing diagnostic comparisons keep their own intervals.
- Missing historical counters remain unknown. Matching VM/swap allocation stays
  a correlation between potentially overlapping storage, never an additive total
  or proof of the responsible application.
- Technical evidence preserves exact current counter values and their source.
- Platform/readiness reports distinguish developer credentials, local filesystem
  privileges, kernel entitlement checks and implementation-specific helper policy.
  Disposable direct-call probes and their limitations are documented separately.

No collector/schema or snapshot-service policy change is included in this patch.
The 3.0.0 read-only snapshot intelligence and lifecycle engine are preserved.

## Capability and distribution limits

**Privileged snapshot creation, deletion, mounting and automatic lifecycle policies
remain unavailable in this ad-hoc package.** Neither this release nor Full Disk
Access establishes the missing native capability. At publication, the root-only
disposable probe still awaited user-provided output. The subsequent user-run test
verified UID 0 and the disposable target, but native creation returned `EPERM`
(errno 1), with no deletion attempted. Root alone did not enable this API route;
no successful native lifecycle is claimed.
System/startup Data and other role-bearing volumes remain observation-only under
the current product policy. Time Machine settings and foreign snapshots are not
modified. No vendor snapshot engine was incorporated.

Spoken VoiceOver navigation/announcements, Intel execution, native lifecycle
success, real external SSD removal, and installed-helper authorization/scheduling
remain outstanding. Developer ID distribution and notarization are not performed.
The ad-hoc Gatekeeper limitations in [PACKAGING.md](PACKAGING.md) still apply.

## Validation

Final results: **32 focused counter checks, 1,163 viewer/model checks and 40 DMG
checks passed**, including 282 bundled monitor self-tests from the read-only image.
The initial viewer run caught a stale 3.0.0 version assertion; it was corrected
for 3.0.1 and the complete suite passed on rerun.

- Artifact: `Storage-Monitor-3.0.1.dmg`, 19725346 bytes.
- SHA-256: `80362b6a5da48773e7612e8f343d8c2edc14c4a0ab13c42baad2d7b21b8db8e9`.
- Viewer, monitor and snapshot-service bundles: 3.0.1 (23), arm64 + x86_64.

[Structured validation](artifacts/apfs-snapshot-management/RELEASE-3.0.1-VALIDATION.json)
records command outcomes, log hashes, bundle metadata and source hashes.

The real final development GUI was exercised at 1000×640 using three disposable
histories: allocation growth, usage-only growth, and missing legacy counters.
Dark/light rendering, expanded explanations, filtering, copied details, Cmd-F,
Tab/Down selection and accessible labels/states were checked. The legacy fixture
returns no Swap Changes matches; usage-only changes remain included without a
false VM correlation. App-bound Command-F5 did not enable VoiceOver; audible
output was not verified. QA applications were quit and development filters restored.

See [the detailed swap follow-up](artifacts/apfs-snapshot-management/SWAP-COUNTER-FOLLOWUP.md)
and [local APFS capability investigation](APFS-LOCAL-CAPABILITY-INVESTIGATION.md).
The 3.0.0 integration result remains 52 passing checks; this patch changes neither
collection nor persistence. Its earlier lifecycle fixture tests do not establish
kernel snapshot mutation success.

Release preparation does not install or update the user's applications, restart
background workers, alter production databases/LaunchAgents, or mutate user-drive
snapshots. Source and DMG publication are separately authorized by the user.
