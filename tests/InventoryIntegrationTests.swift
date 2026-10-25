import Foundation
import Darwin
import SQLite3

#if INVENTORY_TESTS
private struct OracleTotals {
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var files: Int64 = 0
    var directories: Int64 = 0
}

private func oracleTotals(_ path: String, device: dev_t, seen: inout Set<InventoryIdentity>) throws -> OracleTotals {
    var result = OracleTotals()
    guard let directory = opendir(path) else { throw Failure("oracle cannot open \(path): \(String(cString: strerror(errno)))") }
    defer { closedir(directory) }
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        var info = stat()
        guard fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure("oracle cannot stat \(path)/\(name)") }
        guard info.st_dev == device else { continue }
        let metadata = InventoryFilesystemMetadata(info)
        if metadata.kind == .directory {
            result.directories += 1
            let nested = try oracleTotals(path + "/" + name, device: device, seen: &seen)
            result.logical += nested.logical; result.allocated += nested.allocated
            result.files += nested.files; result.directories += nested.directories
        } else if seen.insert(metadata.identity).inserted {
            result.logical += metadata.logicalBytes; result.allocated += metadata.allocatedBytes
            if metadata.kind == .file { result.files += 1 }
        }
    }
    return result
}

private func directOracle(_ path: String, device: dev_t, seen: inout Set<InventoryIdentity>) throws -> OracleTotals {
    var result = OracleTotals()
    guard let directory = opendir(path) else { throw Failure("direct oracle cannot open \(path)") }
    defer { closedir(directory) }
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
        if name == "." || name == ".." { continue }
        var info = stat()
        guard fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure("direct oracle cannot stat \(name)") }
        let metadata = InventoryFilesystemMetadata(info)
        if metadata.kind == .directory { result.directories += 1 }
        else if info.st_dev == device && seen.insert(metadata.identity).inserted {
            result.logical += metadata.logicalBytes; result.allocated += metadata.allocatedBytes
            if metadata.kind == .file { result.files += 1 }
        }
    }
    return result
}

