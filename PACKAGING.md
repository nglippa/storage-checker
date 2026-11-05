# Packaging and distribution

Storage Monitor ships as a disk image:

**open the DMG → drag Storage Monitor into Applications → launch → Settings → Enable Background Monitoring.**

Users do not need Homebrew, Python, Node.js, Swift, Xcode or the command-line developer tools. The app is native Swift/SwiftUI, uses no other runtime, and is universal (Apple silicon and Intel), for macOS 14 Sonoma or later.

## Build prerequisites (build machine only)

- macOS with the Command Line Tools: `swiftc`, `lipo`, `codesign`, `hdiutil`, `sips`, `iconutil`, `plutil`.
- A macOS SDK with SwiftUI and Charts. The script prefers `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, because the newer default SDK on the reference machine lacks a SwiftUI macro plugin. Override it with `STORAGE_MONITOR_SDK_PATH`.
- The approved artwork `Assets/AppIcon.png`. The script stops if it is missing; it never generates placeholder art.
- No Apple developer account is needed.

## Development DMG

```sh
scripts/build-dmg.sh
```

This produces:

- `build/dist/Storage-Monitor-2.3.0.dmg` plus a `.sha256` checksum;
- the assembled app in `build/dist/work/`.

It is ad-hoc signed. The script finishes by running `scripts/verify-dmg.sh`, which mounts the image read-only with `-nobrowse -noautoopen`, so no Finder window opens and nothing is launched. It then checks structure, metadata, signatures, architectures and libraries, runs the bundled monitor's self-test from the image, and detaches.

Options, all set through environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `STORAGE_MONITOR_VERSION` | `scripts/version.env` (2.3.0) | `CFBundleShortVersionString` of the app and helper; also the DMG file name |
| `STORAGE_MONITOR_BUILD` | `scripts/version.env` (10) | `CFBundleVersion`; only ever increases |
| `STORAGE_MONITOR_APP_ONLY` | unset | `1` stops after building and verifying `build/dist/work/Storage Monitor.app`; no disk image |
| `STORAGE_MONITOR_SIGN_IDENTITY` | `-` (ad-hoc) | codesign identity |
| `STORAGE_MONITOR_ARCHS` | `arm64 x86_64` | architectures |
| `SOURCE_DATE_EPOCH` | last commit time | timestamps of every file in the image |
| `STORAGE_MONITOR_SKIP_VERIFY` | unset | `1` skips verification |
| `STORAGE_MONITOR_DMG_NAME` | `Storage-Monitor-<version>.dmg` | image file name in `build/dist/` (for distinguishable test builds) |

**Reproducibility.** The steps are deterministic:

- clean work directory;
- pinned target (macOS 14.0);
- fixed plist contents;
- normalized permissions;
- extended attributes cleared;
- `SOURCE_DATE_EPOCH` timestamps;
- the same signing order.

The DMG bytes are not bit-for-bit identical between builds, because `hdiutil` and code signatures embed their own metadata. Compare app contents rather than image checksums.

## Distribution DMG (optional, future)

```sh
STORAGE_MONITOR_VERSION=1.1.0 STORAGE_MONITOR_BUILD=2 \
STORAGE_MONITOR_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" scripts/build-dmg.sh
```

With a Developer ID identity, the helper and the app are signed with the hardened runtime and a secure timestamp, and the DMG is signed too. Notarization is **not** part of this release and is never run by the script. It would be a separate, manual step:

```sh
xcrun notarytool submit build/dist/Storage-Monitor-<version>.dmg --keychain-profile <profile> --wait
xcrun stapler staple build/dist/Storage-Monitor-<version>.dmg
```

## Application bundle structure

```
Storage Monitor.app                           local.macbook.storage-monitor.viewer
  Contents/Info.plist                         version, build, LSMinimumSystemVersion 14.0
  Contents/MacOS/StorageMonitorViewer         SwiftUI desktop app (universal)
  Contents/Resources/AppIcon.icns
  Contents/Helpers/MacBook Storage Monitor.app  local.macbook.storage-monitor (LSUIElement)
    Contents/MacOS/StorageMonitor             background monitor, inventory worker, CLI (universal)
    Contents/Resources/AppIcon.icns
