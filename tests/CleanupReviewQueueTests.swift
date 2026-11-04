import Foundation
import SQLite3

private final class QueueProcessReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func observe() -> ProcessObservation {
        lock.lock(); reads += 1; lock.unlock()
        return ProcessObservation(executables: [], workingDirectories: [], inspected: 10, unreadable: 0)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
}

/// A fresh, small, synthetic catalog. No production database is opened or copied.
private final class CleanupQueueFixture {
    let root: URL
    let database: URL
    var db: OpaquePointer?
    var ids = [String: Int64]()
    var nextID: Int64 = 1
    init(_ parent: URL) throws {
        root = parent.appendingPathComponent(UUID().uuidString).appendingPathComponent("home")
        database = root.deletingLastPathComponent().appendingPathComponent("catalog.sqlite3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw InventoryReaderError.open("Queue fixture open failed") }
        try exec("""
        CREATE TABLE inventory_generations(id INTEGER PRIMARY KEY,root_path TEXT,active INTEGER,volume_uuid TEXT,event_availability TEXT);
        CREATE TABLE inventory_objects(id INTEGER PRIMARY KEY,device INTEGER,inode INTEGER,birth_ns INTEGER,modified_at REAL,owner_node_id INTEGER,logical INTEGER,allocated INTEGER);
        CREATE TABLE inventory_nodes(id INTEGER PRIMARY KEY,parent_id INTEGER,generation_id INTEGER,name TEXT,kind TEXT,total_logical INTEGER,total_allocated INTEGER,direct_logical INTEGER DEFAULT 0,direct_allocated INTEGER DEFAULT 0,child_count INTEGER DEFAULT 0,descendant_files INTEGER DEFAULT 0,descendant_directories INTEGER DEFAULT 0,status TEXT DEFAULT 'complete',reason TEXT,measured_at REAL,object_id INTEGER);
        CREATE INDEX inventory_nodes_children ON inventory_nodes(parent_id,name COLLATE NOCASE,id);
        CREATE TABLE inventory_jobs(node_id INTEGER,state TEXT);
        CREATE TABLE inventory_reconcile(root_node_id INTEGER);
        CREATE TABLE inventory_tombstones(node_id INTEGER);
        CREATE TABLE inventory_prune_jobs(parent_node_id INTEGER);
        CREATE TABLE inventory_invalidations(generation_id INTEGER);
        CREATE TABLE inventory_change_clock(id INTEGER PRIMARY KEY,journal_id TEXT,sequence INTEGER,retained_after INTEGER,signals_retained_after INTEGER);
        CREATE TABLE inventory_changed_directories(directory_id INTEGER,generation_id INTEGER,sequence INTEGER,subtree_sequence INTEGER);
        INSERT INTO inventory_change_clock VALUES(1,'queue-fixture',0,0,0);
        """)
        try write("INSERT INTO inventory_generations VALUES(1,?,1,NULL,'available')", [.string(root.path)])
        _ = try index("")
    }
    deinit { sqlite3_close(db) }
    enum Value { case string(String), integer(Int64), real(Double), null }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(db))) }
    }
    func write(_ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let column = Int32(index + 1)
            switch value {
            case .string(let text): sqlite3_bind_text(statement, column, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .integer(let number): sqlite3_bind_int64(statement, column, number)
            case .real(let number): sqlite3_bind_double(statement, column, number)
            case .null: sqlite3_bind_null(statement, column)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(db))) }
    }
    @discardableResult func file(_ relative: String, text: String = "fixture") throws -> Int64 {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return try index(relative)
    }
    @discardableResult func index(_ relative: String) throws -> Int64 {
        if let id = ids[relative] { return id }
        let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw InventoryReaderError.query("Queue fixture metadata unavailable") }
        let parentRelative = (relative as NSString).deletingLastPathComponent
        let parent = relative.isEmpty ? nil : try index(parentRelative == "." ? "" : parentRelative)
        let id = nextID; nextID += 1; ids[relative] = id
        let birth = Int64(metadata.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_birthtimespec.tv_nsec)
        let allocated = Int64(metadata.st_blocks) * 512
        try write("INSERT INTO inventory_objects VALUES(?,?,?,?,?,?,?,?)", [.integer(id), .integer(Int64(metadata.st_dev)), .integer(Int64(bitPattern: UInt64(metadata.st_ino))), .integer(birth), .real(Date().timeIntervalSince1970), .integer(id), .integer(Int64(metadata.st_size)), .integer(allocated)])
        try write("INSERT INTO inventory_nodes(id,parent_id,generation_id,name,kind,total_logical,total_allocated,measured_at,object_id) VALUES(?,?,1,?,?,?,?,?,?)",
                  [.integer(id), parent.map(Value.integer) ?? .null, .string(relative.isEmpty ? "" : url.lastPathComponent), .string(metadata.st_mode & S_IFMT == S_IFDIR ? "directory" : "file"), .integer(Int64(metadata.st_size)), .integer(allocated), .real(Date().timeIntervalSince1970), .integer(id)])
        return id
    }
    var environment: ArtifactEnvironment {
        ArtifactEnvironment(home: root.path, pathDirectories: [], processes: { ProcessObservation(executables: [], workingDirectories: [], inspected: 10, unreadable: 0) }, git: nil)
    }
}

