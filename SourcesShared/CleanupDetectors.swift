import Foundation

// Artifact detectors. Each recognizes one family of validated layouts and records what it observed as structured
// facts; none decides whether anything may be removed (that is the assessment policy's job). A detector first
// matches the path cheaply (`applies`: names only, at most one lstat), then classifies with bounded evidence.
// Unrecognized or unvalidated structures return nil and stay unclassified.

/// The item being inspected, as indexed.
public struct ArtifactSubject: Sendable {
    public let nodeID: Int64
    /// The path in the inventory (may carry the Data volume prefix).
    public let path: String
    public let kind: InventoryNodeKind
    public let identity: InventoryIdentity?
    public init(nodeID: Int64, path: String, kind: InventoryNodeKind, identity: InventoryIdentity?) { self.nodeID = nodeID; self.path = path; self.kind = kind; self.identity = identity }
}

/// Everything a detector may use. The process table is read at most once per inspection, on first use.
public final class ArtifactContext: @unchecked Sendable {
    public let subject: ArtifactSubject
    public let probe: ArtifactProbe
    public let environment: ArtifactEnvironment
    /// The logical path (no Data volume prefix) and its components.
    public let logical: String
    public let parts: [String]
    public let name: String
    private var cachedProcesses: ProcessObservation?

    public init(subject: ArtifactSubject, probe: ArtifactProbe, environment: ArtifactEnvironment) {
        self.subject = subject; self.probe = probe; self.environment = environment
        logical = ArtifactPaths.logical(subject.path); parts = ArtifactPaths.components(subject.path); name = parts.last ?? "/"
    }

    public var processes: ProcessObservation {
        if let cachedProcesses { return cachedProcesses }
        let observed = environment.processes()
        cachedProcesses = observed
        return observed
    }

    public var isDirectory: Bool { subject.kind == .directory }
    /// Components after the home folder, when the item is inside it.
    public var homeRelative: [String]? {
        guard let relative = ArtifactPaths.canonicalRelativeComponents(subject.path, within: environment.home), !relative.isEmpty else { return nil }
        return relative
    }
    public var parent: String { (subject.path as NSString).deletingLastPathComponent }
    public func child(_ name: String) -> String { (subject.path as NSString).appendingPathComponent(name) }
    public static func join(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }

    /// The index of a component sequence in the path, if present.
    public func index(of sequence: [String]) -> Int? {
        guard sequence.count <= parts.count else { return nil }
        for start in 0...(parts.count - sequence.count) where Array(parts[start..<start + sequence.count]) == sequence { return start }
        return nil
    }

    /// The filesystem path made of the first `count` logical components (keeping the subject's volume prefix).
    public func prefixPath(_ count: Int) -> String {
        let logicalPrefix = "/" + parts.prefix(count).joined(separator: "/")
        return subject.path.hasPrefix(ArtifactPaths.dataVolumePrefix + "/") ? ArtifactPaths.dataVolumePrefix + logicalPrefix : logicalPrefix
    }

    /// A process-table statement that never turns absence into proof.
    public func processObservation(running: Bool, what: String) -> ArtifactObservation {
        let table = processes
        if running { return ArtifactObservation(.process, .supports, "A running process executes \(what).") }
        if table.inspected == 0 { return ArtifactObservation(.process, .neutral, "Running processes could not be inspected.") }
        let caveat = table.unreadable > 0 ? " \(table.unreadable) processes could not be inspected, so this is not proof it is unused." : " This is not proof it is unused."
        return ArtifactObservation(.process, .neutral, "No running process was observed executing \(what).\(caveat)")
    }
}

public protocol ArtifactDetector: Sendable {
    var name: String { get }
    /// Cheap path match (names only; at most one lstat of a marker).
    func applies(to context: ArtifactContext) -> Bool
    /// Bounded classification, or nil when the layout is not validated.
    func classify(_ context: ArtifactContext) -> ArtifactClassification?
}

