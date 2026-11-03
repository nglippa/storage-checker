# Migration Readiness — performance results

All numbers were measured on this Mac (Apple silicon, macOS 27, APFS) on 2026-11-03, while other work ran on the machine (dozens of Codex app-server processes and the production inventory worker). Release builds (`-O`). Commands:

- `scripts/benchmark-migration-readiness.sh synthetic`: builds and indexes a fixture under `/private/tmp`.
- `scripts/benchmark-migration-readiness.sh catalog <clone>`: an APFS clone (`cp -c`) of the real catalog, taken while no journal was present and verified with `PRAGMA quick_check` = ok. The clone was only read and has been deleted.
- `scripts/test-inventory-model.sh`: navigation responsiveness during a scan.

Percentiles are nearest-rank over the stated sample count. Small samples (n = 3) are reported as measured, not extrapolated.

## Fixtures

| | Synthetic | Real catalog clone |
|---|---|---|
| Catalog nodes | 27,435 (max id 27,435) | 2,807,179 (max id 3,117,887) |
| Hierarchy | 400 folders × 50 files, plus image folders | the startup Data volume as indexed |
| Sparse candidates | 2,000 (1,000 × 12 GiB → REVIEW, 1,000 × 1.5 GiB → INFORMATIONAL), each 4 KB allocated | 0 meeting the 1 GiB floor |
| Sparse bundle | 1 bundle with 5,000 band files | — |
| Logical / physical | about 13.5 TiB logical, a few MB allocated (sparse) | — |

## Results

| Measurement | Result |
|---|---|
| Indexing, detection **disabled** (worker process, incl. launch) | n=3: p50 1,403 ms, p95/max 1,494 ms; all 3 complete, 27,435 nodes |
| Indexing, detection **enabled** (a detector refreshing every 50 ms during indexing; 21 passes) | n=3: p50 1,386 ms, p95/max 2,229 ms; all 3 complete, 27,435 nodes |
| Full detection pass, synthetic (fresh detector, 2,000 live `lstat`s) | n=7: p50 219 ms, p95/max 243 ms |
| Full pass with the shipped 2 ms pause between slices, synthetic | 229 ms (one slice; the catalog is under 50,000 ids) |
| One 50,000-id catalog slice, synthetic | n=21: p50 3.2 ms, p95 3.5 ms, max 3.6 ms |
| Hydrating 2,001 candidates (path and ancestry each) | n=5: p50 168 ms, p95/max 170 ms |
| Full pass, **real catalog** (63 slices) | n=3: p50 398 ms, p95/max 7,296 ms (the first pass after cloning, cold) |
| Slowest single slice, real catalog | 7.0 ms (the longest any one read held the catalog) |
| Full pass with the shipped 2 ms pause, real catalog | 562 ms |
| Pass with no catalog change, real catalog | n=5: p50 16.4 ms, p95/max 17.2 ms |
| Pass with no catalog change, synthetic (2,001 cached entries re-evaluated) | n=7: p50 27.4 ms, p95/max 27.9 ms |
| Pass after 50 changed candidates (worker relist, then incremental) | n=7: p50 39.3 ms, p95/max 42.6 ms; every pass incremental, no full rescan |
| Inspector recheck within 15 s (cached) | n=200: p50 0.00 ms, p95 0.00 ms, max 0.02 ms |
| Inspector recheck, forced `lstat` | n=200: p50 0.34 ms, p95 0.37 ms, max 0.46 ms |
| Structured Explorer visibility, filter off (1,079 laid-out nodes) | n=50: p50 2.34 ms, p95 2.42 ms, max 2.50 ms |
| Visibility, **Migration Review on** (500 targets, 57 highlighted) | n=50: p50 0.79 ms, p95 0.83 ms, max 0.93 ms |
| Folder loads during a running scan (browser model, small fixture) | n=12: p50 3.0 ms, max 3.3 ms; idle max 4.2 ms |

Numbers above are from the run on the final code (after the code-review fixes); an earlier run before those fixes gave the same picture. Detector counters over the synthetic churn run: 1 full scan, 7 incremental, 7 unchanged passes, 1 catalog slice, 7 changed-folder reads, 2,550 live checks, 27,864 cache hits.

## Interpretation

