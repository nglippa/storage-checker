# Studio Reload feedback — build12 candidate

> Superseded by [build13](STUDIO-RELOAD-BUILD13-20261105.md), which fixes the Retry accessibility identifier and passed the full native Reload/failure/Retry cycle.

Date: 2026-11-05. Candidate: version 2.2.0, build 12, selected with environment overrides. `scripts/version.env` remains release 2.2.0 (10).

This candidate adds bounded feedback corrections after the build11 native fixture test exposed an up-to-date header beside a failed catalog read.

## Implemented behavior

- `Reload Inventory` reads saved indexed results. Visible guidance directs filesystem rechecks to `Folder updates`.
- An explicit Reload or Retry shows `Reloading saved inventory…`, disables repeated action controls during its read, and on successful publication shows `Saved inventory reloaded at <localized time>.` The toolbar exposes the notice as its accessibility value.
- Background reads do not activate manual progress or change the last manual completion timestamp.
- A failed read replaces the header with `Saved inventory could not be reloaded`, retains previously displayed catalog results, gives plain-language Retry and Settings guidance, and places the underlying reader error in a `Technical details` disclosure.
- A first-read failure does not claim retained results. Missing-database and no-root paths do not claim a successful manual reload. Monitoring setup, pause and background-indexer failure priorities remain distinct.
- Cancellation, an obsolete load generation, and an older read with a pending manual replay cannot publish a manual completion timestamp.

## Verification

- `scripts/test-gui.sh`: **PASS**, exit 0, 1166 GUI model/read-only tests; fixture `/private/tmp/storage-monitor-viewer-fixtures.AtVEZH`. Existing no-UserNotifications/no-process/no-SQL live-capacity checks also passed.
- `STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/test-inventory-model.sh`: **PASS**, exit 0, 128 inventory model tests, 0 failed. Coverage includes manual success, silent background reads, coalesced predecessors and replay, cancellation, obsolete-generation completion, first-read failure, Retry recovery, retained catalog after failure and missing database.
- Source review and `git diff --check`: **PASS**.
- Universal packaging: **PASS**, exit 0, all 25 structural DMG checks passed. Both binaries contain arm64 and x86_64 slices targeting macOS 14.0; deep/strict signature verification passed. The verifier reported 238 bundled monitor tests passed.
- Direct packaged self-test: **PASS**, 238 tests passed, actual process exit 0; deep/strict codesign exit 0 and image detach exit 0. Ran from `/private/tmp/storage-monitor-build12-selftest-ly6bksji` mounted read-only with `-nobrowse -noautoopen`, then detached and removed the empty mount directory. See `build12-packaged-selftest.json` and `.log`. An initial concurrent second-mount attempt was refused while the stock verifier held the image; no test was started in that attempt, and its empty temporary mount folder was removed.
- Freeze check: all 71 source/build input hashes in `build12-source-sha256.json` still match after packaging.

### Native build12 check (MacBook, user-authorized, 2026-11-05)

The user explicitly authorized two separate 60-second QA windows. Both targeted only the staged build12 viewer (CFBundleVersion 12, viewer CDHash `651a2ee3…`, identical to the DMG), launched with LaunchServices and process-local restoration isolation against the disposable `reload-verification.sqlite3` fixture. Each window closed itself (7.3 s and 9.1 s); no QA process remained. Actions were own-PID AXPress only; no keyboard or coordinate input.

**Verified natively (both runs):**

- Inline explanation visible: `Reload Inventory reads saved indexed results. To recheck files and folders, use Folder updates.` Hover help: `Reload indexed results. No filesystem scan is performed.`
- Manual Reload: button disabled immediately, toolbar accessibility value `Reloading saved inventory…`; catalog page read completed (2 → 3); completion shown inline and as the toolbar value: `Saved inventory reloaded at 10:55:09 AM.`
- Forced read failure (exclusive lock on the disposable fixture only): button disabled with `Reloading saved inventory…`, then the header changed to `Saved inventory could not be reloaded`. The friendly explanation, a `Retry` button and a collapsed `Technical details` disclosure appeared. Raw SQLite text was not visible, `Inventory is up to date` was absent, the previous success notice was hidden, and all six saved fixture folders remained visible. Screenshot: `build/studio-reload-build12-verification/native-reload/native-build12-failure.png`.

**Not verified natively:** pressing Retry and the recovery after it. Run 1's harness looked for the raw `database is locked` text, which build12 intentionally hides. Run 2 recognised the visible failure wording, but could not resolve the Retry button through accessibility by identifier (`inventory.retry`) or by role/title, so no Retry press was sent. The likely cause is that the panel's container identifier (`inventory.error` on a plain `HStack` without `.accessibilityElement(children: .contain)`) overrides or hides the child identifier. This is a test-hook gap, not a visible defect: the button renders and reads as "Retry". Retry recovery remains covered by the 128 inventory model tests and by the build11 native pass, which used the same `model.reload()` path.

Evidence for both runs (results, driver records, harness sources) is in `build/studio-reload-build12-verification/native-reload/`.

Still **NOT VERIFIED**: native Retry press and recovery in build12; visible Resume interaction; Settings navigation; Enable/Repair; normal restoration/startup without QA overrides; Gatekeeper first launch; physical Intel/macOS 14 execution.

## Artifacts and safety

Candidate: `build/dist/Storage-Monitor-2.2.0-Studio-reload-build12-20261105.dmg` (17,123,744 bytes), with an adjacent SHA-256 file. SHA-256: `e3154e41fab3b74e956822be8ac0f157e47756bce468f0d1991a48e37c4dad24`. Packaging uses SDK 26.5 for the viewer and targets arm64 and x86_64, macOS 14.0 or newer.

The app and helper are ad-hoc signed. Viewer CDHash: `651a2ee3e722aa9057724545729f0ac96a0e7f12`; helper CDHash: `d3c3479fa9518d42b7d23b627576452c3f19af1a`. Informational Gatekeeper assessment rejected the ad-hoc candidate; this artifact is not Developer ID signed or notarized.

Logs: `build12-presentation-tests.log`, `build12-inventory-model-tests.log`, `build12-package.log`, `build12-packaged-selftest.log` and its JSON exit-status receipt in this directory. The separate packaged monitor self-test captures the direct process exit status because the stock DMG verifier pipes its self-test through `tail`.

Apart from the two user-authorized QA windows above, no app was launched. No other desktop input or focus/window actions, installs, commits, pushes, production state changes, active QA worker changes, or unrestricted scans were performed. Test fixtures are disposable paths under `/private/tmp`.

## Studio delivery

Before transfer, the DMG's SHA-256 still matched, and all 71 frozen source hashes still matched. Delivered with `rsync --ignore-existing` over the dedicated Studio SSH identity to `Mac-Studio.local:~/Downloads/Storage-Monitor-2.2.0-Studio-reload-build12-20261105.dmg` (plus `.sha256`). On the Studio: 17,123,744 bytes, SHA-256 `e3154e41…4dad24`, `shasum -c` OK. **Not installed**: the Studio still runs installed build 10. Build11's DMG remains alongside it.

Read-only Studio log check (16:51 UTC): no pause marker present. Generation 2's backlog fell from ~59,000 pending folders to single or double digits, and the worker is running short maintenance slices that replay filesystem events every 30 minutes, with no errors. Full index completion is not separately asserted.

Structural exploration used the codebase-memory skill and Graft caller traces. The codebase-memory snapshot is dated 2026-10-21; relevant source paths are not freshness-tracked and scripts are excluded. Current exact source was read for the edited model, view, presentation, tests and packaging scripts; no graph completeness claim is made.