/// Captures a real read-only catalog page, then suspends its delivery deterministically. Journal
/// mutations can run while the queue is awaiting that page, without sleeps or probabilistic races.
private actor SuspendedCleanupQueueReader: CleanupReviewInventoryReading {
    let base: InventoryReader
    private var deliveredFirst = false
    private var suspended = false
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    init(_ base: InventoryReader) { self.base = base }
    func cleanupDiscoveryPage(after cursor: CleanupDiscoveryCursor?, limit: Int) async throws -> CleanupDiscoveryPage {
        let page = try await base.cleanupDiscoveryPage(after: cursor, limit: limit)
        if !deliveredFirst {
            deliveredFirst = true; suspended = true
            started?.resume(); started = nil
            await withCheckedContinuation { release = $0 }
        }
        return page
    }
    func waitUntilSuspended() async {
        if !suspended { await withCheckedContinuation { started = $0 } }
    }
    func releasePage() { release?.resume(); release = nil }
    func cleanupListingDiscoveryPage(directoryID: Int64, after cursor: CleanupListingCursor?, limit: Int) async throws -> CleanupListingDiscoveryPage {
        try await base.cleanupListingDiscoveryPage(directoryID: directoryID, after: cursor, limit: limit)
    }
    func node(id: Int64) async throws -> InventoryNode? { try await base.node(id: id) }
    func changes(since cursor: InventoryChangeCursor?, limit: Int) async throws -> InventoryChangeBatch { try await base.changes(since: cursor, limit: limit) }
}

