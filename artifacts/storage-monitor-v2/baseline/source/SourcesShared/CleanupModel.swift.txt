import Foundation

// Cleanup Inspector model: what an item appears to be (classification), what was observed about it (evidence), and a
// conservative review status (assessment). The three are produced by separate components: detectors classify and
// record facts, the probe collects bounded read-only evidence, and the assessment policy reads only the facts.
// Nothing here deletes, moves or modifies anything; a review candidate is never a deletion authorization.

// MARK: Classification

public enum ArtifactKind: String, Sendable, CaseIterable {
    case claudeCodeRelease, claudeCodeVersions
    case codexRelease, codexReleases
    case nodeDependencies, nodeBuildOutput, nodePackageCache
    case pythonVirtualEnvironment, pythonBytecodeCache, pythonPackageCache
    case gitWorktree
    case agentSessionHistory, agentSessionRecord, agentDatabase
    case protectedLocation

    public var title: String {
        switch self {
        case .claudeCodeRelease: return "Claude Code release"
        case .claudeCodeVersions: return "Claude Code installed versions"
        case .codexRelease: return "Codex downloaded release"
        case .codexReleases: return "Codex releases"
        case .nodeDependencies: return "Node dependencies"
        case .nodeBuildOutput: return "Generated build output"
        case .nodePackageCache: return "Package manager cache"
        case .pythonVirtualEnvironment: return "Python virtual environment"
        case .pythonBytecodeCache: return "Python bytecode cache"
        case .pythonPackageCache: return "Python package cache"
        case .gitWorktree: return "Git linked worktree"
        case .agentSessionHistory: return "Agent session history"
        case .agentSessionRecord: return "Agent session record"
        case .agentDatabase: return "Agent state database"
        case .protectedLocation: return "Protected location"
        }
    }
}

public enum ArtifactTool: String, Sendable {
    case claudeCode = "Claude Code", codex = "Codex", node = "Node.js", npm, pnpm = "pnpm", yarn = "Yarn", bun = "Bun"
    case python = "Python", pip = "pip", uv = "uv", git = "Git", macOS = "macOS", storageMonitor = "Storage Monitor", user = "Your account"
}

