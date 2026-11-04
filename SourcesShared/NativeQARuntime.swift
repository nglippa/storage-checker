import Foundation
import Darwin
import CryptoKit
import SQLite3

/// Explicit development profile. Never inferred from a database override or the working directory.
public struct NativeQARuntime: Sendable {
    public static let bundleIdentifier = "local.macbook.storage-monitor.viewer.native-qa"
    public static let expectedRoot: String = {
        #if STORAGE_MONITOR_DISTRIBUTION
        // A portable test/distribution image never activates repository-bound development QA.
        return ""
        #else
        let source = #filePath
        guard source.hasPrefix("/") else { return "" }
        return URL(fileURLWithPath: source).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/native-acceptance/runtime").path
        #endif
    }()
    public static var active: NativeQARuntime?
    public struct Item: Codable, Sendable {
        public let path: String
        public let device: Int64
        public let inode: UInt64
        public let kind: String
        public let authorized: Bool
    }
    public struct Profile: Codable, Sendable {
        public let version: Int
        public let root: Item
        public let catalog: Item
        public let createdAt: Double
        public let helperSHA256: String
        public let fixtures: [Item]
    }
    public struct Refusal: Error, LocalizedError, CustomStringConvertible { public let description: String; public var errorDescription: String? { description } }
    public let root: String
    public let profile: Profile
    private let originalProfile: Data
    public var support: String { root + "/ApplicationSupport" }
    public var database: String { support + "/history.sqlite3" }
    public var fixtures: String { root + "/fixtures" }
    public var caches: String { root + "/Caches" }
    public var logs: String { root + "/Logs" }
    public var temporary: String { root + "/Temporary" }
    public var workerState: String { support }
    public var helper: String { root + "/bin/StorageMonitor" }
    public var readiness: String { logs + "/readiness.json" }