```

- Both executables link only `/usr/lib` and `/System/Library` (the Swift runtime ships with macOS).
- They have no rpaths and embed no paths from the build machine.
- The helper is signed first; the outer signature seals it.
- The app reads its data from `~/Library/Application Support/MacBook Storage Monitor` and never depends on the repository or the disk image's mount point.

## Background monitoring

Monitoring is never enabled silently. In **Storage Monitor → Settings → Background Monitoring**:

- **Enable Background Monitoring…** shows what will be installed. After the person confirms, the app runs the bundled helper's own `install`:
  1. records a durable install journal (`install-transaction/` in the data directory) and copies of the existing agents;
  2. boots out any existing Storage Monitor agents;
  3. snapshots history as an APFS clone (constant time and space; a full copy only off APFS);
  4. moves the previous helper aside and copies the new one to `~/Applications/MacBook Storage Monitor.app`;
  5. applies the new code's schema migration while nothing else can write;
  6. writes three per-user LaunchAgents, removes duplicate agent files for the same labels, and enables, bootstraps and confirms each in `gui/<uid>`;
  7. commits: the previous helper is removed, and the snapshot is discarded unless the migration changed the schema (then one `history.pre-update-*.sqlite3` is kept).

  See **Updating** for failure and interruption handling.

  No administrator password is needed.

  | Label | Job |
  |---|---|
  | `local.macbook.storage-monitor` | Capacity check at login and at :00/:30 |
  | `local.macbook.storage-monitor.baseline` | One-time folder baseline |
  | `local.macbook.storage-monitor.inventory` | Disk inventory worker, low priority |

  The agents point to the stable copy in `~/Applications`, never to `/Applications` or the DMG, so moving or updating the desktop app cannot break them.
- **Status** combines the LaunchAgent files with what launchd itself reports (`launchctl list` and `print-disabled`, read-only):
  - off (no agent files and nothing loaded);
  - on (every agent file present, pointing at the installed copy, and loaded by launchd);
  - **update** (the installed monitor's version differs from the app's);
  - **needs repair**, with **Repair**: missing agents; an agent pointing at a missing program (such as an ejected image) or at a different copy of the monitor; a duplicate agent file for one of these labels; an agent macOS has disabled or not loaded; a job still loaded without its file; or an interrupted update.
  - If launchd cannot be queried, Settings says so rather than implying the tasks run.
- **Disable…** confirms, then runs `uninstall`: it boots out and removes all three agents and keeps history and the installed helper.
- **Allow Low-Space Notifications…** runs `authorize`, which asks macOS for notification permission for the background monitor.
- **Failures** show the monitor's own message (for example a `launchctl bootstrap` error) and say that the previous installation was restored. History is never lost by a failure.
- Install and uninstall run to completion; the app imposes no time limit on them. Only **Allow Low-Space Notifications…** waits a bounded 130 s for an answer to the macOS prompt.
- **QA builds** (`--database-path`) disable these buttons, so development never changes real LaunchAgents.

Command-line equivalent: `~/Applications/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor install|uninstall|authorize`. In a development checkout, use `bin/storage-monitor`.

## Permissions

| Situation | Behavior |
|---|---|
| No extra permission | Measures free space, APFS volumes and every folder macOS allows. Protected places (other users' folders, and app data such as Mail, Messages and Safari) are recorded as inaccessible, never estimated. |
| Full Disk Access (optional) | Granting it to the **background monitor** widens folder coverage. Monitoring works without it. |
| How to grant | System Settings → Privacy & Security → Full Disk Access → **+** → `~/Applications/MacBook Storage Monitor.app`. Settings has an **Open Full Disk Access Settings…** button. macOS never grants this silently, and the app never tries to bypass privacy protections. |
| Restricted access | Coverage and inventory show inaccessible areas and partial sizes explicitly. Free-space checks and alerts are unaffected. |

## Gatekeeper expectations

| Build | What happens |
|---|---|
| Built locally (no download) | Not quarantined; opens normally. |
| Ad-hoc DMG downloaded from the internet | Quarantined. On first open, macOS says it cannot verify the app. Go to **System Settings → Privacy & Security → Open Anyway** for Storage Monitor, then confirm. On macOS 15 and later, Control-click → Open no longer bypasses this. |
| Developer ID signed and notarized (future) | Opens after the standard download prompt. |

**Background monitor from a downloaded ad-hoc build (NOT VERIFIED).** The helper copied to `~/Applications` keeps the download's quarantine attribute. Gatekeeper may refuse to let launchd run it, and in the background there is no visible prompt.

- Setup detects quarantine and reports it; the app never removes it.
- If monitoring shows no new readings, open `~/Applications/MacBook Storage Monitor.app` once in Finder and approve it in Privacy & Security.
- Developers who built and trust a copy may instead clear quarantine for that one app with `xattr -dr com.apple.quarantine <app>`.
- Do **not** disable Gatekeeper globally (`spctl --master-disable`).

## Updating

1. Quit Storage Monitor.
2. Drag the new `Storage Monitor.app` from the new DMG over the old one in Applications.
3. Open Settings. If the installed background monitor's version differs, choose **Update Background Monitor…**. This replaces only the helper copy and its agents; history, preferences and the inventory catalog are kept, and the catalog migrates forward in place.

**Existing installations (in-place upgrades).**

| Installed | What Settings shows after the new app is in Applications | What to choose |
|---|---|---|
| 1.0.0 (two background tasks, no disk inventory) | "Background monitoring is partly set up (2 of 3 background tasks…)" | **Repair**. It runs the new helper's transactional install, which adds the inventory task and keeps every reading, alert and diagnostic. |
| 1.0.1 | "The installed background monitor (1.0.1) differs from this app (1.0.2). Update it to match." | **Update Background Monitor…**. The inventory task's arguments and catalog are migrated in place. 1.0.2 adds one table and two columns, so one `history.pre-update-*.sqlite3` snapshot is kept. |

Verified on copies only (STORAGE-MONITOR-1.0.2-RELEASE.md §7): a 1.0.0-era history database and a 2.9 M-node 1.0.1 catalog migrate with every row preserved. A real upgrade on the MacBook Air has not been performed yet.

An ordinary update copies no history: its APFS-clone snapshot is discarded at commit when the schema did not change. When the update migrates the schema, one pre-update snapshot (`history.pre-update-*.sqlite3`) is kept and older ones are removed. Backups made by earlier versions (`history.install-backup-*.sqlite3`) are left untouched; delete them yourself if you no longer need them.

Failure and interruption:

- **A failure at any step** restores the previous helper and agents. Agents that were enabled before are registered again. A migration that changed the schema is undone only if no new agent had been started yet. From the first bootstrap a started agent may already have written history, so the database is kept (migrations are additive) and the snapshot is set aside as `history.pre-update-*.sqlite3`.
- **An interruption** (crash, kill, power loss) leaves the journal. Settings then reports an interrupted update; **Repair**, or any later install or uninstall, reverts it first.
- **After the agents were registered** the update is completed, never rolled back. From then on the agents may have written new history.

## Uninstalling

1. Settings → **Disable…**. This removes all three LaunchAgents and stops background work.
2. Quit, then move `/Applications/Storage Monitor.app` and `~/Applications/MacBook Storage Monitor.app` to the Trash.
3. Optional, and **irreversible**: delete `~/Library/Application Support/MacBook Storage Monitor` (history, install backups, inventory catalog).
4. Optional: remove Storage Monitor from Full Disk Access and Notifications in System Settings.

## Data preservation

| Data | Location |
|---|---|
| History, coverage and inventory catalog | `~/Library/Application Support/MacBook Storage Monitor/history.sqlite3` (mode 0600, directory 0700) |
| Pre-update snapshot, only when an update migrated the schema | `history.pre-update-*.sqlite3`; only the newest is kept |
| Backups from earlier versions | `history.install-backup-*.sqlite3`; never removed by install |
| In-progress install journal | `install-transaction/` (present only during an install or after an interruption) |
| Desktop-app preferences | the app's own defaults domain |

- Install, update, disable and uninstall never delete history.
- Schema migrations are additive and transactional.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Settings says monitoring needs repair | Choose **Repair** (finishes or reverts an interrupted update, then reinstalls the agents from the bundled helper) or **Disable**. |
| "This build does not include the background monitor" | You are running a development build (`scripts/build-gui.sh`). Use the DMG app or `bin/storage-monitor install`. |
| No new readings | Check `launchctl print gui/$(id -u)/local.macbook.storage-monitor` (read-only) and `~/Library/Application Support/MacBook Storage Monitor/monitor.log`. For downloaded ad-hoc builds, see Gatekeeper above. |
| No notifications | **Allow Low-Space Notifications…**, then check System Settings → Notifications → MacBook Storage Monitor. |
| Many inaccessible folders | Expected without Full Disk Access; see Permissions. |
| Disk inventory not advancing | Disk Inventory → Background indexing → Resume indexing. The first pass of a large disk can take hours. |
| Verify a DMG | `scripts/verify-dmg.sh build/dist/Storage-Monitor-<version>.dmg <version> <build>` |

## Verification status

For the 2.3.0 (build 17) controlled public test, see [its release notes](STORAGE-MONITOR-2.3.0-RELEASE.md). For the 2.2.0 (build 10) release, see [the release record](STORAGE-MONITOR-2.2.0-RELEASE.md) for automated checks, packaging verification and remaining native acceptance gaps.

Latest packaged build (2026-10-29): `build/dist/Storage-Monitor-2.2.0.dmg`, 15,673,130 bytes (14.95 MiB), sha256 `9464630294e5b4265a958b0b4f4e77f63ba2ce7b102ca28f4c3676339304ea04`.

- Version 2.2.0 (build 10), ad-hoc signed, universal, macOS 14+.
- All 25 noninteractive DMG checks passed, including 235 bundled monitor self-tests from the read-only image.
- Gatekeeper rejects the ad-hoc, unnotarized app. Native distribution GUI/installation and real launchd registration remain **NOT VERIFIED**; see the release record for the remaining acceptance gaps.

Historical development build (2026-10-23): `build/dist/Storage-Monitor-1.0.0.dmg`, 9,211,261 bytes (8.8 MB), sha256 `4f4c05cf0cfccb8027a1e39cc7f0f5240455289b630f1f2faf57d88af8ea4e87`.

- Version 1.0.0 (build 1), ad-hoc signed, universal, macOS 14+.
- `scripts/verify-dmg.sh` passes every check, including the bundled monitor's self-test (209 passed) run directly from the mounted image.
- Gatekeeper assessment of the ad-hoc app is `rejected`, as expected without notarization.


See `INVENTORY-VERIFICATION.md` for the latest results. Native GUI interaction (clicking Enable/Disable, dragging from the DMG) and real launchd registration were **NOT VERIFIED**. Agents must not focus windows or touch real LaunchAgents (see `AGENTS.md`). Installation behavior is verified against an isolated home with a recording launchd fake.
