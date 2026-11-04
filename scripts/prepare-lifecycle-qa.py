#!/usr/bin/env python3
"""Build a fresh disposable source-bound lifecycle QA installation. Never launches apps or launchctl."""
from pathlib import Path
import hashlib, json, os, plistlib, shutil, subprocess, tempfile, time, uuid

repo = Path(__file__).resolve().parents[1]
workspace = Path(tempfile.mkdtemp(prefix="storage-monitor-lifecycle-", dir="/private/tmp"))
source = workspace / "source"
source.mkdir(mode=0o700)
for folder in ["Sources", "SourcesShared", "SourcesGUI", "tests", "scripts"]:
    shutil.copytree(repo / folder, source / folder, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
for name in ["THIRD-PARTY-NOTICES.md", "AGENTS.md"]:
    shutil.copyfile(repo / name, source / name)
root = source / "build/lifecycle-qa/runtime"
for relative in ["", "home/Applications", "home/Library/Application Support/MacBook Storage Monitor/inventory-requests", "home/Library/LaunchAgents", "fixtures/project/cache", "Logs", "Temporary", "Bundles"]:
    (root / relative).mkdir(mode=0o700, parents=True, exist_ok=True)
(root / "fixtures/project/readme.txt").write_text("Disposable lifecycle QA fixture.\n")
(root / "fixtures/project/cache/generated.bin").write_bytes(b"disposable fixture\n" * 128)
for path in (root / "fixtures").rglob("*"):
    path.chmod(0o700 if path.is_dir() else 0o600)
records = []
sdk = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

def run(name, argv):
    started = time.monotonic()
    print("START " + name, flush=True)
    with (workspace / (name + ".log")).open("w") as log:
        result = subprocess.run(argv, cwd=source, stdout=log, stderr=subprocess.STDOUT)
    records.append({"name": name, "argv": argv, "exit": result.returncode, "seconds": round(time.monotonic() - started, 3)})
    (workspace / "build-results.json").write_text(json.dumps(records, indent=2) + "\n")
    print("DONE " + name + " exit=" + str(result.returncode), flush=True)
    if result.returncode:
        raise SystemExit("Build failed; inspect " + str(workspace / (name + ".log")))

images = {}
for role in ["V1", "V2"]:
    app = root / ("Bundles/" + role + ".app")
    (app / "Contents/MacOS").mkdir(mode=0o700, parents=True)
    exe = app / "Contents/MacOS/StorageMonitor"
    command = ["/usr/bin/xcrun", "swiftc", "-target", "arm64-apple-macos14.0", "-swift-version", "5", "-Onone", "-parse-as-library", "-module-cache-path", str(source / "build/module-cache"), "-framework", "AppKit", "-framework", "UserNotifications"]
    if role == "V1":
        command += ["-D", "LIFECYCLE_QA_V1"]
    command += [str(p) for folder in ["Sources", "SourcesShared"] for p in sorted((source / folder).glob("*.swift"))]
    command += [str(source / "tests/InventoryTests.swift"), "-o", str(exe)]
    run("helper-" + role, command)
    exe.chmod(0o700)
    build = "1" if role == "V1" else "2"
    info = {"CFBundleIdentifier": "local.macbook.storage-monitor.helper.lifecycle-qa", "CFBundleName": "Storage Monitor Lifecycle QA Helper", "CFBundleExecutable": "StorageMonitor", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.0", "CFBundleVersion": build, "LSUIElement": True, "LSMinimumSystemVersion": "14.0"}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    images[role] = {"sha256": hashlib.sha256(exe.read_bytes()).hexdigest(), "version": "0.0.0", "build": build}
shutil.copytree(root / "Bundles/V2.app", root / "Bundles/Installer.app")
images["Installer"] = images["V2"]
# The V2 compiler invocation has production flags. A private normal-identity copy runs ordinary CLI self-tests.
normal = workspace / "Production CLI.app"
shutil.copytree(root / "Bundles/V2.app", normal)
normal_info = plistlib.loads((normal / "Contents/Info.plist").read_bytes())
normal_info["CFBundleIdentifier"] = "local.macbook.storage-monitor"
(normal / "Contents/Info.plist").write_bytes(plistlib.dumps(normal_info))
viewer = root / "Storage Monitor Lifecycle QA.app"
(viewer / "Contents/MacOS").mkdir(mode=0o700, parents=True)
command = ["/usr/bin/xcrun", "swiftc", "-sdk", sdk, "-target", "arm64-apple-macos14.0", "-swift-version", "5", "-Onone", "-parse-as-library", "-module-cache-path", str(source / "build/module-cache"), "-framework", "SwiftUI", "-framework", "Charts", "-framework", "AppKit"]
command += [str(p) for folder in ["SourcesGUI", "SourcesShared"] for p in sorted((source / folder).glob("*.swift"))]
command += ["-o", str(viewer / "Contents/MacOS/StorageMonitorViewer")]
run("viewer", command)
(viewer / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "local.macbook.storage-monitor.viewer.lifecycle-qa", "CFBundleName": "Storage Monitor Lifecycle QA", "CFBundleDisplayName": "Storage Monitor Lifecycle QA", "CFBundleExecutable": "StorageMonitorViewer", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "2", "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "14.0"}))
info = root.stat()
created = time.time()
profile = {"version": 1, "session": str(uuid.uuid4()), "uid": os.getuid(), "device": info.st_dev, "inode": info.st_ino, "createdAt": created, "expiresAt": created + 7200, "images": images}
(root / "profile.json").write_text(json.dumps(profile, indent=2) + "\n")
(root / "profile.json").chmod(0o600)
manifest = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest() for folder in ["Sources", "SourcesGUI", "SourcesShared", "scripts", "tests"] for p in sorted((source / folder).rglob("*")) if p.is_file() and p.suffix in [".swift", ".sh", ".py"]}
result = {"workspace": str(workspace), "source": str(source), "root": str(root), "source_files": manifest, "images": images, "profile": profile, "viewer": str(viewer), "normal_cli": str(normal / "Contents/MacOS/StorageMonitor"), "gui_launched": False, "launchctl_mutations": False, "distribution_signing": False}
(workspace / "readiness.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({"workspace": str(workspace), "root": str(root), "readiness": str(workspace / "readiness.json"), "gui_launched": False, "launchctl_mutations": False}), flush=True)
