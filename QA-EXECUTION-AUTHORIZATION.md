# QA execution authorization

**Status: authorization prepared. Nothing in QA has been changed.** The corrected worker has not been installed, and the QA worker keeps running the old code.

Inspected 2026-10-23 at about 13:05 UTC, read-only, on Claude Code 2.1.309.

## 1. Guard identity

The "Interfere With Workloads" denials come from the **Claude Code auto mode classifier**. Its built-in `soft_deny` rule of that name is the source:

> Interfere With Workloads [named+specifics — **must name:** interfering with those jobs or that shared resource]: Deleting, cancelling, or killing any job the agent did not create this session — by any mechanism (… kill, … API call, or equivalent) …

The QA worker is a job this session did not create, so the following all match the rule:
- writing `inventory.cancel`, which cancels its running slice;
- a watcher that does the same;
- `launchctl bootout`.

These were ruled out, each by inspection:

| Candidate | Finding |
|---|---|
| Permission rule (`permissions.deny`/`ask`) | None: `~/.claude/settings.json` holds only 13 unrelated `allow` rules. The project `.claude/settings.local.json` holds only MCP keys. |
| PreToolUse hook | The hooks (GateGuard fact gate, subagent guard, codebase-memory, GSD commit check, Orca relay) produce differently worded messages. None emits this category. GateGuard still asks for facts before the first edit or command, and is not the blocker. |
| Repository policy | `AGENTS.md` asks for explicit authorization of protected-state changes, but it is guidance and does not execute. |
| Central policy | None: there is no `/Library/Application Support/ClaudeCode/`, no `/Library/Managed Preferences` entry, no `/etc/claude-code`, and no `com.anthropic.claudecode` defaults domain. |

## 2. Configuration location

- **Rule text:** built into Claude Code. `claude auto-mode defaults` prints it, with 17 allow rules, 72 soft_deny rules and 1 hard_deny rule.
- **Local overrides:** `autoMode` in `~/.claude/settings.json`, which can only be set at user or managed scope. It sets only `environment`. `claude auto-mode config` shows that the effective `allow` and `soft_deny` lists equal the defaults, so the rule is unmodified.
- **Unrelated finding, leave it alone for now:** that `autoMode.environment` describes a different project (`nglippa/steam-tycoon` as "the trusted repo"). It does not cause the workload denial, which ignores repository trust. It is stale, though, and worth correcting separately. Changing it is a Self-Modification action that only you should make.

## 3. Supported authorization mechanisms

Each row is checked against the installed documentation (code.claude.com permission-modes, permissions and settings reference) and the local CLI.

| Mechanism | Granularity | Lifetime | Fit |
|---|---|---|---|
| **Approval stated in conversation** | Must name the action and the specific target; naming only the verb clears nothing. Covers the named action, or the named set when you mark it as standing. | This session only; nothing is written to disk. | **Recommended** |
| `/permissions` → Recently denied → `r` | Retries one exact denied call, interactively. | One-time | Fallback for a single step |
| Leave auto mode (Shift+Tab) and answer each prompt "Yes" (not "don't ask again") | Exact command, approved interactively. | One-time per prompt | Fallback when a block will not clear |
| Exact `permissions.allow` rules, e.g. `Bash(launchctl bootout gui/501/local.macbook.storage-monitor.inventory-qa)` | Exact string or prefix; path-scoped `Edit(//abs/path)` rules exist. Narrow rules skip the classifier in auto mode; hooks still run. | Persistent until removed | Possible but not needed. Exact matching of commands with quoted, space-containing paths, such as the QA bundle, was not tested here. |
| `autoMode.allow` prose rule | Prose and fuzzy; user or managed scope only, so it would apply to every project. | Persistent | **Not recommended**: too broad |
| `classifyAllShell`, `bypassPermissions`, `--dangerously-skip-permissions`, `CLAUDE_CODE_AUTO_MODE_SERVER`, disabling hooks | n/a | n/a | **Rejected**: these weaken or bypass guards |