private func integrationFixture(_ test: (Bool, String) throws -> Void) async throws {
    let root = "/private/tmp/storage-monitor-inventory-integration-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { _ = chmod(root + "/perm-zero", 0o700); _ = chmod(root + "/metadata-denied", 0o700); try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try privateDirectory(state)
    for path in ["a/sub", "b", "metrics", "empty", "large", "allocation", "deleteTree", "perm-zero", "metadata-denied"] {
        try fm.createDirectory(atPath: root + "/" + path, withIntermediateDirectories: true)
    }
    try Data(repeating: 1, count: 12_345).write(to: URL(fileURLWithPath: root + "/a/sub/child"))
    try Data(repeating: 1, count: 321).write(to: URL(fileURLWithPath: root + "/a/sub/child.bin"))
    try Data(repeating: 2, count: 40_000).write(to: URL(fileURLWithPath: root + "/a/hard"))
    try required(link(root + "/a/hard", root + "/b/hard-alias") == 0, "create integration hard link")
    try Data(repeating: 3, count: 7_777).write(to: URL(fileURLWithPath: root + "/metrics/plain"))
    try fm.createSymbolicLink(atPath: root + "/metrics/symlink", withDestinationPath: "../a/sub/child")
    for index in 0..<530 { try Data([UInt8(index & 255)]).write(to: URL(fileURLWithPath: root + "/large/item-\(String(format: "%04d", index))")) }
    for index in 0..<300 {
        let path = root + "/deleteTree/d\(index)"
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: path + "/payload"))
    }
    try Data(count: 2_048).write(to: URL(fileURLWithPath: root + "/perm-zero/hidden"))
    try Data(count: 3_072).write(to: URL(fileURLWithPath: root + "/metadata-denied/hidden"))
    let sparsePath = root + "/allocation/sparse"
    try Data().write(to: URL(fileURLWithPath: sparsePath))
    let sparse = try FileHandle(forWritingTo: URL(fileURLWithPath: sparsePath))
    try sparse.truncate(atOffset: 8 * 1_024 * 1_024); try sparse.close()
    try Data(repeating: 7, count: 65_536).write(to: URL(fileURLWithPath: root + "/allocation/original"))
    let cloned = clonefile(root + "/allocation/original", root + "/allocation/clone", 0) == 0

    guard let region = coverageRegion(root: root) else { throw Failure("fixture is not on the startup Data volume") }
    var rootInfo = stat(); try required(lstat(root, &rootInfo) == 0, "stat fixture")
    let databasePath = state.appendingPathComponent("history.sqlite3").path
    let database = try Database(databasePath)
    try database.write("INSERT INTO readings(id,timestamp,container,free,used,volumes) VALUES (1,1,'fixture',10,20,'[]')")
    let emptyReader = InventoryReader(path: databasePath)
    let emptyStatus = try await emptyReader.status(), missingRoot = try await emptyReader.root()
    try test(emptyStatus.state == "uninitialized" && missingRoot == nil, "legacy history opens as an uninitialized inventory without SQL errors or migrations")

    let interrupted = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, batchSize: 13, stopAfterEntries: 19), fdaOverride: "granted")
    try test(interrupted.outcome == "interrupted" && inventoryNeedsWork(databasePath: databasePath), "cancel boundary persists resumable directory state")
    let completed = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 90, batchSize: 41), fdaOverride: "granted")
    try test(completed.outcome == "complete", "reopened worker resumes without persistent telldir cookies")

    func rows(_ sql: String, _ values: [Any] = []) throws -> [[String:String]] { try Database(databasePath).rows(sql, values) }
    var seen = Set<InventoryIdentity>()
    let oracle = try oracleTotals(root, device: rootInfo.st_dev, seen: &seen)
    let rootRow = try rows("SELECT direct_logical,direct_allocated,total_logical,total_allocated,child_count,descendant_files,descendant_directories,status FROM inventory_nodes WHERE parent_id IS NULL").first!
    let sparseRow = try rows("SELECT total_logical,total_allocated FROM inventory_nodes WHERE name='sparse'").first!
    try test(Int64(sparseRow["total_logical"]!) == 8 * 1_024 * 1_024 && Int64(sparseRow["total_allocated"]!)! < Int64(sparseRow["total_logical"]!)!, "sparse files preserve logical size separately from file allocation")
    if cloned {
        let clones = try rows("SELECT object_id,total_logical FROM inventory_nodes WHERE name IN ('original','clone')")
        try test(clones.count == 2 && Set(clones.compactMap { $0["object_id"] }).count == 2 && clones.allSatisfy { $0["total_logical"] == "65536" }, "APFS clones remain distinct objects without claiming shared blocks are reclaimable")
    }
    try test(Int64(rootRow["total_logical"]!) == oracle.logical && Int64(rootRow["total_allocated"]!) == oracle.allocated && Int64(rootRow["descendant_files"]!) == oracle.files && Int64(rootRow["descendant_directories"]!) == oracle.directories, "root totals match independent lstat oracle with hard links counted once (inventory logical=\(rootRow["total_logical"] ?? "nil") allocated=\(rootRow["total_allocated"] ?? "nil") files=\(rootRow["descendant_files"] ?? "nil") directories=\(rootRow["descendant_directories"] ?? "nil"); oracle logical=\(oracle.logical) allocated=\(oracle.allocated) files=\(oracle.files) directories=\(oracle.directories))")
    let namespaceCount = try rows("SELECT (SELECT descendant_entries FROM inventory_nodes WHERE parent_id IS NULL) AS descendants,(SELECT COUNT(*)-1 FROM inventory_nodes) AS entries").first!
    try test(namespaceCount["descendants"] == namespaceCount["entries"], "descendant entry count includes symlinks and hard-link names without duplicating allocated bytes")
    var directSeen = Set<InventoryIdentity>()
    let metricsOracle = try directOracle(root + "/metrics", device: rootInfo.st_dev, seen: &directSeen)
    let metrics = try rows("SELECT id,direct_logical,direct_allocated,total_logical,total_allocated,child_count FROM inventory_nodes WHERE name='metrics'").first!
    try test(Int64(metrics["direct_logical"]!) == metricsOracle.logical && Int64(metrics["direct_allocated"]!) == metricsOracle.allocated && metrics["direct_logical"] == metrics["total_logical"] && metrics["child_count"] == "2", "direct totals include file and symlink metadata but exclude directory inode overhead")
    let empty = try rows("SELECT direct_logical,direct_allocated,total_logical,total_allocated,child_count,status FROM inventory_nodes WHERE name='empty'").first!
    try test(empty["direct_logical"] == "0" && empty["direct_allocated"] == "0" && empty["total_logical"] == "0" && empty["total_allocated"] == "0" && empty["child_count"] == "0" && empty["status"] == "complete", "empty directory is a complete zero with parent-child integrity")
    try fm.removeItem(atPath: root + "/empty")
    try requestInventoryRefresh(databasePath: databasePath, paths: [region.root + "/empty"], reason: "removed directory direct refresh")
    let removedDirectory = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    try test(removedDirectory.outcome == "complete" && (try rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name='empty'").first?["n"]) == "0" && !inventoryNeedsWork(databasePath: databasePath), "direct refresh of an absent directory relists its parent and prunes the durable entry")

    // Updating a non-owner hard-link name must refresh the remote owner's aggregates, and deleting
    // the owner must transfer accounting without leaving an unscheduled stale directory behind.
    let hardlinks = try rows("SELECT n.name,p.name AS parent,(o.owner_node_id=n.id) AS owner FROM inventory_nodes n JOIN inventory_nodes p ON p.id=n.parent_id JOIN inventory_objects o ON o.id=n.object_id WHERE n.name IN ('hard','hard-alias')")
    let hardlinkOwner = hardlinks.first { $0["owner"] == "1" }!
    let hardlinkAlias = hardlinks.first { $0["owner"] == "0" }!
    let aliasID = Int64(try rows("SELECT id FROM inventory_nodes WHERE name=?", [hardlinkAlias["name"]!]).first!["id"]!)!
    let aliasMetadata = try await InventoryReader(path: databasePath).node(id: aliasID)!
    try test(aliasMetadata.isHardlinkAlias && aliasMetadata.logicalBytes == 0 && (aliasMetadata.objectLogicalBytes ?? 0) > 0 && aliasMetadata.objectAllocatedBytes != nil, "hard-link names retain actual file metadata independently of their zero duplicate storage contribution")
    let ownerDirectoryBefore = try rows("SELECT total_logical FROM inventory_nodes WHERE name=? AND kind='directory'", [hardlinkOwner["parent"]!]).first!
    let rootBeforeHardlinkMutation = try rows("SELECT total_logical FROM inventory_nodes WHERE parent_id IS NULL").first!
    let aliasPath = root + "/\(hardlinkAlias["parent"]!)/\(hardlinkAlias["name"]!)"
    let aliasHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: aliasPath))
    try aliasHandle.seekToEnd(); try aliasHandle.write(contentsOf: Data(count: 8_193)); try aliasHandle.close()
    try invalidateInventory(databasePath: databasePath, paths: [root + "/\(hardlinkAlias["parent"]!)"], eventID: 190, gap: false, reason: "non-owner hard-link mutation", deviceIdentifier: "integration")
    let hardlinkMutation = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 45), fdaOverride: "granted")
    let ownerDirectoryAfter = try rows("SELECT total_logical FROM inventory_nodes WHERE name=? AND kind='directory'", [hardlinkOwner["parent"]!]).first!
    let rootAfterHardlinkMutation = try rows("SELECT total_logical FROM inventory_nodes WHERE parent_id IS NULL").first!
    try test(hardlinkMutation.outcome == "complete" && Int64(ownerDirectoryAfter["total_logical"]!)! == Int64(ownerDirectoryBefore["total_logical"]!)! + 8_193 && Int64(rootAfterHardlinkMutation["total_logical"]!)! == Int64(rootBeforeHardlinkMutation["total_logical"]!)! + 8_193, "mutating a non-owner hard link refreshes owner-directory and root aggregates")

    try fm.removeItem(atPath: root + "/\(hardlinkOwner["parent"]!)/\(hardlinkOwner["name"]!)")
    try invalidateInventory(databasePath: databasePath, paths: [root + "/\(hardlinkOwner["parent"]!)"], eventID: 191, gap: false, reason: "hard-link owner deletion", deviceIdentifier: "integration")
    let ownerDeletion = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 45), fdaOverride: "granted")
    let remainingHardlink = try rows("SELECT n.name,(o.owner_node_id=n.id) AS owner FROM inventory_nodes n JOIN inventory_objects o ON o.id=n.object_id WHERE n.name IN ('hard','hard-alias')")
    try test(ownerDeletion.outcome == "complete" && !inventoryNeedsWork(databasePath: databasePath) && remainingHardlink.count == 1 && remainingHardlink[0]["owner"] == "1", "deleting a cross-directory hard-link owner transfers accounting and reaches a terminal state")

    // Ordinary mutations and stable namespace identities.
    let subID = try rows("SELECT id FROM inventory_nodes WHERE name='sub'").first!["id"]!
    let childID = try rows("SELECT id FROM inventory_nodes WHERE name='child'").first!["id"]!
    try Data(repeating: 4, count: 5_000).write(to: URL(fileURLWithPath: root + "/a/created"))
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/a/sub/child")); try handle.seekToEnd(); try handle.write(contentsOf: Data(count: 1_111)); try handle.close()
    try fm.removeItem(atPath: root + "/metrics/plain")
    try invalidateInventory(databasePath: databasePath, paths: [root + "/a", root + "/a/sub", root + "/metrics"], eventID: 200, gap: false, reason: "file mutations", deviceIdentifier: "integration")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 45), fdaOverride: "granted")
    try test((try rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name='created'").first?["n"]) == "1" && (try rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name='plain'").first?["n"]) == "0" && (try rows("SELECT total_logical FROM inventory_nodes WHERE name='child'").first?["total_logical"]) == "13456", "create, modify, and delete regular files reconcile exactly")

    let replacePath = root + "/replace"
    try fm.createDirectory(atPath: replacePath, withIntermediateDirectories: true)
    for index in 0..<321 { try Data([1]).write(to: URL(fileURLWithPath: replacePath + "/old-\(index)")) }
    try invalidateInventory(databasePath: databasePath, paths: [root], eventID: nil, gap: false, reason: "replacement fixture")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    try fm.removeItem(atPath: replacePath)
    try fm.createDirectory(atPath: replacePath, withIntermediateDirectories: true)
    try Data([2]).write(to: URL(fileURLWithPath: replacePath + "/new-entry"))
    // Refreshing the replaced directory alone must first repair its parent's identity.
    try invalidateInventory(databasePath: databasePath, paths: [replacePath], eventID: nil, gap: false, reason: "directory replaced in place")
    let replacedDirectory = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    try test(replacedDirectory.outcome == "complete" && (try rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name LIKE 'old-%'").first?["n"]) == "0" && (try rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name='new-entry'").first?["n"]) == "1", "replacement directory discards old checkpoints and prunes more than 256 obsolete children")
    try fm.removeItem(atPath: replacePath); try Data(count: 24_576).write(to: URL(fileURLWithPath: replacePath))
    try invalidateInventory(databasePath: databasePath, paths: [root], eventID: nil, gap: false, reason: "directory replaced by file")
    let replacedFile = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let replacementRow = try rows("SELECT kind,total_logical,child_count FROM inventory_nodes WHERE name='replace'").first!
    try test(replacedFile.outcome == "complete" && replacementRow["kind"] == "file" && replacementRow["total_logical"] == "24576" && replacementRow["child_count"] == "0" && (try rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name='new-entry'").first?["n"]) == "0", "directory-to-file replacement removes stale descendants without replacing file size with old directory totals")

    try fm.moveItem(atPath: root + "/a/sub", toPath: root + "/a/renamed")
    try invalidateInventory(databasePath: databasePath, paths: [root + "/a"], eventID: 201, gap: false, reason: "same-parent rename", deviceIdentifier: "integration")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 45), fdaOverride: "granted")
    try test((try rows("SELECT id FROM inventory_nodes WHERE name='renamed'").first?["id"]) == subID && (try rows("SELECT id FROM inventory_nodes WHERE name='child'").first?["id"]) == childID, "same-parent rename preserves directory and descendant IDs")
    try fm.moveItem(atPath: root + "/a/renamed", toPath: root + "/b/sub")
    try invalidateInventory(databasePath: databasePath, paths: [root + "/a", root + "/b"], eventID: 202, gap: false, reason: "cross-parent move", deviceIdentifier: "integration")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 45), fdaOverride: "granted")
    let moved = try rows("SELECT n.id,p.name AS parent FROM inventory_nodes n JOIN inventory_nodes p ON p.id=n.parent_id WHERE n.name='sub'").first!
    try test(moved["id"] == subID && moved["parent"] == "b" && (try rows("SELECT id FROM inventory_nodes WHERE name='child'").first?["id"]) == childID, "old-parent-first cross-parent move preserves subtree identity")

    let beforeRelist = try rows("SELECT total_logical,total_allocated,measured_at FROM inventory_nodes WHERE id=?", [Int64(subID)!]).first!
    try invalidateInventory(databasePath: databasePath, paths: [root + "/b"], eventID: 203, gap: false, reason: "parent only", deviceIdentifier: "integration")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let afterRelist = try rows("SELECT total_logical,total_allocated,measured_at FROM inventory_nodes WHERE id=?", [Int64(subID)!]).first!
    try test(beforeRelist == afterRelist, "parent relist preserves unchanged child aggregates and measurement time")

    // Gap invalidation is visible to readers before reconciliation and inherited by descendants.
    try invalidateInventory(databasePath: databasePath, paths: [root + "/b"], eventID: 204, gap: true, reason: "controlled gap", deviceIdentifier: "integration")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 0), fdaOverride: "granted")
    let staleReader = InventoryReader(path: databasePath)
    let staleChild = try await staleReader.node(id: Int64(childID)!)
    try test(staleChild?.status == .stale && staleChild?.coverageState == "stale" && staleChild?.logicalBytes == nil && staleChild?.allocatedBytes == nil, "stale gap ancestry hides prior byte totals before reconciliation")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 90), fdaOverride: "granted")

    // Replay overhead must not consume the new-work budget forever on a large prefix.
    try requestInventoryRefresh(databasePath: databasePath, paths: [root + "/large"], reason: "resume budget")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, batchSize: 64, stopAfterEntries: 500), fdaOverride: "granted")
    var resumeChecks = 0
    let replayBudget = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 0.02, batchSize: 8), fdaOverride: "granted") {
        resumeChecks += 1
        if resumeChecks == 3 { Thread.sleep(forTimeInterval: 0.04) }
        return false
    }
    try test(resumeChecks >= 3 && replayBudget.entries > 0, "reopened committed prefix cannot exhaust every new-work budget without progress")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")

    // A mutation between batches invalidates the open listing; the next process resumes safely.
    try requestInventoryRefresh(databasePath: databasePath, paths: [root + "/large"], reason: "batch mutation")
    var callbacks = 0, mutated = false
    let changed = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, batchSize: 16), fdaOverride: "granted") {
        callbacks += 1
        if callbacks == 3 { try? Data([9]).write(to: URL(fileURLWithPath: root + "/large/inserted-between-batches")); mutated = true }
        return callbacks >= 5
    }
    try test(mutated && changed.outcome == "interrupted" && inventoryNeedsWork(databasePath: databasePath), "directory mutation between bounded batches remains resumable and incomplete")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60, batchSize: 23), fdaOverride: "granted")
    try test((try rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name='inserted-between-batches'").first?["n"]) == "1", "resume after reopened handle captures between-batch mutation")

    // Permission and metadata failures stay unknown and recover after explicit refresh.
    _ = chmod(root + "/perm-zero", 0)
    _ = chmod(root + "/metadata-denied", 0o400)
    try requestInventoryRefresh(databasePath: databasePath, paths: [root + "/perm-zero", root + "/metadata-denied"], reason: "permissions")
    let partial = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 45), fdaOverride: "granted")
    let denied = try rows("SELECT name,status,total_logical,total_allocated FROM inventory_nodes WHERE name IN ('perm-zero','metadata-denied')")
    // A folder that cannot be opened stays unknown. A folder whose names are readable but whose entries'
    // metadata is refused is listed (D1): the refused entries are unknown and the folder is a lower bound.
    let hidden = try rows("SELECT status,reason,total_logical FROM inventory_nodes WHERE name='hidden'").first ?? [:]
    try test(partial.outcome == "partial" && denied.first { $0["name"] == "perm-zero" }.map { $0["status"] == "unknown" && $0["total_logical"] == nil && $0["total_allocated"] == nil } == true
             && denied.first { $0["name"] == "metadata-denied" }?["status"] == "partial" && hidden["status"] == "unknown" && hidden["reason"] == "metadata:permissions" && hidden["total_logical"] == nil,
             "permission and metadata failures are unknown rather than complete zeroes; a readable folder with refused entry metadata is listed as a lower bound")
    _ = chmod(root + "/perm-zero", 0o700); _ = chmod(root + "/metadata-denied", 0o700)
    try requestInventoryRefresh(databasePath: databasePath, paths: [root + "/perm-zero", root + "/metadata-denied"], reason: "permission recovery")
    let recovered = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 60), fdaOverride: "granted")
    try test(recovered.outcome == "complete" && (try rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name IN ('perm-zero','metadata-denied') AND status='complete'").first?["n"]) == "2", "explicit refresh recovers both permission fixtures")

    // Delete a subtree larger than one prune batch.
    try fm.removeItem(atPath: root + "/deleteTree")
    try invalidateInventory(databasePath: databasePath, paths: [root], eventID: 205, gap: false, reason: "interrupted deletion", deviceIdentifier: "integration")
    // Stop just after the parent listing commits, before deferred pruning can run.
    var deleteChecks = 0
    let deferredDelete = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted") {
        deleteChecks += 1; return deleteChecks >= 3
    }
    let pendingDeleteRoot = try await InventoryReader(path: databasePath).root()
    try test(deferredDelete.outcome == "interrupted" && pendingDeleteRoot?.status == .stale && pendingDeleteRoot?.allocatedBytes == nil && inventoryNeedsWork(databasePath: databasePath), "interruption before pruning never publishes deleted subtree totals as complete")
    try invalidateInventory(databasePath: databasePath, paths: [root], eventID: 205, gap: false, reason: "large deletion", deviceIdentifier: "integration")
    let deleted = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 90, batchSize: 47), fdaOverride: "granted")
    try test(deleted.outcome == "complete" && (try rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name='deleteTree'").first?["n"]) == "0" && (try rows("SELECT (SELECT COUNT(*) FROM inventory_tombstones)+(SELECT COUNT(*) FROM inventory_prune_jobs) AS n").first?["n"]) == "0", "large subtree deletion drains bounded prune queues")

    // Pagination, prefix/path search, largest scopes, and the existing async reader contract.
    let reader = InventoryReader(path: databasePath)
    let identity = try await reader.root()!.identity
    if let volume = identity.volumeUUID {
        let remounted = InventoryIdentity(device: identity.device + 1, inode: identity.inode, birthNanoseconds: identity.birthNanoseconds, volumeUUID: volume)
        try test(identity.stableKey == remounted.stableKey, "volume UUID, inode and birth time preserve the public identity key across device-number changes")
    }
    let largeID = Int64(try rows("SELECT id FROM inventory_nodes WHERE name='large'").first!["id"]!)!
    let page1 = try await reader.children(parentID: largeID, offset: 0, limit: 64, sort: .name)
    let page2 = try await reader.children(parentID: largeID, offset: 64, limit: 64, sort: .name)
    let prefix = try await reader.search(text: "item-01", under: largeID, offset: 0, limit: 17)
    let pathSearch = try await reader.search(text: "b/sub/chi", under: nil, offset: 0, limit: 10)
    let globalLargest = try await reader.largest(kind: .files, under: nil, offset: 0, limit: 5)
    let scopedLargest = try await reader.largest(kind: .files, under: largeID, offset: 0, limit: 5)
    try test(page1.items.count == 64 && page1.hasMore && Set(page1.items.map(\.id)).isDisjoint(with: page2.items.map(\.id)) && prefix.items.count == 17 && prefix.hasMore, "large-folder pagination and prefix limits are stable")
    try test(pathSearch.items.contains { $0.name == "child" } && !globalLargest.items.isEmpty && scopedLargest.items.allSatisfy { $0.path.hasPrefix(region.root + "/large/") }, "relative path search and global/scoped largest queries respect scope")
    try await inventoryReaderSelfTest(databasePath: databasePath, rootPath: region.root, test)

    // Immutable request files preserve pause/resume ordering and operational files stay excluded.
    let pauseID = try InventoryRequests.enqueue(database: databasePath, action: "pause")
    let paused = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 1, cancelFile: state.appendingPathComponent("inventory.cancel").path), fdaOverride: "granted")
    let resumeID = try InventoryRequests.enqueue(database: databasePath, action: "resume")
    let requests = try fm.contentsOfDirectory(at: InventoryRequests.directory(database: databasePath), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    try test(paused.reason == "cancelled" && pauseID != resumeID && requests.count >= 2 && !fm.fileExists(atPath: state.appendingPathComponent("inventory.cancel").path), "pause and resume use distinct durable requests and resume clears cancellation")

    // Capacity writes and read-only inventory queries coexist on separate short connections.
    try requestInventoryRefresh(databasePath: databasePath, paths: [root + "/large"], reason: "concurrency")
    let group = DispatchGroup(), queue = DispatchQueue(label: "inventory-integration-concurrency", attributes: .concurrent)
    let resultLock = NSLock(); var writeFailures = 0, readFailures = 0
    group.enter(); queue.async {
        defer { group.leave() }
        _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 20, batchSize: 19, pause: 0.0005), fdaOverride: "granted")
    }
    group.enter(); queue.async {
        defer { group.leave() }
        for index in 0..<40 {
            do { try Database(databasePath).write("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES (?,?,?,?,?)", [Double(100 + index),"concurrent",Int64(index),Int64(index),"[]"]) }
            catch { resultLock.lock(); writeFailures += 1; resultLock.unlock() }
        }
    }
    group.enter(); queue.async {
        defer { group.leave() }
        for _ in 0..<40 {
            do { _ = try Database(databasePath).rows("SELECT COUNT(*) AS n FROM readings"); _ = try Database(databasePath).rows("SELECT COUNT(*) AS n FROM inventory_nodes") }
            catch { resultLock.lock(); readFailures += 1; resultLock.unlock() }
        }
    }
    let concurrentFinished = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: group.wait(timeout: .now() + 30) == .success) }
    }
    try test(concurrentFinished, "concurrent monitor and inventory work finishes within bounded wait")
    let capacityRows = Int(try rows("SELECT COUNT(*) AS n FROM readings").first!["n"]!)!
    try test(writeFailures == 0 && readFailures == 0 && capacityRows == 41, "concurrent capacity rows are preserved while inventory readers and writer run")

    // Canonical Data-volume/firmlink forms resolve to one region identity.
    let canonical = dataRelative(region.root, mount: region.mount)
    let alternate = dataRelative(displayPath(region.deviceRelative(""), mount: region.mount), mount: region.mount)
    try test(canonical == alternate && region.relative(fromDevice: region.deviceRelative("b/sub/child")) == "b/sub/child", "canonical and display path forms map to one inventory namespace")

    let oldRootID = try await reader.root()!.id
    try requestInventoryRefresh(databasePath: databasePath, paths: [root], reason: "superseded pending work")
    _ = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 0), fdaOverride: "granted")
    let replacement = root + "-replacement"
    try fm.createDirectory(atPath: replacement, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: replacement) }
    try Data([1]).write(to: URL(fileURLWithPath: replacement + "/replacement-file"))
    let replacementRegion = coverageRegion(root: replacement)!
    let replaced = runInventory(databasePath: databasePath, directory: state, region: replacementRegion, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let obsolete = try await reader.node(id: oldRootID)
    let obsoleteChildren = try await reader.children(parentID: oldRootID)
    try test(replaced.outcome == "complete" && obsolete == nil && obsoleteChildren.items.isEmpty && !inventoryNeedsWork(databasePath: databasePath), "generation replacement hides superseded nodes and ignores their unfinished jobs")
}

