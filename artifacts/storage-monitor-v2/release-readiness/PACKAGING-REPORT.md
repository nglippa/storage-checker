# Storage Monitor 2.1.0 (9): DMG build and artifact validation

Date: 2026-10-29.

**Scope.** This phase built the artifact and verified it. Nothing was installed, pushed, tagged or distributed.

**Unchanged.** Installed apps, production preferences, LaunchAgents, background services, Full Disk Access and the original repository's tracked files were all left as they were (evidence in section 9).

**Result.** A DMG was built from the exact commit `873e069` and verified, 38/38 checks. It is ad hoc signed and not notarized, so it is **unsuitable for normal external distribution**. It is suitable for local, operator-controlled installation testing.

| Requirement | Status |
|---|---|
| DMG built from exact commit 873e069 | VERIFIED |
| No source changes | VERIFIED |
| No existing artifact overwritten | VERIFIED |
| Bundle identities and versions | VERIFIED |
| QA execution functionality excluded | VERIFIED |
| DMG integrity | VERIFIED |
| Code signature valid (ad hoc) | VERIFIED |
| Gatekeeper / notarization | BLOCKED for external distribution: ad hoc; no Developer ID credentials or notarization authorized |
| Bundled monitor self-test from the image | NOT TESTED: running the helper was out of scope (see section 4) |
| No production installation or service changes | VERIFIED |
| Installation and rollback plan | VERIFIED as prepared ([INSTALL-ROLLBACK-PLAN.md](INSTALL-ROLLBACK-PLAN.md)); NOT TESTED as executed |

## 1. Source

- Branch `v2.1-rc` at `873e069dc88788d24d620b4f9f6ff1904ea52f6a`, "Harden V2.1 release: isolate QA identity, stamp 2.1.0 (9), compile QA tooling out of release". The parent `b43f8d5` is preserved; `master` is unchanged at `6218eba`.
- Built from a fresh `git clone --no-hardlinks` of the repository, detached at `873e069`. It had zero tracked changes before and after the build, and the original repository was only read.
- Version 2.1.0 (9), from `scripts/version.env`. No version overrides were set.

## 2. Preflight and side-effect review

**Preflight**
- **Identities:** the release identities are `local.macbook.storage-monitor.viewer` and `local.macbook.storage-monitor`. The dev identity `…viewer.dev` is separate, in `build-gui.sh` only.
- **Signing:** there is no Developer ID identity or notarization authorization, so the default ad hoc signing was used.

**Side effects of `scripts/build-dmg.sh`** (at `873e069`)
- Everything resolves under `$ROOT/build`. That includes:
  - `rm -rf build/dist/work`;
  - `rm -f` of the output DMG and its `.sha256`;
  - the module cache;
  - the `/Applications` symlink, created inside the staging folder only.
- No privileges, installation, LaunchAgent, `launchctl`, helper, preference or Full Disk Access operations.
- The icon scripts `prepare-icon.swift` and `pack-icon.swift` only read `Assets/AppIcon.png` and write into `build/dist/work`.
- **How collisions were avoided:** `$ROOT` was the isolated clone, which had no `build/` folder, so nothing existing could be deleted or overwritten.

**`scripts/verify-dmg.sh`**
- It mounts the image read-only.
- Its last step executes the bundled background monitor (`StorageMonitor self-test`). That conflicts with "do not execute the bundled helper", so the build used the script's own `STORAGE_MONITOR_SKIP_VERIFY=1` switch.
- Every other check was reproduced, without modifying source, in a separate read-only script (`verify-artifact.sh`).

## 3. Build

```
cd /private/tmp/storage-monitor-pkg-2.1.0-9-20261029T063406Z/src
env -u STORAGE_MONITOR_VERSION -u STORAGE_MONITOR_BUILD -u STORAGE_MONITOR_SIGN_IDENTITY STORAGE_MONITOR_SKIP_VERIFY=1 scripts/build-dmg.sh
```