There is no executable-specific allow mechanism in the classifier beyond Bash prefix and exact rules.

## 4. Recommended narrow authorization

Use a single message stating the approval, given in this session. It names the job, the label, the paths and the hashes, is standing only for the enumerated steps, and explicitly replaces your earlier "do not stop QA" restrictions for those steps alone. Otherwise the classifier can still read those earlier instructions as a refusal. It grants nothing for production, other LaunchAgents, other processes or other databases. Nothing persists after the session, and no settings file changes.

## 5. Exact user action required

Send this message, with any edits you want:

```text
I authorize, as a standing approval for this session only, the QA-only Storage Monitor upgrade in
QA-EXECUTION-AUTHORIZATION.md §7, for exactly these actions. For these actions only, this supersedes my
earlier instructions not to stop QA, write QA pause files, run launchctl mutations, or modify the QA database:

1. Gracefully cancel the running slice of QA launchd job local.macbook.storage-monitor.inventory-qa by writing
   /Users/nicholaslippa/storage-checker/build/inventory-fresh-20261023T031313Z/data/inventory.cancel
   (the worker stops at its next committed batch boundary).
2. After that worker has exited, run: launchctl bootout gui/501/local.macbook.storage-monitor.inventory-qa
3. Back up build/inventory-fresh-20261023T031313Z/data/history.sqlite3 with sqlite3 .backup into
   build/inventory-qa-upgrade-20261023/qa-pre-upgrade/, and copy the old QA app, plist, supervise.py, run.json,
   samples.jsonl and logs there.
4. Replace only build/inventory-fresh-20261023T031313Z/Storage Inventory Fresh QA Worker.app/Contents/MacOS/StorageMonitor
   with candidate 2 (SHA-256 0525bdf66353c2af6c6dcd516985bfdfdb9fd30938c9f8901298ef6d19b20307) and ad-hoc re-sign only
   that bundle with identifier local.macbook.storage-monitor.inventory-fresh-qa (expected SHA-256 afterwards
   0c24644ffc01f006d39a10f4ae3d437042ac06843d86c4807873de38ea90007e).
5. Run that QA executable's inventory-resume --data-dir build/inventory-fresh-20261023T031313Z/data, then
   launchctl bootstrap gui/501 /Users/nicholaslippa/storage-checker/build/inventory-fresh-20261023T031313Z/inventory-worker.plist
6. Observe read-only for at least three slices.
If a post-upgrade check fails, you may boot out the same QA label and restore the old QA executable and the backed-up
database from build/inventory-qa-upgrade-20261023/qa-pre-upgrade/, then bootstrap the same plist.
Not included: any production label, app, LaunchAgent or database; the DMG; install; commit; push.
```

If one step is still denied, either run `/permissions`, open Recently denied and press `r` on that exact call, or press Shift+Tab to leave auto mode and answer that one prompt with "Yes". I will stop and report the exact denied step; I will not try another command instead.

## 6. Revocation

- **Stated approval:** it ends with the session, so there is nothing to revoke. To withdraw it earlier, send "Authorization withdrawn". I will stop at the next step boundary, leaving QA paused or resumed, whichever is consistent at that point.
- **If you chose persistent `permissions.allow` rules instead:** delete those entries from the file you put them in, for example `/Users/nicholaslippa/storage-checker/.claude/settings.local.json`, or remove them in `/permissions`. They take effect in new sessions.

## 7. Safe QA shutdown and upgrade sequence (no timing watcher)

Evidence from the supervisor and worker code:
- `supervise.py` exits with the worker's exit code.
- The worker checks `inventory.cancel` in the same places as its budget deadline: before each job and each batch, and inside each directory read. Each listing batch is committed, so a cancel ends the slice exactly the way budget expiry does, but exits **0** instead of 75.
- `KeepAlive {SuccessfulExit=false}` relaunches only after a non-zero exit. A cancelled slice is therefore **not** relaunched; there is no 10-second race.
- **Observed precedent:** the supervisor's own resource guard wrote `inventory.cancel` at 03:39:49Z. The worker logged `outcome interrupted, reason cancelled` 3 s later with partial results retained, and the job did not restart within the throttle interval; the next slice began 10 minutes later.

