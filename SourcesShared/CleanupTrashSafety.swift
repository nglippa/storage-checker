import Foundation
import Darwin

/// The sheet receives this validated target, rather than a mutable selection. It expires and can be used once.
public final class CleanupTrashConfirmationToken: @unchecked Sendable {
    public let node: InventoryNode
    public let inspection: ArtifactInspection
    public let decision: CleanupTrashDecision
    public let preparedAt: Date
    fileprivate let snapshot: CleanupTrashSnapshot
    fileprivate let qaRuntime: NativeQARuntime?
    private let lock = NSLock()
    private var consumed = false
    fileprivate init(node: InventoryNode, inspection: ArtifactInspection, decision: CleanupTrashDecision, snapshot: CleanupTrashSnapshot, preparedAt: Date, qaRuntime: NativeQARuntime?) {
        self.node = node; self.inspection = inspection; self.decision = decision; self.snapshot = snapshot; self.preparedAt = preparedAt; self.qaRuntime = qaRuntime
    }
    fileprivate func consume() -> Bool { lock.lock(); defer { lock.unlock() }; guard !consumed else { return false }; consumed = true; return true }
}

public enum CleanupTrashPreparation: Sendable {
    case ready(CleanupTrashConfirmationToken)
    case blocked(String)
}

fileprivate struct CleanupTrashSnapshot: Equatable {
    var canonical: String
    var entries: [String: String]
    var ancestors: [String: String]
    var assessment: String
    var activeUseLimited: Bool
}

fileprivate struct CleanupTrashSafetyFailure: Error { let reason: String }

public extension CleanupTrashPolicy {
    // Serializes distinct confirmed requests across Inspector instances without waiting or automatic retry.
    private static let executionLock = NSLock()

    static func prepare(node: InventoryNode, environment: ArtifactEnvironment, budget: ArtifactProbe.Budget = .standard) -> CleanupTrashPreparation {
        do {
            var environment = environment
            environment.qaRuntime = try NativeQARuntime.effectiveScope(environment.qaRuntime)
            let (inspection, snapshot) = try validate(node: node, environment: environment, budget: budget)
            var decision = decide(node: node, inspection: inspection, examined: true, home: environment.home)
            if case .blocked(let reason) = decision { return .blocked(reason) }
            if snapshot.activeUseLimited, case .allowed(_, let warnings) = decision {
                decision = .allowed(override: true, warnings: warnings + ["Current-user active-use observations were partial. No active reference was observed in that scope; this is not proof of non-use. Required protection, descendant, Git and executable/database checks must still pass."])
            }
            return .ready(CleanupTrashConfirmationToken(node: node, inspection: inspection, decision: decision, snapshot: snapshot, preparedAt: environment.now(), qaRuntime: environment.qaRuntime))
        } catch let failure as CleanupTrashSafetyFailure { return .blocked(failure.reason) }
        catch { return .blocked("Protection could not be reliably assessed: \(error.localizedDescription)") }
    }

