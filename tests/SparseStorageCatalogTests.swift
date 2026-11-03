import Foundation
import Darwin
import SQLite3

#if INVENTORY_TESTS
// Migration Readiness against real catalogs: sparse files created with ftruncate on APFS under /private/tmp, indexed by
// the real inventory worker, then detected through InventoryReader and checked with lstat. Thresholds are scaled to
// MiB so the fixture allocates almost nothing; the default GiB thresholds are covered by the model tests.
func sparseStorageCatalogTests(_ test: (Bool, String) throws -> Void) async throws {
    let MiB: Int64 = 1 << 20
    let thresholds = SparseStorageThresholds(reviewMinimumLogical: 64 * MiB, reviewMinimumGap: 32 * MiB, reviewMinimumRatio: 4, reportMinimumGap: 8 * MiB, reportMinimumRatio: 1.25)
    let root = "/private/tmp/storage-monitor-sparse-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state"), gatedState = URL(fileURLWithPath: root + "-gated-state")
    defer { _ = chmod(root + "/locked", 0o755); try? fm.removeItem(atPath: root); try? fm.removeItem(at: state); try? fm.removeItem(at: gatedState) }
    let home = root + "/home"
    for folder in ["home/Library/Containers/com.docker.docker/Data/vms/0/data", "home/.orbstack/data", "home/VMs", "home/Library/Mobile Documents/com~apple~CloudDocs",
                   "plain", "locked", "bundles/Archive.sparsebundle/bands", "bundles/Sparse.sparsebundle/bands"] {
        try fm.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
    }
    func sparse(_ path: String, _ logical: Int64, written: Int = 4_096) throws { try makeSparseFile(root + "/" + path, logical: logical, written: written) }
    try sparse("home/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", 256 * MiB, written: 65_536)
    try sparse("home/.orbstack/data/data.img", 128 * MiB)
    try sparse("home/VMs/server.qcow2", 40 * MiB)
    try sparse("home/Library/Mobile Documents/com~apple~CloudDocs/movie.mov", 128 * MiB)
    try Data(repeating: 0xA5, count: Int(16 * MiB)).write(to: URL(fileURLWithPath: root + "/plain/full.bin"))
    try sparse("plain/close.bin", 20 * MiB, written: Int(16 * MiB))
    try sparse("plain/zero.bin", 0, written: 0)
    try sparse("plain/hole.bin", 80 * MiB, written: 0)
    try sparse("plain/original.img", 96 * MiB, written: Int(MiB))
    try sparse("plain/gone.raw", 128 * MiB)
    try sparse("plain/grows.raw", 128 * MiB)
    try sparse("plain/replaced.raw", 128 * MiB)
    try sparse("plain/data.unknownformat", 72 * MiB)
    try sparse("locked/secret.raw", 128 * MiB)
    guard link(root + "/plain/hole.bin", root + "/plain/hardlink.bin") == 0 else { throw POSIXError(.EIO) }
    try fm.createSymbolicLink(atPath: root + "/plain/link.raw", withDestinationPath: root + "/plain/hole.bin")
    guard clonefile(root + "/plain/original.img", root + "/plain/clone.img", 0) == 0 else { throw POSIXError(.EIO) }
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleInfoDictionaryVersion": "6.0", "band-size": 8_388_608, "size": 1_099_511_627_776,
                                                                        "diskimage-bundle-type": "com.apple.diskimage.sparsebundle", "bundle-backingstore-version": 1], format: .xml, options: 0)
    // Archive: 8 MiB bands. Observed on APFS: a file of 16 MiB or less extended with ftruncate is fully allocated,
    // so these bands are not sparse and the bundle must not be reported, whatever its 1 TiB capacity says.
    // Sparse: 64 MiB bands with one 4 KiB write each stay sparse, so its band data is reported.
    for name in ["Archive", "Sparse"] {
        try plist.write(to: URL(fileURLWithPath: root + "/bundles/\(name).sparsebundle/Info.plist"))
        try Data(count: 0).write(to: URL(fileURLWithPath: root + "/bundles/\(name).sparsebundle/token"))
    }
    for band in 0..<8 { try sparse("bundles/Archive.sparsebundle/bands/\(band)", 8 * MiB) }
    for band in 0..<2 { try sparse("bundles/Sparse.sparsebundle/bands/\(band)", 64 * MiB) }

    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    let region = coverageRegion(root: root)!
    func run(_ db: String = database, _ directory: URL = state, gate: ConsentGate? = nil) {
        _ = runInventory(databasePath: db, directory: directory, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: gate == nil ? "granted" : nil, gatedOverride: gate)
    }
    run()
    func rows(_ sql: String, _ values: [Any] = []) throws -> [[String: String]] { try Database(database).rows(sql, values) }
    func int(_ sql: String, _ values: [Any] = []) throws -> Int64 { Int64(try rows(sql, values).first?.values.first ?? "") ?? 0 }
    try test(try int("SELECT COUNT(*) FROM inventory_nodes WHERE name IN ('Docker.raw','data.img','hole.bin','Archive.sparsebundle')") == 4,
             "sparse catalog: the real worker indexed the APFS fixture (sparse files and a sparse bundle)")

    // Changes after indexing, not yet seen by the catalog: the live check must notice them.
    _ = chmod(root + "/locked", 0o000)
    try fm.removeItem(atPath: root + "/plain/gone.raw")
    let grow = open(root + "/plain/grows.raw", O_WRONLY | O_CLOEXEC); _ = pwrite(grow, [UInt8](repeating: 1, count: Int(64 * MiB)), Int(64 * MiB), 0); _ = fsync(grow); close(grow)
    try fm.removeItem(atPath: root + "/plain/replaced.raw"); try sparse("plain/replaced.raw", 128 * MiB)

    func digest(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    let before = try digest(database)
    let rootTotals = try rows("SELECT total_logical,total_allocated FROM inventory_nodes WHERE parent_id IS NULL").first
    let detector = SparseStorageDetector(database: database, thresholds: thresholds, home: home, chunkSpan: 7, pauseNanoseconds: 0)
    let report = try await detector.refresh()
    let stats = await detector.statistics
    func item(_ name: String) -> SparseStorageItem? { report.items.first { $0.node.name == name } }

    // MARK: Read-only and accounting
    try test(try digest(database) == before && (try rows("SELECT total_logical,total_allocated FROM inventory_nodes WHERE parent_id IS NULL").first) == rootTotals,
             "sparse catalog: detection is read-only (catalog bytes identical) and root storage totals are unchanged")
    try test(stats.fullScans == 1 && stats.chunkReads > 3 && stats.idsSpanned == (try int("SELECT MAX(id) FROM inventory_nodes")),
             "sparse catalog: one full pass reads the catalog in bounded primary-key slices (\(stats.chunkReads) slices), never the filesystem tree")

    // MARK: Detection on real metadata
    let docker = item("Docker.raw"), orb = item("data.img"), hole = item("hole.bin"), qcow = item("server.qcow2")
    try test(docker?.severity == .review && docker?.kind.application == "Docker Desktop" && docker?.kind.category == .containerRuntime
             && docker?.allocation.logical == 256 * MiB && (docker?.allocation.allocated ?? .max) < MiB && { if case .notChecked? = docker?.verification { return true }; return false }(),
             "sparse catalog: Docker Desktop's image is REVIEW from indexed values, not checked live in its protected location")
    try test(orb?.severity == .review && orb?.kind.application == "OrbStack" && { if case .confirmed? = orb?.verification { return true }; return false }()
             && orb.map { $0.allocation.gap == $0.allocation.logical - $0.allocation.allocated } == true,
             "sparse catalog: OrbStack's image is REVIEW and confirmed by lstat; gap = logical − allocated")
    try test(hole?.severity == .review && hole?.allocation.allocated == 0 && hole?.allocation.ratio == nil && hole?.kind.category == .sparseFile,
             "sparse catalog: a file with zero allocation is reported safely (unbounded ratio)")
    try test(qcow?.severity == .informational && qcow?.kind.category == .virtualization && qcow?.kind.format == "QCOW2 virtual disk",
             "sparse catalog: a smaller sparse virtual disk is INFORMATIONAL, not REVIEW")
    try test(item("full.bin") == nil && item("close.bin") == nil && item("zero.bin") == nil, "sparse catalog: fully allocated, nearly allocated and zero-byte files are not reported")
    try test(report.items.filter { $0.node.identity.inode == hole?.node.identity.inode }.count == 1 && item("link.raw") == nil,
             "sparse catalog: a hard link is one item (no duplicate catalog entry) and a symbolic link is never followed or reported")
    let original = item("original.img"), clone = item("clone.img")
    try test(original != nil && clone != nil && original?.allocation == clone?.allocation && original?.node.identity.inode != clone?.node.identity.inode,
             "sparse catalog (APFS clone limitation): a clone reports its own allocation and appears as its own item; shared extents are not deduplicated")
    let unsupported = item("data.unknownformat")
    try test(unsupported?.kind.format == nil && unsupported?.kind.category == .sparseFile && unsupported?.severity == .review,
             "sparse catalog: an unsupported format is reported as a sparse file without a guessed format or capacity")
    let bundle = item("Sparse.sparsebundle")
    let bundleTotal = try int("SELECT total_logical FROM inventory_nodes WHERE name='Sparse.sparsebundle'")
    let archive = try rows("SELECT total_logical,total_allocated FROM inventory_nodes WHERE name='Archive.sparsebundle'").first
    try test(item("Archive.sparsebundle") == nil && Int64(archive?["total_allocated"] ?? "0")! >= Int64(archive?["total_logical"] ?? "1")!,
             "sparse catalog: a 1 TiB-capacity sparse bundle whose bands are fully allocated is not reported (capacity is never used as a size)")
    if ProcessInfo.processInfo.environment["SPARSE_DEBUG"] != nil { print("DEBUG bundle", bundle.map { "\($0.severity) \($0.allocation) \(String(describing: $0.bundle)) \($0.verification)" } ?? "absent", try rows("SELECT id,kind,status,total_logical,total_allocated FROM inventory_nodes WHERE name='Archive.sparsebundle'")) }
    try test(bundle?.kind.isSparseBundle == true && bundle?.bundle?.capacity == 1_099_511_627_776 && bundle?.allocation.logical == bundleTotal
             && bundleTotal >= 128 * MiB && bundleTotal < 129 * MiB && !report.items.contains { $0.node.path.contains("/bands/") },
             "sparse catalog: a sparse bundle reports its Info.plist capacity (1 TiB) separately from its band data (\(bundleTotal) bytes); bands are not listed")
    let secret = item("secret.raw")
    try test(secret?.severity == .unknown && secret?.kind.category == .diskImage && { if case .inaccessible? = secret?.verification { return true }; return false }(),
             "sparse catalog: a file macOS refuses to check is UNKNOWN, with its indexed values")
    try test(item("gone.raw") == nil && report.coverage.vanished == 1, "sparse catalog: a file deleted after indexing is dropped and counted")
    let grown = item("grows.raw")
    try test(grown?.severity == .informational && { if case .changedSinceIndexed? = grown?.verification { return true }; return false }() && (grown?.allocation.allocated ?? 0) >= 64 * MiB
             && (grown?.indexed.allocated ?? .max) < MiB, "sparse catalog: metadata that changed after indexing is re-evaluated on live values (REVIEW → INFORMATIONAL)")
    let replaced = item("replaced.raw")
    try test(replaced?.severity == .unknown && { if case .replaced? = replaced?.verification { return true }; return false }(),
             "sparse catalog: a file replaced after indexing (new identity) is UNKNOWN until the index catches up")
    try test(item("movie.mov") == nil && report.coverage.cloudLocations == 1, "sparse catalog: a large item in iCloud Drive is skipped (possible placeholder) and counted")
    try test(report.items.first?.severity == .review && report.items.map(\.severity.rank) == report.items.map(\.severity.rank).sorted()
             && report.headline?.node.name == "Docker.raw" && report.reviewCount == 7,
             "sparse catalog: review items come first, largest gap first; the Overview leads with the largest (\(report.reviewCount) to review)")
    try test(report.items.allSatisfy { $0.ancestors.first == (try? int("SELECT id FROM inventory_nodes WHERE parent_id IS NULL")) && !$0.ancestors.contains($0.id) },
             "sparse catalog: each item carries its real ancestry from the inventory root (for Migration Review paths)")
    try test(report.filesystem == "apfs", "sparse catalog: the fixture volume's filesystem is reported as APFS")

    let rechecked = await detector.recheck(orb!.id, maximumAge: 0)
    let afterRecheck = await detector.report
    try test(rechecked?.severity == .review && afterRecheck?.reviewCount == report.reviewCount && afterRecheck?.unknownCount == report.unknownCount
             && afterRecheck?.informationalCount == report.informationalCount,
             "sparse catalog: an Inspector recheck keeps the report's counts exact")

    // MARK: Cache: no unexpected rereads, then an incremental pass from the change journal
    let beforeQuiet = await detector.statistics
    let again = try await detector.refresh()
    let quiet = await detector.statistics
    try test(again.pass == .unchanged && quiet.chunkReads == stats.chunkReads && quiet.candidatesHydrated == stats.candidatesHydrated && quiet.directoryReads == stats.directoryReads
             && quiet.liveChecks - beforeQuiet.liveChecks == 2 && quiet.liveCacheHits > beforeQuiet.liveCacheHits && again.reviewCount == report.reviewCount,
             "sparse catalog: a pass with no catalog changes rereads no candidate; only the 2 failed checks are retried (cache hits \(quiet.liveCacheHits - beforeQuiet.liveCacheHits))")
    _ = chmod(root + "/locked", 0o755)
    try sparse("plain/new.raw", 200 * MiB)
    let fill = open(root + "/home/.orbstack/data/data.img", O_WRONLY | O_CLOEXEC); _ = pwrite(fill, [UInt8](repeating: 2, count: Int(128 * MiB)), Int(128 * MiB), 0); _ = fsync(fill); close(fill)
    try invalidateInventory(databasePath: database, paths: [root + "/plain", root + "/home/.orbstack/data", root + "/locked"], eventID: nil, gap: false, reason: "Filesystem activity")
    run()
    let updated = try await detector.refresh()
    let incremental = await detector.statistics
    func updatedItem(_ name: String) -> SparseStorageItem? { updated.items.first { $0.node.name == name } }
    try test(updated.pass == .incremental && incremental.fullScans == 1 && incremental.chunkReads == stats.chunkReads && incremental.directoryReads > quiet.directoryReads,
             "sparse catalog: changed folders are re-read from the change journal without a full rescan")
    try test(updatedItem("new.raw")?.severity == .review && updatedItem("data.img") == nil && { if case .confirmed? = updatedItem("replaced.raw")?.verification { return true }; return false }()
             && updatedItem("secret.raw")?.severity == .review && updatedItem("Docker.raw")?.severity == .review,
             "sparse catalog: the cache is invalidated by identity and size (new item added, filled image removed, replaced file confirmed) while unchanged items are kept")

    // MARK: Cancellation leaves the previous state untouched
    let slow = SparseStorageDetector(database: database, thresholds: thresholds, home: home, chunkSpan: 1, pauseNanoseconds: 20_000_000)
    let task = Task { try await slow.refresh() }
    try await Task.sleep(nanoseconds: 60_000_000)
    task.cancel()
    var cancelled = false
    do { _ = try await task.value } catch is CancellationError { cancelled = true } catch let error as InventoryReaderError { cancelled = error.description.contains("interrupt") }
    let afterCancel = await slow.report, cancelStats = await slow.statistics
    try test(cancelled && afterCancel == nil && cancelStats.fullScans == 0 && cancelStats.chunkReads > 0,
             "sparse catalog: cancelling a scan stops it between catalog reads and publishes nothing (\(cancelStats.chunkReads) slices read)")
    let resumed = try await SparseStorageDetector(database: database, thresholds: thresholds, home: home, pauseNanoseconds: 0).refresh()
    try test(resumed.reviewCount == updated.reviewCount, "sparse catalog: a new pass after cancellation completes normally")

    // MARK: Incomplete coverage: a protected application folder is never claimed clear
    try privateDirectory(gatedState)
    let gatedDatabase = gatedState.appendingPathComponent("history.sqlite3").path
    run(gatedDatabase, gatedState, gate: ConsentGate(exact: ["home/Library/Containers", "home/Library/Mobile Documents"], childrenOf: [:]))
    let gated = try await SparseStorageDetector(database: gatedDatabase, thresholds: thresholds, home: home, pauseNanoseconds: 0).refresh()
    try test(!gated.items.contains { $0.node.name == "Docker.raw" } && !gated.coverage.isComplete
             && gated.coverage.limitedLocations.contains { $0.application == "Docker Desktop" && $0.state == .protected }
             && gated.coverage.notes.contains { $0.contains("Docker Desktop") && $0.contains("protected") },
             "sparse catalog: when Docker Desktop's folder is protected, the report says it was not inspected instead of claiming it is clear")
    var empty: OpaquePointer?
    let emptyPath = gatedState.appendingPathComponent("empty.sqlite3").path
    _ = sqlite3_open(emptyPath, &empty); _ = sqlite3_exec(empty, "PRAGMA user_version=1", nil, nil, nil); sqlite3_close(empty)
    let uninitialized = try await SparseStorageDetector(database: emptyPath, thresholds: thresholds, home: home).refresh()
    try test(uninitialized.items.isEmpty && !uninitialized.coverage.inventoryAvailable && uninitialized.coverage.notes.first?.contains("has not started") == true,
             "sparse catalog: without an inventory nothing is claimed; the report says nothing was checked")
}
#endif
