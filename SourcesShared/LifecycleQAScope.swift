import Foundation
import Darwin

/// Explicit, repository-bound development installation. Never inferred from HOME, a database or an environment variable.
/// Production constants and the strict native Trash QA runtime remain independent.
public struct LifecycleQAScope: Sendable {
    public static let viewerIdentifier = "local.macbook.storage-monitor.viewer.lifecycle-qa"
    public static let helperIdentifier = "local.macbook.storage-monitor.helper.lifecycle-qa"
    public static let flag = "--lifecycle-qa-root"
    public static let compiledFixtureRole: String = {
        #if LIFECYCLE_QA_V1
        return "V1"
        #else
        return "V2"
        #endif
    }()
    public static var active: Self?
    public static let expectedRoot: String = {
        #if STORAGE_MONITOR_DISTRIBUTION
        return ""
        #else
        let source = #filePath
        guard source.hasPrefix("/private/tmp/") else { return "" }
        return URL(fileURLWithPath: source).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/lifecycle-qa/runtime").path
        #endif
    }()
    public struct Image: Codable, Sendable {
        public let sha256: String
        public let version: String
        public let build: String
    }
    public struct Profile: Codable, Sendable {
        public let version: Int
        public let session: String
        public let uid: UInt32
        public let device: Int64
        public let inode: UInt64
        public let createdAt: Double
        public let expiresAt: Double
        public let images: [String: Image]
    }
    public let root: String
    public let profile: Profile
    private let originalProfile: Data
    public var home: URL { URL(fileURLWithPath: root + "/home") }
    public var data: URL { home.appendingPathComponent("Library/Application Support/MacBook Storage Monitor") }
    public var database: String { data.appendingPathComponent("history.sqlite3").path }
    public var fixtures: String { root + "/fixtures" }
    public var logs: String { root + "/Logs" }
    public var temporary: String { root + "/Temporary" }
    public var app: URL { home.appendingPathComponent("Applications/MacBook Storage Monitor.app") }
    public var executable: String { app.appendingPathComponent("Contents/MacOS/StorageMonitor").path }
    public var agentsDirectory: URL { home.appendingPathComponent("Library/LaunchAgents") }
    /// One scoped LaunchAgent: the supervisor, which runs the check, baseline and inventory workers as children.
    public var labels: [String] { ["local.macbook.storage-monitor.lifecycle-qa." + profile.session] }
    public var expired: Bool { Date().timeIntervalSince1970 >= profile.expiresAt }
    public func bundle(_ role: String) -> URL { URL(fileURLWithPath: root + "/Bundles/" + role + ".app") }
    public var installer: URL { bundle("Installer").appendingPathComponent("Contents/MacOS/StorageMonitor") }
    public var arguments: [String] { [Self.flag, root] }
    public func agentURL(_ label: String) -> URL { agentsDirectory.appendingPathComponent(label + ".plist") }

