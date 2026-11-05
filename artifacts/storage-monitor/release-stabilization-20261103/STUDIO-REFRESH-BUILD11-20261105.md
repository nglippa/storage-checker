# Studio refresh and indexing diagnostics — 2026-11-05

The reported Mac Studio problem occurred **after Enable Background Monitoring**: Settings said monitoring was configured, indexing did not appear to start, and Reload Inventory repeatedly flashed. Direct Studio diagnosis established an **existing pause marker from October 25**, retained when the new DMG reused the existing data folder. The installed worker ran successfully but honored that saved pause; its summaries reported `paused` / `cancelled`, not a startup failure.

The user approved resuming the existing Studio index. The normal installed helper's `inventory-resume` preserved the catalog, removed the pause marker and woke the existing worker through its request directory. Generation 2 advanced from **1 to 18,166 nodes**, with **1,622 completed directories** and state `building`. The original marker was backed up first. No helper installation, service replacement, reset or full-refresh request was needed. See the [diagnosis and recovery receipt](STUDIO-INDEXING-RECOVERY-20261105.md); completion of the whole index remains unverified.

Sustained recovery was observed at **07:43:14 UTC**: the normal 1201-second slice processed **262,432 entries and 24,622 directories**, with 48,518 listings still pending, `status: continuing`, and no cancellation/error. Launchd automatically started the next existing worker slice (run 8, PID 48231); last exit **75** denotes normal continuation. These are worker-summary counts, not a claim that the full index completed.

## Changes

- Automatic catalog reads no longer animate the manual Reload Inventory button. Explicit reload/retry requests have their own progress state, preserve the label, and coalesce requests arriving during an existing read. Cancellation and failures clear the appropriate indicator.
- A saved pause is recognized even before a database/root exists and has a visible **Resume indexing** action, rather than requiring discovery of the Folder updates menu. The UI explains that pause intent survives app updates. Paused work no longer drives the two-second active-indexing clock; normal 30-second catalog/status checks remain. Monitoring known to be off offers Settings instead of Resume. Reloading a catalog never clears a pause automatically.
- Worker evidence now recognizes timestamped `ERROR inventory-work failed:` startup records and retains bounded reasons from those records and failed JSON summaries. Previously these startup lines were ignored. The worker can also deliberately exit zero after a recorded engine failure to avoid an automatic restart loop; exit zero cannot hide that failure in the Storage view.
- Storage and Settings display the retained failure reason. Storage stops indefinite first-index progress, preserves an existing catalog for browsing, and offers catalog reload and Settings. A running retry supersedes an old nonzero exit status; a logged failure remains until later committed inventory progress. A later failure updates the reason. Existing timestamp/stream ordering checks prevent older rotated logs from establishing recovery.
- No scanning, scheduling, installation, permission or capacity policy was changed. Existing 30-second monitoring/status reads continue while an error is shown so later recovery can appear.
- [Read-only diagnostic collector](../../../scripts/diagnose-indexing.sh): `sh scripts/diagnose-indexing.sh`. It reports metadata, signature/quarantine, filtered service status, catalog file metadata and bounded worker logs. It never opens the database, launches the helper or changes services. Review existing log paths before sharing the output.

## Verification

- Final GUI/read-only model suite: **1164 passed**, exit 0, including startup reasons, exit-zero failure, existing-root failure, Settings detail, recovery, log ordering and saved-pause/off/root/setup behavior. `build/studio-refresh-build11-verification/gui-model-pause-final.log`.
- Final inventory browser/model suite: **114 passed, 0 failed**, exit 0, including quiet refresh/cancellation and real pause/Resume requests against disposable fixtures. Missing-catalog reload preserves the pause and creates no database; explicit Resume clears the fixture marker and queues work. `build/studio-refresh-build11-verification/inventory-model-pause-final.log`.
- Direct scoped startup probe: the real helper queued a request before its database existed, indexed a six-folder fixture into **13 nodes**, consumed the request and exited **0**. A missing-root probe exited **1** and wrote the actual timestamped startup-error format. This exercises a direct helper process, not launchd, installation or the Studio. `build/studio-refresh-build11-verification/startup-probe.json`.
- Final package suite: **25 passed**, exit 0.
- Final direct monitor self-test: **238 passed**, actual exit 0 outside the sandbox. The earlier sandbox run failed while reading swap information; it is not a passing test result.
- `sh -n scripts/diagnose-indexing.sh` and `git diff --check` passed.

The sandboxed model executable initially trapped while initializing AppKit; the approved noninteractive rerun passed. A separate sandboxed startup probe paused for reported low space; the identical approved nonsandboxed probe completed. Neither sandbox result establishes the Studio's cause. An intermediate GUI-suite compile correctly refused an input changed during review; the final 1164-check run used frozen inputs.

Local source identity: HEAD `734ec2f10d6a161cafa1d17041cdb68a3043ee30` plus the working-tree changes. Final fingerprint `5bd5cb30f7dc6d2b2755ffec8bf84924db0baddaebab70649970c0e3e4ffa02d` over 151 source/test/script inputs; exact hashes are in `build/studio-refresh-build11-verification/source-manifest.json`. The earlier snapshot is preserved separately as `source-manifest-before-pause.json`.

## Candidate package

Build command (release defaults in `scripts/version.env` remain unchanged):

```sh
STORAGE_MONITOR_BUILD=11 \
STORAGE_MONITOR_DMG_NAME=Storage-Monitor-2.2.0-Studio-refresh-build11-20261105.dmg \
scripts/build-dmg.sh
```

Package build and verification completed. The local artifact is:

`/Users/nicholaslippa/orca/projects/storage-checker/build/dist/Storage-Monitor-2.2.0-Studio-refresh-build11-20261105.dmg`

- Size: **17,102,428 bytes**.
- SHA-256: `57ff94fcef5e8630c4746545a82e30ca4a8f571de47e5a950dc205e900baae60`.
- Delivered with `rsync --ignore-existing` to Mac Studio: `/Users/nicholaslippa/Downloads/Storage-Monitor-2.2.0-Studio-refresh-build11-20261105.dmg`.
- Remote `stat` and `shasum -a 256` confirmed the exact expected size and checksum, both exit 0. **Delivery verified; installation is pending.** No app was launched or installed during transfer.

## Not verified

Subsequent user-authorized native verification of the actual build 11 QA app **passed Reload success, native disabled states, native error/Retry, and Retry recovery**, with the six-folder saved catalog preserved. The native AXHelp explanation was verified. See [native Reload receipt](RELOAD-NATIVE-VERIFICATION-20261105.md) for exact binary identity, JSON evidence, process-local restoration isolation, earlier failed harness attempts, and observed wording gaps. This later test used only its explicitly authorized disposable MacBook QA window.

**NOT VERIFIED:** pixel-level appearance of the changed toolbar/pause/error states and spinner; visible Resume interaction; Settings navigation; real packaged Enable/Repair flow; normal restoration/startup without QA isolation; Gatekeeper first launch and transferred/downloaded candidate quarantine acceptance; physical Intel/macOS 14 execution. Existing native receipts retain their original source identities. The separate, explicitly approved Studio resume and real catalog progress are verified as described above.

The candidate is a local ad-hoc signed development build, not a notarized public release. No commit, push, installation, catalog reset, full-refresh request or existing QA-worker modification was performed. Local checks used disposable fixtures. Studio recovery allowed the existing bounded worker to resume normal catalog writes only after explicit user approval; diagnostics opened only disposable APFS copies, never the production database.
