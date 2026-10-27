# Storage Monitor 2.1.0 — local test DMG

**Local test artifact; not a formal RC or release approval.** Native-window/Finder Put Back/native-resource/performance gaps remain unchanged. The strict isolated QA profile is incomplete and unavailable in this DMG; this app uses the **normal production runtime** if the operator chooses to launch it. No app was launched or installed by this task.

- DMG: `/Users/nicholaslippa/orca/projects/storage-checker/build/dist/Storage-Monitor-2.1.0-LOCAL-TEST-20261027T162336Z.dmg`
- Version **2.1.0**, build **1**, app/helper both universal **arm64 + x86_64**, macOS **14.0+**.
- Size: **13,851,976 bytes**.
- SHA-256: `735bd901ad2e55f13e0a71cd0112b86b8b528abcf87554ecf668f8ddad618658` (matches accompanying `.sha256`).
- Existing `scripts/build-dmg.sh` completed exit **0**, **398.511 seconds**, **zero compiler diagnostics**.
- **25 packaging checks passed**; no failed checks. Both plists, nested ad-hoc signatures, system libraries/rpaths, approved icons and absence of embedded home/repository paths verified. Gatekeeper rejection is expected for an ad-hoc, unnotarized local test build.
- The image was mounted **read-only**, `-nobrowse -noautoopen`; its temporary mountpoint was removed after detachment. No Finder window or app launch.
- PASS bundled background monitor runs from the image (235 tests passed)
- Prior work directory preserved at `/Users/nicholaslippa/orca/projects/storage-checker/build/dist/work-before-2.1.0-20261027T162336Z`; previous DMGs/checksums were not overwritten.

Packaging-only `STORAGE_MONITOR_DISTRIBUTION` is passed to both packaged binaries. It compiles the repository-bound QA anchor out, preventing accidental strict QA activation and embedded build-machine paths; the production bundle identifiers/signing branch are preserved. The final **normal distribution viewer** therefore built successfully for both architectures. This does not complete the stopped **normal development/controller QA proof** or native operator acceptance.

Evidence: `/Users/nicholaslippa/orca/projects/storage-checker/build/dist/evidence-2.1.0-20261027T162336Z` (`provenance.json`, full `build-dmg.log`, `result.json`, `package-verification-summary.json`). All recorded source hashes still match. No notarization, publication, installation, commits or pushes. QA work summary and remaining steps: [QA-WORK-STOPPED.md](QA-WORK-STOPPED.md).
