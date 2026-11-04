#!/usr/bin/env python3
"""Inspect generated scope; --execute explicitly runs bounded real launchd lifecycle tests. No native windows."""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, signal, sqlite3, subprocess, sys, time

source = Path(__file__).resolve().parents[1]
root = source / "build/lifecycle-qa/runtime"
workspace = source.parent
helper = root / "Bundles/Installer.app/Contents/MacOS/StorageMonitor"
records = []
def run(argv, timeout=45):
    began = time.monotonic()
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    records.append({"argv": argv, "exit": result.returncode, "seconds": round(time.monotonic() - began, 3), "stdout": result.stdout, "stderr": result.stderr})
    return result
def command(action, *options):
    return [str(helper), action, "--lifecycle-qa-root", str(root), *options]
def check(value, description):
    if not value:
        raise AssertionError(description)
    print("PASS " + description, flush=True)
    records.append({"assertion": description, "pass": True})
def rows(sql):
    try:
        with sqlite3.connect("file:" + str(root / "home/Library/Application Support/MacBook Storage Monitor/history.sqlite3") + "?mode=ro", uri=True, timeout=1) as db:
            return db.execute(sql).fetchall()
    except sqlite3.Error:
        return []
def wait_for(predicate, description, timeout=35):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if predicate():
            check(True, description); return
        time.sleep(.2)
    raise AssertionError("Timed out: " + description)
