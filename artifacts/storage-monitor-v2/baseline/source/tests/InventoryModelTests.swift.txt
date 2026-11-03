import Foundation

/// Supplies one already indexed fixture node to the queue without opening or changing a catalog.
private struct ReviewQueuePresentationReader: CleanupReviewInventoryReading {
    let subject: InventoryNode
    private var journal: InventoryChangeCursor { .init(journalID: "presentation-fixture", sequence: 0) }
    func cleanupDiscoveryPage(after cursor: CleanupDiscoveryCursor?, limit: Int) async throws -> CleanupDiscoveryPage {
        .init(nodes: [subject], scannedRows: 1, next: nil, generation: subject.generation, journal: journal, inventoryStale: false, resynchronized: false)
    }
    func cleanupListingDiscoveryPage(directoryID: Int64, after cursor: CleanupListingCursor?, limit: Int) async throws -> CleanupListingDiscoveryPage {
        .init(nodes: [], scannedRows: 0, next: nil, generation: subject.generation, journal: journal, inventoryStale: false)
    }
    func node(id: Int64) async throws -> InventoryNode? { id == subject.id ? subject : nil }
    func changes(since cursor: InventoryChangeCursor?, limit: Int) async throws -> InventoryChangeBatch {
        .init(available: true, journalID: journal.journalID, latestSequence: 0, generation: subject.generation,
              generationStale: false, changes: [], next: journal, complete: true, mustResynchronize: false)
    }
}

/// Holds a preview estimate across evidence replacement without sleeps or filesystem mutation.
private actor PreviewEstimateGate {
    private var started = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var completion: CheckedContinuation<Void, Never>?
    func estimate() async -> ArtifactRecoveryEstimate? {
        started = true
        startWaiters.forEach { $0.resume() }; startWaiters = []
        await withCheckedContinuation { completion = $0 }
        return ArtifactRecoveryEstimate(privateBytes: 4096, files: 1, sharedFiles: 0, hardLinkedFiles: 0, unreadable: 0, complete: true)
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
    }
    func release() { completion?.resume(); completion = nil }
}

