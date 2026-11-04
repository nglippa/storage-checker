import Foundation

// Read-only inventory discovery and review planning. Matching names only produce potential matches;
// the existing ArtifactInspector is the sole classifier and CleanupPolicy is the sole assessment policy.
public struct CleanupDiscoveryCursor: Hashable, Sendable {
    public let generation: Int64
    public let afterID: Int64
    public init(generation: Int64, afterID: Int64) { self.generation = generation; self.afterID = afterID }
}

public struct CleanupDiscoveryPage: Sendable {
    public let nodes: [InventoryNode]
    public let scannedRows: Int
    public let next: CleanupDiscoveryCursor?
    public let generation: Int64?
    public let journal: InventoryChangeCursor?
    public let inventoryStale: Bool
    public let resynchronized: Bool
}

public struct CleanupListingCursor: Sendable {
    public let generation: Int64
    public let name: String
    public let id: Int64
}

public struct CleanupListingDiscoveryPage: Sendable {
    public let nodes: [InventoryNode]
    public let scannedRows: Int
    public let next: CleanupListingCursor?
    public let generation: Int64?
    public let journal: InventoryChangeCursor?
    public let inventoryStale: Bool
}

/// Read-only catalog boundary. A narrow protocol also permits deterministic suspended-read regression
/// tests without production SQL, sleeps, or timing assumptions.
public protocol CleanupReviewInventoryReading: Sendable {
    func cleanupDiscoveryPage(after cursor: CleanupDiscoveryCursor?, limit: Int) async throws -> CleanupDiscoveryPage
    func cleanupListingDiscoveryPage(directoryID: Int64, after cursor: CleanupListingCursor?, limit: Int) async throws -> CleanupListingDiscoveryPage
    func node(id: Int64) async throws -> InventoryNode?
    func changes(since cursor: InventoryChangeCursor?, limit: Int) async throws -> InventoryChangeBatch
}

/// Cheap discovery hints, deliberately broader than classification. A match proves nothing about removability.
public enum CleanupDiscoveryHints {
    public static func isPotential(name: String, kind: InventoryNodeKind) -> Bool {
        if name == ".git" || name == "pyvenv.cfg" || name == "codex-package.json" { return true }
        if kind == .directory {
            return ["versions", "releases", "node_modules", "dist", "build", ".next", "storybook-static", "out", ".venv", "venv", "__pycache__",
                    "pip", "uv", "npm", ".npm", "_cacache", "pnpm", ".pnpm-store", "store", "Yarn", "yarn", "cache", ".bun", "projects", "sessions", "archived_sessions",
                    ".ssh", ".aws", ".gnupg", "Keychains", "MacBook Storage Monitor", ".claude", ".codex"].contains(name)
                || name.hasPrefix(".claude-") || name.hasPrefix(".codex-")
                || name.first?.isNumber == true
        }
        return name.first?.isNumber == true || name.hasPrefix("rollout-") || name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")
    }
    public static func targetsParent(name: String) -> Bool { [".git", "pyvenv.cfg", "codex-package.json"].contains(name) }
}

public struct CleanupReviewQueueBudget: Sendable {
    public var rowsPerPage: Int
    public var maximumScannedRows: Int
    public var maximumEntries: Int
    public var inspectionsPerStep: Int
    public var evidence: ArtifactProbe.Budget
    public init(rowsPerPage: Int = 128, maximumScannedRows: Int = 100_000, maximumEntries: Int = 512, inspectionsPerStep: Int = 4,
                evidence: ArtifactProbe.Budget = .init(entries: 1_000, reads: 24, seconds: 0.35)) {
        self.rowsPerPage = min(256, max(8, rowsPerPage)); self.maximumScannedRows = max(1, maximumScannedRows)
        self.maximumEntries = min(4_096, max(1, maximumEntries)); self.inspectionsPerStep = min(16, max(1, inspectionsPerStep)); self.evidence = evidence
    }
    public static let standard = CleanupReviewQueueBudget()
}

