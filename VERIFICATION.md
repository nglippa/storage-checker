# Verification report — 2026-10-21

Status: **installed and running; native notification delivery verified from launchd**.

Host: macOS 27.0 (26A428), Apple Silicon, user UID 501. Built with the installed Apple Swift 6.4/macOS SDK, in Swift 5 language mode, using Foundation, AppKit, UserNotifications, SQLite3, and Darwin. There are no downloaded runtime dependencies.

## Installed service and persistence

- App: `~/Applications/MacBook Storage Monitor.app`.
- Agent: `~/Library/LaunchAgents/local.macbook.storage-monitor.plist`.
- Job: `gui/501/local.macbook.storage-monitor`.
- Final `launchctl` status: loaded, idle between checks, `runs = 1`, `last exit code = 0` after final installation's actual RunAtLoad check.
- Installed plist independently inspected with `plutil`: `RunAtLoad = true`, calendar minutes `0` and `30`, absolute app executable and data path, background/low-priority I/O, umask `077`, stdout/stderr `/dev/null`. There is no second independent interval schedule.
- Repeated installation/replacement succeeded and preserved existing SQLite measurements, alert acknowledgements, and notification permission.
- `codesign --verify --strict` passed for the installed app.
- File permissions verified: data directory `0700`; SQLite DB, operational log, and LaunchAgent plist `0600`.

The LaunchAgent is configured to load automatically at the next login after restart. Calendar checks missed during sleep coalesce on wake. **The Mac was not rebooted, and a real sleep/wake cycle was not performed.** Monitoring runs in the logged-in user's session; no checks run while powered off/asleep/logged out. This is the normal per-user launchd lifecycle.

## Real storage readings

The initial actual launchd check at **2026-10-21 07:14:06 UTC** recorded:

| Field | Value |
|---|---:|
| Internal APFS container UUID | `FED7A55E-D74B-4F32-93D9-0D4EB5A52FBE` |
| Container capacity ceiling | 245,107,195,904 bytes |
| Free physical container capacity | 23,857,352,704 bytes (23.86 decimal GB) |
| Used physical container capacity | 221,249,843,200 bytes (221.25 decimal GB) |

The final snapshot's actual reading at **2026-10-21 07:21:35 UTC** recorded **22,673,534,976 bytes free (22.67 GB)** and **222,433,660,928 bytes used (222.43 GB)**. APFS volume allocation was stored, including Data, System, Preboot, Recovery, Update, and VM. Every selected physical store passed the internal-storage check.

The host was already below the 25 GB warning threshold. This is real machine data, not a threshold simulation or fabricated growth alert. After enabling notifications, the actual low-space warning was delivered. Later unchanged low-space checks printed `notification=deduplicated`, with no additional low-space alert record. The history DB passed `PRAGMA integrity_check` (`ok`); after verification it occupied 114,688 bytes. The native executable occupied 252,208 bytes.

## Notifications

Initial authorization was not determined, and then denied. The user enabled this app in System Settings → Notifications. Final status was **`authorization=authorized alert=2 center=2`** (`2` means enabled). No permission database, TCC configuration, or notification preferences were modified programmatically.

Delivery was confirmed by querying `getDeliveredNotifications` for each exact generated identifier:

| Context | Confirmed identifier/result |
|---|---|
| Direct installed bundled app test | `ACE8DDF4-B758-4CF1-B922-CCC9EF8343C5` |
| First real one-shot per-user LaunchAgent test | `E9E6249C-793C-4C65-BC10-E83E24EB0110`, exit 0 |
| Actual low-space warning after permission enabled | `DD84CBBE-4B71-4DE6-9257-7240B7799511` |
| Repeated one-shot LaunchAgent test of **final rebuilt installed app** | `C59B4A80-C996-4253-93F5-0873FD5DF1E5`, `runs = 1`, exit 0 |

The temporary test job was unloaded and its own temporary files removed after each probe. Monitoring's permanent job remained loaded. Initial permission failures and the later successful actual warning remain in the alert log. Only confirmed delivery acknowledges a condition; failure/unconfirmed outcomes stay pending for a bounded retry. `check --retry-notifications` was exercised to deliver the pending actual warning immediately after the user enabled permission.

**Notification Center delivery is proven. Banner visibility, sound, Focus behavior, and the user's subjective observation were not independently verified.** macOS notification preferences can affect those presentation details.

## Automated tests

Final `bin/storage-monitor self-test`: **37 passed**, using isolated temporary SQLite files. Coverage:

- Exact and just-below 3 GB previous-reading and 5 GB/two-hour boundaries.
- Inclusive two-hour window, excluded older readings, and container isolation.
- Strict 25/15 GB low/critical boundaries and first-reading low detection.
- The production `AlertPlan` logic across actual SQLite reopen transitions: low plus growth, growth resolving while low persists, critical escalation, recovery/rearm, denial pending, retry cooldown, successful retry deduplication, and container replacement.
- Thirty-day expiry in measurements, alert records, and diagnostic snapshots, including the retained exact age boundary.
- LaunchAgent plist serialization with spaced absolute paths, one calendar schedule, login startup, and wake catch-up fields.
- Nonblocking execution lock against a second overlapping holder.
- Subprocess deadlines, continuous-output deadlines/capture caps, and preserving stdout totals despite noisy bounded stderr.

