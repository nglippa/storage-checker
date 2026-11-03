import Foundation

// The Migration Readiness detector: finds sparse-storage candidates in the existing inventory catalog and checks them
// on disk. It never walks the filesystem: the catalog already holds each file's logical and allocated sizes, so the
// first pass is a bounded, cancellable primary-key scan of the catalog and later passes read only the folders the
// change journal names. It owns its own catalog reader, so a running scan never waits behind (or delays) folder
// navigation, which uses the browser's reader.
//
// Process invariant: run the detector only in a process that never writes the catalog (the viewer). With macOS's system
// SQLite (3.54.0 measured), a read-only connection in the same process as an active catalog writer makes the writer's
// lock requests intermittently fail with EBADF, surfacing as SQLITE_IOERR_LOCK ("disk I/O error"). Reproduced in plain
// C with no app code; never observed with the reader in another process, or with a read-write reader. See
// artifacts/storage-monitor/migration-readiness/PERFORMANCE-RESULTS.md.

/// One reported item.
public struct SparseStorageItem: Identifiable, Sendable {
    public var id: Int64 { node.id }
    public let node: InventoryNode
    /// Folders from the inventory root down to the item's parent (catalog node ids).
    public let ancestors: [Int64]
    public let kind: SparseStorageKind
    public let severity: SparseStorageSeverity
    /// What the catalog recorded.
    public let indexed: SparseAllocation
    /// The values the severity was decided on: live when checked and unchanged in identity, otherwise indexed.
    public let allocation: SparseAllocation
    public let verification: SparseStorageVerification
    /// A sparse bundle's own Info.plist (capacity), when it could be read without a permission prompt.
    public let bundle: SparseBundleInfo?

    public var title: String { kind.title }
}

/// What the report can and cannot speak for.
public struct SparseStorageCoverage: Sendable, Equatable {
    public enum LocationState: String, Sendable { case indexed, protected, unavailable, pending }
    /// A known application storage location the inventory could not fully measure.
    public struct Location: Sendable, Equatable, Hashable {
        public let application: String
        public let path: String
        public let state: LocationState
        /// The application's bundle is present in /Applications (nil: not known).
        public let installed: Bool?
    }
    public var inventoryAvailable = false
    /// The inventory's first full pass has not finished, or work is queued: unscanned folders may hold candidates.
    public var inventoryIncomplete = true
    public var protectedFolders: Int64 = 0
    public var unavailableFolders: Int64 = 0
    public var unreadableEntries: Int64 = 0
    public var fullDiskAccess: String?
    public var limitedLocations: [Location] = []
    /// Candidates set aside, with the reason.
    public var cloudLocations = 0
    public var cloudPlaceholders = 0
    public var compressed = 0
    public var vanished = 0
    /// Candidates beyond the per-pass live-check budget (reported from indexed values).
    public var unchecked = 0

    public var isComplete: Bool { inventoryAvailable && !inventoryIncomplete && protectedFolders == 0 && unavailableFolders == 0 && limitedLocations.isEmpty }

    /// Plain-language limits, most important first. Empty only when nothing limits the result.
    public var notes: [String] {
        var notes = [String]()
        if !inventoryAvailable { notes.append("The disk inventory has not started, so nothing has been checked yet.") }
        else if inventoryIncomplete { notes.append("The disk inventory is still measuring some folders; items there are not checked yet.") }
        for location in limitedLocations {
            let installed = location.installed == true ? "\(location.application) is installed, but its" : "\(location.application)'s"
            switch location.state {
            case .protected: notes.append("\(installed) storage folder is protected by macOS and was not inspected. Full Disk Access for Storage Monitor would include it.")
            case .unavailable: notes.append("\(installed) storage folder could not be read.")
            case .pending: notes.append("\(installed) storage folder has not been measured yet.")
            case .indexed: break
            }
        }
        if protectedFolders > 0 { notes.append("\(protectedFolders.formatted()) protected folders were not inspected.") }
        if unavailableFolders > 0 { notes.append("\(unavailableFolders.formatted()) folders could not be read.") }
        if cloudLocations > 0 { notes.append("\(cloudLocations.formatted()) large items in iCloud Drive or cloud storage folders were skipped: they may not be stored on this Mac.") }
        if cloudPlaceholders > 0 { notes.append("\(cloudPlaceholders.formatted()) cloud placeholders were skipped (their data is not on this Mac).") }
        if compressed > 0 { notes.append("\(compressed.formatted()) files are smaller on disk because of filesystem compression, not sparse allocation; they are not listed.") }
        if unchecked > 0 { notes.append("\(unchecked.formatted()) items were not checked on disk in this pass; their indexed sizes are shown.") }
        return notes
    }
}