private func legacyMigrationTest(_ test: (Bool, String) throws -> Void) throws {
    let folder = URL(fileURLWithPath: "/private/tmp/storage-monitor-inventory-legacy-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: folder) }
    try privateDirectory(folder)
    let path = folder.appendingPathComponent("history.sqlite3").path
    let db = try Database(path)
    try db.write("INSERT INTO readings(id,timestamp,container,free,used,volumes) VALUES (7,1,'keep',2,3,'[]')")
    try db.write("INSERT INTO alerts(id,timestamp,severity,reasons,free,delta,notification) VALUES (8,1,'warning','keep',2,1,'sent')")
    try db.write("INSERT INTO diagnostics(id,timestamp,snapshot) VALUES (9,1,'keep')")
    try db.write("INSERT INTO state(key,value) VALUES ('keep','state')")
    try db.write("INSERT INTO interval_evidence(reading_id,timestamp,evidence) VALUES (7,1,'keep')")
    try db.write("INSERT INTO coverage_units(path,depth,kind,state,discovered_at) VALUES ('keep',1,'tree','pending',1)")
    try db.write("INSERT INTO coverage_epochs(timestamp,reading_id,scope,detail) VALUES (1,7,'folders','keep')")
    try initializeInventorySchema(databasePath: path)
    let checks = ["readings":"id=7", "alerts":"id=8", "diagnostics":"id=9", "state":"key='keep'", "interval_evidence":"reading_id=7", "coverage_units":"path='keep'", "coverage_epochs":"reading_id=7"]
    try test(try checks.allSatisfy { try db.rows("SELECT 1 FROM \($0.key) WHERE \($0.value)").count == 1 } && (try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes").first?["n"]) == "0", "additive migration preserves every existing monitor and coverage table without backfill claims")
}

private func statsTriggerMigrationTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-stats-trigger-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/child", withIntermediateDirectories: true)
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    let region = coverageRegion(root: root)!
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let db = try Database(database)
    let guardSQL = "WHEN OLD.kind<>NEW.kind OR OLD.status<>NEW.status"
    let canonical = try db.rows("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='inventory_nodes_stats_update'").first!["sql"]!
    let legacy = canonical.replacingOccurrences(of: guardSQL, with: "")
    try db.write("DROP TRIGGER inventory_nodes_stats_update")
    try db.write(legacy)
    let statsBefore = try db.rows("SELECT total_nodes,completed_directories,pending_directories,stale_directories,unknown_directories FROM inventory_stats").first!
    try initializeInventorySchema(databasePath: database)
    let upgraded = try db.rows("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='inventory_nodes_stats_update'").first!["sql"]!
    let statsAfter = try db.rows("SELECT total_nodes,completed_directories,pending_directories,stale_directories,unknown_directories FROM inventory_stats").first!
    try test(upgraded.contains(guardSQL) && statsAfter == statsBefore,
             "inventory stats trigger upgrades once without changing existing counters")

    let rootNode = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE parent_id IS NULL").first!["id"]!)!
    // These counts measure the stats trigger alone. The change journal's own trigger writes (clock, changed
    // directory, size-signal baseline) are verified in InventoryChangeJournalTests, so its triggers are removed here.
    for (name, _) in inventoryChangeJournalTriggers { try db.write("DROP TRIGGER IF EXISTS \(name)") }
    let noOpBefore = sqlite3_total_changes(db.db)
    try db.write("UPDATE inventory_nodes SET kind=kind,status=status WHERE id=?", [rootNode])
    let noOpChanges = sqlite3_total_changes(db.db) - noOpBefore
    try test(noOpChanges == 1, "unchanged kind and status update only the node row, not inventory stats")

    let transitionBefore = sqlite3_total_changes(db.db)
    try db.write("UPDATE inventory_nodes SET status='stale' WHERE id=?", [rootNode])
    let transitionChanges = sqlite3_total_changes(db.db) - transitionBefore
    let transitioned = try db.rows("SELECT completed_directories,stale_directories FROM inventory_stats").first!
    try test(transitionChanges == 2 && Int64(transitioned["completed_directories"]!) == Int64(statsBefore["completed_directories"]!)! - 1 && Int64(transitioned["stale_directories"]!) == Int64(statsBefore["stale_directories"]!)! + 1,
             "real directory status transition updates exactly one inventory stats bucket row")
}

private func reconcileHorizonMigrationTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-horizon-migration-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/child", withIntermediateDirectories: true)
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    let region = coverageRegion(root: root)!
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let db = try Database(database)
    let rootRow = try db.rows("SELECT id,generation_id FROM inventory_nodes WHERE parent_id IS NULL").first!
    let rootNode = Int64(rootRow["id"]!)!, generation = Int64(rootRow["generation_id"]!)!
    try db.write("INSERT INTO inventory_reconcile(root_node_id,generation_id,reason,created_at,last_node_id,end_node_id) VALUES (?,?,'legacy pass',1,?,0)", [rootNode,generation,rootNode])
    try db.write("ALTER TABLE inventory_reconcile DROP COLUMN end_node_id")
    try initializeInventorySchema(databasePath: database)
    let migrated = try db.rows("SELECT reason,last_node_id,end_node_id FROM inventory_reconcile WHERE root_node_id=?", [rootNode]).first!
    let maximum = try db.rows("SELECT MAX(id) AS id FROM inventory_nodes").first!["id"]!
    try test(migrated["reason"] == "legacy pass" && migrated["last_node_id"] == String(rootNode) && migrated["end_node_id"] == maximum,
             "reconcile horizon migration retains an interrupted legacy pass and captures a finite conservative boundary")
}

private func reconcileHorizonTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-horizon-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/existing", withIntermediateDirectories: true)
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    let region = coverageRegion(root: root)!
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let db = try Database(database)
    let rootRow = try db.rows("SELECT id,generation_id FROM inventory_nodes WHERE parent_id IS NULL").first!
    let rootNode = Int64(rootRow["id"]!)!, generation = Int64(rootRow["generation_id"]!)!
    let existing = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE parent_id=? AND name='existing'", [rootNode]).first!["id"]!)!
    let oldEnd = Int64(try db.rows("SELECT MAX(id) AS id FROM inventory_nodes").first!["id"]!)!
    try db.write("INSERT INTO inventory_reconcile(root_node_id,generation_id,reason,created_at,last_node_id,end_node_id) VALUES (?,?,'bounded old pass',1,0,?)", [rootNode,generation,oldEnd])
    try db.write("INSERT INTO inventory_objects(device,inode,birth_ns,kind,logical,allocated,link_count,modified_at,changed_ns) VALUES (9001,9002,9003,'directory',0,0,1,1,1)")
    let object = Int64(try db.rows("SELECT id FROM inventory_objects WHERE device=9001 AND inode=9002 AND birth_ns=9003").first!["id"]!)!
    try db.write("INSERT INTO inventory_nodes(generation_id,parent_id,object_id,name,kind,status,direct_logical,direct_allocated,total_logical,total_allocated,measured_at) VALUES (?,?,?,'newer','directory','complete',0,0,0,0,1)", [generation,rootNode,object])
    let newer = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE generation_id=? AND parent_id=? AND name='newer'", [generation,rootNode]).first!["id"]!)!
    try db.write("INSERT INTO inventory_jobs(node_id,generation_id,state,updated_at) VALUES (?,?,'complete',1)", [newer,generation])
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 0), fdaOverride: "granted")
    let untouched = try db.rows("SELECT n.status,j.state FROM inventory_nodes n JOIN inventory_jobs j ON j.node_id=n.id WHERE n.id=?", [newer]).first!
    try test(untouched["status"] == "complete" && untouched["state"] == "complete",
             "an older reconciliation pass does not queue a directory discovered beyond its durable horizon")

    try db.write("UPDATE inventory_nodes SET status='complete' WHERE id IN (?,?)", [existing,newer])
    try db.write("UPDATE inventory_jobs SET state='complete' WHERE node_id IN (?,?)", [existing,newer])
    try db.write("INSERT INTO inventory_reconcile(root_node_id,generation_id,reason,created_at,last_node_id,end_node_id) VALUES (?,?,'old prefix',2,?,?) ON CONFLICT(root_node_id) DO UPDATE SET reason=excluded.reason,created_at=excluded.created_at,last_node_id=excluded.last_node_id,end_node_id=excluded.end_node_id", [rootNode,generation,oldEnd,newer])
    try invalidateInventory(databasePath: database, paths: [], eventID: 99, gap: true, reason: "newer gap")
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 0), fdaOverride: "granted")
    let reset = try db.rows("SELECT node_id,state FROM inventory_jobs WHERE node_id IN (?,?) ORDER BY node_id", [existing,newer])
    try test(reset.count == 2 && reset.allSatisfy { $0["state"] == "pending" },
             "a newer gap replaces the horizon, resets the old prefix, and includes directories beyond the older pass")
}