Build completed without compiler warnings. `git diff --check` passed. No commits or pushes were made. Existing `.serena` and `graft` content was preserved.

## Diagnostic verification

Two explicitly requested read-only snapshots were collected; the final snapshot was **30,840 bytes**. The second verified separate bounded stdout/stderr captures preserve `du` totals even when permission errors fill the error capture. No command timed out in that snapshot.

| Scope | Apparent logical size (KiB) | Ordinary `du` block estimate (KiB) | Qualification |
|---|---:|---:|---|
| `/private/var/folders` | 2,350,905 | 2,333,672 | **Partial**: macOS denied some paths; errors captured/truncated explicitly |
| `~/Library/Application Support` | 15,326,163 | 15,685,252 | Commands exited 0 |
| `~/Library/Caches` | 3,325,068 | 3,475,288 | Commands exited 0 |
| Chrome `X/com.google.Chrome.code_sign_clone` under the user's var/folders tree | 1,472,289 | Not separately requested for clones | Found and logical size read successfully; discovery elsewhere in var/folders was partial |
| Claude Desktop `~/Library/Application Support/Claude/claude-code-vm` | 258,427 | 258,436 | Commands exited 0; two other known VM locations absent/inaccessible |

`vm_stat` was captured, and `vm.swapusage` reported total 4096.00 M, used 3249.12 M, free 846.88 M (encrypted). The diagnostic's secondary raw APFS-list command hit its output capture limit and is flagged `truncated`; the primary physical-container values and full selected-container volume allocation are separately present in the snapshot and reading.

These rows **must not be added together** or interpreted as exclusive physical container allocation. Apparent sizes and block estimates differ from APFS accounting because of shared extents, clones, sparse files, compression, snapshots, and filesystem metadata. Permission-denied totals are lower-bound partial observations. No extra permissions were granted to inspect protected paths.

## Performance and safety

One real routine check measured with `/usr/bin/time -l`: **0.85 seconds wall**, 0.07 seconds user CPU, 0.17 seconds system CPU, maximum resident set **12,812,288 bytes (~12.2 MiB)**, peak reported footprint 4,375,128 bytes, and zero process swaps. It read APFS plists and SQLite without directory scans. A single sample is an observation, not an enduring upper bound on a busy Mac.

Monitoring uses no network code or telemetry. All system utility calls use absolute paths and argument arrays without a shell. Only this monitor's own user-scoped app, agent, bounded logs/history, and temporary verification artifacts were written. No root/sudo commands, privileged daemon changes, APFS snapshot changes, update-setting changes, user-file cleanup, application termination, or Claude Code/Codex session manipulation occurred. Timeouts terminate only child diagnostic/system utility subprocesses started by the monitor.

## Supplied app icon — installed 2026-10-21 07:29 UTC

The user's supplied 1254×1254 PNG was preserved byte-for-byte as `Assets/AppIcon.png`, SHA-256 `1dec82a9aa5832909f117abeefb240c005792c693e6795634d4d1fe7b8a94e95`. Its artwork, background, framing, and colors were retained. Generated output adds opaque alpha and resizes to all ten standard macOS icon representations from 16 to 1024 pixels. `CFBundleIconFile=AppIcon` and `Contents/Resources/AppIcon.icns` are present in the actual installed app, which was reinstalled and registered with LaunchServices. No monitoring source code changed for this icon update.

This host's `iconutil` rejected correctly named/sized PNG iconsets, including an RGBA normalization attempt. The reproducible build therefore uses a small native fallback that writes the standard ICNS container with ten PNG chunks, validates dimensions and AppKit decoding, and then signs the app. The resulting installed ICNS and built ICNS have the same SHA-256: `0ee0a5d7cc3fa0cc88f4ede9764cecf94ed8bfc39c812b350eeee638b2a67a64`. `codesign --verify --strict` passed after installation.

The installed resource was independently decoded by `sips` to `build/icon-preview/direct-resource.png` at 1024 pixels, and visually inspected alongside `build/AppIcon.iconset/icon_32x32@2x.png` at 64 pixels. Both match the supplied artwork, including its background.

`NSWorkspace.icon(forFile:)` returned 32 lazy `NSISIconImageRep` representations but blank pixels from both drawing and TIFF export. A built-in Calculator app control also returned blank pixels, so the renderer issue is not specific to this app's resource. **Finder/IconServices rendered appearance could not be verified from this command-line host.** No broad icon-cache reset, Finder/Dock restart, or system change was attempted. `tests/verify-icon.swift` explicitly reports blank rendering and exits 2 rather than claiming visual verification.

After the icon-bearing signed bundle was installed, the permanent LaunchAgent remained loaded with `runs=1`, last exit 0, notification authorization remained enabled, and a fresh real launchd notification was confirmed delivered with identifier `75FDBFE2-EF25-47D5-9075-C85AD2EAF6CB` (test exit 0). Its RunAtLoad check recorded 22.16 GB free at 07:29:18 UTC and deduplicated the already acknowledged low-space condition. No commits or pushes were made.