    public static func refuse(_ message: String) throws -> Never { try NativeQARuntime.reject("lifecycle installation: " + message) }
    private static func regularData(_ path: String, limit: Int = 131_072) throws -> Data {
        _ = try NativeQARuntime.canonical(path)
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { try refuse("cannot open private file") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= limit else { try refuse("unsafe private file") }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
    public static func load(root: String, expected: String = expectedRoot, now: Double = Date().timeIntervalSince1970) throws -> Self {
        #if STORAGE_MONITOR_DISTRIBUTION
        try refuse("unavailable in distribution builds")
        #else
        guard !expected.isEmpty, root == expected, root.hasPrefix("/private/tmp/") else { try refuse("requires the exact baked disposable-source runtime") }
        _ = try NativeQARuntime.canonical(root)
        let info = try NativeQARuntime.info(root), bytes = try regularData(root + "/profile.json")
        let profile = try JSONDecoder().decode(Profile.self, from: bytes)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              profile.version == 1, profile.uid == getuid(), profile.device == Int64(info.st_dev), profile.inode == UInt64(info.st_ino),
              UUID(uuidString: profile.session)?.uuidString.lowercased() == profile.session,
              profile.createdAt <= now + 5, profile.expiresAt > profile.createdAt, profile.expiresAt - profile.createdAt <= 7200,
              Set(profile.images.keys) == Set(["Installer", "V1", "V2"]),
              profile.images.values.allSatisfy({ $0.sha256.count == 64 && $0.sha256.allSatisfy { $0.isHexDigit } }),
              profile.images["Installer"]?.sha256 == profile.images["V2"]?.sha256,
              profile.images["V1"]?.sha256 != profile.images["V2"]?.sha256,
              profile.images["V1"]?.version == "0.0.0", profile.images["V1"]?.build == "1",
              profile.images["V2"]?.version == "0.0.0", profile.images["V2"]?.build == "2" else { try refuse("profile identity, image roles or lease invalid") }
        let scope = Self(root: root, profile: profile, originalProfile: bytes)
        try scope.validateStorage()
        for role in ["Installer", "V1", "V2"] { try scope.validateBundle(scope.bundle(role), roles: [role]) }
        return scope
        #endif
    }
    /// Expiry forbids new work, while status and uninstall remain possible for owned cleanup.
    public func admit(command: String) throws {
        try validateStorage()
        if expired && !["status", "uninstall", "lifecycle-qa-inspect"].contains(command) { try Self.refuse("lease expired; only owned status and cleanup are allowed") }
    }
    public func validateStorage() throws {
        _ = try NativeQARuntime.canonical(root)
        let value = try NativeQARuntime.info(root)
        guard value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFDIR, value.st_mode & 0o077 == 0,
              Int64(value.st_dev) == profile.device, UInt64(value.st_ino) == profile.inode,
              try Self.regularData(root + "/profile.json") == originalProfile else { try Self.refuse("root/profile changed") }
        for path in [home.path, data.path, fixtures, logs, temporary, agentsDirectory.path, root + "/Bundles"] {
            _ = try NativeQARuntime.canonical(path)
            let item = try NativeQARuntime.info(path)
            guard item.st_mode & S_IFMT == S_IFDIR, item.st_uid == getuid(), item.st_mode & 0o022 == 0, Int64(item.st_dev) == profile.device else { try Self.refuse("unsafe destination directory") }
        }
        // Include app/transaction/database sidecars: no operational symlink can redirect a write.
        guard let tree = FileManager.default.enumerator(atPath: root) else { try Self.refuse("cannot inspect private tree") }
        var count = 0
        for case let relative as String in tree {
            count += 1; guard count <= 2048 else { try Self.refuse("private tree exceeds small-fixture bound") }
            let path = root + "/" + relative
            var item = stat()
            if lstat(path, &item) != 0 { if errno == ENOENT { continue }; try Self.refuse("private object unavailable") }
            let kind = item.st_mode & S_IFMT
            guard item.st_uid == getuid(), Int64(item.st_dev) == profile.device, item.st_mode & 0o022 == 0,
                  kind == S_IFDIR || (kind == S_IFREG && item.st_nlink == 1 && item.st_size <= 134_217_728) else { try Self.refuse("linked, foreign, mounted or oversized private object") }
        }
    }
    public func validateFixtures() throws {
        try validateStorage()
        guard let tree = FileManager.default.enumerator(atPath: fixtures) else { try Self.refuse("fixtures unavailable") }
        var count = 0, bytes: Int64 = 0
        for case let relative as String in tree {
            count += 1; let info = try NativeQARuntime.info(fixtures + "/" + relative)
            bytes += info.st_mode & S_IFMT == S_IFREG ? info.st_size : 0
            guard count <= 256, bytes <= 16_777_216 else { try Self.refuse("fixtures exceed bounded lifecycle test") }
        }
    }
    public func validateRequest(database: String, path: String?) throws {
        try admit(command: "inventory-request")
        guard database == self.database else { try Self.refuse("request database is outside scope") }
        guard let path else { return }
        guard path == fixtures || path.hasPrefix(fixtures + "/"),
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { try Self.refuse("request path escaped fixtures") }
        var ancestor = path
        while !FileManager.default.fileExists(atPath: ancestor), ancestor != fixtures { ancestor = (ancestor as NSString).deletingLastPathComponent }
        _ = try NativeQARuntime.canonical(ancestor)
    }
    public func validateBundle(_ app: URL, roles: [String] = ["V1", "V2"]) throws {
        guard app.path == self.app.path || app.path == self.app.deletingLastPathComponent().appendingPathComponent(".MacBook Storage Monitor.previous.app").path || roles.contains(where: { app.path == bundle($0).path }) else { try Self.refuse("unadmitted bundle path") }
        let infoBytes = try Self.regularData(app.appendingPathComponent("Contents/Info.plist").path)
        guard let info = try PropertyListSerialization.propertyList(from: infoBytes, format: nil) as? [String: Any], info["CFBundleIdentifier"] as? String == Self.helperIdentifier else { try Self.refuse("helper bundle identity changed") }
        let path = app.appendingPathComponent("Contents/MacOS/StorageMonitor").path
        _ = try NativeQARuntime.canonical(path)
        let hash = try NativeQARuntime.hash(path)
        guard roles.contains(where: { role in
            guard let image = profile.images[role] else { return false }
            return image.sha256 == hash && info["CFBundleShortVersionString"] as? String == image.version && info["CFBundleVersion"] as? String == image.build
        }) else { try Self.refuse("helper hash/version is not an admitted image") }
    }
    public func validateCurrentImage(installerOnly: Bool) throws {
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &bytes, UInt32(bytes.count)) > 0, let real = realpath(String(cString: bytes), nil) else { try Self.refuse("kernel image unavailable") }
        defer { free(real) }
        let actual = String(cString: real)
        if installerOnly && actual == installer.path { try validateBundle(bundle("Installer"), roles: ["Installer"]) }
        else if !installerOnly && actual == executable { try validateBundle(app) }
        else { try Self.refuse("command must run from its pinned image role") }
    }
    public func workerArguments(command: String) -> [String] {
        let budget = command == "inventory-work" ? ["--budget", "2"] : []
        return [executable, command] + budget + arguments + ["--root", fixtures, "--data-dir", data.path]
    }
    public func validateAgent(_ path: String, expected: [[String: Any]]) throws {
        guard (path as NSString).deletingLastPathComponent == agentsDirectory.path || (path as NSString).deletingLastPathComponent == data.appendingPathComponent("install-transaction").path else { try Self.refuse("agent path escaped private installation") }
        let bytes = try Self.regularData(path)
        guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, labels.contains(label),
              plist["ProgramArguments"] as? [String] == workerArguments(command: "supervise"),
              expected.contains(where: { NSDictionary(dictionary: plist).isEqual(to: $0) }) else { try Self.refuse("saved agent differs from complete generated fixture plist") }
    }
    public func validateSavedAgent(name: String, original: String, expected: [[String: Any]]) throws {
        guard name.range(of: "^agent-[0-9]+[.]plist$", options: .regularExpression) != nil,
              (original as NSString).deletingLastPathComponent == agentsDirectory.path,
              (original as NSString).lastPathComponent.range(of: "^[A-Za-z0-9._-]+[.]plist$", options: .regularExpression) != nil else { try Self.refuse("recovery journal contains an escaped agent path") }
        try validateAgent(data.appendingPathComponent("install-transaction/" + name).path, expected: expected)
    }
    public static func validateEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let account = getpwuid(getuid()) else { try refuse("account unavailable") }
        let home = String(cString: account.pointee.pw_dir)
        for key in environment.keys where key.hasPrefix("DYLD_") || key.hasPrefix("STORAGE_MONITOR_") || ["CFFIXED_USER_HOME", "CFPREFERENCES_AVOID_DAEMON", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"].contains(key) { try refuse("unsupported environment override " + key) }
        if let override = environment["HOME"], override != home { try refuse("HOME override is not an installation scope") }
    }
    public static func bootstrapViewer(arguments: [String], bundle: String?) throws -> Self? {
        guard arguments.contains(where: { $0.hasPrefix("--lifecycle-qa") }) || bundle == viewerIdentifier else { return nil }
        try validateEnvironment()
        guard bundle == viewerIdentifier, arguments.count == 3, arguments[1] == flag else { try refuse("viewer needs its own identity and exactly one explicit scope") }
        let scope = try load(root: arguments[2]); try scope.admit(command: "viewer")
        guard ProcessInfo.processInfo.environment["TMPDIR"] == scope.temporary + "/",
              ProcessInfo.processInfo.environment["SQLITE_TMPDIR"] == scope.temporary else { try refuse("viewer temporary paths must belong to its scope") }
        active = scope
        return scope
    }
}

public final class LifecycleQALease {
    private let fd: Int32
    public init(_ scope: LifecycleQAScope, name: String = "viewer.lock") throws {
        guard ["viewer.lock", "installer.lock"].contains(name) else { try LifecycleQAScope.refuse("unknown lease") }
        try scope.validateStorage()
        let descriptor = open(scope.root + "/" + name, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        var value = stat()
        guard descriptor >= 0, fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == getuid(), value.st_nlink == 1, Int64(value.st_dev) == scope.profile.device,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { if descriptor >= 0 { close(descriptor) }; try LifecycleQAScope.refuse("another process owns the lifecycle " + name) }
        fd = descriptor
    }
    deinit { close(fd) }
}