    /// Executes one explicit user confirmation after revalidation. This is a layered preflight, not an
    /// atomic expected-object guarantee: a pathname replacement can still occur before FileManager resolves it.
    static func perform(confirmation: CleanupTrashConfirmationToken, overrideAccepted: Bool, environment: ArtifactEnvironment,
                        trash: ((URL) throws -> URL?)? = nil) -> CleanupTrashOutcome {
        guard confirmation.consume() else { return .refused("This confirmation has already been used or cancelled.") }
        guard executionLock.try() else { return .refused("Another Move to Trash is in progress. Review this item again after it finishes.") }
        defer { executionLock.unlock() }
        let age = Date().timeIntervalSince(confirmation.preparedAt)
        guard age >= 0, age <= 60 else { return .refused("The confirmation expired. Review the item again.") }
        guard case .allowed(let needsWarning, _) = confirmation.decision else { return .refused("The prepared item is blocked from Move to Trash.") }
        if needsWarning && !overrideAccepted { return .refused("The warning was not accepted.") }
        do {
            var environment = environment
            let effective = try NativeQARuntime.effectiveScope(environment.qaRuntime)
            if let effective, let prepared = confirmation.qaRuntime, !effective.sameProfile(as: prepared) { return .refused("The QA profile changed after confirmation.") }
            environment.qaRuntime = effective ?? confirmation.qaRuntime
            if environment.qaRuntime != nil && confirmation.qaRuntime == nil { return .refused("A QA session requires a QA-bound confirmation.") }
            try confirmation.qaRuntime?.validateTrash(confirmation.node.path)
            let (_, current) = try validate(node: confirmation.node, environment: environment, budget: .standard)
            guard current == confirmation.snapshot else { return .refused("The target or relevant evidence changed after confirmation was prepared. Review it again.") }
            guard !Task.isCancelled else { return .refused("Move to Trash was cancelled before the system operation.") }
            guard Date().timeIntervalSince(confirmation.preparedAt) <= 60 else { return .refused("The confirmation expired during preflight. Review the item again.") }
            try confirmation.qaRuntime?.validateTrash(current.canonical)
            let source = URL(fileURLWithPath: current.canonical)
            // No rename/staging/permanent-delete fallback. Only this validated token path reaches FileManager.
            let destination: URL?
            do { if let trash { destination = try trash(source) } else { destination = try fileManagerTrash(source) } }
            catch {
                return .failed("macOS Trash reported: \(error.localizedDescription). Its final filesystem outcome is not confirmed. Check the original location before trying again.")
            }
            guard let destination, destination.isFileURL else {
                return .failed("The Trash operation returned no usable destination. Its outcome is unverified; check the original location and Trash before trying again.")
            }
            var moved = stat()
            guard lstat(destination.path, &moved) == 0 else {
                return .failed("The returned Trash item could not be examined at \(destination.path). The operation may have moved it; do not retry automatically.")
            }
            let expected = confirmation.node.identity
            let birth = Int64(moved.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(moved.st_birthtimespec.tv_nsec)
            guard Int64(moved.st_dev) == expected.device, UInt64(moved.st_ino) == expected.inode,
                  expected.birthNanoseconds == 0 || birth == expected.birthNanoseconds else {
                return .failed("The returned Trash item has a different filesystem identity at \(destination.path). The outcome is uncertain. Inspect the original location and this destination; do not retry automatically.")
            }
            var original = stat()
            guard lstat(current.canonical, &original) != 0, errno == ENOENT || errno == ENOTDIR else {
                return .failed("A filesystem item is still present or cannot be checked at the selected path after Trash returned \(destination.path). The outcome is uncertain; review both locations before trying again.")
            }
            return .moved(trashPath: destination.path)
        } catch let failure as CleanupTrashSafetyFailure { return .refused(failure.reason) }
        catch { return .refused("Preflight could not complete: \(error.localizedDescription)") }
    }

    private static func fileManagerTrash(_ url: URL) throws -> URL? {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }

    static func cancel(_ confirmation: CleanupTrashConfirmationToken) { _ = confirmation.consume() }

    private static func validate(node: InventoryNode, environment: ArtifactEnvironment, budget: ArtifactProbe.Budget) throws -> (ArtifactInspection, CleanupTrashSnapshot) {
        func reject(_ reason: String) throws -> Never { throw CleanupTrashSafetyFailure(reason: reason) }
        try environment.qaRuntime?.validateTrash(node.path)
        let probe = ArtifactProbe(budget: budget)
        if (node.path as NSString).lastPathComponent.lowercased() == ".git" { try reject("Git metadata cannot be moved independently of its worktree; review the worktree itself.") }
        let subject = ArtifactSubject(nodeID: node.id, path: node.path, kind: node.kind, identity: node.identity)
        switch ArtifactInspector.identity(of: subject, probe: probe) {
        case .verified: break
        case .changed: try reject("The path now refers to a different item; nothing was moved.")
        case .missing: try reject("Nothing is at this path any more.")
        case .unavailable(let reason): try reject(reason)
        }
        guard let rootInfo = probe.info(node.path), rootInfo.ownerIsCurrentUser else { try reject("The item's ownership could not be verified as yours.") }
        let parent = (node.path as NSString).deletingLastPathComponent
        guard access(parent, W_OK | X_OK) == 0 else { try reject("The enclosing folder does not permit moving this item.") }
        guard let parentCanonical = probe.canonical(parent) else { try reject("The enclosing folder could not be resolved.") }
        let lexicalParent = (parent as NSString).standardizingPath
        // /tmp and /var are Apple's stable aliases. Other symlinked ancestors require selecting the canonical item.
        let expectedParent = lexicalParent == "/tmp" || lexicalParent.hasPrefix("/tmp/") ? "/private" + lexicalParent : (lexicalParent == "/var" || lexicalParent.hasPrefix("/var/") ? "/private" + lexicalParent : lexicalParent)
        guard ArtifactPaths.logical(parentCanonical) == ArtifactPaths.logical(expectedParent) else { try reject("An enclosing folder is a symbolic link. Review the canonical target in Navigator.") }
        let canonical = (parentCanonical as NSString).appendingPathComponent((node.path as NSString).lastPathComponent)
        if ArtifactPaths.components(canonical).contains(where: { $0.precomposedStringWithCanonicalMapping.lowercased() == ".git" }) {
            try reject("Git metadata and its descendants cannot be moved independently of their worktree.")
        }
        let processes = (environment.safetyProcesses ?? environment.processes)()
        // Ordinary items retain scoped partial-observation warnings; a completely unavailable provider cannot authorize any item.
        guard processes.inspected > 0 else { try reject("Active-use observations are unavailable; nothing was moved.") }
        guard Date().timeIntervalSince(processes.takenAt) < 5 else { try reject("Active-use observations are stale; review the item again.") }
        var refreshedEnvironment = environment
        refreshedEnvironment.processes = { processes }
        let inspection = ArtifactInspector.inspect(node, environment: refreshedEnvironment, budget: budget)
        if case .blocked(let why) = decide(node: node, inspection: inspection, examined: true, home: environment.home) { try reject(why) }
        if let why = hardBlock(inspection.classification?.facts) { try reject(why) }
        var ancestors = [String: String](), ancestor = parentCanonical
        for _ in 0..<256 {
            ancestors[ancestor] = try stamp(ancestor, identityOnly: true)
            if try gitMetadataDirectory(ancestor, probe: probe) { try reject("The selected item is inside a Git metadata store.") }
            if ancestor == "/" { break }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        guard ancestors["/"] != nil else { try reject("The target's ancestor chain exceeds the safety budget.") }
        // A target containing any protected root is prohibited, including a custom data directory.
        let protectedRoots = [environment.home, (environment.home as NSString).appendingPathComponent("Library/Application Support/MacBook Storage Monitor")] + (environment.ownData.map { [$0] } ?? [])
        for root in protectedRoots {
            guard let resolved = ArtifactPaths.canonicalProtectionLocation(root) else {
                try reject("A protected location could not be resolved; its boundary cannot be excluded.")
            }
            if ArtifactPaths.isWithin(resolved, canonical) { try reject("This folder contains a protected home or Storage Monitor data root.") }
        }
        var protectedObjects = Set<String>()
        let fixedHome = broadHomeFolders.union([".ssh", ".gnupg", ".aws", ".kube", ".git-credentials", ".docker", ".codex", ".claude", "Library/Keychains", ".config/gh", ".codex/auth.json", ".aws/credentials", ".ssh/id_rsa", ".ssh/id_ed25519"])
        for path in protectedRoots + Array(broadAbsolute) + fixedHome.map({ (environment.home as NSString).appendingPathComponent($0) }) {
            if let info = probe.info(path) { protectedObjects.insert("\(info.device):\(info.inode)") }
        }
        var activeObjects = Set<String>()
        for path in processes.executables + processes.openFiles {
            guard !probe.timedOut else { try reject("Active-use inspection exceeded the safety time budget.") }
            if let info = probe.info(path) { activeObjects.insert("\(info.device):\(info.inode)") }
        }
        var pathReferences: Set<String>?
        var entries = [String: String](), pending = [canonical], checked = 0
        var visitedObjects = Set<String>(), databasePaths = Set<String>()
        var requiresCompleteProcesses = inspection.classification?.facts.isDatabase == true
        var gitRoots = [String]()
        while let path = pending.popLast() {
            if Task.isCancelled { try reject("Trash validation was cancelled.") }
            guard !probe.timedOut, checked < max(1, budget.entries) else { try reject("The directory cannot be assessed within the safety budget. Nothing will be moved.") }
            checked += 1
            guard let info = probe.info(path) else { try reject("A descendant could not be examined; protection is incomplete.") }
            guard info.device == rootInfo.device else { try reject("The item contains a mount point on another filesystem.") }
            guard info.ownerIsCurrentUser else { try reject("A descendant is not owned by the current user.") }
            if protectedObjects.contains("\(info.device):\(info.inode)") { try reject("The target or a descendant is the same filesystem object as a protected root or credential store.") }
            entries[path] = try stamp(path)
            visitedObjects.insert("\(info.device):\(info.inode)")
            let kind: InventoryNodeKind = info.kind == .directory ? .directory : (info.kind == .symlink ? .symlink : .file)
            let context = ArtifactContext(subject: .init(nodeID: node.id, path: path, kind: kind, identity: nil), probe: probe, environment: refreshedEnvironment)
            if let why = ArtifactProtection.reason(context) ?? normalizedProtection(path, environment: refreshedEnvironment, probe: probe) { try reject("Protected: \(why) (\(path))") }
            // A plain parent can contain a recognized current installation that is neither running nor on
            // PATH. Reuse the same bounded probe and fixed process observation for descendant facts.
            // Inspect every applicable safety fact, including overlapping layouts at the selected root.
            for detector in ArtifactInspector.detectors where detector.applies(to: context) {
                let beforeIncomplete = probe.incomplete.count
                let classification = detector.classify(context)
                if probe.timedOut || probe.incomplete.count > beforeIncomplete {
                    try reject("Required descendant evidence could not be completed within the safety budget.")
                }
                if let classification, let why = hardBlock(classification.facts) {
                    try reject("The target or a descendant has a verified dependency: \(why) (\(path))")
                }
            }
            if processes.runs(within: path) || processes.holdsOpen(within: path) || processes.works(within: path) { try reject("A running process uses the target or a descendant: \(path)") }
            // Also compare objects: a hard-link alias of an executing file is still an active executable.
            if activeObjects.contains("\(info.device):\(info.inode)") { try reject("This object is an active executable or open file, including through another hard link.") }
            if info.isExecutable && !processes.complete { try reject("Active executable use could not be completely assessed.") }
            if info.isExecutable { requiresCompleteProcesses = true }
            if info.isExecutable {
                if pathReferences == nil {
                    var references = Set<String>()
                    for folder in environment.pathDirectories where probe.info(folder)?.kind == .directory {
                        guard let listing = probe.list(folder, limit: max(1, budget.entries)), listing.complete else { try reject("Current executable references on PATH cannot be completely assessed within the safety budget.") }
                        for name in listing.names {
                            guard !probe.timedOut else { try reject("Current executable reference checks exceeded the safety time budget.") }
                            let entry = (folder as NSString).appendingPathComponent(name)
                            if let destination = probe.canonical(entry), let reference = probe.info(destination), reference.isExecutable { references.insert("\(reference.device):\(reference.inode)") }
                        }
                    }
                    pathReferences = references
                }
                if pathReferences?.contains("\(info.device):\(info.inode)") == true { try reject("A command on the current PATH resolves to this executable, including through a link.") }
                for folder in environment.pathDirectories {
                    if let resolved = probe.canonical(folder), ArtifactPaths.isWithin(path, resolved), (path as NSString).deletingLastPathComponent == resolved {
                        try reject("This executable is directly available through a current PATH directory.")
                    }
                }
            }
            // A selected SQLite sidecar is an active dependency when its base or another
            // companion is observed open. Apply the same required completeness in both directions.
            let databaseSuffix = ["-wal", "-shm", "-journal"].first(where: { path.hasSuffix($0) })
            let databaseBase = databaseSuffix.map { String(path.dropLast($0.count)) } ?? path
            let databaseName = ["sqlite", "sqlite3", "db"].contains((databaseBase as NSString).pathExtension.lowercased())
            if databaseName {
                requiresCompleteProcesses = true
                guard let location = ArtifactPaths.canonicalProtectionLocation(databaseBase) else { try reject("The database path could not be resolved for active-use checks.") }
                databasePaths.insert(location)
                for active in processes.openFiles {
                    guard let observed = ArtifactPaths.canonicalProtectionLocation(active) else { try reject("An open-file path could not be resolved for database safety.") }
                    if observed == location || ["-wal", "-shm", "-journal"].contains(where: { observed == location + $0 }) {
                        try reject("The database or one of its companions is open by a running process.")
                    }
                }
                if !processes.complete { try reject("Active database use could not be completely assessed.") }
            }
            if info.kind == .other { try reject("Special filesystem objects cannot be assessed for Trash.") }
            if info.kind == .symlink {
                guard let resolved = probe.canonical(path) else { try reject("The symbolic link target cannot be reliably assessed.") }
                if ArtifactPaths.components(resolved).contains(where: { $0.precomposedStringWithCanonicalMapping.lowercased() == ".git" }) { try reject("The symbolic link refers into protected Git metadata.") }
                var metadataAncestor = resolved
                for _ in 0..<256 {
                    if try gitMetadataDirectory(metadataAncestor, probe: probe) { try reject("The symbolic link refers into a Git metadata store.") }
                    if metadataAncestor == "/" { break }
                    metadataAncestor = (metadataAncestor as NSString).deletingLastPathComponent
                }
                let linkContext = ArtifactContext(subject: .init(nodeID: node.id, path: resolved, kind: .file, identity: nil), probe: probe, environment: refreshedEnvironment)
                if let why = ArtifactProtection.reason(linkContext) ?? normalizedProtection(resolved, environment: refreshedEnvironment, probe: probe) { try reject("Protected symbolic-link target: \(why)") }
                if let referent = probe.info(resolved) { visitedObjects.insert("\(referent.device):\(referent.inode)") }
                if processes.runs(within: resolved) || processes.holdsOpen(within: resolved) { try reject("The symbolic link refers to an item in active use.") }
                continue // Trash the link itself, never enumerate or move its referent.
            }
            if info.kind == .directory {
                guard access(path, R_OK | X_OK) == 0, let listed = probe.list(path, limit: max(1, budget.entries)), listed.complete else { try reject("A directory listing is incomplete; protected descendants cannot be excluded.") }
                if try gitMetadataDirectory(path, probe: probe) {
                    let parent = (path as NSString).deletingLastPathComponent
                    let assessedWorktreeMetadata = (path as NSString).lastPathComponent == ".git" && gitRoots.contains(parent)
                    if !assessedWorktreeMetadata { try reject("The target contains a bare or separate Git metadata store, whose dependencies cannot be safely assessed: \(path)") }
                }
                if listed.names.contains(".git") { gitRoots.append(path) }
                for name in listed.names.sorted().reversed() { pending.append((path as NSString).appendingPathComponent(name)) }
            }
        }
        for gitRoot in gitRoots {
            guard !probe.timedOut, let availableGit = environment.git else { try reject("Git state is required but cannot be assessed within the safety budget.") }
            let pointerPath = (gitRoot as NSString).appendingPathComponent(".git")
            if probe.info(pointerPath)?.kind == .symlink { try reject("A Git metadata pointer is a symbolic link; its protection boundary cannot be established.") }
            if probe.info(pointerPath)?.kind == .file {
                guard let pointer = probe.text(pointerPath, .gitPointer), let line = pointer.split(separator: "\n").first, line.hasPrefix("gitdir:") else { try reject("A Git metadata pointer could not be verified.") }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let joined = raw.hasPrefix("/") ? raw : (gitRoot as NSString).appendingPathComponent(raw)
                guard let registered = probe.canonical(joined) else { try reject("The linked Git metadata directory could not be resolved.") }
                let lockPath = (registered as NSString).appendingPathComponent("locked")
                if probe.info(lockPath) != nil { try reject("A descendant Git worktree is locked: \(gitRoot)") }
                if probe.lastError != ENOENT { try reject("The linked Git worktree lock state could not be assessed.") }
            }
            let git = GitInspector(executable: availableGit.executable, timeout: min(availableGit.timeout, max(0.01, budget.seconds / 4)))
            let state = git.inspect(worktree: gitRoot)
            guard let dirty = state.uncommitted, let untracked = state.untracked, let unmerged = state.unpushed, state.error == nil else { try reject("Git state could not be reliably assessed.") }
            if dirty > 0 || untracked > 0 || unmerged > 0 { try reject("A Git worktree contains uncommitted, untracked, or potentially unmerged work: \(gitRoot)") }
            guard let common = git.run(["rev-parse", "--git-common-dir"], in: gitRoot), common.status == 0 else { try reject("The Git repository preservation boundary could not be established.") }
            let rawCommon = common.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let commonPath = rawCommon.hasPrefix("/") ? rawCommon : (gitRoot as NSString).appendingPathComponent(rawCommon)
            guard let canonicalCommon = probe.canonical(commonPath) else { try reject("The common Git repository location could not be resolved.") }
            if ArtifactPaths.isWithin(canonicalCommon, canonical) {
                let registry = (canonicalCommon as NSString).appendingPathComponent("worktrees")
                if let info = probe.info(registry) {
                    guard info.kind == .directory, let registered = probe.list(registry, limit: 1), registered.complete, registered.names.isEmpty else {
                        try reject("This common Git repository has registered worktree dependencies. Moving it could orphan external worktrees, including locked or modified work.")
                    }
                } else if probe.lastError != ENOENT { try reject("The linked-worktree dependency registry could not be reliably assessed.") }
                // All local branches/tags disappear with this repository. A sibling local branch is not an
                // independent copy; require every local commit to be covered by observed remote-tracking refs.
                guard let coverage = git.run(["rev-list", "--count", "--max-count=1", "--all", "--not", "--remotes"], in: gitRoot), coverage.status == 0,
                      let count = Int(coverage.output.trimmingCharacters(in: .whitespacesAndNewlines)), count == 0 else {
                    try reject("Removing this repository would include local commits not established as merged into observed remote references. Local branches in the same target do not preserve that work.")
                }
            }
            guard let stash = git.run(["stash", "list", "--format=%H"], in: gitRoot), stash.status == 0 else { try reject("Git stash state could not be assessed.") }
            if !stash.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try reject("A related Git repository contains stashed work.") }
            if probe.timedOut { try reject("Git state exceeded the overall safety time budget.") }
        }
        // Process state has its own clock. Re-observe after traversal and Git, before final filesystem stamps.
        let latestProcesses = (environment.safetyProcesses ?? environment.processes)()
        guard latestProcesses.inspected > 0 else { try reject("The final active-use observation is unavailable; nothing was moved.") }
        guard Date().timeIntervalSince(latestProcesses.takenAt) < 5 else { try reject("The final active-use observation is stale.") }
        if requiresCompleteProcesses && !latestProcesses.complete { try reject("The final required active-use check is incomplete.") }
        if latestProcesses.runs(within: canonical) || latestProcesses.holdsOpen(within: canonical) || latestProcesses.works(within: canonical) { try reject("A process started using the target during validation.") }
        for active in latestProcesses.executables + latestProcesses.openFiles {
            if let info = probe.info(active), visitedObjects.contains("\(info.device):\(info.inode)") { try reject("A target object became active during validation, including through an alias.") }
            if !databasePaths.isEmpty {
                guard let observed = ArtifactPaths.canonicalProtectionLocation(active) else { try reject("An active path could not be resolved for database safety.") }
                if databasePaths.contains(where: { location in observed == location || ["-wal", "-shm", "-journal"].contains(where: { observed == location + $0 }) }) {
                    try reject("A database companion became active during validation.")
                }
            }
        }
        var finalEnvironment = environment
        finalEnvironment.processes = { latestProcesses }
        let finalInspection = ArtifactInspector.inspect(node, environment: finalEnvironment, budget: budget)
        if let reason = hardBlock(finalInspection.classification?.facts) { try reject(reason) }
        if finalInspection.classification?.facts != inspection.classification?.facts || finalInspection.identity != .verified {
            try reject("Relevant classification or active-reference evidence changed during final validation.")
        }
        // Re-read every visited object after process/Git/protection checks. This includes directory ctime/mtime,
        // so inserting a new child during inspection invalidates the result.
        for (path, before) in entries { guard try stamp(path) == before else { try reject("The target changed during validation. Review it again.") } }
        for (path, before) in ancestors { guard try stamp(path, identityOnly: true) == before else { try reject("An enclosing folder changed identity during validation.") } }
        let f = inspection.classification?.facts
        let signature = "\(inspection.classification?.kind.rawValue ?? "ordinary")|\(inspection.assessment?.status.rawValue ?? "unknown")|\(String(describing: f))"
        return (inspection, CleanupTrashSnapshot(canonical: canonical, entries: entries, ancestors: ancestors, assessment: signature,
                                                   activeUseLimited: !processes.complete || !latestProcesses.complete))
    }

    private static func stamp(_ path: String, identityOnly: Bool = false) throws -> String {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw CleanupTrashSafetyFailure(reason: "The target or an enclosing folder disappeared or became unreadable.") }
        // UF_DATALESS (0x40000000) must never cause file-provider materialization during safety inspection.
        guard identityOnly || st.st_flags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE) | 0x00080000 | 0x40000000) == 0 else { throw CleanupTrashSafetyFailure(reason: "The item is immutable, restricted, or not locally materialized.") }
        let identity = "\(st.st_dev):\(st.st_ino):\(st.st_birthtimespec.tv_sec):\(st.st_birthtimespec.tv_nsec):\(st.st_mode):\(st.st_uid)"
        if identityOnly { return identity }
        return identity + ":\(st.st_size):\(st.st_nlink):\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec):\(st.st_ctimespec.tv_nsec)"
    }

    /// A bounded positive signature for bare and separate metadata stores, independent of the directory name.
    /// Incomplete access after finding the signature fails closed; no recursive Git-object walk is needed.
    private static func gitMetadataDirectory(_ directory: String, probe: ArtifactProbe) throws -> Bool {
        let head = (directory as NSString).appendingPathComponent("HEAD")
        guard let headInfo = probe.info(head) else {
            if probe.lastError == ENOENT || probe.lastError == ENOTDIR { return false }
            throw CleanupTrashSafetyFailure(reason: "Potential Git metadata could not be assessed.")
        }
        guard headInfo.kind == .file else { return false }
        for name in ["objects", "refs"] {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let info = probe.info(path) else {
                if probe.lastError == ENOENT || probe.lastError == ENOTDIR { return false }
                throw CleanupTrashSafetyFailure(reason: "Potential Git metadata could not be assessed.")
            }
            guard info.kind == .directory else { return false }
        }
        _ = try stamp(head)
        guard let text = probe.text(head, .gitPointer)?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw CleanupTrashSafetyFailure(reason: "The Git metadata HEAD could not be verified within the safety budget.") }
        return text.hasPrefix("ref: refs/") || text.range(of: "^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$", options: .regularExpression) != nil
    }

    private static func normalizedProtection(_ path: String, environment: ArtifactEnvironment, probe: ArtifactProbe) -> String? {
        var normalized = environment
        normalized.home = environment.home.precomposedStringWithCanonicalMapping.lowercased()
        normalized.ownData = environment.ownData?.precomposedStringWithCanonicalMapping.lowercased()
        let p = path.precomposedStringWithCanonicalMapping.lowercased()
        let own = (normalized.home as NSString).appendingPathComponent("library/application support/macbook storage monitor")
        if ArtifactPaths.isWithin(p, own) { return "Storage Monitor's application data." }
        if ArtifactPaths.isWithin(p, (normalized.home as NSString).appendingPathComponent(".trash")) { return "The user's Trash." }
        return ArtifactProtection.reason(ArtifactContext(subject: .init(nodeID: 0, path: p, kind: .file, identity: nil), probe: probe, environment: normalized))
    }
}
