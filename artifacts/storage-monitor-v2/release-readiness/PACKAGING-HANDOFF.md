# Storage Monitor 2.1.0 (9): packaging handoff

This file prepares the next phase, a separately authorized DMG build and installation-validation pass. Nothing has been packaged, signed for distribution, notarized, installed, pushed or tagged. Full evidence is in [RELEASE-READINESS.md](RELEASE-READINESS.md).

## 1. Source and version

| | |
|---|---|
| Branch | `v2.1-rc` (local only, not pushed) |
| HEAD | `873e069` Harden V2.1 release: isolate QA identity, stamp 2.1.0 (9), compile QA tooling out of release |
| Parent | `b43f8d5` Storage Monitor V2 release candidate (preserved) |
| Version | 2.1.0, build 9 (`scripts/version.env`; the app and bundled helper both carry it) |
| Working tree | Clean except untracked `.DS_Store`, `artifacts/`, `docs/` (deliberately not committed) |

**Build number.** It has only ever increased: 1.0.6 (7), 2.0.0 (8), 2.1.0 (9). The installed `/Applications/Storage Monitor.app` is the 2.1.0 build 1 local test DMG, so build 9 is an upgrade over it.

## 2. Production identity, confirmed from a built release app

- App `local.macbook.storage-monitor.viewer`, "Storage Monitor".
- Bundled helper `local.macbook.storage-monitor`, "MacBook Storage Monitor".
- Both are 2.1.0 (9), universal (x86_64 + arm64), macOS 14.0+, and signed with matching identifiers.
- `codesign --verify --deep --strict` passes.
- Development builds are `local.macbook.storage-monitor.viewer.dev`, "Storage Monitor Dev", and are never installed: `install-gui.sh` refuses any other identifier.

## 3. QA/production isolation evidence

**Preferences.**
- Native session: clicks in the QA app (visualization, navigator, 3D, evidence), then quit and relaunch. The changes persisted in the QA suite, and the dev domain stayed empty.
- Headless probe: QA writes under a stand-in production identity left that domain byte-identical.
- Production preferences file: SHA-256 `4ab8a7be…`, export `38889189…`, identical before, during and after every run.
- No Saved Application State was written for any Storage Monitor identity.

**Release tooling.**
- The QA timing log, stall monitor, argument handling and scripted navigation are compiled out of distribution builds.
- A 7-row activation matrix ran against distribution-compiled sources.
- The release executable contains none of the script's literals.
- The release executable, with only its identifier changed, ran with a QA database plus `--perf-log --perf-script` for more than 30 s with its window open. It wrote no log, ran no script step, and left production unchanged.

**Trash.** QA mode keeps Trash disabled. The cleanup and Trash-safety sources are unchanged from `b43f8d5`.

**Production preference left as is.** The installed app's saved visualization is `tree`, written by the 2026-10-28 session before isolation existed. It is left unchanged by operator decision.

## 4. Regression results (HEAD sources, 2026-10-29)

| Suite | Command | Result |
|---|---|---|
| Viewer | `scripts/test-gui.sh` (default fixtures, now `/private/tmp`) | 911 passed (28 new) |
| Monitor self-test | `scripts/build.sh` then `StorageMonitor self-test` | 235 passed |
| Inventory browser | `scripts/test-inventory-model.sh` | 67 passed |
| Inventory integration | `scripts/test-inventory.sh` | 350 passed (1 new: storage totals vs full scan) |

**Builds.** The release app-only build exited 0 in 262 s. The one compiler warning is an existing one, `CleanupInspectorView.swift:174`.

**Performance.** In the hidden-window harness, every navigation step was equal to or faster than the previous verified run, and peak memory was 102 MB. In the native session without VoiceOver, no main-thread stall exceeded 197 ms.

## 5. VoiceOver: partially verified

VoiceOver ran natively for about 2 minutes.

**Confirmed:**
- Reading order across the Storage header and toolbar.
- One combined element for available storage.
- Labeled Review Cleanup, Explain, Filters and Clear Filters buttons.
- "Expand <name>" disclosures in the navigator.
- Living Tree branches as "<name>, folder, <size>" buttons, so size is text.
- Severity in event cells read as text.
- The "Storage status" disclosure reports its state.

