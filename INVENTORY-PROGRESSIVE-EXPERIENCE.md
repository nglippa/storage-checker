# Progressive storage exploration

This development pass uses bounded synthetic scopes only. Production, the active QA worker/database, and the preserved evidence snapshot are outside the pass. Product targets (usable within seconds; meaningful in 30–120 seconds) require measurement; bounded results do not establish full-volume performance or production readiness.

## Existing launch behavior, inspected before changes

`StorageMonitorViewerApp` constructs `ViewerStore` and starts the Monitoring section. `ViewerStore.start()` independently requests live capacity and historical SQLite data. The capacity probe uses a detached utility task; history uses a read-only actor and short transaction. Inventory has a separate read-only query actor, 100 ms busy timeout, query deadline, and 100-row pages. Launch never waits for inventory completion and does not initiate a filesystem crawl.

Two presentation dependencies obscured those capabilities: `HistoryView` hid the capacity overview until a recorded reading existed, and inventory reloads depended on history snapshot publication. The inventory browser already exposed partial records, breadcrumbs, search, pagination and largest-item queries. Its first load unnecessarily requested the root twice, section changes discarded browser state, and partial directory aggregates were not published until a whole listing finished.

## Implemented changes

Live capacity now renders independently of recorded history. Recorded changes/history remain their own source; inventory is not added to APFS used space. Existing overview typography and layout are reused. The root owns the inventory browser model so navigation survives section changes. A single initial load returns the selected page; later reloads preserve committed rows, selection, mode and sorting.

The existing viewer timer now ticks every two seconds while the app/window is active. It refreshes only the visible busy inventory's status and selected page, backs off to 30 seconds when idle, and retains history's 30-second and capacity's 60-second cadence. It runs no filesystem scanner. History-read failure cannot prevent inventory updates. Queries execute through the read actor, never on the SwiftUI main actor.

Navigation to unfinished work enqueues a coalesced `focus` request. A complete cached directory opens without waking a worker or replaying events. “Prioritize this folder” explicitly repeats that scheduling intent; it does not request a refresh. “Go to folder…” uses a native directory picker, resolves known indexed ancestors, and follows discovery toward an unindexed requested path without blocking the interface. Index lookups refuse symbolic-link/file traversal and reject paths outside the selected startup Data scope. Explicit folder/full refresh actions retain their original authority semantics.

## Priority architecture

There is one inventory engine and the existing durable directory-job queue. `focus.json` is a last-selection mailbox, atomically renamed to a claimed file before consumption; a crash retains the claim and a newer mailbox is not accidentally deleted. Focus is scheduling evidence only: it does not reset jobs, listing tokens, request sequences, cleanup authority, or completed measurements.

The additive `inventory_focus` table stores at most 16 generation/path intents for five minutes. Duplicate paths coalesce; newer interactive focus precedes initial hints. A small serial request writer rejects obsolete UI revisions before publication, so out-of-order detached navigation cannot overwrite the newer selection. The scheduler resolves the closest indexed pending directory, so deeper requests promote necessary ancestors as discovery progresses. Complete, inaccessible, absent, excluded and non-directory targets do not trigger repeated enumeration merely because they are viewed.

At most three focused quanta precede a background quantum. A quantum is at most two existing bounded entry batches when focus work exists. Large listings retain committed checkpoints and open handles; at most four handles are retained under preemption. Evicted or interrupted handles replay committed names safely, without rereading their metadata as new entries. This preserves generation authority and crash safety. A blocking filesystem syscall still requires the existing watchdog and cannot be preempted immediately.

New startup Data generations receive six lightweight hints for the current user's Downloads/Documents/Movies/Developer/Caches and Data Applications. These are conditional requests resolved through discovered parents, not an extra discovery pass or permission assumption. No second directory job is created for a hinted path. Scoped benchmarks do not pretend that these whole-volume hints were measured on a complete disk.

## States and sizes

No persisted lifecycle states are invented. The presentation derives:

| Presentation | Existing evidence |
| --- | --- |
| Not yet indexed | No catalog/root record |
| Discovered | Pending listing, no observed contents/size |
| Indexing | Durable job is enumerating |
| Partial measurement | Incomplete descendants/listing with observed bytes |
| Complete | Complete value and no qualifying outstanding invalidation |
| Previously measured | Stale value awaiting reconciliation |
| Access restricted | Unknown value with permission/privacy/consent reason |
| Unavailable | Blocked I/O/error; excluded locations remain outside measured scope |

Incomplete sizes say “Partial”; stale sizes say “Previously.” Current logical/allocated fields remain nil while stale; separate `previousLogicalBytes`/`previousAllocatedBytes` fields preserve useful prior observations without weakening the existing reader contract. An incomplete zero aggregate says “No size yet.” Access gaps never become zero. Logical bytes remain distinct from attributed allocation. No `≥` claim is made about unique APFS physical storage. Mixed largest-item rankings explicitly disclose partial/stale values.

