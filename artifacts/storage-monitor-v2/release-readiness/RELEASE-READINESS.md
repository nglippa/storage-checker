# Storage Monitor V2.1 release readiness

Date: 2026-10-29. Branch `v2.1-rc`, HEAD `b43f8d5` (preserved: not amended, reset or rebased). This milestone's changes are uncommitted, for review.
Nothing was pushed, merged, tagged, packaged as a DMG, installed or released.

## Assessment: READY FOR PACKAGING

Every P0 safeguard is verified, including natively. The native acceptance session ran on 2026-10-29, 01:11–01:23, with operator approval. VoiceOver is PARTIALLY VERIFIED, and its gaps are listed below.

Two things to handle before packaging:

- **Commit.** This milestone's changes are uncommitted on `v2.1-rc` and need commit approval. Package from a committed tree.
- **Production preference written earlier.** Production `inventory.explorer.visualization` is still `tree`, written by the 2026-10-28 session (see below). Whether to restore it is the operator's call.

| Requirement | Status |
|---|---|
| P0-1 QA/production identity and preference isolation | VERIFIED (headless probe and native click-driven run with relaunch) |
| P0-2 Release version stamping | VERIFIED (from the built release bundle; the About panel itself not viewed) |
| P0-3 QA tooling cannot execute in Release | VERIFIED (compile-time exclusion, executed matrix, binary inspection, native launch of the identical release code with QA flags) |
| P1-4 Living Tree 3D label clicks | VERIFIED |
| P1-5 QA window identification | VERIFIED |
| P1-6 Dark mode and minimum window | VERIFIED (non-blocking findings below) |
| P1-7 VoiceOver | PARTIALLY VERIFIED (VoiceOver ran; navigation and labels confirmed; spoken output not captured) |
| P2-8 Storage-total correctness | VERIFIED |
| P2-9 Nonblocking work deferred | Done (listed below) |

## Release configuration

The configuration below was read from the built artifacts (`release-bundle-inspection.txt`).

| | Release app | Bundled helper | Development viewer |
|---|---|---|---|
| Built by | `STORAGE_MONITOR_APP_ONLY=1 scripts/build-dmg.sh` | (same) | `scripts/build-gui.sh` |
| Path | `build/dist/work/Storage Monitor.app` | `…/Contents/Helpers/MacBook Storage Monitor.app` | `build/Storage Monitor.app` |
| CFBundleIdentifier | `local.macbook.storage-monitor.viewer` | `local.macbook.storage-monitor` | `local.macbook.storage-monitor.viewer.dev` |
| Name | Storage Monitor | MacBook Storage Monitor | Storage Monitor Dev |
| Version (build) | 2.1.0 (9) | 2.1.0 (9) | 2.1.0 (9) |
| Signing identifier | `local.macbook.storage-monitor.viewer` (ad hoc, `--deep --strict` valid) | `local.macbook.storage-monitor` | `local.macbook.storage-monitor.viewer.dev` |
| Architectures | x86_64 arm64 | x86_64 arm64 | arm64 |
| QA preference suite | `local.macbook.storage-monitor.viewer.qa` (any build reading a QA database) | | |

**Version source.** `scripts/version.env` is the single version source, read by `build.sh`, `build-gui.sh` and `build-dmg.sh`. Environment overrides are still honored.

**Build number.** The build number has only ever increased: 1.0.6 (7), then 2.0.0 (8). The 2.1.0 local test DMG regressed it to 1, and that build is what is installed now: `/Applications/Storage Monitor.app` is 2.1.0 (1). Build 9 restores the order. The app keeps the production identifier, so it upgrades the installed app normally.

**About panel.** The About panel is the standard SwiftUI/AppKit panel, which reads these plist keys. It was not viewed natively.

`STORAGE_MONITOR_APP_ONLY=1` stops `build-dmg.sh` after the app is built and verified. The existing `build/dist/work` was moved to `build/dist/work-before-2.1.0-build9-20261029T051855Z` before the build, and `build/dist` still holds only its 7 earlier DMGs.

