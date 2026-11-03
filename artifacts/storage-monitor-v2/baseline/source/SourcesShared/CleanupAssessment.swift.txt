import Foundation

// The cleanup assessment policy and the inspection that ties identity, protection, detection, assessment and storage
// together. The policy reads only structured facts and the identity state; it never sees file names, sizes or ages,
// so "old", "large" or "not running" cannot by themselves make anything a review candidate.

public enum CleanupPolicy {
    /// For an item whose identity could not be verified: no earlier evidence or recommendation applies.
    public static func identityAssessment(_ identity: ArtifactIdentityState) -> CleanupAssessment? {
        switch identity {
        case .missing:
            return CleanupAssessment(status: .insufficientEvidence, summary: "This item is no longer at this path.",
                                     reasons: ["The inventory still lists it, but nothing exists at the path now; the inventory will catch up at its next update."], risks: [])
        case .changed:
            return CleanupAssessment(status: .insufficientEvidence, summary: "The path now refers to a different item than the one indexed.",
                                     reasons: ["Its filesystem identity changed since it was measured; earlier evidence does not apply."], risks: [])
        case .unavailable(let why):
            return CleanupAssessment(status: .insufficientEvidence, summary: "The item could not be examined.", reasons: [why], risks: [])
        case .verified: return nil
        }
    }

    public static func assess(_ classification: ArtifactClassification, identity: ArtifactIdentityState) -> CleanupAssessment {
        if classification.kind != .protectedLocation, let voided = identityAssessment(identity) { return voided }
        switch identity {
        case .missing:
            return CleanupAssessment(status: .insufficientEvidence, summary: "This item is no longer at this path.",
                                     reasons: ["The inventory still lists it, but nothing exists at the path now; the inventory will catch up at its next update."], risks: [])
        case .changed:
            return CleanupAssessment(status: .insufficientEvidence, summary: "The path now refers to a different item than the one indexed.",
                                     reasons: ["Its filesystem identity changed since it was measured; earlier evidence does not apply."], risks: [])
        case .unavailable(let why):
            return CleanupAssessment(status: .insufficientEvidence, summary: "The item could not be examined.", reasons: [why], risks: [])
        case .verified: break
        }
        let f = classification.facts
        let risks = classification.dependencies
        if f.protectedScope || classification.kind == .protectedLocation {
            return CleanupAssessment(status: .protected, summary: "Excluded from cleanup review.", reasons: classification.supporting.map(\.text), risks: [])
        }
        // Positive evidence of current use always wins.
        var preserve = [String]()
        if f.isResolved == true { preserve.append("It is the version the command currently resolves to.") }
        if f.isCurrent == true { preserve.append("It is the tool's current release.") }
        if f.isRunning == true { preserve.append("A running process executes it.") }
        if f.containsActive == true { preserve.append("It contains the installation in use.") }
        if f.openByProcess == true { preserve.append("A running process has files in it open.") }
        if f.referencedByProcess == true { preserve.append("A running process is working in it or its project.") }
        if f.linkedFromPath == true { preserve.append("Commands on PATH are installed from it.") }
        if f.isDatabase { preserve.append("It is a live application database.") }
        if f.worktreeLocked == true { preserve.append("The worktree is locked.") }
        if let n = f.uncommittedChanges, n > 0 { preserve.append("It has uncommitted changes.") }
        if let n = f.untrackedFiles, n > 0 { preserve.append("It has untracked files.") }
        if let n = f.unpushedCommits, n > 0 { preserve.append("It has commits not contained in any other branch or remote.") }
        if f.recentlyModified == true && [.agentSessionHistory, .agentSessionRecord].contains(classification.kind) { preserve.append("It was written in the last few minutes (a session may still be active).") }
        if !preserve.isEmpty {
            return CleanupAssessment(status: .preserve, summary: "Evidence shows it is in use or holds work that exists only here.", reasons: preserve, risks: risks)
        }
        // Everything else needs established facts, not absence of evidence.
        var missing = [String]()
        if classification.confidence < .strong { missing.append("The classification is \(classification.confidence.title.lowercased()).") }
        switch classification.kind {
        case .claudeCodeRelease, .codexRelease:
            if f.otherActiveVersion == nil { missing.append("No other version is established as active, so this one may be the one in use.") }
            if f.isRunning == nil { missing.append("Running processes could not be inspected.") }
        case .claudeCodeVersions, .codexReleases:
            missing.append("This folder holds the tool's installations; individual versions are reviewed one by one.")
        case .nodeDependencies:
            if f.projectFound != true { missing.append("No project manifest establishes how these dependencies are installed.") }
            if f.reproducible != true { missing.append("Without a lockfile, reinstalling may not reproduce them.") }
        case .nodeBuildOutput:
            if f.projectFound != true { missing.append("No project establishes how this output is built.") }
            if f.generatedEvidence != true { missing.append("Nothing establishes that it is generated; its name alone is not evidence.") }
        case .pythonVirtualEnvironment:
            if f.linkedFromPath == false { missing.append("It looks like an installed tool's environment, but no command links to it; it may be in use another way.") }
            if f.projectFound != true && f.linkedFromPath == nil { missing.append("No project establishes how this environment was built.") }
            if f.reproducible != true && f.linkedFromPath == nil { missing.append("Nothing records its installed packages.") }
        case .pythonBytecodeCache:
            if f.generatedEvidence != true { missing.append("It contains files other than compiled bytecode.") }
        case .gitWorktree:
            if f.worktreeRegistered != true { missing.append("The repository's registry entry does not confirm this worktree.") }
            if f.uncommittedChanges == nil || f.untrackedFiles == nil { missing.append("Its uncommitted and untracked work could not be checked.") }
            if f.unpushedCommits == nil { missing.append("Whether its commits exist elsewhere could not be checked.") }
        case .agentSessionHistory, .agentSessionRecord:
            if f.openByProcess == nil { missing.append("Running processes could not be inspected.") }
            if f.recentlyModified == nil { missing.append("Its timestamps could not be read.") }
        case .nodePackageCache, .pythonPackageCache:
            break
        case .agentDatabase, .protectedLocation:
            break
        }
        if !missing.isEmpty {
            return CleanupAssessment(status: .insufficientEvidence, summary: "The evidence does not establish what removing it would affect.", reasons: missing, risks: risks)
        }
        var reasons = [String]()
        switch classification.kind {
        case .claudeCodeRelease, .codexRelease:
            reasons.append("Another version (\(f.otherActiveVersion!)) is the one in use; this one is not the current or resolved version.")
            reasons.append("No running process was observed executing it, which does not prove nothing will.")
        case .nodeDependencies: reasons.append("The project's lockfile allows reinstalling the same versions.")
        case .nodeBuildOutput: reasons.append("It is generated output of a project that can rebuild it.")
        case .pythonVirtualEnvironment: reasons.append("Its project records the packages needed to recreate it.")
        case .pythonBytecodeCache: reasons.append("Python recreates bytecode automatically.")
        case .gitWorktree: reasons.append("No uncommitted changes, no untracked files, and every commit exists in another branch or remote.")
        case .agentSessionHistory, .agentSessionRecord: reasons.append("No running process was observed using these records and none were written recently.")
        case .nodePackageCache, .pythonPackageCache: reasons.append("The package manager refills its cache when needed.")
        default: break
        }
        return CleanupAssessment(status: .reviewCandidate, summary: "It may not be needed. This is not a recommendation to delete it: review the evidence and risks first.", reasons: reasons, risks: risks)
    }
}

