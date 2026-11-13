# Storage Monitor 3.1.0 (build 24)

Date: 2026-11-13. Production source branch: `master`. Universal macOS 14+ DMG.
Ad-hoc signed; not Developer ID signed or notarized. This release follows 3.0.1.

## Changes

- **Start Index without background monitoring.**
  - The viewer runs the bundled indexing engine itself, in bounded `inventory-index` slices, until runnable work drains. It stops on pause, failure, busy or unknown results, low space, timeout or quit.
  - Atlas and saved catalogs stay browsable with monitoring off.
  - External drives can be discovered, enrolled and indexed on demand. A manual index resolves and revalidates the selected drive's UUID and fails closed, never falling back to the startup volume.
  - Full Disk Access stays optional. Details: [ON-DEMAND-INDEXING.md](ON-DEMAND-INDEXING.md).
- **Request Time Machine Snapshot…**
  - The action sits in Snapshot Management, independent of the privileged helper and the selected volume.
  - The confirmation explains scope, naming, retention and the up-to-two-minute wait.
  - Requests are recorded in a private per-user history: outcome, date token, exit code and command output on demand.
  - Uncertain requests require acknowledgement before another one; there is no automatic retry.
  - No scheduling, deletion, thinning or Time Machine settings change. Details: [STORAGE-MONITOR-TMUTIL-RELEASE-NOTES.md](STORAGE-MONITOR-TMUTIL-RELEASE-NOTES.md).

The native snapshot route and privileged helper are unchanged and remain capability-gated, as in 3.0.x.

## Validation

All automated suites were run on the release tree against disposable fixtures, with no user-volume scan:

| Suite | Result |
|---|---|
| `scripts/build.sh` | passed |
| `scripts/test-on-demand-index.sh` | passed |
| `scripts/test-gui.sh` (on 3.1.0) | 1,169 viewer/model checks passed |
| `scripts/test-inventory-model.sh` | 101 passed, 0 failed |
| `scripts/test-inventory.sh` | 379 passed |
| `scripts/test-external-wave.sh` | 24 passed |
| `scripts/test-external-store.sh` | 13 passed |
| `scripts/test-snapshot-model.sh` | passed (APFS and Time Machine models) |
| `scripts/test-snapshot-management.sh` | passed |
| `scripts/test-time-machine-snapshots.sh` | passed |
| `scripts/build-dmg.sh` (with `verify-dmg.sh`) | see below |

**DMG:** `scripts/build-dmg.sh` passed with 40 verification checks, including deep/strict signatures, no snapshot entitlement or profile in the ad-hoc build, and 282 bundled monitor self-tests run from the read-only image. Gatekeeper rejects the ad-hoc app, which is informational and expected.

- Artifact: `Storage-Monitor-3.1.0.dmg`, 19959733 bytes.
- SHA-256: `738898a443fe2e5329c87f0de4d35ef7764fddf84bb9247e57710d76ec1d6cb8`.
- Viewer, monitor and snapshot-service bundles: 3.1.0 (24), arm64 + x86_64.

**Native checks from development (2026-11-13), on the Time Machine work, with explicit operator approval:**
- The confirmation text and the Cancel path were checked natively, along with the QA-disabled state and section navigation.
- One real request was made and reported created (token `2026-11-13-013805`). Its history survived reopening the app. Evidence: [TMUTIL-LIVE-VALIDATION-20261113.json](artifacts/apfs-snapshot-management/TMUTIL-LIVE-VALIDATION-20261113.json).

## NOT VERIFIED

- Native running-app **Start Index / Atlas** interaction.
- Actual **Full Disk Access** attribution for app-started indexing.
- **Physical external-drive** lifecycle during on-demand indexing.
- Native interaction of the Time Machine **acknowledgement sheet** (its state flow is covered by fake-runner model tests).
- Carried over from 3.0.x: spoken VoiceOver, Intel execution, native snapshot lifecycle success, installed-helper authorization, and Developer ID distribution or notarization.

The ad-hoc Gatekeeper limitations in [PACKAGING.md](PACKAGING.md) still apply.