public struct SparseStorageReport: Sendable {
    public enum Pass: String, Sendable { case full, incremental, unchanged }
    /// Sorted: review first, then unknown, then informational; within each, the largest gap first. At most `limit`.
    public let items: [SparseStorageItem]
    public let reviewCount: Int
    public let unknownCount: Int
    public let informationalCount: Int
    public let coverage: SparseStorageCoverage
    public let thresholds: SparseStorageThresholds
    public let generation: Int64?
    /// The indexed volume's filesystem ("apfs"), from statfs of the inventory root; nil when unknown.
    public let filesystem: String?
    public let completedAt: Date
    public let pass: Pass

    public static let limit = 500

    /// The item the Overview leads with: the largest gap among those to review, else among those not checkable.
    public var headline: SparseStorageItem? { items.first { $0.severity == .review } ?? items.first { $0.severity == .unknown } }
    public func item(_ id: Int64) -> SparseStorageItem? { items.first { $0.id == id } }

    /// The Overview's status sentence; never claims more than the scanned coverage supports.
    public var summary: String {
        if reviewCount > 0 { return reviewCount == 1 ? "1 item to review" : "\(reviewCount) items to review" }
        if unknownCount > 0 { return unknownCount == 1 ? "1 item could not be checked" : "\(unknownCount) items could not be checked" }
        return "No large sparse-storage discrepancies detected in scanned locations."
    }
}

/// The application storage locations checked for coverage, relative to the home folder.
public struct SparseStorageKnownLocation: Sendable {
    public let application: String
    public let relativePath: String
    public let bundle: String?
    public static let all: [SparseStorageKnownLocation] = [
        .init(application: "Docker Desktop", relativePath: "Library/Containers/com.docker.docker", bundle: "Docker.app"),
        .init(application: "OrbStack", relativePath: ".orbstack", bundle: "OrbStack.app"),
        .init(application: "UTM", relativePath: "Library/Containers/com.utmapp.UTM", bundle: "UTM.app"),
        .init(application: "Parallels Desktop", relativePath: "Parallels", bundle: "Parallels Desktop.app"),
        .init(application: "VMware Fusion", relativePath: "Virtual Machines.localized", bundle: "VMware Fusion.app"),
        .init(application: "Lima", relativePath: ".lima", bundle: nil),
        .init(application: "Colima", relativePath: ".colima", bundle: nil),
        .init(application: "Tart", relativePath: ".tart", bundle: nil),
    ]
}

