# Storage Monitor 2.0.0 (build 8) — test release

Built 2026-10-26 from the uncommitted working tree (not committed or pushed). Not installed anywhere by this build.

- **Image:** `build/dist/Storage-Monitor-2.0.0.dmg` (13.3 MB)
- **SHA-256:** `489eade85f5313dfa00028adfcbca669ef2ab13c2fb855545bf38e97b1a49e24`
- **Version:** 2.0.0 (build 8) for both the app and the bundled helper; replaces 1.0.6 (build 7); minimum macOS 14.0; universal (arm64 + x86_64); ad-hoc signed, not notarized.
- **Build command:** `STORAGE_MONITOR_VERSION=2.0.0 STORAGE_MONITOR_BUILD=8 scripts/build-dmg.sh` (log: `build/dmg-2.0.0.log`)

## What is new since 1.0.6

- **Living Tree camera** — pan, zoom about the pointer, focus, fit and reset; a fuller fit; collision-aware labels that increase with zoom; stability through inventory updates (`LIVING-TREE-CAMERA.md`).
- **Living Tree 3D** — an opt-in 3D/2D mode: drag to turn, depth shading, focus turns a branch side-on (`LIVING-TREE-3D.md`).
- **Cleanup Inspector** — read-only classification of Claude Code and Codex installations, Node and Python artifacts, Git worktrees and agent sessions, with evidence, a conservative assessment (Preserve, Review candidate, Insufficient evidence, Protected) and a read-only preview. Nothing is deleted or moved (`CLEANUP-INSPECTOR.md`).
- The background monitor's code is unchanged in function; it shares the updated inventory and arranger code (absolute dead-band in the Living Tree arranger).

## Verification (`scripts/verify-dmg.sh`, run by the build)

All checks passed: checksum; read-only mount without Finder; volume contents (the app and an Applications link); identifiers, display name, background-only helper; version 2.0.0 (8) in both bundles; minimum macOS 14.0; both executables universal, deployment target 14.0, system libraries only, no build-machine paths; icon; valid Info.plists; deep strict signature; the bundled monitor's self-test from the image (233 passed). Gatekeeper rejects the app (informational, expected for an ad-hoc, unnotarized build).

Before the build: viewer model 569, headless inventory model 37, inventory 345 and monitor self-test 233 tests passed; viewer and monitor builds had no warnings.

## Not verified

- Installing from the image, the upgrade from 1.0.6 on another Mac, and the new features in a real window (camera, 3D, Cleanup Inspector). See the checklists in the three records above.
- Because the build is ad-hoc signed and not notarized, opening it on another Mac needs right-click → Open (or System Settings → Privacy & Security → Open Anyway) on first launch.