public struct CleanupReviewFreshness: Sendable, Equatable {
    public let inventoryGeneration: Int64
    public let journal: InventoryChangeCursor?
    public let evidenceTimestamp: Date?
    public let assessmentTimestamp: Date?
    public let measurementTimestamp: Date?
    public let processObservation: ProcessObservation?
    public var invalidationReasons: [String]
    public func reasons(now: Date, processMaximumAge: TimeInterval = 20) -> [String] {
        var result = invalidationReasons
        if evidenceTimestamp == nil { result.append("Potential match: evidence has not been collected.") }
        if processObservation == nil || now.timeIntervalSince(processObservation!.takenAt) > processMaximumAge || now < processObservation!.takenAt {
            result.append("Active-use evidence needs refreshing; filesystem events do not track processes.")
        }
        return result
    }
    public func isFresh(now: Date) -> Bool { reasons(now: now).isEmpty }
}

public struct CleanupReviewQueueEntry: Identifiable, Sendable {
    public enum Stage: String, Sendable { case potentialMatch, verifiedArtifact }
    public let node: InventoryNode
    public let canonicalPath: String
    public let filesystemIdentity: InventoryIdentity
    public let inspection: ArtifactInspection?
    public var freshness: CleanupReviewFreshness
    /// Display context only; never grants assessment, plan or Trash eligibility.
    private let retainedReviewContext: Bool
    public var id: Int64 { node.id }
    public var stage: Stage {
        guard let inspection, inspection.identity == .verified, let classification = inspection.classification,
              classification.confidence >= .strong else { return .potentialMatch }
        return .verifiedArtifact
    }
    /// Invalidated evidence must not remain a review recommendation.
    public var status: CleanupStatus? {
        status(at: Date())
    }
    /// A quiet filesystem does not keep an old process observation current.
    public func status(at now: Date) -> CleanupStatus? {
        guard freshness.isFresh(now: now) else { return .insufficientEvidence }
        return inspection?.assessment?.status ?? (retainedReviewContext ? .insufficientEvidence : nil)
    }
    /// Retained review context only. Eligibility, recovery estimates, plans and Trash still require fresh evidence.
    public func needsRecheck(at now: Date) -> Bool {
        retainedReviewContext && status(at: now) == .insufficientEvidence
    }
    public var confidence: ArtifactConfidence { inspection?.classification?.confidence ?? .unknown }
    /// This is exclusively indexed allocated storage. Logical size is never substituted.
    public var indexedAllocatedBytes: Int64? {
        guard node.status != .unknown else { return nil }
        return inspection?.storage.indexedAllocatedBytes ?? node.allocatedBytes ?? node.previousAllocatedBytes
    }
    public var recoverableBytes: Int64? {
        recoverableBytes(at: Date())
    }
    public func recoverableBytes(at now: Date) -> Int64? {
        guard freshness.isFresh(now: now), let inspection, inspection.identity == .verified,
              inspection.storage.measurementComplete, case .estimated(let bytes, _) = inspection.storage.recovery else { return nil }
        return bytes
    }
    public var uncertainty: [String] { (inspection?.classification?.unknowns ?? []) + (inspection?.incomplete ?? []) + freshness.invalidationReasons }
    public init(node: InventoryNode, inspection: ArtifactInspection?, journal: InventoryChangeCursor?, processes: ProcessObservation?, invalidationReasons: [String] = [], retainingReviewContext: Bool = false) {
        self.node = node; filesystemIdentity = node.identity
        retainedReviewContext = inspection?.assessment?.status != .preserve && inspection?.assessment?.status != .protected
            && (retainingReviewContext || (inspection?.identity == .verified
                && (inspection?.classification?.confidence ?? .unknown) >= .strong && inspection?.assessment?.status == .reviewCandidate))
        // The shared Inspector consumes ArtifactInspection directly. Carry freshness uncertainty into
        // that same model so opening a stale row cannot display a fresher assessment than the queue.
        if let inspection, !invalidationReasons.isEmpty {
            self.inspection = ArtifactInspection(nodeID: inspection.nodeID,path: inspection.path,collectedAt: inspection.collectedAt,elapsed: inspection.elapsed,
                identity: inspection.identity,classification: inspection.classification,
                assessment: CleanupAssessment(status: .insufficientEvidence,summary: "Evidence freshness needs revalidation.",
                    reasons: invalidationReasons,risks: inspection.assessment?.risks ?? []),storage: Self.invalidatedStorage(inspection.storage),incomplete: inspection.incomplete + invalidationReasons)
        } else { self.inspection = inspection }
        canonicalPath = ArtifactProbe().canonical(node.path) ?? ArtifactPaths.logical((node.path as NSString).standardizingPath)
        freshness = CleanupReviewFreshness(inventoryGeneration: node.generation, journal: journal, evidenceTimestamp: inspection?.collectedAt,
            assessmentTimestamp: inspection?.collectedAt, measurementTimestamp: node.measuredAt, processObservation: processes, invalidationReasons: invalidationReasons)
    }
    /// The shared Inspector must use the same freshness decision as the queue, including evidence
    /// that expires while a read is suspended. This only derives presentation from retained values.
    public func inspectionForReview(at now: Date) -> ArtifactInspection? {
        guard let inspection else { return nil }
        let reasons = freshness.reasons(now: now)
        guard !reasons.isEmpty else { return inspection }
        return ArtifactInspection(nodeID: inspection.nodeID, path: inspection.path,
            collectedAt: inspection.collectedAt, elapsed: inspection.elapsed, identity: inspection.identity,
            classification: inspection.classification,
            assessment: CleanupAssessment(status: .insufficientEvidence, summary: "Evidence freshness needs revalidation.",
                reasons: reasons, risks: inspection.assessment?.risks ?? []),
            storage: Self.invalidatedStorage(inspection.storage), incomplete: Array(Set(inspection.incomplete + reasons)).sorted())
    }
    private static func invalidatedStorage(_ storage: ArtifactStorage) -> ArtifactStorage {
        ArtifactStorage(logicalBytes: storage.logicalBytes, indexedAllocatedBytes: storage.indexedAllocatedBytes,
            measuredAt: storage.measuredAt, measurement: storage.measurement, measurementComplete: storage.measurementComplete,
            recovery: .unknown("Evidence freshness needs revalidation."))
    }
}

