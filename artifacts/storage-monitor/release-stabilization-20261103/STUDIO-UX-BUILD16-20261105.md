# Storage Monitor UX — native lifecycle verification and build16

Date: 2026-11-05. Supersedes [build15](STUDIO-UX-BUILD15-20261105.md) for delivery. Build16 = build15 plus one fix found by this native test.

## Native lifecycle UX test (user-authorized)

The test ran in a disposable lifecycle QA scope, using `scripts/prepare-lifecycle-qa.py`, built from source identical to build15's 70 manifest files. The QA viewer bundle was re-signed ad hoc because its linker-only signature was rejected by LaunchServices. The driver is `build/studio-ux-build15-verification/lifecycle-native/ux-lifecycle-cycle.swift`. It used own-PID AXPress only, with no keyboard or pointer input. The independent `lifecycle-qa-guard.py` ran as the driver's child and removed the session's three unique `local.macbook.storage-monitor.lifecycle-qa.<uuid>` tasks after every attempt; all labels were confirmed absent afterwards. No production label, data or installed app was touched.

**Final run: PASS** (25 s, fresh scope `storage-monitor-lifecycle-r17wmo3i`; evidence in `.../lifecycle-native/run-final/`):

1. **First run.** A single prominent **Enable Monitoring…** appears, with no duplicate Open Settings.
2. **Consent prompt.** Pressing Enable Monitoring opened Settings with the consent prompt already shown.
3. **Settings order.** Background Monitoring is listed before Appearance.
4. **Enable.** Pressing Enable completed setup, and the status reports configured.
5. **Health text.** The main health text contains no process IDs.
6. **Indexing menu.** It lists Recheck This Folder, Recheck Everything and Pause Indexing Until Resumed…. A partial run while indexing was active also showed Check "Startup Data" First.
7. **Pause.** The confirmation was shown. Storage then showed "Indexing is paused · Resume Indexing" and "paused since Nov 5, 2026 at 12:29 PM" (partial run).
8. **Settings while paused.** It showed "Disk indexing is paused" with the date and **Resume Indexing**. Technical details expanded to show PIDs and exit codes.
9. **Resume from Settings.** It reported "Resume requested. Disk indexing continues in the next background run…", and the pause cleared. After the next run, health read "Disk indexing last finished normally".
10. **History.** The new wording rendered: "View only · the background monitor records history on its own", "Orange: under 25 GB free · Red: under 15 GB", "Colored points: changes of 1 GB or more", "Disk capacity as macOS reports it…".
11. **Review Cleanup.** "Start Review Again" and "Back to Browsing" rendered and worked.
12. **Disable.** It confirmed, and status returned to off.

Earlier attempts in this approval sequence failed before any action. The causes were the linker-only signature, extra launch arguments, missing scope temporary-path environment, and a title mismatch, all corrected. One partial run stopped at the Settings Resume button, which the harness couldn't address by identifier. As with build12's Retry, the health panel is a plain stack whose identifier lands on its child. The harness now finds the button by title. VoiceOver labels are unaffected, and the product was not changed for this.

### Defect found and fixed in build16

After **Resume in Settings**, the Storage screen kept the stale note "Indexing paused. It stays paused until you choose Resume Indexing…". Pausing had also shown that note as a duplicate of the paused-state explanation. Fix in `SourcesGUI/InventoryView.swift`:
- Pausing adds no separate note.
- Any pause note clears on the next read once the marker is gone.

Two new model tests cover this: no duplicate note while paused, and the note clears after resume.

## Build16 verification

- `test-gui.sh`: 1170 passed. `test-inventory-model.sh`: 130 passed (two new).
- Universal packaging: 25 checks passed. Direct packaged self-test: 238 passed, exit 0; codesign deep/strict 0.
- Freeze: 71 hashes in `build16-source-sha256.json` matched after packaging. Versus build15, only `InventoryView.swift` changed.
- The native Refresh/failure/Retry cycle was not re-run for build16. The change touches only pause/resume note handling and is covered by the model tests. Build15's native pass at 1000×700 covers the unchanged Refresh path.

## Artifact and delivery

`build/dist/Storage-Monitor-2.2.0-Studio-ux-build16-20261105.dmg`: 16,058,377 bytes, SHA-256 `d767b2fe782b0d915be6d3bc1c93afddd7715896b169f5d6be842f813cd0ce0b`. Viewer CDHash `98fbc742aabb78d2f5d62ba152c1ccd673e6310b`, helper `8097b183a05d5ea7c13c3d69e874be1697315f99`. Ad-hoc signed, not notarized.

Delivered to `Mac-Studio.local:~/Downloads/`; `shasum -c` OK. **Not installed**: the Studio runs build 10.

**Still NOT VERIFIED:**
- The paused/Resume flow in the real installed (non-QA) app
- Repair shown on a real failure; it is model-tested via `offersRepair`
- The narrow-window Settings layout
- Gatekeeper first launch
- Physical Intel/macOS 14