## Release isolation

**What depends on identity.**

| Resource | Production | Development | Notes |
|---|---|---|---|
| CFBundleIdentifier | `local.macbook.storage-monitor.viewer` | `local.macbook.storage-monitor.viewer.dev` | |
| Preferences domain | production | its own | |
| Saved window state | production | its own | |
| Caches | production | its own | |

Identifiers that stay shared on purpose, because they aren't keyed to the viewer's identity:

- The monitor helper (`local.macbook.storage-monitor`).
- The LaunchAgent labels (`local.macbook.storage-monitor*`), which only the production helper installs; QA builds never change them.
- The production history and catalog paths under `~/Library/Application Support/MacBook Storage Monitor/`. They are read-only in the viewer, and QA reads its `--database-path` copy instead.

The viewer uses no Keychain, App Groups or entitlements. The strict native-QA runtime keeps its own `…viewer.native-qa` identity and is unchanged.

**Code-level layer.** A build reading a QA database keeps every view preference in the QA suite, even if it is a production-identity build:

- All nine `@AppStorage` settings take `store: ViewerStore.viewPreferences`.
- The three direct `UserDefaults.standard` writes in the Cleanup Review queue now go through `ViewerStore.viewPreferences`.
- The performance script uses the same store.
- QA windows save no frame autosave and no restoration state.

**Install path.** `scripts/install-gui.sh` now installs only a release build with the production identifier. Before this change, it would have copied the dev build over the installed app.

### Preference-isolation evidence (`probe/`, headless)

`probe/PreferenceProbe.swift` is compiled from the real viewer sources, with only `@main` removed. It runs inside app bundles with chosen identifiers and activation policy `.prohibited`: it opens no window, takes no focus and sends no input. It changes the visualization, the two settings added in V2 (`treeNavigatorExpanded`, `event.showEvidence`) and the Living Tree dimension, through the same `@AppStorage` bindings the views use. It then exits and is relaunched. It never ran with the production identifier (`probe-run.log`):

- **Stand-in production identity with a QA database:** the settings were written to the QA suite, and the stand-in's own domain stayed byte-identical.
- **Development identity with a QA database:** the settings went to the QA suite and the dev domain was unchanged. A relaunch read `tree / true / true / depth` back from QA.
- **Stand-in production, normal launch:** it read its own established settings (`atlas / false / false / flat`), so production still recognizes saved preferences.
- **Control:** a normal launch that changes settings writes to the app's own domain. This shows the QA routing is what keeps QA writes out.
- **Production preferences file:** the same SHA-256 before and after (`4ab8a7be…`), and the same `defaults export` hash (`38889189…`).

The probe's QA-suite keys and the stand-in domain were removed afterwards.

**Production preference written by an earlier session.** Production `inventory.explorer.visualization` is `tree`. It read `atlas` before the 2026-10-28 native session, during which the dev build still had the production identifier and a "Living Tree" click wrote it. This is exactly the defect fixed here. The value has not been changed back; that is the operator's call.

## QA tooling activation matrix

Executed with the viewer sources compiled with and without `-D STORAGE_MONITOR_DISTRIBUTION`, the flag `build-dmg.sh` uses (`probe/activation-matrix.log`):

| Build | Database | Arguments | Log path honored | Script enabled | Log file created |
|---|---|---|---|---|---|
| Release | Production | none | no | no | no |
| Release | Production | `--perf-log --perf-script` | no | no | no |
| Release | QA | `--perf-log --perf-script` | no | no | no |
| Release | QA | none | no | no | no |
| Development | Production | `--perf-log --perf-script` | no | no | no |
| Development | QA | none | no | no | no |
| Development (authorized QA) | QA | `--perf-log /abs --perf-script` | **yes** | **yes** | **yes** |

**What distribution builds compile out.**

- The timing-log file output.
- The stall monitor.
- The QA argument parsing.
- The whole scripted navigation, leaving an inert `start()`.

Signposts remain; they are inert unless Instruments records them.