    public static func reject(_ message: String) throws -> Never { throw Refusal(description: "QA runtime refused: " + message) }
    public static func info(_ path: String) throws -> stat {
        var value = stat()
        guard lstat(path, &value) == 0 else { try reject("missing/unreadable path: \(path)") }
        return value
    }
    /// Check lexical spelling without Foundation's alias rewriting: standardizingPath changes
    /// /private/tmp to /tmp on macOS. realpath below independently rejects actual symlink aliases.
    private static func hasCanonicalSpelling(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        if path == "/" { return true }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
    public static func canonical(_ path: String) throws -> String {
        guard hasCanonicalSpelling(path),
              let buffer = realpath(path, nil) else { try reject("noncanonical path: \(path)") }
        defer { free(buffer) }
        let actual = String(cString: buffer)
        guard actual == path else { try reject("symbolic-link/alias path: \(path)") }
        return actual
    }
    /// The kernel supplies this process image, not an argument, URL, environment override or request.
    /// Foundation may spell /private/tmp as /tmp after Process spawning. Resolve only this trusted
    /// OS observation; all supplied paths still pass the strict lexical + realpath equality checks.
    public func validateCurrentWorkerImage() throws {
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &bytes, UInt32(bytes.count)) > 0,
              let resolved = realpath(String(cString: bytes), nil) else { try Self.reject("worker image unavailable") }
        defer { free(resolved) }
        guard String(cString: resolved) == helper,
              try Self.canonical(helper) == helper,
              try Self.hash(helper) == profile.helperSHA256 else { try Self.reject("worker image does not match pinned helper") }
    }
    public static func hash(_ path: String) throws -> String {
        // Only used for the small pinned helper, never for production catalogs.
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func load(root: String, expected: String = expectedRoot) throws -> Self {
        guard !expected.isEmpty, root == expected else { try reject("root must be the baked repository build/native-acceptance/runtime") }
        _ = try canonical(root)
        let directory = try info(root)
        guard directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(), directory.st_mode & 0o077 == 0, directory.st_mode & 0o700 == 0o700 else { try reject("root must be a current-user private directory") }
        let repo = URL(fileURLWithPath: root).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        guard try info(repo).st_dev == directory.st_dev else { try reject("runtime is on another mount") }
        let profilePath = root + "/profile.json"
        let metadata = try info(profilePath)
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1, metadata.st_size < 131_072 else { try reject("invalid profile file") }
        _ = try canonical(profilePath)
        let data = try Data(contentsOf: URL(fileURLWithPath: profilePath))
        let value = try JSONDecoder().decode(Profile.self, from: data)
        guard value.version == 1, value.root.path == root, value.root.device == Int64(directory.st_dev), value.root.inode == UInt64(directory.st_ino), value.root.kind == "directory",
              value.catalog.path == root + "/ApplicationSupport/history.sqlite3", value.catalog.kind == "file",
              value.createdAt <= Date().timeIntervalSince1970 + 5, Date().timeIntervalSince1970 - value.createdAt < 7 * 86400,
              !value.fixtures.isEmpty, value.fixtures.count <= 256, Set(value.fixtures.map(\.path)).count == value.fixtures.count else { try reject("stale/mismatched profile or fixture registration") }
        let result = Self(root: root, profile: value, originalProfile: data)
        try result.validateStorage()
        guard try hash(result.helper) == value.helperSHA256 else { try reject("worker executable changed") }
        for entry in value.fixtures {
            guard entry.path.hasPrefix(result.fixtures + "/"), hasCanonicalSpelling(entry.path), ["file", "directory"].contains(entry.kind) else { try reject("out-of-root registration") }
        }
        return result
    }
    public static func bootstrap(arguments: [String], bundle: String?, worker: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self? {
        let flag = "--qa-runtime-root"
        guard let index = arguments.firstIndex(of: flag) else {
            if bundle == bundleIdentifier || arguments.contains(where: { $0.hasPrefix("--qa-") }) { try reject("explicit --qa-runtime-root activation is required") }
            return nil
        }
        guard arguments.filter({ $0 == flag }).count == 1, arguments.count > index + 1, worker || bundle == bundleIdentifier else { try reject("profile requires the QA application identity") }
        let allowed = worker ? ["inventory-work", flag, "--qa-owner-pid"] : [flag, "--qa-verify-only"]
        var remaining = Array(arguments.dropFirst())
        while !remaining.isEmpty {
            let arg = remaining.removeFirst()
            guard allowed.contains(arg) else { try reject("unsupported/conflicting argument \(arg)") }
            if arg == flag || arg == "--qa-owner-pid" { guard !remaining.isEmpty else { try reject("missing argument value") }; remaining.removeFirst() }
        }
        for key in environment.keys where key.hasPrefix("STORAGE_MONITOR_") { try reject("unsupported environment override \(key)") }
        for key in ["CFFIXED_USER_HOME", "CFPREFERENCES_AVOID_DAEMON", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"] where environment[key] != nil { try reject("unsupported environment override \(key)") }
        for key in environment.keys where key.hasPrefix("DYLD_") { try reject("unsupported loader override \(key)") }
        guard let account = getpwuid(getuid()) else { try reject("account identity unavailable") }
        let accountHome = String(cString: account.pointee.pw_dir), accountName = String(cString: account.pointee.pw_name)
        for (key, expected) in [("HOME", accountHome), ("USER", accountName), ("LOGNAME", accountName)] {
            if let override = environment[key], override != expected { try reject("account override \(key)") }
        }
        let result = try load(root: arguments[index + 1])
        guard environment["TMPDIR"]?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == result.temporary.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { try reject("TMPDIR must name the explicit QA temporary directory") }
        guard environment["SQLITE_TMPDIR"] == result.temporary else { try reject("SQLITE_TMPDIR must name the explicit QA temporary directory") }
        _ = try result.verifySQLiteTemporary()
        active = result
        return result
    }
    public func verifySQLiteTemporary() throws -> String {
        guard sqlite3_temp_directory == nil else { try Self.reject("unexpected SQLite global temporary override") }
        var connection: OpaquePointer?, name: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(name); sqlite3_close(connection) }
        guard sqlite3_open_v2(database, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              sqlite3_file_control(connection, "main", SQLITE_FCNTL_TEMPFILENAME, &name) == SQLITE_OK, let name else { try Self.reject("SQLite VFS temporary filename unavailable") }
        let actual = String(cString: name)
        guard actual.hasPrefix(temporary + "/"), Self.hasCanonicalSpelling(actual) else { try Self.reject("SQLite VFS temporary filename escapes QA root") }
        return actual
    }
    public func sameProfile(as other: NativeQARuntime) -> Bool { root == other.root && originalProfile == other.originalProfile }
    public static func effectiveScope(_ supplied: NativeQARuntime?) throws -> NativeQARuntime? {
        if let active, let supplied, !active.sameProfile(as: supplied) { try reject("QA scope differs from active profile") }
        return active ?? supplied
    }
    public func validateStorage() throws {
        _ = try Self.canonical(root)
        let currentRoot = try Self.info(root)
        guard currentRoot.st_uid == getuid(), currentRoot.st_mode & 0o077 == 0, currentRoot.st_mode & 0o700 == 0o700, Int64(currentRoot.st_dev) == profile.root.device, UInt64(currentRoot.st_ino) == profile.root.inode else { try Self.reject("root identity/permissions changed") }
        let profilePath = root + "/profile.json"
        _ = try Self.canonical(profilePath)
        let profileInfo = try Self.info(profilePath)
        guard profileInfo.st_mode & S_IFMT == S_IFREG, profileInfo.st_uid == getuid(), profileInfo.st_nlink == 1, profileInfo.st_size < 131_072 else { try Self.reject("profile metadata changed") }
        guard try Data(contentsOf: URL(fileURLWithPath: profilePath)) == originalProfile else { try Self.reject("profile changed during session") }
        for directory in [support, fixtures, caches, logs, temporary, root + "/bin", support + "/inventory-requests"] {
            _ = try Self.canonical(directory)
            let value = try Self.info(directory)
            guard value.st_mode & S_IFMT == S_IFDIR, value.st_dev == currentRoot.st_dev, value.st_uid == getuid(), value.st_mode & 0o022 == 0, value.st_mode & 0o700 == 0o700 else { try Self.reject("invalid runtime directory") }
        }
        try verify(profile.catalog)
        guard try Self.info(database).st_size <= 4_194_304 else { try Self.reject("catalog exceeds small-fixture bound") }
        guard let iterator = FileManager.default.enumerator(atPath: root) else { try Self.reject("cannot inspect runtime tree") }
        var count = 0
        for case let relative as String in iterator {
            count += 1
            guard count <= 2048 else { try Self.reject("runtime tree exceeds bound") }
            let path = root + "/" + relative
            let value: stat
            do { value = try Self.info(path) }
            catch { if errno == ENOENT && [database + "-journal", database + "-wal", database + "-shm"].contains(path) { continue }; throw error }
            let kind = value.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG, value.st_uid == getuid(), value.st_dev == currentRoot.st_dev, value.st_mode & 0o022 == 0,
                  kind != S_IFREG || value.st_nlink == 1 else { try Self.reject("symlink, mount, hardlink or unsafe runtime entry: \(relative)") }
        }
        try validateCatalog() // Sidecars have been checked before SQLite can inspect them.
    }
    private func validateCatalog() throws {
        var db: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { try Self.reject("cannot inspect isolated catalog") }
        sqlite3_busy_timeout(db, 100)
        func count(_ sql: String) throws -> Int64 {
            sqlite3_finalize(statement); statement = nil
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { try Self.reject("unreadable QA catalog schema") }
            return sqlite3_column_int64(statement, 0)
        }
        // An empty pre-initialization catalog is permitted. Every persisted generation remains scoped.
        guard try count("SELECT COUNT(*) FROM sqlite_master WHERE name='inventory_generations'") > 0 else { return }
        sqlite3_finalize(statement); statement = nil
        guard sqlite3_prepare_v2(db, "SELECT root_path FROM inventory_generations", -1, &statement, nil) == SQLITE_OK else { try Self.reject("missing catalog root metadata") }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0), String(cString: text) == fixtures else { try Self.reject("persisted catalog root is outside QA fixtures") }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { try Self.reject("catalog root inspection did not complete") }
        guard try count("SELECT COUNT(*) FROM inventory_nodes WHERE name IN ('.','..') OR instr(name,'/')>0 OR (parent_id IS NOT NULL AND name='')") == 0 else { try Self.reject("persisted node contains a traversal component") }
    }
    public func openLog(_ name: String) throws -> FileHandle {
        guard ["viewer.log", "worker.log", "worker-errors.log"].contains(name) else { try Self.reject("unknown log destination") }
        try validateStorage()
        let fd = open(logs + "/" + name, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { try Self.reject("cannot open contained log") }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_uid == getuid(), Int64(value.st_dev) == profile.root.device else { close(fd); try Self.reject("unsafe log object") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    public func verify(_ item: Item) throws {
        _ = try Self.canonical(item.path)
        let current = try Self.info(item.path)
        let kind = current.st_mode & S_IFMT
        guard Int64(current.st_dev) == item.device, UInt64(current.st_ino) == item.inode, current.st_uid == getuid(),
              (item.kind == "file" ? kind == S_IFREG && current.st_nlink == 1 && current.st_mode & 0o111 == 0 : kind == S_IFDIR) else { try Self.reject("registered item identity/type changed: \(item.path)") }
    }
    /// Additional restriction only. The existing Trash policy still performs all its normal safety checks.
    public func validateTrash(_ path: String) throws {
        try validateStorage()
        guard path.hasPrefix(fixtures + "/"), let item = profile.fixtures.first(where: { $0.path == path }), item.authorized else { try Self.reject("target is not an explicitly registered disposable fixture") }
        try verify(item)
        var ancestor = item.kind == "directory" ? path : (path as NSString).deletingLastPathComponent
        while ancestor == fixtures || ancestor.hasPrefix(fixtures + "/") {
            if lstatExists(ancestor + "/.git") { try Self.reject("Git worktrees are unsupported in strict QA") }
            if ancestor == fixtures { break }; ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        guard !path.split(separator: "/").contains(".git") else { try Self.reject("Git metadata is never a disposable QA target") }
        if item.kind == "directory" {
            guard let iterator = FileManager.default.enumerator(atPath: path) else { try Self.reject("cannot verify fixture descendants") }
            var count = 0
            for case let relative as String in iterator {
                count += 1
                guard count <= 256, let child = profile.fixtures.first(where: { $0.path == path + "/" + relative }), child.authorized else { try Self.reject("directory contains an unregistered descendant") }
                try verify(child)
                guard !child.path.split(separator: "/").contains(".git") else { try Self.reject("Git metadata descendant blocks strict QA target") }
            }
        }
    }
    public func validateRequest(_ path: String?, action: String) throws {
        try validateStorage()
        guard ["refresh", "focus", "pause", "resume"].contains(action) else { try Self.reject("unsupported worker request") }
        if let path {
            guard path == fixtures || path.hasPrefix(fixtures + "/"), Self.hasCanonicalSpelling(path) else { try Self.reject("request is outside fixtures") }
            // A disappeared selected item is allowed; verify its nearest existing ancestor without following links.
            var ancestor = path
            while lstatExists(ancestor) == false && ancestor != fixtures { ancestor = (ancestor as NSString).deletingLastPathComponent }
            _ = try Self.canonical(ancestor)
        } else if action == "focus" { try Self.reject("focus needs a path") }
    }
    public var profileSHA256: String { SHA256.hash(data: originalProfile).map { String(format: "%02x", $0) }.joined() }
    public func destinations() -> [String: String] {
        ["root": root, "profile_sha256": profileSHA256, "application_support": support, "catalog": database, "worker_state": workerState, "mailbox": support + "/inventory-requests", "caches": caches, "logs": logs, "temporary": temporary, "preferences_domain": Self.bundleIdentifier, "window_restoration": "disabled", "fixtures": fixtures, "worker": helper, "foundation_os_temporary_exception": FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path]
    }
}
private func lstatExists(_ path: String) -> Bool { var value = stat(); return lstat(path, &value) == 0 }

/// Advisory lock is process-owned and automatically released after a crash. No PID-based recovery kill.
public final class NativeQASessionLock {
    private var descriptor: Int32 = -1
    public init(_ runtime: NativeQARuntime) throws {
        try runtime.validateStorage()
        descriptor = open(runtime.support + "/viewer-session.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        var value = stat()
        guard descriptor >= 0, fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(), value.st_nlink == 1, Int64(value.st_dev) == runtime.profile.root.device, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { if descriptor >= 0 { close(descriptor) }; descriptor = -1; try NativeQARuntime.reject("another QA viewer session holds the lock") }
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}
