import Foundation

// Cleanup Inspector tests: detectors on synthetic layouts (Claude Code, Codex, Node, Python, Git worktrees, agent
// sessions, protected scopes), the assessment policy, safety (nothing executed, written or read beyond the
// allowlist; bounded symlinks; permission failures; age and process absence never establish eligibility; stale
// identity), presentation and the read-only preview. Fixtures live in an isolated folder; nothing else is touched.

private final class CleanupFixture {
    let root: URL
    let home: URL
    let marker: URL
    let fm = FileManager.default
    init(_ root: URL) throws {
        self.root = root
        try? fm.removeItem(at: root)
        home = root.appendingPathComponent("home")
        marker = root.appendingPathComponent("EXECUTED-MARKER")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }
    @discardableResult func dir(_ relative: String) throws -> String {
        let p = path(relative); try fm.createDirectory(atPath: p, withIntermediateDirectories: true); return p
    }
    @discardableResult func file(_ relative: String, _ text: String = "", executable: Bool = false, modified: Date? = nil) throws -> String {
        let p = path(relative)
        try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: p))
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p) }
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: p) }
        return p
    }
    /// A file that starts like a Mach-O executable and, if it were ever run as a script, would create the marker.
    @discardableResult func executable(_ relative: String) throws -> String {
        let p = path(relative)
        try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data([0xCF, 0xFA, 0xED, 0xFE])
        data.append(Data("\n#!/bin/sh\ntouch '\(marker.path)'\n".utf8))
        try data.write(to: URL(fileURLWithPath: p))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        return p
    }
    func link(_ relative: String, to target: String) throws {
        let p = path(relative)
        try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: p, withDestinationPath: target)
    }
    /// Every path under the fixture with its size, modification time and mode (to prove nothing changed).
    func snapshot() -> [String: String] {
        var result = [String: String]()
        guard let walker = fm.enumerator(atPath: root.path) else { return result }
        while let relative = walker.nextObject() as? String {
            var st = stat()
            guard lstat(root.appendingPathComponent(relative).path, &st) == 0 else { continue }
            result[relative] = "\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)|\(st.st_mode)|\(st.st_ino)"
        }
        return result
    }
}

/// An inventory row for a path, from its current metadata (as the indexer would have recorded it).
private func cleanupNode(_ path: String, id: Int64 = 1, inode: UInt64? = nil, status: InventoryValueStatus = .complete, hardlink: Bool = false) -> InventoryNode? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let kind: InventoryNodeKind
    switch st.st_mode & S_IFMT { case S_IFDIR: kind = .directory; case S_IFLNK: kind = .symlink; default: kind = .file }
    let birth = Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec)
    let allocated = Int64(st.st_blocks) * 512
    return InventoryNode(id: id, parentID: 0, identity: InventoryIdentity(device: Int64(st.st_dev), inode: inode ?? UInt64(st.st_ino), birthNanoseconds: birth, volumeUUID: nil),
                         path: path, name: (path as NSString).lastPathComponent, kind: kind, logicalBytes: Int64(st.st_size), allocatedBytes: status == .stale ? nil : allocated,
                         previousLogicalBytes: status == .stale ? Int64(st.st_size) : nil, previousAllocatedBytes: status == .stale ? allocated : nil, objectLogicalBytes: nil, objectAllocatedBytes: nil,
                         directLogicalBytes: 0, directAllocatedBytes: 0, childCount: 0, descendantFiles: 0, descendantDirectories: 0, status: status,
                         coverageState: status == .stale ? "stale" : "complete", listingState: nil, statusReason: nil, measuredAt: Date(), modifiedAt: nil, generation: 1, isHardlinkAlias: hardlink, historicalGrowthBytes: nil)
}

