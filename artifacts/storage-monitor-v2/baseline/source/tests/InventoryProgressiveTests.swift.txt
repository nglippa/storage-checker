import Foundation
import Darwin
import SQLite3

#if INVENTORY_TESTS
func inventoryProgressiveTests(_ check: (Bool, String) throws -> Void) async throws {
    _ = try await progressiveFixture(check, keep: false)
}

// Generated fixtures only. Keeping a fixture supplies an isolated native-browser scope.
func progressiveFixture(_ check: (Bool, String) throws -> Void, keep: Bool) async throws -> [String: Any] {
    let root = "/private/tmp/storage-monitor-progressive-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    let started = DispatchTime.now().uptimeNanoseconds
    func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 }
    defer {
        _ = chmod(root + "/restricted", 0o700)
        if !keep { try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    }
    for i in 0..<32 {
        let dir = root + "/background-\(i)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for j in 0..<60 { try Data(count: 1024 + j).write(to: URL(fileURLWithPath: dir + "/file-\(j)")) }
    }
    try fm.createDirectory(atPath: root + "/focus/deep/a/b/c", withIntermediateDirectories: true)
    for i in 0..<1200 { try Data(count: i % 7 == 0 ? 65_536 : 2048).write(to: URL(fileURLWithPath: root + "/focus/item-\(i)")) }
    try Data(count: 9999).write(to: URL(fileURLWithPath: root + "/focus/deep/a/b/c/payload"))
    try fm.createDirectory(atPath: root + "/restricted", withIntermediateDirectories: true)
    try Data(count: 9876).write(to: URL(fileURLWithPath: root + "/restricted/hidden"))
    try fm.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)
    try required(link(root + "/focus/item-0", root + "/background-0/alias") == 0, "fixture hard link")
    try fm.createSymbolicLink(atPath: root + "/shortcut", withDestinationPath: "focus")
    _ = chmod(root + "/restricted", 0)
    try privateDirectory(state)
    let path = state.appendingPathComponent("history.sqlite3").path
    let db = try Database(path), region = coverageRegion(root: root)!
    try db.write("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES (1,'progressive-history',4000,6000,'[]')")
    let historyBefore = try db.rows("SELECT * FROM readings")
    let initialStart = elapsed()
    let directCount = try fm.contentsOfDirectory(atPath: root).count
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10, stopAfterEntries: directCount), fdaOverride: "granted")
    let reader = InventoryReader(path: path), status = try await reader.status(), rootNode = try await reader.root()!
    let page = try await reader.children(parentID: rootNode.id)
    let firstDirectorySeconds = elapsed() - initialStart
    actor ReadGate {
        var opened = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { opened = true; continuation?.resume(); continuation = nil }
    }
    let gate = ReadGate()
    let cancelledRead = Task { await gate.wait(); return try await reader.children(parentID: rootNode.id) }
    cancelledRead.cancel(); await gate.release()
    var cancellationHonored = false
    do { _ = try await cancelledRead.value } catch is CancellationError { cancellationHonored = true }
    try check(cancellationHonored, "rapid navigation cancels obsolete queued read work before opening SQLite")
    let target = page.items.first { $0.name == "focus" }!
    let unknownPath = try await reader.locateDirectory(path: root + "/focus/deep/a/b/c")
    try check(!unknownPath.exact && unknownPath.node.id == target.id, "unindexed path opens its known ancestor without filesystem traversal")
    let alternateRoot = root.hasPrefix("/private/tmp/") ? "/tmp/" + String(root.dropFirst("/private/tmp/".count)) : "/private" + root
    let alternatePath = try await reader.locateDirectory(path: alternateRoot + "/focus/deep/a/b/c")
    try check(!alternatePath.exact && alternatePath.node.id == target.id, "unindexed navigation through either /tmp spelling returns the same indexed ancestor")
    var refusedSibling = false
    do { _ = try await reader.locateDirectory(path: root + "-neighbor/focus") } catch { refusedSibling = true }
    try check(refusedSibling, "stable alias navigation does not admit a same-prefix sibling outside the indexed root")
    var refusedLink = false
    do { _ = try await reader.locateDirectory(path: root + "/shortcut/deep") } catch { refusedLink = true }
    try check(refusedLink, "path navigation refuses symbolic links instead of starting another tree")
    try check(!page.items.isEmpty && status.completeness != .complete, "partial discovery can be browsed before initial indexing finishes")
    try check(target.allocatedBytes == nil && target.status != .complete, "newly discovered directory has no fabricated zero-byte aggregate")
    try check(status.progress == nil, "growing discovery denominator never produces a completion percentage")
    try check(try db.rows("SELECT * FROM readings") == historyBefore, "existing history is available and unchanged during initial discovery")

    let writer = InventoryFocusWriter()
    _ = try await writer.enqueue(database: path, path: target.path, revision: 2)
    let outdated = try await writer.enqueue(database: path, path: root, revision: 1)
    let newest = try JSONDecoder().decode(InventoryWorkRequest.self, from: Data(contentsOf: InventoryRequests.directory(database: path).appendingPathComponent("focus.json")))
    try check(!outdated && newest.path == target.path, "out-of-order navigation publication cannot replace newer focus with an obsolete selection")
    for _ in 0..<80 { _ = try InventoryRequests.enqueue(database: path, action: "focus", path: target.path) }
    let mail = try fm.contentsOfDirectory(atPath: InventoryRequests.directory(database: path).path)
    try check(mail.filter { $0.hasSuffix(".json") }.count == 1, "repeated navigation coalesces to one focus mailbox instead of UUID refresh jobs")
    try consumeInventoryRequests(database: path, directory: state, region: region)
    try db.exec("DELETE FROM inventory_focus")
    let mailbox = InventoryRequests.directory(database: path)
    let expired = InventoryWorkRequest(id: UUID(), action: "focus", path: target.path, requestedAt: Date().addingTimeInterval(-600), boundary: nil)
    try JSONEncoder().encode(expired).write(to: mailbox.appendingPathComponent("focus.json"))
    try consumeInventoryRequests(database: path, directory: state, region: region)
    try check((try db.rows("SELECT * FROM inventory_focus")).isEmpty, "old focus mailbox cannot acquire a new priority lease after pause")
    try Data("invalid-json".utf8).write(to: mailbox.appendingPathComponent("focus-claimed.json"))
    _ = try InventoryRequests.enqueue(database: path, action: "focus", path: target.path)
    try consumeInventoryRequests(database: path, directory: state, region: region)
    try consumeInventoryRequests(database: path, directory: state, region: region)
    try check((try db.rows("SELECT COUNT(*) AS n FROM inventory_focus").first?["n"]) == "1", "malformed claimed focus is retired without wedging newer navigation or the worker")
    _ = try InventoryRequests.enqueue(database: path, action: "focus", path: target.path)
    try fm.moveItem(at: mailbox.appendingPathComponent("focus.json"), to: mailbox.appendingPathComponent("focus-claimed.json"))
    try consumeInventoryRequests(database: path, directory: state, region: region)
    try check((try db.rows("SELECT COUNT(*) AS n FROM inventory_focus").first?["n"]) == "1", "crashed focus claim is idempotently recovered without duplicating directory jobs")
    let tokenBefore = try db.rows("SELECT listing_token,listing_sequence FROM inventory_jobs WHERE node_id=?", [target.id])
    for i in 0..<64 { try requestInventoryFocus(databasePath: path, path: root + "/background-\(i % 32)") }
    let bounded = try db.rows("SELECT COUNT(*) AS n FROM inventory_focus").first!["n"]!
    try check(Int(bounded)! <= 16, "rapid navigation keeps at most sixteen durable focus intents")
    try db.exec("DELETE FROM inventory_focus")
    var rejected = false
    do { try requestInventoryFocus(databasePath: path, path: "/Volumes/other") } catch { rejected = true }
    try check(rejected, "priority rejects paths outside the inventory volume scope")
    try requestInventoryFocus(databasePath: path, path: target.path)
    try check(try db.rows("SELECT listing_token,listing_sequence FROM inventory_jobs WHERE node_id=?", [target.id]) == tokenBefore, "focus never resets job authority or creates a refresh invalidation")
    // Deliberately place the target behind ordinary work to measure demand response.
    try db.write("UPDATE inventory_jobs SET updated_at=CASE WHEN node_id=? THEN 1000000000000 ELSE 1 END WHERE node_id<>?", [target.id,rootNode.id])
    let focusStart = elapsed(), profile = InventoryProfile()
    let focused = profile.withScope {
        runInventory(databasePath: path, directory: state, region: region,
                     options: InventoryRunOptions(maxDuration: 15, batchSize: 16, stopAfterEntries: 350), fdaOverride: "granted")
    }
    let focusSeconds = elapsed() - focusStart
    let focusProfileJSON = profile.json
    if keep {
        let partial = URL(fileURLWithPath: state.path + "-partial")
        try privateDirectory(partial)
        var input: OpaquePointer?, output: OpaquePointer?
        defer { sqlite3_close(input); sqlite3_close(output) }
        try required(sqlite3_open_v2(path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK && sqlite3_open(partial.appendingPathComponent("history.sqlite3").path, &output) == SQLITE_OK, "open partial fixture copy")
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw Failure("partial copy init") }
        let copied = sqlite3_backup_step(backup, -1); sqlite3_backup_finish(backup)
        try required(copied == SQLITE_DONE, "partial fixture backup")
    }
    let focusedPage = try await reader.children(parentID: target.id, limit: 25)
    let focusedPage2 = try await reader.children(parentID: target.id, offset: 25, limit: 25)
    let measuredTarget = try await reader.node(id: target.id)!
    var navigationMS = [Double]()
    for _ in 0..<20 {
        let t = DispatchTime.now().uptimeNanoseconds
        _ = try await reader.children(parentID: target.id, limit: 100)
        navigationMS.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1_000_000)
    }
    try check(!focusedPage.items.isEmpty && (measuredTarget.allocatedBytes ?? 0) > 0 && focused.outcome != "complete", "interactive work exposes qualified useful file sizes while the wider index remains incomplete (outcome=\(focused.outcome), reason=\(focused.reason ?? ""), children=\(focusedPage.items.count), size=\(measuredTarget.allocatedBytes ?? -1), counts=\(profile.counts))")
    try check(focusedPage.hasMore && Set(focusedPage.items.map(\.id)).isDisjoint(with: focusedPage2.items.map(\.id)), "large partially indexed directories retain correct lazy pagination")
    let backgroundFiles = try db.rows("SELECT COUNT(*) AS n FROM inventory_nodes n JOIN inventory_nodes p ON p.id=n.parent_id WHERE p.name LIKE 'background-%' AND n.kind='file'").first!["n"]!
    try check(Int(backgroundFiles)! > 0 && profile.counts["background_quanta",default:0] > 0, "interactive enumeration reserves background turns instead of starving ordinary discovery")
    try check(profile.counts["interactive_quanta",default:0] <= 3 * profile.counts["background_quanta",default:0] + 3, "foreground quantum budget remains bounded at three turns per background turn")
    let interruptedFocus = try db.rows("SELECT path FROM inventory_focus")
    try check(!interruptedFocus.isEmpty && (try db.rows("SELECT snapshot_device FROM inventory_jobs WHERE node_id=?", [target.id]).first?["snapshot_device"]) != nil, "interrupted prioritized jobs retain focus intent and committed listing checkpoint")

    try db.exec("DELETE FROM inventory_focus")
    try requestInventoryFocus(databasePath: path, path: root + "/focus/deep/a/b/c")
    let deep = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 15, batchSize: 31, stopAfterEntries: 2000), fdaOverride: "granted")
    let deepFound = try await reader.search(text: "focus/deep/a/b/c/payload")
    try check(!deepFound.items.isEmpty && deep.outcome != "failed", "priority resolves necessary discovered ancestors for a deep unindexed path")
    _ = chmod(root + "/restricted", 0)
    let completeProfile = InventoryProfile()
    let finished = completeProfile.withScope { runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted") }
    try check(finished.outcome == "partial", "index can finish accessible work while a protected directory remains a coverage gap")
    let restricted = try await reader.search(text: "restricted")
    let protectedNode = restricted.items.first { $0.name == "restricted" }!
    let protectedToken = try db.rows("SELECT listing_token,attempts FROM inventory_jobs WHERE node_id=?", [protectedNode.id])
    try requestInventoryFocus(databasePath: path, path: protectedNode.path)
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted")
    try check((try db.rows("SELECT listing_token,attempts FROM inventory_jobs WHERE node_id=?", [protectedNode.id])) == protectedToken, "navigation alone does not repeatedly retry inaccessible directories")
    let completedTokens = try db.rows("SELECT node_id,listing_token FROM inventory_jobs ORDER BY node_id")
    try requestInventoryFocus(databasePath: path, path: target.path)
    let noDuplicate = InventoryProfile()
    _ = noDuplicate.withScope { runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 10), fdaOverride: "granted") }
    try check(try db.rows("SELECT node_id,listing_token FROM inventory_jobs ORDER BY node_id") == completedTokens && noDuplicate.counts["listings_attempted",default:0] == 0, "opening a measured directory causes no duplicate filesystem enumeration")

    let targetToken = try db.rows("SELECT listing_token FROM inventory_jobs WHERE node_id=?", [target.id]).first!["listing_token"]!
    try Data(count: 123456).write(to: URL(fileURLWithPath: root + "/focus/item-1"))
    try invalidateInventory(databasePath: path, paths: [root + "/focus"], eventID: 77, gap: false, reason: "Filesystem activity")
    try requestInventoryFocus(databasePath: path, path: target.path)
    let stale = try await reader.node(id: target.id)!
    try check(stale.status == .stale && stale.logicalBytes == nil && stale.previousLogicalBytes != nil, "reader sees newer invalidation immediately despite interactive priority")
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 20), fdaOverride: "granted")
    let nextToken = try db.rows("SELECT listing_token FROM inventory_jobs WHERE node_id=?", [target.id]).first!["listing_token"]!
    try check(Int(nextToken)! == Int(targetToken)! + 1, "priority during FSEvents invalidation performs exactly the required newer listing")
    try requestInventoryRefresh(databasePath: path, paths: [root + "/focus"], reason: "priority refresh")
    try requestInventoryFocus(databasePath: path, path: target.path)
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 20), fdaOverride: "granted")
    try check(try db.rows("SELECT listing_token FROM inventory_jobs WHERE node_id=?", [target.id]).first!["listing_token"] == String(Int(nextToken)!+1), "focus and refresh share one authoritative listing without duplicate jobs")
    let rootToken = Int64(try db.rows("SELECT listing_token FROM inventory_jobs WHERE node_id=?", [rootNode.id]).first!["listing_token"]!)!
    try db.write("INSERT INTO inventory_prune_jobs(parent_node_id,generation_id,seen_token,created_at) VALUES (?,?,?,0)", [rootNode.id,rootNode.generation,rootToken-1])
    try requestInventoryFocus(databasePath: path, path: target.path)
    let priorRootChildren = try db.rows("SELECT id FROM inventory_nodes WHERE parent_id=? ORDER BY id", [rootNode.id])
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 15), fdaOverride: "granted")
    try check(try db.rows("SELECT id FROM inventory_nodes WHERE parent_id=? ORDER BY id", [rootNode.id]) == priorRootChildren, "interactive focus does not weaken obsolete cleanup protection")
    try fm.removeItem(atPath: root + "/focus/item-0")
    try invalidateInventory(databasePath: path, paths: [root + "/focus"], eventID: 78, gap: false, reason: "Filesystem activity")
    try requestInventoryFocus(databasePath: path, path: target.path)
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 20), fdaOverride: "granted")
    let alias = try db.rows("SELECT o.owner_node_id=n.id AS owner,n.total_logical FROM inventory_nodes n JOIN inventory_objects o ON o.id=n.object_id WHERE n.name='alias'").first!
    try check(alias["owner"] == "1" && alias["total_logical"] == "65536", "legitimate prioritized cleanup preserves hard-link ownership and byte attribution")
    try fm.removeItem(atPath: root + "/empty")
    try invalidateInventory(databasePath: path, paths: [root], eventID: 79, gap: false, reason: "Filesystem activity")
    _ = runInventory(databasePath: path, directory: state, region: region, options: InventoryRunOptions(maxDuration: 20), fdaOverride: "granted")
    let deleted = try await reader.search(text: "empty")
    try check(deleted.items.isEmpty, "directory deleted during navigation disappears from committed reader results")
    try check((try db.rows("PRAGMA quick_check").first?.values.first) == "ok" && (try db.rows("PRAGMA foreign_key_check")).isEmpty && (try db.rows("SELECT * FROM readings")) == historyBefore, "progressive priority leaves database integrity and monitoring history intact")
    return ["fixture_root":root,"state_directory":state.path,"partial_state_directory":state.path+"-partial","first_directory_seconds":firstDirectorySeconds,"focused_partial_seconds":focusSeconds,"navigation_ms":navigationMS,"focus_profile":focusProfileJSON,"final_profile":completeProfile.json,"peak_memory_bytes":peakMemoryBytes(),"elapsed_seconds":elapsed(),"nodes":try db.rows("SELECT total_nodes FROM inventory_stats").first!["total_nodes"]!,"meaningful_condition":"Selected focus folder has committed children and nonzero qualified allocation while inventory remains incomplete; not a timer threshold.","kept":keep]
}
#endif

