# UX refinement and cleanup reliability — 2026-10-27

Uncommitted working-tree changes on `master` (base `6218eba`). No install, package, commit or push. Status per requirement: **VERIFIED**, **PARTIALLY VERIFIED**, **NOT VERIFIED**.

## Move to Trash: why eligible items were refused

Reproduced read-only by running the production `CleanupTrashPolicy.prepare` (tokens cancelled, nothing executed) on 38 real user folders and on disposable `/private/tmp` fixtures. Before: 14/38 eligible; after: 27/38.

| Cause | Kind | Fix |
|---|---|---|
| The Trash preflight walked every descendant inside the Inspector's quick evidence budget (4,000 entries, 24 reads, 1.2 s). A 3,000-file folder failed on time. | Budget too small for the job | `ArtifactProbe.Budget.trashPreflight` (150,000 entries, 4,000 reads, 20 s) for prepare and for the revalidation before the system call. Every per-entry check still runs. |
| `holdsOpen/runs/works(within:)` resolved every observed open file (≈3,800) with `realpath` for every descendant, so the walk ran at ≈150 entries/s. | Performance defect | `ProcessObservation.scoped(within:)` keeps only observations related to the target. Anything related to a descendant is related to the target, so results are identical. 3,000 entries: >20 s → 0.54 s. |
| Process observation is never `complete` on a normal Mac (182 other-user processes unreadable; Chrome and others exceed 512 descriptors). Any folder containing an executable or database was refused permanently. | Policy | **User-directed change:** observed use still hard-blocks. Partial observation of programs or databases now requires the explicit `programUseWarning` acknowledgment instead of blocking. |
| Any unresolvable open-file path anywhere (e.g. a system service's `/var/db/biome/restricted` store) refused every database-containing item. | Incorrect classification | `openFileMatchesDatabase`: an unresolvable path can only match when it is beside the database. It fails closed there and is irrelevant elsewhere. |
| The Node detector listed `node_modules` with a 64-entry limit to look for install records. The truncation note was read as missing safety evidence. | Evidence defect | Look the records up by exact name; `ArtifactProbe.readable` keeps the unreadable-folder signal. |

Still refused, correctly: items in use by a running process, credential-protected content, a `.venv` whose interpreter link points at a running Python, folders over the 20 s budget (one 39,693-entry `node_modules`), QA builds (catalog copy).

Refusals now show a plain-language kind and next step (`CleanupTrashGuidance`) beside the exact reason.

## Other changes

- **Landing screen:** every launch opens on **Storage** (the disk inventory), never restored from saved state. Section labels are now *Storage* and *Monitoring*. QA-only `--open-monitoring` is a capture aid.
- **Storage header:** available space with a usage bar answers "how much do I have" first. **Review Cleanup** and **Back to Explorer** buttons replace the menu-only route to review.
- **Monitoring:** order is now status → *Latest notable change* (plain sentence, certainty, Show Details) → chart → *All recorded changes*, with filters in one row and a popover. The duplicate severity badge is gone. The live-vs-recorded line is plain language; its technical qualifier is in help.
- **Event panel:** *What happened / What may explain it / How sure is this? / What you can do* are built only from `EventAnalysis` (`EventPlainSummary`). The existing measured changes, breakdown, evidence and technical sections sit under one *Details and evidence* disclosure. Attribution calculations are unchanged. A measured volume change is "measured", a same-interval change is "not established", and no evidence is "unknown". The app responsible is always "not recorded".
- **Living Tree:** larger controls, separate **Fit to Content** and **Reset View (0)** (the fit button previously carried the reset shortcut), an **Up one level** button beside the path, a **Selected: name · size** indicator, and a **How to Navigate** popover. Every action has a visible control; drags never select.

## Verification

| Requirement | Status | Evidence |
|---|---|---|
| Fresh launch opens Storage | VERIFIED | Native window capture, dark and light |
| Monitoring reachable, clearer hierarchy | VERIFIED | Native window capture |
| Plain summary accuracy | VERIFIED (model) | 11 new viewer assertions: measured, partly measured, unknown, first reading, unattributed Data growth, latest-change rule |
| Event panel in the native window | PARTIALLY VERIFIED | Offscreen renders (dark, light, evidence expanded). Native captures with an event selected failed twice (Stage Manager) and were not retried |
| Living Tree controls visible and labelled | VERIFIED (render) | Native window capture of the controls; offscreen render of a selection. Clicking them natively: NOT VERIFIED (no input sent) |
| Small window sizes | NOT VERIFIED | `--window-size 1000x700` captures did not complete |
| Eligible cleanup works | VERIFIED (headless, real Trash) | Disposable 5,050-file folder, folder with a program, folder with a database, single file moved via real `FileManager.trashItem`; identity, contents and source absence checked; cancel and declined warning moved nothing. The four fixtures remain in the user's Trash |
| Protected targets stay blocked | VERIFIED (model) | Existing safety suite passes; observed running executables, aliases, open WAL/companions and protected roots still block |
| Native confirmation sheet, keyboard/VoiceOver, Finder Put Back | NOT VERIFIED | Requires desktop input |

Automated: viewer model **833 passed** (804 before; fixtures under `/private/tmp`, see note), inventory model **67**, inventory **349**, monitor self-test **235**, monitor build OK.

Note: `scripts/test-gui.sh` with its default fixture folder under `build/` fails "active database alias blocks its -wal companion". That test needs the `/tmp`↔`/private/tmp` alias and passes with a `/private/tmp` fixture argument. This was pre-existing and is unrelated to these changes.

## Remaining

- The Trash confirmation sheet repeats "not established as safe" in several warnings; it needs a copy pass.
- Preparing a 30,000–40,000-entry folder takes 8–13 s with only a small spinner, and revalidation repeats the walk inside the 60 s confirmation window.
- Finder Put Back, the native sheet, keyboard and VoiceOver, and small-window layouts need a native operator pass.
- The Storage header still shows the technical accounting line ("indexed sizes exceed the Data volume by …").

## Final acceptance and Trash safety review — 2026-10-28

### Independent review
- **Reviewer:** a Claude Sonnet subagent, read-only. This is **not cross-model**: the user declined sending code to Codex.
- **Result:** no blockers.
- **Findings acted on:**
  - Symbolic-link descendants: the scoped walk missed working directories inside a link's target. The link check now also tests `works(within:)`, and the doc comments were corrected.
  - The "unresolvable unrelated path" test actually resolved. It now uses an ELOOP link, and an assertion proves the path is unresolvable.
  - An unresolvable path named like the database or a companion now fails closed in any folder.
  - "Complete" process observation covers only the current user's processes. The program/database warning is therefore shown whenever the item contains programs or databases, as one merged line instead of two stacked warnings.
  - `perform` refused confirmations held for more than ~40 s on large folders. The post-revalidation check is now bounded by the revalidation's own duration (budget + 5 s). The 60 s decision window is unchanged.
  - Fixed doc-comment placement.
- **Not changed:**
  - Case and Unicode-normalization differences in folder comparison. This is pre-existing and also affects the resolvable branch.
  - Hard-link aliases behind EACCES. These are low likelihood because only the current user's descriptors are observed.

### Large-folder timeout
The 39,693-entry `node_modules` now completes in about 14 s; previously it ran past the 20 s limit. Two causes, both fixed without removing checks:
- **Repeated path resolution.** The Node detector queried `holdsOpen/works(within:)` against ≈3,800 observed paths for every nested package, resolving each with `realpath` on every call. `ProcessObservation` now resolves each observed path once per observation (a point-in-time snapshot) and the query path once per call. The answers are identical.
- **A truncated listing.** A 400-entry sibling listing of pnpm's `.pnpm` store was read as missing evidence. Lockfiles and manifests are now looked up by exact name.

Capped listings that feed safety facts (PATH) or need full contents (`__pycache__`) are unchanged.

Read-only survey of the same 38 real folders: **30/38 eligible** (from 14 at the start). The remaining refusals are processes actually using the folder (4), a venv interpreter link in use (2), credential protection (1), and an unresolvable link target (1).

### Usability fixes
- **Confirmation sheet:**
  - one plain title, and one "Storage Monitor has not confirmed that this is safe to remove." with the specific reasons, de-duplicated (`CleanupTrashGuidance.presentedWarnings`)
  - one "About Move to Trash" paragraph
  - a checkbox that states what it acknowledges
  - the policy's warning strings are unchanged
- **Preparation progress:** "Checked N of about M items…", where M is the inventory's indexed count, labelled "about". There is a **Stop** button. No percentage is shown.
- **Storage header:** "Files found: … · more than the disk reports, because copies that share storage count once per file". The exact rows stay in Details.

### Native acceptance

| Check | Status | Evidence |
|---|---|---|
| Confirmation sheet presentation, simplified text | VERIFIED | Real sheet component in a native harness window (`Trash Sheet Harness`, disposable `/private/tmp/sm-putback*`). The full app's sheet is unreachable: QA viewers block Trash by design and the strict QA runtime is marked do-not-launch (`QA-WORK-STOPPED.md`) |
| Cancel (Esc and Cancel button) | VERIFIED | Token cancelled, file unchanged (harness log) |
| Decline warning | VERIFIED | Move to Trash stays disabled (AX `enabled=false`). Return and clicking the disabled button do nothing |
| Accept and move | VERIFIED | Folder with a program and a 10,000-file folder moved to `~/.Trash` via the real token path |
| Finder Put Back | VERIFIED | `sm-putback-large` restored to `/private/tmp/sm-putback2/` with the same inode (50267838) and all 10,000 files |
| Keyboard | PARTIALLY VERIFIED | Esc cancels and Return does not confirm. Tab does not reach the checkbox with the system Keyboard Navigation setting off, which is standard macOS behaviour; the setting was not changed |
| VoiceOver/AX basics | PARTIALLY VERIFIED | AX tree exposes labelled buttons and checkbox, with the disabled state. No VoiceOver session was run |
| Progress text | PARTIALLY VERIFIED | Initial "Checking every item inside…" seen natively; a 10,000-item folder finished before the first count report. Counts are covered by an automated test |
| Living Tree clicks (zoom, fit, reset, up, selection), Monitoring with a selected event, small window | BLOCKED | Stage Manager plus focus contention kept the QA window in the strip. `focus_window` by app name also activated the user's own dev viewer once (no input sent), and automation was stopped |
| Light/dark | VERIFIED earlier (window captures, 2026-10-27) | `scratchpad/live/after/` |

The harness's own progress label once enumerated the folder while it was being prepared. The final re-observation refused the move ("A process started using the target during validation"). That was the check working as intended; the harness was fixed. The Inspector does not enumerate targets.

### Regression results (final code)
- Viewer **841** (with a `/private/tmp` fixture folder).
- Monitor build OK.
- Inventory model **67**.
- Inventory **349**.
- Monitor self-test **235**.

**Known issue, reported separately:** `scripts/test-gui.sh` with its default `build/qa-fixtures` folder stops at "trash safety: active database alias blocks its -wal companion" (exit 133). The test builds a `/tmp`↔`/private/tmp` alias of the fixture path, which a folder under the home directory does not have. This is pre-existing and fixture-location dependent, not caused by these changes, and it hides every assertion after it in that run.

### Disposable items left in the user's Trash
`large-cache`, `tool-env`, `app-cache`, `old-export.log` (2026-10-27) and `sm-putback-folder`. Nothing was emptied or permanently deleted.

## Native viewer acceptance attempt — 2026-10-28 (stopped)

Procedure:
- The QA viewer (scratch build from current source, bundle `local.macbook.storage-monitor.viewer.tour`) ran on a disposable catalog clone, 1000×700, dark.
- It was identified as PID 82333 and window 60263. Controls were read by PID only, never by application name.
- Stage Manager was recorded as on, turned off for the session, and restored to on.
- The QA preferences were backed up and restored byte-identical.
- The user's development viewer (PID 77575) was not activated, sent input, terminated or modified.
- No Trash operations were run.

Stopped after launch. The window's search field had received keystrokes the operator was typing in another app ("PT" appeared in "Search name or path prefix"), so focus contention was active and the brief required stopping. No click or key was sent to the QA window.

| Check | Status |
|---|---|
| Living Tree zoom, Fit to Content, Reset View, Up one level, folder selection by click | BLOCKED (focus contention; stopped before interaction) |
| Monitoring explanation panel with a selected event | BLOCKED. A native capture exists from 2026-10-27 (`scratchpad/live/after/after-03`, `after-04`), but it was not interaction-tested |
| Small-window layout, dark | PARTIALLY VERIFIED: the 1000×700 window opened and was captured (`scratchpad/live/final/01-tree-dark-small-initial.png`); no interaction |
| Small-window layout, light | BLOCKED |
| Keyboard | BLOCKED for the viewer. The confirmation-sheet results above stand |

### Release blockers
1. **Launch focus captures typing.** On launch, Storage's "Search name or path prefix" field becomes first responder: there is no focus control in `InventoryView.swift`. Keystrokes reaching the window then go into search. Observed natively on 2026-10-28. Monitoring's search field behaves the same way. It should not take initial focus.
2. **Native interaction evidence is missing** for the Living Tree controls, the Monitoring panel with a selected event, small-window light layout, and viewer keyboard use. These need an operator-attended session with nobody typing.
3. **The full-app Move to Trash sheet is unreachable in QA builds by design.** Only the sheet component was verified natively. A production-mode check would need operator authorization and disposable items in the real inventory.
4. **The default-fixture viewer test run stops early.** See the known issue above: the `/tmp` alias test masks later assertions under `build/qa-fixtures`.

### Retry — 2026-10-28 (stopped)
Same procedure:
- QA viewer PID 99288, window 60299
- Stage Manager recorded as on, disabled, then restored to on
- QA preferences restored byte-identical
- development viewer untouched
- no Trash operations

Within 16 s of launch the QA window had become frontmost, and its Storage search field held text the operator was typing in another app. Testing stopped before any interaction. All checks remain **BLOCKED**. This confirms release blocker 1, launch focus capturing typing, and it captured user text twice.

## Launch focus fix and native viewer acceptance — 2026-10-28

**Fix:** `WindowSetup` in `StorageMonitorApp.swift` now releases text-field focus that AppKit or SwiftUI assigns automatically while the window opens. It does this for 3 s, or until the person clicks or uses a ⌘ shortcut. Native check: the window was frontmost at launch and the search field was empty and unfocused, in both appearances. This resolves release blocker 1.

**Procedure:**
- QA viewer, scratch build from current source, bundle `local.macbook.storage-monitor.viewer.tour`, disposable catalog clone.
- Sessions: PIDs 6662, 18151 and 20261. Controls were read by PID through the accessibility API, and clicks went only to that window.
- Stage Manager was recorded as on, disabled for the session, and restored to on.
- QA preferences were restored byte-identical.
- The development viewer (PID 77575) was untouched.
- No Trash operations.

Screenshots: `scratchpad/live/final/`.

| Check | Status | Evidence |
|---|---|---|
| Zoom In / Zoom Out (clicks) | VERIFIED | 100% → 150% → 100% → 225% |
| Fit to Content | VERIFIED | 225% → 100%; Fit/Reset then disabled |
| Reset View | VERIFIED | In 3D at 150% → fitted standard view; buttons disabled |
| Folder selection | VERIFIED | Clicking the Users branch shows "Selected: Users · 313.2 GB", lights the path, and Inspector and Navigator match |
| Open folder / Up one level | VERIFIED | Double-click opens (breadcrumb Startup Data › Users); Up returns and disables itself at the top |
| Tree keyboard | VERIFIED | Return opens, Esc goes up, I toggles Isolate. The `+` key could not be sent by the tool |
| Help popover | PARTIALLY VERIFIED | Opens and closes by its button. Esc does not close it, and its last line is truncated |
| Monitoring panel with selected event | VERIFIED | Show Details, and clicking a row (Oct 21 23:00) update the panel; Details and evidence expands |
| Small window 1000×700, light and dark | PARTIALLY VERIFIED | Storage fits in both. Monitoring pushes the event list completely below the window in both |
| Monitoring keyboard | PARTIALLY VERIFIED | After clicking a row, Down arrow does not move the selection; the row shows the inactive (grey) highlight |
| VoiceOver/AX basics | PARTIALLY VERIFIED | Every control and tree branch is exposed with a label ("Users, folder, 313.2 GB"). No VoiceOver session was run |

### Remaining release blockers
1. **Monitoring at the minimum window size (1000×700) hides the event list.** Overview, latest change and chart take the whole height, so events can only be reached through Show Details.
2. **Event-list keyboard navigation fails after a click:** opening the panel appears to take focus from the table.
3. **The full-app Move to Trash sheet is unreachable in QA builds** by design; only the component was verified natively.
4. **The default-fixture viewer test run stops at the `/tmp` alias test** and masks later assertions.

Minor:
- The help popover ignores Esc and truncates its last line.
- Only the triangle of "Details and evidence" is clickable, not its label.
- When volume changes offset each other, the explanation names only the growing volume (e.g. +3.22 GB virtual memory for a −1.98 GB loss).

## Final blocker repair — 2026-10-28

| Issue | Root cause | Fix |
|---|---|---|
| Monitoring event list hidden at 1000×700 | Overview, latest change and chart sat in one `VStack` with the table. Their natural height (~480 pt) exceeded the ~640 pt content, so the table got none | `HistoryView` measures the summary's natural height. Its scroll area is that height when it fits; otherwise it is capped at the content height minus `eventListReserve` (270 pt), so the list keeps ≥ 6 rows. An earlier `ViewThatFits` attempt clipped the chart at 1440×900 and was replaced |
| Event list loses keyboard focus after a click | Opening the inspector rebuilds the split view and takes first responder from the table | `@FocusState` on the table. If it loses focus within 0.5 s of a selection made in the list, focus returns. Later focus changes (a deliberate click elsewhere) are kept. Esc still closes the panel and keeps the selection |
| Startup focus used a 3 s timer | Timing heuristic | Event-driven. Until the first deliberate interaction in this window (click, ⌘ shortcut or Tab), automatic first-responder moves into a text field are undone as they happen: KVO on `firstResponder`, plus a did-become-key fallback. Uses an app-local event monitor (returns events unchanged); all observers stop after that interaction |
| Offsetting volume changes | The explanation named only the driving volume | `EventPlainSummary` appends "At the same time, ⟨volume⟩ freed/used X, so the net loss/gain was Y", for offsets ≥ max(10 MB, 1% of net). Measurements, attribution and certainty are unchanged |
| Help popover | The tree's Esc handler went up a level, and text lines had no vertical growth | Esc closes the popover first; `.onExitCommand` added; help texts wrap |
| Disclosure label | Only the triangle toggled | The label toggles too, with full-width hit area; accessibility hint kept |
| Default test fixture | Trash safety fixtures were placed next to `build/qa-fixtures`, which has no `/tmp` alias | The safety suite now always uses a unique `/private/tmp` root, as `NativeQARuntimeTests` already did. The assertion is unchanged |

### Verification
- **Headless native QA** (`scratchpad/headless/`): real views in windows never ordered on screen, activation prohibited, synthetic events to those windows only, disposable catalog clone.
  - 20 checks pass:
    - event list ≥ 6 rows at 1000×700, dark and light
    - summary scrolls there, and is shown in full (482/482 pt) at 1440×900
    - selecting a row opens the panel and the list keeps focus
    - Down/Up move between events and the panel follows
    - Esc closes the panel and keeps the selection
    - no text field focused at launch; automatic Search focus is released; stray typing does not reach Search; ⌘ shortcuts and clicks count as deliberate
  - Not testable headless: the click into Search, the disclosure label tap, and the help popover. Synthetic mouse events do not reach never-shown windows, and popovers are not presented from them.
- **Native, real window** (2026-10-28):
  - Monitoring at 1000×700 dark shows 8 event rows. That was an earlier layout revision; the final layout guarantees ≥ 6.
  - The search field was not focused at launch.
  - The native session stopped because the operator was actively using other apps.

### Final results (final code)
- Viewer suite, **default command** `scripts/test-gui.sh` (`build/qa-fixtures`): **846 passed, exit 0**. The run is complete; the alias failure is fixed.
- Viewer suite with a `/private/tmp` fixture folder: **847 passed, exit 0**. The extra test is a review-queue `/tmp` alias case that runs only when the queue fixtures are under `/private/tmp`. It is skipped by default, not failed.
- Monitor build OK; inventory model **67**; inventory **349**; monitor self-test **235**.
- Headless native QA: **20 passed, 0 failed, 3 not testable headless**.

### Remaining blockers
1. **Not yet seen in a real window**, because the operator was active and headless cannot cover them:
   - a click into Search right after launch
   - the "Details and evidence" label tap
   - Esc on the Living Tree help popover, and its full text
2. **The full-app Move to Trash sheet is unreachable in QA builds** by design; only the sheet component was verified natively.