public enum CleanupReviewQueueSort: String, CaseIterable, Sendable {
    case recoverable, indexedAllocated, artifactType, confidence, lastVerification
    public var title: String {
        switch self {
        case .recoverable: return "Estimated recoverable storage"
        case .indexedAllocated: return "Indexed allocated size"
        case .artifactType: return "Artifact type"
        case .confidence: return "Evidence confidence"
        case .lastVerification: return "Last verification"
        }
    }
}

public struct CleanupReviewQueueFilter: Sendable {
    public var status: CleanupStatus?
    public var kind: ArtifactKind?
    public var tool: ArtifactTool?
    public var includesPotentialMatches: Bool
    public init(status: CleanupStatus? = .reviewCandidate, kind: ArtifactKind? = nil, tool: ArtifactTool? = nil, includesPotentialMatches: Bool = false) {
        self.status = status; self.kind = kind; self.tool = tool; self.includesPotentialMatches = includesPotentialMatches
    }
}

public struct CleanupReviewQueueProgress: Sendable {
    public var scannedRows = 0
    public var potentialMatches = 0
    public var verifiedArtifacts = 0
    public var reviewCandidates = 0
    public var complete = false
    public var hasMore = true
    public var stopReason: String?
    public var isCancelled = false
    /// Earlier artifact pages are deliberately released, never silently retained in an unbounded cache.
    public var pagedOutEntries = 0
    public var text: String {
        "Checked \(scannedRows.formatted()) indexed entries · \(verifiedArtifacts.formatted()) verified artifacts · \(reviewCandidates.formatted()) review candidates"
    }
}

public struct CleanupReviewQueueSnapshot: Sendable {
    public let entries: [CleanupReviewQueueEntry]
    public let progress: CleanupReviewQueueProgress
    public let cursor: CleanupDiscoveryCursor?
    public let journal: InventoryChangeCursor?
    /// Re-evaluates only retained evidence. No filesystem, process, Git or catalog work occurs.
    public func reevaluatingFreshness(at now: Date) -> CleanupReviewQueueSnapshot {
        var current = progress
        current.reviewCandidates = entries.filter { $0.status(at: now) == .reviewCandidate }.count
        return .init(entries: entries, progress: current, cursor: cursor, journal: journal)
    }
    public func filtered(filter: CleanupReviewQueueFilter = .init(), sort: CleanupReviewQueueSort = .indexedAllocated, now: Date = Date()) -> [CleanupReviewQueueEntry] {
        entries.filter { entry in
            (filter.includesPotentialMatches || entry.stage == .verifiedArtifact || entry.needsRecheck(at: now))
                && (filter.status == nil || entry.status(at: now) == filter.status
                    || (filter.status == .reviewCandidate && entry.needsRecheck(at: now)))
                && (filter.kind == nil || entry.inspection?.classification?.kind == filter.kind)
                && (filter.tool == nil || entry.inspection?.classification?.tool == filter.tool)
        }.sorted { a, b in
            switch sort {
            case .recoverable:
                if a.recoverableBytes(at: now) != b.recoverableBytes(at: now) { return (a.recoverableBytes(at: now) ?? -1) > (b.recoverableBytes(at: now) ?? -1) }
            case .indexedAllocated:
                if a.indexedAllocatedBytes != b.indexedAllocatedBytes { return (a.indexedAllocatedBytes ?? -1) > (b.indexedAllocatedBytes ?? -1) }
            case .artifactType:
                let left = a.inspection?.classification?.kind.title ?? "", right = b.inspection?.classification?.kind.title ?? ""
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            case .confidence: if a.confidence != b.confidence { return a.confidence > b.confidence }
            case .lastVerification:
                if a.freshness.assessmentTimestamp != b.freshness.assessmentTimestamp { return (a.freshness.assessmentTimestamp ?? .distantPast) > (b.freshness.assessmentTimestamp ?? .distantPast) }
            }
            return a.node.path == b.node.path ? a.id < b.id : a.node.path.localizedStandardCompare(b.node.path) == .orderedAscending
        }
    }
}