private func unavailableEventIdentityTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-events-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/folder", withIntermediateDirectories: true)
    try Data(count: 4_096).write(to: URL(fileURLWithPath: root + "/folder/file"))
    try privateDirectory(state)
    guard let region = coverageRegion(root: root) else { throw Failure("event-identity fixture is not on the startup Data volume") }
    let databasePath = state.appendingPathComponent("history.sqlite3").path
    _ = try Database(databasePath)
    let initial = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    func rows(_ sql: String, _ values: [Any] = []) throws -> [[String:String]] { try Database(databasePath).rows(sql, values) }
    try test(initial.outcome == "complete", "event-identity fixture establishes a complete inventory")

    let unavailable = EventMarker(eventId: 100, device: nil)
    try reconcileInventoryEvents(database: databasePath, directory: state, region: region, markerOverride: unavailable)
    try reconcileInventoryEvents(database: databasePath, directory: state, region: region, markerOverride: unavailable)
    let queuedOnce = try rows("SELECT event_availability,(SELECT COUNT(*) FROM inventory_invalidations WHERE generation_id=g.id) AS invalidations FROM inventory_generations g WHERE active=1").first!
    try test(queuedOnce["event_availability"] == "unavailable_reconciling" && queuedOnce["invalidations"] == "1", "repeated unavailable event identity queues exactly one full reconciliation")

    let drained = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let staleState = try rows("SELECT g.event_availability,g.state,n.status,(SELECT COUNT(*) FROM inventory_invalidations)+(SELECT COUNT(*) FROM inventory_reconcile)+(SELECT COUNT(*) FROM inventory_tombstones)+(SELECT COUNT(*) FROM inventory_prune_jobs)+(SELECT COUNT(*) FROM inventory_jobs WHERE state IN ('pending','enumerating')) AS work FROM inventory_generations g JOIN inventory_nodes n ON n.generation_id=g.id AND n.parent_id IS NULL WHERE g.active=1").first!
    try test(drained.outcome == "stale" && staleState["event_availability"] == "unavailable_stale" && staleState["state"] == "stale" && staleState["status"] == "stale" && staleState["work"] == "0" && !inventoryNeedsWork(databasePath: databasePath), "unavailable identity drains once into a terminal stale generation without queued work")

    try reconcileInventoryEvents(database: databasePath, directory: state, region: region, markerOverride: unavailable)
    let repeated = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 0.01), fdaOverride: "granted")
    try test(repeated.outcome == "stale" && repeated.entries == 0 && !inventoryNeedsWork(databasePath: databasePath), "later unavailable wakes remain terminal without restarting traversal")

    let tokenBeforeRefresh = try rows("SELECT listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.parent_id IS NULL").first!["listing_token"]!
    try requestInventoryRefresh(databasePath: databasePath, paths: [region.root], reason: "explicit stale refresh")
    let refreshed = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let tokenAfterRefresh = try rows("SELECT listing_token FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.parent_id IS NULL").first!["listing_token"]!
    try test(refreshed.outcome == "stale" && Int64(tokenAfterRefresh)! > Int64(tokenBeforeRefresh)! && !inventoryNeedsWork(databasePath: databasePath), "explicit refresh remains available while event identity is unavailable")

    try reconcileInventoryEvents(database: databasePath, directory: state, region: region,
                                 markerOverride: EventMarker(eventId: 200, device: "recovered-test-device"))
    let recovered = runInventory(databasePath: databasePath, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let recoveredState = try rows("SELECT g.event_availability,g.state,n.status FROM inventory_generations g JOIN inventory_nodes n ON n.generation_id=g.id AND n.parent_id IS NULL WHERE g.active=1").first!
    let cursor = try loadInventoryEventCursor(databasePath: databasePath, deviceIdentifier: "recovered-test-device")
    try test(recovered.outcome == "complete" && recoveredState["event_availability"] == "available" && recoveredState["state"] == "complete" && recoveredState["status"] == "complete" && cursor?.eventID == 200 && !inventoryNeedsWork(databasePath: databasePath), "event identity recovery reconciles once and restores incremental operation")
}