**Release binary inspection.** The release executable contains none of the scripted-navigation step literals (`storage_to_monitoring`, `monitoring_to_storage_tree`, `atlas_to_living_tree`, `script.launchReady`) nor the timing-log formats (`frame.committed …`, `main.stall …`). The dev executable contains all of them. Short literals such as `--perf-log` are stored inline in Swift code and can't be checked with `strings`. The optimized builds carry no symbols for these functions, so symbol counts read 0 in both.

**Trash in QA.** QA mode still sets `allowsTrash = false`. The only exception is the strict native QA runtime, whose repository anchor is compiled out of distribution builds. Cleanup and Trash-safety sources are unchanged since `b43f8d5`.

## QA window identification

- `ViewerIdentity.windowTitle` is the one source of the title. It is set on the shared root for both sections and on the window itself:
  - QA: "Storage Monitor — QA: catalog.sqlite3"
  - production: "Storage Monitor"
  - native QA: its own marker
- Tests cover production never being marked QA, and that `HistoryView` no longer sets its own title.
- The probe reported the QA title for a QA database and "Storage Monitor" otherwise.
- The dev app is now identifiable by exact bundle identifier (`…viewer.dev`) and name ("Storage Monitor Dev"), not by the name "Storage Monitor" alone.
- Native automation will check the frontmost bundle identifier with `lsappinfo` before every input, and stop on a mismatch. During this milestone it correctly reported Chrome as frontmost.
- Native Storage → Monitoring → Storage title persistence: VERIFIED on 2026-10-29 (see Native acceptance).

## Native acceptance (2026-10-29, `native/session.log`, `native/perf-run*.log`)

**Setup.** Dark appearance (app setting only), 1000×648 content (the minimum), a disposable catalog clone, and Trash disabled.

**Input guard.** Before every click or key, `native/front.sh` confirmed the frontmost app's exact bundle identifier. Two unexpected focus changes were handled:

- At the start, Chrome and Orca were frontmost. No input was sent until the dev app was frontmost.
- ⌘F5 opened the VoiceOver welcome dialog. It was inspected first, then only its "Use VoiceOver" button was clicked, within the approved VoiceOver scope.

No input reached any other app.

**P0-1, native.**

1. Launched "Storage Monitor Dev" (`…viewer.dev`) with a QA database.
2. Clicked Living Tree, Show Navigator, 3D, and Details and evidence. Each write landed in the QA suite (`tree`, `1`, `depth`, then `flat`, `1`), and the dev domain stayed empty.
3. Quit with ⌘Q and relaunched. The app came back in Living Tree with the navigator shown.
4. No Saved Application State was written for any Storage Monitor identity.

The production preferences file hash was `4ab8a7be…` and its `defaults export` hash `38889189…` at the start, after every click, after quitting, and at the end.

**P0-3, native.** The release app was copied and only its bundle identifier changed, to `…viewer.release-probe`, so production preferences were never at stake. Its unsigned executable is byte-identical to the release app's (`3aaead40…`).

It was launched with a QA database, `--perf-log` and `--perf-script`, and its main window stayed open for more than 30 s:
- No log file was created.
- No script step ran: the QA visualization stayed `tree`, where the script's first step sets `atlas`.
- Production was unchanged.

The QA title showed, and the QA suite settings applied.

**3D labels.**
- The Users label (large, 70%) selected Users. The Inspector showed 323.88 GB, 70% of Startup Data, the branch was highlighted, the label outlined, and the context stayed "Startup Data".
- The 27B label (small, 2%, deep under `Users/…/bonsai2-gguf`) selected 27B with its whole path highlighted.
- The private label, adjacent to Users, selected private and not Users.
- A drag that started on the Applications label turned the camera (Reset enabled), left the selection unchanged, and cleared a stray hover card.
- A click on empty space selected nothing new.
- Switching to 2D kept private selected and highlighted.
- The labeler places labels without overlap, so no overlapping pair was available; the adjacent pair was the closest case.

