import Foundation
import Darwin
import SQLite3

/// Development-only dispatch runs before any production data directory or scan default is selected.
@MainActor func runLifecycleQACommand(arguments: [String]) async throws -> Bool {
    let requested = arguments.contains(where: { $0.hasPrefix("--lifecycle-qa") })
    guard requested || Bundle.main.bundleIdentifier == LifecycleQAScope.helperIdentifier else { return false }
    try LifecycleQAScope.validateEnvironment()
    guard arguments.count > 1, arguments.filter({ $0 == LifecycleQAScope.flag }).count == 1,
          let rootIndex = arguments.firstIndex(of: LifecycleQAScope.flag), rootIndex + 1 < arguments.count else { try LifecycleQAScope.refuse("explicit scope is required") }
    let scope = try LifecycleQAScope.load(root: arguments[rootIndex + 1]), command = arguments[1]
    let workers = ["check", "initialize-baseline", "inventory-work"]
    guard workers.contains(command) || ["install", "uninstall", "status", "lifecycle-qa-inspect"].contains(command) else { try LifecycleQAScope.refuse("unsupported lifecycle command") }
    try scope.admit(command: command)
    try scope.validateCurrentImage(installerOnly: !workers.contains(command))
    LifecycleQAScope.active = scope
    if workers.contains(command) {
        guard Array(arguments.dropFirst()) == Array(scope.workerArguments(command: command).dropFirst()) else { try LifecycleQAScope.refuse("worker root/data/options must exactly match the generated plist") }
        try scope.validateFixtures()
        switch command {
        case "check": try check(scope.data, qa: scope)
        case "initialize-baseline":
            let result = initializeBaseline(dbPath: scope.database, directory: scope.data,
                roots: [MonitoredRoot(path: scope.fixtures, label: "Disposable lifecycle fixtures")], within: scope.root)
            let summary = "lifecycle-qa initialize-baseline \(result.outcome) fixtures=\(scope.fixtures)"
            log(scope.data, summary); print(summary)
            if !["terminal", "already_running"].contains(result.outcome) { exit(75) }
        default: try await inventoryCommand(command, args: Array(arguments.dropFirst()), directory: scope.data)
        }
        return true
    }
    var options = [String: String](), remaining = Array(arguments.dropFirst(2))
    let allowed = command == "install" ? [LifecycleQAScope.flag, "--lifecycle-qa-version", "--lifecycle-qa-fail-at", "--lifecycle-qa-pause-at"] : [LifecycleQAScope.flag]
    while !remaining.isEmpty {
        let key = remaining.removeFirst()
        guard allowed.contains(key), options[key] == nil, !remaining.isEmpty else { try LifecycleQAScope.refuse("unsupported, duplicate or incomplete option") }
        options[key] = remaining.removeFirst()
    }
    guard options[LifecycleQAScope.flag] == scope.root else { try LifecycleQAScope.refuse("scope argument mismatch") }
    if ["status", "lifecycle-qa-inspect"].contains(command) {
        print(try lifecycleQAStatus(scope)); return true
    }
    // Setup always runs from the stable bundled installer; stop/reap an interrupted installer before retrying.
    let lock = try LifecycleQALease(scope, name: "installer.lock")
    defer { withExtendedLifetime(lock) {} }
    let layout = MonitorInstallLayout(home: scope.home, qa: scope)
    if command == "uninstall" { for note in try uninstall(layout: layout) { print(note) }; return true }
    let role = options["--lifecycle-qa-version"] ?? "V2"
    guard ["V1", "V2"].contains(role) else { try LifecycleQAScope.refuse("source role must be V1 or V2") }
    let failure = options["--lifecycle-qa-fail-at"], pause = options["--lifecycle-qa-pause-at"]
    guard !(failure != nil && pause != nil), [failure, pause].compactMap({ $0 }).allSatisfy({ InstallJournal.Phase(rawValue: $0) != nil }) else { try LifecycleQAScope.refuse("invalid fault phase") }
    let notes = try install(layout: layout, source: scope.bundle(role), fault: { phase in
        if failure == phase.rawValue {
            if phase == .registered {
                let deadline = Date().addingTimeInterval(12)
                while lifecycleQARecordedRole(scope) != role && Date() < deadline { usleep(100_000) }
                guard lifecycleQARecordedRole(scope) == role else { throw Failure("Lifecycle QA did not observe the registered worker's committed reading") }
                try JSONSerialization.data(withJSONObject: ["observed_role": role, "phase": phase.rawValue], options: [.sortedKeys])
                    .write(to: URL(fileURLWithPath: scope.root + "/registered-observation.json"), options: .atomic)
            }
            throw Failure("Lifecycle QA injected failure at \(phase.rawValue)")
        }
        if pause == phase.rawValue {
            let marker = URL(fileURLWithPath: scope.root + "/paused-installer.json")
            try JSONSerialization.data(withJSONObject: ["pid": getpid(), "phase": phase.rawValue], options: [.sortedKeys]).write(to: marker, options: .atomic)
            // Independent harness terminates this exact child. Even if abandoned, it cannot wait indefinitely.
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline { usleep(100_000) }
            throw Failure("Lifecycle QA pause expired")
        }
    })
    for note in notes { print(note) }
    return true
}

private func lifecycleQARecordedRole(_ scope: LifecycleQAScope) -> String? {
    var db: OpaquePointer?, statement: OpaquePointer?
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_open_v2(scope.database, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
          sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key='lifecycle_qa_last_check_role'", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: value)
}

/// No Database initializer, retention, notification API or production-label query, including after expiry.
func lifecycleQAStatus(_ scope: LifecycleQAScope) throws -> String {
    try scope.admit(command: "status")
    var result: [String: Any] = ["root": scope.root, "labels": scope.labels, "data": scope.data.path,
        "fixtures": scope.fixtures, "installer": scope.installer.path, "expired": scope.expired,
        "login_persistence": "NOT VERIFIED: private plists are explicitly bootstrapped only",
        "notifications": "suppressed; not an authorization or delivery test", "compiled_fixture_role": LifecycleQAScope.compiledFixtureRole]
    result["agents"] = scope.labels.map { FileManager.default.fileExists(atPath: scope.agentURL($0).path) }
    result["generated_plists"] = MonitorInstallLayout(home: scope.home, qa: scope).agents.map(\.plist)
    if FileManager.default.fileExists(atPath: scope.app.path) {
        result["installed_sha256"] = try NativeQARuntime.hash(scope.executable)
    }
    if FileManager.default.fileExists(atPath: scope.database) {
        var db: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        if sqlite3_open_v2(scope.database, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
           sqlite3_prepare_v2(db, "SELECT count(*) FROM readings", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
            result["readings"] = sqlite3_column_int64(statement, 0)
        }
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
}
