# Build 11 native Reload verification — 2026-11-05

**PASS: native Reload success, disabled state, failure response and Retry recovery.** This attests the existing build 11 behavior, including the limitations below; it is not a claim that every user-facing message is polished.

## Identity and scope

- App: **2.2.0, build 11**, `local.macbook.storage-monitor.viewer`.
- Actual staged executable: `/Users/nicholaslippa/orca/projects/storage-checker/build/dist/work/Storage Monitor.app/Contents/MacOS/StorageMonitorViewer`.
- Executable SHA-256: `8508fa2ebbd04669b43ad16fdda1946b6e4579349f064f2dda351fb98f8ab3c7`.
- DMG: `Storage-Monitor-2.2.0-Studio-refresh-build11-20261105.dmg`, **17,102,428 bytes**, SHA-256 `57ff94fcef5e8630c4746545a82e30ca4a8f571de47e5a950dc205e900baae60`.
- User explicitly authorized the temporary MacBook QA window. The passing process was **PID 89193**, exact title **Storage Monitor — QA: reload-verification.sqlite3**.
- Launch used `NSWorkspace.openApplication` with `createsNewApplicationInstance=true`, `activates=true`, the disposable `--database-path`, and process-local `-ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO`. No persistent defaults were changed by the harness. These flags isolate QA restoration; **ordinary user restoration/startup behavior is not attested**.
- Only the newly returned application's PID, exact bundle/executable and unique fixture database arguments were eligible for activation, AX actions and cleanup. No global mouse coordinates or keyboard actions were used in the passing cycle.

## Actual native observations

The cycle passed with helper **exit 0** in **3.45 seconds**. The app was already active and had the exact QA window before the helper's additional own-PID activation.

1. Native AXHelp explained: **“Reload indexed results. No filesystem scan is performed.”** The Reload Inventory label remained present.
2. AXPress on `inventory.reload` completed a catalog read: page-load counter **2 → 3**. The actual native button became disabled immediately after the press, then returned enabled after completion.
3. A bounded exclusive lock on **only the disposable fixture database** forced a read failure. A second targeted Reload press again produced an observed disabled state. Native accessible text showed **“database is locked”** and **Retry**; the saved six-folder catalog remained visible.
4. The owned lock was released. AXPress on Retry completed another catalog read: **3 → 4**. The error disappeared, Reload returned enabled, and the same six fixture folders remained available.
5. Only the owned QA app was terminated. Driver evidence confirms `viewer_terminated: true`; an independent PID/unique-command-guarded deadline watchdog was also armed.

The three AXPress actions returned success. Evidence records actual native control states and accessible messages, not just controller simulation. **No pixel-level spinner appearance assertion is made.**

## Observed UX limitations

- While the read error was displayed, the saved catalog's header still said **“Inventory is up to date”**. That wording can be misleading after a failed reload.
- Success has no explicit per-reload “Reloaded at…” or “No changes” confirmation. The button settles and the saved results remain visible.
- The reload-versus-filesystem-scan explanation is hover help, rather than inline explanation.
- The separate table-footer spinner still follows general loading state, including background reads. The toolbar flashing fix is narrower.

These findings are preserved for the subsequent feedback correction; no product source was changed by this verification.

## Earlier attempts and remaining limits

The first authorized QA window established button/help visibility and a normal settled reload. During a subsequent coordinate-driven attempt the frontmost application was unexpected; root stopped all native input immediately and closed only the owned QA viewer. The later target-PID attempts never reached a main QA window, and performed **zero AXPress actions**. One diagnostic attempt confirmed a finished, active process with `AXWindows: []` and no catalog reads. Both it and the first working launch had invoked the same executable directly. The absence's trigger was not established, and is not a proven product startup or Reload defect. An attempted LaunchServices retry was refused before launch by the authorization-deadline guard. No such aborted attempt is counted as a pass.

The passing run changed both launch method and process-local restoration isolation. It therefore does not determine which earlier condition caused the missing scene. **NOT VERIFIED:** normal restoration/startup without QA overrides; pixel-level busy/error rendering; visible Resume; Settings navigation; Enable/Repair; Gatekeeper/download acceptance; physical Intel/macOS 14 execution.

No installed app, production database, service, QA supervisor or preserved snapshot was modified. No scan outside the tiny disposable fixture, catalog reset, full-volume refresh, installation, commit or push was performed.

## Evidence

Actual JSON records are preserved under `build/studio-refresh-build11-verification/native-reload/`: `ax-cycle-result.json`, `ls-driver-result.json`, `identity.json`, session/readiness and lock records. The temporary harness and earlier attempt records remain in `/private/tmp/storage-monitor-reload-attestation-1cvc1xeb`.