/// Runs one inspection: identity, protection, detection, assessment, storage. Bounded by the probe's budget.
public enum ArtifactInspector {
    public static let detectors: [ArtifactDetector] = [ClaudeCodeDetector(), CodexDetector(), AgentSessionDetector(), GitWorktreeDetector(), PythonDetector(), NodeDetector()]

    /// Whether any detector or protection could apply: names only, plus at most two lstat calls for folders.
    /// Ordinary items stop here, so navigation never pays for a full inspection.
    public static func mightApply(_ subject: ArtifactSubject, environment: ArtifactEnvironment, probe: ArtifactProbe = ArtifactProbe()) -> Bool {
        let context = ArtifactContext(subject: subject, probe: probe, environment: environment)
        return ArtifactProtection.reason(context) != nil || detectors.contains { $0.applies(to: context) }
    }

    /// Whether the path still names the object the inventory indexed (device, inode and creation time).
    public static func identity(of subject: ArtifactSubject, probe: ArtifactProbe) -> ArtifactIdentityState {
        guard let info = probe.info(subject.path) else {
            return probe.lastError == ENOENT || probe.lastError == ENOTDIR ? .missing : .unavailable("Its metadata could not be read.")
        }
        guard let indexed = subject.identity else { return .unavailable("No indexed filesystem identity is available.") }
        if info.device != indexed.device || UInt64(info.inode) != indexed.inode || (indexed.birthNanoseconds != 0 && info.birthNanoseconds != indexed.birthNanoseconds) { return .changed }
        return .verified
    }