**QA window identity.**
- The title "Storage Monitor — QA: catalog.sqlite3" survived Storage → Monitoring → Storage (this used to revert to "Storage Monitor"), and it was correct after relaunch.
- The release-probe window showed the same QA title.
- The app names (Storage Monitor Dev, Storage Monitor Release Probe) and bundle identifiers are distinct from production.
- At minimum width with the event panel open, the toolbar shortens the title to "Storage Monitor —…", but the yellow "QA history · catalog.sqlite3" banner stays visible.

**Dark mode and minimum window.** All of these looked correct: readable, with nothing clipped or overlapping.
- The Storage landing screen.
- The Inspector.
- The treemap.
- Living Tree 2D and 3D.
- Cleanup Review: the disabled "Review plan…" button is visibly dimmed.
- Monitoring, including its empty state. The QA data is now more than 7 days old, so the empty state offered "Show Last 30 Days", which revealed all 29 events and enabled Clear Filters. The chart shows "No recorded capacity measurements in this chart range" for Last 7 Days. A dark chart with points was verified on 2026-10-28.
- Event selection: highlighted row, panel updates.
- The explanation, which states attribution uncertainty in text ("which app caused it was not recorded").
- Details and evidence: expands with its arrow turning and no overlap.
- ↓ after a row click moves the selection, and the panel follows.
- Settings: monitoring status loads; QA disables the actions.

**VoiceOver.** VoiceOver ran for about 2 minutes and was turned off with `killall VoiceOver`. Its caption panel was off (turning it on is another global setting), so spoken output was not captured. What VoiceOver read was taken from the cursor position plus the accessibility labels.

Storage:
- The VoiceOver cursor started on "Available now, 28.43 GB, Disk usage, 465.95 GB used of 494.38 GB" (one element).
- VO-→ moved in reading order through Startup Data, the status line, Indexing details, Disk details, Go to folder…, and Review Cleanup (a labeled button).
- Navigator rows have "Expand <name>" disclosure buttons.
- Every Living Tree branch is a button "<name>, folder, <size>", so size is text, not color or thickness.
- The tree group is "Living Tree of Startup Data", with a text note on what width means.

Monitoring:
- "Storage status" is a disclosure reporting Collapsed or Expanded.
- Explain, Filters (1) and Clear Filters are labeled buttons, and the column headers are buttons.
- Event cells read "Storage loss, Warning", so severity is text.

Not covered:
- Pressing a branch with VoiceOver, and returning to the parent with VoiceOver.
- Cleanup eligibility announcements: the QA data has no review candidates.
- Duplicate announcements as heard.

**Accessibility findings, non-blocking.**
- Living Tree buttons have no parent context: "models, folder, …" appears three times.
- The search field has no title of its own.
- Two different controls are both named "Visualization" (the Atlas/Living Tree group and the show-map toggle).
- Event cells have role `AXUnknown`.

**Responsiveness.**
- Run 1 (no VoiceOver): longest main-thread stall 197 ms, none over 250 ms.
- Run 2: one 481 ms stall at about 98 s, when the app became active again after the VoiceOver welcome dialog and VoiceOver attached. That probably means building accessibility elements for up to 3,000 tree branches; the cause is inferred, not proven. A section switch's first frame took 99 ms.

**Other findings, non-blocking.**
- With "All assessments" selected and nothing found, Cleanup Review still says "No suggestions on this page" and offers "See all assessments".
- A freshly identified app reopened with its Settings window open, a launch quirk of the QA identity.

## Verification

| Suite | Count | Previous |
|---|---|---|
| Viewer (default command `scripts/test-gui.sh`) | 911 passed | 883 |
| Monitor self-test | 235 passed | 235 |
| Inventory browser | 67 passed | 67 |
| Inventory integration | 350 passed | 349 |

**Default viewer command.** `scripts/test-gui.sh` now defaults its fixtures to a fresh `/private/tmp` folder. The old default (`build/qa-fixtures`) silently skipped the `/tmp` ↔ `/private/tmp` alias queue test, giving 882 tests instead of 883.