private func destinationRefreshMoveTest(_ test: (Bool, String) throws -> Void) async throws {
    let root = "/private/tmp/storage-monitor-inventory-move-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/source/subtree", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root + "/destination", withIntermediateDirectories: true)
    try Data(count: 8_192).write(to: URL(fileURLWithPath: root + "/source/subtree/file"))
    try Data(count: 4_096).write(to: URL(fileURLWithPath: root + "/destination/retained"))
    try privateDirectory(state)
    let region = coverageRegion(root: root)!
    let database = state.appendingPathComponent("history.sqlite3").path
    _ = try Database(database)
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let reader = InventoryReader(path: database)
    let rootNode = try await reader.root()!
    let children = try await reader.children(parentID: rootNode.id)
    let source = children.items.first { $0.name == "source" }!
    let destination = children.items.first { $0.name == "destination" }!
    let movedBefore = try await reader.children(parentID: source.id).items.first!
    let retained = try await reader.children(parentID: destination.id).items.first!
    // A stale ancestor aggregate can come from one sibling. It must not hide
    // trustworthy measurements in every other branch of the partial inventory.
    let db = try Database(database)
    try db.write("UPDATE inventory_nodes SET status='stale' WHERE id IN (?,?)", [rootNode.id,source.id])
    try db.write("UPDATE inventory_jobs SET state='pending' WHERE node_id=?", [source.id])
    let retainedDuringUpdate = try await reader.node(id: retained.id)!
    let affectedDuringUpdate = try await reader.node(id: movedBefore.id)!
    try test(retainedDuringUpdate.status == .complete && retainedDuringUpdate.logicalBytes == 4_096 && affectedDuringUpdate.status == .stale, "stale sibling aggregates preserve current values in unaffected branches")
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    try fm.moveItem(atPath: root + "/source/subtree", toPath: root + "/destination/subtree")
    try requestInventoryRefresh(databasePath: database, paths: [root + "/destination"], reason: "destination-only refresh")
    let result = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let sourceAfter = try await reader.node(id: source.id)!
    let destinationAfter = try await reader.node(id: destination.id)!
    let rootAfter = try await reader.root()!
    let movedAfter = try await reader.node(id: movedBefore.id)!
    try test(result.outcome == "complete" && sourceAfter.logicalBytes == 0 && sourceAfter.childCount == 0 && destinationAfter.logicalBytes == 12_288 && rootAfter.logicalBytes == rootNode.logicalBytes, "destination-only move refresh repairs both parents without changing total usage")
    try test(movedAfter.parentID == destination.id && movedAfter.measuredAt == movedBefore.measuredAt, "move preserves subtree identity and its actual measurement timestamp")
    // Simulate a previous gap's committed final page before its frontier is removed.
    // A new gap must revisit that prefix, even though it shares the same root.
    try db.write("INSERT INTO inventory_reconcile(root_node_id,generation_id,reason,created_at,last_node_id) VALUES (?,?,'older gap',?,?)", [rootNode.id,rootNode.generation,Date().timeIntervalSince1970,Int64.max])
    try invalidateInventory(databasePath: database, paths: [], eventID: 999, gap: true, reason: "newer gap")
    let queuedNode = try await reader.node(id: retained.id)!
    let queuedStatus = try await reader.status()
    try test(queuedNode.status == .stale && queuedNode.logicalBytes == nil && queuedStatus.state == "stale" && queuedStatus.completeness == .stale, "committed invalidation is visible before a worker applies it, including after interruption")
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 0), fdaOverride: "granted")
    let pendingAgain = try db.rows("SELECT state FROM inventory_jobs WHERE node_id=?", [movedAfter.id]).first?["state"]
    let retainedAfterGap = try await reader.node(id: retained.id)!
    try test(pendingAgain == "pending" && retainedAfterGap.status == .stale, "a newer event gap restarts an existing reconciliation frontier before certifying its old prefix")
}