Steps:
1. **Preflight, read-only:** the hashes in §9, one supervisor and one worker, and the reconcile row from an APFS clone.
2. **Write the pause file**, `cancel\n` with mode 0600. Do not use `inventory-request pause`, because it also touches the watched folder.
3. **Confirm the exit:** the `slice_end` row has `exit_code` 0, no `supervise.py` or `inventory-work` process for `R` remains, `launchctl print` shows the job not running, and the last `inventory {…}` log line has `reason: cancelled`.
4. **Bootout** the now-idle QA label. Nothing is killed; this removes `WatchPaths`, so a stray request file cannot relaunch the old code. While loaded, a relaunch would still run old-code reconciliation before honouring the pause.
5. **Back up** with `.backup`, nothing writing, into `U/qa-pre-upgrade/`; run `integrity_check` on the copy and record its SHA-256. Then copy the app, plist, `supervise.py`, `run.json`, samples and logs alongside it.
6. **Swap and re-sign** the executable only: hash `0525bdf6…` before signing and `0c24644f…` after, and `codesign -v --strict` must pass.
7. **Resume** with `inventory-resume`, which removes the pause file and drops one request while the job is unloaded, then **bootstrap** the same plist. Confirm one supervisor, one worker, and the expected executable hash.
8. **Observe three slices, read-only:** `inventory events` lines, the reconcile row (no new `created_at`/`request_sequence` without a logged gap), the cursor, CPU and RSS, and database size.

The database is preserved throughout: writes stop only at a committed boundary, the backup is taken with no writer, the migration is additive (0.73 s on a clone), and no step resets the catalog, cursor, generation or frontier.

**This stops the slice early, at a committed batch boundary.** If you require the slice to run its full 1,200 s, the smallest safe change is a hold check in `supervise.py`: before `Popen`, exit 0 if `run / 'hold'` exists. Python reads the script at each launch, so the next launch, 10 s after the slice's exit 75, would exit without starting a worker, and launchd would not relaunch it again. That edit changes supervisor configuration (SHA `7a25f8f9…`), so it needs its own authorization. **It has not been implemented.** Stopping early loses only the remainder of an old-code slice, whose work the old code already discards on each false reset.

## 8. Remaining blockers

- Your stated approval (§5) is the only blocker.
- An unauthorized step, or a check failure before the swap, leaves QA paused and unchanged, and I report it.
- Rollback conditions and risks are unchanged from `QA-UPGRADE-APPROVAL.md` §6–7.
- That document's step 5 and step 7 hash checks were corrected today. They previously expected `0525bdf6…` after re-signing, which would have failed falsely.

## 9. Can the upgrade proceed without weakening unrelated protections?

**Yes.** A stated approval leaves the classifier, every hook, every settings file and all production protections exactly as they are. It applies only to the named QA job, label, paths and hashes, and only in this session.

### State at inspection (13:01–13:05 UTC, read-only)

| Item | Value |
|---|---|
| QA | launchd `state = running`, `runs = 33`, last exit 75; supervisor pid 1612, worker pid 1621, slice started 12:43:19Z; no `inventory.cancel` |
| Old QA executable | `25c49e96…4822e`, unchanged |
| Plist / supervisor | `6caea476…8d77` / `7a25f8f9…55f2`, unchanged |
| Candidate 2 | `0525bdf6…b20307`, present and unchanged; re-signed copy (scratch rehearsal) `0c24644f…90007e` |
| QA database | 1,448,464,384 bytes; APFS clone `quick_check` ok |
| Catalog | 3,005,417 nodes; jobs 476,969 complete, 1 enumerating, 273 pending |
| Reconciliation | frontier 623,778 of 2,980,782; `request_sequence` 1,127,814; `created_at` = 11:43:03Z, so there has been no new reset since then |
| Production | all four recorded hashes unchanged |
| Actions taken | none on QA or production; scratch-only clones in the session scratchpad |