**New coverage.**
- 28 viewer tests in `tests/ViewerIdentityTests.swift`:
  - QA tooling matrix, 9 cases.
  - Distribution exclusion in the sources and in `build-dmg.sh`.
  - Preference domains.
  - Development and release identifiers, and the install guard.
  - Every `@AppStorage` routed, no direct writes to the standard domain, no QA frame or restoration state.
  - Window titles.
  - `version.env` as the single source, with the build number above 8.
- 1 integration test that compares the storage-totals query with the plain full scan it replaced on every run. The earlier 6,000-case randomized comparison is kept as `accounting-differential-fuzz.py`.

**Storage totals.** The query is unchanged. If it fails, the presentation gets `nil` and shows only the macOS figures, never zero totals.

**Performance (headless harness, same method, `performance/rc9-run*.json`).**
- Navigation transitions: medians are equal to or below the previous verified run in every case, e.g. Monitoring → Storage warm 99 ms (was 207 ms), open folder warm 67 ms (was 160 ms).
- RSS peaked at 102 MB (was 157 MB).
- No main-thread stall over 250 ms.
- Cold startup: 654 ms in the first run on a fresh catalog clone, then 200 ms on a rerun (earlier runs: 372 and 434 ms). The first figure is a cold-disk effect.
- Native timings were not re-measured.

**Build warnings.** One existing warning, `CleanupInspectorView.swift:174` (an implicitly strong `self` capture), predates this milestone and is untouched.

## Files changed (uncommitted)

**Modified:**
- `SourcesGUI/StorageMonitorApp.swift`: preference store; QA windows not restorable; title.
- `SourcesGUI/InventoryView.swift`: root title.
- `SourcesGUI/PerformanceTrace.swift` and `SourcesGUI/PerformanceScript.swift`: distribution exclusion.
- `SourcesGUI/CleanupReviewQueueView.swift`, `SourcesGUI/EventDetailView.swift`, `SourcesGUI/InventoryExplorerView.swift`, `SourcesGUI/LivingTreeView.swift`: preference store.
- `scripts/build.sh`, `scripts/build-gui.sh`, `scripts/build-dmg.sh`, `scripts/install-gui.sh`, `scripts/test-gui.sh`.
- `tests/GUIModelTests.swift`, `tests/InventoryReconciliationTests.swift`.
- `PACKAGING.md`, `README.md`.

**New:**
- `SourcesGUI/ViewerIdentity.swift`
- `scripts/version.env`
- `tests/ViewerIdentityTests.swift`

**Evidence (untracked):** `artifacts/storage-monitor-v2/release-readiness/`, plus the bench `prepare.py` adjustment and the `rc9-run*.json` results under `performance/`.

## Remaining risks

- **VoiceOver.** Spoken output was not captured, and Cleanup eligibility announcements were not exercised (no candidates in the QA data).
- **VoiceOver attach cost.** A possible ~0.5 s stall when VoiceOver first reads a large Living Tree.
- **Dev-build preferences.** The dev build no longer shares the installed app's preferences. Dev launches against the production history start with default view settings, by design.
- **Other runtime-gated QA arguments.** `--open-monitoring`, `--select-event`, `--show-evidence`, `--capture-window-path` and `--readiness-output` remain in distribution builds, gated at runtime by a QA database. They are read-only aids. `--capture-window-path` writes a PNG to the given path. They are not automation, but they are not compiled out.
- **Unsigned build.** The build is ad hoc signed and not notarized, so Gatekeeper rejects it on other Macs (as with earlier test builds).

## Deferred, not release blockers (P2-9)

- The accessibility findings above: branch path context, search field title, duplicate "Visualization" names, `AXUnknown` event cells.
- The wording of the Cleanup Review empty state with "All assessments".
- Chart point lookups.
- `LatestChange` recomputation.
- The Inspector's top-3 sort.
- The unused `OverviewView` helpers.
- A structured refusal-kind enum for Trash guidance.
- Any further Living Tree or monitoring features.
