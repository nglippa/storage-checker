#!/usr/bin/env python3
"""Independent bounded teardown of one fresh lifecycle namespace. Never activates a desktop app."""
from pathlib import Path
import argparse, ctypes, hashlib, json, os, signal, stat, subprocess, time, uuid

ROOT = Path(__file__).resolve().parents[1] / "build/lifecycle-qa/runtime"
LIB = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
class BSD(ctypes.Structure):
    _fields_ = [("fields", ctypes.c_uint32 * 12), ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32), ("more", ctypes.c_uint32 * 5), ("nice", ctypes.c_int32), ("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]
LIB.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
LIB.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
def identity(pid):
    path, info = ctypes.create_string_buffer(4096), BSD()
    if LIB.proc_pidpath(pid, path, len(path)) <= 0 or LIB.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        return None
    return {"pid": pid, "exe": os.path.realpath(os.fsdecode(path.value)), "uid": info.fields[5], "seconds": info.seconds, "microseconds": info.microseconds}
def run(argv, timeout=20):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
def labels(profile):
    session = profile["session"]
    assert str(uuid.UUID(session)) == session
    base = "local.macbook.storage-monitor.lifecycle-qa." + session
    return [base, base + ".baseline", base + ".inventory"]
def helper_pinned(helper, digest, device):
    try:
        info = helper.lstat()
        return helper.resolve() == helper and stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1 and info.st_dev == device and info.st_mode & 0o022 == 0 and hashlib.sha256(helper.read_bytes()).hexdigest() == digest
    except OSError:
        return False
def pinned_cleanup(helper, digest, device, execute):
    if not helper_pinned(helper, digest, device):
        return None  # Fixed-label bootouts remain safe; never execute a substituted helper.
    return execute()
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--seconds", type=float, default=600)
    args = parser.parse_args()
    assert str(ROOT).startswith("/private/tmp/") and ROOT.resolve() == ROOT
    profile = json.loads((ROOT / "profile.json").read_text())
    owned_labels = labels(profile)
    domain = "gui/" + str(os.getuid())
    helper = ROOT / "Bundles/Installer.app/Contents/MacOS/StorageMonitor"
    digest = profile["images"]["Installer"]["sha256"]
    assert helper_pinned(helper, digest, profile["device"])
    if args.validate:
        assert not args.watch
        calls = []
        assert pinned_cleanup(helper, "0" * 64, profile["device"], lambda: calls.append("unsafe-exec")) is None and not calls
        print(json.dumps({"labels": owned_labels, "helper": str(helper), "mutations": False, "negative_pin_test": "mismatched helper hash refuses before execution; zero recording executor calls", "expiry_cleanup": "status/uninstall permitted; no restart during uninstall recovery"}))
        return
    assert args.watch and 10 <= args.seconds <= 1800
    for label in owned_labels:
        assert run(["/bin/launchctl", "print", domain + "/" + label]).returncode != 0, "Pre-existing QA service; guard baseline refused"
    began = time.time()
    owner = identity(os.getppid())
    journal = ROOT / "guard.jsonl"
    stop = ROOT / "guard-stop"
    assert not stop.exists() and not journal.exists(), "Guard is single-use"
    def record(event, **extra):
        with journal.open("a") as out:
            out.write(json.dumps({"event": event, "unix": time.time(), **extra}) + "\n")
    def manual_installers():
        found = []
        for row in subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True).splitlines():
            parts = row.strip().split(None, 1)
            if len(parts) != 2 or os.path.realpath(parts[1]) != str(helper):
                continue
            value = identity(int(parts[0]))
            if value and value["uid"] == os.getuid() and value["seconds"] + value["microseconds"] / 1e6 >= began and value["exe"] == str(helper):
                found.append(value)
        return found
    worker_paths = {str(ROOT / "home/Applications/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor"), str(ROOT / "home/Applications/.MacBook Storage Monitor.previous.app/Contents/MacOS/StorageMonitor")}
    def owned_workers():
        found = []
        for row in subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True).splitlines():
            parts = row.strip().split(None, 1)
            if len(parts) != 2 or os.path.realpath(parts[1]) not in worker_paths:
                continue
            value = identity(int(parts[0]))
            if value and value["uid"] == os.getuid() and value["seconds"] + value["microseconds"] / 1e6 >= began and value["exe"] in worker_paths:
                found.append(value)
        return found
    def cleanup():
        # Stop exact owned manual installers before recovery tries their lock. Never use a PID alone.
        for value in manual_installers():
            if identity(value["pid"]) == value:
                os.kill(value["pid"], signal.SIGTERM)
                until = time.monotonic() + 3
                while identity(value["pid"]) == value and time.monotonic() < until:
                    time.sleep(.05)
                if identity(value["pid"]) == value:
                    os.kill(value["pid"], signal.SIGKILL)
                record("manual-installer-stopped", identity=value)
        for label in owned_labels:
            result = run(["/bin/launchctl", "bootout", domain + "/" + label])
            record("owned-bootout", label=label, exit=result.returncode)
        until = time.monotonic() + 4
        while owned_workers() and time.monotonic() < until:
            time.sleep(.1)
        for value in owned_workers():
            if identity(value["pid"]) == value:
                os.kill(value["pid"], signal.SIGTERM)
                time.sleep(.2)
                if identity(value["pid"]) == value:
                    os.kill(value["pid"], signal.SIGKILL)
                record("owned-worker-stopped", identity=value)
        # Even an expired profile admits this cleanup. A damaged profile may reject recovery, but jobs are already gone.
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(ROOT / "Temporary") + "/", "SQLITE_TMPDIR": str(ROOT / "Temporary")}
        result = pinned_cleanup(helper, digest, profile["device"], lambda: subprocess.run([str(helper), "uninstall", "--lifecycle-qa-root", str(ROOT)], capture_output=True, text=True, timeout=30, env=environment))
        record("owned-uninstall", exit=None if result is None else result.returncode, refused_changed_helper=result is None, output="" if result is None else result.stdout, error="" if result is None else result.stderr)
        absent = {label: run(["/bin/launchctl", "print", domain + "/" + label]).returncode != 0 for label in owned_labels}
        workers, installers = owned_workers(), manual_installers()
        success = all(absent.values()) and not workers and not installers and result is not None and result.returncode == 0
        record("cleanup-complete", labels_absent=absent, manual_installers=installers, installed_workers=workers, success=success)
        assert success, "Owned teardown incomplete"
    def interrupted(signum, frame):
        raise SystemExit("Guard interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    record("armed", owner=owner, labels=owned_labels, seconds=args.seconds)
    deadline = time.monotonic() + args.seconds
    try:
        while not stop.exists() and time.monotonic() < deadline:
            if owner is not None and identity(owner["pid"]) != owner:
                record("owner-exited"); break
            time.sleep(.2)
        record("teardown-trigger", deadline_fired=time.monotonic() >= deadline, requested=stop.exists())
    finally:
        cleanup()
        record("guard-exit")
if __name__ == "__main__":
    main()