/// Incremental, bounded state. No timer and no filesystem watcher; callers schedule one step at a time.
public actor CleanupReviewQueue {
    public let budget: CleanupReviewQueueBudget
    private var entries = [Int64: CleanupReviewQueueEntry]()
    private var identities = Set<String>()
    private var pending = [InventoryNode]()
    private var pendingInvalidationReasons = [String]()
    private var pendingJournal: InventoryChangeCursor?
    private var changedListings = [Int64]()
    private var listingCursor: CleanupListingCursor?
    private var requiresIndexedResynchronization = false
    private var cursor: CleanupDiscoveryCursor?
    private var journal: InventoryChangeCursor?
    private var progress = CleanupReviewQueueProgress()
    private var generation: Int64?
    private var cancelled = false
    private var epoch = 0
    private var journalRevision = 0
    private var discoveryToken: UUID?
    private var rowLimit: Int
    public init(budget: CleanupReviewQueueBudget = .standard) { self.budget = budget; rowLimit = budget.maximumScannedRows }
    public func snapshot(now: Date = Date()) -> CleanupReviewQueueSnapshot {
        CleanupReviewQueueSnapshot(entries: Array(entries.values), progress: progress, cursor: cursor, journal: journal).reevaluatingFreshness(at: now)
    }
    public func reset() {
        entries = [:]; identities = []; pending = []; pendingInvalidationReasons = []; pendingJournal = nil; changedListings = []; listingCursor = nil; requiresIndexedResynchronization = false
        discoveryToken = nil; journalRevision += 1
        cursor = nil; journal = nil; progress = .init(); generation = nil; cancelled = false; rowLimit = budget.maximumScannedRows; epoch += 1
    }
    public func cancel() { cancelled = true; progress.isCancelled = true; progress.stopReason = "Discovery cancelled; coverage is incomplete."; epoch += 1 }
    /// Resume with the same keyset cursor and bounded memory, without rescanning earlier records.
    public func resume() {
        guard !progress.complete, !requiresIndexedResynchronization else { return }
        if entries.count >= budget.maximumEntries {
            progress.pagedOutEntries += entries.count
            entries = [:]; identities = []
        }
        if progress.scannedRows >= rowLimit {
            let next = rowLimit.addingReportingOverflow(budget.maximumScannedRows)
            rowLimit = next.overflow ? Int.max : next.partialValue
        }
        cancelled = false; progress.isCancelled = false; progress.stopReason = nil; updateCounts()
    }
    public func discoverNext(reader: any CleanupReviewInventoryReading, environment: ArtifactEnvironment) async throws -> CleanupReviewQueueSnapshot {
        try Task.checkCancellation()
        guard !cancelled, !progress.complete, progress.stopReason == nil else { return snapshot() }
        guard discoveryToken == nil else { return snapshot() }
        let token = UUID(); discoveryToken = token
        defer { if discoveryToken == token { discoveryToken = nil } }
        let requestEpoch = epoch
        let requestJournalRevision = journalRevision
        if pending.isEmpty {
            guard progress.scannedRows < rowLimit else {
                progress.stopReason = "Discovery reached its indexed-entry budget; coverage is incomplete."; return snapshot()
            }
            if let directory = changedListings.first {
                let page = try await reader.cleanupListingDiscoveryPage(directoryID: directory, after: listingCursor,
                    limit: min(budget.rowsPerPage, rowLimit - progress.scannedRows))
                try Task.checkCancellation()
                guard epoch == requestEpoch, journalRevision == requestJournalRevision, !cancelled else { return snapshot() }
                guard page.generation == generation else {
                    requireResynchronization("Inventory generation changed; restart indexed discovery."); return snapshot()
                }
                guard observeJournal(page.journal) else { return snapshot() }
                progress.scannedRows += page.scannedRows; progress.potentialMatches += page.nodes.count
                pending = page.nodes; pendingInvalidationReasons = page.inventoryStale ? ["Inventory history or measurements are incomplete."] : []
                pendingJournal = page.journal
                listingCursor = page.next
                if page.next == nil { changedListings.removeFirst() }
                // Do not advance the journal cursor here: the controller must still consume all intervening changes.
            } else {
                let page = try await reader.cleanupDiscoveryPage(after: cursor, limit: min(budget.rowsPerPage, rowLimit - progress.scannedRows))
                try Task.checkCancellation()
                guard epoch == requestEpoch, journalRevision == requestJournalRevision, !cancelled else { return snapshot() }
                if page.resynchronized || (generation != nil && page.generation != generation) {
                    entries = [:]; identities = []; progress = .init(); rowLimit = budget.maximumScannedRows
                }
                guard observeJournal(page.journal) else { return snapshot() }
                generation = page.generation; cursor = page.next
                progress.scannedRows += page.scannedRows; progress.potentialMatches += page.nodes.count
                progress.hasMore = page.next != nil
                pending = page.nodes
                pendingJournal = page.journal
                pendingInvalidationReasons = page.inventoryStale ? ["Inventory history or measurements are incomplete."] : []
                if page.inventoryStale {
                    invalidateAll("Inventory change history or measurements are incomplete.")
                }
            }
        }
        // One fresh process observation per bounded step, never reused when a candidate opens for review.
        let processes = pending.isEmpty ? nil : environment.processes()
        var stepEnvironment = environment
        if let processes { stepEnvironment.processes = { processes } }
        var inspected = 0
        while !pending.isEmpty && inspected < budget.inspectionsPerStep {
            try Task.checkCancellation()
            guard !cancelled else { return snapshot() }
            guard entries.count < budget.maximumEntries else {
                progress.stopReason = "Discovery reached its \(budget.maximumEntries)-artifact memory budget; coverage is incomplete."; updateCounts(); return snapshot()
            }
            let node = pending.removeFirst()
            let key = node.identity.stableKey
            guard !identities.contains(key), entries[node.id] == nil else { continue }
            inspected += 1
            let inspection = ArtifactInspector.inspect(node, environment: stepEnvironment, budget: budget.evidence)
            // A false positive is not a verified artifact or an opportunity. Retain no unbounded rejection set.
            guard inspection.classification != nil else { continue }
            identities.insert(key)
            entries[node.id] = CleanupReviewQueueEntry(node: node, inspection: inspection, journal: pendingJournal, processes: processes,
                invalidationReasons: pendingInvalidationReasons + (node.status == .stale ? ["Indexed measurement is stale."] : []) + inspection.incomplete)
        }
        if pending.isEmpty && cursor == nil && changedListings.isEmpty {
            progress.complete = true
            progress.stopReason = "Discovery covered the indexed entries, not unindexed or inaccessible locations."
        }
        updateCounts()
        return snapshot()
    }

    /// Selected rows always get fresh active-use evidence. A vanished catalog row is removed.
    public func refresh(nodeID: Int64, reader: any CleanupReviewInventoryReading, environment: ArtifactEnvironment) async throws -> CleanupReviewQueueEntry? {
        let requestEpoch = epoch
        let requestJournalRevision = journalRevision
        let readNode = try await reader.node(id: nodeID)
        try Task.checkCancellation()
        guard epoch == requestEpoch, journalRevision == requestJournalRevision else { return nil }
        guard let node = readNode else {
            if let removed = entries.removeValue(forKey: nodeID) { identities.remove(removed.filesystemIdentity.stableKey) }
            updateCounts(); return nil
        }
        try Task.checkCancellation()
        guard epoch == requestEpoch, journalRevision == requestJournalRevision else { return nil }
        let processes = environment.processes()
        var freshEnvironment = environment; freshEnvironment.processes = { processes }
        let inspection = ArtifactInspector.inspect(node, environment: freshEnvironment)
        let latest = try await reader.changes(since: journal, limit: 8)
        try Task.checkCancellation()
        guard epoch == requestEpoch, journalRevision == requestJournalRevision else { return nil }
        var reasons = [String]()
        if !latest.available || latest.mustResynchronize || !latest.complete || latest.generation != node.generation {
            reasons.append("Inventory change journal could not verify evidence freshness; revalidation is required.")
        }
        if !latest.changes.isEmpty { reasons.append("The inventory changed while evidence was collected; revalidation is required.") }
        if latest.generationStale { reasons.append("Inventory change history or measurements are incomplete.") }
        if node.status == .stale { reasons.append("Indexed measurement is stale.") }
        reasons += inspection.incomplete
        if let old = entries[nodeID], old.filesystemIdentity != node.identity { reasons.append("Filesystem identity changed; earlier evidence no longer applies.") }
        let old = entries[nodeID]
        let uncertainIdentity: Bool = { if case .unavailable = inspection.identity { return true }; return false }()
        let retainContext = old?.filesystemIdentity == node.identity
            && (old?.needsRecheck(at: Date()) == true || old?.inspection?.assessment?.status == .reviewCandidate)
            && inspection.assessment?.status != .preserve && inspection.assessment?.status != .protected
            && ((inspection.identity == .verified && inspection.classification != nil) || uncertainIdentity)
        let result = CleanupReviewQueueEntry(node: node, inspection: inspection, journal: latest.next, processes: processes, invalidationReasons: reasons, retainingReviewContext: retainContext)
        if inspection.classification != nil || retainContext, entries[nodeID] != nil || entries.count < budget.maximumEntries {
            if let old = entries[nodeID] { identities.remove(old.filesystemIdentity.stableKey) }
            entries[nodeID] = result; identities.insert(node.identity.stableKey)
        } else if inspection.classification == nil {
            if let old = entries.removeValue(forKey: nodeID) { identities.remove(old.filesystemIdentity.stableKey) }
        }
        updateCounts(); return result
    }

    /// Journal changes conservatively invalidate retained rows. The bounded queue is cheap to revalidate;
    /// no unsupported assumption is made that a direct parent is the only relevant ancestor.
    public func applyChanges(_ batch: InventoryChangeBatch) -> CleanupReviewQueueSnapshot {
        let journalRegressed = journal.map { old in
            batch.journalID == old.journalID && batch.latestSequence < old.sequence
        } ?? false
        if batch.mustResynchronize || !batch.available || batch.generation != generation || batch.generationStale || !batch.complete || !batch.changes.isEmpty || journalRegressed {
            // A read suspended in another actor must not overwrite invalidation reasons, cursors, or
            // a resynchronization stop when it returns with an older snapshot.
            journalRevision += 1
        }
        if batch.mustResynchronize || !batch.available || batch.generation != generation || journalRegressed {
            invalidateAll("Inventory change journal requires resynchronization.")
            requireResynchronization("Inventory change journal requires resynchronization; restart indexed discovery.")
        } else if batch.generationStale || !batch.complete || !batch.changes.isEmpty {
            invalidateAll(batch.generationStale ? "Inventory measurements are stale." : "The inventory changed; review evidence needs revalidation.")
            pendingInvalidationReasons = ["The inventory changed; pending evidence needs revalidation."]
            if !batch.complete {
                requireResynchronization("Change backlog exceeds the bounded journal read; restart indexed discovery.")
            } else {
                for change in batch.changes {
                    // A newly inserted/renamed child can sort before an in-flight name cursor.
                    // Revisit the bounded listing from its beginning rather than acknowledge that
                    // event while silently skipping the new child. Retained identities deduplicate it.
                    if changedListings.first == change.directoryID { listingCursor = nil }
                    guard !changedListings.contains(change.directoryID) else { continue }
                    guard changedListings.count < 256 else {
                        requireResynchronization("More than 256 changed directories need review; restart indexed discovery."); break
                    }
                    changedListings.append(change.directoryID)
                }
                if !changedListings.isEmpty {
                    progress.complete = false
                    if !requiresIndexedResynchronization && progress.stopReason?.hasPrefix("Discovery covered") == true { progress.stopReason = nil }
                }
            }
        }
        journal = batch.next
        updateCounts(); return snapshot()
    }
    private func invalidateAll(_ reason: String) {
        for id in Array(entries.keys) where entries[id]?.freshness.invalidationReasons.contains(reason) == false {
            entries[id]?.freshness.invalidationReasons.append(reason)
        }
    }
    /// `journal` is the last CONSUMED journal position, not the stamp of the newest discovery page.
    /// Advancing it just because a page observed newer SQL state would lose events for earlier rows.
    private func observeJournal(_ observed: InventoryChangeCursor?) -> Bool {
        guard let previous = journal else {
            if entries.isEmpty && progress.scannedRows == 0 { journal = observed }
            return true
        }
        guard let observed, observed.journalID == previous.journalID, observed.sequence >= previous.sequence else {
            invalidateAll("Inventory journal identity changed or regressed during discovery.")
            requireResynchronization("Inventory journal changed during discovery; restart indexed discovery.")
            return false
        }
        if observed.sequence > previous.sequence {
            invalidateAll("The inventory changed since earlier evidence; pending journal changes require revalidation.")
        }
        return true
    }
    private func requireResynchronization(_ reason: String) {
        requiresIndexedResynchronization = true; progress.complete = false; progress.stopReason = reason
    }
    private func updateCounts() {
        progress.verifiedArtifacts = entries.values.filter { $0.stage == .verifiedArtifact }.count
        progress.reviewCandidates = entries.values.filter { $0.status == .reviewCandidate }.count
        if !progress.complete { progress.hasMore = cursor != nil || !pending.isEmpty || !changedListings.isEmpty || requiresIndexedResynchronization }
    }
}

