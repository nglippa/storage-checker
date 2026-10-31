# Focus filtering candidate package — 2026-10-31

Created after explicit user authorization to commit, push and package the completed filtering work. The parent directory's implementation reports/manifests record the earlier pre-packaging phase; this record covers the subsequent candidate build. **Native GUI acceptance is still pending.**

## Artifact and source

- DMG: `build/dist/Storage-Monitor-2.3.0-focus-filtering-candidate.dmg`
- Version: **2.3.0 (11)**; universal **arm64 + x86_64**, macOS **14+**.
- Size: **15,956,765 bytes**.
- SHA-256: `f63adf3e207ff6cd9ad11ecbb9220e2187f6d11da06fb7a69faf634e9a645748`. Matching `.sha256` sidecar beside the image.
- Source commit: `a98fa0f487df0bcbf4501ea4b9fbfc2e2069c479`; Git tree `73fd16a37e57a05c136bc194429d234892ca8eb3`.
- Built from an exact clean export of that tree in `/private/tmp/storage-monitor-focus-package.eyneIj/source`. Existing cleanup Inspector edits and unrelated untracked work were excluded and preserved; see `source-scope.json`.
- Version/build/name were environment overrides for this package. `scripts/version.env` and existing release images remain unchanged. No tag or GitHub release was created; the DMG remains a local candidate artifact.

## Reproducible command

Run in a clean checkout of the source commit:

```sh
STORAGE_MONITOR_VERSION=2.3.0 STORAGE_MONITOR_BUILD=11 \
STORAGE_MONITOR_DMG_NAME=Storage-Monitor-2.3.0-focus-filtering-candidate.dmg \
STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
STORAGE_MONITOR_ARCHS='arm64 x86_64' STORAGE_MONITOR_SIGN_IDENTITY=- \
SOURCE_DATE_EPOCH=1793459522 scripts/build-dmg.sh
```

Exit **0**. Full command/timing record: `package-result.json`; log: `package.log`. Verification was enabled. Both architectures were freshly compiled with `STORAGE_MONITOR_DISTRIBUTION` and signed in the existing helper-first order. DMG bytes are not guaranteed identical on rebuild because signatures/disk-image metadata are not bit-reproducible.

## Verification

- Clean exported source: monitor build, GUI models (**960 checks**), inventory/controller (**68 tests**), chart/input (**52/52**) and inventory integration (**350 tests**) all exited **0**. Raw commands/times: `clean-source-test-results.json`; individual logs retained here. Counts describe this clean commit and exclude the separately uncommitted cleanup test addition.
- Automatic DMG verification: **25/25 checks passed**, including image checksum, read-only mounting, correct two-entry drag-to-Applications layout, app/helper metadata and 2.3.0 (11), macOS 14 deployment target for both architectures, system-only dependencies/runtime paths, approved icons, valid plists and deep/strict signatures.
- Bundled monitor ran from the read-only image: **235 self-tests passed**. The viewer was never launched.
- Both executable architectures independently confirmed; viewer does not link UserNotifications. Binary hashes are recorded in `receipt.json`.
- The image was mounted with `-readonly -nobrowse -noautoopen`, then detached. No Finder or app window was opened. A post-build `hdiutil info -plist` check confirms this image is no longer mounted.
- Copied candidate checksum verified from `build/dist` with `shasum -a 256 -c Storage-Monitor-2.3.0-focus-filtering-candidate.dmg.sha256` (exit **0**). An initial checksum invocation redundantly included `build/dist/` while already in that directory and failed with file-not-found; corrected command passes.
- Existing 2.2.0 DMG, protected 2.1.0 DMG and preserved catalog retain SHA-256, size, mtime and inode; `v2.1-rc` is unchanged. Original cleanup-edit hashes still match. See `receipt.json` / `source-scope.json`.

## Acceptance limits

This is **ad-hoc signed and not notarized**. Gatekeeper assessment reports rejection, as expected for this signing mode; the packaging script records that assessment informationally. No signing/notarization requirement was weakened or bypassed.

**NOT VERIFIED:** native size/custom controls, Focus/transitions, isolation/exit/Reset, right-click menu delivery, real click/double-click/keyboard delivery, displayed Inspector/Navigator scrolling, actual minimum-window rendering, physical mouse wheel and trackpad gestures, native fallback switching and VoiceOver. Follow the existing `../NATIVE-QA-PLAN.md` with explicit desktop authorization. Headless/package checks do not certify native acceptance or release readiness.

No installation, production preference/database/LaunchAgent change, unrestricted scan, application activation or desktop input was performed.