/// A deterministic barrier for detached Trash work; owned fixtures are moved to retained locations only.
private final class TrashControllerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    let release = DispatchSemaphore(value: 0)
    var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
    @discardableResult func hit() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

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
            // Camera: Reduce Motion jumps; otherwise an animated zoom steps to its target and stops; a selection off
            // screen is brought into view; a search reveal is framed once per request.
            tree.viewportChanged(CGSize(width: 1000, height: 520))
            tree.reduceMotion = true
            tree.zoom(by: 2, at: CGPoint(x: 500, y: 260), animated: true)
            let jumped = !tree.isMoving && abs(tree.camera.zoom - 2) < 1e-9 && tree.camera == tree.cameraTarget
            tree.reduceMotion = false
            tree.zoom(by: 1.5, at: CGPoint(x: 500, y: 260), animated: true)
            let started = tree.isMoving && tree.camera != tree.cameraTarget
            var frames = 0
            while tree.isMoving && frames < 600 { tree.stepMotion(1.0 / 120); frames += 1 }
            test(jumped && started && !tree.isMoving && abs(tree.camera.zoom - 3) < 1e-9,
                 "the Living Tree camera jumps under Reduce Motion, and otherwise glides to an animated zoom and stops (\(frames) frames)")
            if let model = tree.model, let deep = model.order.last(where: { model[$0]?.node != nil && $0 != model.rootKey }), let framing = tree.framing(for: tree.viewport) {
                tree.setCamera(LivingTreeCamera(zoom: 8, center: nil).panned(by: CGVector(dx: 5_000, dy: 5_000), in: framing), animated: false)
                tree.reduceMotion = true
                tree.bringIntoView(deep)
                let tip = tree.transform(for: tree.viewport).map { $0.apply(tree.layout()!.geometry[deep]!.end) }
                test(tip.map { CGRect(origin: .zero, size: tree.viewport).contains($0) } == true,
                     "a selection outside the view is brought on screen")
                tree.fitTree(animated: false)
                tree.reveal(deep.nodeID!, serial: 41)
                let framed = !tree.cameraTarget.isFit
                tree.fitTree(animated: false)
                tree.reveal(deep.nodeID!, serial: 41)
                test(framed && tree.cameraTarget.isFit, "a search reveal frames its result once; showing the tree again does not reframe it")
                tree.reduceMotion = false
            } else { test(false, "a selection outside the view is brought on screen (no tree)") }
            // 3D: the dome is ready with the tree; dragging turns it at once, Reduce Motion makes key turns jump, each
            // dimension keeps its own camera, and focusing turns the element toward the viewer.
            tree.setCamera(.fit, animated: false)
            tree.zoom(by: 1.8, at: CGPoint(x: 500, y: 260), animated: false)
            let flatCamera = tree.cameraTarget
            tree.setDimension(.depth)
            let domeReady = tree.domeLayout != nil && tree.planeGeometry() != nil && tree.framing(for: tree.viewport) != nil && tree.cameraTarget.isFit
            tree.turn(yaw: 0.3, pitch: 0.1, animated: false)
            let dragged = abs(LivingTreeOrbit.wrap(tree.orbit.yaw - LivingTreeOrbit.standard.yaw - 0.3)) < 1e-9 && !tree.isMoving
            tree.reduceMotion = true
            tree.turn(yaw: 0.35, pitch: 0, animated: true)
            let jumpedTurn = !tree.isMoving && tree.orbit == tree.orbitTarget
            tree.reduceMotion = false
            tree.turn(yaw: -0.35, pitch: 0, animated: true)
            let glides = tree.isMoving
            var turnFrames = 0
            while tree.isMoving && turnFrames < 600 { tree.stepMotion(1.0 / 120); turnFrames += 1 }
            test(domeReady && dragged && jumpedTurn && glides && !tree.isMoving && tree.orbit == tree.orbitTarget,
                 "3D: the dome is built with the tree; dragging turns it at once; Reduce Motion makes key turns jump; otherwise they glide and stop (\(turnFrames) frames)")
            // Turning while zoomed in keeps what is at the centre of the view in place (the orbit pivots on it).
            tree.zoom(by: 3, at: CGPoint(x: 500, y: 260), animated: false)
            func nearestCentre() -> (LivingTreeKey, CGPoint)? {
                guard let framing = tree.framing(for: tree.viewport), let plane = tree.planeGeometry() else { return nil }
                let t = tree.camera.transform(in: framing)
                return plane.branches.filter { $0.depth >= 1 }.map { ($0.key, t.apply($0.end)) }
                    .min { hypot($0.1.x - framing.anchor.x, $0.1.y - framing.anchor.y) < hypot($1.1.x - framing.anchor.x, $1.1.y - framing.anchor.y) }
            }
            if let (key, before) = nearestCentre() {
                for _ in 0..<10 { tree.turn(yaw: 0.06, pitch: 0.01, animated: false) }
                let after = tree.framing(for: tree.viewport).flatMap { f in tree.planeGeometry()?[key].map { tree.camera.transform(in: f).apply($0.end) } }
                test(after.map { hypot($0.x - before.x, $0.y - before.y) < 0.5 } == true, "3D: turning while zoomed in keeps the element at the centre of the view in place (moved \(after.map { String(format: "%.3f", hypot($0.x - before.x, $0.y - before.y)) } ?? "?") pt)")
            } else { test(false, "3D: turning keeps the centre in place (nothing on screen)") }
            tree.endTurn()
            let glidesAfterRelease = tree.isMoving
            var glideFrames = 0
            while tree.isMoving && glideFrames < 600 { tree.stepMotion(1.0 / 120); glideFrames += 1 }
            tree.reduceMotion = true
            for _ in 0..<5 { tree.turn(yaw: 0.06, pitch: 0, animated: false) }
            tree.endTurn()
            test(glidesAfterRelease && !tree.isMoving && glideFrames > 0, "3D: a fast drag keeps turning briefly after release and stops (\(glideFrames) frames); with Reduce Motion it stops at once")
            tree.reduceMotion = false
            tree.setCamera(.fit, animated: false)
            tree.zoom(by: 2, at: CGPoint(x: 500, y: 260), animated: false)
            let depthCamera = tree.cameraTarget
            tree.setDimension(.flat)
            let flatRestored = tree.cameraTarget == flatCamera
            tree.setDimension(.depth)
            test(flatRestored && tree.cameraTarget == depthCamera, "2D and 3D each keep their own view of the folder when switching")
            if let model = tree.model, let target = model[model.rootKey]?.children.first(where: { model[$0]?.node != nil }), let branch = tree.domeLayout?[target] {
                let from = tree.orbitTarget.yaw
                tree.focus(on: target, animated: false)
                test(abs(LivingTreeOrbit.wrap(tree.orbit.yaw - LivingTreeOrbit.yaw(profile: branch.azimuth, from: from))) < 1e-9 && tree.cameraTarget.zoom >= 1 && tree.cameraTarget.center != nil,
                     "3D: focusing an element turns the tree so the element is seen side-on, and frames it")
            } else { test(false, "3D: focusing an element turns the tree (no branch)") }
            tree.setDimension(.flat)
            tree.setCamera(.fit, animated: false)
            tree.zoom(by: 3, at: CGPoint(x: 480, y: 240), animated: false)
            let cameraBeforeChange = tree.cameraTarget
            // Where the tips on screen are.
            func onScreen() -> [LivingTreeKey: CGPoint] {
                guard let framing = tree.framing(for: tree.viewport), let plane = tree.planeGeometry() else { return [:] }
                let t = tree.camera.transform(in: framing), screen = CGRect(origin: .zero, size: tree.viewport)
                return Dictionary(uniqueKeysWithValues: plane.branches.filter { $0.depth >= 1 }.map { ($0.key, t.apply($0.end)) }.filter { screen.contains($0.1) })
            }
            if let d5 = tree.model?[.node(top.id)]?.children.compactMap({ tree.model?[$0]?.node }).first(where: { $0.name == "d5" }) {
                let revision = tree.revision, grown = (d5.allocatedBytes ?? 0) + 1_048_576
                _ = try sql(database, "UPDATE inventory_nodes SET total_allocated=total_allocated+1048576 WHERE id IN (\(d5.id),\(top.id))")
                try? await Task.sleep(for: .milliseconds(1_100))
                tree.inventoryChanged()
                let lit = await waitUntil(timeout: 6) { tree.illumination.glows[d5.id]?.trend == .growth }
                let rebuilt = await waitUntil(timeout: 6) { tree.revision > revision && tree.model?[.node(d5.id)]?.bytes == grown }
                test(lit && rebuilt && tree.illumination.isActive(at: Date()),
                     "a committed size change rebuilds the tree (the branch takes its new size) and lights the folder amber (lit \(lit), rebuilt \(rebuilt))")
                // This change (+1 MB to a tree of a few hundred KB) re-shapes and refits the whole tree; the zoom is kept.
                test(rebuilt && abs(tree.cameraTarget.zoom - cameraBeforeChange.zoom) < 1e-9, "through a rebuild that refits the tree the zoom is kept")
                // A small change elsewhere (+4 KB to another folder) while zoomed in: everything on screen outside that
                // folder stays exactly where it was.
                if let d7 = tree.model?[.node(top.id)]?.children.compactMap({ tree.model?[$0]?.node }).first(where: { $0.name == "d7" }) {
                    try? await Task.sleep(for: .milliseconds(1_600))
                    let before = onScreen(), revisionBefore = tree.revision
                    _ = try sql(database, "UPDATE inventory_nodes SET total_allocated=total_allocated+4096 WHERE id IN (\(d7.id),\(top.id))")
                    tree.inventoryChanged()
                    let again = await waitUntil(timeout: 6) { tree.revision > revisionBefore }
                    let changedKeys = Set(tree.model?.subtree(of: .node(d7.id)) ?? [])
                    let after = onScreen()
                    let moves = before.filter { !changedKeys.contains($0.key) }.compactMap { key, p in after[key].map { hypot($0.x - p.x, $0.y - p.y) } }
                    test(again && moves.count >= 3 && moves.allSatisfy { $0 < 0.5 },
                         "a small change elsewhere while zoomed in moves nothing on screen (\(moves.count) tips, max \(String(format: "%.3f", moves.max() ?? -1)) pt)")
                } else { test(false, "a small change elsewhere while zoomed in moves nothing on screen (d7 not drawn)") }
                // Into a folder and back: the folder starts fitted, the volume returns as it was left.
                if let d5Now = tree.model?[.node(d5.id)]?.node {
                    let before = tree.revision, cameraLeft = tree.cameraTarget
                    tree.show(root: d5Now, trail: [top, d5Now])
                    let entered = await waitUntil(timeout: 6) { tree.model?.root.id == d5.id && tree.revision > before }
                    let fittedThere = tree.cameraTarget.isFit
                    tree.show(root: top, trail: [top])
                    let returned = await waitUntil(timeout: 6) { tree.model?.root.id == top.id }
                    test(entered && fittedThere && returned && tree.cameraTarget == cameraLeft && !cameraLeft.isFit && tree.rememberedCameraCount >= 1,
                         "a folder opened as the trunk starts fitted; returning to the enclosing folder restores its camera")
                }
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

        // Cleanup Inspector controller: evidence follows the selection off the main thread; a slower result for an
        // earlier selection never replaces a newer one; ordinary items cost only a name check; an inventory row
        // change collects evidence again; a vanished subject is reported; the preview is read-only and bounded.
        do {
            let home = scratch.appendingPathComponent("cleanup-home")
            let fm = FileManager.default
            @discardableResult func make(_ relative: String, _ text: String = "x") throws -> String {
                let url = home.appendingPathComponent(relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url); return url.path
            }
            func row(_ path: String, id: Int64, measured: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> InventoryNode? {
                var st = stat(); guard lstat(path, &st) == 0 else { return nil }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                return InventoryNode(id: id, parentID: 0, identity: InventoryIdentity(device: Int64(st.st_dev), inode: UInt64(st.st_ino), birthNanoseconds: Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec), volumeUUID: nil),
                                     path: path, name: (path as NSString).lastPathComponent, kind: isDir ? .directory : .file, logicalBytes: Int64(st.st_size), allocatedBytes: Int64(st.st_blocks) * 512,
                                     previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil, directLogicalBytes: 0, directAllocatedBytes: 0, childCount: 0,
                                     descendantFiles: 0, descendantDirectories: 0, status: .complete, coverageState: "complete", listingState: nil, statusReason: nil, measuredAt: measured, modifiedAt: nil,
                                     generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
            }
            try make("web/package.json", "{\"name\":\"web\"}"); try make("web/package-lock.json", "{}"); try make("web/node_modules/.package-lock.json", "{}")
            try make("web/node_modules/a/index.js", String(repeating: "a", count: 8_192))
            try make("web/src/app.js")
            let environment = ArtifactEnvironment(home: home.path, pathDirectories: [], processes: { ProcessObservation(executables: [], workingDirectories: [], inspected: 100, unreadable: 0) }, git: nil)
            let cleanup = CleanupInspectorController(database: database, environment: environment)
            let deps = row(home.appendingPathComponent("web/node_modules").path, id: 101)!
            let plain = row(home.appendingPathComponent("web/src/app.js").path, id: 102)!
            cleanup.update(deps)
            let first = await waitUntil { cleanup.inspection?.nodeID == 101 }
            test(first && cleanup.inspection?.assessment?.status == .reviewCandidate && cleanup.inspecting == nil, "cleanup inspector: evidence for the selection is collected off the main thread and published")
            let queueInspection = ArtifactInspector.inspect(deps, environment: environment)
            let queueInspectionsBefore = cleanup.statistics.inspections
            cleanup.beginQueueReview(deps)
            test(cleanup.inspecting == deps.id && cleanup.inspection == nil && cleanup.preview == nil,
                 "review queue: selecting a row prepares the shared Inspector without launching a duplicate inspection")
            cleanup.acceptQueueReview(queueInspection, node: deps)
            test(cleanup.inspection == queueInspection && cleanup.inspecting == nil && cleanup.statistics.inspections == queueInspectionsBefore + 1,
                 "review queue: the refreshed queue evidence is adopted by the existing Cleanup Inspector")
            for reason in ["process expiry", "journal invalidation"] {
                let pending = CleanupInspectorController(database: database, environment: environment)
                pending.beginQueueReview(deps)
                pending.acceptQueueReview(queueInspection, node: deps)
                let gate = PreviewEstimateGate()
                pending.previewEstimate = { _ in await gate.estimate() }
                let previewTask = pending.loadPreview(deps)
                await gate.waitForStart()
                let wasLoading = pending.previewLoading && pending.preview == nil
                let observed = ProcessObservation(executables: [], workingDirectories: [], inspected: 1, unreadable: 0)
                let entry = CleanupReviewQueueEntry(node: deps, inspection: queueInspection, journal: nil, processes: observed,
                    invalidationReasons: reason == "journal invalidation" ? ["Inventory changed during preview."] : [])
                let invalidated = entry.inspectionForReview(at: observed.takenAt.addingTimeInterval(reason == "process expiry" ? 21 : 0))!
                pending.acceptQueueReview(invalidated, node: deps)
                let closed = pending.preview == nil && !pending.previewLoading
                await gate.release()
                await previewTask?.value
                test(wasLoading && closed && pending.inspection?.assessment?.status == .insufficientEvidence
                     && pending.preview == nil && !pending.previewLoading,
                     "cleanup inspector: \(reason) cancels a suspended first preview and discards its stale recovery result")
            }
            let presentation = CleanupReviewQueueController(database: database)
            _ = try await presentation.queue.discoverNext(reader: ReviewQueuePresentationReader(subject: deps), environment: environment)
            presentation.cancel() // Publish the retained actor snapshot; starts no catalog/evidence work.
            let published = await waitUntil { presentation.snapshot?.entries.count == 1 }
            presentation.selection = [deps.id]
            let processTime = presentation.snapshot?.entries.first?.freshness.processObservation?.takenAt ?? .distantPast
            presentation.advanceFreshness(to: processTime)
            test(published && presentation.rows.count == 1 && presentation.plan.count == 1 && presentation.snapshot?.progress.reviewCandidates == 1,
                 "review queue: controller publishes fresh candidates consistently in table count and selected plan")
            presentation.advanceFreshness(to: processTime.addingTimeInterval(21))
            test(presentation.rows.isEmpty && presentation.snapshot?.progress.reviewCandidates == 0 && presentation.plan.count == 0
                 && presentation.plan.excludedNonCandidates == [deps.path] && presentation.selection == [deps.id],
                 "review queue: idle controller expiry removes eligibility and plan accounting while preserving explicit selection")
            cleanup.beginQueueReview(plain)
            cleanup.acceptQueueReview(queueInspection, node: deps)
            test(cleanup.inspection == nil && cleanup.inspecting == plain.id,
                 "review queue: late evidence for a previous selection cannot replace the current Inspector subject")
            cleanup.update(deps)
            _ = await waitUntil { cleanup.inspection?.nodeID == deps.id }
            test(CleanupTrashConfirmation.displayPath("/fixture/a\nb\u{202e}txt") == "/fixture/a\\u{a}b\\u{202e}txt"
                 && CleanupTrashConfirmation.displayPath("/fixture/\u{61c}\u{200f}\u{2028}\\u{a}") == "/fixture/\\u{61c}\\u{200f}\\u{2028}\\\\u{a}",
                 "Trash confirmation: control and bidirectional formatting characters are visibly escaped in the exact target")
            model.mode = .review
            model.search = "previous search"
            model.revealReviewCandidate(deps)
            test(model.mode == .explorer && model.pendingReveal?.identity == deps.identity && model.parentID == deps.parentID && model.search.isEmpty,
                 "review queue: Reveal reuses the browser's exact-identity pending selection and enclosing-folder navigation")
            test(InventoryBrowserMode.allCases.contains(.review), "review queue: the destination remains contextual within Disk Inventory browse modes")
            cleanup.update(plain)
            test(cleanup.inspection == nil && cleanup.inspecting == nil && cleanup.ordinary == plain.id && cleanup.statistics.quickSkips == 1, "cleanup inspector: an ordinary file is shown as not a recognized artifact and starts no inspection")
            // A slow inspection for the earlier selection must not replace the newer one.
            let slow = deps.id
            cleanup.inspect = { node, environment in if node.id == slow { Thread.sleep(forTimeInterval: 0.4) }; return ArtifactInspector.inspect(node, environment: environment) }
            let other = row(home.appendingPathComponent("web/node_modules/a").path, id: 103)!
            cleanup.update(deps)
            try make("web/node_modules/a/package.json", "{}")
            let second = row(home.appendingPathComponent("web").path, id: 104)!
            _ = other
            cleanup.update(second)   // web itself is ordinary: nothing to show
            try? await Task.sleep(for: .milliseconds(700))
            test(cleanup.inspection == nil && cleanup.statistics.discarded >= 1, "cleanup inspector: a slower result for an earlier selection is discarded, never shown for a newer one")
            cleanup.inspect = { node, environment in ArtifactInspector.inspect(node, environment: environment) }
            cleanup.update(deps)
            _ = await waitUntil { cleanup.inspection?.nodeID == 101 }
            let before = cleanup.statistics.inspections
            cleanup.update(deps)   // same row: nothing to do
            let changed = row(deps.path, id: 101, measured: Date(timeIntervalSince1970: 1_900_000_000))!
            cleanup.update(changed)   // the inventory remeasured it: collect again
            let again = await waitUntil { cleanup.statistics.inspections == before + 1 }
            test(again, "cleanup inspector: an unchanged inventory row reuses its evidence; a remeasured row collects it again")
            cleanup.loadPreview(changed)
            let previewed = await waitUntil(timeout: 8) { cleanup.preview != nil }
            if case .estimated(let bytes, _)? = cleanup.preview?.recovery { test(previewed && bytes > 0 && cleanup.preview?.target == deps.path, "cleanup inspector: the read-only preview names the target and estimates recovery from a complete bounded walk") }
            else { test(false, "cleanup inspector: the preview estimates recovery (\(String(describing: cleanup.preview?.recovery)))") }
            // An open preview stays open through a refresh of the same item (the Inspector keeps its length and scroll).
            cleanup.refresh(changed)
            let stayedOpen = cleanup.preview != nil
            _ = await waitUntil { cleanup.inspecting == nil }
            try? await Task.sleep(for: .milliseconds(300))
            test(stayedOpen && cleanup.preview != nil && cleanup.inspection?.nodeID == 101, "cleanup inspector: refreshing the evidence keeps an open preview on screen (no collapse, no jump to the top)")
            let count = cleanup.statistics.inspections
            cleanup.inventoryChanged(changed)   // evidence is seconds old: not collected again
            test(cleanup.statistics.inspections == count && cleanup.inspecting == nil, "cleanup inspector: frequent inventory updates do not re-run a fresh inspection")
            // A direct legacy controller call must not bypass production unavailability.
            final class Moved: @unchecked Sendable { var calls = 0 }
            let moved = Moved()
            cleanup.trash = { _ in moved.calls += 1; return nil }
            let requestsBefore = (try? FileManager.default.contentsOfDirectory(atPath: InventoryRequests.directory(database: database).path)) ?? []
            cleanup.moveToTrash(changed, overrideAccepted: false)
            _ = await waitUntil { cleanup.trashResult != nil }
            let requests = (try? FileManager.default.contentsOfDirectory(atPath: InventoryRequests.directory(database: database).path)) ?? []
            test(moved.calls == 0 && cleanup.trashResult?.outcome == .refused(CleanupTrashPolicy.unavailableReason) && requests.sorted() == requestsBefore.sorted() && cleanup.preview != nil,
                 "cleanup inspector: disabled legacy Trash preserves the preview and enqueues no reconciliation request")
            cleanup.update(second) { $0 != 101 }   // the previous subject left the inventory
            test(cleanup.vanished == "node_modules" && cleanup.preview == nil, "cleanup inspector: a subject that disappears is reported and keeps no preview or recommendation")
        } catch { test(false, "cleanup inspector fixture: \(error)") }

        // Exercise explicit confirmed Trash with a retained fixture adapter and the real inventory worker.
        // No test adapter here invokes real Trash or permanently deletes a fixture.
        do {
            let reconciliationRoot = scratch.appendingPathComponent("trash-reconciliation-tree")
            let reconciliationState = scratch.appendingPathComponent("trash-reconciliation-state")
            let parent = reconciliationRoot.appendingPathComponent("parent")
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data("disposable indexed Trash reconciliation fixture".utf8).write(to: parent.appendingPathComponent("ordinary.txt"))
            try Data("newer selection must remain".utf8).write(to: parent.appendingPathComponent("second.txt"))
            try Data("{}".utf8).write(to: parent.appendingPathComponent("package.json"))
            try Data("{}".utf8).write(to: parent.appendingPathComponent("package-lock.json"))
            let dependencies = parent.appendingPathComponent("node_modules")
            try fm.createDirectory(at: dependencies, withIntermediateDirectories: true)
            try Data("retained dependency fixture".utf8).write(to: dependencies.appendingPathComponent("fixture.txt"))
            let indexed = try run(monitor, ["inventory-work", "--root", reconciliationRoot.path, "--data-dir", reconciliationState.path, "--budget", "30"])
            guard indexed.status == 0 else { throw HistoryError.invalid("Trash reconciliation indexing failed: \(indexed.output)") }
            let reconciliationDatabase = reconciliationState.appendingPathComponent("history.sqlite3").path
            let reconciliationReader = InventoryReader(path: reconciliationDatabase)
            let location = try await reconciliationReader.locateDirectory(path: parent.path)
            let indexedChildren = try await reconciliationReader.explorerChildren(parentID: location.node.id).items
            guard let file = indexedChildren.first(where: { $0.name == "ordinary.txt" }),
                  let secondFile = indexedChildren.first(where: { $0.name == "second.txt" }),
                  let candidate = indexedChildren.first(where: { $0.name == "node_modules" }) else {
                throw HistoryError.invalid("missing indexed reconciliation fixtures")
            }
            let environment = ArtifactEnvironment(home: scratch.path, pathDirectories: [], processes: {
                ProcessObservation(executables: [], workingDirectories: [], inspected: 1, unreadable: 0)
            }, git: nil)
            let cleanup = CleanupInspectorController(database: reconciliationDatabase, environment: environment)
            let calls = TrashControllerGate()
            let held = reconciliationState.appendingPathComponent("retained-ordinary-fixture")
            cleanup.trash = { url in
                calls.hit()
                guard calls.release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
                try FileManager.default.moveItem(at: url, to: held); return held
            }
            let unrecognizedDirectory = parent.appendingPathComponent(".codex-fixture/packages/standalone/releases/incomplete-layout")
            try fm.createDirectory(at: unrecognizedDirectory, withIntermediateDirectories: true)
            var unrecognizedStat = stat(); guard lstat(unrecognizedDirectory.path, &unrecognizedStat) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
            let checkedUnrecognized = InventoryNode(id: secondFile.id + 1000, parentID: location.node.id,
                identity: .init(device: Int64(unrecognizedStat.st_dev), inode: UInt64(unrecognizedStat.st_ino), birthNanoseconds: Int64(unrecognizedStat.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(unrecognizedStat.st_birthtimespec.tv_nsec)),
                path: unrecognizedDirectory.path, name: unrecognizedDirectory.lastPathComponent, kind: .directory, logicalBytes: nil, allocatedBytes: nil,
                previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil, directLogicalBytes: 0, directAllocatedBytes: 0,
                childCount: 0, descendantFiles: 0, descendantDirectories: 0, status: .complete, coverageState: "complete", listingState: nil, statusReason: nil,
                measuredAt: nil, modifiedAt: nil, generation: file.generation, isHardlinkAlias: false, historicalGrowthBytes: nil)
            cleanup.update(checkedUnrecognized)
            _ = await waitUntil { cleanup.inspecting == nil }
            let ordinaryEligible: Bool = { if case .allowed = cleanup.trashDecision(checkedUnrecognized) { return true }; return false }()
            test(cleanup.ordinary == checkedUnrecognized.id && cleanup.inspection?.classification == nil && ordinaryEligible,
                 "Trash confirmation: checked unrecognized detector false positives retain the ordinary-item action")
            cleanup.update(file)
            await cleanup.prepareTrash(file)?.value
            test(cleanup.trashConfirmation?.node.identity == file.identity && cleanup.trashConfirmation?.node.path == file.path,
                 "Trash confirmation: async preparation presents the exact current selected identity and path")
            guard let cancelled = cleanup.trashConfirmation else { throw HistoryError.invalid("missing displayed fixture confirmation") }
            cleanup.cancelTrashConfirmation()
            cleanup.moveToTrash(cancelled, overrideAccepted: true)
            test(calls.calls == 0 && fm.fileExists(atPath: file.path) && !cleanup.trashing,
                 "Trash confirmation: Cancel consumes displayed authorization and leaves target untouched")
            await cleanup.prepareTrash(file)?.value
            guard let displayed = cleanup.trashConfirmation,
                  case .ready(let external) = CleanupTrashPolicy.prepare(node: file, environment: environment) else { throw HistoryError.invalid("fixture confirmation unavailable") }
            cleanup.moveToTrash(external, overrideAccepted: true)
            test(calls.calls == 0 && cleanup.trashConfirmation === displayed,
                 "Trash confirmation: an independently valid token cannot replace the currently displayed sheet token")
            cleanup.update(secondFile)
            cleanup.moveToTrash(displayed, overrideAccepted: true)
            test(calls.calls == 0 && cleanup.trashConfirmation == nil && cleanup.ordinary == secondFile.id,
                 "Trash confirmation: changing selection invalidates the old sheet without touching either item")

            // Cancellation propagates to the detached preparation, not just its eventual UI publication.
            let preparationGate = TrashControllerGate()
            var delayedEnvironment = environment
            delayedEnvironment.processes = {
                if preparationGate.hit() == 1 { _ = preparationGate.release.wait(timeout: .now() + 5) }
                return ProcessObservation(executables: [], workingDirectories: [], inspected: 1, unreadable: 0)
            }
            let delayed = CleanupInspectorController(database: reconciliationDatabase, environment: delayedEnvironment)
            delayed.update(file)
            let pendingPreparation = delayed.prepareTrash(file)
            let beganPreparation = await waitUntil { preparationGate.calls > 0 }
            delayed.update(secondFile)
            preparationGate.release.signal()
            await pendingPreparation?.value
            test(beganPreparation && !delayed.preparingTrash && delayed.trashConfirmation == nil && delayed.ordinary == secondFile.id,
                 "Trash confirmation: selection changes cancel detached preparation and suppress its stale sheet")

            cleanup.update(file)
            await cleanup.prepareTrash(file)?.value
            guard let approved = cleanup.trashConfirmation else { throw HistoryError.invalid("missing approved fixture confirmation") }
            cleanup.moveToTrash(approved, overrideAccepted: true)
            let entered = await waitUntil { calls.calls == 1 }
            cleanup.moveToTrash(approved, overrideAccepted: true) // duplicate callback cannot cancel in-flight execution
            cleanup.update(secondFile)
            calls.release.signal()
            let finished = await waitUntil { !cleanup.trashing }
            test(entered && finished && calls.calls == 1 && cleanup.trashResult?.outcome == .moved(trashPath: held.path)
                 && fm.fileExists(atPath: held.path) && !fm.fileExists(atPath: file.path),
                 "Trash execution: one displayed confirmation moves exactly one retained fixture despite duplicate requests")
            test(cleanup.ordinary == secondFile.id && cleanup.inspection == nil,
                 "Trash execution: completing an earlier move preserves a newer Inspector selection")
            let requests = (try? fm.contentsOfDirectory(atPath: InventoryRequests.directory(database: reconciliationDatabase).path)) ?? []
            test(requests.contains(where: { $0.hasSuffix(".json") && $0 != "focus.json" }),
                 "Trash reconciliation: successful execution queues the existing parent refresh request")
            let reconciled = try run(monitor, ["inventory-work", "--root", reconciliationRoot.path, "--data-dir", reconciliationState.path, "--budget", "30"])
            let after = try await reconciliationReader.node(id: file.id)
            let children = try await reconciliationReader.explorerChildren(parentID: location.node.id)
            test(reconciled.status == 0 && after == nil && !children.items.contains(where: { $0.id == file.id }) && fm.fileExists(atPath: held.path),
                 "Trash reconciliation: real isolated worker consumes the refresh and removes only the moved target from inventory")

            let queue = CleanupReviewQueueController(database: reconciliationDatabase)
            queue.discover()
            let discovered = await waitUntil(timeout: 10) { !queue.loading }
            queue.selection = [candidate.id]
            queue.reviewSelection(cleanup: cleanup)
            let reviewed = await waitUntil(timeout: 10) { !queue.reviewing }
            test(discovered && reviewed && queue.snapshot?.entries.contains(where: { $0.id == candidate.id }) == true && cleanup.inspection?.nodeID == candidate.id,
                 "Trash reconciliation: candidate queue and shared Inspector start with the same indexed target")
            let retainedCandidate = reconciliationState.appendingPathComponent("retained-candidate-fixture")
            cleanup.trash = { url in try FileManager.default.moveItem(at: url, to: retainedCandidate); return retainedCandidate }
            guard let currentCandidate = queue.inspectorNode, currentCandidate.id == candidate.id,
                  currentCandidate.path == candidate.path, currentCandidate.identity == candidate.identity else {
                throw HistoryError.invalid("queue selected a different candidate identity")
            }
            let obsoletePreparation = cleanup.prepareTrash(candidate)
            test(obsoletePreparation == nil && cleanup.trashConfirmation == nil
                 && CleanupInspectorController.fingerprint(candidate) != CleanupInspectorController.fingerprint(currentCandidate),
                 "Trash confirmation: a pre-refresh inventory row cannot authorize the newly reviewed candidate")
            await cleanup.prepareTrash(currentCandidate)?.value
            guard let candidateConfirmation = cleanup.trashConfirmation else { throw HistoryError.invalid("candidate confirmation unavailable") }
            cleanup.moveToTrash(candidateConfirmation, overrideAccepted: false)
            _ = await waitUntil { !cleanup.trashing }
            test(cleanup.trashResult?.outcome == .moved(trashPath: retainedCandidate.path) && cleanup.inspection == nil && cleanup.preview == nil,
                 "Trash reconciliation: successful candidate move clears stale Inspector evidence and preview immediately")
            let candidateReconciled = try run(monitor, ["inventory-work", "--root", reconciliationRoot.path, "--data-dir", reconciliationState.path, "--budget", "30"])
            queue.inventoryChanged(cleanup: cleanup)
            let queueReconciled = await waitUntil(timeout: 10) { !queue.selection.contains(candidate.id) && queue.inspectorNode == nil }
            test(candidateReconciled.status == 0 && queueReconciled && queue.snapshot?.entries.contains(where: { $0.id == candidate.id }) == false && cleanup.inspection == nil,
                 "Trash reconciliation: journal refresh removes the vanished Queue candidate, plan selection and shared Inspector")

            cleanup.update(secondFile)
            cleanup.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
            await cleanup.prepareTrash(secondFile)?.value
            guard let failureConfirmation = cleanup.trashConfirmation else { throw HistoryError.invalid("failure confirmation unavailable") }
            cleanup.moveToTrash(failureConfirmation, overrideAccepted: true)
            _ = await waitUntil { !cleanup.trashing }
            let failure: Bool = { if case .failed(let why)? = cleanup.trashResult?.outcome { return why.contains("not confirmed") }; return false }()
            let failureRequests = (try? fm.contentsOfDirectory(atPath: InventoryRequests.directory(database: reconciliationDatabase).path)) ?? []
            test(failure && fm.fileExists(atPath: secondFile.path) && failureRequests.contains(where: { $0.hasSuffix(".json") && $0 != "focus.json" }),
                 "Trash failure: uncertain API outcome requests reconciliation, reports error and never retries automatically")

        } catch { test(false, "Trash reconciliation fixture: \(error)") }

        print("\(passed) inventory model tests passed, \(failures.count) failed")
        if !failures.isEmpty {
            failures.forEach { print("  - \($0)") }
            exit(1)
        }
    }
}