private func invalidationProgressTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-queue-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/folder", withIntermediateDirectories: true)
    try Data([1]).write(to: URL(fileURLWithPath: root + "/folder/file"))
    try privateDirectory(state)
    let region = coverageRegion(root: root)!
    let database = state.appendingPathComponent("history.sqlite3").path
    _ = try Database(database)
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    // Multiple replay passes can queue the same directory before the crawl drains.
    try invalidateInventory(databasePath: database, paths: Array(repeating: root + "/folder", count: 300), eventID: 1, gap: false, reason: "queued activity")
    let interrupted = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, stopAfterEntries: 1), fdaOverride: "granted")
    let remaining = try Database(database).rows("SELECT COUNT(*) AS n FROM inventory_invalidations").first?["n"]
    try test(interrupted.outcome == "interrupted" && remaining == "0" && inventoryNeedsWork(databasePath: database), "queued invalidations make bounded progress while directory work remains pending")
}

private func smallListingCommitTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-commit-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    for index in 0..<4 {
        try fm.createDirectory(atPath: root + "/leaf-\(index)", withIntermediateDirectories: true)
        for name in ["first", "second"] { try Data([1,2]).write(to: URL(fileURLWithPath: root + "/leaf-\(index)/" + name)) }
    }
    try privateDirectory(state)
    let region = coverageRegion(root: root)!
    let database = state.appendingPathComponent("history.sqlite3").path
    let db = try Database(database)
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, batchSize: 4, stopAfterEntries: 4), fdaOverride: "granted")
    try db.exec("CREATE TRIGGER inventory_fixture_abort BEFORE UPDATE OF state ON inventory_jobs WHEN NEW.state='complete' AND NEW.node_id=(SELECT id FROM inventory_nodes WHERE name='leaf-2') BEGIN SELECT RAISE(ABORT,'fixture commit failure'); END")
    let failed = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let afterFailure = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE kind='file'").first?["n"]
    try test(failed.outcome == "failed" && afterFailure == "0" && inventoryNeedsWork(databasePath: database), "failed grouped listing commit rolls back observations and preserves durable jobs")
    try db.exec("DROP TRIGGER inventory_fixture_abort")
    let interrupted = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, stopAfterEntries: 6), fdaOverride: "granted")
    let committed = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE kind='file'").first?["n"]
    try test(interrupted.outcome == "interrupted" && interrupted.entries == 6 && committed == "6", "entry-budget interruption commits completed sibling listings before returning partial results")
    let resumed = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let totals = try db.rows("SELECT total_logical,descendant_files FROM inventory_nodes WHERE parent_id IS NULL").first!
    try test(resumed.outcome == "complete" && totals["total_logical"] == "16" && totals["descendant_files"] == "8", "resumed grouped listings produce exact aggregates after a rolled-back commit and interruption")
}