/// Informational only. This type has no execution or Trash capability.
public struct CleanupReviewPlan: Sendable {
    public let count: Int
    public let items: [CleanupReviewQueueEntry]
    public let excludedOverlaps: [String]
    public let excludedNonCandidates: [String]
    public let indexedAllocatedBytes: Int64?
    public let recovery: ArtifactStorage.Recovery
    public let unknownRecoveryCount: Int
    public let risks: [String]
    public let dependencies: [String]
    public let requiresRevalidation: [String]
    public let protectedRelated: [ArtifactRelation]
    public init(entries: [CleanupReviewQueueEntry], now: Date = Date()) {
        let sorted = entries.sorted { $0.canonicalPath.count == $1.canonicalPath.count ? $0.canonicalPath < $1.canonicalPath : $0.canonicalPath.count < $1.canonicalPath.count }
        var kept = [CleanupReviewQueueEntry](), overlaps = [String](), excluded = [String](), identities = Set<String>()
        for entry in sorted {
            guard entry.status(at: now) == .reviewCandidate else { excluded.append(entry.node.path); continue }
            if !identities.insert(entry.filesystemIdentity.stableKey).inserted || kept.contains(where: { ArtifactPaths.isWithin(entry.canonicalPath, $0.canonicalPath) }) {
                overlaps.append(entry.node.path); continue
            }
            kept.append(entry)
        }
        items = kept; count = kept.count; excludedOverlaps = overlaps; excludedNonCandidates = excluded
        var indexed: Int64 = 0, known = true
        for item in kept {
            guard let value = item.indexedAllocatedBytes else { known = false; continue }
            let sum = indexed.addingReportingOverflow(value); indexed = sum.partialValue; if sum.overflow { known = false }
        }
        indexedAllocatedBytes = known ? indexed : nil
        unknownRecoveryCount = kept.filter { $0.recoverableBytes(at: now) == nil }.count
        if kept.count == 1, let value = kept.first?.recoverableBytes(at: now) {
            recovery = .estimated(value, basis: "Single-item estimate only; local snapshots may retain the data. Moving to Trash does not establish physical recovery.")
        } else {
            recovery = .unknown("Total recoverable storage cannot be determined.")
        }
        risks = Array(Set(kept.flatMap { ($0.inspection?.assessment?.risks ?? []) + $0.uncertainty })).sorted()
        dependencies = Array(Set(kept.flatMap { $0.inspection?.classification?.dependencies ?? [] })).sorted()
        requiresRevalidation = kept.filter { !$0.freshness.isFresh(now: now) }.map { $0.node.path }
        protectedRelated = Array(Set(kept.flatMap { $0.inspection?.classification?.related.filter(\.mustPreserve) ?? [] })).sorted { $0.path < $1.path }
    }
}
