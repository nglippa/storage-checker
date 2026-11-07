# Storage Monitor 2.1.0 (9): installation and rollback plan

**NOT EXECUTED.** This is a plan only.

Steps marked ⚠ are separate operator-controlled actions, each needing its own explicit authorization. They change:
- installed apps;
- background-monitor files;
- LaunchAgents;
- Full Disk Access;
- or system permission prompts.

**Artifact.** `build/release-artifacts/2.1.0-9-20261029T063406Z/Storage-Monitor-2.1.0.dmg`, SHA-256 `3484abea58524cd090808714e38672cc0f82a628d3b42b9c797c66674f774f0c`, built from `873e069`. See [PACKAGING-REPORT.md](PACKAGING-REPORT.md).

## Current production state (recorded read-only, 2026-10-29)

| Item | State |
|---|---|
| `/Applications/Storage Monitor.app` | `local.macbook.storage-monitor.viewer` 2.1.0 (1), ad hoc, CDHash `118a6f42…`, modified 2026-10-25 14:10 |
| Bundled helper inside it | `local.macbook.storage-monitor` 2.1.0 (1), CDHash `8a5393ef…` |
| `~/Applications/MacBook Storage Monitor.app` (installed helper) | `local.macbook.storage-monitor` 2.1.0 (1), CDHash `8a5393ef…` |
| LaunchAgents (2026-10-27 13:28) | `local.macbook.storage-monitor`, `.baseline`, `.inventory`; all run `~/Applications/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor`; all loaded (`launchctl list`: no PID between runs, last exit 0) |
| Viewer preferences | `~/Library/Preferences/local.macbook.storage-monitor.viewer.plist`, SHA-256 `4ab8a7be…` (`inventory.explorer.visualization = tree`, left as is) |
| Data | `~/Library/Application Support/MacBook Storage Monitor/` (history and catalog) |

**Since the installed build.** Nothing in `Sources/` (monitor-only code) and no schema statement changed between the installed build (`6218eba`) and `873e069`. A helper update therefore performs no history or catalog schema migration. The helper binary still changes, because shared code compiles into it.

## 1. Backup (non-destructive; operator may run)

1. Quit Storage Monitor normally. Confirm no `StorageMonitorViewer` process is running.
2. Make a dated backup folder outside both apps, for example `~/StorageMonitor-backup-2.1.0-1-<date>/`.
3. `ditto "/Applications/Storage Monitor.app" <backup>/Storage Monitor.app`
4. `ditto "$HOME/Applications/MacBook Storage Monitor.app" <backup>/MacBook Storage Monitor.app`
5. Copy the three `~/Library/LaunchAgents/local.macbook.storage-monitor*.plist` files to `<backup>/LaunchAgents/`.
6. `defaults export local.macbook.storage-monitor.viewer <backup>/viewer-preferences.plist`, and record its SHA-256.
7. Data: take an online SQLite backup of `history.sqlite3` and the catalog with `sqlite3 <db> ".backup <backup>/<name>"`, which is consistent while the worker writes. Do not copy them with `cp` while the inventory worker is active.
8. Record `launchctl list | grep storage-monitor`, both CDHashes and the Full Disk Access state of `MacBook Storage Monitor` (System Settings → Privacy & Security → Full Disk Access).
9. Keep the 2.1.0 (1) DMG if available. The 2026-10-27 record puts it in the other checkout (`orca/projects/storage-checker/build/dist/`).

## 2. Preferences preservation

- The release keeps `local.macbook.storage-monitor.viewer`, so existing preferences carry over unchanged.
- No migration exists or is needed.
- Do not edit preferences during the upgrade.
- After the upgrade, compare a fresh `defaults export` with the backup: only keys the person changes in the new app should differ.

## 3. Upgrade the app (⚠ replaces `/Applications/Storage Monitor.app`)

1. Verify the DMG first: `shasum -a 256 -c Storage-Monitor-2.1.0.dmg.sha256`.
2. Mount it read-only: `hdiutil attach -readonly -nobrowse`.
3. Install: drag `Storage Monitor.app` to Applications (replace), or run `ditto` from the mount into `/Applications`, with the viewer quit.
4. Check the installed copy:
   - `PlistBuddy` → `local.macbook.storage-monitor.viewer`, 2.1.0, 9;
   - `codesign --verify --deep --strict`;
   - `codesign -dvvv` → CDHash `b91d4e3c…`.
5. Detach the image.

**Gatekeeper.** The app is ad hoc signed and not notarized, so Gatekeeper rejects it. On this Mac the first launch may need right-click → Open, or System Settings → Privacy & Security → Open Anyway. ⚠ That is a system permission prompt. Do not bypass Gatekeeper globally.

## 4. Background Monitoring check (read-only until Update is pressed)

