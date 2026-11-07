# Migration Readiness — native QA plan

**Status: NOT EXECUTED. Every native GUI check below is NOT VERIFIED.**

Under AGENTS.md, launching the viewer activates its window and requires the user's explicit permission. No app was launched, focused or clicked during this milestone. Headless coverage is listed in REGRESSION-RESULTS.md and does not count as native acceptance.

## Permission request (to be granted by the user before any step)

- **Window that comes forward:** "Storage Monitor Dev" (bundle `local.macbook.storage-monitor.viewer.dev`, built by `scripts/build-gui.sh` into `build/Storage Monitor.app` inside the worktree), opened on a disposable QA catalog with `--database-path`. It is not the installed app and not the production catalog.
- **Duration:** about 20 minutes of the viewer in front, with the user present. Keyboard and mouse input goes to that window only while the user drives the steps (or watches an agent drive them, with explicit authorization).
- **Never touched:** `/Applications/Storage Monitor.app`, `~/Applications/MacBook Storage Monitor.app`, production LaunchAgents, `~/Library/Application Support/MacBook Storage Monitor/`, the running inventory worker, preserved snapshots.

## Fixture preparation (headless; safe to run any time)

```sh
WT=~/storage-checker-structured-explorer
QA=$(mktemp -d /private/tmp/storage-monitor-migration-qa.XXXXXX)
mkdir -p "$QA/tree/home/Library/Containers/com.docker.docker/Data/vms/0/data" "$QA/tree/home/.orbstack/data" \
         "$QA/tree/home/Parallels/Windows.pvm/harddisk.hdd" "$QA/tree/Backups/Old.sparsebundle/bands" "$QA/tree/docs"
# Sparse files: large logical sizes, almost nothing allocated (ftruncate). Uses python only to call ftruncate.
python3 - "$QA/tree" <<'PY'
import os, sys
root = sys.argv[1]
def sparse(rel, gib, written=4096):
    fd = os.open(os.path.join(root, rel), os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
    os.write(fd, b'Q' * written); os.ftruncate(fd, int(gib * (1 << 30))); os.fsync(fd); os.close(fd)
sparse('home/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw', 460, 64 << 20)  # 64 MiB written
sparse('home/.orbstack/data/data.img', 64)
sparse('home/Parallels/Windows.pvm/harddisk.hdd/harddisk.hdd.0.hds', 128)
sparse('docs/scratch.img', 3)
for b in range(4): sparse(f'Backups/Old.sparsebundle/bands/{b}', 0.0625)                    # 64 MiB bands
PY
"$WT/build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor" inventory-work --root "$QA/tree" --data-dir "$QA/state" --budget 60
```

Physical use: about 70 MB. Remove `$QA` afterwards.

The fixture's `home/Library/Containers` is not inside the real home folder, so the viewer checks it live. The "protected location, not checked" path is covered headlessly (catalog tests) and by step 9 on the real catalog, only if the user wants that.

## Launch (operator only, after permission)

```sh
STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk "$WT/scripts/build-gui.sh"
"$WT/build/Storage Monitor.app/Contents/MacOS/StorageMonitorViewer" --database-path "$QA/state/history.sqlite3"
```

## Steps and expected results

| # | Check | Steps | Expected | Status |
|---|---|---|---|---|
| 1 | Overview warning | Open the Storage section. Read the line under the status line. | "Migration readiness: 3 items to review · Docker Desktop disk image" (the fixture's Docker, Parallels and OrbStack images), with a warning icon. If the inventory is still measuring, "coverage limited" is appended. | NOT VERIFIED |
| 2 | Details popover | Click **Details**. | "MIGRATION READINESS", "3 items to review", Docker Desktop disk image with Logical size ≈ 494 GB, Allocated on disk ≈ 67 MB, Apparent gap ≈ 494 GB (measured, decimal units), "Potential migration compatibility issue", the explanation paragraph. Other items list Parallels, OrbStack and `scratch.img` (Informational). | NOT VERIFIED |
| 3 | Logical vs allocated | Compare the popover with the Storage header and the Explorer's sizes. | Header totals and Explorer node sizes show allocated sizes (MB), never the 460 GiB logical size. | NOT VERIFIED |
| 4 | Learn More | Click **Learn More**. | Container guidance bullets plus the three "always shown" statements; no delete, prune, compact or exclude advice. | NOT VERIFIED |
| 5 | Inspector details | Click **Reveal in Inspector**. | Explorer opens `…/vms/0/data`, `Docker.raw` selected; Inspector shows "Migration readiness" (Review), Category, Format "Raw disk image (from its name)", Likely application "Docker Desktop (from its location)", Logical, Allocated, Gap, Ratio, Virtual capacity "Unknown (the format is not parsed)", Filesystem APFS, "Checked on disk; matches the index.", the data-safety box. | NOT VERIFIED |
| 6 | Known virtualization identification | Select the `.hds` file and `data.img`. | "Parallels Desktop virtual disk" / "OrbStack disk image", each with application "(from its location)". | NOT VERIFIED |
| 7 | Migration Review visualization | Living Tree → Structured Explorer at the fixture root. Turn on **Migration Review**. | Dashed violet rings on the deepest shown node of each review path; unrelated branches (e.g. `docs`, `Backups`) fade; node sizes unchanged; footer adds "· N on migration review paths". | NOT VERIFIED |
| 8 | Path isolation | Select the `home` folder → path menu → **Isolate This Path**. | Only `home`'s subtree; review rings remain on its paths; `Backups` gone. | NOT VERIFIED |
| 9 | Reset | Click **Reset**. | Migration Review off, size All, Dim, focus off, isolation exited; previous selection restored. | NOT VERIFIED |
| 10 | Hide mode | Migration Review on, Nonmatches → **Hide**. | Only the paths to review items remain; hidden discs are not clickable. | NOT VERIFIED |
| 11 | Small-window responsiveness | Resize to the 1000 × 700 minimum; open the popover; scroll the Inspector; toggle Migration Review repeatedly. | Popover scrolls within 560 pt; filter row wraps to two lines; no clipped controls; no visible stall. | NOT VERIFIED |
| 12 | No cleanup actions | Inspect the popover and the Migration readiness section; expand "Cleanup & safety". | No delete, Trash, compact, prune, mount or exclude control in Migration Readiness. The existing Cleanup section behaves exactly as before this milestone. | NOT VERIFIED |
| 13 | VoiceOver | VoiceOver on: navigate the summary line, popover, Inspector section, explorer nodes. | Summary reads as one group; nodes on review paths end with "on a migration review path"; the toggle reads "Migration Review, On, N detected items". | NOT VERIFIED |
| 14 | Coverage note (optional, real data) | Only with explicit permission: open the dev viewer on a **clone** of the real catalog (`cp -c`, no journal). | If Docker Desktop's folder is protected for the monitor: "Docker Desktop is installed, but its storage folder is protected by macOS…"; never "No … discrepancies" without "coverage limited". | NOT VERIFIED |

## After QA

Quit the dev viewer, `rm -rf "$QA"`, and record outcomes (pass/fail, notes) in this file. Personal paths in screenshots must be redacted (the panel's hover help already shows `~` paths).