- **Result:** exit 0, 384 s, no compiler errors.
- **Warnings:** 2 compiler warnings, both the existing `CleanupInspectorView.swift:174` implicit strong `self` capture, once per architecture.
- **Environment:** macOS 27.0 (26A428); Apple Swift 6.4 (swiftlang-6.4.0.34.1); SDK `MacOSX26.5.sdk` (Command Line Tools); system `hdiutil` and `codesign`.
- **Image settings:** `SOURCE_DATE_EPOCH` is the commit time; architectures arm64 and x86_64.

## 4. Artifacts

| Artifact | Path | SHA-256 |
|---|---|---|
| DMG (15,137,570 bytes, UDZO, CRC32) | `build/release-artifacts/2.1.0-9-20261029T063406Z/Storage-Monitor-2.1.0.dmg` | `3484abea58524cd090808714e38672cc0f82a628d3b42b9c797c66674f774f0c` |
| Viewer executable | `Storage Monitor.app/Contents/MacOS/StorageMonitorViewer` | `3e9e6049d6ba2bfa57caf1cab0b985979a0859c19126fc5119f2e32b27e61a38` |
| Helper executable | `…/Helpers/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor` | `b8f84b9e49542350c89d099d08e681b24eefebd3d2bd1aa83acb5648ca92c95a` |
| App Info.plist | | `06be293ef02f675f65de09bc885bdd188ca3abe92f3897333b6224c9b04f34a0` |
| Helper Info.plist | | `f88b3bb78ffd4314e1c7b49d3211eea872a8b40421050c9dce70ef6a628f27ee` |
| Whole-app manifest (modes, sizes and SHA-256 of every file) | | `ecfcf09ccd5f27a7f471441699ca9c78c990287fd2aa139ab57e8c4b887de367` |

**Where the files are.**
- The persistent copy, in a new git-ignored folder `build/release-artifacts/2.1.0-9-20261029T063406Z/`, holds the DMG, `.sha256` (verified `OK` after copying), `build-dmg.log`, `build-command.txt`, `environment.txt`, `verify-artifact.sh` and `verify-artifact.log`.
- The original build output remains in `/private/tmp/storage-monitor-pkg-2.1.0-9-20261029T063406Z/src/build/dist/`, which is cleared on reboot.
- The repository's `build/dist/` still holds its 7 earlier DMGs, untouched.

## 5. Bundle metadata, read from the mounted image

| | App | Bundled helper |
|---|---|---|
| CFBundleIdentifier | `local.macbook.storage-monitor.viewer` | `local.macbook.storage-monitor` (LSUIElement) |
| Name | Storage Monitor | MacBook Storage Monitor |
| Version (build) | 2.1.0 (9) | 2.1.0 (9) |
| Minimum macOS | 14.0 (`LSMinimumSystemVersion` and `minos` for every slice) | 14.0 |
| Architectures | arm64 + x86_64 | arm64 + x86_64 |
| Libraries | system only; no toolchain rpaths | system only |
| Entitlements | none | none |
| Embedded paths | no home, repository or packaging-workspace paths | same |

**Contents.**
- The volume holds exactly `Storage Monitor.app` and the `Applications` → `/Applications` symlink, with no hidden entries.
- The bundle holds only the two Info.plists, the two executables, the two icons and the two `CodeResources`.
- No logs, databases, credentials, `.DS_Store`, QA or JSON files.
- No development or QA identity keys in either plist.

## 6. Code signature and Gatekeeper

| | Signature | CDHash | Team ID | Timestamp | Hardened runtime |
|---|---|---|---|---|---|
| App | ad hoc, identifier `local.macbook.storage-monitor.viewer`, `--verify --deep --strict` valid | `b91d4e3cdee1f4ebc308c41a22f32d19b728a037` | not set | none | no |
| Helper | ad hoc, identifier `local.macbook.storage-monitor`, `--verify --strict` valid | `e5707cf95bbb45c638b8b998ecb0ee6bfb4ce95c` | not set | none | no |
| DMG | unsigned | | | | |