1. Open the app, then Settings → Background Monitoring.
2. Expected, from the code at `873e069`: **"The installed background monitor (2.1.0 (1)) differs from this app (2.1.0 (9)). Update it to match."** (state `needsUpdate`). Settings compares version and build. Not yet observed natively.
3. Monitoring keeps running the old 2.1.0 (1) helper until Update is pressed. The viewer itself is read-only.

## 5. ⚠ Helper update (separate authorization: changes production LaunchAgents and the installed helper)

**What "Update" runs.** It runs the bundled helper's `install` command. The command's own self-test describes it:

1. It boots out the three agents.
2. It replaces `~/Applications/MacBook Storage Monitor.app` under a durable install journal (`Application Support/…/install-transaction/journal.json`).
3. It runs any schema migration (none is expected for this build).
4. It enables, bootstraps and confirms the three agents in the user's GUI domain.

**Interrupted update.** If an update is interrupted, the journal remains, and Settings reports "interrupted" with a Repair action.

**After the update, verify:**
- the installed helper is 2.1.0 (9) with CDHash `e5707cf9…`;
- the three plists still point at `~/Applications/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor`;
- `launchctl list` shows all three labels;
- Settings shows "Background monitoring is on".

## 6. Code signature and Full Disk Access

- The helper is ad hoc signed. Its designated requirement is tied to its CDHash, which changes (`8a5393ef…` → `e5707cf9…`).
- macOS privacy grants (Full Disk Access, notifications) are tied to the code's identity. An existing Full Disk Access grant is therefore expected to stop applying to the new helper. This is inferred, not tested; it was not observed on this Mac.
- **Check after the update:** whether the catalog's `inventory_full_disk_access` state and protected-folder counts (Storage → accounting details) change at the next inventory pass.
- ⚠ Re-granting Full Disk Access (System Settings → Privacy & Security → Full Disk Access, add `~/Applications/MacBook Storage Monitor.app`) is an operator action.
- Notification permission may also need re-approval through Settings → "Allow Low-Space Notifications…" (⚠ a system prompt).
- A Developer ID signature would keep a stable designated requirement across updates; ad hoc builds cannot.

## 7. Launch and application-health checks (after the app upgrade)

- The window opens on the production history and catalog. Available storage matches the macOS figures. Storage, Living Tree 2D/3D, Monitoring, Cleanup Review and Settings all render, in light and dark.
- The title is "Storage Monitor", with no QA banner.
- Trash is enabled in production, so do not move anything during validation unless separately authorized.
- No `perf` or `QA` files are created; the release binary contains no such tooling.
- About Storage Monitor shows version 2.1.0 (9).
- Preferences: the saved `tree` visualization is honored.

## 8. Monitoring-service verification (after the helper update)

- `launchctl list | grep storage-monitor` shows three labels, with the last exit status 0 after their next run.
- Within 30 minutes, or at the next login, a new reading appears in Monitoring with "Live · updated".
- The inventory worker progresses: Indexing details shows activity, and no errors appear in Settings.
- No duplicate agents. `MonitoringSetupStatus` reports duplicates and wrong targets as "incomplete".

## 9. Rollback

**Viewer only (no helper update was done).**
1. Quit the app.
2. ⚠ Replace `/Applications/Storage Monitor.app` with the backed-up 2.1.0 (1) copy (`ditto`).
3. `codesign --verify --deep --strict`.
4. The build number goes backward (9 → 1). If LaunchServices keeps opening a cached copy, run `lsregister -f "/Applications/Storage Monitor.app"`.
5. Preferences need nothing.

**Helper also updated.**
1. Restore the viewer first, as above.
2. ⚠ With the restored 2.1.0 (1) app open, Settings → Background Monitoring should report that the installed helper (2.1.0 (9)) differs from the app (2.1.0 (1)) and offer Update. Running it installs the 2.1.0 (1) helper back, under the same transactional install.
3. Alternatively, restore `~/Applications/MacBook Storage Monitor.app` from backup, but only with the agents booted out. That is ⚠ `launchctl bootout`/`bootstrap` for production labels, which project policy forbids without explicit authorization. Prefer the app's own install path.

**Data.** No schema migration is expected for this build, so no data rollback is needed. Restore the SQLite backups only if a later check shows damage, with all agents stopped.

**Privacy grants.** These may need re-granting again for the restored helper: it has its own CDHash.

## 10. Post-rollback confirmation

- The viewer and helper report 2.1.0 (1), with CDHashes `118a6f42…` and `8a5393ef…`.
- Three agents are loaded; Settings shows "on".
- A new reading arrives within 30 minutes.
- The inventory continues.
- Viewer preferences match the backup export, apart from deliberate changes.
- Full Disk Access and notifications work as before.