The first partial batch publishes aggregates; subsequent publication is throttled to roughly once a second, with a final authoritative derivation at EOF. Refresh listings with earlier completed authority remain stale until their newer listing and cleanup establish current totals. The implementation reuses existing ownership and aggregate calculations rather than creating an independent size estimator.

## Progress and readiness

Progress uses found items/folders, completed folders, queued directory jobs, coverage gaps, elapsed generation time and separate discovery/reconciliation/changed-update/idle phases. A growing discovery denominator never produces a completion percentage. Pending jobs and unexpanded broad reconciliation remain distinct.

Optional QA-only `--readiness-output /absolute/path` records monotonic model/data milestones for capacity, history, inventory status and a nonzero qualified page with priority support ready (its request succeeded, or its complete cached listing needs no new work). It is disabled by default and explicitly does not claim native rendering readiness. Native interaction verification supplies separate evidence. A timer alone cannot certify a meaningful page.

## Verification results and remaining acceptance

Verification completed on the Mac mini M4 Pro / 24 GiB. The M2 Air / 8 GiB was unavailable. All timings are scoped observations, not full-volume estimates.

### Measured startup and useful exploration

| Milestone | Measurement | Evidence and scope |
| --- | --- | --- |
| Live volume + existing history visible | **1.51 s** launch-to-native-AX upper bound | Fresh catalog with two synthetic historical readings; inventory still uninitialized |
| Live/history data ready | **0.43–0.68 s** after viewer model creation | Detached live probe and independent historical reader; data readiness, not frame timing |
| First native page with nonzero qualified sizes | **0.71 s** after bounded index process start | Model's monotonic readiness, correlated with recorded process start; positive size and priority readiness required |
| Native partial inventory exposed | **1.81 s** after index process start | AX header: discovery active, 987 items, 31 listings queued; native navigation controls enabled |
| Fresh default native scope complete | **4.184 s**, 13,163 catalog nodes / 40 directories | Single isolated initial catalog; default 256-entry batches; 17.9 MB reported peak RSS |
| Focused partial investigation | **105 ms** for a 350-entry scheduling window | 288 focused file names and 62 background file names committed; selected folder has nonzero partial allocation and browsable contents |
| Navigation query | **18.17 ms median**, 12.16–26.63 ms (20 queries) | 100-row children reads on the incomplete fixture, including actor/SQLite work |
| Visible busy-page updates | Approximately **2.0–2.13 s** between successful loads | Bounded QA readiness retains the last 16 load times; explicit navigation/reload can add a load |
| Cached restart | **0.57 s** page data readiness | Same completed isolated catalog; no new worker or crawl |

“Meaningful” was not inferred from a timer or an item threshold. It required actual committed contents with nonzero qualified size and the ability to request focus. Native AX separately confirmed the incomplete page and controls. The operator also exercised native folder navigation and the directory picker through a deep indexed path. Data-ready timestamps are explicitly distinguished from rendered/interactive verification. Deep AX traversal of a 100-row table sometimes exceeded the automation tool's timeout; bounded-depth AX and native screenshots confirmed the app remained responsive. Shared-desktop focus/display changes prevented a reliable new screenshot artifact and a controlled foreground-idle refresh trace; no unrelated application's capture is used as evidence. Idle backoff is implemented, while the recorded inactive cached window performed only its initial page load.

The earlier native interaction stress run used **one-entry batches deliberately** to prolong indexing: 13,163 nodes completed in **58.324 s**, peak RSS **20.6 MB**. Partial directory sizes and counts were visible while it ran. That timing is a stress setting, not the default paid-app indexing configuration or a full-volume benchmark.

### Default indexing and steady-state bounded probes

Three fresh default-batch runs each indexed 4,089 nodes / 86 directories:

- Initial duration **1.052 / 0.953 / 1.127 s**; zero repeated listings, zero retry listings.
- First browsable commit **71–89 ms**; 1,000 discovered names **226–347 ms**. That threshold is a throughput milestone, not the definition of meaningful UI.
- **3,629–4,290 new names/s**, **76–90 completed directories/s**; process-reported peak RSS **16.5–17.4 MB**.
- SQLite **1,716,224 bytes**, growth **1,662,976 bytes**, DELETE journal / zero WAL footprint.
- Nine real FSEvents updates: **0.670 s median**, **0.570–0.836 s** range.
- Competing insert/rollback probes: **90/90 passed**, maximum **203.84 ms**. These proxy capacity writes are not a full production attribution-check benchmark.
- Sampled driver CPU peaks **72–77%** (sampling includes partial/update phases). UI peak memory was not captured; backend RSS must not be presented as the full SwiftUI application's footprint.

Earlier same-size correction-pass runs were 1.04–1.44 s. The new results show no observed regression in this workload, but concurrent QA activity, warm filesystem caches and host load prevent a controlled speedup claim. The independent lightweight metadata enumerator still matches counts and hard-link/logical/allocated totals; it omits persistence, aggregates, checkpoints and events and is not a comparable product.