func cleanupReviewQueueTests(_ folder: URL, _ test: (Bool, String) throws -> Void) async throws {
    let fixture = try CleanupQueueFixture(folder)
    _ = try fixture.file("project/package.json", text: "{\"name\":\"fixture\"}")
    _ = try fixture.file("project/package-lock.json", text: "{}")
    _ = try fixture.file("project/node_modules/.package-lock.json", text: "{}")
    _ = try fixture.file("project/__pycache__/main.pyc")
    let cacheID = fixture.ids["project/__pycache__"]!
    _ = try fixture.file("false-positive/build/personal-notes.txt")
    _ = try fixture.file("environment/pyvenv.cfg", text: "home = /fixture/python\nversion = 3.12\n")
    let envID = fixture.ids["environment"]!
    _ = try fixture.file("project/README.txt")
    for index in 0..<30 { _ = try fixture.file("ordinary-\(index).txt") }
    let reader = InventoryReader(path: fixture.database.path)
    let original = try Data(contentsOf: fixture.database)
    let first = try await reader.cleanupDiscoveryPage(after: nil, limit: 8)
    try test(first.scannedRows == 8 && first.next != nil, "queue discovery pages bound examined indexed rows")
    let second = try await reader.cleanupDiscoveryPage(after: first.next, limit: 8)
    try test(second.scannedRows == 8 && second.next!.afterID > first.next!.afterID, "queue keyset cursor progresses without OFFSET")
    var cursor: CleanupDiscoveryCursor?, ids = [Int64](), scanned = 0
    repeat {
        let page = try await reader.cleanupDiscoveryPage(after: cursor, limit: 8)
        ids += page.nodes.map(\.id); scanned += page.scannedRows; cursor = page.next
    } while cursor != nil
    try test(scanned == fixture.ids.count, "queue paginated discovery examines every catalog row exactly once")
    try test(ids.contains(cacheID) && ids.contains(envID), "queue discovery includes bytecode cache and marker-named environment parent")
    try test(CleanupDiscoveryHints.isPotential(name: ".git", kind: .file) && CleanupDiscoveryHints.targetsParent(name: ".git"), "queue Git marker discovery targets its indexed worktree parent")
    try test(!CleanupDiscoveryHints.isPotential(name: "ordinary.txt", kind: .file), "ordinary names do not become discovery opportunities")
    try test(["_cacache", ".pnpm-store", "store", "cache", "Yarn"].allSatisfy { CleanupDiscoveryHints.isPotential(name: $0, kind: .directory) }, "queue discovery includes all existing package-cache leaf layouts")
    let queue = CleanupReviewQueue(budget: .init(rowsPerPage: 8, maximumScannedRows: 500, maximumEntries: 32, inspectionsPerStep: 2))
    var snapshot = await queue.snapshot()
    for _ in 0..<100 {
        snapshot = try await queue.discoverNext(reader: reader, environment: fixture.environment)
        if snapshot.progress.complete || snapshot.progress.stopReason != nil { break }
    }
    try test(snapshot.progress.complete && snapshot.progress.scannedRows == fixture.ids.count, "queue discovery reports complete indexed coverage for bounded fixture")
    try test(snapshot.entries.contains { $0.id == cacheID && $0.status == .reviewCandidate }, "queue reuses existing inspector to verify review candidate")
    try test(!snapshot.entries.contains { $0.node.path.hasSuffix("false-positive/build") && $0.stage == .verifiedArtifact }, "queue does not promote false-positive build name to verified artifact")
    try test(snapshot.entries.contains { $0.id == envID && $0.status == .insufficientEvidence }, "queue retains insufficient-evidence classification separately")
    try test(Set(snapshot.entries.map { $0.filesystemIdentity.stableKey }).count == snapshot.entries.count, "queue deduplicates retained artifacts by filesystem identity")
    try test(snapshot.filtered().allSatisfy { $0.status == .reviewCandidate }, "queue default filter shows review candidates only")
    let python = snapshot.filtered(filter: .init(status: nil, tool: .python))
    try test(!python.isEmpty && python.allSatisfy { $0.inspection?.classification?.tool == .python }, "queue associated-tool filter")
    let caches = snapshot.filtered(filter: .init(status: nil, kind: .pythonBytecodeCache))
    try test(caches.count == 1 && caches.first?.id == cacheID, "queue artifact-type filter")
    for sort in CleanupReviewQueueSort.allCases {
        let rows = snapshot.filtered(filter: .init(status: nil, includesPotentialMatches: true), sort: sort)
        try test(rows.count == snapshot.entries.count, "queue \(sort.title) sorting retains every matching row")
    }
    let cache = snapshot.entries.first { $0.id == cacheID }!
    try test(cache.freshness.inventoryGeneration == 1 && cache.freshness.journal?.journalID == "queue-fixture", "queue retains generation and journal provenance")
    try test(cache.freshness.evidenceTimestamp != nil && cache.freshness.assessmentTimestamp != nil && cache.freshness.measurementTimestamp != nil, "queue tracks separate evidence assessment and measurement timestamps")
    try test(cache.freshness.processObservation != nil && cache.confidence == .confirmed, "queue retains process snapshot and classification confidence")
    try test(!cache.freshness.isFresh(now: Date().addingTimeInterval(60)), "queue process observations expire without filesystem events")
    let observedAt = cache.freshness.processObservation!.takenAt
    let expiredAt = observedAt.addingTimeInterval(20.001)
    try test(cache.status(at: observedAt.addingTimeInterval(20)) == .reviewCandidate && cache.status(at: expiredAt) == .insufficientEvidence,
             "queue candidate eligibility expires with process evidence at the explicit TTL boundary")
    try test(snapshot.filtered(now: expiredAt).contains { $0.id == cache.id } && cache.needsRecheck(at: expiredAt), "default queue filter retains expired review context marked Needs recheck without extending eligibility")
    try test(cache.status(at: expiredAt) == .insufficientEvidence && CleanupReviewPlan(entries: [cache], now: expiredAt).count == 0,
             "retained Needs recheck row cannot enter a cleanup plan or regain candidate eligibility")
    try test(!snapshot.filtered(filter: .init(status: .preserve), now: expiredAt).contains { $0.id == cache.id },
             "retaining expired review context does not override an explicit assessment filter")
    try test(!cache.needsRecheck(at: observedAt), "fresh review evidence never displays the stale review label")
    let expiredSnapshot = snapshot.reevaluatingFreshness(at: Date().addingTimeInterval(60))
    let expiredActorSnapshot = await queue.snapshot(now: Date().addingTimeInterval(60))
    try test(expiredSnapshot.progress.reviewCandidates == 0 && expiredSnapshot.filtered(now: Date().addingTimeInterval(60)).contains { $0.id == cache.id },
             "idle freshness publication expires eligible count while retaining review context without evidence collection")
    try test(expiredActorSnapshot.progress.reviewCandidates == 0, "actor snapshots derive current eligibility without discovery or process polling")
    let noProcess = CleanupReviewQueueEntry(node: cache.node, inspection: cache.inspection, journal: cache.freshness.journal, processes: nil)
    try test(noProcess.status(at: observedAt) == .insufficientEvidence && CleanupReviewPlan(entries: [noProcess], now: observedAt).count == 0,
             "missing process evidence cannot remain eligible for queue or plan")
    try test(cache.status(at: observedAt.addingTimeInterval(-1)) == .insufficientEvidence,
             "future-dated process evidence cannot authorize candidate eligibility")
    let estimatedInspection = ArtifactInspection(nodeID: cache.id, path: cache.node.path,
        collectedAt: cache.inspection!.collectedAt, elapsed: cache.inspection!.elapsed,
        identity: .verified, classification: cache.inspection!.classification, assessment: cache.inspection!.assessment,
        storage: ArtifactStorage(logicalBytes: 100, indexedAllocatedBytes: 128, measuredAt: observedAt,
            measurement: "Deterministic fixture estimate", measurementComplete: true, recovery: .estimated(64, basis: "Fixture")), incomplete: [])
    let estimatedEntry = CleanupReviewQueueEntry(node: cache.node, inspection: estimatedInspection,
        journal: cache.freshness.journal, processes: cache.freshness.processObservation)
    try test(estimatedEntry.recoverableBytes(at: observedAt) == 64 && estimatedEntry.recoverableBytes(at: expiredAt) == nil,
             "expired process evidence removes a formerly available recovery estimate")
    let expiredReview = estimatedEntry.inspectionForReview(at: expiredAt)!
    try test(expiredReview.assessment?.status == .insufficientEvidence && expiredReview.storage.recovery == .unknown("Evidence freshness needs revalidation."),
             "opening expired retained evidence cannot show a fresher assessment or estimate in the shared Inspector")
    let protectedInspection = ArtifactInspection(nodeID: cache.id, path: cache.node.path, collectedAt: observedAt, elapsed: 0,
        identity: .verified, classification: cache.inspection!.classification,
        assessment: CleanupAssessment(status: .protected, summary: "Protected fixture", reasons: [], risks: []), storage: cache.inspection!.storage, incomplete: [])
    let protectedEntry = CleanupReviewQueueEntry(node: cache.node, inspection: protectedInspection, journal: cache.freshness.journal,
        processes: cache.freshness.processObservation, retainingReviewContext: true)
    try test(protectedEntry.status(at: observedAt) == .protected && !protectedEntry.needsRecheck(at: observedAt)
             && !protectedEntry.needsRecheck(at: expiredAt), "a fresh Protected result clears prior candidate context even after later evidence expiry")
    let invalidatedEstimate = CleanupReviewQueueEntry(node: cache.node, inspection: estimatedInspection,
        journal: cache.freshness.journal, processes: cache.freshness.processObservation, invalidationReasons: ["Journal changed."])
    try test(invalidatedEstimate.inspection?.assessment?.status == .insufficientEvidence && invalidatedEstimate.inspection?.storage.recovery == .unknown("Evidence freshness needs revalidation."),
             "journal-invalidated Inspector evidence also discards its historical recovery estimate")
    let resync = InventoryChangeBatch(available: true, journalID: "replacement", latestSequence: 20, generation: 1, generationStale: false, changes: [], next: .init(journalID: "replacement", sequence: 20), complete: true, mustResynchronize: true)
    let invalidated = await queue.applyChanges(resync)
    try test(invalidated.entries.allSatisfy { !$0.freshness.invalidationReasons.isEmpty && $0.status == .insufficientEvidence }, "journal resynchronization invalidates every retained recommendation")
    let whileResynchronizing = try await queue.refresh(nodeID: cacheID, reader: reader, environment: fixture.environment)
    try test(whileResynchronizing?.status == .insufficientEvidence, "selected row remains invalid when journal cannot verify freshness")
    let uncertainSnapshot = await queue.snapshot()
    try test(whileResynchronizing?.needsRecheck(at: Date()) == true && uncertainSnapshot.filtered().contains { $0.id == cacheID }
             && CleanupReviewPlan(entries: [whileResynchronizing!]).count == 0,
             "a failed journal recheck preserves prior review context in the default filter but cannot authorize a plan")
    try test(whileResynchronizing?.inspection?.assessment?.status == .insufficientEvidence && whileResynchronizing?.inspection?.incomplete.isEmpty == false,
             "shared Inspector receives the queue freshness uncertainty and conservative assessment")
    _ = await queue.applyChanges(try await reader.changes(since: nil))
    let refreshed = try await queue.refresh(nodeID: cacheID, reader: reader, environment: fixture.environment)
    try test(refreshed?.status == .reviewCandidate && refreshed!.freshness.isFresh(now: Date()), "opening candidate revalidates classification and current process evidence")
    try test(refreshed?.needsRecheck(at: Date()) == false, "successful recheck replaces retained uncertainty with fresh candidate evidence")
    let processReads = QueueProcessReadCounter()
    var countedEnvironment = fixture.environment
    countedEnvironment.processes = { processReads.observe() }
    let countedRefresh = try await queue.refresh(nodeID: cacheID, reader: reader, environment: countedEnvironment)
    try test(countedRefresh?.status == .reviewCandidate && processReads.count == 1,
             "opening review collects one fresh process observation shared by the detectors")
    let countedSnapshot = await queue.snapshot(now: expiredAt)
    for sort in CleanupReviewQueueSort.allCases { _ = countedSnapshot.filtered(sort: sort, now: expiredAt) }
    _ = countedSnapshot.reevaluatingFreshness(at: expiredAt)
    _ = CleanupReviewPlan(entries: countedSnapshot.entries, now: expiredAt)
    _ = countedRefresh?.inspectionForReview(at: expiredAt)
    try test(processReads.count == 1,
             "idle expiry filtering sorting planning and Inspector presentation never recollect process evidence")
    var running = fixture.environment
    let project = fixture.root.appendingPathComponent("project").path
    running.processes = { ProcessObservation(executables: [], workingDirectories: [project], inspected: 10, unreadable: 0) }
    let dependency = snapshot.entries.first { $0.inspection?.classification?.kind == .nodeDependencies }!
    let active = try await queue.refresh(nodeID: dependency.id, reader: reader, environment: running)
    try test(active?.status == .preserve, "opening candidate observes process changes that the journal cannot track")
    let afterPreserve = await queue.snapshot()
    try test(active?.needsRecheck(at: Date()) == false && !afterPreserve.filtered().contains { $0.id == dependency.id },
             "fresh Preserve assessment clears retained candidate visibility without losing the safety result")
    let small = CleanupReviewQueue(budget: .init(rowsPerPage: 8, maximumScannedRows: 8, maximumEntries: 2, inspectionsPerStep: 2))
    var partial = try await small.discoverNext(reader: reader, environment: fixture.environment)
    for _ in 0..<6 where partial.progress.stopReason == nil { partial = try await small.discoverNext(reader: reader, environment: fixture.environment) }
    try test(!partial.progress.complete && partial.progress.stopReason != nil && partial.progress.scannedRows <= 8 && partial.entries.count <= 2, "queue row and memory budgets report incomplete coverage")
    let originalCursor = partial.cursor?.afterID ?? 0
    await small.resume()
    var continued = try await small.discoverNext(reader: reader, environment: fixture.environment)
    for _ in 0..<100 {
        if continued.progress.complete { break }
        if continued.progress.stopReason != nil { await small.resume() }
        continued = try await small.discoverNext(reader: reader, environment: fixture.environment)
        try test(continued.entries.count <= 2, "continued queue page remains within artifact memory bound")
    }
    try test(continued.progress.complete && continued.progress.scannedRows == fixture.ids.count && continued.progress.scannedRows > originalCursor,
             "explicit continuation advances beyond row budget without restarting first tranche")
    try test(continued.progress.pagedOutEntries > 0, "artifact pagination explicitly counts released earlier pages")
    await small.cancel()
    let cancelled = try await small.discoverNext(reader: reader, environment: fixture.environment)
    try test(cancelled.progress.isCancelled, "queue explicit cancellation records cancellation")
    let task = Task { () throws -> CleanupDiscoveryPage in
        try Task.checkCancellation(); return try await reader.cleanupDiscoveryPage(after: nil)
    }
    task.cancel()
    var wasCancelled = false
    do { _ = try await task.value } catch is CancellationError { wasCancelled = true } catch { }
    try test(wasCancelled, "queue SQL discovery respects task cancellation")
    let freshPlanAt = [cache, dependency].compactMap { $0.freshness.processObservation?.takenAt }.max()!
    let plan = CleanupReviewPlan(entries: [cache, cache, dependency], now: freshPlanAt)
    try test(plan.count == 2 && plan.excludedOverlaps.count == 1, "read-only plan deduplicates selected filesystem identities")
    if cache.node.path.hasPrefix("/private/tmp/") || cache.node.path.hasPrefix("/tmp/") {
        let alias = cache.node.path.hasPrefix("/private/tmp/")
            ? "/tmp/" + String(cache.node.path.dropFirst("/private/tmp/".count))
            : "/private/tmp/" + String(cache.node.path.dropFirst("/tmp/".count))
        let aliasNode = cache.node.withPath(alias, kind: cache.node.kind)
        let aliasInspection = ArtifactInspector.inspect(aliasNode, environment: fixture.environment)
        let aliasEntry = CleanupReviewQueueEntry(node: aliasNode, inspection: aliasInspection, journal: cache.freshness.journal,
                                                processes: cache.freshness.processObservation)
        let aliasPlan = CleanupReviewPlan(entries: [cache, aliasEntry], now: freshPlanAt)
        try test(aliasEntry.canonicalPath == cache.canonicalPath && aliasPlan.count == 1 && aliasPlan.excludedOverlaps.count == 1,
                 "queue /tmp and /private/tmp aliases name one candidate and one filesystem identity")
    }
    let expiredPlan = CleanupReviewPlan(entries: [cache, dependency], now: Date().addingTimeInterval(60))
    try test(expiredPlan.count == 0 && expiredPlan.excludedNonCandidates.count == 2,
             "read-only plan excludes process-expired selections from candidate items and totals")
    if case .unknown(let reason) = plan.recovery { try test(reason == "Total recoverable storage cannot be determined.", "APFS multi-item plan never sums uncertain sharing") }
    else { try test(false, "APFS multi-item plan never sums uncertain sharing") }
    try test(!plan.dependencies.isEmpty && plan.items.allSatisfy { $0.node.path.hasPrefix(fixture.root.path) }, "read-only plan retains consequences and exact target paths")
    let excluded = CleanupReviewPlan(entries: [active!])
    try test(excluded.count == 0 && excluded.excludedNonCandidates.count == 1, "read-only plan excludes Preserve entries")
    let parentNode = try await reader.node(id: fixture.ids["project"]!)!
    let parentInspection = ArtifactInspection(nodeID: parentNode.id, path: parentNode.path, collectedAt: Date(), elapsed: 0, identity: .verified,
        classification: cache.inspection!.classification, assessment: cache.inspection!.assessment, storage: cache.inspection!.storage, incomplete: [])
    let parentEntry = CleanupReviewQueueEntry(node: parentNode, inspection: parentInspection, journal: cache.freshness.journal, processes: cache.freshness.processObservation)
    let overlap = CleanupReviewPlan(entries: [cache, parentEntry])
    try test(overlap.count == 1 && overlap.items.first?.id == parentEntry.id && overlap.excludedOverlaps == [cache.node.path], "review plan excludes nested child paths before indexed accounting")
    let changedBatch = InventoryChangeBatch(available: true, journalID: "queue-fixture", latestSequence: 1, generation: 1, generationStale: false,
        changes: [.init(directoryID: parentNode.id, sequence: 1, subtree: true)], next: .init(journalID: "queue-fixture", sequence: 1), complete: true, mustResynchronize: false)
    let parentChanged = await queue.applyChanges(changedBatch)
    try test(parentChanged.entries.allSatisfy { !$0.freshness.invalidationReasons.isEmpty }, "relevant parent journal changes invalidate retained evidence")
    try test(try Data(contentsOf: fixture.database) == original, "queue discovery inspection and planning leave catalog byte-identical")
    let movedEnvironment = fixture.root.appendingPathComponent("environment-relocated")
    try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("environment"), to: movedEnvironment)
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("environment"), withIntermediateDirectories: true)
    try Data("version = 3.12\n".utf8).write(to: fixture.root.appendingPathComponent("environment/pyvenv.cfg"))
    let replacement = try await queue.refresh(nodeID: envID, reader: reader, environment: fixture.environment)
    try test(replacement?.inspection?.identity == .changed && replacement?.status == .insufficientEvidence, "queue replacement identity invalidates prior evidence")
    try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("project/node_modules"), to: fixture.root.appendingPathComponent("project/dependencies-relocated"))
    let moved = try await queue.refresh(nodeID: dependency.id, reader: reader, environment: fixture.environment)
    try test(moved?.inspection?.identity == .missing && moved?.status == .insufficientEvidence, "queue moved filesystem target loses its earlier assessment")
    // Delete only catalog rows in this disposable database; no real filesystem item is deleted.
    try fixture.write("DELETE FROM inventory_nodes WHERE id=?", [.integer(cacheID)])
    let missing = try await queue.refresh(nodeID: cacheID, reader: reader, environment: fixture.environment)
    let afterDeletion = await queue.snapshot()
    try test(missing == nil && !afterDeletion.entries.contains { $0.id == cacheID }, "queue drops candidates deleted from inventory")
    try fixture.exec("UPDATE inventory_generations SET active=0; INSERT INTO inventory_generations VALUES(2,'/fixture/empty',1,NULL,'available')")
    let generationPage = try await reader.cleanupDiscoveryPage(after: first.next, limit: 8)
    try test(generationPage.resynchronized && generationPage.generation == 2 && generationPage.nodes.isEmpty, "queue generation change resets keyset discovery safely")
    // Earlier discovery opened a read-only connection: these writes are confined to the fixture owner.
    try test(original.count > 0 && !FileManager.default.fileExists(atPath: fixture.database.path + "-wal"), "queue never enables WAL or writes catalog schema")

    let incremental = try CleanupQueueFixture(folder)
    _ = try incremental.file("project/README.txt")
    let incrementalReader = InventoryReader(path: incremental.database.path)
    let incrementalQueue = CleanupReviewQueue()
    var state = try await incrementalQueue.discoverNext(reader: incrementalReader, environment: incremental.environment)
    try test(state.progress.complete && state.entries.isEmpty, "initial discovery can complete with no candidates")
    _ = try incremental.file("project/__pycache__/new.pyc")
    let newCacheID = incremental.ids["project/__pycache__"]!
    try incremental.exec("UPDATE inventory_change_clock SET sequence=1; INSERT INTO inventory_changed_directories VALUES(\(incremental.ids["project"]!),1,1,0)")
    let change = try await incrementalReader.changes(since: state.journal)
    state = await incrementalQueue.applyChanges(change)
    try test(!state.progress.complete && state.progress.hasMore, "new committed directory change schedules bounded incremental discovery")
    let scannedBefore = state.progress.scannedRows
    for _ in 0..<10 {
        state = try await incrementalQueue.discoverNext(reader: incrementalReader, environment: incremental.environment)
        if state.progress.complete { break }
    }
    try test(state.entries.contains { $0.id == newCacheID && $0.status == .reviewCandidate }, "journal-driven listing discovers newly indexed candidate after completion")
    try test(state.progress.scannedRows - scannedBefore == 2, "incremental discovery reads changed listing only instead of restarting catalog")
    let listing = try await incrementalReader.cleanupListingDiscoveryPage(directoryID: incremental.ids["project"]!, after: nil, limit: 1)
    let following = try await incrementalReader.cleanupListingDiscoveryPage(directoryID: incremental.ids["project"]!, after: listing.next, limit: 1)
    try test(listing.scannedRows == 1 && listing.next != nil && following.scannedRows == 1 && following.next == nil, "changed-listing name keyset pagination is bounded and exhaustive")

    // A second event can insert a name before the current cursor in the same listing.
    // Acknowledge that event only while ensuring the new earlier child will be revisited.
    let changedListing = try CleanupQueueFixture(folder)
    _ = try changedListing.file("project/README.txt")
    for index in 0..<20 { _ = try changedListing.file(String(format: "project/ordinary-%02d.txt", index)) }
    let changedListingReader = InventoryReader(path: changedListing.database.path)
    let changedListingQueue = CleanupReviewQueue(budget: .init(rowsPerPage: 8))
    var listingState = await changedListingQueue.snapshot()
    for _ in 0..<20 {
        listingState = try await changedListingQueue.discoverNext(reader: changedListingReader, environment: changedListing.environment)
        if listingState.progress.complete { break }
    }
    let projectID = changedListing.ids["project"]!
    try changedListing.exec("UPDATE inventory_change_clock SET sequence=1; INSERT INTO inventory_changed_directories VALUES(\(projectID),1,1,0)")
    _ = await changedListingQueue.applyChanges(try await changedListingReader.changes(since: listingState.journal))
    listingState = try await changedListingQueue.discoverNext(reader: changedListingReader, environment: changedListing.environment)
    try test(!listingState.progress.complete, "changed listing has a pending name cursor before a second event")
    _ = try changedListing.file("project/__pycache__/new.pyc")
    let insertedBeforeCursor = changedListing.ids["project/__pycache__"]!
    try changedListing.exec("UPDATE inventory_change_clock SET sequence=2; UPDATE inventory_changed_directories SET sequence=2")
    _ = await changedListingQueue.applyChanges(try await changedListingReader.changes(since: listingState.journal))
    for _ in 0..<20 {
        listingState = try await changedListingQueue.discoverNext(reader: changedListingReader, environment: changedListing.environment)
        if listingState.progress.complete { break }
    }
    try test(listingState.progress.complete && listingState.entries.contains { $0.id == insertedBeforeCursor },
             "second listing event rewinds its cursor and discovers a newly inserted earlier name")
    let incompleteJournal = InventoryChangeBatch(available: true, journalID: "queue-fixture", latestSequence: 2, generation: 1, generationStale: false,
        changes: [], next: .init(journalID: "queue-fixture",sequence: 1), complete: false, mustResynchronize: false)
    let backlog = await incrementalQueue.applyChanges(incompleteJournal)
    await incrementalQueue.resume()
    let held = try await incrementalQueue.discoverNext(reader: incrementalReader, environment: incremental.environment)
    try test(backlog.progress.stopReason != nil && held.progress.stopReason == backlog.progress.stopReason && held.entries.allSatisfy { $0.status == .insufficientEvidence },
             "journal backlog stops incremental coverage until explicit indexed resynchronization")

    let absentJournal = try CleanupQueueFixture(folder)
    _ = try absentJournal.file("project/__pycache__/cache.pyc")
    try absentJournal.exec("DROP TABLE inventory_change_clock")
    let absentReader = InventoryReader(path: absentJournal.database.path), absentQueue = CleanupReviewQueue()
    var absent = try await absentQueue.discoverNext(reader: absentReader, environment: absentJournal.environment)
    for _ in 0..<10 where !absent.progress.complete { absent = try await absentQueue.discoverNext(reader: absentReader, environment: absentJournal.environment) }
    try test(!absent.entries.isEmpty && absent.entries.allSatisfy { $0.status == .insufficientEvidence }, "newly discovered candidates inherit missing-journal invalidation")
    let absentRefresh = try await absentQueue.refresh(nodeID: absent.entries[0].id, reader: absentReader, environment: absentJournal.environment)
    try test(absentRefresh?.status == .insufficientEvidence && absentRefresh!.recoverableBytes == nil, "selected refresh never promotes unavailable journal to fresh evidence")

    let unallocated = try CleanupQueueFixture(folder)
    _ = try unallocated.file("project/__pycache__/cache.pyc")
    try unallocated.exec("UPDATE inventory_nodes SET total_allocated=NULL")
    let unallocatedReader = InventoryReader(path: unallocated.database.path), unallocatedQueue = CleanupReviewQueue()
    var unallocatedState = try await unallocatedQueue.discoverNext(reader: unallocatedReader, environment: unallocated.environment)
    for _ in 0..<10 where !unallocatedState.progress.complete { unallocatedState = try await unallocatedQueue.discoverNext(reader: unallocatedReader, environment: unallocated.environment) }
    try test(!unallocatedState.entries.isEmpty && unallocatedState.entries.allSatisfy { $0.indexedAllocatedBytes == nil }, "unknown allocated size never substitutes known logical bytes")

    let interleaved = try CleanupQueueFixture(folder)
    _ = try interleaved.file("project/__pycache__/cache.pyc")
    for index in 0..<20 { _ = try interleaved.file("ordinary-\(index).txt") }
    let interleavedReader = InventoryReader(path: interleaved.database.path)
    let interleavedQueue = CleanupReviewQueue(budget: .init(rowsPerPage: 8))
    let beforeWriter = try await interleavedQueue.discoverNext(reader: interleavedReader, environment: interleaved.environment)
    try test(!beforeWriter.entries.isEmpty && beforeWriter.journal?.sequence == 0 && beforeWriter.cursor != nil, "between-page fixture starts with verified candidate and unconsumed journal baseline")
    try interleaved.exec("UPDATE inventory_change_clock SET sequence=1; INSERT INTO inventory_changed_directories VALUES(\(interleaved.ids["project"]!),1,1,0)")
    let laterPage = try await interleavedQueue.discoverNext(reader: interleavedReader, environment: interleaved.environment)
    try test(laterPage.journal?.sequence == 0 && laterPage.entries.allSatisfy { $0.status == .insufficientEvidence }, "later discovery page preserves consumed cursor and invalidates earlier evidence when writer commits")
    let pendingChange = try await interleavedReader.changes(since: laterPage.journal)
    try test(pendingChange.changes.count == 1 && pendingChange.next?.sequence == 1, "journal change between discovery pages remains consumable")
    _ = await interleavedQueue.applyChanges(pendingChange)

    let suspendedQueue = CleanupReviewQueue(budget: .init(rowsPerPage: 8))
    let suspendedReader = SuspendedCleanupQueueReader(interleavedReader)
    let awaitedPage = Task { try await suspendedQueue.discoverNext(reader: suspendedReader, environment: interleaved.environment) }
    await suspendedReader.waitUntilSuspended()
    let stop = InventoryChangeBatch(available: true,journalID: "new-journal",latestSequence: 2,generation: 1,generationStale: false,changes: [],
        next: .init(journalID: "new-journal",sequence: 2),complete: true,mustResynchronize: true)
    let stopped = await suspendedQueue.applyChanges(stop)
    await suspendedReader.releasePage()
    let afterAwait = try await awaitedPage.value
    try test(afterAwait.progress.scannedRows == 0 && afterAwait.entries.isEmpty && afterAwait.cursor == nil && afterAwait.progress.stopReason == stopped.progress.stopReason,
             "resynchronization during awaited page discards old result without advancing discovery or clearing stop")
    try test(afterAwait.journal?.journalID == "new-journal", "suspended page cannot overwrite newly applied journal identity")

    let changeQueue = CleanupReviewQueue(budget: .init(rowsPerPage: 8))
    _ = try await changeQueue.discoverNext(reader: interleavedReader, environment: interleaved.environment)
    let changeReader = SuspendedCleanupQueueReader(interleavedReader)
    let changeRead = Task { try await changeQueue.discoverNext(reader: changeReader, environment: interleaved.environment) }
    await changeReader.waitUntilSuspended()
    try interleaved.exec("UPDATE inventory_change_clock SET sequence=2; UPDATE inventory_changed_directories SET sequence=2")
    let changed = try await interleavedReader.changes(since: .init(journalID: "queue-fixture",sequence: 1))
    let changedState = await changeQueue.applyChanges(changed)
    await changeReader.releasePage()
    let afterConcurrentChange = try await changeRead.value
    try test(afterConcurrentChange.cursor == changedState.cursor && afterConcurrentChange.progress.scannedRows == changedState.progress.scannedRows
                && afterConcurrentChange.entries.allSatisfy { $0.status == .insufficientEvidence },
             "journal invalidation during awaited page preserves cursor and invalidation reasons")
}