private func containerListingCommitTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-containers-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    for index in 0..<4 {
        try fm.createDirectory(atPath: root + "/container-\(index)/child", withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: URL(fileURLWithPath: root + "/container-\(index)/child/file"))
    }
    try privateDirectory(state)
    let region = coverageRegion(root: root)!, database = state.appendingPathComponent("history.sqlite3").path
    let db = try Database(database)
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, batchSize: 4, stopAfterEntries: 4), fdaOverride: "granted")
    let partial = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30, stopAfterEntries: 4), fdaOverride: "granted")
    let childCount = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE name='child'").first?["n"]
    let fileCount = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes WHERE kind='file'").first?["n"]
    try test(partial.outcome == "interrupted" && partial.entries == 4 && childCount == "4" && fileCount == "0", "bounded container commits persist child jobs before descendant discovery resumes")
    let resumed = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    try test(resumed.outcome == "complete" && (try db.rows("SELECT total_logical FROM inventory_nodes WHERE parent_id IS NULL").first?["total_logical"]) == "12", "resumed container listings preserve exact parent and descendant totals")

    // A stale directory's old-path job must not run before its move commits.
    let movedID = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='container-1'").first!["id"]!)!
    let destination = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='container-0'").first!["id"]!)!
    try fm.moveItem(atPath: root + "/container-1", toPath: root + "/container-0/moved")
    try db.write("UPDATE inventory_nodes SET status='stale' WHERE id IN (?,?)", [movedID,destination])
    try db.write("UPDATE inventory_jobs SET state='pending',updated_at=-2 WHERE node_id=?", [destination])
    try db.write("UPDATE inventory_jobs SET state='pending',updated_at=-1 WHERE node_id=?", [movedID])
    let moved = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted")
    let after = try db.rows("SELECT parent_id,status,name FROM inventory_nodes WHERE id=?", [movedID]).first!
    try test(moved.outcome == "complete" && after["parent_id"] == String(destination) && after["status"] == "complete" && after["name"] == "moved", "directory moves commit before stale sibling jobs read their previous paths")
}

