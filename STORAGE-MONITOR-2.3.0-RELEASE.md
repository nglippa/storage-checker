# Storage Monitor 2.3.0 (build 17) — controlled public test

This release makes indexing state visible and simplifies the app's wording. It follows a real incident: a pause saved weeks earlier survived a fresh install, so indexing never ran while Settings said monitoring was configured, and the Reload button flashed during background reads.

Version metadata comes from `scripts/version.env`: **2.3.0**, build **17**. The DMG is universal (arm64 and x86_64), targets macOS 14+, and is **ad-hoc signed, not Developer ID signed or notarized**. Packaging does not install or start monitoring.

## What's new

- **Paused indexing is visible everywhere.** The Storage screen and Settings both say "paused since <date>" and offer **Resume Indexing**. A pause still lasts through updates and restarts, now by design and stated plainly. Pausing asks for confirmation first.
- **Two clear controls.** **Refresh** shows the latest saved results and reports "Refreshed at …" or a plain failure with Retry. The **Indexing** menu holds Recheck This Folder, Recheck Everything, and Pause/Resume. Background reads no longer animate the toolbar.
- **Settings speaks plainly.** Health reads like "Working normally" or "Disk indexing is paused". Process IDs, exit codes and raw errors sit under **Technical details**. **Repair…** appears whenever a background task has failed. Background Monitoring is now the first section.
- **Simpler first run.** One **Enable Monitoring…** button opens the consent prompt directly.
- **Easier browsing.** Largest Files and Largest Folders are visible choices in Browse; it becomes a dropdown in narrow windows. The size caveat appears once, in the footer, instead of on every panel. Names are consistent (List, Table, Show in…). The migration-readiness line appears only when it finds something. Wording was rewritten across Storage, History and Cleanup.

## Verification

Source: commit recorded in `build/release-2.3.0-verification/source-commit.txt` (branch `release/2.3.0`).

| Check | Result |
|---|---|
| Viewer model/read-only suite | 1170 passed |
| Inventory browser/model suite | 130 passed, 0 failed |
| Packaged DMG checks (universal, macOS 14 target, deep/strict signature, 238 bundled monitor tests) | 25 passed |
| Direct packaged self-test from read-only mount | 238 passed, exit 0 |

The suites ran on the identical source as candidate build 16; 2.3.0 (17) changes only the version stamp. Packaging and the self-test were re-run for build 17.

Native checks (user-authorized, disposable fixtures only):
- Refresh, its progress and completion messages, the forced read failure, Retry and recovery, at 1000×700 and 1240×820.
- In a disposable lifecycle QA installation: first-run Enable → consent prompt → setup, the Indexing menu, the Pause confirmation, the paused state in Storage and Settings, Resume from Settings, History, Cleanup review and Disable.

Records: `artifacts/storage-monitor/release-stabilization-20261103/` (`STUDIO-UX-BUILD15/16`, `STUDIO-RELOAD-BUILD12/13`, `STUDIO-INDEXING-RECOVERY`).

Artifact: `build/dist/Storage-Monitor-2.3.0.dmg`, 16,239,412 bytes, SHA-256 `ee544e6bfbb38a3c1f29c008a8a6808ace1f88c9eb616e5111776b3c4d59d1af`.

## For testers

**Opening the app.** This build is not notarized, so macOS blocks the first launch.
- On macOS 15 or later: try to open the app once, then go to **System Settings → Privacy & Security** and choose **Open Anyway**.
- On macOS 14: Control-click the app and choose **Open**.

The background helper may need the same approval when you choose Enable Monitoring. Only install builds whose SHA-256 matches the value above.

**Getting started.** Open Storage Monitor and choose **Enable Monitoring…**, then confirm. The first disk inventory can take hours on a large disk, and you can browse results as they appear. Full Disk Access is optional; without it, protected folders aren't measured.

**Reporting problems.** Include the app version (Storage Monitor → About) and what Settings → Background Monitoring shows, with Technical details expanded. `scripts/diagnose-indexing.sh` prints a read-only status summary. Review it before sharing, because logs can contain folder names.

## Known limits (NOT VERIFIED)

- The download, quarantine and first-launch flow for an unnotarized build, including helper approval
- Upgrading an installed 2.2.0 with an existing catalog
- Pause and Resume in a real installed app, outside the QA fixtures
- Starting automatically after logout/login and sleep/wake
- Real low-space notifications and the Full Disk Access prompt
- VoiceOver; the Increase Contrast, Reduce Motion and larger-text sweeps
- Native Move to Trash confirmation, cancel and restore screens
- Physical Intel Mac or macOS 14 hardware (x86_64 passes under Rosetta only)

Developer ID signing and notarization are documented in `PACKAGING.md`. They are required before a broad public release.