private func runGit(_ arguments: [String], in directory: String) -> Bool {
    guard let git = GitInspector.available() else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: git.executable)
    process.arguments = ["-C", directory] + arguments
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory, "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                           "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid", "GIT_CONFIG_NOSYSTEM": "1"]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func cleanupInspectorTests(_ folder: URL, _ test: (Bool, String) throws -> Void) throws {
    let f = try CleanupFixture(folder)
    let now = Date()
    let old = Date(timeIntervalSince1970: 1_262_304_000)   // 2010
    let sentinel = "SENTINEL-SECRET-91f2"

    // MARK: Fixture layouts
    // Claude Code: three versions (2.1.310 is the one the claude command links to), a non-version name, and a
    // second home whose launcher is a script (with a secret in it that must never surface).
    for v in ["2.1.300", "2.1.306", "2.1.310"] { try f.executable(".local/share/claude/versions/\(v)") }
    try f.executable(".local/share/claude/versions/notaversion")
    try f.link(".local/bin/claude", to: f.path(".local/share/claude/versions/2.1.310"))
    try f.executable("other/.local/share/claude/versions/2.1.290")
    try f.executable("other/.local/share/claude/versions/2.1.295")
    try f.file("other/.local/bin/claude", "#!/bin/zsh\nexport ANTHROPIC_API_KEY=\(sentinel)\nexec \"$HOME/.local/share/claude/versions/2.1.295\" \"$@\"\n", executable: true)
    try f.executable("nobody/.local/share/claude/versions/3.0.0")
    try f.executable("nobody/.local/share/claude/versions/3.0.1")
    // Codex: two accounts, current links, PATH link into the default account, a shared (symlinked) binary, an
    // unrecognized release folder.
    for r in ["0.160.0", "0.164.0"] {
        try f.executable(".codex/packages/standalone/releases/\(r)-aarch64-apple-darwin/bin/codex")
        try f.file(".codex/packages/standalone/releases/\(r)-aarch64-apple-darwin/codex-package.json", "{\"version\":\"\(r)\"}")
    }
    try f.link(".codex/packages/standalone/current", to: f.path(".codex/packages/standalone/releases/0.164.0-aarch64-apple-darwin"))
    try f.link(".local/bin/codex", to: f.path(".codex/packages/standalone/current/bin/codex"))
    for r in ["0.158.0", "0.163.0"] {
        try f.executable(".codex-account-2/packages/app-server-daemon/releases/\(r)-aarch64-apple-darwin/bin/codex")
        try f.file(".codex-account-2/packages/app-server-daemon/releases/\(r)-aarch64-apple-darwin/codex-package.json", "{\"version\":\"\(r)\"}")
    }
    try f.link(".codex-account-2/packages/app-server-daemon/current", to: f.path(".codex-account-2/packages/app-server-daemon/releases/0.163.0-aarch64-apple-darwin"))
    try f.dir(".codex/packages/standalone/releases/0.161.0-aarch64-apple-darwin/bin")
    try f.file(".codex/packages/standalone/releases/0.161.0-aarch64-apple-darwin/codex-package.json", "{\"version\":\"0.161.0\"}")
    try f.link(".codex/packages/standalone/releases/0.161.0-aarch64-apple-darwin/bin/codex", to: "/usr/bin/true")
    try f.file(".codex/packages/standalone/releases/weird/readme.txt", "not a release")
    try f.file(".codex/auth.json", "{\"token\":\"\(sentinel)\"}")
    // Node: a Next.js project with lockfile, install record and ignored output; an unrelated "build" folder; a
    // "dist" that is itself a project; nested dependencies.
    try f.file("web/package.json", "{\"name\":\"web-app\",\"dependencies\":{\"next\":\"14.0.0\"},\"scripts\":{\"build\":\"touch '\(f.marker.path)'\"}}")
    try f.file("web/package-lock.json", "{}")
    try f.file("web/.gitignore", "node_modules\n/dist\n.next/\n")
    try f.file("web/node_modules/.package-lock.json", "{}")
    try f.dir("web/node_modules/.bin")
    try f.file("web/node_modules/left-pad/package.json", "{\"name\":\"left-pad\"}")
    try f.file("web/node_modules/left-pad/node_modules/inner/index.js", "x")
    try f.file("web/dist/index.js", "built")
    try f.file("web/.next/build-manifest.json", "{}")
    try f.file("web/build/notes.md", "hand written")
    try f.file("photos/build/IMG_0001.txt", "not generated")
    try f.file("lib/dist/package.json", "{\"name\":\"inner\"}")
    try f.file("lib/package.json", "{\"name\":\"lib\"}")
    try f.file("lib/.gitignore", "dist\n")
    // Python: a project venv with lockfile, an unexplained venv, a tool venv linked from PATH, bytecode caches.
    try f.file("pyproj/pyproject.toml", "[project]\nname='p'\n")
    try f.file("pyproj/uv.lock", "")
    try f.file("pyproj/.venv/pyvenv.cfg", "home = /usr/bin\nversion = 3.12.1\nsecret = \(sentinel)\n")
    try f.file("pyproj/__pycache__/m.cpython-312.pyc", "bytecode")
    try f.file("pyproj/mixed/__pycache__/m.cpython-312.pyc", "bytecode")
    try f.file("pyproj/mixed/__pycache__/notes.txt", "hand written")
    try f.file("loose/venv/pyvenv.cfg", "home = /usr/bin\nversion = 3.11.0\n")
    try f.file(".local/share/uv/tools/ruff/pyvenv.cfg", "home = /usr/bin\nversion = 3.12.0\nuv = 0.4\n")
    try f.executable(".local/share/uv/tools/ruff/bin/ruff")
    try f.link(".local/bin/ruff", to: f.path(".local/share/uv/tools/ruff/bin/ruff"))
    try f.file(".local/share/uv/tools/orphan/pyvenv.cfg", "home = /usr/bin\nversion = 3.12.0\n")
    // Agent sessions (content holds a sentinel that must never be read).
    try f.file(".claude/projects/-web/a1.jsonl", "{\"text\":\"\(sentinel)\"}", modified: old)
    try f.file(".claude/projects/-web/a2.jsonl", "{\"text\":\"\(sentinel)\"}", modified: old)
    try f.file(".claude/projects/-live/b1.jsonl", "{\"text\":\"\(sentinel)\"}", modified: now)
    try f.file(".codex/sessions/2026/10/05/rollout-2026-10-05T21-58-43-abc.jsonl.zst", sentinel, modified: old)
    try f.file(".codex/archived_sessions/rollout-2026-05-05T23-57-41-def.jsonl.zst", sentinel, modified: old)
    try f.file(".codex/thread_history_1.sqlite", "SQLite format 3")
    // Bounded symlinks: a loop and a link escaping the fixture.
    try f.link("web/dist/loop", to: f.path("web/dist/loop"))
    try f.link("web/dist/escape", to: "/")
    // Git: a repository with clean, dirty, untracked, unmerged, locked and orphaned worktrees.
    let gitAvailable = GitInspector.available() != nil
    let repo = try f.dir("repo")
    if gitAvailable {
        try f.file("repo/README.md", "fixture\n")
        _ = runGit(["init", "-q", "-b", "main"], in: repo)
        _ = runGit(["add", "."], in: repo)
        _ = runGit(["commit", "-q", "-m", "init"], in: repo)
        for name in ["clean", "dirty", "untracked", "unmerged", "locked", "relative"] { _ = runGit(["worktree", "add", "-q", "-b", name, f.path("wt-\(name)")], in: repo) }
        // A relative registry pointer is interpreted from the registry directory, never cwd.
        try f.file("repo/.git/worktrees/wt-relative/gitdir", "../../../../wt-relative/.git\n")
        try f.file("wt-dirty/README.md", "changed\n")
        try f.file("wt-untracked/new.txt", "new\n")
        try f.file("wt-unmerged/feature.txt", "feature\n")
        _ = runGit(["add", "."], in: f.path("wt-unmerged"))
        _ = runGit(["commit", "-q", "-m", "feature"], in: f.path("wt-unmerged"))
        _ = runGit(["worktree", "lock", f.path("wt-locked")], in: repo)
    }
    try f.file("wt-orphan/.git", "gitdir: \(f.path("repo/.git/worktrees/gone"))\n")
    try f.file("submodule/.git", "gitdir: ../repo/.git/modules/sub\n")
    // Permissions: an unreadable project.
    try f.file("locked/package.json", "{\"name\":\"locked\"}")
    try f.file("locked/build/out.js", "x")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path("locked/build"))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path("locked/build")) }

    // Caches, an ordinary old file and Storage Monitor's own data (all created before the safety snapshot).
    try f.dir(".npm/_cacache/index-v5")
    try f.dir("Library/Caches/pip/http")
    let ordinary = try f.file("Documents/report.txt", "x", modified: old)
    let ownData = try f.file("Library/Application Support/MacBook Storage Monitor/history.sqlite3", "x")

    // MARK: Environment (fake process table; real Git)
    final class Table: @unchecked Sendable { var observation = ProcessObservation(executables: [], workingDirectories: [], inspected: 300, unreadable: 0) }
    let table = Table()
    func environment(home: String? = nil) -> ArtifactEnvironment {
        let h = home ?? f.home.path
        return ArtifactEnvironment(home: h, pathDirectories: [(h as NSString).appendingPathComponent(".local/bin"), "/usr/bin"], processes: { table.observation },
                                   git: GitInspector.available(), now: { now }, ownData: f.path("Library/Application Support/MacBook Storage Monitor"))
    }
    var reads = [(path: String, purpose: ArtifactReadPurpose)]()
    var outputs = [String]()
    func inspect(_ relative: String, home: String? = nil, inode: UInt64? = nil, status: InventoryValueStatus = .complete) -> ArtifactInspection? {
        let path = relative.hasPrefix("/") ? relative : f.path(relative)
        guard let node = cleanupNode(path, inode: inode, status: status) else { return nil }
        // An audited probe: every content read is recorded.
        let probe = ArtifactProbe()
        let result = ArtifactInspector.inspect(node, environment: environment(home: home), probe: probe)
        reads += probe.contentReads
        if let c = result.classification { outputs += [c.title] + c.supporting.map(\.text) + c.contradicting.map(\.text) + c.unknowns + c.related.map(\.label) + c.dependencies }
        if let a = result.assessment { outputs += [a.summary] + a.reasons + a.risks }
        return result
    }
    func status(_ relative: String, home: String? = nil) -> CleanupStatus? { inspect(relative, home: home)?.assessment?.status }
    let snapshotBefore = f.snapshot()

    // MARK: Claude Code
    let active = inspect(".local/share/claude/versions/2.1.310")
    try test(active?.classification?.kind == .claudeCodeRelease && active?.classification?.facts.isResolved == true && active?.classification?.confidence == .confirmed
             && active?.classification?.characteristics.contains(.active) == true && active?.assessment?.status == .preserve,
             "cleanup claude: the version the claude command resolves to is identified (confirmed) and preserved")
    let historical = inspect(".local/share/claude/versions/2.1.300")
    try test(historical?.classification?.characteristics.contains(.historical) == true && historical?.classification?.facts.otherActiveVersion == "2.1.310"
             && historical?.assessment?.status == .reviewCandidate && historical?.classification?.related.contains { $0.label == "Claude Code 2.1.310" && $0.mustPreserve } == true,
             "cleanup claude: an older version with another version resolved is a historical review candidate, and the active version is listed as one to preserve")
    table.observation = ProcessObservation(executables: [f.path(".local/share/claude/versions/2.1.306")], workingDirectories: [], inspected: 300, unreadable: 0)
    try test(status(".local/share/claude/versions/2.1.306") == .preserve, "cleanup claude: a version a running process executes is preserved even though another is resolved")
    table.observation = ProcessObservation(executables: [], workingDirectories: [], inspected: 300, unreadable: 0)
    let scripted = inspect("other/.local/share/claude/versions/2.1.290", home: f.path("other"))
    try test(scripted?.classification?.facts.otherActiveVersion == "2.1.295" && scripted?.assessment?.status == .reviewCandidate && status("other/.local/share/claude/versions/2.1.295", home: f.path("other")) == .preserve,
             "cleanup claude: a launcher script that names one version resolves it (only the version reference is used)")
    let unnamed = inspect(".local/share/claude/versions/notaversion")
    try test(unnamed?.classification?.confidence == .tentative && unnamed?.assessment?.status == .insufficientEvidence && unnamed?.classification?.unknowns.contains { $0.contains("Version metadata") } == true,
             "cleanup claude: missing version metadata leaves the classification tentative and the evidence insufficient")
    try test(status("nobody/.local/share/claude/versions/3.0.0", home: f.path("nobody")) == .insufficientEvidence,
             "cleanup claude: with no version established as active, no version becomes a review candidate")
    try test(status(".local/share/claude/versions") == .preserve, "cleanup claude: the versions folder (holding the active version) is preserved")

    // MARK: Codex
    try test(status(".codex/packages/standalone/releases/0.164.0-aarch64-apple-darwin") == .preserve, "cleanup codex: the current release is preserved")
    let oldCodex = inspect(".codex/packages/standalone/releases/0.160.0-aarch64-apple-darwin")
    try test(oldCodex?.assessment?.status == .reviewCandidate && oldCodex?.classification?.facts.otherActiveVersion == "0.164.0" && oldCodex?.classification?.characteristics.contains(.historical) == true,
             "cleanup codex: a downloaded release that is not current, resolved or running is a historical review candidate")
    try test(status(".codex-account-2/packages/app-server-daemon/releases/0.163.0-aarch64-apple-darwin") == .preserve
             && inspect(".codex-account-2/packages/app-server-daemon/releases/0.158.0-aarch64-apple-darwin")?.classification?.facts.otherActiveVersion == "0.163.0",
             "cleanup codex: each account's current release is judged within that account (another account's releases are not assumed unused)")
    table.observation = ProcessObservation(executables: [f.path(".codex-account-2/packages/app-server-daemon/releases/0.158.0-aarch64-apple-darwin/bin/codex")], workingDirectories: [], inspected: 300, unreadable: 0)
    try test(status(".codex-account-2/packages/app-server-daemon/releases/0.158.0-aarch64-apple-darwin") == .preserve, "cleanup codex: a release a running process executes is preserved")
    table.observation = ProcessObservation(executables: [], workingDirectories: [], inspected: 300, unreadable: 0)
    let shared = inspect(".codex/packages/standalone/releases/0.161.0-aarch64-apple-darwin")
    try test(shared?.classification?.supporting.contains { $0.text.contains("shared location") } == true, "cleanup codex: a release whose binary links to a shared location says so (the link is not followed)")
    try test(inspect(".codex/packages/standalone/releases/weird")?.classification == nil, "cleanup codex: an unrecognized release structure stays unclassified")

    // MARK: Node
    let deps = inspect("web/node_modules")
    try test(deps?.classification?.kind == .nodeDependencies && deps?.classification?.confidence == .confirmed && deps?.assessment?.status == .reviewCandidate
             && deps?.classification?.characteristics.isSuperset(of: [.generated, .reinstallable]) == true,
             "cleanup node: node_modules of a project with a lockfile and install record is a reinstallable review candidate")
    table.observation = ProcessObservation(executables: [], workingDirectories: [f.path("web")], inspected: 300, unreadable: 0)
    try test(status("web/node_modules") == .preserve, "cleanup node: dependencies of a project a running process works in are preserved")
    table.observation = ProcessObservation(executables: [], workingDirectories: [], inspected: 300, unreadable: 0)
    try test(status("web/dist") == .reviewCandidate && status("web/.next") == .reviewCandidate, "cleanup node: output the project ignores (dist) or its framework writes (.next) is generated output")
    try test(status("web/build") == .insufficientEvidence && status("photos/build") == .insufficientEvidence, "cleanup node: a folder named build is not generated output on its name alone")
    try test(status("lib/dist") == .insufficientEvidence && inspect("lib/dist")?.classification?.contradicting.isEmpty == false, "cleanup node: a dist folder that is itself a project is not treated as output")
    try test(status("web/node_modules/left-pad/node_modules") == .insufficientEvidence, "cleanup node: nested dependency folders are not judged on their own")
    let npm = inspect(".npm/_cacache")
    try test(npm?.classification?.kind == .nodePackageCache && npm?.assessment?.status == .reviewCandidate, "cleanup node: the npm package cache is recognized as a reinstallable cache")

    // MARK: Python
    let venv = inspect("pyproj/.venv")
    try test(venv?.classification?.kind == .pythonVirtualEnvironment && venv?.assessment?.status == .reviewCandidate && venv?.classification?.related.first?.roles == [.project],
             "cleanup python: a project's virtual environment with a lockfile is a review candidate associated with its project")
    try test(status("loose/venv") == .insufficientEvidence, "cleanup python: a virtual environment without a project or lockfile is insufficient evidence")
    try test(status(".local/share/uv/tools/ruff") == .preserve && status(".local/share/uv/tools/orphan") == .insufficientEvidence,
             "cleanup python: a tool environment with a command on PATH is preserved; one without is not assumed unused")
    try test(status("pyproj/__pycache__") == .reviewCandidate && status("pyproj/mixed/__pycache__") == .insufficientEvidence, "cleanup python: bytecode caches are generated; one holding other files is not")
    let pip = inspect("Library/Caches/pip")
    try test(pip?.classification?.kind == .pythonPackageCache && pip?.assessment?.status == .reviewCandidate, "cleanup python: the pip cache is recognized")

    // MARK: Git worktrees
    if gitAvailable {
        let gitBefore = f.snapshot().filter { $0.key.hasPrefix("home/repo/.git") }
        let clean = inspect("wt-clean")
        try test(clean?.classification?.kind == .gitWorktree && clean?.classification?.facts.worktreeRegistered == true && clean?.classification?.facts.uncommittedChanges == 0
                 && clean?.classification?.facts.unpushedCommits == 0 && clean?.assessment?.status == .reviewCandidate,
                 "cleanup git: a registered worktree with no uncommitted, untracked or unmerged work is a review candidate")
        try test(inspect("wt-relative")?.classification?.facts.worktreeRegistered == true,
                 "cleanup git: a relative registry back-pointer resolves from its own directory")
        try test(status("wt-dirty") == .preserve && inspect("wt-dirty")?.assessment?.reasons.contains { $0.contains("uncommitted") } == true, "cleanup git: uncommitted changes preserve a worktree")
        try test(status("wt-untracked") == .preserve, "cleanup git: untracked files preserve a worktree")
        try test(status("wt-unmerged") == .preserve && inspect("wt-unmerged")?.classification?.facts.unpushedCommits == 1, "cleanup git: commits in no other branch or remote preserve a worktree")
        try test(status("wt-locked") == .preserve, "cleanup git: a locked worktree is preserved")
        table.observation = ProcessObservation(executables: [], workingDirectories: [f.path("wt-clean/sub")], inspected: 300, unreadable: 0)
        try test(status("wt-clean") == .preserve, "cleanup git: a worktree a running process works in is preserved")
        table.observation = ProcessObservation(executables: [], workingDirectories: [], inspected: 300, unreadable: 0)
        try test(f.snapshot().filter { $0.key.hasPrefix("home/repo/.git") } == gitBefore, "cleanup git: inspection leaves the repository byte-for-byte unchanged (no index refresh, no locks)")
    } else { try test(true, "cleanup git: Git not available; worktree checks skipped (reported, not passed silently)") }
    try test(status("wt-orphan") == .insufficientEvidence && inspect("wt-orphan")?.classification?.facts.worktreeRegistered == false, "cleanup git: a worktree whose registration is gone is insufficient evidence")
    try test(inspect("submodule")?.classification == nil, "cleanup git: a submodule's .git file is not a worktree")

    // MARK: Agent sessions
    try test(status(".claude/projects/-web") == .reviewCandidate && inspect(".claude/projects/-web")?.classification?.characteristics == [.historical],
             "cleanup sessions: Claude Code session records with no observed use and no recent writes are historical review candidates")
    try test(status(".claude/projects/-live") == .preserve, "cleanup sessions: records written in the last minutes are preserved (a session may be active)")
    table.observation = ProcessObservation(executables: [], workingDirectories: [], openFiles: [f.path(".claude/projects/-web/a1.jsonl")], inspected: 300, unreadable: 0)
    try test(status(".claude/projects/-web") == .preserve, "cleanup sessions: records a running process holds open are preserved")
    table.observation = ProcessObservation(executables: [], workingDirectories: [], inspected: 300, unreadable: 0)
    try test(inspect(".codex/sessions")?.classification?.kind == .agentSessionHistory && status(".codex/archived_sessions") == .reviewCandidate
             && inspect(".codex/sessions/2026/10/05/rollout-2026-10-05T21-58-43-abc.jsonl.zst")?.classification?.kind == .agentSessionRecord,
             "cleanup sessions: Codex dated and archived session records are recognized")
    try test(status(".codex/thread_history_1.sqlite") == .preserve, "cleanup sessions: a tool's state database is preserved")

    // MARK: Protected
    try test(status(".codex/auth.json") == .protected && status("/System/Library") == .protected, "cleanup protected: credentials and system locations are protected")
    try test(inspect(ownData)?.assessment?.status == .protected, "cleanup protected: Storage Monitor's own data is protected")
    try test(status(".codex") == .protected, "cleanup protected: a tool's settings folder itself is protected")

    // MARK: Ordinary and unknown
    try test(inspect(ordinary)?.classification == nil && inspect(ordinary)?.assessment == nil
             && !ArtifactInspector.mightApply(ArtifactSubject(nodeID: 1, path: ordinary, kind: .file, identity: nil), environment: environment()),
             "cleanup unknown: an ordinary old file is not classified and is never assessed")

    // MARK: Safety
    try test(!FileManager.default.fileExists(atPath: f.marker.path), "cleanup safety: no inspected executable (or package script) was run")
    try test(f.snapshot() == snapshotBefore,
             "cleanup safety: inspection changes nothing in the fixture (sizes, times, modes, identities)")
    let allowed = reads.allSatisfy { $0.purpose.allows(fileName: ($0.path as NSString).lastPathComponent) }
    let secretFiles = reads.filter { ["auth.json", "a1.jsonl", "a2.jsonl", "b1.jsonl"].contains(($0.path as NSString).lastPathComponent) || $0.path.hasSuffix(".zst") || $0.path.hasSuffix(".sqlite") }
    try test(allowed && secretFiles.isEmpty && !reads.isEmpty, "cleanup safety: only allowlisted manifest files were read (\(reads.count) reads); credentials, session records and databases were not")
    try test(!outputs.contains { $0.contains(sentinel) }, "cleanup safety: no secret or conversation content appears in any classification, evidence or assessment")
    try test(reads.allSatisfy { ArtifactPaths.canonicalRelativeComponents($0.path, within: f.root.path) != nil },
             "cleanup safety: every allowlisted read resolves inside the fixture, including /tmp aliases")
    let loopEstimate = ArtifactRecoveryEstimate.measure(f.path("web/dist"), probe: ArtifactProbe())
    try test(loopEstimate.complete && loopEstimate.files == 1, "cleanup safety: a symlink loop and a link to / do not extend the bounded walk")
    // Keep display paths separate from resolved filesystem ancestry. These fixtures are disposable;
    // the path comparisons never read file contents or mutate the inspected object.
    let aliasFile = try f.file("alias-scope/real/étoile.txt", "unicode fixture")
    let aliasSibling = try f.file("alias-scope/real-other/étoile.txt", "different object")
    try f.link("alias-scope/parent-link", to: f.path("alias-scope/real"))
    try f.link("alias-scope/final-link", to: aliasFile)
    try f.link("alias-scope/broken-link", to: f.path("alias-scope/missing"))
    try f.link("alias-scope/loop-a", to: f.path("alias-scope/loop-b"))
    try f.link("alias-scope/loop-b", to: f.path("alias-scope/loop-a"))
    try f.link("alias-scope/secret-link", to: f.path(".codex/auth.json"))
    let realFolder = f.path("alias-scope/real")
    try test(ArtifactPaths.canonicalRelativeComponents(aliasFile, within: realFolder) == ["étoile.txt"]
             && ArtifactPaths.canonicalRelativeComponents(f.path("alias-scope/real/../real/étoile.txt"), within: realFolder) == ["étoile.txt"],
             "cleanup paths: redundant components and Unicode retain exact component-aware ancestry")
    try test(ArtifactPaths.canonicalRelativeComponents(f.path("alias-scope/parent-link/étoile.txt"), within: realFolder) == ["étoile.txt"]
             && ArtifactPaths.canonicalRelativeComponents(f.path("alias-scope/final-link"), within: realFolder) == ["étoile.txt"],
             "cleanup paths: parent and final symlinks resolve to the same existing object")
    try test(ArtifactPaths.canonicalRelativeComponents(aliasSibling, within: realFolder) == nil,
             "cleanup paths: a same-prefix sibling is not a descendant")
    try test(ArtifactPaths.canonicalRelativeComponents(f.path("alias-scope/broken-link"), within: realFolder) == nil
             && ArtifactPaths.canonicalRelativeComponents(f.path("alias-scope/loop-a"), within: realFolder) == nil
             && status("alias-scope/broken-link") == .insufficientEvidence,
             "cleanup paths: broken links and symlink loops fail closed")
    try test(status("alias-scope/secret-link") == .protected,
             "cleanup paths: a benignly named link into credentials stays protected")
    let working = ArtifactPaths.components(FileManager.default.currentDirectoryPath)
    let absolute = ArtifactPaths.components(aliasFile)
    let common = zip(working, absolute).prefix { $0.0 == $0.1 }.count
    let relative = (Array(repeating: "..", count: working.count - common) + Array(absolute.dropFirst(common))).joined(separator: "/")
    try test(ArtifactPaths.canonicalRelativeComponents(relative, within: realFolder) == ["étoile.txt"],
             "cleanup paths: relative and absolute names resolve to the same file")
    if FileManager.default.fileExists(atPath: "/tmp"), FileManager.default.fileExists(atPath: "/private/tmp") {
        try test(ArtifactPaths.canonicalRelativeComponents("/tmp", within: "/private/tmp") == []
                 && ArtifactPaths.canonicalRelativeComponents("/private/tmp", within: "/tmp") == [],
                 "cleanup paths: macOS /tmp and /private/tmp aliases resolve to the same directory")
    }
    let unreadable = inspect("locked/build")
    try test(unreadable?.assessment?.status == .insufficientEvidence && unreadable?.incomplete.contains { $0.contains("did not allow") } == true,
             "cleanup safety: a folder macOS does not let us read is reported as incomplete evidence, never as empty")
    // Age alone never decides: the same release old or new gets the same status; with nothing active it is never a candidate.
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path("nobody/.local/share/claude/versions/3.0.1"))
    try test(status("nobody/.local/share/claude/versions/3.0.1", home: f.path("nobody")) == .insufficientEvidence
             && status(".local/share/claude/versions/2.1.300") == .reviewCandidate,
             "cleanup safety: an old modification date never makes an item a review candidate")
    // Absence from the process table is never proof.
    table.observation = ProcessObservation(executables: [], workingDirectories: [], inspected: 0, unreadable: 0)
    let blind = inspect(".codex/packages/standalone/releases/0.160.0-aarch64-apple-darwin")
    try test(blind?.assessment?.status == .insufficientEvidence && blind?.classification?.supporting.contains { $0.text.contains("could not be inspected") } == true,
             "cleanup safety: when running processes cannot be inspected, a historical release is not a review candidate")
    table.observation = ProcessObservation(executables: [], workingDirectories: [], inspected: 290, unreadable: 10)
    try test(inspect(".codex/packages/standalone/releases/0.160.0-aarch64-apple-darwin")?.classification?.supporting.contains { $0.text.contains("10 processes could not be inspected") && $0.text.contains("not proof") } == true,
             "cleanup safety: a partly readable process table is reported as such: no observation is presented as proof of disuse")
    table.observation = ProcessObservation(executables: [], workingDirectories: [], inspected: 300, unreadable: 0)
    // Stale identity: the path now holds a different object, or nothing.
    let replaced = inspect(".local/share/claude/versions/2.1.300", inode: 1)
    try test(replaced?.identity == .changed && replaced?.assessment?.status == .insufficientEvidence && replaced?.assessment?.summary.contains("different item") == true,
             "cleanup freshness: a path that now holds a different filesystem object invalidates the earlier evidence")
    var gone = cleanupNode(f.path(".local/share/claude/versions/2.1.306"))!
    gone = gone.withPath(f.path(".local/share/claude/versions/2.1.999"), kind: .file)
    let missing = ArtifactInspector.inspect(gone, environment: environment())
    try test(missing.identity == .missing && missing.assessment?.status == .insufficientEvidence && missing.assessment?.summary.contains("no longer") == true,
             "cleanup freshness: an item no longer on disk keeps no recommendation and says it is gone")

    // MARK: Policy (facts only)
    func classified(_ kind: ArtifactKind, confidence: ArtifactConfidence = .confirmed, _ edit: (inout ArtifactFacts) -> Void) -> ArtifactClassification {
        var facts = ArtifactFacts(); edit(&facts)
        return ArtifactClassification(kind: kind, tool: .codex, title: "t", characteristics: [], confidence: confidence, supporting: [], facts: facts)
    }
    try test(CleanupPolicy.assess(classified(.codexRelease) { $0.otherActiveVersion = "1"; $0.isRunning = false }, identity: .verified).status == .reviewCandidate
             && CleanupPolicy.assess(classified(.codexRelease) { $0.otherActiveVersion = "1"; $0.isRunning = true }, identity: .verified).status == .preserve
             && CleanupPolicy.assess(classified(.codexRelease) { $0.isRunning = false }, identity: .verified).status == .insufficientEvidence
             && CleanupPolicy.assess(classified(.codexRelease, confidence: .tentative) { $0.otherActiveVersion = "1"; $0.isRunning = false }, identity: .verified).status == .insufficientEvidence
             && CleanupPolicy.assess(classified(.gitWorktree) { $0.worktreeRegistered = true; $0.uncommittedChanges = 0; $0.untrackedFiles = 0 }, identity: .verified).status == .insufficientEvidence
             && CleanupPolicy.assess(classified(.nodePackageCache) { $0.protectedScope = true }, identity: .verified).status == .protected
             && CleanupPolicy.assess(classified(.codexRelease) { $0.otherActiveVersion = "1"; $0.isRunning = false }, identity: .changed).status == .insufficientEvidence,
             "cleanup policy: positive use preserves; review needs established facts (another active version, process table read, confident classification, worktree state known); identity changes void it")
    try test(CleanupStatus.allCases.allSatisfy { !$0.title.lowercased().contains("safe") && !$0.title.lowercased().contains("delete") },
             "cleanup policy: no status says safe to delete")

    // MARK: Presentation
    let shown = CleanupInspectorPresentation(historical!, formatter: { "\($0) B" })!
    try test(shown.statusTitle == "Review candidate" && shown.offersPreview && shown.summary.contains("not a recommendation to delete") && shown.evidence.count <= CleanupInspectorPresentation.visibleEvidence
             && shown.allEvidence.count >= shown.evidence.count && shown.related.contains { $0.label == "Claude Code 2.1.310" },
             "cleanup presentation: a review candidate says it is not a deletion recommendation, shows a few observations and expands to all of them")
    try test(CleanupInspectorPresentation(inspect(ordinary)!, formatter: { "\($0)" }) == nil, "cleanup presentation: ordinary items get no cleanup section (the Inspector is unchanged)")
    let preserved = CleanupInspectorPresentation(active!, formatter: { "\($0) B" })!
    try test(!preserved.offersPreview && preserved.statusTitle == "Preserve", "cleanup presentation: no preview is offered for preserved items")
    let folderShown = CleanupInspectorPresentation(deps!, formatter: { "\($0) B" })!
    try test(folderShown.recovery == "Recovery amount unknown" && !folderShown.recovery.contains("0 B"), "cleanup presentation: a folder's recovery is unknown until measured, never shown as zero")

    // MARK: Preview and recovery estimate
    let original = try f.file("clones/original.bin", String(repeating: "x", count: 64 * 1024))
    try FileManager.default.copyItem(atPath: original, toPath: f.path("clones/clone.bin"))   // APFS clone
    _ = link(original, f.path("clones/hardlink.bin"))
    let estimate = ArtifactRecoveryEstimate.measure(f.path("clones"), probe: ArtifactProbe())
    try test(estimate.complete && estimate.files == 3 && estimate.hardLinkedFiles == 2 && estimate.sharedFiles == 1 && estimate.privateBytes == 0,
             "cleanup accounting: clones and hard links are not counted as recoverable (APFS private size, links excluded)")
    let limited = ArtifactRecoveryEstimate.measure(f.path("web"), probe: ArtifactProbe(), limit: 3)
    let previewNode = cleanupNode(f.path("web/dist"))!
    let preview = CleanupPreview(inspection: inspect("web/dist")!, node: previewNode, children: [], childrenComplete: false, estimate: limited)
    if case .unknown = preview.recovery {} else { try test(false, "cleanup preview: an incomplete walk gives no estimate") }
    try test(!preview.contentsComplete && preview.unknowns.count >= 0 && preview.limitations.count >= 2, "cleanup preview: an incomplete listing and walk are presented as incomplete, with accounting limitations")
    let releasePreview = CleanupPreview(inspection: historical!, node: cleanupNode(f.path(".local/share/claude/versions/2.1.300"))!, children: [], childrenComplete: true, estimate: nil)
    try test(releasePreview.preserved.contains { $0.label == "Claude Code 2.1.310" } && !releasePreview.risks.isEmpty && releasePreview.target.hasSuffix("2.1.300"),
             "cleanup preview: the preview names the exact target, the versions that must be preserved and the risks")
}

