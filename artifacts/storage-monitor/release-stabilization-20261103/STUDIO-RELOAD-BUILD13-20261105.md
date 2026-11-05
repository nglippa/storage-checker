# Studio Reload feedback — build13 candidate

Date: 2026-11-05. Candidate: version 2.2.0, build 13, selected with environment overrides. `scripts/version.env` remains release 2.2.0 (10). Supersedes the build12 candidate ([build12 receipt](STUDIO-RELOAD-BUILD12-20261105.md)).

## Change from build12

There is one source change, in `SourcesGUI/InventoryView.swift`. The catalog error panel now applies `.accessibilityElement(children: .contain)` before `.accessibilityIdentifier("inventory.error")`. In build12 the panel was a plain `HStack` carrying an identifier, and its Retry button could not be resolved through accessibility by `inventory.retry`. The build12 native run therefore could not press Retry. This change has no visual effect. It matches the existing `inventory.lifecycle` placeholder pattern. All other build12 behavior is unchanged. `build13-source-sha256.json` differs from `build12-source-sha256.json` only for that file.

## Verification

- `scripts/test-gui.sh`: **PASS**, exit 0, 1166 GUI model/read-only tests. Log: `build13-presentation-tests.log`.
- `scripts/test-inventory-model.sh` (SDK 26.5): **PASS**, exit 0, 128 tests, 0 failed. Log: `build13-inventory-model-tests.log`.
- Universal packaging: **PASS**, exit 0, all 25 DMG checks. Both binaries are arm64 and x86_64, targeting macOS 14.0, with deep/strict signature verification. Log: `build13-package.log`.
- Direct packaged self-test from a read-only `-nobrowse` mount: **PASS**, 238 tests, process exit 0. codesign deep/strict exit 0, detach exit 0. Receipt: `build13-packaged-selftest.json` and `.log`.
- Freeze check: all 71 source/build input hashes in `build13-source-sha256.json` still matched after packaging.

### Native check (MacBook, user-authorized 60-second window)

The window was open 4.8 s and was then closed; viewer termination was confirmed. The target was the staged build13 viewer (CFBundleVersion 13, viewer CDHash `e1f874ecbe66598e9d21b08fb7e0c830398bd42a`, helper CDHash `a9b05b46409bf9a5ba1edf64f2598dd9d266eb2e`). It was launched by LaunchServices with process-local restoration isolation against the disposable `reload-verification.sqlite3` fixture. Only own-PID AXPress actions were used; there was no keyboard or coordinate input. **PASS**, helper exit 0:

1. The inline explanation and hover help are present.
2. Manual Reload: the button disabled immediately, with toolbar value `Reloading saved inventory…`. The page read completed (2 → 3), and `Saved inventory reloaded at 11:12:43 AM.` appeared inline and as the toolbar value.
3. A forced lock on the disposable fixture only made the header read `Saved inventory could not be reloaded`. The friendly explanation, Retry and a collapsed `Technical details` appeared. Raw SQLite text was hidden, the old success notice was hidden, and all six saved folders remained visible.
4. **Retry resolved by its `inventory.retry` identifier.** After the lock was released, Retry was pressed and disabled immediately. The read completed (3 → 4), the failure wording cleared, Reload was re-enabled, and `Saved inventory reloaded at 11:12:45 AM.` appeared. All six folders remained.

Evidence: `build/studio-reload-build13-verification/native-reload/` (cycle and driver results, harness sources, screenshots `native-build13-normal-completion.png`, `-friendly-error.png`, `-retry-completion.png`). The harness used fallbacks (visible failure wording; a button titled or described "Retry"), and it records which one matched. In this run the Retry button matched by identifier.

**NOT VERIFIED:** visible Resume interaction; Settings navigation; Enable/Repair; normal restoration/startup without QA overrides; Gatekeeper first launch and quarantine acceptance; physical Intel/macOS 14 execution.

## Artifact and delivery

`build/dist/Storage-Monitor-2.2.0-Studio-reload-build13-20261105.dmg`: 17,152,256 bytes, SHA-256 `6f16f048e744edd29de64aaef7474ed0359601aabc88549bd068cb39c99c8701`. Ad-hoc signed; informational Gatekeeper assessment rejected it. It is not Developer ID signed or notarized.

Delivered with `rsync --ignore-existing` to `Mac-Studio.local:~/Downloads/` together with its `.sha256`; `shasum -c` OK on the Studio. **Not installed**: the Studio still runs installed build 10. The build11 and build12 DMGs remain alongside it; build13 is the one to install.

## Safety

The only GUI activity was the single user-authorized QA window above. There were no installs, commits, pushes, production database or service changes, active QA worker changes, or unrestricted scans. Fixtures are disposable paths under `/private/tmp`.
