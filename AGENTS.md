# Agent instructions — Storage Monitor

## Desktop safety (mandatory, no exceptions without explicit user authorization)

The user works on this Mac while agents run. On 2026-10-23, an agent focused a development window during verification, and keystrokes the user was typing in another app landed in it.

1. **Never activate, focus, raise or bring forward any application window.** This includes `mac-use focus_window`, `open` / `open -a` of a GUI app (apps such as this viewer activate themselves at launch), AppleScript `activate`, `NSApp.activate`, and clicking a window to bring it forward.
2. **Never send keyboard input, mouse clicks, shortcuts or accessibility actions** (AXPress, menu clicks, typing) to the desktop.
3. **Never use `focus_window` or an equivalent API during unattended verification.**
4. **A differently named development app is not isolated.** It still shares the user's screen, focus and keyboard.
5. **Never steal focus from another application**, even briefly, even "just for a screenshot".
6. **Never dismiss, minimize, close, move or resize windows that belong to the user.**
7. **Prefer non-interactive verification:** headless and model tests, isolated fixtures, builds, SQLite checks on disposable copies, `codesign`/`plutil`/`otool`, and `hdiutil attach -nobrowse`.
8. **If a check needs a focused GUI, stop and ask the user for permission.** Say exactly which window will come forward and for how long.
9. **Do not weaken or remove a verification requirement** to hide a check that could not run safely.
10. **Report skipped native GUI checks as NOT VERIFIED**, listing each one.

Launching this project's apps (`open "…/Storage Monitor.app"`, `open -n …`) counts as activating a window. It requires the same explicit permission.

## Protected state

Without explicit authorization for that specific action, do not modify, restart or stop any of the following:

- the active QA worker or supervisor (`local.macbook.storage-monitor.inventory-qa`, `build/inventory-fresh-*/`, pointed to by `build/inventory-fresh-current.json`);
- its database;
- preserved snapshots;
- production databases (`~/Library/Application Support/MacBook Storage Monitor/`);
- installed apps (`/Applications/Storage Monitor.app`, `~/Applications/MacBook Storage Monitor.app`);
- production LaunchAgents (`~/Library/LaunchAgents/local.macbook.storage-monitor*.plist`).

Never run `install`, `uninstall`, `authorize`, or `launchctl bootstrap`/`bootout` for the production labels during development or testing. Never launch an unrestricted full-volume scan. No commits, pushes, installs or deployments unless asked.

Work on disposable copies (`cp -c` APFS clones) and isolated `--data-dir`/`--root` fixtures under `/private/tmp`.

## Build and test

- `scripts/test-inventory.sh` runs the inventory integration tests.
- `"build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor" self-test` runs the monitor tests, after `scripts/build.sh`.
- `scripts/test-gui.sh` runs the viewer model tests.
- `scripts/test-inventory-model.sh` runs the headless disk inventory browser tests (refresh replay, deferred folders, prioritize messages, explorer re-reads) against an isolated fixture built by the monitor's worker. Needs `scripts/build.sh` first and `STORAGE_MONITOR_SDK_PATH` as for the viewer build.
- `STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-gui.sh` builds the viewer. The default newer SDK lacks a SwiftUI macro plugin.
- `scripts/build-dmg.sh` builds the distribution DMG; see `PACKAGING.md`.

Lifecycle and verification records live in `INVENTORY-*.md`, `VERIFICATION.md` and `PACKAGING.md`. Keep them truthful: implementation and verified behavior are different claims.
