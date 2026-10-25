#!/usr/bin/env python3
"""Read-only inventory query benchmark; never initializes or refreshes an index."""
import argparse
import datetime
import json
import pathlib
import sqlite3
import statistics
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=pathlib.Path, required=True)
    parser.add_argument("--binary", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1] / "build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor")
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--under", type=int, help="Also benchmark this selected subtree")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    directory = args.data_dir.resolve()
    database = directory / "history.sqlite3"

    def command(arguments):
        result = subprocess.run([str(args.binary.resolve()), *arguments, "--data-dir", str(directory)], check=True, capture_output=True, text=True, timeout=10)
        return json.loads(result.stdout)

    report = {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "status": command(["inventory-status"]), "queries": {}}
    queries = {"navigation": ["inventory-children"], "largest_directories": ["inventory-largest", "directories"], "largest_files": ["inventory-largest", "files"], "search": ["inventory-search", "Library"]}
    if args.under is not None:
        queries["selected_subtree_files"] = ["inventory-largest", "files", "--under", str(args.under)]
        queries["selected_subtree_directories"] = ["inventory-largest", "directories", "--under", str(args.under)]
    for name, query in queries.items():
        times = []
        try:
            for _ in range(max(1, min(100, args.repetitions))):
                started = time.perf_counter()
                page = command([*query, "--limit", "100"])
                times.append((time.perf_counter() - started) * 1000)
            report["queries"][name] = {"milliseconds": times, "median_ms": statistics.median(times), "items": len(page["items"]), "has_more": page["hasMore"]}
        except (subprocess.SubprocessError, json.JSONDecodeError) as error:
            report["queries"][name] = {"error": str(error), "milliseconds": times}
    # Use the existing kind index; hold no read transaction during subprocess measurements.
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.1)
    try:
        connection.execute("PRAGMA query_only=ON")
        report["indexed_entries"] = dict(connection.execute("SELECT kind,COUNT(*) FROM inventory_nodes WHERE generation_id=(SELECT id FROM inventory_generations WHERE active=1) GROUP BY kind"))
    finally:
        connection.close()
    report["database_files_bytes"] = {p.name: p.stat().st_size for p in directory.glob("history.sqlite3*") if p.is_file()}
    output = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(output)
    print(output, end="")


if __name__ == "__main__":
    main()
