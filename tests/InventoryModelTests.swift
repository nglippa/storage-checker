import Foundation

// Headless checks of the disk inventory browser model: refresh replay and cancellation, the deferred-folder
// list behind "Show N folders", and the prioritize confirmations. The database is built by the monitor's own
// inventory worker from a synthetic tree inside a scratch directory, so the production history is never opened.
@main struct InventoryModelTests {
    static var passed = 0
    static var failures: [String] = []

    static func test(_ ok: Bool, _ message: String) {
        if ok { passed += 1; print("PASS \(message)") } else { failures.append(message); print("FAIL \(message)") }
    }

    /// Runs a process to completion and returns its status and combined output.
    static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    /// Runs SQL against a scratch database with the sqlite3 command line tool and returns its rows.
    static func sql(_ database: String, _ statement: String) throws -> [String] {
        let result = try run("/usr/bin/sqlite3", [database, statement])
        guard result.status == 0 else { throw NSError(domain: "fixture", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.output]) }
        return result.output.split(separator: "\n").map(String.init)
    }

    /// Polls until the condition holds or the timeout passes.
    @MainActor static func waitUntil(timeout: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @MainActor static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            print("usage: InventoryModelTests <monitor executable> <scratch directory>")
            exit(2)
        }
        let monitor = arguments[0]
        let scratch = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: scratch)

        // Fixture: twelve folders, each with one file, indexed by the monitor's own worker.
        let tree = scratch.appendingPathComponent("tree"), state = scratch.appendingPathComponent("state")
        for index in 0..<12 {
            let folder = tree.appendingPathComponent("d\(index)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 4_096 * (index + 1)).write(to: folder.appendingPathComponent("f"))
        }
        let indexed = try run(monitor, ["inventory-work", "--root", tree.path, "--data-dir", state.path, "--budget", "30"])
        let database = state.appendingPathComponent("history.sqlite3").path
        test(indexed.status == 0 && fm.fileExists(atPath: database), "the isolated fixture is indexed by the monitor worker (exit \(indexed.status))")
        test(database.hasPrefix(scratch.path), "the model only opens the scratch database")

        let readiness = ViewerReadiness(output: nil)
        let model = InventoryBrowserModel(database: database, readiness: readiness)
        await model.load()
        test((model.status?.totalNodes ?? 0) >= 13 && model.root != nil, "the browser loads the indexed fixture (\(model.status?.totalNodes ?? 0) nodes)")

        // Refresh requested while a load is running: it must run once that load ends, however many are asked for.
        model.search = "d"  // a search adds a short delay to each load, so the load is reliably in flight
        var before = model.revision
        let during = Task { await model.load() }
        let inFlight = await waitUntil { model.loading }
        model.refreshIfIdle(); model.refreshIfIdle(); model.refreshIfIdle()
        await during.value
        test(inFlight, "a load is in flight when the refresh arrives")
        test(model.revision == before + 1, "refreshes during one load replay as a single reload (revision +\(model.revision - before))")
        test(!model.loading, "loading clears when the load ends")

        // A cancelled load must neither leave the spinner running nor lose a refresh that arrived before it.
        before = model.revision
        let cancelled = Task { await model.load() }
        _ = await waitUntil { model.loading }
        model.refreshIfIdle()
        cancelled.cancel()
        await cancelled.value
        test(!model.loading, "a cancelled load does not leave loading set (the refresh control would spin)")
        test(model.revision == before + 1, "a refresh requested before cancellation is not lost (revision +\(model.revision - before))")
        model.search = ""

        // Deferred folders: two directories kept changing during the last listing.
        let deferredReason = inventoryDeferredReason
        func markDeferred(_ names: String) throws {
            _ = try sql(database, "DELETE FROM inventory_jobs WHERE reason='\(deferredReason)'")
            _ = try sql(database, "INSERT INTO inventory_jobs(node_id,generation_id,state,reason,updated_at) SELECT id,generation_id,'pending','\(deferredReason)',unixepoch() FROM inventory_nodes WHERE kind='directory' AND name IN (\(names)) ON CONFLICT(node_id) DO UPDATE SET state='pending', reason=excluded.reason")
        }
        try markDeferred("'d3','d7'")
        await model.load()
        test(model.status?.deferredDirectories == 2, "the status counts two deferred folders (\(model.status?.deferredDirectories ?? -1))")

        let popover = InventoryBrowserModel(database: database, readiness: readiness)
        test(popover.deferredFoldersState == .loading && popover.deferredFolders.isEmpty, "the list starts in the loading state")
        await popover.loadDeferredFolders()
        let names = popover.deferredFolders.map(\.name).sorted()
        test(popover.deferredFoldersState == .loaded && names == ["d3", "d7"], "populated: lists exactly the deferred folders (\(names))")
        test(popover.deferredFolders.allSatisfy { $0.kind == .directory && $0.path.hasSuffix("/" + $0.name) }, "each deferred row carries its own folder path")

        try markDeferred("'d99'")  // no deferred folder matches: the empty state
        await popover.loadDeferredFolders()
        test(popover.deferredFoldersState == .loaded && popover.deferredFolders.isEmpty, "empty: a loaded list with no folders is reported as empty")

        let corrupt = scratch.appendingPathComponent("corrupt.sqlite3")
        try Data("not a database".utf8).write(to: corrupt)
        let broken = InventoryBrowserModel(database: corrupt.path, readiness: readiness)
        await broken.loadDeferredFolders()
        test(broken.deferredFoldersState == .failed && broken.deferredFolders.isEmpty, "failure: an unreadable database reports a failure, not an empty list")

        // The "Show" action on a deferred row opens that folder.
        try markDeferred("'d3','d7'")
        await popover.loadDeferredFolders()
        if let target = popover.deferredFolders.first(where: { $0.name == "d3" }) {
            model.navigate(target)
            test(model.parentID == target.id, "choosing a deferred folder navigates to it")
        } else {
            test(false, "choosing a deferred folder navigates to it (d3 not listed)")
        }

        // Prioritize confirmations name the folder that was asked for.
        await model.load()
        let reader = InventoryReader(path: database)
        if let rootID = model.root?.id, let d5 = try await reader.explorerChildren(parentID: rootID, limit: 256).items.first(where: { $0.name == "d5" }) {
            await model.openPath(d5.path)
            let confirmed = await waitUntil { model.message?.contains("indexing queue") == true }
            test(confirmed && model.message == "“d5” moved ahead in the indexing queue.", "exploring a folder confirms it by name and says it is queued (\(model.message ?? "none"))")
        } else {
            test(false, "exploring a folder confirms it by name (d5 not found)")
        }

        model.navigate(popover.deferredFolders.first(where: { $0.name == "d7" }) ?? popover.deferredFolders[0])
        await model.load()
        model.message = nil
        model.prioritizeCurrentFolder()
        let announced = await waitUntil { model.message != nil }
        test(announced && model.message?.hasPrefix("“d") == true && model.message?.contains("will be indexed before other folders") == true,
             "the index-first action names the folder and says it is queued, not indexed (\(model.message ?? "none"))")

        // Expanded explorer branches re-read when the inventory changes. A change that arrives within five seconds
        // of the previous re-read must still appear, not be dropped by the re-read throttle.
        let explorer = InventoryExplorerController(database: database)
        if let top = model.root, let d3 = try await reader.explorerChildren(parentID: top.id, limit: 256).items.first(where: { $0.name == "d3" }) {
            explorer.show(root: top, trail: [])
            _ = await waitUntil { explorer.rows.contains { $0.node?.id == d3.id } }
            explorer.toggle(d3.id)
            let childName = { explorer.rows.compactMap { $0.node?.name }.first { $0.hasPrefix("f") } }
            _ = await waitUntil { childName() == "f" }
            _ = try sql(database, "UPDATE inventory_nodes SET name='f1' WHERE parent_id=\(d3.id)")
            explorer.inventoryChanged()
            let firstSeen = await waitUntil { childName() == "f1" }
            _ = try sql(database, "UPDATE inventory_nodes SET name='f2' WHERE parent_id=\(d3.id)")
            explorer.inventoryChanged()  // within five seconds of the previous re-read
            let secondSeen = await waitUntil(timeout: 8) { childName() == "f2" }
            test(firstSeen && secondSeen, "a change within five seconds of the last re-read still shows in an expanded branch (first \(firstSeen), second \(secondSeen), rows \(explorer.rows.map { $0.node?.name ?? "…" }))")
        } else {
            test(false, "a change within five seconds of the last re-read still shows in an expanded branch (d3 not found)")
        }

        // Living Tree: the controller grows the current folder's tree from the scratch catalog, rebuilds it after a
        // committed change, and lights a measured change; a tree selection opens its folders in the Navigator.
        if let top = model.root {
            let tree = LivingTreeController(database: database)
            tree.show(root: top, trail: [top])
            let built = await waitUntil { tree.model != nil }
            let elements = tree.model?.count ?? 0
            test(built && elements >= 25 && tree.model?.root.id == top.id && tree.arrangement != nil,
                 "the Living Tree grows from the scratch catalog without a window (\(elements) elements, \(tree.statistics.lastReads) folder reads, \(String(format: "%.1f", tree.statistics.lastBuildSeconds * 1000)) ms)")
            tree.inventoryChanged()
            let positioned = await waitUntil { tree.illumination.cursor != nil }
            test(positioned && tree.illumination.glows.isEmpty && tree.statistics.rebuildsAvoided == 1,
                 "its first change read only positions it: nothing is rebuilt and nothing lights up")
            if let d5 = tree.model?[.node(top.id)]?.children.compactMap({ tree.model?[$0]?.node }).first(where: { $0.name == "d5" }) {
                let revision = tree.revision, grown = (d5.allocatedBytes ?? 0) + 1_048_576
                _ = try sql(database, "UPDATE inventory_nodes SET total_allocated=total_allocated+1048576 WHERE id IN (\(d5.id),\(top.id))")
                try? await Task.sleep(for: .milliseconds(1_100))
                tree.inventoryChanged()
                let lit = await waitUntil(timeout: 6) { tree.illumination.glows[d5.id]?.trend == .growth }
                let rebuilt = await waitUntil(timeout: 6) { tree.revision > revision && tree.model?[.node(d5.id)]?.bytes == grown }
                test(lit && rebuilt && tree.illumination.isActive(at: Date()),
                     "a committed size change rebuilds the tree (the branch takes its new size) and lights the folder amber (lit \(lit), rebuilt \(rebuilt))")
                if let file = tree.model?[.node(d5.id)]?.children.compactMap({ tree.model?[$0]?.node }).first,
                   let d7 = tree.model?[.node(top.id)]?.children.compactMap({ tree.model?[$0]?.node }).first(where: { $0.name == "d7" }),
                   let other = try await reader.explorerChildren(parentID: d7.id).items.first {
                    let navigator = InventoryExplorerController(database: database)
                    navigator.show(root: top, trail: [])
                    _ = await waitUntil { navigator.rows.contains { $0.node?.id == d5.id } }
                    navigator.select(file, through: [d5])
                    let shown = await waitUntil { navigator.rows.contains { $0.id == file.id && $0.depth == 1 } }
                    navigator.select(d5, through: [])   // the folder opened for the reveal is itself selected next
                    navigator.select(other, through: [d7])
                    let moved = await waitUntil { navigator.rows.contains { $0.id == other.id } }
                    test(shown && moved && navigator.selection == other.id && !navigator.state.isExpanded(d5.id) && navigator.state.isExpanded(d7.id),
                         "a tree selection opens its folders in the Navigator and closes the ones opened for the previous selection")
                } else { test(false, "a tree selection opens its folders in the Navigator (fixture entries not found)") }
            } else { test(false, "a committed size change lights its folder (d5 not drawn)") }
        } else { test(false, "the Living Tree grows from the scratch catalog (no root)") }

        print("\(passed) inventory model tests passed, \(failures.count) failed")
        if !failures.isEmpty {
            failures.forEach { print("  - \($0)") }
            exit(1)
        }
    }
}