- `spctl --assess --type execute` on the app: **rejected**.
- `spctl --assess --type open` on the DMG: **rejected (no usable signature)**.
- `stapler validate`: no ticket.

**Conclusion.** It is not suitable for normal external distribution. On another Mac it opens only with a manual Gatekeeper override.

**Remaining notarization requirements** (not attempted; they need credentials and separate authorization):
1. A Developer ID Application certificate, used as `STORAGE_MONITOR_SIGN_IDENTITY`. The script then adds the hardened runtime and secure timestamp, signs the helper first, then the app, and signs the DMG.
2. Hardened-runtime review: the app currently uses no entitlements, so check that nothing it does needs one.
3. Submission with `xcrun notarytool submit … --wait`, using App Store Connect API key or app-specific password credentials.
4. Then `xcrun stapler staple` on the DMG, and `spctl --assess` acceptance for both the app and the DMG.
5. Rebuild and re-verify with this report's method, because the artifact hashes will change.

## 7. QA tooling exclusion

- The viewer in the image contains none of the scripted-navigation or timing-log literals (`storage_to_monitoring`, `monitoring_to_storage_tree`, `atlas_to_living_tree`, `script.launchReady`, `frame.committed %@ +%.0fms`, `main.stall %.0fms`): count 0.
- It was compiled with `-D STORAGE_MONITOR_DISTRIBUTION`, which compiles the timing log, stall monitor, QA argument handling and scripted navigation out.
- This repeats [RELEASE-READINESS.md](RELEASE-READINESS.md). That report also launched the identical release code with QA flags natively, and no tooling ran.

## 8. Packaging integrity

- `hdiutil verify`: the checksum verifies.
- The mount was read-only (confirmed by `mount`), used `-nobrowse -noautoopen` so no Finder window opened, and detached cleanly with no mount left behind.
- The packaged app is identical to the built and validated `build/dist/work` app in every file's mode, size and SHA-256.
- The first comparison flagged directory sizes, which APFS and HFS+ report differently. The manifest was corrected to compare directories by mode and path; file contents were identical in both runs.
- **Not tested:** the bundled monitor's self-test from the image (out of scope). The same source's monitor self-test passed 235/235 from the repository build on 2026-10-29.

## 9. Production state after packaging (unchanged)

- **Installed app.** `/Applications/Storage Monitor.app` 2.1.0 (1): CDHash `118a6f42…`, modified 2026-10-25 14:10, the same as before.
- **Helpers.** The bundled helper and the installed helper `~/Applications/MacBook Storage Monitor.app` are 2.1.0 (1) with CDHash `8a5393ef…`, the same as before.
- **LaunchAgents.** The three plists keep their 2026-10-27 13:28 modification times and are all still loaded.
- **Preferences.** SHA-256 `4ab8a7be…`, the same as before.
- **Repository.** `873e069`, clean apart from the pre-existing untracked `.DS_Store`, `artifacts/` and `docs/`.

## 10. Installation and rollback

See [INSTALL-ROLLBACK-PLAN.md](INSTALL-ROLLBACK-PLAN.md); it is not executed. The key points:
- It is an upgrade from 2.1.0 (1) to 2.1.0 (9) with the same identity, so preferences carry over.
- Settings is expected to report the helper as needing an update. The helper update is a separate ⚠ operator action that changes LaunchAgents.
- No schema migration is expected.
- The ad hoc helper's CDHash changes, so Full Disk Access and notification grants will probably need re-approval (inferred).
- Rollback restores the backed-up 2.1.0 (1) bundles through the app's own install path.

## 11. Unresolved blockers

- **External distribution:** BLOCKED pending Developer ID signing and notarization (credentials and authorization).
- **Installation and upgrade validation:** not started; it needs separate authorization per the plan.
- **No blockers remain for local, operator-controlled installation testing of this artifact.**
