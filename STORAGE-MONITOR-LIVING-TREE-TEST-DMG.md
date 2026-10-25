# Storage Monitor 1.0.6 (7) — Living Tree test DMG

Date: 2026-10-25. A development test build for manual testing. Not installed, launched, committed or notarized.

- **Image:** `build/dist/Storage-Monitor-Living-Tree-Test.dmg`, 11,526,359 bytes (11 MB), UDZO, HFS+.
- **SHA-256:** `db9c3ae044414de0b1b9058fb18ba4cbc2275803088bdbf280015118f71e6df6` (also in `.sha256` beside it).
- **Version:** 1.0.6 (build 7) for both the app and the bundled helper; minimum macOS 14.0; universal (arm64 + x86_64).
- **Build command:** `STORAGE_MONITOR_VERSION=1.0.6 STORAGE_MONITOR_BUILD=7 STORAGE_MONITOR_DMG_NAME=Storage-Monitor-Living-Tree-Test.dmg scripts/build-dmg.sh`
- **Build configuration:** `swiftc -O`, Swift 5 mode, 26.5 CLT SDK, target macOS 14.0. The work directory was rebuilt from scratch. The previous one was kept as `build/dist/work-1.0.5`.
- **Packaging change:** an optional `STORAGE_MONITOR_DMG_NAME` in `scripts/build-dmg.sh`, documented in PACKAGING.md. The default name is unchanged.
- **Contents:** Storage Atlas, Living Tree, the inventory change journal, the refresh and cancellation fixes, explorer incremental updates, and Navigator and Inspector integration. All were confirmed in the sources, and the app's strings were confirmed in the shipped binaries.
- **Signing:** ad-hoc for the app and the helper (no team identifier). The keychain has no code-signing identities. Gatekeeper rejects the app (expected for ad-hoc).
- **Notarization:** not notarized and no ticket stapled; it needs a Developer ID identity and notarytool credentials.

## Tests (run against the same tree, before packaging)

| Check | Result |
|---|---|
| Monitor build (`scripts/build.sh`) | OK, 0 warnings |
| Viewer build (`scripts/build-gui.sh`) | OK, 0 warnings |
| Inventory tests | 345 passed |
| Viewer model tests | 459 passed, plus 2 binary checks |
| Headless explorer and inventory model tests | 22 passed |
| Monitor self-test | 233 passed |

## DMG validation

- `scripts/verify-dmg.sh` passed all checks:
  - the image checksum;
  - a read-only mount with `-nobrowse -noautoopen`;
  - the volume contents;
  - identifiers and versions;
  - universal binaries;
  - the macOS 14.0 deployment target;
  - links to system libraries only;
  - no build paths embedded;
  - the icons;
  - the plists;
  - a deep, strict signature check;
  - the bundled monitor's self-test run from the image (233 passed).
- **Independent checks:**
  - `hdiutil verify` passes;
  - the mount reported `read-only, nobrowse`;
  - Info.plist metadata as above;
  - `lipo` reports x86_64 and arm64 for both executables;
  - the image was detached and no mounts are left.
- **Previous DMGs unchanged:** the SHA-256 checksums of 1.0.0 to 1.0.5 match their values from before the build.
- **Warnings:**
  - `hdiutil imageinfo` is deprecated (informational);
  - "replacing existing signature" during signing, which is expected because the linker ad-hoc signs first.