def protected():
    paths = list((Path.home() / "Library/LaunchAgents").glob("local.macbook.storage-monitor*.plist"))
    for app in [Path("/Applications/Storage Monitor.app"), Path.home() / "Applications/MacBook Storage Monitor.app"]:
        if app.exists():
            paths += [p for p in app.rglob("*") if p.is_file() and not p.is_symlink()]
    return {str(p): {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "inode": p.stat().st_ino, "mode": p.stat().st_mode, "size": p.stat().st_size, "mtime_ns": p.stat().st_mtime_ns} for p in paths}
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--guard-seconds", type=float, default=600)
    args = parser.parse_args()
    assert str(root).startswith("/private/tmp/") and root.resolve() == root
    readiness = json.loads((workspace / "readiness.json").read_text())
    check(all(hashlib.sha256((source / path).read_bytes()).hexdigest() == digest for path, digest in readiness["source_files"].items()), "disposable source matches build manifest")
    inspect = run(command("lifecycle-qa-inspect"))
    check(inspect.returncode == 0, "actual stable helper admits exact scope without production fallback")
    data = json.loads(inspect.stdout)
    labels = data["labels"]
    check(len(labels) == 3 and all(".lifecycle-qa." in label for label in labels), "exact three unique QA labels")
    for plist in data["generated_plists"]:
        argv = plist["ProgramArguments"]
        check(argv[argv.index("--root") + 1] == str(root / "fixtures") and argv[argv.index("--data-dir") + 1].startswith(str(root) + "/"), "generated " + argv[1] + " explicitly fixture rooted")
        wrong_image = run([str(helper), *argv[1:]])
        check(wrong_image.returncode != 0 and "pinned image role" in wrong_image.stderr, "stable installer cannot execute scheduled " + argv[1])
    guard = run([sys.executable, str(source / "scripts/lifecycle-qa-guard.py"), "--validate"])
    check(guard.returncode == 0, "independent teardown guard validates fixed namespace and image")
    if not args.execute:
        (workspace / "scope-inspection.json").write_text(json.dumps({"inspection": data, "records": records, "mutations": False, "gui_launched": False}, indent=2) + "\n")
        print(json.dumps({"scope_inspection": str(workspace / "scope-inspection.json"), "mutations": False}), flush=True)
        return
    domain = "gui/" + str(os.getuid())
    target = lambda label: domain + "/" + label
    before = protected()
    (workspace / "protected-before.json").write_text(json.dumps(before, indent=2) + "\n")
    for label in labels:
        check(run(["/bin/launchctl", "print", target(label)]).returncode != 0, "fresh namespace absent: " + label)
    before_overrides = run(["/bin/launchctl", "print-disabled", domain]).stdout
    guard_process = subprocess.Popen([sys.executable, str(source / "scripts/lifecycle-qa-guard.py"), "--watch", "--seconds", str(args.guard_seconds)], start_new_session=True, stdout=(workspace / "guard-output.log").open("w"), stderr=subprocess.STDOUT)
    paused = None
    succeeded = False
    def interrupt(signum, frame):
        raise SystemExit("Lifecycle harness interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupt); signal.signal(signal.SIGINT, interrupt)
    def install(role="V2", *options, ok=True):
        result = run(command("install", "--lifecycle-qa-version", role, *options))
        check((result.returncode == 0) == ok, "real installer " + role + (" succeeds" if ok else " reports injected failure"))
        return result
    try:
        wait_for(lambda: (root / "guard.jsonl").exists() and '"armed"' in (root / "guard.jsonl").read_text(), "independent guard armed before services")
        install("V1")
        check(all(run(["/bin/launchctl", "print", target(label)]).returncode == 0 for label in labels), "real launchd loads all three private plists")
        wait_for(lambda: rows("SELECT value FROM state WHERE key='lifecycle_qa_last_check_role'") == [("V1",)], "RunAtLoad V1 check commits actual capacity reading")
        wait_for(lambda: rows("SELECT root_path FROM inventory_generations") == [(str(root / "fixtures"),)] and rows("SELECT count(*) FROM inventory_nodes")[0][0] >= 5, "real inventory worker indexes only explicit fixtures")
        wait_for(lambda: "initialize-baseline terminal" in (root / "home/Library/Application Support/MacBook Storage Monitor/monitor.log").read_text(), "real baseline initializer finishes fixture-only work")
        installed = Path(data["generated_plists"][0]["ProgramArguments"][0])
        check(hashlib.sha256(installed.read_bytes()).hexdigest() == readiness["images"]["V1"]["sha256"], "actual installed V1 image matches immutable role")
        wrong_installer = run([str(installed), "install", "--lifecycle-qa-root", str(root)])
        check(wrong_installer.returncode != 0 and "pinned image role" in wrong_installer.stderr, "installed worker cannot act as stable installer")
        sentinel = "lifecycle-fixture-sentinel"
        database = Path(data["data"]) / "history.sqlite3"
        with sqlite3.connect(database) as db:
            db.execute("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES(?,?,?,?,?)", [time.time(), sentinel, 2, 3, "[]"])
        result = install("V2", "--lifecycle-qa-fail-at", "swapped", ok=False)
        check("restored" in result.stderr and hashlib.sha256(installed.read_bytes()).hexdigest() == readiness["images"]["V1"]["sha256"], "real failed V2 swap rolls executable back to V1")
        result = install("V2", "--lifecycle-qa-fail-at", "registered", ok=False)
        observation = json.loads((root / "registered-observation.json").read_text())
        check(observation["observed_role"] == "V2" and hashlib.sha256(installed.read_bytes()).hexdigest() == readiness["images"]["V1"]["sha256"], "post-registration rollback follows an observed committed V2 worker reading")
        check(rows("SELECT container FROM readings WHERE container='" + sentinel + "'") == [(sentinel,)], "history survives both real rollback phases")
        paused = subprocess.Popen(command("install", "--lifecycle-qa-version", "V2", "--lifecycle-qa-pause-at", "swapped"), stdout=(workspace / "paused-installer.log").open("w"), stderr=subprocess.STDOUT)
        wait_for(lambda: (root / "paused-installer.json").exists(), "actual installer reaches journaled interruption phase")
        check(json.loads((root / "paused-installer.json").read_text())["pid"] == paused.pid, "pause marker identifies the exact launched installer child")
        paused.terminate(); paused.wait(timeout=5)
        check(paused.returncode == -signal.SIGTERM, "actual installer process terminated and reaped before recovery lock")
        paused = None
        recovered = install("V2")
        check("Reverted an interrupted update" in recovered.stdout, "same installer recovers real interrupted transaction")
        check(hashlib.sha256(installed.read_bytes()).hexdigest() == readiness["images"]["V2"]["sha256"], "in-place update installs distinct real V2 image")
        missing = root / "home/Library/LaunchAgents" / (labels[2] + ".plist")
        check(run(["/bin/launchctl", "bootout", target(labels[2])]).returncode == 0, "test removes only its own inventory registration")
        missing.unlink()
        install("V2")
        check(missing.exists() and run(["/bin/launchctl", "print", target(labels[2])]).returncode == 0, "repair restores own missing plist and actual registration")
        disabled = run(command("uninstall"))
        check(disabled.returncode == 0, "real disable completes")
        check(all(run(["/bin/launchctl", "print", target(label)]).returncode != 0 for label in labels), "disable removes all own real services")
        check(rows("SELECT container FROM readings WHERE container='" + sentinel + "'") == [(sentinel,)], "disable retains private history")
        check(rows("SELECT count(*) FROM diagnostics") == [(0,)] and rows("SELECT value FROM state WHERE key='attribution_processes'") == [], "actual fixture checks perform no broad diagnostic or process sampling writes")
        succeeded = True
    finally:
        if paused is not None and paused.poll() is None:
            paused.terminate(); paused.wait(timeout=5)
        cleanup = run(command("uninstall"))
        records.append({"finally_uninstall_exit": cleanup.returncode})
        (root / "guard-stop").write_text("Owned test finished; execute independent final cleanup.\n")
        guard_process.wait(timeout=45)
        guard_events = [json.loads(line) for line in (root / "guard.jsonl").read_text().splitlines()]
        cleanup_events = [event for event in guard_events if event["event"] == "cleanup-complete"]
        guard_ok = guard_process.returncode == 0 and bool(cleanup_events) and cleanup_events[-1].get("success") is True and guard_events[-1]["event"] == "guard-exit"
        after = protected()
        unchanged = before == after
        absent = {label: run(["/bin/launchctl", "print", target(label)]).returncode != 0 for label in labels}
        overrides = run(["/bin/launchctl", "print-disabled", domain]).stdout
        own_override_rows = [line for line in overrides.splitlines() if any(label in line for label in labels)]
        result = {"passed": succeeded and unchanged and all(absent.values()) and guard_ok, "records": records, "protected_unchanged": unchanged, "labels_absent": absent, "guard_exit": guard_process.returncode, "guard_cleanup_verified": guard_ok, "guard_cleanup": cleanup_events, "own_disabled_override_rows": own_override_rows, "before_override_sha256": hashlib.sha256(before_overrides.encode()).hexdigest(), "after_override_sha256": hashlib.sha256(overrides.encode()).hexdigest(), "gui_launched": False, "login_persistence": "NOT VERIFIED", "notifications_FDA": "NOT VERIFIED; fixture checks suppress notification/process/diagnostic side effects"}
        (workspace / "lifecycle-results.json").write_text(json.dumps(result, indent=2) + "\n")
        (workspace / "protected-after.json").write_text(json.dumps(after, indent=2) + "\n")
        check(guard_ok, "independent guard exits zero with successful cleanup receipt and no exact-owned installed worker or manual installer")
        check(unchanged, "production app and LaunchAgent hashes/identities unchanged")
        check(all(absent.values()), "final independent teardown leaves no QA service loaded")
        print(json.dumps({"passed": succeeded, "results": str(workspace / "lifecycle-results.json"), "production_unchanged": unchanged, "labels_absent": absent}), flush=True)
if __name__ == "__main__":
    main()