- **Normal inventory:** the worker is unchanged. In both modes all runs completed with identical node counts. Medians match (1,386 vs 1,403 ms). One of the three "enabled" runs took 2,229 ms, against a 1,494 ms maximum without detection. With n = 3 on a loaded machine this cannot be separated from noise, so it is reported as a possible slowdown of up to about 50 % in the worst case while a detector reads every 50 ms. The shipped controller runs at most one pass every 30 s, or 5 min during a first index. **Superseded by the controlled 60-run sample below.**
- **No second crawl:** a full pass reads the catalog, not the filesystem. On the 2.8 M-node real catalog that is 63 primary-key slices, each at most 7–10 ms across runs. With a rollback journal, that is the longest a detector read can delay a worker commit.
- **Cold start:** the first pass over a freshly cloned real catalog took 7.3 s in both benchmark runs (not yet in memory). It runs at utility priority on its own actor and reader, never on the main thread, and does not block navigation. The shipped controller starts it when the Storage section appears.
- **Steady state:** with no catalog change a pass costs about 16–32 ms and reads no candidate; after changes it reads only the changed folders.
- **Thousands of candidates:** hydration is about 0.1 ms per candidate (path and ancestry); 2,000 candidates cost about 0.2 s once, then are cached.
- **Sparse bundle with 5,000 bands:** bands under the 1 GiB floor never become candidates; band files inside a bundle are excluded from listing even when they would.
- **Inspector:** repeated selection does no filesystem work for 15 s; a fresh check is one `lstat` (under 0.5 ms).
- **Filter activation:** Migration Review is cheaper than the existing size filter pass. It is cached per layout, filter, selection and report.
- **Memory:** the report keeps at most 500 items; the cache holds one entry per candidate.

## Live catalog under a busy worker (found in native QA, fixed)

The first native launch opened the dev viewer on the real catalog (2.8 M nodes, 1.4 GB) while the production worker was reconciling. It showed "Migration readiness: unavailable (interrupted)".

A read-only probe of the live catalog, the same reads the viewer makes, found the cause:

- 50,000-id slices took **60–250 ms**, not the 3–10 ms measured on a warm, idle clone. The file was partly cold, and the worker was writing.
- **13 of 64 slices** hit the reader's 0.25 s deadline. One failed slice abandoned the whole pass.
- `accounting()` took 178 ms, also close to the deadline.

The clone benchmarks above did not show this because no worker was competing for the catalog.

**Fix:**

- Full-pass slices adapt: they start at 10,000 ids and aim for about 50 ms per read. A slice that hits the deadline is halved and re-read (minimum 500 ids); fast slices grow back to 50,000.
- Hydration uses one connection per 16 candidates; changed-folder reads use one connection per 32 folders.
- Status, accounting, change-journal, hydration and location reads are retried up to 4 times after a lock or a deadline interrupt (100–400 ms backoff). Real cancellation is never retried.

**Result on the live catalog** (shipped settings, read-only, worker running):

| Trial | Result | Time | Slices | Halved | Slowest slice |
|---|---|---|---|---|---|
| 1 | OK | 10.5 s | 173 | 0 | 201 ms |
| 2 | OK | 12.0 s | 189 | 1 | 217 ms |
| 3 | OK | 10.9 s | 175 | 0 | 174 ms |
| 4 | OK | 11.0 s | 191 | 0 | 178 ms |

The pass after trial 1 was incremental and took 109 ms. All four reported 3 REVIEW and 1 INFORMATIONAL: the native QA fixture under `/private/tmp`, which the production worker had indexed, and nothing else.

A full pass on a busy live catalog takes about 11 s in the background. A single read can still hold the shared lock for up to about 0.2 s while the catalog is cold.

## Controlled indexing sample (follow-up)

The first comparison had n = 3, and one run with a detector was 47 % above the slowest run without one. That cannot separate noise from a regression, so a controlled sample was run: `scripts/benchmark-migration-readiness.sh indexing 20`.

- Fixture: 1,200 folders × 60 files plus 2,000 sparse candidates and a 500-band bundle; 75,751 catalog nodes.
- The worker ran as its own process (production topology), with a fresh catalog each run.
- Three conditions, 20 runs each (60 total), in rotated and alternately reversed order to spread drift across conditions:
  - **none:** no detector.
  - **shipped:** one detector pass when indexing starts, which is what the controller can do at most during any 30 s (5 min during a first index).
  - **stress:** a detector pass every 50 ms for the whole run, 12 passes per index in the median.