enum Semver {
    static func isVersion(_ text: String) -> Bool { text.range(of: #"^\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil }
    /// Orders "2.1.310" after "2.1.306" (numeric components).
    static func less(_ a: String, _ b: String) -> Bool {
        let x = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }, y = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for (p, q) in zip(x, y) where p != q { return p < q }
        return x.count < y.count
    }
}

/// `.claude`, `.claude-account-2`, `.codex`, `.codex-account-3`.
enum ToolHome {
    static func isClaude(_ name: String) -> Bool { name.range(of: #"^\.claude(-[A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil }
    static func isCodex(_ name: String) -> Bool { name.range(of: #"^\.codex(-[A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil }
    static func account(_ name: String) -> String {
        guard let dash = name.firstIndex(of: "-") else { return "default account" }
        return "account " + name[name.index(after: dash)...].replacingOccurrences(of: "account-", with: "")
    }
}

// MARK: Claude Code

/// `~/.local/share/claude/versions/<version>`: one executable per installed version. The `claude` command (a
/// symlink or a small launcher script in a PATH folder) selects one of them.
public struct ClaudeCodeDetector: ArtifactDetector {
    public let name = "Claude Code"
    public init() {}
    static let layout = [".local", "share", "claude", "versions"]

    public func applies(to c: ArtifactContext) -> Bool {
        guard let i = c.index(of: Self.layout) else { return false }
        return c.parts.count == i + 4 || c.parts.count == i + 5
    }

    public func classify(_ c: ArtifactContext) -> ArtifactClassification? {
        guard let i = c.index(of: Self.layout) else { return nil }
        let versionsDir = c.prefixPath(i + 4)
        guard let listing = c.probe.list(versionsDir, limit: 128) else { return nil }
        let versions = listing.names.filter { !$0.hasPrefix(".") }
        // The command `claude` on PATH.
        var resolved: String?, resolution = [ArtifactObservation](), unknowns = [String]()
        var resolvedVia: String?
        for directory in c.environment.pathDirectories {
            let candidate = ArtifactContext.join(directory, "claude")
            guard let info = c.probe.info(candidate) else { continue }
            resolvedVia = candidate
            if info.kind == .symlink, let target = c.probe.canonical(candidate) {
                if let relative = ArtifactPaths.canonicalRelativeComponents(target, within: versionsDir) { resolved = relative.first }
                else { resolution.append(ArtifactObservation(.resolution, .neutral, "The claude command resolves outside this versions folder.")) }
            } else if info.kind == .symlink {
                unknowns.append("The claude command's symbolic link could not be resolved.")
            } else if info.kind == .file, info.size <= 4_096, c.probe.isMachO(candidate) == false, let script = c.probe.text(candidate, .launcherScript) {
                // A launcher script: only references to this versions folder are extracted; nothing else is kept.
                let referenced = Set(versions.filter { script.contains("claude/versions/\($0)") })
                if referenced.count == 1 { resolved = referenced.first; resolution.append(ArtifactObservation(.resolution, .supports, "The claude launcher in \((directory as NSString).abbreviatingWithTildeInPath) refers to version \(referenced.first!).")) }
                else if referenced.count > 1 { unknowns.append("The claude launcher refers to more than one version; which one runs could not be determined.") }
                else { unknowns.append("The claude launcher does not name a version directly (it may choose one at run time).") }
            } else if info.kind == .file { unknowns.append("The claude command is a standalone executable outside this versions folder.") }
            break
        }
        if resolvedVia == nil { unknowns.append("No claude command was found on PATH.") }
        let table = c.processes
        let running = Set(table.executables.compactMap { ArtifactPaths.canonicalRelativeComponents($0, within: versionsDir)?.first })
        func roles(_ v: String) -> [ArtifactRelation.Role] {
            var r = [ArtifactRelation.Role]()
            if v == resolved { r.append(.resolved) }
            if running.contains(v) { r.append(.running) }
            return r.isEmpty ? [.historical] : r
        }
        let related = versions.sorted(by: Semver.less).reversed().map { ArtifactRelation(label: "Claude Code \($0)", path: ArtifactContext.join(versionsDir, $0), roles: roles($0)) }

        if c.parts.count == i + 4 {
            // The versions folder itself: it contains the installation in use.
            var facts = ArtifactFacts()
            facts.containsActive = resolved != nil || !running.isEmpty ? true : nil
            var supporting = [ArtifactObservation(.layout, .supports, "Claude Code's native installer keeps one executable per version here (\(versions.count) installed).")]
            if let resolved { supporting.append(ArtifactObservation(.resolution, .supports, "The claude command uses version \(resolved).")) }
            if !running.isEmpty { supporting.append(ArtifactObservation(.process, .supports, "Running: \(running.sorted(by: Semver.less).joined(separator: ", ")).")) }
            return ArtifactClassification(kind: .claudeCodeVersions, tool: .claudeCode, title: "Claude Code versions", characteristics: facts.containsActive == true ? [.active] : [.unknown],
                                          confidence: .confirmed, supporting: supporting + resolution, unknowns: unknowns, related: related, facts: facts,
                                          dependencies: ["The claude command stops working if the version it uses is missing."])
        }

        let version = c.name
        guard let info = c.probe.info(c.subject.path), info.kind == .file else { return nil }
        let named = Semver.isVersion(version)
        let machO = c.probe.isMachO(c.subject.path)
        var supporting = [ArtifactObservation(.layout, .supports, "Located in Claude Code's versions folder.")]
        var contradicting = [ArtifactObservation]()
        if named { supporting.append(ArtifactObservation(.version, .supports, "Version \(version) detected from its file name.")) }
        else { contradicting.append(ArtifactObservation(.version, .contradicts, "The file name is not a version number.")); unknowns.append("Version metadata is missing.") }
        if machO == true { supporting.append(ArtifactObservation(.layout, .supports, "It is a macOS executable (identified from its header; it was not run).")) }
        else if machO == false { contradicting.append(ArtifactObservation(.layout, .contradicts, "It is not a macOS executable.")) }
        var facts = ArtifactFacts()
        facts.isResolved = resolved.map { $0 == version } ?? nil
        facts.isRunning = running.contains(version) ? true : (table.inspected > 0 ? false : nil)
        let others = (resolved.map { [$0] } ?? []) + running.sorted(by: Semver.less)
        facts.otherActiveVersion = others.first { $0 != version }
        if facts.isResolved == true { supporting.append(ArtifactObservation(.resolution, .supports, "The claude command currently resolves to this version.")) }
        else if let resolved { supporting.append(ArtifactObservation(.resolution, .neutral, "Another version is currently resolved (\(resolved)).")) }
        let observation = c.processObservation(running: facts.isRunning == true, what: "this version")
        let active = facts.isResolved == true || facts.isRunning == true
        var characteristics: Set<ArtifactCharacteristic> = [.reinstallable]
        if active { characteristics.insert(.active) } else if facts.otherActiveVersion != nil { characteristics.insert(.historical) }
        let confidence: ArtifactConfidence = named && machO == true && info.isExecutable ? .confirmed : (named && info.isExecutable ? .strong : .tentative)
        return ArtifactClassification(kind: .claudeCodeRelease, tool: .claudeCode, title: named ? "Claude Code \(version)" : "Claude Code installation (version unknown)",
                                      characteristics: characteristics, confidence: confidence, supporting: supporting + resolution + [observation], contradicting: contradicting,
                                      unknowns: unknowns, related: related.filter { $0.path != c.subject.path }, facts: facts,
                                      dependencies: active ? ["The claude command or a running session uses this version."]
                                                           : ["Sessions or scripts that call this version's path directly would stop working.", "Claude Code can download a version again; an exact older version may not stay available."])
    }
}

// MARK: Codex

/// `<codex home>/packages/<channel>/releases/<version>-<platform>` with `bin/`, and `<channel>/current` pointing at
/// the active release. Each account (`.codex`, `.codex-account-N`) has its own releases and current pointer.
public struct CodexDetector: ArtifactDetector {
    public let name = "Codex"
    public init() {}

    /// "0.163.0" from "0.163.0-aarch64-apple-darwin".
    static func version(_ release: String) -> String {
        guard release.range(of: #"-[0-9a-z_]+-apple-darwin$"#, options: .regularExpression) != nil, let dash = release.firstIndex(of: "-") else { return release }
        return String(release[..<dash])
    }

    func layout(_ c: ArtifactContext) -> Int? {
        guard let p = c.parts.firstIndex(where: ToolHome.isCodex), c.parts.count > p + 1, c.parts[p + 1] == "packages" else { return nil }
        return p
    }

    public func applies(to c: ArtifactContext) -> Bool {
        guard let p = layout(c) else { return false }
        // packages/<channel>/releases or one release below it.
        return (c.parts.count == p + 4 && c.parts[p + 3] == "releases") || (c.parts.count == p + 5 && c.parts[p + 3] == "releases")
    }

    public func classify(_ c: ArtifactContext) -> ArtifactClassification? {
        guard let p = layout(c) else { return nil }
        let home = c.parts[p], channel = c.parts[p + 2]
        let channelDir = c.prefixPath(p + 3), releasesDir = c.prefixPath(p + 4)
        let currentLink = ArtifactContext.join(channelDir, "current")
        let current = ArtifactPaths.canonicalRelativeComponents(currentLink, within: releasesDir)?.first
        guard let listing = c.probe.list(releasesDir, limit: 128) else { return nil }
        let releases = listing.names.filter { !$0.hasPrefix(".") }
        var resolved: String?
        for directory in c.environment.pathDirectories {
            let candidate = ArtifactContext.join(directory, "codex")
            guard c.probe.info(candidate) != nil else { continue }
            resolved = ArtifactPaths.canonicalRelativeComponents(candidate, within: releasesDir)?.first
            break
        }
        let table = c.processes
        let running = Set(table.executables.compactMap { ArtifactPaths.canonicalRelativeComponents($0, within: releasesDir)?.first })
        func roles(_ r: String) -> [ArtifactRelation.Role] {
            var result = [ArtifactRelation.Role]()
            if r == current { result.append(.current) }
            if r == resolved { result.append(.resolved) }
            if running.contains(r) { result.append(.running) }
            return result.isEmpty ? [.historical] : result
        }
        let related = releases.sorted(by: Semver.less).reversed().map { ArtifactRelation(label: "Codex \(Self.version($0))", path: ArtifactContext.join(releasesDir, $0), roles: roles($0)) }
        let account = ToolHome.account(home)

        if c.parts.count == p + 4 {
            var facts = ArtifactFacts()
            facts.containsActive = current != nil || resolved != nil || !running.isEmpty ? true : nil
            var supporting = [ArtifactObservation(.layout, .supports, "Codex keeps downloaded \(channel) releases here (\(releases.count), \(account)).")]
            if let current { supporting.append(ArtifactObservation(.resolution, .supports, "The current release is \(Self.version(current)).")) }
            return ArtifactClassification(kind: .codexReleases, tool: .codex, title: "Codex \(channel) releases (\(account))", characteristics: facts.containsActive == true ? [.active] : [.unknown],
                                          confidence: .confirmed, supporting: supporting, related: related, facts: facts,
                                          dependencies: ["Codex for this account stops working if its current release is missing."])
        }

        // A release: validated by its bin folder and package metadata or launcher.
        let release = c.name
        let bin = c.child("bin"), metadata = c.child("codex-package.json")
        guard c.probe.info(bin)?.kind == .directory, c.probe.exists(metadata) || c.probe.exists(c.child("codex")) else { return nil }
        let parsed = release.range(of: #"^(\d+\.\d+\.\d+[0-9A-Za-z.]*)-([0-9a-z_]+-apple-darwin)$"#, options: .regularExpression) != nil
        let version = parsed ? Self.version(release) : release
        var supporting = [ArtifactObservation(.layout, .supports, "Codex \(channel) release layout (\(account)).")]
        var contradicting = [ArtifactObservation](), unknowns = [String]()
        if parsed { supporting.append(ArtifactObservation(.version, .supports, "Version \(version) detected.")) } else { unknowns.append("Version metadata could not be read from the folder name.") }
        if let meta = c.probe.read(metadata, .releaseMetadata), let json = try? JSONSerialization.jsonObject(with: meta) as? [String: Any], let v = json["version"] as? String {
            if parsed && !v.hasPrefix(version) { contradicting.append(ArtifactObservation(.version, .contradicts, "Its package metadata names version \(v).")) }
        }
        let binary = ArtifactContext.join(bin, "codex")
        if let info = c.probe.info(binary) {
            if info.kind == .symlink, let target = c.probe.linkTarget(binary), !ArtifactPaths.isWithin(target, c.subject.path) {
                supporting.append(ArtifactObservation(.layout, .neutral, "Its codex binary is a link to a shared location (\((target as NSString).abbreviatingWithTildeInPath)); the shared binary is not part of this folder."))
            } else if info.kind == .file, c.probe.isMachO(binary) == true { supporting.append(ArtifactObservation(.layout, .supports, "Contains a macOS codex executable (identified from its header; not run).")) }
        } else { contradicting.append(ArtifactObservation(.layout, .contradicts, "No codex executable in bin.")) }
        var facts = ArtifactFacts()
        facts.isCurrent = current.map { $0 == release }
        facts.isResolved = resolved.map { $0 == release }
        facts.isRunning = running.contains(release) ? true : (table.inspected > 0 ? false : nil)
        facts.otherActiveVersion = ([current, resolved].compactMap { $0 } + running.sorted(by: Semver.less)).first { $0 != release }.map(Self.version)
        if facts.isCurrent == true { supporting.append(ArtifactObservation(.resolution, .supports, "This is the current \(channel) release for this account.")) }
        else if let current { supporting.append(ArtifactObservation(.resolution, .neutral, "The current release for this account is \(Self.version(current)).")) }
        else { unknowns.append("This account's current release could not be determined.") }
        if facts.isResolved == true { supporting.append(ArtifactObservation(.resolution, .supports, "The codex command resolves to this release.")) }
        supporting.append(c.processObservation(running: facts.isRunning == true, what: "this release"))
        unknowns.append("Other accounts and tools may start this release by path; only processes running now were observed.")
        let active = facts.isCurrent == true || facts.isResolved == true || facts.isRunning == true
        var characteristics: Set<ArtifactCharacteristic> = [.reinstallable]
        if active { characteristics.insert(.active) } else if facts.otherActiveVersion != nil { characteristics.insert(.historical) }
        return ArtifactClassification(kind: .codexRelease, tool: .codex, title: "Codex \(version) (\(channel), \(account))", characteristics: characteristics,
                                      confidence: contradicting.isEmpty && parsed ? .confirmed : .tentative, supporting: supporting, contradicting: contradicting, unknowns: unknowns,
                                      related: related.filter { $0.path != c.subject.path }, facts: facts,
                                      dependencies: active ? ["Codex for this account uses this release."]
                                                           : ["Anything that starts this release by its path would stop working.", "Codex downloads releases again when needed; an exact older release may not stay available."])
    }
}

// MARK: Node

public struct NodeDetector: ArtifactDetector {
    public let name = "Node"
    public init() {}
    static let outputs = ["dist", "build", ".next", "storybook-static", "out"]
    static let lockfiles = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]

    /// Package manager caches (relative to the home folder).
    static let caches: [(path: [String], tool: ArtifactTool)] = [
        ([".npm", "_cacache"], .npm), ([".npm"], .npm), (["Library", "Caches", "Yarn"], .yarn), ([".yarn", "berry", "cache"], .yarn),
        (["Library", "pnpm", "store"], .pnpm), ([".pnpm-store"], .pnpm), ([".bun", "install", "cache"], .bun), (["Library", "Caches", "pnpm"], .pnpm),
    ]

    func cache(_ c: ArtifactContext) -> ArtifactTool? {
        guard let rest = c.homeRelative else { return nil }
        return Self.caches.first { $0.path == rest }?.tool
    }

    public func applies(to c: ArtifactContext) -> Bool {
        guard c.isDirectory else { return false }
        return c.name == "node_modules" || Self.outputs.contains(c.name) || cache(c) != nil
    }

    func manifest(_ c: ArtifactContext, in directory: String) -> [String: Any]? {
        let path = ArtifactContext.join(directory, "package.json")
        guard let data = c.probe.read(path, .packageManifest) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func dependsOn(_ manifest: [String: Any], _ match: (String) -> Bool) -> Bool {
        for key in ["dependencies", "devDependencies", "peerDependencies"] { if let deps = manifest[key] as? [String: Any], deps.keys.contains(where: match) { return true } }
        return false
    }

    public func classify(_ c: ArtifactContext) -> ArtifactClassification? {
        if let tool = cache(c) {
            var facts = ArtifactFacts(); facts.reproducible = true; facts.generatedEvidence = true
            return ArtifactClassification(kind: .nodePackageCache, tool: tool, title: "\(tool.rawValue) package cache", characteristics: [.generated, .reinstallable], confidence: .strong,
                                          supporting: [ArtifactObservation(.layout, .supports, "\(tool.rawValue) keeps downloaded packages here and refills it when needed.")],
                                          unknowns: ["Whether an install is running right now was not checked against this cache."], facts: facts,
                                          dependencies: ["Installs work offline only from this cache; without it, packages are downloaded again.",
                                                         "Packages installed from it on APFS may share data with it (clones), so removing it can free less than its indexed size."])
        }
        let parent = c.parent
        let nested = c.parts.dropLast().contains("node_modules")
        let project = manifest(c, in: parent)
        let projectName = (project?["name"] as? String) ?? (parent as NSString).lastPathComponent
        var supporting = [ArtifactObservation](), contradicting = [ArtifactObservation](), unknowns = [String]()
        var facts = ArtifactFacts()
        facts.projectFound = project != nil && !nested
        if nested { contradicting.append(ArtifactObservation(.layout, .contradicts, "It is inside another node_modules folder (part of an installed package).")) }
        if project != nil { supporting.append(ArtifactObservation(.manifest, .supports, "package.json found in the enclosing folder (\(projectName)).")) }
        else { contradicting.append(ArtifactObservation(.manifest, .contradicts, "No package.json in the enclosing folder.")) }
        // Exact-name lookups: a large parent (pnpm's .pnpm store) would truncate a listing and hide the lockfile.
        c.probe.readable(parent)
        let lock = Self.lockfiles.first { c.probe.info(ArtifactContext.join(parent, $0)) != nil }
        facts.reproducible = lock != nil
        if let lock { supporting.append(ArtifactObservation(.manifest, .supports, "Lockfile \(lock) pins the dependency versions.")) }
        else if project != nil { unknowns.append("No lockfile: reinstalling may resolve different versions.") }
        let busy = c.processes.works(within: parent)
        facts.referencedByProcess = busy ? true : nil
        if busy { supporting.append(ArtifactObservation(.process, .supports, "A running process is working in this project.")) }
        else { unknowns.append("Whether a development server or editor uses this project could only be checked from running processes' working folders.") }
        let relations = project != nil ? [ArtifactRelation(label: projectName, path: parent, roles: [.project])] : []

        if c.name == "node_modules" {
            // Look the install records up by name: a large folder's truncated listing would miss them.
            c.probe.readable(c.subject.path)
            func inside(_ name: String) -> Bool { c.probe.info(ArtifactContext.join(c.subject.path, name)) != nil }
            let marker = [(".package-lock.json", "npm"), (".modules.yaml", "pnpm"), (".yarn-state.yml", "Yarn"), (".yarn-integrity", "Yarn")].first { inside($0.0) }
            if let marker { supporting.append(ArtifactObservation(.layout, .supports, "Installed by \(marker.1) (its install record is present).")); facts.generatedEvidence = true }
            else if inside(".bin") { supporting.append(ArtifactObservation(.layout, .supports, "Contains installed command links (.bin).")); facts.generatedEvidence = true }
            var characteristics: Set<ArtifactCharacteristic> = [.generated]
            if facts.reproducible == true { characteristics.insert(.reinstallable) }
            if busy { characteristics.insert(.active) }
            return ArtifactClassification(kind: .nodeDependencies, tool: .node, title: nested ? "Nested Node dependencies" : "Node dependencies of \(projectName)", characteristics: characteristics,
                                          confidence: project != nil && !nested && marker != nil ? .confirmed : (project != nil ? .strong : .tentative),
                                          supporting: supporting, contradicting: contradicting, unknowns: unknowns, related: relations, facts: facts,
                                          dependencies: ["The project cannot build or run until dependencies are installed again (network access may be needed).",
                                                         "Running development servers or editors indexing this project may fail."])
        }

        // Build output: requires positive evidence beyond the folder's name.
        guard !nested else { return nil }
        c.probe.readable(c.subject.path)
        func inside(_ name: String) -> Bool { c.probe.info(ArtifactContext.join(c.subject.path, name)) != nil }
        if inside("package.json") || inside(".git") { contradicting.append(ArtifactObservation(.layout, .contradicts, "It contains its own project files (package.json or .git), unlike generated output.")) }
        if let project {
            if c.name == ".next", dependsOn(project, { $0 == "next" }) { facts.generatedEvidence = true; supporting.append(ArtifactObservation(.manifest, .supports, "The project depends on Next.js, which writes .next.")) }
            if c.name == "storybook-static", dependsOn(project, { $0 == "storybook" || $0.hasPrefix("@storybook/") }) { facts.generatedEvidence = true; supporting.append(ArtifactObservation(.manifest, .supports, "The project uses Storybook, which builds storybook-static.")) }
            if let scripts = project["scripts"] as? [String: Any], scripts["build"] != nil { supporting.append(ArtifactObservation(.manifest, .neutral, "The project has a build script (it was not run).")) }
        }
        if let ignore = c.probe.text(ArtifactContext.join(parent, ".gitignore"), .ignoreRules) {
            let lines = Set(ignore.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            if [c.name, "/\(c.name)", "\(c.name)/", "/\(c.name)/"].contains(where: lines.contains) { facts.generatedEvidence = true; supporting.append(ArtifactObservation(.manifest, .supports, "The project's .gitignore excludes \(c.name) (it is not source).")) }
        }
        if facts.generatedEvidence != true { unknowns.append("Nothing establishes that \(c.name) is generated; the name alone is not evidence.") }
        if !contradicting.filter({ $0.topic == .layout }).isEmpty { facts.generatedEvidence = nil }
        var characteristics: Set<ArtifactCharacteristic> = facts.generatedEvidence == true ? [.generated, .reinstallable] : [.unknown]
        if busy { characteristics.insert(.active) }
        let confidence: ArtifactConfidence = project != nil && facts.generatedEvidence == true ? .strong : .tentative
        facts.reproducible = facts.generatedEvidence == true && project != nil ? true : facts.reproducible
        return ArtifactClassification(kind: .nodeBuildOutput, tool: .node, title: "\(c.name) of \(projectName)", characteristics: characteristics, confidence: confidence,
                                      supporting: supporting, contradicting: contradicting, unknowns: unknowns, related: relations, facts: facts,
                                      dependencies: ["Anything serving or deploying these files needs them rebuilt first.", "Rebuilding runs the project's build tooling (not done here)."])
    }
}

// MARK: Python

public struct PythonDetector: ArtifactDetector {
    public let name = "Python"
    public init() {}
    static let caches: [(path: [String], tool: ArtifactTool)] = [
        (["Library", "Caches", "pip"], .pip), ([".cache", "pip"], .pip), ([".cache", "uv"], .uv), (["Library", "Caches", "uv"], .uv),
    ]
    static let manifests = ["pyproject.toml", "setup.py", "setup.cfg", "Pipfile", "requirements.txt"]
    static let locks = ["uv.lock", "poetry.lock", "Pipfile.lock", "pdm.lock", "requirements.txt"]
    /// Folders that hold installed command-line tools' environments.
    static let toolRoots = [[".local", "share", "uv", "tools"], ["Library", "Application Support", "pipx", "venvs"], [".local", "pipx", "venvs"]]

    func cache(_ c: ArtifactContext) -> ArtifactTool? {
        guard let rest = c.homeRelative else { return nil }
        return Self.caches.first { $0.path == rest }?.tool
    }

    public func applies(to c: ArtifactContext) -> Bool {
        if c.subject.kind == .file, c.parts.dropLast().last == "__pycache__" { return true }
        guard c.isDirectory else { return false }
        return c.name == "__pycache__" || cache(c) != nil || c.probe.info(c.child("pyvenv.cfg"))?.kind == .file
    }

    public func classify(_ c: ArtifactContext) -> ArtifactClassification? {
        if let tool = cache(c) {
            var facts = ArtifactFacts(); facts.reproducible = true; facts.generatedEvidence = true
            var dependencies = ["Packages are downloaded again when next needed (network access may be needed)."]
            if tool == .uv { dependencies.append("uv installs packages from this cache by cloning on APFS: environments keep working, and removing the cache can free much less than its indexed size.") }
            return ArtifactClassification(kind: .pythonPackageCache, tool: tool, title: "\(tool.rawValue) cache", characteristics: [.generated, .reinstallable], confidence: .strong,
                                          supporting: [ArtifactObservation(.layout, .supports, "\(tool.rawValue) keeps downloaded and built packages here.")], facts: facts, dependencies: dependencies)
        }
        if c.name == "__pycache__" || c.parts.dropLast().last == "__pycache__" {
            let folder = c.name == "__pycache__" ? c.subject.path : c.parent
            let names = c.probe.list(folder, limit: 256)?.names ?? []
            let onlyBytecode = !names.isEmpty && names.allSatisfy { $0.hasSuffix(".pyc") || $0.hasSuffix(".pyo") }
            var facts = ArtifactFacts(); facts.generatedEvidence = onlyBytecode ? true : nil; facts.reproducible = onlyBytecode ? true : nil; facts.projectFound = true
            var supporting = [ArtifactObservation(.layout, .supports, "Python writes compiled bytecode to __pycache__ folders and recreates them on the next run.")]
            var contradicting = [ArtifactObservation]()
            if onlyBytecode { supporting.append(ArtifactObservation(.layout, .supports, "Contains only compiled bytecode (\(names.count) files listed).")) }
            else { contradicting.append(ArtifactObservation(.layout, .contradicts, names.isEmpty ? "Its contents could not be listed." : "It contains files other than compiled bytecode.")) }
            return ArtifactClassification(kind: .pythonBytecodeCache, tool: .python, title: "Python bytecode cache", characteristics: onlyBytecode ? [.generated, .reinstallable] : [.unknown],
                                          confidence: onlyBytecode ? .confirmed : .tentative, supporting: supporting, contradicting: contradicting, facts: facts,
                                          dependencies: ["The next run of this code is slightly slower while Python recompiles it.", "Read-only installations cannot recreate it."])
        }
        // A virtual environment: pyvenv.cfg is the defining marker.
        guard let config = c.probe.text(c.child("pyvenv.cfg"), .pythonEnvironment) else { return nil }
        var values = [String: String]()
        for line in config.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, ["home", "version", "version_info", "uv"].contains(pair[0]) { values[pair[0]] = pair[1] }
        }
        var supporting = [ArtifactObservation(.layout, .supports, "pyvenv.cfg marks this as a Python virtual environment.")]
        var unknowns = [String](), facts = ArtifactFacts()
        if let version = values["version"] ?? values["version_info"] { supporting.append(ArtifactObservation(.version, .supports, "Python \(version).")) }
        if values["uv"] != nil { supporting.append(ArtifactObservation(.layout, .neutral, "Created by uv.")) }
        let isTool = c.homeRelative.map { rest in Self.toolRoots.contains { root in rest.count == root.count + 1 && Array(rest.prefix(root.count)) == root } } ?? false
        var related = [ArtifactRelation]()
        if isTool {
            // Installed tools are linked from PATH folders.
            var linked = Set<String>()
            for directory in Array(Set(c.environment.pathDirectories)).sorted().prefix(32) {
                for entry in (c.probe.list(directory, limit: 400)?.names ?? []) {
                    let path = ArtifactContext.join(directory, entry)
                    if let target = c.probe.linkTarget(path), ArtifactPaths.canonicalRelativeComponents(target, within: c.subject.path) != nil { linked.insert(entry) }
                }
            }
            facts.linkedFromPath = !linked.isEmpty
            if !linked.isEmpty { supporting.append(ArtifactObservation(.resolution, .supports, "Installed command\(linked.count == 1 ? "" : "s") on PATH: \(linked.sorted().prefix(6).joined(separator: ", ")).")) }
            else { unknowns.append("No command on PATH links into this tool environment.") }
        } else {
            let parent = c.parent
            c.probe.readable(parent)
            let manifest = Self.manifests.first { c.probe.info(ArtifactContext.join(parent, $0)) != nil }
            let lock = Self.locks.first { c.probe.info(ArtifactContext.join(parent, $0)) != nil }
            facts.projectFound = manifest != nil
            facts.reproducible = lock != nil
            if let manifest { supporting.append(ArtifactObservation(.manifest, .supports, "Its folder has a Python project (\(manifest))."));
                related.append(ArtifactRelation(label: (parent as NSString).lastPathComponent, path: parent, roles: [.project])) }
            else { unknowns.append("No Python project manifest next to it: how it was built cannot be reproduced from evidence.") }
            if let lock { supporting.append(ArtifactObservation(.manifest, .supports, "\(lock) records the installed packages.")) }
            let busy = c.processes.works(within: parent)
            facts.referencedByProcess = busy ? true : nil
            if busy { supporting.append(ArtifactObservation(.process, .supports, "A running process is working in this project.")) }
        }
        unknowns.append("A Python process using an environment appears as the base interpreter, so use of this environment cannot be observed.")
        var characteristics: Set<ArtifactCharacteristic> = [.generated]
        if facts.reproducible == true { characteristics.insert(.reinstallable) }
        if facts.linkedFromPath == true || facts.referencedByProcess == true { characteristics.insert(.active) }
        return ArtifactClassification(kind: .pythonVirtualEnvironment, tool: values["uv"] != nil ? .uv : .python,
                                      title: isTool ? "Python tool environment \(c.name)" : "Python virtual environment in \((c.parent as NSString).lastPathComponent)",
                                      characteristics: characteristics, confidence: .confirmed, supporting: supporting, unknowns: unknowns, related: related, facts: facts,
                                      dependencies: isTool ? ["The commands installed from this environment stop working until the tool is reinstalled."]
                                                           : ["Scripts, editors and notebooks configured to use this interpreter stop working until it is recreated.",
                                                              "Packages installed by hand (not recorded in a lockfile) would be lost."])
    }
}

// MARK: Git worktrees

/// A linked worktree: a `.git` file pointing to `<repository>/.git/worktrees/<id>`, whose `gitdir` file points back.
public struct GitWorktreeDetector: ArtifactDetector {
    public let name = "Git worktree"
    public init() {}

    public func applies(to c: ArtifactContext) -> Bool { c.isDirectory && c.probe.info(c.child(".git"))?.kind == .file }

    public func classify(_ c: ArtifactContext) -> ArtifactClassification? {
        guard let pointer = c.probe.text(c.child(".git"), .gitPointer), let line = pointer.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = ((c.subject.path as NSString).appendingPathComponent(gitdir) as NSString).standardizingPath }
        // Submodules also use .git files (pointing into .git/modules): only worktrees are recognized.
        guard gitdir.contains("/worktrees/") else { return nil }
        var supporting = [ArtifactObservation(.layout, .supports, "Its .git file links it to a repository's worktree registry.")]
        var contradicting = [ArtifactObservation](), unknowns = [String](), facts = ArtifactFacts()
        let registered = c.probe.info(gitdir)?.kind == .directory
        var repository: String?
        if registered {
            let back = c.probe.text(ArtifactContext.join(gitdir, "gitdir"), .gitPointer)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let pointsBack = back.map { pointer in
                let target = pointer.hasPrefix("/") ? pointer : (gitdir as NSString).appendingPathComponent(pointer)
                return ArtifactPaths.canonicalRelativeComponents(target, within: c.child(".git")) == []
            } ?? false
            facts.worktreeRegistered = pointsBack
            if pointsBack { supporting.append(ArtifactObservation(.git, .supports, "The repository lists this folder as one of its worktrees.")) }
            else { contradicting.append(ArtifactObservation(.git, .contradicts, "The repository's registry entry points to a different folder.")) }
            if let common = c.probe.text(ArtifactContext.join(gitdir, "commondir"), .gitPointer)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                let commonDir = common.hasPrefix("/") ? common : ((gitdir as NSString).appendingPathComponent(common) as NSString).standardizingPath
                repository = (commonDir as NSString).lastPathComponent == ".git" ? (commonDir as NSString).deletingLastPathComponent : commonDir
            }
            facts.worktreeLocked = c.probe.exists(ArtifactContext.join(gitdir, "locked"))
            if facts.worktreeLocked == true { supporting.append(ArtifactObservation(.git, .supports, "The worktree is locked (git worktree lock), which asks Git to keep it.")) }
        } else {
            facts.worktreeRegistered = false
            contradicting.append(ArtifactObservation(.git, .contradicts, "The repository no longer has a registry entry for it (Git may report it as prunable)."))
        }
        if let git = c.environment.git, registered {
            let state = git.inspect(worktree: c.subject.path)
            if let error = state.error { unknowns.append("\(error): uncommitted and unmerged work could not be checked.") }
            facts.uncommittedChanges = state.uncommitted; facts.untrackedFiles = state.untracked; facts.unpushedCommits = state.unpushed
            if let branch = state.branch { supporting.append(ArtifactObservation(.git, .neutral, "Branch \(branch).")) }
            if state.detached { supporting.append(ArtifactObservation(.git, .neutral, "Detached HEAD (no branch).")) }
            if let n = state.uncommitted { supporting.append(ArtifactObservation(.git, n > 0 ? .supports : .neutral, n > 0 ? "\(n) uncommitted change\(n == 1 ? "" : "s")." : "No uncommitted changes.")) }
            if let n = state.untracked { supporting.append(ArtifactObservation(.git, n > 0 ? .supports : .neutral, n > 0 ? "\(n) untracked file\(n == 1 ? "" : "s") or folder\(n == 1 ? "" : "s")." : "No untracked files.")) }
            if let n = state.unpushed { supporting.append(ArtifactObservation(.git, n > 0 ? .supports : .neutral, n > 0 ? "\(n >= 1000 ? "1000+" : "\(n)") commit\(n == 1 ? "" : "s") not contained in any other branch or remote." : "Every commit is contained in another branch or a remote.")) }
            else { unknowns.append("Whether its commits exist elsewhere could not be determined.") }
        } else if registered { unknowns.append("Git is not available: uncommitted and unmerged work could not be checked.") }
        let busy = c.processes.works(within: c.subject.path)
        facts.referencedByProcess = busy ? true : nil
        if busy { supporting.append(ArtifactObservation(.reference, .supports, "A running process is working in this worktree.")) }
        else { unknowns.append("Editors or agents that open files here without working in this folder are not observed.") }
        let hasWork = (facts.uncommittedChanges ?? 0) > 0 || (facts.untrackedFiles ?? 0) > 0 || (facts.unpushedCommits ?? 0) > 0
        var characteristics: Set<ArtifactCharacteristic> = []
        if busy || hasWork || facts.worktreeLocked == true { characteristics.insert(.active) }
        if characteristics.isEmpty { characteristics.insert(.unknown) }
        let related = repository.map { [ArtifactRelation(label: ($0 as NSString).lastPathComponent, path: $0, roles: [.repository])] } ?? []
        return ArtifactClassification(kind: .gitWorktree, tool: .git, title: "Worktree \(c.name)\(repository.map { " of \(($0 as NSString).lastPathComponent)" } ?? "")",
                                      characteristics: characteristics, confidence: facts.worktreeRegistered == true ? .confirmed : .tentative,
                                      supporting: supporting, contradicting: contradicting, unknowns: unknowns, related: related, facts: facts,
                                      dependencies: ["Uncommitted, untracked and unmerged work exists only here.", "Removing the folder without `git worktree remove` leaves a stale registry entry; its branch stays in the repository."])
    }
}

// MARK: Agent sessions and state

/// Claude Code (`<home>/projects/<project>/<session>.jsonl`) and Codex (`<home>/sessions/YYYY/MM/DD/rollout-*.jsonl[.zst]`,
/// `<home>/archived_sessions/…`) session histories, and the tools' state databases. Only names, structure and
/// timestamps are used; conversation content is never read.
public struct AgentSessionDetector: ArtifactDetector {
    public let name = "Agent sessions"
    public init() {}
    /// Writes this recent may belong to a session that is still going.
    public static let recentWindow: TimeInterval = 15 * 60

    enum Match { case claudeProjects(home: Int), codexSessions(home: Int, archived: Bool), database(home: Int, tool: ArtifactTool) }

    func match(_ c: ArtifactContext) -> Match? {
        if let h = c.parts.firstIndex(where: ToolHome.isClaude), c.parts.count > h + 1, c.parts[h + 1] == "projects", c.parts.count <= h + 4 {
            if c.parts.count == h + 4 && !(c.name.hasSuffix(".jsonl")) { return nil }
            return .claudeProjects(home: h)
        }
        if let h = c.parts.firstIndex(where: ToolHome.isCodex), c.parts.count > h + 1 {
            let area = c.parts[h + 1]
            if area == "sessions" || area == "archived_sessions" {
                if c.subject.kind == .file && !c.name.hasPrefix("rollout-") { return nil }
                return .codexSessions(home: h, archived: area == "archived_sessions")
            }
            if c.parts.count == h + 2, c.subject.kind == .file, c.name.hasSuffix(".sqlite") || c.name.hasSuffix(".sqlite-wal") || c.name.hasSuffix(".sqlite-shm") { return .database(home: h, tool: .codex) }
        }
        return nil
    }

    public func applies(to c: ArtifactContext) -> Bool { match(c) != nil }

    public func classify(_ c: ArtifactContext) -> ArtifactClassification? {
        guard let match = match(c) else { return nil }
        let table = c.processes
        let now = c.environment.now()
        var facts = ArtifactFacts()
        if case .database(let h, let tool) = match {
            facts.isDatabase = true
            let open = table.holdsOpen(within: c.subject.path)
            facts.openByProcess = open ? true : nil
            let walPresent = c.probe.exists(c.subject.path.hasSuffix(".sqlite") ? c.subject.path + "-wal" : c.subject.path)
            var supporting = [ArtifactObservation(.layout, .supports, "A \(tool.rawValue) state database in its data folder (\(ToolHome.account(c.parts[h]))).")]
            if open { supporting.append(ArtifactObservation(.process, .supports, "A running \(tool.rawValue) process has it open.")) }
            if walPresent { supporting.append(ArtifactObservation(.layout, .supports, "Its write-ahead log is present (the database is in use or was not closed cleanly).")) }
            return ArtifactClassification(kind: .agentDatabase, tool: tool, title: "\(tool.rawValue) database \(c.name)", characteristics: [.active], confidence: .strong, supporting: supporting,
                                          unknowns: ["Its contents were not read."], facts: facts,
                                          dependencies: ["\(tool.rawValue) keeps live state here (threads, history, settings); removing or editing it while \(tool.rawValue) runs can corrupt it."])
        }
        let tool: ArtifactTool, home: Int, archived: Bool
        switch match {
        case .claudeProjects(let h): tool = .claudeCode; home = h; archived = false
        case .codexSessions(let h, let a): tool = .codex; home = h; archived = a
        case .database: return nil
        }
        // Names and timestamps only (bounded).
        var files = 0, newest: Date?, complete = true
        if c.isDirectory {
            var queue = [c.subject.path], depth = 0
            while !queue.isEmpty && depth < 4 {
                var next = [String]()
                for folder in queue {
                    guard let listing = c.probe.list(folder, limit: 1_000) else { complete = false; continue }
                    complete = complete && listing.complete
                    for entry in listing.names {
                        let path = ArtifactContext.join(folder, entry)
                        guard let info = c.probe.info(path) else { continue }
                        if info.kind == .directory { next.append(path) }
                        else if entry.hasSuffix(".jsonl") || entry.hasSuffix(".jsonl.zst") { files += 1; newest = max(newest ?? info.modified, info.modified) }
                    }
                }
                queue = next; depth += 1
            }
            if !queue.isEmpty { complete = false }
        } else if let info = c.probe.info(c.subject.path) { files = 1; newest = info.modified }
        let open = table.holdsOpen(within: c.subject.path)
        facts.openByProcess = open ? true : (table.inspected > 0 ? false : nil)
        facts.recentlyModified = newest.map { now.timeIntervalSince($0) < Self.recentWindow }
        var supporting = [ArtifactObservation(.layout, .supports, tool == .claudeCode ? "Claude Code stores each conversation as a session record in its projects folder." : (archived ? "Codex moves sessions here when they are archived." : "Codex stores each session as a dated rollout record."))]
        supporting.append(ArtifactObservation(.layout, .neutral, "\(files) session record\(files == 1 ? "" : "s")\(complete ? "" : " counted so far (listing incomplete)") · \(ToolHome.account(c.parts[home])); contents were not read."))
        if let newest { supporting.append(ArtifactObservation(.freshness, facts.recentlyModified == true ? .supports : .neutral, "Last written \(newest.formatted(date: .abbreviated, time: .shortened)).")) }
        if open { supporting.append(ArtifactObservation(.process, .supports, "A running \(tool.rawValue) process has a session file here open.")) }
        else if table.inspected > 0 { supporting.append(ArtifactObservation(.process, .neutral, "No running \(tool.rawValue) process was observed holding these files open. This is not proof none will resume them.")) }
        var unknowns = ["Whether you will want to resume or search these conversations later cannot be known from metadata."]
        if !complete { unknowns.append("Not every record was listed within the inspection budget.") }
        var characteristics: Set<ArtifactCharacteristic> = []
        if open || facts.recentlyModified == true { characteristics.insert(.active) } else { characteristics.insert(.historical) }
        let single = !c.isDirectory
        return ArtifactClassification(kind: single ? .agentSessionRecord : .agentSessionHistory, tool: tool,
                                      title: single ? "\(tool.rawValue) session record" : (archived ? "Archived \(tool.rawValue) sessions" : "\(tool.rawValue) session history"),
                                      characteristics: characteristics, confidence: .strong, supporting: supporting, unknowns: unknowns, facts: facts,
                                      dependencies: ["These conversations could no longer be resumed or searched in \(tool.rawValue).",
                                                     "\(tool.rawValue) may keep an index that still lists them."])
    }
}

// MARK: Protected scopes

/// Credentials, system-managed locations, tool settings folders and Storage Monitor's own data.
public enum ArtifactProtection {
    static let credentialNames: Set<String> = ["auth.json", "credentials.json", ".credentials.json", "credentials", ".netrc", ".npmrc", ".pypirc", ".env", ".git-credentials", "id_rsa", "id_ed25519", "id_ecdsa", "known_hosts", ".claude.json"]
    static let protectedHomeFolders: [[String]] = [[".ssh"], [".gnupg"], [".aws"], [".kube"], ["Library", "Keychains"], [".config", "gh"], [".docker"]]
    static let systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/private/var/vm", "/private/var/folders", "/Library/Apple", "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100", "/.vol", "/dev", "/cores"]

    /// Why a path is protected, or nil.
    public static func reason(_ c: ArtifactContext) -> String? { reason(c, baseInterpreterLink: false) }

    // Only the qualified Trash descendant-link role may retain a shared base interpreter.
    static func reason(_ c: ArtifactContext, baseInterpreterLink: Bool) -> String? {
        let logical = c.logical
        if logical == "/" { return "The startup volume itself." }
        let canonical = c.probe.canonical(c.subject.path).map(ArtifactPaths.logical)
        if !(baseInterpreterLink && canonical == "/usr/bin/python3") && systemPrefixes.contains(where: { prefix in
            let direct = ArtifactPaths.isWithin(logical, prefix) && !(prefix == "/usr" && ArtifactPaths.isWithin(logical, "/usr/local"))
            let resolved = canonical.map { ArtifactPaths.isWithin($0, prefix) && !(prefix == "/usr" && ArtifactPaths.isWithin($0, "/usr/local")) } ?? false
            return direct || resolved
        }) { return "Managed by macOS." }
        if let own = c.environment.ownData,
           ArtifactPaths.isWithin(c.subject.path, own) || ArtifactPaths.canonicalRelativeComponents(c.subject.path, within: own) != nil {
            return "Storage Monitor's own data (inventory and history)."
        }
        let name = c.name
        if credentialNames.contains(name) || name.hasPrefix(".env.") || name.hasSuffix(".pem") || name.hasSuffix(".key") || name.hasSuffix(".p12") || name.hasSuffix(".keychain-db") || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") {
            return "May contain credentials; it was not read."
        }
        if let rest = c.homeRelative {
            if protectedHomeFolders.contains(where: { rest.count >= $0.count && Array(rest.prefix($0.count)) == $0 }) { return "Holds keys, credentials or keychains." }
            // A tool's data folder itself, and its settings files.
            if rest.count == 1, ToolHome.isClaude(rest[0]) || ToolHome.isCodex(rest[0]) { return "Claude Code or Codex settings, credentials and history live in this folder." }
            if rest.count == 2, ToolHome.isClaude(rest[0]) || ToolHome.isCodex(rest[0]), ["settings.json", "settings.local.json", "config.toml", "hooks.json", "installation_id"].contains(rest[1]) || rest[1].hasPrefix("config.toml.bak") || rest[1].hasPrefix("settings.json.bak") {
                return "Tool settings; it was not read."
            }
        }
        // A selected symlink may have an innocuous display name while resolving into a
        // credential or another protected scope. Evaluate the resolved location too.
        if let canonical, canonical != logical {
            let resolved = ArtifactContext(subject: .init(nodeID: c.subject.nodeID, path: canonical, kind: c.subject.kind, identity: c.subject.identity),
                                           probe: c.probe, environment: c.environment)
            return reason(resolved, baseInterpreterLink: baseInterpreterLink)
        }
        return nil
    }
}