private func blockedInventoryIOTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-blocked-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/child", withIntermediateDirectories: true)
    try Data([1,2,3]).write(to: URL(fileURLWithPath: root + "/child/file"))
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    let region = coverageRegion(root: root)!, db = try Database(database)
    _ = runInventory(databasePath: database, directory: state, region: region,
                     options: InventoryRunOptions(maxDuration: 30, stopAfterEntries: 1), fdaOverride: "granted")
    let row = try db.rows("SELECT id,generation_id FROM inventory_nodes WHERE name='child'").first!
    let node = Int64(row["id"]!)!, generation = Int64(row["generation_id"]!)!
    let watchdog = WalkWatchdog.shared
    watchdog.exitOnStall = false
    defer { watchdog.end(); watchdog.exitOnStall = true }
    let unexpectedExpiry = DispatchSemaphore(value: 0)
    watchdog.begin(path: "productive replay", allowed: 1) { unexpectedExpiry.signal() }
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.3)
        watchdog.progress()
    }
    watchdog.end()
    try test(unexpectedExpiry.wait(timeout: .now()) == .timedOut,
             "productive enumeration refreshes the inactivity limit during long prefix replay")
    watchdog.begin(path: "synthetic blocked inventory I/O", allowed: -1) {
        watchdog.end() // Recovery callbacks may safely disarm their own watchdog.
        try? markInventoryIOBlocked(databasePath: database, node: node, generation: generation)
    }
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        if try db.rows("SELECT reason FROM inventory_nodes WHERE id=?", [node]).first?["reason"] == "blocked" { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    let blocked = try db.rows("SELECT status,total_logical,total_allocated FROM inventory_nodes WHERE id=?", [node]).first!
    try test(blocked["status"] == "unknown" && blocked["total_logical"] == nil && blocked["total_allocated"] == nil,
             "blocked filesystem I/O watchdog persists an explicit unknown region without zero-byte totals")
    let continued = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 5), fdaOverride: "granted")
    try test(continued.outcome == "partial" && continued.pending == 0,
             "resumed worker skips the blocked job and preserves ancestor uncertainty")
    try requestInventoryRefresh(databasePath: database, paths: [root + "/child"])
    let recovered = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 5), fdaOverride: "granted")
    try test(recovered.outcome == "complete", "explicit refresh can recover a previously blocked inventory region")
}

private func queuedIdentityReplacementTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-replaced-job-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state"), saved = root + "-saved"
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state); try? fm.removeItem(atPath: saved) }
    try fm.createDirectory(atPath: root + "/child", withIntermediateDirectories: true)
    try Data([1]).write(to: URL(fileURLWithPath: root + "/child/old"))
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path, region = coverageRegion(root: root)!
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 5), fdaOverride: "granted")
    let db = try Database(database)
    let id = Int64(try db.rows("SELECT id FROM inventory_nodes WHERE name='child'").first!["id"]!)!
    // Preserve the old inode elsewhere so this fixture cannot pass through inode reuse.
    try fm.moveItem(atPath: root + "/child", toPath: saved)
    try fm.createDirectory(atPath: root + "/child", withIntermediateDirectories: true)
    try Data(count: 12_288).write(to: URL(fileURLWithPath: root + "/child/new"))
    try db.write("UPDATE inventory_jobs SET state='pending',snapshot_device=NULL,updated_at=0 WHERE node_id=?", [id])
    var cancelChecks = 0
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 1), fdaOverride: "granted") {
        cancelChecks += 1
        return cancelChecks >= 3
    }
    let interrupted = try db.rows("SELECT j.state,j.reason,n.total_logical,n.total_allocated FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.id=?", [id]).first!
    let parent = try db.rows("SELECT j.state,j.snapshot_device FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE n.parent_id IS NULL").first!
    try test(interrupted["state"] == "complete" && interrupted["reason"] == "identity_changed" && interrupted["total_logical"] == nil && interrupted["total_allocated"] == nil && parent["state"] == "pending" && parent["snapshot_device"] == nil,
             "an identity-mismatched child retires its retry while parent repair remains durably queued")
    let result = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 1), fdaOverride: "granted")
    let children = try db.rows("SELECT name FROM inventory_nodes WHERE parent_id=? ORDER BY name", [id]).compactMap { $0["name"] }
    try test(result.outcome == "complete" && children == ["new"], "a replaced queued directory repairs its parent instead of retrying its old identity forever")
    try test((try db.rows("SELECT total_logical FROM inventory_nodes WHERE parent_id IS NULL").first?["total_logical"]) == "12288", "identity replacement recovery removes obsolete children and derives exact parent totals")
    try fm.moveItem(atPath: root + "/child", toPath: saved + "/replacement")
    try Data(count: 24_576).write(to: URL(fileURLWithPath: root + "/child"))
    try db.write("UPDATE inventory_jobs SET state='pending',snapshot_device=NULL,updated_at=0 WHERE node_id=?", [id])
    let fileResult = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 1), fdaOverride: "granted")
    let file = try db.rows("SELECT kind,total_logical,child_count FROM inventory_nodes WHERE id=?", [id]).first!
    try test(fileResult.outcome == "complete" && file["kind"] == "file" && file["total_logical"] == "24576" && file["child_count"] == "0", "a queued directory replaced by a file repairs its parent and prunes obsolete descendants")
}

private func rootIdentityReplacementTest(_ test: (Bool, String) throws -> Void) throws {
    let root = "/private/tmp/storage-monitor-inventory-replaced-root-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state"), saved = root + "-saved"
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state); try? fm.removeItem(atPath: saved) }
    try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    try Data([1]).write(to: URL(fileURLWithPath: root + "/old"))
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path, region = coverageRegion(root: root)!
    _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 5), fdaOverride: "granted")
    let db = try Database(database)
    let row = try db.rows("SELECT id,generation_id FROM inventory_nodes WHERE parent_id IS NULL").first!
    let id = Int64(row["id"]!)!, generation = Int64(row["generation_id"]!)!
    try db.write("UPDATE inventory_jobs SET state='pending',snapshot_device=NULL WHERE node_id=?", [id])
    var callbacks = 0
    let interrupted = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 1), fdaOverride: "granted") {
        callbacks += 1
        if callbacks == 2 {
            try! fm.moveItem(atPath: root, toPath: saved)
            try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            try! Data(count: 4_096).write(to: URL(fileURLWithPath: root + "/new"))
        }
        return false
    }
    try test(interrupted.outcome == "failed" && (try db.rows("SELECT state FROM inventory_jobs WHERE node_id=?", [id]).first?["state"]) == "pending", "root identity replacement remains unfinished instead of completing the old root as unknown")
    let resumed = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 1), fdaOverride: "granted")
    let active = try db.rows("SELECT g.id,n.total_logical FROM inventory_generations g JOIN inventory_nodes n ON n.generation_id=g.id AND n.parent_id IS NULL WHERE g.active=1").first!
    try test(resumed.outcome == "complete" && Int64(active["id"]!)! > generation && active["total_logical"] == "4096", "root replacement resumes in a new generation with exact new-root totals")
}

@main enum InventoryIntegrationTestMain {
    static func main() async {
        do {
            var count = 0
            let check: (Bool,String) throws -> Void = { value, description in
                try required(value, "FAIL: \(description)"); count += 1; print("PASS \(description)")
            }
            try inventorySelfTest(check)
            try inventoryLifecycleTests(check)
            try await inventoryBoundaryTests(check)
            try await inventoryProgressiveTests(check)
            try await inventoryCompletionTests(check)
            try await inventoryExplorerTests(check)
            try inventoryChangeTrackerTests(check)
            try await inventoryChangeJournalTests(check)
            try await livingTreeCatalogTests(check)
            try inventoryReconciliationTests(check)
            try legacyMigrationTest(check)
            try statsTriggerMigrationTest(check)
            try reconcileHorizonMigrationTest(check)
            try reconcileHorizonTest(check)
            try unavailableEventIdentityTest(check)
            try invalidationProgressTest(check)
            try smallListingCommitTest(check)
            try containerListingCommitTest(check)
            try await destinationRefreshMoveTest(check)
            try await integrationFixture(check)
            try blockedInventoryIOTest(check)
            try queuedIdentityReplacementTest(check)
            try rootIdentityReplacementTest(check)
            print("\(count) inventory tests passed")
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