**Limitations:**
- Spoken output was not captured; the caption panel was not enabled because that is another global setting.
- Selecting a Living Tree branch and returning to the parent through VoiceOver were not exercised.
- Cleanup Review eligibility announcements were not exercised (the QA data has no review candidates).
- Duplicate announcements were not checked by ear.
- One 481 ms stall coincided with VoiceOver attaching, possibly from building elements for up to 3,000 branches. The cause is inferred.

## 6. Nonblocking UI and accessibility issues (deferred)

- Living Tree accessibility buttons lack parent context: three "models" branches sound identical.
- The search field has no title of its own.
- Two different controls are both named "Visualization".
- Event cells have role `AXUnknown`.
- With "All assessments" selected and nothing found, Cleanup Review still says "No suggestions on this page" and offers "See all assessments".
- At minimum width with the event panel open, the window title shortens to "Storage Monitor —…". The QA banner stays visible.
- A freshly identified app reopened with Settings open (QA identity launch quirk).
- Code-level items: chart point lookups, `LatestChange` recomputation, the Inspector's top-3 sort, unused `OverviewView` helpers, a structured Trash refusal kind.

## 7. Still required in the packaging phase

**Build**
- Build from a clean checkout of `873e069`: `scripts/build-dmg.sh`, which defaults to 2.1.0 (9) from `version.env`.
- The script deletes `build/dist/work` first. Move any `work` folder that should be kept; the last one is preserved as `build/dist/work-before-2.1.0-build9-20261029T051855Z`.
- Confirm `Storage-Monitor-2.1.0.dmg` doesn't overwrite an image you want to keep. Earlier 2.1.0 images live in another checkout; `build/dist` holds only 1.0.x and test images.
- Record the SHA-256 and the full log.

**Verify**
- Let `verify-dmg.sh` run. It covers:
  - checksum and a read-only, `-nobrowse` mount;
  - identifiers, names and 2.1.0 (9) in both bundles;
  - universal binaries, the deployment target, system libraries only, no build-machine paths;
  - a deep strict signature;
  - the bundled monitor's self-test from the image.
- Re-check that the distribution viewer contains none of the QA script literals (`release-bundle-inspection.txt` method).

**Signing and notarization**
- The default is ad hoc: Gatekeeper rejects the app on other Macs (expected, as with earlier test builds).
- For distribution: a Developer ID identity (`STORAGE_MONITOR_SIGN_IDENTITY`), then hardened runtime, timestamp and a signed DMG (the script handles these).
- Then notarize and staple manually, which the script never does, and check with `spctl --assess` and `stapler validate`.

**Installation (needs operator authorization: it replaces `/Applications/Storage Monitor.app`)**
1. Quit the running viewer.
2. Back up the current 2.1.0 (1) app bundle for rollback.
3. Install 2.1.0 (9) from the DMG.
4. Confirm the bundle ID and version with `PlistBuddy` and `codesign -dv`.
5. First launch: confirm the existing production preferences are recognized, and the history and catalog under `~/Library/Application Support/MacBook Storage Monitor/` load read-only.

**Upgrade checks**
- The background helper and LaunchAgents: check what Settings → Background Monitoring reports for the installed helper versus the bundled 2.1.0 (9) helper. This hasn't been checked for this build. Any helper update changes production LaunchAgents and needs explicit authorization.
- Full Disk Access is tied to the helper's code signature. An ad hoc rebuild changes it, so the grant may need re-approval after the helper is updated. Verify the inventory worker still reads protected folders.
- Confirm no Saved Application State or preference keys from the dev or QA identities appear in the production domain.

**Rollback**
- Keep the 2.1.0 (1) bundle and its DMG.
- Rollback means quitting the app, restoring the backed-up bundle, and reverting the helper through Settings if it was updated.
- Note that the version goes backward (build 9 → 1). Confirm LaunchServices opens the restored copy, and re-register it with `lsregister -f` if needed.
- Data and preferences are shared across these builds and need no migration.

**After packaging**
- Native smoke test of the installed app in light and dark: Storage, Living Tree 2D/3D, Monitoring, Cleanup Review (Trash enabled only in the production app; do not move anything during validation unless separately authorized), and Settings.
- Optionally, a VoiceOver pass with captions to close the limitations in section 5.
