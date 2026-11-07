import Foundation

// Incremental-change reads for viewers, and the bounded bookkeeping a viewer needs to refresh only the
// branches it shows. Nothing here reports raw filesystem events: a directory appears in the change feed
// only after the inventory worker committed new catalog state for it.

/// Where a reader is in one change journal. A cursor from another journal (a recreated database) or one
/// older than the journal's retention floor cannot be continued: the reader resynchronizes instead.
public struct InventoryChangeCursor: Codable, Hashable, Sendable {
    public let journalID: String
    public let sequence: Int64
    public init(journalID: String, sequence: Int64) { self.journalID = journalID; self.sequence = sequence }
}

/// A directory whose catalog state changed after the cursor. `subtree` means state derived along its
/// chain changed for everything beneath it (staleness from reconciliation or pruning, paths after a move);
/// otherwise only its own listing (its children's rows, or its own row) changed.
public struct InventoryDirectoryChange: Hashable, Sendable {
    public let directoryID: Int64
    public let sequence: Int64
    public let subtree: Bool
}

public struct InventoryChangeBatch: Sendable {
    /// False when the catalog has no change journal yet (a worker that predates it): refresh everything visible.
    public let available: Bool
    public let journalID: String?
    /// The latest committed change sequence when the read was taken.
    public let latestSequence: Int64
    public let generation: Int64?
    /// Every value in the generation is qualified as stale (pending invalidations, unavailable file events).
    /// This is not journaled per directory; a viewer refreshes everything visible when it flips.
    public let generationStale: Bool
    /// Changed directories in sequence order; never the same directory twice.
    public let changes: [InventoryDirectoryChange]
    /// The cursor to pass next time.
    public let next: InventoryChangeCursor?
    /// False when more changes exist after `next` than the read returned.
    public let complete: Bool
    /// The cursor could not be continued (missing, another journal, or older than retention). `changes` is
    /// empty: the caller must reconcile its visible branches and continue from `next`.
    public let mustResynchronize: Bool
}

/// One node's latest comparison of two settled measurements of its indexed allocated size. Emitted only when
/// both measurements are settled (`complete`, or `partial` with a value) after the generation's first pass; a
/// measurement in progress is never compared. The delta is a change in *indexed allocation*: APFS clones, shared
/// extents, snapshots and purgeable space mean it is not the physical space consumed or reclaimed.
public struct InventorySizeSignal: Hashable, Sendable {
    public enum Confidence: String, Sendable {
        /// Both measurements cover the whole subtree.
        case complete
        /// At least one measurement covers only the observable part of the subtree (protected or unreadable
        /// descendants are excluded from both sides); compare as observed allocation.
        case observedLowerBound
    }
    public enum Trend: String, Sendable { case growth, reduction, unchanged }

    public let nodeID: Int64
    public let generation: Int64
    public let sequence: Int64
    public let previousAllocatedBytes: Int64
    public let allocatedBytes: Int64
    public let previousMeasuredAt: Date?
    public let measuredAt: Date?
    public let confidence: Confidence

    public var deltaBytes: Int64 { allocatedBytes &- previousAllocatedBytes }
    public var trend: Trend { deltaBytes > 0 ? .growth : (deltaBytes < 0 ? .reduction : .unchanged) }

    public init(nodeID: Int64, generation: Int64, sequence: Int64, previousAllocatedBytes: Int64, allocatedBytes: Int64, previousMeasuredAt: Date?, measuredAt: Date?, previousStatus: String, status: String) {
        self.nodeID = nodeID; self.generation = generation; self.sequence = sequence
        self.previousAllocatedBytes = previousAllocatedBytes; self.allocatedBytes = allocatedBytes
        self.previousMeasuredAt = previousMeasuredAt; self.measuredAt = measuredAt
        confidence = previousStatus == "complete" && status == "complete" ? .complete : .observedLowerBound
    }
}

public struct InventorySignalBatch: Sendable {
    public let available: Bool
    public let latestSequence: Int64
    public let signals: [InventorySizeSignal]
    public let next: InventoryChangeCursor?
    public let complete: Bool
    public let mustResynchronize: Bool
}

/// A viewer's position in the change feed and the folders whose last refresh failed. Bounded: the cursor,
/// one flag, and at most `retryLimit` folder ids. Planning is pure; the caller commits the returned tracker
/// only when it carries out the plan, so a deferred plan never loses changes.
public struct InventoryChangeTracker: Sendable, Equatable {
    public enum Plan: Equatable, Sendable {
        /// Nothing visible changed.
        case none
        /// Re-read every visible folder (no journal, resynchronization, a backlog beyond one read, or a
        /// generation-wide staleness change).
        case everything(String)
        /// Re-read only these loaded folders: changed listings, and every loaded folder at or beneath a subtree.
        case folders(listing: Set<Int64>, subtrees: Set<Int64>)
    }

    public static let retryLimit = 512
    public private(set) var cursor: InventoryChangeCursor?
    private var generationStale: Bool?
    public private(set) var retry = Set<Int64>()

    public init() {}

