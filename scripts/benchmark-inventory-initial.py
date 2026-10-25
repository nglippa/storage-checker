#!/usr/bin/env python3
"""Bounded, isolated first-index measurements. Never starts a full-volume crawl."""
import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import sqlite3
import stat
import subprocess
import time
import uuid


def enumerate_metadata(root):
    start = time.monotonic()
    device = root.stat().st_dev
    stack, seen = [root], set()
    counts = {"directory": 1, "file": 0, "symlink": 0, "other": 0}
    logical = allocated = 0
    while stack:
        with os.scandir(stack.pop()) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if info.st_dev != device:
                    continue
                if stat.S_ISDIR(info.st_mode):
                    counts["directory"] += 1
                    stack.append(Path(entry.path))
                else:
                    kind = "file" if stat.S_ISREG(info.st_mode) else "symlink" if stat.S_ISLNK(info.st_mode) else "other"
                    counts[kind] += 1
                    if (info.st_dev, info.st_ino) not in seen:
                        seen.add((info.st_dev, info.st_ino))
                        logical += info.st_size
                        allocated += info.st_blocks * 512
    return {"seconds": time.monotonic() - start, "entries_by_kind": counts,
            "logical_counted_once": logical, "allocated_counted_once": allocated,
            "limitations": "Warm synthetic scope; no persistence, events, checkpoints, aggregates, permissions gaps or SQL. Does not measure unique physical APFS storage."}


def child_limits():
    os.nice(15)
    resource.setrlimit(resource.RLIMIT_CPU, (90, 90))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--files", type=int, default=4000)
    parser.add_argument("--directories", type=int, default=80)
    parser.add_argument("--trials", type=int, default=1)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--keep", action="store_true", help="Retain generated fixture/state for native QA")
    args = parser.parse_args()
    if not (1 <= args.files <= 10000 and 1 <= args.directories <= 200 and 1 <= args.trials <= 3):
        parser.error("Bounded limits: 1..10000 files, 1..200 directories, 1..3 trials")
    repo = Path(__file__).resolve().parents[1]
    executable = repo / "build/InventoryVerification"
    if not executable.exists():
        parser.error("Run sh scripts/build-inventory-verification.sh first")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    qa = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/local.macbook.storage-monitor.inventory-qa"], capture_output=True, text=True)
    active = "state = running" in qa.stdout
    results = []
    for trial in range(args.trials):
        root = Path(f"/private/tmp/storage-monitor-benchmark-{uuid.uuid4()}")
        state = Path(str(root) + "-state")
        root.mkdir(mode=0o700)
        try:
            for i in range(args.directories):
                (root / f"folder-{i:03d}").mkdir()
            for i in range(args.files):
                (root / f"folder-{i % args.directories:03d}" / f"file-{i:05d}").write_bytes(bytes([i % 251]) * 4096)
            for i in range(5):
                (root / f"empty-{i}").mkdir()
            os.link(root / "folder-000/file-00000", root / "hard-alias")
            (root / "symlink").symlink_to("folder-000")
            with (root / "sparse").open("wb") as handle:
                handle.truncate(8 * 1024 * 1024)
            lightweight = enumerate_metadata(root)
            stdout = args.output.with_suffix(f".trial-{trial}.stdout.log")
            stderr = args.output.with_suffix(f".trial-{trial}.stderr.log")
            samples, writes, probe_failures = [], [], []
            with stdout.open("w") as out, stderr.open("w") as err:
                process = subprocess.Popen(["/usr/sbin/taskpolicy", "-b", str(executable), "--root", str(root), "--state", str(state)], cwd=repo,
                                           stdout=out, stderr=err, preexec_fn=child_limits)
                started = time.monotonic()
                while process.poll() is None:
                    if time.monotonic() - started > 180:
                        process.kill()  # Only the child created by this harness.
                        process.wait()
                        raise RuntimeError("Bounded benchmark exceeded 180-second resource limit")
                    sample = subprocess.run(["ps", "-p", str(process.pid), "-o", "pcpu=,rss="], capture_output=True, text=True)
                    try:
                        cpu, rss = map(float, sample.stdout.split())
                        samples.append({"seconds": time.monotonic() - started, "cpu_percent": cpu, "rss_bytes": int(rss * 1024)})
                    except ValueError:
                        pass
                    db = state / "history.sqlite3"
                    if db.exists() and len(writes) < 30:
                        connection = None
                        try:
                            connection = sqlite3.connect(db, timeout=3)
                            # Wait for the monitor schema before measuring contention.
                            if connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='readings'").fetchone()[0]:
                                began = time.monotonic()
                                connection.execute("BEGIN IMMEDIATE")
                                connection.execute("INSERT INTO readings(id,timestamp,container,free,used,volumes) VALUES(987654,0,'benchmark',0,0,'[]')")
                                connection.rollback()
                                writes.append((time.monotonic() - began) * 1000)
                        except sqlite3.Error as error:
                            probe_failures.append(str(error))
                        finally:
                            if connection:
                                connection.close()
                    time.sleep(0.1)
                if process.returncode:
                    raise RuntimeError(f"Benchmark exited {process.returncode}: {stderr.read_text()}")
            measured = json.loads(stdout.read_text().splitlines()[-1])
            observed = {row["kind"]: int(row["n"]) for row in measured["entries_by_kind"]}
            if observed != {k: v for k, v in lightweight["entries_by_kind"].items() if v}:
                raise RuntimeError(f"Enumeration oracle mismatch: {observed} != {lightweight['entries_by_kind']}")
            if int(measured["initial_totals"]["total_logical"]) != lightweight["logical_counted_once"] or int(measured["initial_totals"]["total_allocated"]) != lightweight["allocated_counted_once"]:
                raise RuntimeError("Independent hard-link/logical/allocation oracle mismatch")
            measured.update({"lightweight_metadata_enumerator": lightweight,
                             "peak_sampled_cpu_percent": max((s["cpu_percent"] for s in samples), default=None),
                             "peak_sampled_rss_bytes": max((s["rss_bytes"] for s in samples), default=None),
                             "samples": samples, "competing_insert_rollback_ms": writes, "probe_failures": probe_failures,
                             "fixture_root": str(root) if args.keep else "removed generated fixture"})
            results.append(measured)
        finally:
            if not args.keep:
                shutil.rmtree(root)
                shutil.rmtree(state, ignore_errors=True)
                shutil.rmtree(Path(str(state) + "-partial"), ignore_errors=True)
    report = {"qa_worker_active_at_start": active, "full_volume_benchmark": "NOT RUN; requires separate authorization and no competing QA crawl",
              "resource_limits": {"files_max": 10000, "directories_max": 200, "cpu_seconds": 90, "wall_seconds": 180, "nice": 15, "taskpolicy": "background"},
              "trials": results}
    args.output.write_text(json.dumps(report, indent=2))
    print(json.dumps({"report": str(args.output), "trials": len(results), "qa_worker_active": active}))


if __name__ == "__main__":
    main()