func cleanupTrashTests(_ folder: URL, _ test: (Bool, String) throws -> Void) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: folder)
    let home = folder.appendingPathComponent("home")
    func make(_ relative: String, _ text: String = "x") throws -> String {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url); return url.path
    }
    let historical = try make(".local/share/claude/versions/2.1.300"), active = try make(".local/share/claude/versions/2.1.310")
    try fm.createDirectory(atPath: home.appendingPathComponent(".local/bin").path, withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: home.appendingPathComponent(".local/bin/claude").path, withDestinationPath: active)
    let plain = try make("Projects/notes.txt")
    let secret = try make(".codex/auth.json", "{}")
    let environment = ArtifactEnvironment(home: home.path, pathDirectories: [home.appendingPathComponent(".local/bin").path], processes: { ProcessObservation(executables: [], workingDirectories: [], inspected: 100, unreadable: 0) }, git: nil)
    // Version files must look like executables for a confident classification.
    for path in [historical, active] { var data = Data([0xCF, 0xFA, 0xED, 0xFE]); data.append(Data("x".utf8)); try data.write(to: URL(fileURLWithPath: path)); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    func inspected(_ path: String) -> (InventoryNode, ArtifactInspection) { let n = cleanupNode(path)!; return (n, ArtifactInspector.inspect(n, environment: environment)) }
    let (oldNode, oldInspection) = inspected(historical), (activeNode, activeInspection) = inspected(active), (secretNode, secretInspection) = inspected(secret)
    let plainNode = cleanupNode(plain)!
    func decide(_ node: InventoryNode, _ inspection: ArtifactInspection?, examined: Bool = true) -> CleanupTrashDecision { CleanupTrashPolicy.decide(node: node, inspection: inspection, examined: examined, home: home.path) }
    if case .allowed(let override, _) = decide(oldNode, oldInspection), !override {} else { try test(false, "cleanup trash: a review candidate retains advisory plain-confirmation semantics") }
    try test(true, "cleanup trash: a review candidate retains advisory plain-confirmation semantics")
    if case .blocked = decide(activeNode, activeInspection) { try test(true, "cleanup trash: a verified active executable is a hard block, including after acknowledgment") }
    else { try test(false, "cleanup trash: a verified active executable must be blocked") }
    if case .blocked = decide(secretNode, secretInspection) {} else { try test(false, "cleanup trash: protected items cannot be moved") }
    if case .allowed(true, let warnings) = decide(plainNode, nil), warnings.first?.contains("has not assessed") == true {} else { try test(false, "cleanup trash: an unrecognized item needs an override") }
    if case .blocked = decide(plainNode, nil, examined: false) {} else { try test(false, "cleanup trash: nothing can be moved while its review is running") }
    try test(true, "cleanup trash: protected items cannot be moved; unrecognized items need an override; nothing can be moved while its review is running")
    let broad = [home.path, home.appendingPathComponent("Library").path, home.appendingPathComponent("Documents").path, "/Users", "/", "/Applications"]
    var allBlocked = true
    for path in broad {
        let node = (cleanupNode(path) ?? cleanupNode(home.path)!).withPath(path, kind: .directory)
        if case .blocked = decide(node, nil) {} else { allBlocked = false }
    }
    try test(allBlocked, "cleanup trash: the home folder, its main folders, folders containing it and system roots can never be moved")
    // Performing: re-checks at the last moment; the move function is only called for the exact, verified path.
    final class Calls: @unchecked Sendable { var urls = [URL]() }
    let calls = Calls()
    let fake: (URL) throws -> URL? = { url in calls.urls.append(url); return nil }
    let declined = CleanupTrashPolicy.perform(node: plainNode, decision: decide(plainNode, nil), overrideAccepted: false, environment: environment, trash: fake)
    var replaced = oldNode.withPath(oldNode.path, kind: .file)
    replaced = InventoryNode(id: replaced.id, parentID: replaced.parentID, identity: InventoryIdentity(device: replaced.identity.device, inode: 1, birthNanoseconds: replaced.identity.birthNanoseconds, volumeUUID: nil),
                             path: replaced.path, name: replaced.name, kind: .file, logicalBytes: 1, allocatedBytes: 1, previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil,
                             directLogicalBytes: 0, directAllocatedBytes: 0, childCount: 0, descendantFiles: 0, descendantDirectories: 0, status: .complete, coverageState: "complete", listingState: nil, statusReason: nil,
                             measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
    let changed = CleanupTrashPolicy.perform(node: replaced, decision: .allowed(override: false, warnings: []), overrideAccepted: false, environment: environment, trash: fake)
    let forced = CleanupTrashPolicy.perform(node: secretNode, decision: .allowed(override: false, warnings: []), overrideAccepted: false, environment: environment, trash: fake)
    try test(calls.urls.isEmpty && declined == .refused("The warning was not accepted.") && changed == .refused("The path now refers to a different item; nothing was moved.")
             && { if case .refused(let why) = forced { return why.hasPrefix("Protected") }; return false }(),
             "cleanup trash: nothing moves when the override was not accepted, when the path now holds a different item, or when it is protected (re-checked at the moment of the move)")
    let moved = CleanupTrashPolicy.perform(node: oldNode, decision: decide(oldNode, oldInspection), overrideAccepted: false, environment: environment, trash: fake)
    // The release contains a program, so the program-use warning refuses first; either refusal must move nothing.
    try test((moved == .refused(CleanupTrashPolicy.unavailableReason) || moved == .refused("The warning was not accepted.")) && calls.urls.isEmpty && fm.fileExists(atPath: historical),
             "cleanup trash: legacy advisory review cannot replace a displayed explicit confirmation")
    guard case .ready(let confirmation) = CleanupTrashPolicy.prepare(node: oldNode, environment: environment) else { throw CocoaError(.fileReadUnknown) }
    // Confirmed with its warnings accepted (the release contains a program), so the simulated macOS failure is reached.
    let failing = CleanupTrashPolicy.perform(confirmation: confirmation, overrideAccepted: true, environment: environment, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
    let failed: Bool = { if case .failed(let reason) = failing { return reason.contains("not confirmed") }; return false }()
    try test(failed && fm.fileExists(atPath: historical), "cleanup trash: explicitly confirmed native failure is reported with outcome uncertainty")
}

extension InventoryNode {
    func withPath(_ path: String, kind: InventoryNodeKind) -> InventoryNode {
        InventoryNode(id: id, parentID: parentID, identity: identity, path: path, name: (path as NSString).lastPathComponent, kind: kind, logicalBytes: logicalBytes, allocatedBytes: allocatedBytes,
                      previousLogicalBytes: previousLogicalBytes, previousAllocatedBytes: previousAllocatedBytes, objectLogicalBytes: objectLogicalBytes, objectAllocatedBytes: objectAllocatedBytes,
                      directLogicalBytes: directLogicalBytes, directAllocatedBytes: directAllocatedBytes, childCount: childCount, descendantFiles: descendantFiles, descendantDirectories: descendantDirectories,
                      status: status, coverageState: coverageState, listingState: listingState, statusReason: statusReason, measuredAt: measuredAt, modifiedAt: modifiedAt, generation: generation,
                      isHardlinkAlias: isHardlinkAlias, historicalGrowthBytes: historicalGrowthBytes)
    }
}
