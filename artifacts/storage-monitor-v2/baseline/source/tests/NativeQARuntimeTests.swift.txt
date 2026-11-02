import Foundation
import Darwin
import SQLite3

@main enum NativeQARuntimeTests {
    static var count = 0
    static func check(_ ok: Bool, _ message: String) throws {
        if !ok { throw NativeQARuntime.Refusal(description: "FAIL: " + message) }
        count += 1; print("PASS " + message)
    }
    static func denied(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    static func item(_ path: String, authorized: Bool = false) throws -> NativeQARuntime.Item {
        let s = try NativeQARuntime.info(path)
        return .init(path: path, device: Int64(s.st_dev), inode: UInt64(s.st_ino), kind: s.st_mode & S_IFMT == S_IFDIR ? "directory" : "file", authorized: authorized)
    }
    static func fixture() throws -> NativeQARuntime {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent("build/native-acceptance/runtime-unit-" + UUID().uuidString).path
        let fm = FileManager.default
        for path in [root, root + "/ApplicationSupport", root + "/ApplicationSupport/inventory-requests", root + "/fixtures", root + "/fixtures/folder", root + "/Caches", root + "/Logs", root + "/Temporary", root + "/bin"] { try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        for path in [root + "/ApplicationSupport/history.sqlite3", root + "/fixtures/ordinary.txt", root + "/fixtures/folder/child.txt"] { try Data().write(to: URL(fileURLWithPath: path)); chmod(path, 0o600) }
        try fm.copyItem(atPath: "/usr/bin/true", toPath: root + "/bin/StorageMonitor"); chmod(root + "/bin/StorageMonitor", 0o700)
        let profile = NativeQARuntime.Profile(version: 1, root: try item(root), catalog: try item(root + "/ApplicationSupport/history.sqlite3"), createdAt: Date().timeIntervalSince1970, helperSHA256: try NativeQARuntime.hash(root + "/bin/StorageMonitor"), fixtures: try [item(root + "/fixtures/ordinary.txt", authorized: true), item(root + "/fixtures/folder", authorized: true), item(root + "/fixtures/folder/child.txt", authorized: true)])
        try JSONEncoder().encode(profile).write(to: URL(fileURLWithPath: root + "/profile.json")); chmod(root + "/profile.json", 0o600)
        return try NativeQARuntime.load(root: root, expected: root)
    }
    static func main() throws {
        try check(try NativeQARuntime.bootstrap(arguments: ["tool"], bundle: "production", environment: [:]) == nil, "normal invocation has no QA activation")
        try check(denied { _ = try NativeQARuntime.bootstrap(arguments: ["tool"], bundle: NativeQARuntime.bundleIdentifier, environment: [:]) }, "QA identity without explicit opt-in refuses before lifecycle")
        try check(denied { _ = try NativeQARuntime.bootstrap(arguments: ["tool", "--qa-runtime-root", NativeQARuntime.expectedRoot], bundle: "production", environment: [:]) }, "production identity cannot activate profile")
        try check(NativeQARuntime.expectedRoot.hasPrefix("/") && NativeQARuntime.expectedRoot.hasSuffix("/build/native-acceptance/runtime"), "baked anchor is absolute and independent of working directory")
        let good = try fixture()
        try good.validateStorage(); try good.validateTrash(good.fixtures + "/ordinary.txt"); try good.validateTrash(good.fixtures + "/folder")
        try check(true, "registered file and complete registered directory pass additional boundary")
        for path in [good.root, good.fixtures, good.database, good.helper, "/private/tmp/outside-fixture", good.fixtures + "/../bin/StorageMonitor"] {
            try check(denied { try good.validateTrash(path) }, "deny unregistered/root/operational path " + (path as NSString).lastPathComponent)
        }
        try check(denied { try good.validateRequest("/private/tmp/outside-fixture", action: "refresh") }, "worker request cannot leave fixture root")
        try check(denied { try good.validateRequest(good.fixtures, action: "arbitrary") }, "worker rejects unknown mode")
        try good.validateRequest(good.fixtures + "/gone/child", action: "refresh"); try check(true, "disappeared path may reconcile only through contained canonical ancestor")
        let foreign = good.root + "/unknown-child.txt"; try Data().write(to: URL(fileURLWithPath: foreign)); chmod(foreign,0o600)
        let unregistered = good.fixtures + "/folder/unregistered.txt"; try Data().write(to: URL(fileURLWithPath: unregistered)); chmod(unregistered,0o600)
        try check(denied { try good.validateTrash(good.fixtures + "/folder") }, "unregistered descendant blocks parent")
        let replacement = try fixture(), path = replacement.fixtures + "/ordinary.txt"
        try FileManager.default.moveItem(atPath: path, toPath: path + ".preserved"); try Data("new".utf8).write(to: URL(fileURLWithPath: path)); chmod(path,0o600)
        try check(denied { try replacement.validateTrash(path) }, "pathname replacement fails pinned inode check")
        let linked = try fixture(); try FileManager.default.linkItem(atPath: linked.fixtures + "/ordinary.txt", toPath: linked.root + "/alias")
        try check(denied { try linked.validateStorage() }, "hard-linked disposable file is rejected")
        let sidecar = try fixture(); try FileManager.default.createSymbolicLink(atPath: sidecar.database + "-journal", withDestinationPath: "/private/tmp")
        try check(denied { try sidecar.validateStorage() }, "symlinked SQLite sidecar is rejected before write")
        let profileSwap = try fixture(); try FileManager.default.moveItem(atPath: profileSwap.root + "/profile.json", toPath: profileSwap.root + "/profile.preserved")
        try FileManager.default.createSymbolicLink(atPath: profileSwap.root + "/profile.json", withDestinationPath: profileSwap.root + "/profile.preserved")
        try check(denied { try profileSwap.validateStorage() }, "profile symlink replacement refused before content read")
        let permission = try fixture(); chmod(permission.root,0o755)
        try check(denied { try permission.validateStorage() }, "root permission widening refuses session")
        let lockFixture = try fixture(); let first = try NativeQASessionLock(lockFixture)
        try check(denied { _ = try NativeQASessionLock(lockFixture) }, "exclusive session lock rejects second viewer")
        withExtendedLifetime(first) {}
        for (arguments, environment, label) in [
            (["tool", "--qa-runtime-root", NativeQARuntime.expectedRoot, "--database-path", "/private/tmp/forbidden"], [:], "conflicting database override"),
            (["tool", "--qa-runtime-root", NativeQARuntime.expectedRoot], ["HOME": "/private/tmp/forbidden"], "HOME override"),
            (["tool", "--qa-runtime-root", NativeQARuntime.expectedRoot], ["DYLD_LIBRARY_PATH": "/private/tmp/forbidden"], "dynamic loader override"),
            (["tool", "--qa-runtime-root", NativeQARuntime.expectedRoot], ["STORAGE_MONITOR_QA_ROOT": "/private/tmp/forbidden"], "implicit environment activation")
        ] {
            try check(denied { _ = try NativeQARuntime.bootstrap(arguments: arguments, bundle: NativeQARuntime.bundleIdentifier, environment: environment) }, "strict bootstrap refuses " + label)
        }
        func alteredProfile(_ edit: (inout [String: Any]) -> Void) throws -> Bool {
            let f = try fixture(), url = URL(fileURLWithPath: f.root + "/profile.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            edit(&json); try JSONSerialization.data(withJSONObject: json).write(to: url)
            return denied { _ = try NativeQARuntime.load(root: f.root, expected: f.root) }
        }
        try check(try alteredProfile { $0["createdAt"] = Date().timeIntervalSince1970 - 8 * 86400 }, "expired profile refused")
        try check(try alteredProfile { var value = $0["catalog"] as! [String: Any]; value["kind"] = "directory"; $0["catalog"] = value }, "catalog must be a regular file")
        try check(try alteredProfile { var value = $0["root"] as! [String: Any]; value["device"] = 0; $0["root"] = value }, "device identity mismatch refused")
        let missing = try fixture(); try FileManager.default.moveItem(atPath: missing.caches, toPath: missing.caches + ".preserved")
        try check(denied { _ = try NativeQARuntime.load(root: missing.root, expected: missing.root) }, "missing required runtime component refused")
        let aliased = try fixture(), alias = aliased.root + "-alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: aliased.root)
        try check(denied { _ = try NativeQARuntime.load(root: alias, expected: alias) }, "symbolic-link root refused")
        let staleCatalog = try fixture(); var database: OpaquePointer?
        guard sqlite3_open(staleCatalog.database, &database) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let sql = "CREATE TABLE inventory_generations(root_path TEXT); INSERT INTO inventory_generations VALUES('/private/tmp/native-qa-outside-disposable');"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        sqlite3_close(database)
        try check(denied { try staleCatalog.validateStorage() }, "stale catalog outside-root generation refused before worker reads")
        let scope = try fixture()
        var environment = ArtifactEnvironment(home: scope.root, pathDirectories: [], processes: { ProcessObservation(executables: [], workingDirectories: [], inspected: 100, unreadable: 0) }, git: GitInspector.available(), ownData: scope.support)
        environment.qaRuntime = scope
        let node = try trashSafetyNode(scope.fixtures + "/ordinary.txt")
        func ready(_ node: InventoryNode, _ env: ArtifactEnvironment) throws -> CleanupTrashConfirmationToken {
            switch CleanupTrashPolicy.prepare(node: node, environment: env) {
            case .ready(let token): return token
            case .blocked(let reason): throw NativeQARuntime.Refusal(description: "Expected registered QA confirmation: " + reason)
            }
        }
        let cancellation = try ready(node, environment)
        try check(true, "strict registered target reaches ordinary safety confirmation")
        var calls = 0
        CleanupTrashPolicy.cancel(cancellation)
        let cancelled = CleanupTrashPolicy.perform(confirmation: cancellation, overrideAccepted: true, environment: environment, trash: { _ in calls += 1; return nil })
        if case .refused = cancelled { try check(calls == 0, "strict cancellation never reaches Trash adapter") } else { try check(false, "strict cancellation result") }
        let single = try ready(node, environment)
        _ = CleanupTrashPolicy.perform(confirmation: single, overrideAccepted: true, environment: environment, trash: { _ in calls += 1; return nil })
        _ = CleanupTrashPolicy.perform(confirmation: single, overrideAccepted: true, environment: environment, trash: { _ in calls += 1; return nil })
        try check(calls == 1, "strict token is single-use even when adapter fails")
        let unknown = scope.fixtures + "/unknown.txt"; try Data().write(to: URL(fileURLWithPath: unknown)); chmod(unknown,0o600)
        if case .blocked = CleanupTrashPolicy.prepare(node: try trashSafetyNode(unknown), environment: environment) { try check(true, "strict policy denies existing unregistered file") } else { try check(false, "strict unregistered policy") }
        var protected = environment; protected.ownData = scope.fixtures
        if case .blocked = CleanupTrashPolicy.prepare(node: node, environment: protected) { try check(true, "strict mode retains protected-data hard block") } else { try check(false, "strict protected-data policy") }
        var active = environment; active.processes = { ProcessObservation(executables: [node.path], workingDirectories: [], openFiles: [node.path], inspected: 100, unreadable: 0) }
        if case .blocked = CleanupTrashPolicy.prepare(node: node, environment: active) { try check(true, "strict mode retains active-dependency hard block") } else { try check(false, "strict active-dependency policy") }
        let replacementToken = try ready(node, environment)
        try FileManager.default.moveItem(atPath: node.path, toPath: node.path + ".preserved")
        try Data().write(to: URL(fileURLWithPath: node.path)); chmod(node.path,0o600)
        var ordinaryEnvironment = environment; ordinaryEnvironment.qaRuntime = nil
        let replaced = CleanupTrashPolicy.perform(confirmation: replacementToken, overrideAccepted: true, environment: ordinaryEnvironment, trash: { _ in calls += 1; return nil })
        if case .refused = replaced { try check(calls == 1, "prepared token retains QA scope when execution environment omits it; replacement is refused") } else { try check(false, "strict replacement policy") }
        let global = try fixture()
        var globalEnv = ArtifactEnvironment(home: global.root, pathDirectories: [], processes: { ProcessObservation(executables: [], workingDirectories: [], inspected: 100, unreadable: 0) }, git: GitInspector.available(), ownData: global.support)
        NativeQARuntime.active = global
        let globalReady = try ready(try trashSafetyNode(global.fixtures + "/ordinary.txt"), globalEnv)
        try check(true, "active strict runtime is applied when caller omits environment scope")
        CleanupTrashPolicy.cancel(globalReady)
        let globalUnknown = global.fixtures + "/unregistered.txt"; try Data().write(to: URL(fileURLWithPath: globalUnknown)); chmod(globalUnknown,0o600)
        if case .blocked = CleanupTrashPolicy.prepare(node: try trashSafetyNode(globalUnknown), environment: globalEnv) { try check(true, "central active scope blocks unregistered target even without environment scope") } else { try check(false, "central active omission policy") }
        globalEnv.qaRuntime = scope
        if case .blocked = CleanupTrashPolicy.prepare(node: try trashSafetyNode(global.fixtures + "/ordinary.txt"), environment: globalEnv) { try check(true, "mismatched supplied profile is refused") } else { try check(false, "scope mismatch policy") }
        NativeQARuntime.active = nil
        let gitScope = try fixture(), gitDirectory = gitScope.fixtures + "/git-folder"
        try FileManager.default.createDirectory(atPath: gitDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("gitdir: /private/tmp/native-qa-outside-unused\n".utf8).write(to: URL(fileURLWithPath: gitDirectory + "/.git")); chmod(gitDirectory + "/.git",0o600)
        let profileURL = URL(fileURLWithPath: gitScope.root + "/profile.json")
        let registeredGit = NativeQARuntime.Profile(version: 1, root: gitScope.profile.root, catalog: gitScope.profile.catalog, createdAt: gitScope.profile.createdAt, helperSHA256: gitScope.profile.helperSHA256, fixtures: gitScope.profile.fixtures + [try item(gitDirectory, authorized: true), try item(gitDirectory + "/.git", authorized: true)])
        try JSONEncoder().encode(registeredGit).write(to: profileURL)
        let loadedGit = try NativeQARuntime.load(root: gitScope.root, expected: gitScope.root)
        try check(denied { try loadedGit.validateTrash(gitDirectory) }, "registered .git-file folder is denied before resolving external gitdir")
        print("NATIVE QA SCOPE ASSERTIONS: \(count) passed")
        let safetyRoot = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("native-qa-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: safetyRoot, withIntermediateDirectories: true)
        try cleanupTrashSafetyTests(safetyRoot) { ok, message in try check(ok, message) }
        print("NATIVE QA + EXISTING TRASH SAFETY: \(count) assertions passed, 0 failed")
    }
}