/// Characteristics are not exclusive: generated output can also be in active use.
public enum ArtifactCharacteristic: String, Sendable, CaseIterable, Comparable {
    case active, historical, generated, reinstallable, unknown
    public var title: String { rawValue.capitalized }
    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// Structured confidence in the classification (never a percentage).
public enum ArtifactConfidence: Int, Sendable, Comparable, CaseIterable {
    case unknown, tentative, strong, confirmed
    public var title: String {
        switch self {
        case .unknown: return "Unknown"
        case .tentative: return "Tentative"
        case .strong: return "Strong evidence"
        case .confirmed: return "Confirmed"
        }
    }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One observation. `stance` is relative to the classification it belongs to.
public struct ArtifactObservation: Hashable, Sendable {
    public enum Stance: String, Sendable { case supports, contradicts, neutral }
    public enum Topic: String, Sendable { case identity, layout, version, resolution, process, manifest, git, freshness, scope, access, accounting, reference }
    public let topic: Topic
    public let stance: Stance
    public let text: String
    public init(_ topic: Topic, _ stance: Stance, _ text: String) { self.topic = topic; self.stance = stance; self.text = text }
}

/// Another item that matters for this one (other installed versions, the active release, the project it belongs to).
public struct ArtifactRelation: Hashable, Sendable {
    public enum Role: String, Sendable { case active = "Active", resolved = "Resolved on PATH", running = "Running", current = "Current", historical = "Historical", project = "Project", repository = "Repository", unknown = "Unknown" }
    public let label: String
    public let path: String
    public let roles: [Role]
    public init(label: String, path: String, roles: [Role]) { self.label = label; self.path = path; self.roles = roles }
    /// Must be kept whatever happens to the inspected item.
    public var mustPreserve: Bool { roles.contains { [.active, .resolved, .running, .current].contains($0) } }
}

/// Structured facts the assessment policy reads. Nil means "not established" (never "no").
public struct ArtifactFacts: Equatable, Sendable {
    /// The executable a command name resolves to on PATH (or the target of the tool's launcher).
    public var isResolved: Bool?
    /// A running process executes from this item (nil: could not tell).
    public var isRunning: Bool?
    /// The tool's own "current" pointer refers to this release.
    public var isCurrent: Bool?
    /// Another version of the same tool is established as active (resolved, current or running).
    public var otherActiveVersion: String?
    /// The item contains the active installation (a versions or releases folder).
    public var containsActive: Bool?
    /// A process's working directory is inside the item or its project.
    public var referencedByProcess: Bool?
    /// A process holds a file open inside the item.
    public var openByProcess: Bool?
    /// The owning project (manifest) was found next to the item.
    public var projectFound: Bool?
    /// A lockfile or pinned requirements allow reproducing the item.
    public var reproducible: Bool?
    /// Positive evidence the item is generated (ignored by Git, framework marker, bytecode only).
    public var generatedEvidence: Bool?
    /// Git working-tree state.
    public var uncommittedChanges: Int?, untrackedFiles: Int?, unpushedCommits: Int?
    public var worktreeLocked: Bool?, worktreeRegistered: Bool?
    /// Modified in the last few minutes (an active session or download may be writing).
    public var recentlyModified: Bool?
    /// An application database (live state, not an artifact).
    public var isDatabase = false
    /// Credentials, system-managed or Storage Monitor's own data.
    public var protectedScope = false
    /// Symlinks from PATH directories point into the item (an installed tool).
    public var linkedFromPath: Bool?
    public init() {}
}

public struct ArtifactClassification: Equatable, Sendable {
    public let kind: ArtifactKind
    public let tool: ArtifactTool
    /// "Claude Code 2.1.306", "node_modules of web-app".
    public let title: String
    public let characteristics: Set<ArtifactCharacteristic>
    public let confidence: ArtifactConfidence
    public let supporting: [ArtifactObservation]
    public let contradicting: [ArtifactObservation]
    public let unknowns: [String]
    public let related: [ArtifactRelation]
    public let facts: ArtifactFacts
    /// What could break if the item were removed.
    public let dependencies: [String]
    public init(kind: ArtifactKind, tool: ArtifactTool, title: String, characteristics: Set<ArtifactCharacteristic>, confidence: ArtifactConfidence,
                supporting: [ArtifactObservation], contradicting: [ArtifactObservation] = [], unknowns: [String] = [], related: [ArtifactRelation] = [],
                facts: ArtifactFacts, dependencies: [String] = []) {
        self.kind = kind; self.tool = tool; self.title = title; self.characteristics = characteristics; self.confidence = confidence
        self.supporting = supporting; self.contradicting = contradicting; self.unknowns = unknowns; self.related = related; self.facts = facts; self.dependencies = dependencies
    }
}

// MARK: Assessment

public enum CleanupStatus: String, Sendable, CaseIterable {
    case preserve, reviewCandidate, insufficientEvidence, protected
    public var title: String {
        switch self {
        case .preserve: return "Preserve"
        case .reviewCandidate: return "Review candidate"
        case .insufficientEvidence: return "Insufficient evidence"
        case .protected: return "Protected"
        }
    }
}

public struct CleanupAssessment: Equatable, Sendable {
    public let status: CleanupStatus
    /// One sentence.
    public let summary: String
    /// Why this status (the facts that decided it).
    public let reasons: [String]
    /// What would need judgment or could break.
    public let risks: [String]
    public init(status: CleanupStatus, summary: String, reasons: [String], risks: [String]) { self.status = status; self.summary = summary; self.reasons = reasons; self.risks = risks }
}

// MARK: Inspection

/// Whether the path still names the object the inventory indexed.
public enum ArtifactIdentityState: Equatable, Sendable {
    case verified
    /// The path now names another filesystem object (replaced since it was indexed).
    case changed
    /// Nothing is at the path any more.
    case missing
    case unavailable(String)
}

/// The five storage quantities, never interchangeable.
public struct ArtifactStorage: Equatable, Sendable {
    public enum Recovery: Equatable, Sendable {
        /// No defensible estimate.
        case unknown(String)
        /// An estimate with its basis (never shown as verified recovery).
        case estimated(Int64, basis: String)
    }
    public let logicalBytes: Int64?
    public let indexedAllocatedBytes: Int64?
    public let measuredAt: Date?
    /// The inventory's measurement state ("Complete", "Previously measured", …).
    public let measurement: String
    public let measurementComplete: Bool
    public let recovery: Recovery
    public init(logicalBytes: Int64?, indexedAllocatedBytes: Int64?, measuredAt: Date?, measurement: String, measurementComplete: Bool, recovery: Recovery) {
        self.logicalBytes = logicalBytes; self.indexedAllocatedBytes = indexedAllocatedBytes; self.measuredAt = measuredAt
        self.measurement = measurement; self.measurementComplete = measurementComplete; self.recovery = recovery
    }
    /// Said wherever sizes are shown.
    public static let limitations = [
        "Indexed allocation counts every file's allocated blocks; deleting may free less, because APFS clones and hard links share data and local snapshots can keep deleted data until they expire.",
        "Physical allocation on disk was not measured separately; it cannot be derived from the indexed size.",
    ]
}

public struct ArtifactInspection: Equatable, Sendable {
    public let nodeID: Int64
    public let path: String
    public let collectedAt: Date
    public let elapsed: TimeInterval
    public let identity: ArtifactIdentityState
    /// Nil: not a recognized artifact (an ordinary item).
    public let classification: ArtifactClassification?
    /// Nil when there is nothing to assess (an ordinary item).
    public let assessment: CleanupAssessment?
    public let storage: ArtifactStorage
    /// Evidence that could not be collected within the budget or permissions.
    public let incomplete: [String]
    public init(nodeID: Int64, path: String, collectedAt: Date, elapsed: TimeInterval, identity: ArtifactIdentityState, classification: ArtifactClassification?,
                assessment: CleanupAssessment?, storage: ArtifactStorage, incomplete: [String]) {
        self.nodeID = nodeID; self.path = path; self.collectedAt = collectedAt; self.elapsed = elapsed; self.identity = identity
        self.classification = classification; self.assessment = assessment; self.storage = storage; self.incomplete = incomplete
    }
    public var isRecognized: Bool { classification != nil }
}
