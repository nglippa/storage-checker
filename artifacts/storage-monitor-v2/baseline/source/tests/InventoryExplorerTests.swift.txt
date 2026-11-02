import Foundation
import CoreGraphics
import SQLite3

#if INVENTORY_TESTS
// Hierarchical explorer reads (InventoryReader.explorerChildren). Real filesystem fixtures and real worker
// runs; SQL only constructs the deferred state, which a fixture cannot reach deterministically.
func inventoryExplorerTests(_ test: (Bool, String) throws -> Void) async throws {
    let root = "/private/tmp/storage-monitor-explorer-\(UUID().uuidString)"
    let state = URL(fileURLWithPath: root + "-state")
    defer { _ = chmod(root + "/locked", 0o755); try? fm.removeItem(atPath: root); try? fm.removeItem(at: state) }
    try fm.createDirectory(atPath: root + "/big", withIntermediateDirectories: true)
    // Sizes repeat every 50 files, so pages must break ties by name and id.
    for index in 0..<1_234 { try Data(count: 4_096 * (1 + index % 50)).write(to: URL(fileURLWithPath: root + "/big/f\(index)")) }
    try fm.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root + "/nested/a/b", withIntermediateDirectories: true)
    try Data(count: 300_000).write(to: URL(fileURLWithPath: root + "/nested/a/b/payload"))
    try Data(count: 10).write(to: URL(fileURLWithPath: root + "/nested/small"))
    try fm.createDirectory(atPath: root + "/locked/inside", withIntermediateDirectories: true)
    try Data(count: 10).write(to: URL(fileURLWithPath: root + "/locked/inside/x"))
    _ = chmod(root + "/locked", 0o000)
    try privateDirectory(state)
    let database = state.appendingPathComponent("history.sqlite3").path
    let region = coverageRegion(root: root)!
    func run() { _ = runInventory(databasePath: database, directory: state, region: region, options: InventoryRunOptions(maxDuration: 30), fdaOverride: "granted") }
    run()
    let reader = InventoryReader(path: database)
    let top = try await reader.root()!
    func child(_ parent: Int64, _ name: String) async throws -> InventoryNode {
        try await reader.explorerChildren(parentID: parent, limit: 256).items.first { $0.name == name }!
    }

    // Root: largest first, the protected folder present and labelled, nothing implied about it.
    let first = try await reader.explorerChildren(parentID: top.id)
    try test(first.items.map(\.name) == ["big", "nested", "empty", "locked"] || first.items.prefix(2).map(\.name) == ["big", "nested"],
             "explorer lists a folder's children largest first (\(first.items.map(\.name)))")
    let locked = first.items.first { $0.name == "locked" }!
    try test(locked.status == .unknown && locked.allocatedBytes == nil && InventoryNodePresentation.coverage(locked) == "Access restricted"
             && InventoryNodePresentation.explorerNote(locked) == "Access restricted",
             "a protected folder is shown as access restricted, never as a measured or empty folder")
    let empty = try await child(top.id, "empty")
    let emptyPage = try await reader.explorerChildren(parentID: empty.id)
    try test(emptyPage.items.isEmpty && emptyPage.next == nil && empty.status == .complete, "an empty folder expands to no rows and no further page")

    // A large folder: bounded pages that join into exactly the folder's entries, in the stated order.
    let big = try await child(top.id, "big")
    var collected = [InventoryNode](), cursor: InventoryChildCursor? = nil, pages = 0, worst = 0.0
    repeat {
        let began = Date()
        let page = try await reader.explorerChildren(parentID: big.id, after: cursor, limit: 200)
        worst = max(worst, Date().timeIntervalSince(began))
        try test(page.items.count <= 200, "an explorer page holds at most 200 entries")
        collected += page.items; cursor = page.next; pages += 1
    } while cursor != nil
    try test(collected.count == 1_234 && Set(collected.map(\.id)).count == 1_234 && pages == 7,
             "paging a 1,234-entry folder returns every entry exactly once in 7 pages")
    let sorted = zip(collected, collected.dropFirst()).allSatisfy { a, b in
        (a.allocatedBytes ?? -1) > (b.allocatedBytes ?? -1)
            || ((a.allocatedBytes ?? -1) == (b.allocatedBytes ?? -1) && (a.name.lowercased(), a.id) < (b.name.lowercased(), b.id))
    }
    try test(sorted, "pages are ordered by allocated size, then name, then id, with no reordering across page boundaries")
    var legacy = [InventoryNode](), offset = 0
    while true {
        let page = try await reader.children(parentID: big.id, offset: offset, limit: 200, sort: .allocated)
        legacy += page.items; offset += 200
        if !page.hasMore { break }
    }
    try test(legacy.map(\.id) == collected.map(\.id) && legacy.map(\.path) == collected.map(\.path),
             "explorer pages match the existing reader's order and paths entry for entry")
    try test(worst < 0.1, "each explorer page of the large folder reads in under 100 ms (worst \(Int(worst * 1000)) ms)")

    // Storage map: first page plus the exact remainder equals the folder's indexed children.
    func mapTotals(_ parent: Int64) async throws -> (shown: Int64, other: Int64, count: Int64, unmeasured: Int64, tiles: Int) {
        let page = try await reader.explorerChildren(parentID: parent, limit: 200)
        let beyond = page.next == nil ? nil : try await reader.explorerRemainder(parentID: parent, skip: page.items.count)
        let plan = InventoryMapPlan(items: page.items, start: 0, beyond: beyond, canLoadMore: page.next != nil, in: CGRect(x: 0, y: 0, width: 800, height: 300))
        let nodes = plan.tiles.compactMap(\.node)
        return (nodes.reduce(0) { $0 + InventoryMapPlan.weight($1)! }, plan.other?.allocated ?? 0, Int64(nodes.count) + (plan.other?.count ?? 0), plan.other?.unmeasured ?? 0, plan.tiles.count)
    }
    let bigTotal = collected.reduce(Int64(0)) { $0 + (InventoryMapPlan.weight($1) ?? 0) }
    let bigMap = try await mapTotals(big.id)
    try test(bigMap.shown + bigMap.other == bigTotal && bigMap.count == 1_234 && bigMap.tiles == 121,
             "storage map of a 1,234-entry folder: drawn regions plus Other items equal the indexed total exactly (\(bigMap.tiles) regions)")
    let nestedSpan = try await reader.explorerSpan(parentID: big.id, count: 60, pageLimit: 60)
    try test(nestedSpan.page.items.count == 60 && nestedSpan.remainder?.count == 1_174
             && nestedSpan.page.items.reduce(Int64(0), { $0 + InventoryMapPlan.weight($1)! }) + nestedSpan.remainder!.allocated == bigTotal,
             "nested map read: one 60-entry page and the exact remainder of a 1,234-entry folder add up to its indexed total")
    let rootMap = try await mapTotals(top.id)
    try test(rootMap.unmeasured == 1 && rootMap.count == 4, "storage map: the protected folder is counted as unmeasured, not drawn with a size")

    // Stable pagination while the worker commits new entries between pages.
    let pageOne = try await reader.explorerChildren(parentID: big.id, limit: 200)
    for index in 0..<40 { try Data(count: 4_096 * (index % 2 == 0 ? 60 : 1)).write(to: URL(fileURLWithPath: root + "/big/new\(index)")) }
    try requestInventoryRefresh(databasePath: database, paths: [root + "/big"])
    run()
    var resumed = pageOne.items, next = pageOne.next
    while let position = next {
        let page = try await reader.explorerChildren(parentID: big.id, after: position, limit: 200)
        resumed += page.items; next = page.next
    }
    let ids = resumed.map(\.id)
    // A fresh read of the folder after the update (a resumed walk does not revisit entries that sorted in
    // before its cursor, by design) is what the map must add up to.
    var fresh = [InventoryNode](), freshCursor: InventoryChildCursor? = nil
    repeat { let page = try await reader.explorerChildren(parentID: big.id, after: freshCursor, limit: 200); fresh += page.items; freshCursor = page.next } while freshCursor != nil
    let updatedTotal = fresh.reduce(Int64(0)) { $0 + (InventoryMapPlan.weight($1) ?? 0) }
    let updatedMap = try await mapTotals(big.id)
    try test(updatedMap.shown + updatedMap.other == updatedTotal && updatedMap.count == Int64(fresh.count) && fresh.count == 1_274 && updatedTotal > bigTotal,
             "storage map after an index update during navigation: totals follow the new entries exactly")
    try test(Set(ids).count == ids.count && Set(collected.map(\.id)).isSubset(of: Set(ids)),
             "entries committed between pages cause no duplicate and no missing pre-existing row")

    // Nested folders and paths.
    let nested = try await child(top.id, "nested")
    let a = try await child(nested.id, "a")
    let b = try await child(a.id, "b")
    // Paths are reported in their Data-volume form (/System/Volumes/Data/private/tmp/…).
    try test(b.path == a.path + "/b" && a.path == nested.path + "/a" && b.path.hasSuffix(root + "/nested/a/b") && b.kind == .directory && (b.allocatedBytes ?? 0) > 0,
             "a nested folder's entry carries its real path and measured size (\(b.path))")

    // Deferred folder: keeps its earlier size and says so.
    let db = try Database(database)
    try db.write("UPDATE inventory_nodes SET reason=? WHERE id=?", [inventoryDeferredReason, a.id])
    let deferred = try await child(nested.id, "a")
    try test(InventoryNodePresentation.coverage(deferred) == "Kept changing · earlier size" && InventoryNodePresentation.explorerNote(deferred) != nil,
             "a folder that kept changing is labelled as an earlier size, not as current")

    // Deleted entries disappear, and expanding a vanished folder reports it instead of showing stale rows.
    try fm.removeItem(atPath: root + "/nested/a")
    try requestInventoryRefresh(databasePath: database, paths: [root + "/nested"])
    run()
    let afterDelete = try await reader.explorerChildren(parentID: nested.id)
    var vanished = false
    do { _ = try await reader.explorerChildren(parentID: a.id) } catch { vanished = true }
    try test(!afterDelete.items.contains { $0.name == "a" } && vanished,
             "a deleted folder leaves its parent's listing, and expanding it again reports that it is gone")

    // One snapshot for the map: a writer moves bytes between two children in single transactions, so the
    // folder's total never changes; every span read (tiles' pages plus remainder) must add up to it.
    // (The fixture database keeps its rollback journal: a read transaction is one snapshot in either mode.)
    let spanPage = try await reader.explorerChildren(parentID: big.id, limit: 200)
    let constant = try await reader.explorerRemainder(parentID: big.id, skip: 0)
    let movers = (spanPage.items[0].id, spanPage.items[150].id)
    final class Flag: @unchecked Sendable { var stop = false; var done = false; var commits = 0 }
    let flag = Flag()
    Thread.detachNewThread {
        let writer = try! Database(database)
        var sign: Int64 = 1
        while !flag.stop {
            do {
                try writer.exec("BEGIN IMMEDIATE")
                try writer.write("UPDATE inventory_nodes SET total_allocated=total_allocated+? WHERE id=?", [sign * 4_096_000, movers.0])
                try writer.write("UPDATE inventory_nodes SET total_allocated=total_allocated-? WHERE id=?", [sign * 4_096_000, movers.1])
                try writer.exec("COMMIT")
            } catch { try? writer.exec("ROLLBACK") }
            flag.commits += 1; sign = -sign
        }
        flag.done = true
    }
    var spanReads = 0, spanMismatches = 0, splitReads = 0, splitMismatches = 0
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
        if let span = try? await reader.explorerSpan(parentID: big.id, count: 200) {
            spanReads += 1
            let sum = span.page.items.reduce(Int64(0)) { $0 + (InventoryMapPlan.weight($1) ?? 0) } + (span.remainder?.allocated ?? 0)
            if sum != constant.allocated { spanMismatches += 1 }
        }
        if let page = try? await reader.explorerChildren(parentID: big.id, limit: 200), let rest = try? await reader.explorerRemainder(parentID: big.id, skip: page.items.count) {
            splitReads += 1
            if page.items.reduce(Int64(0), { $0 + (InventoryMapPlan.weight($1) ?? 0) }) + rest.allocated != constant.allocated { splitMismatches += 1 }
        }
    }
    flag.stop = true
    while !flag.done { try await Task.sleep(nanoseconds: 1_000_000) }
    try test(spanReads >= 5 && flag.commits > 20 && spanMismatches == 0,
             "storage map reads tiles and Other items from one snapshot: \(spanReads) reads during \(flag.commits) concurrent commits, 0 inconsistent (separate reads: \(splitMismatches) of \(splitReads) inconsistent)")

    // Staleness matches the existing reader while a refresh is pending (parent-chain rules resolved once per page).
    try requestInventoryRefresh(databasePath: database, paths: [root])
    let pendingNew = try await reader.explorerChildren(parentID: big.id, limit: 50).items
    let pendingOld = try await reader.children(parentID: big.id, limit: 50, sort: .allocated).items
    try test(pendingNew.map { "\($0.id)\($0.status)\($0.statusReason ?? "")" } == pendingOld.map { "\($0.id)\($0.status)\($0.statusReason ?? "")" }
             && pendingNew.contains { $0.status == .stale },
             "during a pending refresh, explorer rows carry the same previous-measurement state as the existing reader")
}
#endif