    /// The plan for `batch` (nil: the read failed, so only earlier failures are retried) and the tracker to
    /// keep once the plan has been carried out.
    public func planned(_ batch: InventoryChangeBatch?) -> (plan: Plan, tracker: InventoryChangeTracker) {
        var next = self
        next.retry = []
        guard let batch else { return (retry.isEmpty ? .none : .folders(listing: retry, subtrees: []), next) }
        next.generationStale = batch.generationStale
        guard batch.available, let journal = batch.journalID else { next.cursor = nil; return (.everything("change journal unavailable"), next) }
        let latest = InventoryChangeCursor(journalID: journal, sequence: batch.latestSequence)
        if batch.mustResynchronize { next.cursor = latest; return (.everything(cursor == nil ? "first read" : "cursor outside retained history"), next) }
        if let previous = generationStale, previous != batch.generationStale { next.cursor = latest; return (.everything("generation staleness changed"), next) }
        // A backlog larger than one bounded read is cheaper to settle by re-reading what is visible.
        if !batch.complete { next.cursor = latest; return (.everything("change backlog exceeds one read"), next) }
        next.cursor = batch.next ?? latest
        var listing = retry, subtrees = Set<Int64>()
        for change in batch.changes { if change.subtree { subtrees.insert(change.directoryID) } else { listing.insert(change.directoryID) } }
        return (listing.isEmpty && subtrees.isEmpty ? .none : .folders(listing: listing, subtrees: subtrees), next)
    }

    /// Folders whose refresh failed are retried with the next plan. Only folders still loaded are kept.
    public mutating func noteFailed(_ folders: [Int64], loaded: Set<Int64>) {
        for folder in folders where loaded.contains(folder) && retry.count < Self.retryLimit { retry.insert(folder) }
    }
}

/// What one visible-branch refresh read. Applied to the explorer state in one step by `InventoryExplorerState.apply`.
public struct InventoryVisibleRefreshResult: Sendable {
    public struct Folder: Sendable {
        public let parent: Int64
        /// Entries the folder had loaded when the refresh was planned.
        public let loaded: Int
        public let page: InventoryChildPage
        public let node: InventoryNode?
    }
    public var folders = [Folder]()
    /// Folders that no longer exist in the catalog (deleted, or replaced by a new generation).
    public var deleted = [Int64]()
    /// Folders whose read failed for another reason (a busy database, a read deadline). Their loaded pages
    /// are kept as they were and retried later; a transient failure never evicts a folder.
    public var failed = [Int64]()
    /// The selected entry no longer exists anywhere in the catalog.
    public var selectionDeleted: Int64?
    /// The selected entry still exists; its fresh row (possibly under another parent after a move).
    public var selectionNode: InventoryNode?
    public init() {}
}

public enum InventoryVisibleRefresh {
    /// Re-reads `targets` (each with the span it had loaded), telling deleted folders apart from failed reads,
    /// and checks whether a selection that disappeared from a refreshed folder was deleted or moved.
    /// `previous` gives the entry ids a folder showed before the refresh.
    public static func perform(reader: InventoryReader, targets: [(parent: Int64, count: Int)], selection: Int64?, selectionParent: Int64?, previous: [Int64: Set<Int64>]) async -> InventoryVisibleRefreshResult {
        var result = InventoryVisibleRefreshResult()
        var selectionMissing = false
        for (parent, count) in targets {
            var items = [InventoryNode](), cursor: InventoryChildCursor? = nil, failed = false
            repeat {
                do {
                    let page = try await reader.explorerChildren(parentID: parent, after: cursor, limit: 200)
                    items += page.items; cursor = page.next
                } catch { failed = true; break }
            } while cursor != nil && items.count < max(1, count)
            // Only a successful lookup that finds nothing means the folder is gone.
            let folder = await lookup(reader, parent)
            if case .missing = folder { result.deleted.append(parent); continue }
            if failed { result.failed.append(parent); continue }
            var node: InventoryNode? = nil
            if case .present(let fresh) = folder { node = fresh }
            result.folders.append(.init(parent: parent, loaded: count, page: InventoryChildPage(items: items, next: cursor), node: node))
            if let selection, parent == selectionParent, previous[parent]?.contains(selection) == true, !items.contains(where: { $0.id == selection }) {
                selectionMissing = true
            }
        }
        if let selection, selectionMissing || (selectionParent.map { result.deleted.contains($0) } ?? false) {
            switch await lookup(reader, selection) {
            case .missing: result.selectionDeleted = selection
            case .present(let node): result.selectionNode = node
            case .failed: break
            }
        }
        return result
    }

    private enum Lookup { case present(InventoryNode), missing, failed }
    private static func lookup(_ reader: InventoryReader, _ id: Int64) async -> Lookup {
        do { return try await reader.node(id: id).map(Lookup.present) ?? .missing } catch { return .failed }
    }
}

/// Cumulative refresh work of one explorer: how many folder reads the change feed avoided.
public struct InventoryRefreshStatistics: Sendable, Equatable {
    public var passes = 0
    public var fullRefreshes = 0
    public var incrementalRefreshes = 0
    public var foldersReloaded = 0
    /// Visible folders not re-read because nothing in them changed.
    public var foldersSkipped = 0
    public var failedReads = 0
    public var deletedFolders = 0
    public init() {}
}