public actor SparseStorageDetector {
    public struct Statistics: Sendable, Equatable {
        public var fullScans = 0
        public var incrementalPasses = 0
        public var unchangedPasses = 0
        /// Catalog reads of the scan (primary-key slices) and of changed folders.
        public var chunkReads = 0
        public var directoryReads = 0
        public var idsSpanned: Int64 = 0
        public var candidatesHydrated = 0
        public var liveChecks = 0
        public var liveCacheHits = 0
        public var bundleReads = 0
        public var slowestChunkSeconds = 0.0
        public var lastPassSeconds = 0.0
    }

    private struct Entry {
        let record: SparseCandidateRecord
        let kind: SparseStorageKind
    }
    private struct Fingerprint: Hashable {
        let identity: InventoryIdentity, indexed: SparseAllocation, modified: Date?
    }
    private struct LiveCache {
        let fingerprint: Fingerprint
        let result: Result<SparseStorageLiveMetadata, SparseStorageProbeError>?
        let bundle: SparseBundleInfo?
        let at: Date
    }

    public let thresholds: SparseStorageThresholds
    private let reader: InventoryReader
    private let probe: SparseStorageProbe
    private let home: String?
    private let chunkSpan: Int64
    private let pause: UInt64
    private let liveCheckLimit: Int
    private var generation: Int64?
    private var cursor: InventoryChangeCursor?
    private var entries = [Int64: Entry]()
    private var live = [Int64: LiveCache]()
    private var lastReport: SparseStorageReport?
    public private(set) var statistics = Statistics()

    /// - Parameters:
    ///   - home: the home folder used for protected-location and display rules (the current user's by default).
    ///   - chunkSpan: catalog ids per scan slice; `pauseNanoseconds` yields between slices to the inventory worker.
    public init(database: String, thresholds: SparseStorageThresholds = .standard, probe: SparseStorageProbe = .live,
                home: String? = FileManager.default.homeDirectoryForCurrentUser.path, chunkSpan: Int64 = 50_000,
                pauseNanoseconds: UInt64 = 2_000_000, liveCheckLimit: Int = 2_000) {
        reader = InventoryReader(path: database)
        self.thresholds = thresholds; self.probe = probe; self.home = home
        self.chunkSpan = max(1, chunkSpan); pause = pauseNanoseconds; self.liveCheckLimit = max(0, liveCheckLimit)
    }

    public var report: SparseStorageReport? { lastReport }

    /// Brings the report up to date: a full scan the first time (or when the journal cannot be continued), otherwise
    /// only the folders that changed since the last pass. Cancelling the calling task stops it between catalog reads
    /// and leaves the previous report, entries and journal position untouched (live-check observations already made
    /// stay cached: they are real lstat results keyed to the catalog values they were checked against).
    public func refresh(forceFull: Bool = false) async throws -> SparseStorageReport {
        let started = Date()
        let status = try await reader.status()
        let accounting = try await reader.accounting()
        var pass = SparseStorageReport.Pass.full
        var nextEntries = entries, nextCursor = cursor
        if !forceFull, generation != nil, generation == status.generation, let cursor, let change = try await changedFolders(since: cursor) {
            // Nothing changed: no candidate is read again; coverage is still re-evaluated (it can change on its own).
            if !change.folders.isEmpty || !change.subtree.isEmpty {
                nextEntries = try await incremental(entries, folders: change.folders, subtree: change.subtree)
            }
            nextCursor = change.next
            pass = change.folders.isEmpty && change.subtree.isEmpty ? .unchanged : .incremental
        } else {
            (nextEntries, nextCursor) = try await fullScan()
        }
        try Task.checkCancellation()
        let report = try await evaluate(nextEntries, status: status, accounting: accounting, pass: pass)
        try Task.checkCancellation()
        // Commit only a finished pass.
        entries = nextEntries; cursor = nextCursor; generation = status.generation; lastReport = report
        live = live.filter { nextEntries[$0.key] != nil }
        switch pass { case .full: statistics.fullScans += 1; case .incremental: statistics.incrementalPasses += 1; case .unchanged: statistics.unchangedPasses += 1 }
        statistics.lastPassSeconds = Date().timeIntervalSince(started)
        return report
    }

    /// Checks one reported item on disk again (an Inspector selection), unless it was checked within `maximumAge`.
    /// Returns the updated item, or nil when it is no longer reported.
    public func recheck(_ id: Int64, maximumAge: TimeInterval = 15) async -> SparseStorageItem? {
        guard let entry = entries[id], let report = lastReport else { return nil }
        if let cached = live[id], Date().timeIntervalSince(cached.at) < maximumAge { statistics.liveCacheHits += 1; return report.item(id) }
        live[id] = nil
        var counters = SparseStorageCoverage()
        let item = check(entry, budget: 1, counters: &counters)
        // The report's list is capped; its counts cover everything, so they change only by this item's move.
        var counts = [SparseStorageSeverity.review: report.reviewCount, .unknown: report.unknownCount, .informational: report.informationalCount]
        if let old = report.item(id) { counts[old.severity, default: 0] -= 1 }
        if let item { counts[item.severity, default: 0] += 1 }
        var items = report.items.filter { $0.id != id }
        if let item { items.append(item) }
        lastReport = Self.assemble(items, coverage: report.coverage, thresholds: thresholds, generation: report.generation, filesystem: report.filesystem, pass: report.pass, counts: counts)
        return item
    }

    // MARK: Passes

    private func changedFolders(since cursor: InventoryChangeCursor) async throws -> (folders: Set<Int64>, subtree: Set<Int64>, next: InventoryChangeCursor)? {
        var folders = Set<Int64>(), subtree = Set<Int64>(), next = cursor
        for _ in 0..<8 {
            let batch = try await reader.changes(since: next, limit: InventoryReader.maximumChangeRead)
            guard batch.available, !batch.mustResynchronize, let after = batch.next else { return nil }
            for change in batch.changes { folders.insert(change.directoryID); if change.subtree { subtree.insert(change.directoryID) } }
            next = after
            if batch.complete { return (folders, subtree, next) }
        }
        return nil  // too many changes to replay cheaply: rescan
    }

    private func fullScan() async throws -> ([Int64: Entry], InventoryChangeCursor?) {
        // The journal position is taken first, so anything committed during the scan is replayed by the next pass.
        let start = try await reader.changes(since: nil, limit: 8).next
        var ids = [Int64](), after: Int64 = 0
        while true {
            try Task.checkCancellation()
            let began = Date()
            let chunk = try await withBusyRetry { try await reader.sparseCandidateChunk(after: after, span: chunkSpan, thresholds: thresholds) }
            statistics.chunkReads += 1
            statistics.slowestChunkSeconds = max(statistics.slowestChunkSeconds, Date().timeIntervalSince(began))
            statistics.idsSpanned += chunk.scannedThrough - after
            ids += chunk.ids
            guard chunk.generation != nil, chunk.scannedThrough < chunk.maximumID else { break }
            after = chunk.scannedThrough
            if pause > 0 { try await Task.sleep(nanoseconds: pause) }
        }
        return (try await hydrate(ids), start)
    }

    /// A slice that meets the worker's commit (SQLITE_BUSY after the reader's 100 ms busy timeout) is retried a few
    /// times with a short pause instead of abandoning the whole pass. Cancellation is never retried.
    private func withBusyRetry<T>(_ read: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await read() }
            catch let error as InventoryReaderError where attempt < 3 && !Task.isCancelled && error.description.lowercased().contains("locked") {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
            }
        }
    }

    private func incremental(_ current: [Int64: Entry], folders: Set<Int64>, subtree: Set<Int64>) async throws -> [Int64: Entry] {
        var result = current.filter { key, entry in
            !folders.contains(key) && !(entry.record.node.parentID.map(folders.contains) ?? false)
        }
        // A subtree change can move paths; sparse bundles' totals change with their bands: both are re-read.
        let reread = result.filter { _, entry in entry.kind.isSparseBundle || entry.record.ancestors.contains(where: subtree.contains) }.map(\.key)
        for key in reread { result[key] = nil }
        let ordered = Array(folders).sorted()
        var ids = [Int64]()
        for start in stride(from: 0, to: ordered.count, by: 256) {
            ids += try await reader.sparseCandidates(inDirectories: Array(ordered[start..<min(ordered.count, start + 256)]), thresholds: thresholds)
            statistics.directoryReads += 1
        }
        for (key, entry) in try await hydrate(Array(Set(ids + reread))) { result[key] = entry }
        return result
    }

    private func hydrate(_ ids: [Int64]) async throws -> [Int64: Entry] {
        guard !ids.isEmpty else { return [:] }
        let records = try await reader.sparseCandidateRecords(ids: ids)
        statistics.candidatesHydrated += records.count
        var result = [Int64: Entry]()
        for record in records {
            let node = record.node
            let bundle = node.kind == .directory
            guard node.kind == .file || (bundle && node.name.lowercased().hasSuffix(".sparsebundle")) else { continue }
            // Band files are represented by their sparse bundle, never listed (or counted) on their own.
            if ArtifactPaths.components(node.path).dropLast().contains(where: { $0.lowercased().hasSuffix(".sparsebundle") }) { continue }
            result[node.id] = Entry(record: record, kind: SparseStorageClassifier.classify(path: node.path, isDirectory: bundle))
        }
        return result
    }

    // MARK: Evaluation

    private func evaluate(_ entries: [Int64: Entry], status: InventoryStatus, accounting: InventoryAccounting, pass: SparseStorageReport.Pass) async throws -> SparseStorageReport {
        var coverage = SparseStorageCoverage()
        coverage.inventoryAvailable = status.generation != nil
        coverage.inventoryIncomplete = status.generation == nil || status.initialCompletion == .inProgress || status.initialCompletion == .notStarted
            || status.pendingDirectories > 0 || status.hasInitialDiscoveryWork
        coverage.protectedFolders = accounting.protectedFolders
        coverage.unavailableFolders = accounting.unavailableFolders
        coverage.unreadableEntries = accounting.unreadableEntries
        coverage.fullDiskAccess = accounting.fullDiskAccess
        coverage.limitedLocations = try await knownLocations()

        // One item per filesystem object: hard links are already one row; duplicates by identity keep the lowest id.
        var seen = Set<InventoryIdentity>(), items = [SparseStorageItem](), budget = liveCheckLimit
        for key in entries.keys.sorted() {
            try Task.checkCancellation()
            let entry = entries[key]!
            let identity = InventoryIdentity(device: entry.record.node.identity.device, inode: entry.record.node.identity.inode, birthNanoseconds: entry.record.node.identity.birthNanoseconds)
            guard seen.insert(identity).inserted else { continue }
            let checks = statistics.liveChecks
            if let item = check(entry, budget: budget, counters: &coverage) { items.append(item) }
            if statistics.liveChecks > checks { budget = max(0, budget - 1) }
        }
        return Self.assemble(items, coverage: coverage, thresholds: thresholds, generation: status.generation, filesystem: status.rootPath.flatMap(Self.filesystem), pass: pass)
    }

    /// Live-checks one candidate (cached by identity and indexed sizes) and decides whether and how it is reported.
    private func check(_ entry: Entry, budget: Int, counters: inout SparseStorageCoverage) -> SparseStorageItem? {
        let node = entry.record.node
        let indexed = entry.record.indexed
        if SparseStorageLocations.isCloud(node.path, home: home) { counters.cloudLocations += 1; return nil }
        let fingerprint = Fingerprint(identity: node.identity, indexed: indexed, modified: node.modifiedAt)
        let protected = SparseStorageLocations.isProtected(node.path, home: home)
        var skip: String?
        if protected {
            skip = "Not checked on disk: this location is protected by macOS, and checking it could show a permission prompt. Indexed values are shown."
        } else if entry.kind.isSparseBundle {
            skip = "Sizes are the indexed totals of the bundle's band files."
        }
        if node.status == .stale && skip != nil { skip! += " They are from an earlier measurement." }
        // Successful checks are reused while the indexed identity and sizes are unchanged; refusals and misses are retried.
        var cached = live[node.id].flatMap { cache -> LiveCache? in
            guard cache.fingerprint == fingerprint else { return nil }
            if case .failure? = cache.result { return nil }
            return cache
        }
        if cached != nil { statistics.liveCacheHits += 1 }
        else if !protected && entry.kind.isSparseBundle {
            statistics.bundleReads += 1
            cached = LiveCache(fingerprint: fingerprint, result: nil, bundle: probe.bundleInfo(node.path), at: Date())
            live[node.id] = cached
        } else if !protected && budget > 0 {
            statistics.liveChecks += 1
            cached = LiveCache(fingerprint: fingerprint, result: probe.metadata(node.path), bundle: nil, at: Date())
            live[node.id] = cached
        } else if !protected {
            counters.unchecked += 1
            skip = "Not checked on disk in this pass (check limit reached). Indexed values are shown."
        }
        let evaluation = SparseStorageEvaluator.evaluate(indexed: indexed, identity: node.identity, live: entry.kind.isSparseBundle ? nil : cached?.result,
                                                         skipReason: skip, thresholds: thresholds, now: cached?.at ?? Date())
        switch evaluation {
        case .notSparse: return nil
        case .missing: counters.vanished += 1; return nil
        case .compressed: counters.compressed += 1; return nil
        case .cloudPlaceholder: counters.cloudPlaceholders += 1; return nil
        case .reported(let severity, let allocation, let verification):
            let unverifiedFile: Bool = { if case .inaccessible = verification { return entry.kind.category == .sparseFile }; if case .replaced = verification { return entry.kind.category == .sparseFile }; return false }()
            return SparseStorageItem(node: node, ancestors: entry.record.ancestors, kind: unverifiedFile ? entry.kind.with(category: .unknown) : entry.kind,
                                     severity: severity, indexed: indexed, allocation: allocation, verification: verification, bundle: cached?.bundle)
        }
    }

    /// The filesystem type of the volume holding `path` (no file is opened).
    static func filesystem(_ path: String) -> String? {
        var value = statfs()
        guard statfs(path, &value) == 0 else { return nil }
        return withUnsafePointer(to: value.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
    }

    private static func assemble(_ items: [SparseStorageItem], coverage: SparseStorageCoverage, thresholds: SparseStorageThresholds, generation: Int64?, filesystem: String?, pass: SparseStorageReport.Pass,
                                 counts: [SparseStorageSeverity: Int]? = nil) -> SparseStorageReport {
        func count(_ severity: SparseStorageSeverity) -> Int { counts.map { max(0, $0[severity] ?? 0) } ?? items.filter { $0.severity == severity }.count }
        let sorted = items.sorted { a, b in
            a.severity.rank != b.severity.rank ? a.severity.rank < b.severity.rank : (a.allocation.gap != b.allocation.gap ? a.allocation.gap > b.allocation.gap : a.id < b.id)
        }
        return SparseStorageReport(items: Array(sorted.prefix(SparseStorageReport.limit)), reviewCount: count(.review),
                                   unknownCount: count(.unknown), informationalCount: count(.informational),
                                   coverage: coverage, thresholds: thresholds, generation: generation, filesystem: filesystem, completedAt: Date(), pass: pass)
    }

    /// Known application storage locations the inventory could not measure. Indexed lookups only.
    private func knownLocations() async throws -> [SparseStorageCoverage.Location] {
        guard let home else { return [] }
        var result = [SparseStorageCoverage.Location]()
        for location in SparseStorageKnownLocation.all {
            let path = home + "/" + location.relativePath
            guard let found = try? await reader.locateDirectory(path: path) else { continue }
            let node = found.node
            let state: SparseStorageCoverage.LocationState?
            switch (found.exact, node.status) {
            case (_, .unknown) where node.statusReason == "consent" || node.statusReason == "privacy" || node.statusReason == "metadata:privacy": state = .protected
            case (_, .unknown) where node.kind == .directory: state = found.exact ? .unavailable : nil
            case (true, .lowerBound) where node.listingState == "pending" || node.listingState == "enumerating": state = .pending
            default: state = nil
            }
            guard let state else { continue }
            var installed: Bool?
            if let bundle = location.bundle, let app = try? await reader.locateDirectory(path: "/Applications/" + bundle) { installed = app.exact }
            // A protected parent hides whether the application stores anything there: skip it when known not installed.
            if !found.exact && installed == false { continue }
            result.append(.init(application: location.application, path: SparseStorageLocations.redacted(path, home: home), state: state, installed: installed))
        }
        return result
    }
}