The focus fixture uses a 1,200-entry directory, 32 other directories, a deep hierarchy, mixed file sizes, hard links, a symlink, permission denial, interrupted work and subsequent filesystem changes. Nine interactive quanta and three background quanta demonstrate the scheduling budget. A completed listing is never repeated merely because it is viewed. Bounded handles can replay committed names after eviction/crash; that recovery work is counted separately from newly measured entries.

### Regression and build results

| Check | Result |
| --- | --- |
| Inventory, lifecycle, boundary and progressive integration suites | **145 PASS**, exit 0; original assertions retained |
| Monitor suite | **192 PASS**, exit 0 |
| Viewer model/read-only suite | **284 PASS**, exit 0 |
| Total checks | **621 PASS** |
| Background application build | PASS |
| Native viewer build | PASS with existing macOS 26.5 SDK override |
| Snapshot regression on a fresh disposable clone | PASS: 20 current root children retained; 256 obsolete markers safe; valid absent-record pruning still works |
| Actual priority/crash recovery | PASS: SIGKILL after 258 committed records, focus lease survived, same generation resumed, 3,002 nodes / exact 3,072,000 logical bytes, no duplicate completed listing |
| SQLite | Snapshot and synthetic integrity checks pass; no foreign-key violations |
| Historical preservation | Snapshot's seven original tables equal their source; native synthetic history preserved |

Progressive checks cover partial browsing before completion, unknown size presentation, growing discovery denominators, indexed ancestor resolution for a deep unindexed path, symlink/scope rejection, rapid/coalesced navigation, cancellation of obsolete queued reads before SQLite opens, fair interactive quanta, interrupted prioritized checkpoints, inaccessible-directory no-retry behavior, no repeated completed listings, events/refreshes during priority, obsolete cleanup protection, hard-link transfer after legitimate deletion, directory disappearance and large-page queries. Invalid/expired mailbox and claimed-file recovery regressions cover worker startup safety. Query cancellation is checked before opening SQLite and inside the progress callback so rapid navigation cannot leave expensive obsolete reads queued indefinitely.

The default macOS 27 SDK's absent SwiftUI macro plugin remains an existing environment limitation. Both this pass and the prior correction use the already installed 26.5 SDK; no toolchain or system settings were changed.

### Files and schema

Core changes: `Sources/Inventory.swift`, `Sources/InventoryCommands.swift`; shared reader/requests/presentation: `SourcesShared/InventoryModels.swift`, `InventoryRequests.swift`, new `InventoryPresentation.swift`; native UI: `SourcesGUI/StorageMonitorApp.swift`, `InventoryView.swift`, `HistoryView.swift`, `OverviewView.swift`.

Tests/tooling: new `tests/InventoryProgressiveTests.swift`, integration entry point and GUI presentation tests; `scripts/test-inventory.sh`, `scripts/test-gui.sh`; new bounded-only `scripts/progressive-experience-verification.swift` and `scripts/build-progressive-verification.sh`. This report and `INVENTORY-VERIFICATION.md` record results.

The only new persisted schema is additive `inventory_focus`, keyed by generation/path, with expiry and source. Existing jobs, listing-generation authority, cleanup provenance and history are preserved; no catalog reset or destructive migration is used. Reader fields and presentation phases are rendering-independent and remain suitable for a future tree query client.

### Preservation, limits and production assessment

Final hashes match this pass's baseline for the active QA executable/configuration, installed production binaries/LaunchAgent, and original evidence snapshot. Production still has **zero inventory tables**. The active QA database was not opened or changed by this pass; the QA service was only queried read-only and remained running. Its PID can change through its existing independent launchd lifecycle. Only generated bounded workers were started/killed, and all of them exited. No full-volume crawl, production migration, installation, settings change, commit, push, deploy or visualization was performed.

Local evidence is intentionally under ignored `build/inventory-progressive/`: `experience.json`, `default-initial-benchmark.json`, native readiness/AX records, `native-final-worker.stdout.log`, `snapshot-regression.json`, `crash-recovery.json`, suite logs and `preservation-final.json`. Final inventory/build logs also retain their `build/inventory-progressive-*.log` paths. Snapshot mutation used `build/inventory-correction/progressive-snapshot-copy.sqlite3`, never the original.

**The bounded first-use targets are met on this development machine; customer-scale targets remain unverified.** Full-volume initial duration, steady-state incremental behavior, memory on the smaller machine, full monitoring latency under load and worst-case very wide-directory aggregation cost need representative measurement. The first partial aggregate is prompt and later updates are throttled, but direct-child SUMs still grow with directory width. Blocking filesystem calls still rely on the existing watchdog. Initial-path hints have not been benchmarked on a fresh full startup Data volume. No full-volume result or Disk Inventory X parity is claimed.

The app can now expose live/history information independently and let indexing progressively improve focused exploration. It is **not production-ready** until the remaining full-volume acceptance is measured under separate authorization with no competing QA crawl. The data contract supports a future visualization, but beginning the luminous rendering phase is not recommended before those correctness/performance acceptance gaps close.