- The machine was loaded throughout (1-minute load average 5.8–22.9, median 15.4).

| Condition | n | Median | Mean | p95 | Max | SD |
|---|---|---|---|---|---|---|
| none | 20 | 3,117 ms | 3,423 ms | 4,574 ms | 5,939 ms | 713 ms |
| shipped | 20 | 3,187 ms | 3,371 ms | 4,500 ms | 5,521 ms | 623 ms |
| stress | 20 | 3,297 ms | 3,573 ms | 5,582 ms | 6,893 ms | 955 ms |

All 60 runs exited 0 with outcome `complete` and the same 75,751 nodes.

| Comparison | Median difference | 95 % bootstrap CI of the median difference | Mann-Whitney (two-sided) |
|---|---|---|---|
| shipped vs none | +70 ms (+2.2 %) | −268 to +228 ms | p = 0.77 |
| stress vs none | +180 ms (+5.8 %) | −108 to +298 ms | p = 0.29 |

**Conclusion.** At the shipped cadence there is no detectable effect on indexing time; the interval excludes a median slowdown above about +7 %. This does not prove zero cost.

Under stress (about 12× the shipped read load during one index) there is no statistically significant difference, but the median is 5.8 % higher and the tail is heavier (p95 +1.0 s, max +0.95 s), so a small cost cannot be excluded. That is consistent with readers briefly holding the shared lock on a rollback-journal database. The shipped controller never reads at that rate.

## Finding: same-process writer and read-only reader (root cause)

The first indexing benchmark ran the worker inside the benchmark process. With any concurrent catalog reader there, the existing `InventoryReader.status()` as well as the detector, the worker intermittently failed with "SQLite inventory error: disk I/O error".

It was reproduced without any Storage Monitor code in a C program against the system library (`/usr/lib/libsqlite3.dylib`, SQLite 3.54.0): `evidence/sqlite-same-process-repro.c`. One writer connection ran `BEGIN IMMEDIATE; INSERT; COMMIT` in rollback-journal mode, 3,000 transactions per run, with these readers:

| Reader | Runs | Writer failures |
|---|---|---|
| none | 3 | 0 of 9,000 |
| separate process, read-only, reopening | 5 | 0 of 15,000 |
| same process, read-only, reopening | 17 | failures in 12 runs (1–352 per run) |
| same process, one persistent read-only connection | 5 | failures in 4 runs (119–260) |
| same process, read-only, `SQLITE_OPEN_FULLMUTEX` | 5 | failures in 3 runs (3–431) |
| **same process, read-write connection used only for SELECT** | 10 | **0 of 30,000** |

Every failure was extended code **3850 = `SQLITE_IOERR_LOCK`** at `BEGIN IMMEDIATE`, with `sqlite3_system_errno` = **9 (`EBADF`)**: the writer's lock request was rejected as a bad descriptor.

**Root cause, as far as can be established from outside SQLite:** the failure needs a *read-only* connection to the same database file in the *same process* as the writer. POSIX record locks are per process, and SQLite's Unix VFS shares one lock state per file per process. `EBADF` is what `fcntl` returns when a write lock is requested through a descriptor opened read-only. Opening the reader read-write removes the failure completely in this sample. The exact code path inside Apple's SQLite build was not inspected.

**Production exposure:**

- The viewer only reads the catalog: all catalog connections are read-only, and it never writes the catalog.
- The worker uses its one `InventoryReader` call before it starts writing, and that connection is closed when the call returns; it never reads concurrently.
- The QA worker is spawned as a separate helper process.

So no shipped process combines a concurrent read-only catalog connection with a catalog writer. The detector carries a code comment stating this invariant: it must not run in a process that writes the catalog. This is a pre-existing property of the reader design (the existing reader triggers it too), not something this milestone introduced.

If a future change must read and write the catalog in one process, either open the reader read-write with `PRAGMA query_only=ON`, or confine reads to the writer's own connection.

## Not measured

- The production app with a real Docker Desktop image (none is installed on this Mac, and `~/Library/Containers` is not indexed without Full Disk Access).
- Native frame times in the running app (NOT VERIFIED; see NATIVE-QA-PLAN.md).
