# Storage Monitor UX audit fixes — build15 candidate

Date: 2026-11-05. Candidate: version 2.2.0, build 15, selected with environment overrides. `scripts/version.env` remains release 2.2.0 (10). Supersedes [build13](STUDIO-RELOAD-BUILD13-20261105.md). Build14 was packaged and tested but not delivered. Its native screenshots showed an icon-only Indexing menu and a Browse row too wide for the minimum window. Build15 fixes both.

## Changes (the eleven audit items)

1. **Settings sees a saved pause.** The new `MonitoringHealthPresentation` state `.paused` comes from the `inventory.cancel` marker's date (`ViewerStore.inventoryPausedSince`). Settings shows "Disk indexing is paused", the date it was paused, and a **Resume Indexing** button. That button sends the same `resume` request as the Storage screen. A recorded failure still outranks the pause. This closes the Studio gap: capacity checks alone previously produced a healthy status.
2. **Plain-language health.** Titles are rewritten ("Working normally", "A background task stopped unexpectedly", …). Process IDs, exit codes and raw inventory outcomes moved into a **Technical details** disclosure (`technicalLines`). Failed helper actions now show a sentence, with the helper's output under **Details**. Indexer failure text no longer leads with exit codes.
3. **Two verbs instead of four reload controls.**
   - The toolbar **Refresh** button shows the latest saved results. Its help reads "To scan folders on disk again, use Indexing → Recheck."
   - The toolbar **Indexing** menu holds: Check "X" First, Recheck This Folder, Recheck Everything, and Pause / Resume.
   - The header "Folder updates" menu and the always-visible explanation line are removed.
   - ⌘R is now "Refresh", and Settings' button is now "Check Again".
4. **First run.** The not-configured screen has one prominent **Enable Monitoring…** button. It opens Settings straight to the consent prompt (`enableMonitoringRequested`), and nothing is installed without confirmation. Background Monitoring is now the first Settings section, above Appearance.
5. **Pause is explicit.** The menu item reads "Pause Indexing Until Resumed…", with a confirmation explaining that the pause outlasts updates and restarts. Paused screens state "paused since <date>".
6. **One size caveat.** The footer is the single statement. Atlas keeps only an info icon with the full explanation. The repeated caveat was removed from the Inspector and from the Living Tree and Structured Explorer status lines. "0 context" and "N match" appear only when a filter narrows the view.
7. **Largest items are visible.** Browse is a segmented control (Explore · Folder Contents · Largest Folders · Largest Files · Largest Items) when it fits. It falls back to a dropdown in narrow windows (`ViewThatFits`). The "Find large files…" hint is removed.
8. **Consistent names.** "Navigator" is now "List" and "Detailed table" is now "Table". "Reveal in…" became "Show in…", and "Back to Explorer" became "Back to Browsing".
9. **Quieter header.** The Migration readiness line appears only when it finds items to review.
10. **Jargon rewritten** across inventory status, lifecycle states, History filters, the Overview chart legend and the Cleanup review queue. The Trash confirmation no longer shows the internal filesystem identity key.
11. **Specific advice.** "Check Background Monitoring in Settings" became "Open Settings and choose Repair under Background Monitoring". Settings now offers **Repair…** whenever a task has failed, including while monitoring is on.

Failure states keep the raw error out of the main text. It is available under Technical details, including the new disclosure on the no-results "Disk indexing couldn't start" screen (`InventoryLifecyclePresentation.technicalDetail`).

## Verification

- `scripts/test-gui.sh`: **PASS**, 1170 tests. Four tests are new: Settings paused state and date, failure outranks pause, no PIDs in the main text, and the Storage "paused since" text. Assertions for changed wording were updated, as was the lifecycle failure assertion, which now checks `technicalDetail`. Log: `build15-presentation-tests.log`.
- `scripts/test-inventory-model.sh`: **PASS**, 128 tests. Log: `build15-inventory-model-tests.log`.
- Universal packaging: **PASS**, 25 checks (arm64 and x86_64, macOS 14.0, deep/strict signature). Direct packaged self-test: **PASS**, 238 tests, exit 0. Receipts: `build15-package.log`, `build15-packaged-selftest.json`.
- Freeze: all 71 hashes in `build15-source-sha256.json` matched after packaging. Versus build14, only `SourcesGUI/InventoryView.swift` changed.
- **Native (user-authorized 60-second window, 4.7 s, minimum window size 1000×700):** **PASS**. Run against the staged build15 viewer (CFBundleVersion 15, viewer CDHash `bb5b07ef07fdfd7055765181b8234e1f9d5615b3`, helper `2de290ed6be719aa66cc43fc6dac417f6ccd9d5e`) on the disposable fixture:
  - Refresh help text is correct.
  - The inline explanation is gone.
  - "Refreshing…" appeared, then "Refreshed at 12:07:38 PM."
  - On a forced lock: header "Couldn't refresh results", the friendly text with Repair advice, Retry found by identifier, raw error hidden, and the six folders retained.
  - Retry recovered, showing "Refreshed at 12:07:39 PM."
  - Screenshots confirm, at minimum width: the "Indexing" label is visible, Refresh is visible, and Browse falls back to the dropdown with no overflow.
  - Evidence: `build/studio-ux-build15-verification/native-reload/`. The build14 wide-window screenshots (1240×820, segmented Browse) are in `build/studio-ux-build14-verification/native-reload/`.

**NOT VERIFIED natively** (model-tested only where noted):
- Settings layout, the paused state and Resume button (model), Repair-on-failure, and the Technical details disclosures
- First-run Enable → consent prompt
- The pause confirmation dialog
- The Indexing menu contents (the QA fixture has no worker, so the menu is disabled)
- The build15 segmented Browse at wide width (the same code path was seen in build14)
- History, Overview and Cleanup wording as rendered
- Migration line hiding
- Gatekeeper first launch; physical Intel/macOS 14

## Artifact and delivery

`build/dist/Storage-Monitor-2.2.0-Studio-ux-build15-20261105.dmg`: 16,058,194 bytes, SHA-256 `045dcb00fac0f1f87bbda8c9a4577a816a71effed621503e5dabdc49ac97b956`. Ad-hoc signed, not notarized. The size drop versus build13 is image compression only: the same file list, with slightly larger binaries.

Delivered with `rsync --ignore-existing` to `Mac-Studio.local:~/Downloads/`; `shasum -c` OK. **Not installed**: the Studio still runs build 10. A read-only check found no pause marker and the latest indexer slice completed normally.

## Safety

The only GUI activity was the user-authorized QA windows (build13 earlier, build14 and build15 now), each closed by the harness. There were no installs, commits, pushes, production state changes or unrestricted scans. The harness `ready.json` now launches at 1000×700; the earlier copy is kept as `ready.build14.json`.