    /// - Parameter probe: supply one to audit what the inspection read (tests); otherwise one is made with `budget`.
    public static func inspect(_ node: InventoryNode, environment: ArtifactEnvironment, budget: ArtifactProbe.Budget = .standard, probe: ArtifactProbe? = nil) -> ArtifactInspection {
        let started = Date()
        let subject = ArtifactSubject(nodeID: node.id, path: node.path, kind: node.kind, identity: node.identity)
        let probe = probe ?? ArtifactProbe(budget: budget)
        let context = ArtifactContext(subject: subject, probe: probe, environment: environment)
        let identity = identity(of: subject, probe: probe)
        let canonicalUnavailable = identity == .verified && probe.canonical(subject.path) == nil
        if canonicalUnavailable { probe.note("The filesystem path could not be resolved; cleanup evidence is incomplete.") }
        var classification: ArtifactClassification?
        if let why = ArtifactProtection.reason(context) {
            var facts = ArtifactFacts(); facts.protectedScope = true
            classification = ArtifactClassification(kind: .protectedLocation, tool: context.logical.hasPrefix("/Users/") ? .user : .macOS, title: context.name,
                                                    characteristics: [.unknown], confidence: .confirmed, supporting: [ArtifactObservation(.scope, .supports, why)], facts: facts)
        } else if !canonicalUnavailable && (identity == .verified || identity == .changed) {
            for detector in detectors where detector.applies(to: context) {
                if let found = detector.classify(context) { classification = found; break }
            }
        }
        // A vanished or unreadable item keeps no recommendation, and says why.
        let assessment = classification.map { CleanupPolicy.assess($0, identity: identity) }
            ?? (canonicalUnavailable ? CleanupAssessment(status: .insufficientEvidence, summary: "The item could not be resolved safely.",
                                                      reasons: ["Its canonical filesystem path is unavailable; an alias or symbolic link may change the protection boundary."], risks: [])
                : CleanupPolicy.identityAssessment(identity))
        let storage = Self.storage(node, classification: classification, assessment: assessment, identity: identity, probe: probe)
        return ArtifactInspection(nodeID: node.id, path: node.path, collectedAt: environment.now(), elapsed: Date().timeIntervalSince(started), identity: identity,
                                  classification: classification, assessment: assessment, storage: storage, incomplete: probe.incomplete)
    }

    /// The storage quantities. A recovery estimate is offered only for a single file whose data is not shared
    /// (one link, APFS private size), with a current measurement; folders get one from the preview's bounded walk.
    static func storage(_ node: InventoryNode, classification: ArtifactClassification?, assessment: CleanupAssessment?, identity: ArtifactIdentityState, probe: ArtifactProbe) -> ArtifactStorage {
        let coverage = InventoryNodePresentation.coverage(node)
        let complete = node.status == .complete
        var recovery = ArtifactStorage.Recovery.unknown("Recovery amount unknown.")
        if identity != .verified { recovery = .unknown("Recovery amount unknown: the item at this path is not the one measured.") }
        else if assessment?.status == .protected { recovery = .unknown("Not estimated for protected items.") }
        else if node.isHardlinkAlias { recovery = .unknown("Recovery amount unknown: this is another name for a file stored elsewhere (a hard link).") }
        else if node.kind == .file, assessment != nil, let info = probe.info(node.path), info.kind == .file {
            if info.links > 1 { recovery = .unknown("Recovery amount unknown: the file has \(info.links) hard links, so its data stays while another name exists.") }
            else if let privateBytes = probe.privateSize(node.path) {
                recovery = .estimated(privateBytes, basis: privateBytes < (node.allocatedBytes ?? 0)
                                      ? "APFS reports only this much is not shared with clones; local snapshots may still keep it."
                                      : "APFS reports it shares no data with clones; local snapshots may still keep it.")
            }
        } else if node.kind == .directory { recovery = .unknown("Recovery amount unknown until its contents are examined in the cleanup preview.") }
        return ArtifactStorage(logicalBytes: node.objectLogicalBytes ?? node.logicalBytes ?? node.previousLogicalBytes, indexedAllocatedBytes: InventoryMapPlan.weight(node),
                               measuredAt: node.measuredAt, measurement: coverage, measurementComplete: complete, recovery: recovery)
    }
}

// MARK: Recovery estimate and preview

/// A bounded walk over a folder's metadata: APFS private sizes of files with a single link. Symlinks are not followed;
/// hard-linked files are counted as shared. Stops at the entry or time limit (then no estimate is defensible).
public struct ArtifactRecoveryEstimate: Equatable, Sendable {
    public let privateBytes: Int64
    public let files: Int
    public let sharedFiles: Int
    public let hardLinkedFiles: Int
    public let unreadable: Int
    public let complete: Bool

    public static func measure(_ root: String, probe: ArtifactProbe, limit: Int = 20_000) -> ArtifactRecoveryEstimate {
        var total: Int64 = 0, files = 0, shared = 0, linked = 0, unreadable = 0, visited = 0, complete = true
        var stack = [root]
        while let folder = stack.popLast() {
            guard !probe.timedOut else { complete = false; break }
            guard let listing = probe.list(folder, limit: limit) else { unreadable += 1; continue }
            if !listing.complete { complete = false }
            for name in listing.names {
                visited += 1
                if visited > limit { complete = false; break }
                let path = (folder as NSString).appendingPathComponent(name)
                guard let info = probe.info(path) else { unreadable += 1; continue }
                switch info.kind {
                case .directory: stack.append(path)
                case .file:
                    files += 1
                    if info.links > 1 { linked += 1; continue }
                    guard let privateBytes = probe.privateSize(path) else { unreadable += 1; continue }
                    if privateBytes == 0 && info.size > 0 { shared += 1 }
                    total += privateBytes
                default: break
                }
            }
            if visited > limit { break }
        }
        if !stack.isEmpty { complete = false }
        return ArtifactRecoveryEstimate(privateBytes: total, files: files, sharedFiles: shared, hardLinkedFiles: linked, unreadable: unreadable, complete: complete && unreadable == 0)
    }
}

/// What a future cleanup would affect. Informational only: nothing here performs, schedules or enables removal.
public struct CleanupPreview: Equatable, Sendable {
    public struct Entry: Equatable, Sendable { public let name: String; public let bytes: Int64?; public let isFolder: Bool }
    public let target: String
    public let identity: String
    public let tool: String
    public let classification: String
    public let indexedBytes: Int64?
    public let measurement: String
    /// The largest entries from the inventory, and whether that list is everything.
    public let contents: [Entry]
    public let contentsComplete: Bool
    public let contentsTotal: Int64?
    public let preserved: [ArtifactRelation]
    public let references: [String]
    public let risks: [String]
    public let unknowns: [String]
    public let recovery: ArtifactStorage.Recovery
    public let recoveryDetail: String?
    public let limitations: [String]
    public let evidenceCollected: Date

    public init(inspection: ArtifactInspection, node: InventoryNode, children: [InventoryNode], childrenComplete: Bool, estimate: ArtifactRecoveryEstimate?) {
        let c = inspection.classification
        target = node.path
        identity = "Volume \(node.identity.volumeUUID ?? "device \(node.identity.device)") · file ID \(node.identity.inode)"
        tool = c?.tool.rawValue ?? "—"
        classification = c.map { "\($0.kind.title) · \($0.confidence.title)" } ?? "Not recognized"
        indexedBytes = InventoryMapPlan.weight(node)
        measurement = InventoryNodePresentation.coverage(node)
        contents = children.map { Entry(name: $0.name, bytes: InventoryMapPlan.weight($0), isFolder: $0.kind == .directory) }
        contentsComplete = childrenComplete
        contentsTotal = node.kind == .directory ? node.childCount : nil
        preserved = c?.related.filter(\.mustPreserve) ?? []
        var references = [String]()
        if let c {
            references += c.related.filter { [.project, .repository].contains(where: $0.roles.contains) }.map { "\($0.roles.first!.rawValue): \($0.label) (\($0.path))" }
            references += c.supporting.filter { $0.topic == .process || $0.topic == .reference || $0.topic == .resolution }.map(\.text)
        }
        self.references = references
        risks = (c?.dependencies ?? []) + (inspection.assessment?.risks.filter { !(c?.dependencies ?? []).contains($0) } ?? [])
        unknowns = (c?.unknowns ?? []) + inspection.incomplete
        if let estimate {
            if estimate.complete {
                recovery = .estimated(estimate.privateBytes, basis: "APFS private sizes of \(estimate.files.formatted()) files (data not shared with clones); local snapshots may still keep it.")
                var detail = [String]()
                if estimate.sharedFiles > 0 { detail.append("\(estimate.sharedFiles.formatted()) files share all their data with clones") }
                if estimate.hardLinkedFiles > 0 { detail.append("\(estimate.hardLinkedFiles.formatted()) hard-linked files are excluded") }
                recoveryDetail = detail.isEmpty ? nil : detail.joined(separator: "; ") + "."
            } else {
                recovery = .unknown("Recovery amount unknown: the folder has more entries than the preview examines\(estimate.unreadable > 0 ? ", or some could not be read" : "").")
                recoveryDetail = "Examined \(estimate.files.formatted()) files before stopping."
            }
        } else {
            recovery = inspection.storage.recovery
            recoveryDetail = nil
        }
        limitations = ArtifactStorage.limitations + (inspection.storage.measurementComplete ? [] : ["The indexed size is not a complete current measurement (\(measurement.lowercased()))."])
        evidenceCollected = inspection.collectedAt
    }
}
