import Foundation
import CoreGraphics

// Living Tree model tests: hierarchy, thickness, grouped accounting, deterministic and stable layout, selection
// and keyboard movement, hit testing, illumination (growth, reduction, confidence, resynchronization, Reduce
// Motion), large and unmeasured folders, and bounds. Synthetic catalogs only; nothing reads the filesystem.

private func treeNode(_ id: Int64, parent: Int64?, _ name: String, folder: Bool, size: Int64?, status: InventoryValueStatus = .complete, children: Int64 = 0) -> InventoryNode {
    let known = status != .stale && status != .unknown
    return InventoryNode(id: id, parentID: parent, identity: InventoryIdentity(device: 1, inode: UInt64(id), birthNanoseconds: 1), path: "/t/\(name)", name: name,
                         kind: folder ? .directory : .file, logicalBytes: known ? size : nil, allocatedBytes: known ? size : nil,
                         previousLogicalBytes: status == .stale ? size : nil, previousAllocatedBytes: status == .stale ? size : nil, objectLogicalBytes: nil, objectAllocatedBytes: nil,
                         directLogicalBytes: 0, directAllocatedBytes: 0, childCount: children, descendantFiles: 0, descendantDirectories: 0, status: status,
                         coverageState: status == .unknown ? "inaccessible" : (status == .lowerBound ? "partial" : "complete"), listingState: nil,
                         statusReason: status == .unknown ? "permissions" : nil, measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
}

/// An in-memory catalog: folders total their children, and reads return entries in explorer order (largest first,
/// unmeasured last, then name and id) with the exact totals of the rest, as `InventoryReader.explorerSpan` does.
private struct TreeCatalog {
    struct Entry { var parent: Int64?; var name: String; var folder: Bool; var size: Int64?; var status: InventoryValueStatus }
    var entries = [Int64: Entry]()
    var children = [Int64: [Int64]]()
    var nodes = [Int64: InventoryNode]()
    private var next: Int64 = 1

    @discardableResult mutating func add(_ parent: Int64?, _ name: String, folder: Bool = false, size: Int64? = nil, status: InventoryValueStatus = .complete) -> Int64 {
        let id = next; next += 1
        entries[id] = Entry(parent: parent, name: name, folder: folder, size: size, status: status)
        if let parent { children[parent, default: []].append(id) }
        return id
    }
    mutating func resize(_ id: Int64, _ size: Int64) { entries[id]!.size = size }

    /// Folder sizes become the sum of their measured children (unknown folders stay unknown).
    mutating func finalize() {
        func total(_ id: Int64) -> Int64? {
            let entry = entries[id]!
            guard entry.folder else { return entry.status == .unknown ? nil : entry.size }
            let sums = (children[id] ?? []).map(total)
            guard entry.status != .unknown else { return nil }
            return sums.reduce(Int64(0)) { $0 + ($1 ?? 0) }
        }
        nodes = [:]
        for (id, entry) in entries {
            nodes[id] = treeNode(id, parent: entry.parent, entry.name, folder: entry.folder, size: total(id), status: entry.status, children: Int64(children[id]?.count ?? 0))
        }
    }

    func ordered(_ parent: Int64) -> [InventoryNode] {
        (children[parent] ?? []).map { nodes[$0]! }.sorted { a, b in
            let x = InventoryMapPlan.weight(a), y = InventoryMapPlan.weight(b)
            if x != y { return (x ?? -1) > (y ?? -1) }
            if a.name.lowercased() != b.name.lowercased() { return a.name.lowercased() < b.name.lowercased() }
            return a.id < b.id
        }
    }

    func span(_ parent: Int64, _ count: Int) -> LivingTreeBuilder.Span {
        let all = ordered(parent)
        let page = Array(all.prefix(count)), rest = all.dropFirst(count)
        guard let last = page.last, !rest.isEmpty else { return (InventoryChildPage(items: page, next: nil), nil) }
        let remainder = InventoryChildRemainder(count: Int64(rest.count), allocated: rest.reduce(Int64(0)) { $0 + (InventoryMapPlan.weight($1) ?? 0) },
                                                unmeasured: Int64(rest.filter { InventoryMapPlan.weight($0) == nil }.count))
        return (InventoryChildPage(items: page, next: InventoryChildCursor(allocated: InventoryMapPlan.weight(last), name: last.name, id: last.id)), remainder)
    }

    func build(budget: LivingTreeBudget, memory: LivingTreeMemory = LivingTreeMemory(), pinned: [Int64] = []) -> LivingTreeModel {
        var chain = [InventoryNode]()
        if let target = pinned.last { var current: Int64? = target; while let id = current, id != 1 { chain.insert(nodes[id]!, at: 0); current = nodes[id]!.parentID } }
        return LivingTreeBuilder.build(root: nodes[1]!, pinned: chain, budget: budget, memory: memory) { span($0, $1) }
    }
}

/// A Mac-like fixture: a root with system, library, user and application folders, large and tiny files,
/// a protected folder, an earlier-size folder and a partially measured one.
private func standardCatalog(projectA: Int64 = 30_000_000, documentsScale: Int64 = 1, moviesScale: Int64 = 1, tinyGrowth: Int64 = 0) -> (TreeCatalog, [String: Int64]) {
    var c = TreeCatalog(), ids = [String: Int64]()
    let root = c.add(nil, "", folder: true)
    let library = c.add(root, "Library", folder: true); ids["Library"] = library
    for i in 0..<30 { c.add(library, "lib\(i).dat", size: Int64(1_000_000 * (i + 1))) }
    let caches = c.add(library, "Caches", folder: true); ids["Caches"] = caches
    for i in 0..<50 { c.add(caches, "c\(i)", size: 4_096) }
    ids["Containers"] = c.add(library, "Containers", folder: true, status: .unknown)
    let users = c.add(root, "Users", folder: true); ids["Users"] = users
    let home = c.add(users, "nick", folder: true); ids["nick"] = home
    let documents = c.add(home, "Documents", folder: true); ids["Documents"] = documents
    for i in 0..<40 { c.add(documents, "doc\(i).pdf", size: Int64(100_000 + 95_000 * i) * documentsScale) }
    let movies = c.add(home, "Movies", folder: true); ids["Movies"] = movies
    ids["film"] = c.add(movies, "film.mov", size: 2_000_000_000 * moviesScale)
    c.add(movies, "clip.mov", size: 1_000_000_000 * moviesScale)
    c.add(movies, "trailer.mov", size: 500_000_000 * moviesScale)
    let projects = c.add(home, "Projects", folder: true); ids["Projects"] = projects
    for (name, scale) in [("a", projectA), ("b", 30_000_000), ("c", 30_000_000)] {
        let folder = c.add(projects, name, folder: true); ids["Projects/" + name] = folder
        for i in 0..<10 { c.add(folder, "\(name)\(i).swift", size: scale / 10) }
    }
    let deep = c.add(home, "deep", folder: true)
    let deeper = c.add(deep, "deeper", folder: true)
    ids["tiny"] = c.add(deeper, "tiny.txt", size: 1_024 + tinyGrowth)
    for i in 0..<60 { c.add(deeper, "filler\(i)", size: 40_000) }
    let apps = c.add(root, "Applications", folder: true); ids["Applications"] = apps
    for i in 0..<12 {
        let app = c.add(apps, "App\(i).app", folder: true)
        for j in 0..<3 { c.add(app, "part\(j)", size: Int64(20_000_000 * (i + 1) + j)) }
    }
    let system = c.add(root, "System", folder: true, status: .stale); ids["System"] = system
    for i in 0..<8 { c.add(system, "sys\(i)", size: 300_000_000, status: .stale) }
    let partial = c.add(root, "private", folder: true, status: .lowerBound); ids["private"] = partial
    for i in 0..<5 { c.add(partial, "var\(i)", size: 50_000_000, status: .lowerBound) }
    ids["big"] = c.add(root, "big.bin", size: 5_000_000_000)
    ids["small"] = c.add(root, "small.txt", size: 1_024)
    c.finalize()
    return (c, ids)
}

func livingTreeModelTests(_ test: (Bool, String) throws -> Void) throws {
    let wide = LivingTreeBudget(elements: 2_000, perFolder: 64, slack: 0, minimumShare: 0)
    let (catalog, ids) = standardCatalog()
    let full = catalog.build(budget: wide)

    // MARK: Hierarchy
    var hierarchy = true
    for key in full.order {
        let element = full[key]!
        if key == full.rootKey { hierarchy = hierarchy && element.parent == nil && element.depth == 0; continue }
        guard let parent = element.parent, let parentElement = full[parent] else { hierarchy = false; break }
        hierarchy = hierarchy && element.depth == parentElement.depth + 1 && parentElement.children.contains(key) && full.order.firstIndex(of: parent)! < full.order.firstIndex(of: key)!
        if let node = element.node { hierarchy = hierarchy && parent == .node(node.parentID!) && catalog.children[node.parentID!]!.contains(node.id) }
        if case .rest(let folder) = key { hierarchy = hierarchy && parent == .node(folder) }
    }
    try test(hierarchy && Set(full.order).count == full.order.count && full.count == full.order.count,
             "living tree: every element hangs from its actual parent folder, one level deeper, listed once, parents before children (\(full.count) elements)")
    try test(full[.node(ids["film"]!)]?.role == .file && full[.node(ids["Movies"]!)]?.role == .branch && full[.node(ids["Movies"]!)]?.expanded == true && full[full.rootKey]?.role == .trunk,
             "living tree: the current folder is the trunk, folders are branches and files are terminal elements, keyed by inventory node id")

    // MARK: Grouped accounting
    let small = LivingTreeBudget(elements: 90, perFolder: 6, slack: 2, minimumShare: 0)
    let bounded = catalog.build(budget: small)
    var accounting = true, folders = 0
    for key in bounded.order where bounded[key]!.expanded {
        guard let folder = key.nodeID else { continue }
        folders += 1
        let all = catalog.ordered(folder)
        let elements = bounded[key]!.children.map { bounded[$0]! }
        let drawnBytes = elements.filter { $0.role != .rest }.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let rest = bounded[.rest(folder)]
        let total = all.reduce(Int64(0)) { $0 + (InventoryMapPlan.weight($1) ?? 0) }
        let unmeasured = Int64(all.filter { InventoryMapPlan.weight($0) == nil }.count)
        let drawnUnmeasured = Int64(elements.filter { $0.role == .unmeasured }.count)
        let counted = Int64(elements.filter { $0.role != .rest }.count) + (rest?.count ?? 0)
        accounting = accounting && drawnBytes + (rest?.bytes ?? 0) == total && counted == Int64(all.count) && drawnUnmeasured + (rest?.unmeasured ?? 0) == unmeasured
    }
    try test(accounting && folders > 3 && bounded.count <= small.elements,
             "living tree: in every expanded folder, drawn entries plus the grouped remainder equal the folder's indexed children exactly (bytes, items, unmeasured; \(folders) folders)")
    let caches = bounded[.rest(ids["Caches"]!)] ?? full[.rest(ids["Caches"]!)]
    try test(bounded[.rest(1)].map { $0.role == .rest && $0.count > 0 && $0.bytes != nil } == true && (caches == nil || caches!.bytes! == caches!.count * 4_096),
             "living tree: small files are grouped into one terminal element per folder that keeps their exact total")

    // MARK: Protected and unmeasured
    let containers = full[.node(ids["Containers"]!)]
    try test(containers?.role == .unmeasured && containers?.bytes == nil && containers?.expanded == false && containers?.sizeKnown == false,
             "living tree: a protected folder is a marked stub with an unknown size, never a zero-sized branch, and is not opened")
    let arrangedFull = { () -> (LivingTreeArrangement, LivingTreeGeometry) in var m = LivingTreeMemory(); let a = LivingTreeArranger.arrange(full, memory: &m); return (a, LivingTreeGeometer.layout(full, a, in: CGSize(width: 1200, height: 700))) }()
    let geometry = arrangedFull.1
    try test(geometry[.node(ids["Containers"]!)].map { !$0.sizeKnown && $0.startWidth == LivingTreeGeometer.minimumWidth } == true
             && LivingTreeGeometer.width(bytes: nil, trunkBytes: 100, trunkWidth: 20) == nil && LivingTreeGeometer.width(bytes: 0, trunkBytes: 100, trunkWidth: 20) == LivingTreeGeometer.minimumWidth,
             "living tree: an unknown size has no width from size (a marked hairline), distinct from a measured zero")
    try test(full[.node(ids["System"]!)]?.status == .stale && full[.node(ids["private"]!)]?.status == .lowerBound
             && LivingTreePalette.opacity(depth: 1, status: .stale, sizeKnown: true) < LivingTreePalette.opacity(depth: 1, status: .lowerBound, sizeKnown: true)
             && LivingTreePalette.opacity(depth: 1, status: .lowerBound, sizeKnown: true) < LivingTreePalette.opacity(depth: 1, status: .complete, sizeKnown: true),
             "living tree: earlier and partial measurement states are kept on their elements and drawn quieter than complete ones")
    var unknownRoot = TreeCatalog(); let protectedRoot = unknownRoot.add(nil, "", folder: true, status: .unknown); unknownRoot.add(protectedRoot, "x", size: 5); unknownRoot.finalize()
    let unknownTree = unknownRoot.build(budget: .standard)
    try test(unknownTree.count == 1 && unknownTree.reads == 0 && unknownTree.trunkBytes == nil,
             "living tree: a trunk without a measured size is not read into or drawn by size")

    // MARK: Thickness
    let trunkBytes = Double(full.trunkBytes!), T = geometry.trunkWidth
    var proportional = true, checked = 0
    for branch in geometry.branches where branch.key != full.rootKey && branch.sizeKnown && branch.startWidth > LivingTreeGeometer.minimumWidth {
        let bytes = Double(full[branch.key]!.bytes!)
        proportional = proportional && abs(Double(branch.startWidth / T) * Double(branch.startWidth / T) - bytes / trunkBytes) < 1e-9
        checked += 1
    }
    var nested = true
    for key in full.order where full[key]!.expanded && key != full.rootKey {
        let parentWidth = geometry[key]!.startWidth
        let childArea = full[key]!.children.compactMap { geometry[$0] }.filter { $0.sizeKnown && $0.startWidth > LivingTreeGeometer.minimumWidth }.reduce(CGFloat(0)) { $0 + $1.startWidth * $1.startWidth }
        nested = nested && childArea <= parentWidth * parentWidth * (1 + 1e-9)
    }
    try test(proportional && nested && checked > 50,
             "living tree: branch cross-section is proportional to indexed allocated size, and a folder's children together are never thicker than it (\(checked) branches)")

    // MARK: Deterministic layout
    var m1 = LivingTreeMemory(), m2 = LivingTreeMemory()
    let again = catalog.build(budget: wide)
    let a1 = LivingTreeArranger.arrange(full, memory: &m1), a2 = LivingTreeArranger.arrange(again, memory: &m2)
    let g1 = LivingTreeGeometer.layout(full, a1, in: CGSize(width: 1200, height: 700)), g2 = LivingTreeGeometer.layout(again, a2, in: CGSize(width: 1200, height: 700))
    try test(full.order == again.order && a1 == a2 && g1.branches == g2.branches && m1 == m2,
             "living tree: the same catalog always gives the same tree, arrangement and geometry")
    let inside = geometry.branches.allSatisfy { CGRect(x: 0, y: 0, width: 1200, height: 700).insetBy(dx: -2, dy: -2).contains($0.end) }
    var nestedSectors = true
    for key in full.order { if let parent = full[key]!.parent, let p = a1.placements[parent], let c = a1.placements[key] { nestedSectors = nestedSectors && c.lower >= p.lower - 1e-9 && c.upper <= p.upper + 1e-9 && c.angle >= c.lower && c.angle <= c.upper } }
    var disjoint = true
    for (_, row) in a1.siblings { for (x, y) in zip(row, row.dropFirst()) { disjoint = disjoint && a1.placements[x]!.upper <= a1.placements[y]!.lower + 1e-9 } }
    try test(inside && nestedSectors && disjoint,
             "living tree: each branch grows inside its parent's sector, siblings take separate sectors (no shared directions), and every tip stays on the canvas")

    // After deep folders' children are drawn closer together (no combs along the rim), each top-level subtree's tips
    // still occupy their own range of directions from the crown: drawn subtrees do not interleave.
    func tipAngle(_ branch: LivingTreeGeometry.Branch) -> Double { atan2(Double(branch.end.x - geometry.crown.x), Double(geometry.crown.y - branch.end.y)) }
    let spans = full[full.rootKey]!.children.compactMap { key -> (Double, Double)? in
        let angles = full.subtree(of: key).compactMap { geometry[$0] }.map(tipAngle)
        return angles.isEmpty ? nil : (angles.min()!, angles.max()!)
    }.sorted { $0.0 < $1.0 }
    try test(spans.count > 4 && zip(spans, spans.dropFirst()).allSatisfy { $0.1 <= $1.0 + 1e-9 } && spans.allSatisfy { $0.0 >= -LivingTreeArranger.fan - 1e-9 && $0.1 <= LivingTreeArranger.fan + 1e-9 },
             "living tree: drawn top-level subtrees occupy separate ranges of direction from the crown (no interleaving) within the crown's fan")

    // MARK: Stability across small changes
    func positions(_ g: LivingTreeGeometry) -> [LivingTreeKey: [CGPoint]] {
        Dictionary(uniqueKeysWithValues: g.branches.map { ($0.key, [$0.start, $0.control1, $0.control2, $0.end]) })
    }
    var memory = LivingTreeMemory()
    let before = catalog.build(budget: wide, memory: memory)
    let beforeGeometry = LivingTreeGeometer.layout(before, LivingTreeArranger.arrange(before, memory: &memory), in: CGSize(width: 1200, height: 700))
    let (grown, _) = standardCatalog(tinyGrowth: 31)   // tiny.txt grows 3%
    let afterSmall = grown.build(budget: wide, memory: memory)
    var smallMemory = memory
    let afterSmallGeometry = LivingTreeGeometer.layout(afterSmall, LivingTreeArranger.arrange(afterSmall, memory: &smallMemory), in: CGSize(width: 1200, height: 700))
    try test(positions(beforeGeometry) == positions(afterSmallGeometry) && afterSmallGeometry[.node(ids["tiny"]!)]!.startWidth >= beforeGeometry[.node(ids["tiny"]!)]!.startWidth,
             "living tree: a small measurement change moves nothing (thickness still follows the new size)")
    let (shifted, _) = standardCatalog(projectA: 39_000_000)   // Projects/a grows 30%
    let afterLarge = shifted.build(budget: wide, memory: memory)
    var largeMemory = memory
    let afterLargeGeometry = LivingTreeGeometer.layout(afterLarge, LivingTreeArranger.arrange(afterLarge, memory: &largeMemory), in: CGSize(width: 1200, height: 700))
    let projectsSubtree = Set(afterLarge.subtree(of: .node(ids["Projects"]!)))
    let outside = positions(beforeGeometry).filter { !projectsSubtree.contains($0.key) }
    let moved = positions(afterLargeGeometry).filter { projectsSubtree.contains($0.key) } != positions(beforeGeometry).filter { projectsSubtree.contains($0.key) }
    try test(outside == positions(afterLargeGeometry).filter { !projectsSubtree.contains($0.key) } && moved,
             "living tree: a larger change re-shapes only the folder that changed; the rest of the tree keeps its place")
    let (swapped, _) = standardCatalog(documentsScale: 400, moviesScale: 1)   // Documents becomes larger than Movies
    var swapMemory = memory
    let swappedTree = swapped.build(budget: wide, memory: memory)
    let swappedArrangement = LivingTreeArranger.arrange(swappedTree, memory: &swapMemory)
    var freshMemory = LivingTreeMemory()
    let freshArrangement = LivingTreeArranger.arrange(swappedTree, memory: &freshMemory)
    let homeKey = LivingTreeKey.node(ids["nick"]!)
    let originalArrangement = { () -> LivingTreeArrangement in var m = LivingTreeMemory(); return LivingTreeArranger.arrange(before, memory: &m) }()
    try test(swappedArrangement.siblings[homeKey] == originalArrangement.siblings[homeKey] && freshArrangement.siblings[homeKey] != originalArrangement.siblings[homeKey],
             "living tree: sibling order is remembered: folders that swap size ranks keep their places")
    // Membership hysteresis: an element drawn last time stays drawn after slipping just past the per-folder limit.
    var hysteresis = TreeCatalog(); let hRoot = hysteresis.add(nil, "", folder: true)
    for i in 0..<10 { hysteresis.add(hRoot, "f\(i)", size: Int64(1_000 - i * 10)) }
    hysteresis.finalize()
    let tight = LivingTreeBudget(elements: 100, perFolder: 5, slack: 2, minimumShare: 0)
    var hMemory = LivingTreeMemory()
    let first = hysteresis.build(budget: tight, memory: hMemory)
    _ = LivingTreeArranger.arrange(first, memory: &hMemory)
    let fifth = hysteresis.children[hRoot]![4]
    hysteresis.resize(hysteresis.children[hRoot]![5], 965)   // f5 overtakes f4 by a little
    hysteresis.finalize()
    let second = hysteresis.build(budget: tight, memory: hMemory)
    let fresh = hysteresis.build(budget: tight)
    try test(first[.node(fifth)] != nil && second[.node(fifth)] != nil && fresh[.node(fifth)] == nil,
             "living tree: an element drawn last time stays drawn when it slips just past the limit (hysteresis), while a fresh tree would group it")

    // MARK: Selection and navigation
    let (arrangement, _) = arrangedFull
    let moviesKey = LivingTreeKey.node(ids["Movies"]!)
    let largestRootChild = full[full.rootKey]!.children.max { (full[$0]!.bytes ?? -1, $1) < (full[$1]!.bytes ?? -1, $0) }!
    try test(LivingTreeNavigation.move(.towardTips, from: full.rootKey, in: full, arrangement: arrangement) == largestRootChild
             && LivingTreeNavigation.move(.towardTrunk, from: moviesKey, in: full, arrangement: arrangement) == homeKey
             && LivingTreeNavigation.move(.towardTips, from: moviesKey, in: full, arrangement: arrangement) == .node(ids["film"]!)
             && LivingTreeNavigation.move(.towardTrunk, from: full.rootKey, in: full, arrangement: arrangement) == full.rootKey
             && LivingTreeNavigation.move(.towardTips, from: nil, in: full, arrangement: arrangement) == full.rootKey,
             "living tree keyboard: ↑ moves toward the tips (largest child), ↓ toward the trunk, and nothing selected starts at the trunk")
    let row = arrangement.siblings[homeKey]!
    try test(row.count > 2 && LivingTreeNavigation.move(.nextSibling, from: row[0], in: full, arrangement: arrangement) == row[1]
             && LivingTreeNavigation.move(.previousSibling, from: row[1], in: full, arrangement: arrangement) == row[0]
             && LivingTreeNavigation.move(.previousSibling, from: row[0], in: full, arrangement: arrangement) == row[0]
             && LivingTreeNavigation.move(.nextSibling, from: row.last!, in: full, arrangement: arrangement) == row.last!,
             "living tree keyboard: ← and → move between siblings in their drawn order and stop at the ends")
    let parents: (Int64) -> Int64? = { catalog.nodes[$0]?.parentID }
    let groupedFile = catalog.children[ids["Caches"]!]![3]
    try test(bounded.displayKey(forNode: ids["big"]!, parentOf: parents) == .node(ids["big"]!)
             && bounded.displayKey(forNode: catalog.children[1]!.first { catalog.nodes[$0]!.name == "small.txt" }!, parentOf: parents) == .rest(1)
             && (bounded[.node(ids["Caches"]!)]?.expanded == true ? bounded.displayKey(forNode: groupedFile, parentOf: parents) == .rest(ids["Caches"]!) : bounded.displayKey(forNode: groupedFile, parentOf: parents) != nil),
             "living tree selection: a drawn entry shows itself; a grouped small file shows its folder's grouped element")
    let twigChild = catalog.children[ids["Projects/a"]!]![0]
    let nearest = bounded.displayKey(forNode: twigChild, parentOf: parents)
    try test(nearest != nil && bounded[nearest!] != nil && bounded.displayKey(forNode: 999_999, parentOf: { _ in nil }) == nil,
             "living tree selection: an entry beneath an unopened branch shows its nearest drawn folder; an unknown entry shows nothing")
    let chain = full.ancestry(of: .node(ids["film"]!))
    try test(chain.first == full.rootKey && chain.last == .node(ids["film"]!) && chain.dropFirst().dropLast().compactMap(\.nodeID) == [ids["Users"]!, ids["nick"]!, ids["Movies"]!],
             "living tree → navigator: a deep selection carries the folders between the trunk and it, to open in the Navigator")
    var navigator = InventoryExplorerState()
    navigator.setRoot(catalog.nodes[1]!)
    navigator.receive(parent: 1, page: InventoryChildPage(items: catalog.ordered(1), next: nil))
    for folder in [ids["Users"]!, ids["nick"]!, ids["Movies"]!] {
        navigator.update(catalog.nodes[folder]!)
        _ = navigator.expand(folder)
        navigator.receive(parent: folder, page: InventoryChildPage(items: catalog.ordered(folder), next: nil))
    }
    navigator.selection = ids["film"]!
    try test(navigator.rows.contains { $0.id == ids["film"]! && $0.depth == 3 },
             "living tree → navigator: opening that chain makes the selected file a visible Navigator row")

    // MARK: Hit testing
    let hits = LivingTreeHitIndex(geometry)
    let bigBranch = geometry[.node(ids["big"]!)]!, trunkBranch = geometry[full.rootKey]!
    try test(hits.hit(bigBranch.end) == .node(ids["big"]!) && hits.hit(trunkBranch.point(at: 0.25)) == full.rootKey && hits.hit(CGPoint(x: 2, y: 2)) == nil
             && hits.segmentCount == geometry.branches.count * 8,
             "living tree hit testing: a tip selects its element, the trunk its folder, empty ground nothing")

    // MARK: Pinned reveal
    let revealed = catalog.build(budget: small, pinned: [ids["tiny"]!])
    let tinyParent = catalog.nodes[ids["tiny"]!]!.parentID!
    let revealRest = revealed[.rest(tinyParent)]
    let tinyTotal = catalog.ordered(tinyParent).reduce(Int64(0)) { $0 + (InventoryMapPlan.weight($1) ?? 0) }
    let revealDrawn = revealed[.node(tinyParent)]!.children.filter { $0 != .rest(tinyParent) }.reduce(Int64(0)) { $0 + (revealed[$1]!.bytes ?? 0) }
    try test(bounded[.node(ids["tiny"]!)] == nil && revealed[.node(ids["tiny"]!)] != nil && revealed.ancestry(of: .node(ids["tiny"]!)).count == 6
             && revealDrawn + (revealRest?.bytes ?? 0) == tinyTotal && revealed.count <= small.elements,
             "living tree reveal: a small entry found elsewhere (a search result) is drawn with its folders, and its folder's grouped total stays exact")

    // MARK: Large directories
    let wideCount = 200_000
    func wideSize(_ i: Int) -> Int64 { Int64(1_000_000 - i * 3) }
    let wideTotal = (0..<wideCount).reduce(Int64(0)) { $0 + wideSize($1) }
    let wideRoot = treeNode(1, parent: nil, "", folder: true, size: wideTotal, children: Int64(wideCount))
    var reads = 0
    let wideTree = LivingTreeBuilder.build(root: wideRoot, budget: .standard) { parent, count in
        reads += 1
        let page = (0..<count).map { treeNode(Int64(10 + $0), parent: parent, "w\($0)", folder: false, size: wideSize($0)) }
        let restBytes = wideTotal - page.reduce(Int64(0)) { $0 + $1.allocatedBytes! }
        return (InventoryChildPage(items: page, next: InventoryChildCursor(allocated: page.last!.allocatedBytes, name: page.last!.name, id: page.last!.id)),
                InventoryChildRemainder(count: Int64(wideCount - count), allocated: restBytes, unmeasured: 0))
    }
    let wideRest = wideTree[.rest(1)]!
    let wideDrawn = wideTree[wideTree.rootKey]!.children.count - 1
    try test(reads == 1 && wideDrawn <= LivingTreeBudget.standard.perFolder && wideRest.count == Int64(wideCount - wideDrawn)
             && wideRest.bytes! + wideTree[wideTree.rootKey]!.children.dropLast().reduce(Int64(0)) { $0 + wideTree[$1]!.bytes! } == wideTotal,
             "living tree: a 200,000-entry folder costs one bounded read and draws at most \(LivingTreeBudget.standard.perFolder) entries plus one exact group")

    // MARK: Bounded memory on a very large catalog
    // A virtual catalog: every folder has 40 subfolders and 24 files, six levels deep (billions of entries).
    var virtualReads = 0
    func virtualSpan(_ parent: Int64, _ count: Int, depth: Int) -> LivingTreeBuilder.Span {
        virtualReads += 1
        let base = Double(Int64(1) << 40) / pow(64, Double(depth))
        var items = [InventoryNode]()
        for k in 0..<64 {
            let folder = k < 40 && depth < 6
            items.append(treeNode(parent * 64 + Int64(k), parent: parent, "v\(k)", folder: folder, size: Int64(base * 1.4 / Double(k + 2)), children: folder ? 64 : 0))
        }
        let page = Array(items.prefix(count)), rest = items.dropFirst(count)
        return (InventoryChildPage(items: page, next: rest.isEmpty ? nil : InventoryChildCursor(allocated: page.last!.allocatedBytes, name: page.last!.name, id: page.last!.id)),
                rest.isEmpty ? nil : InventoryChildRemainder(count: Int64(rest.count), allocated: rest.reduce(Int64(0)) { $0 + $1.allocatedBytes! }, unmeasured: 0))
    }
    let virtualRoot = treeNode(1, parent: nil, "", folder: true, size: (Int64(1) << 40) * 3, children: 64)
    var virtualMemory = LivingTreeMemory()
    var depthOf = [Int64: Int](); depthOf[1] = 0
    var largest = 0, largestMemory = 0
    let started = Date()
    for _ in 0..<10 {
        let model = LivingTreeBuilder.build(root: virtualRoot, budget: .standard, memory: virtualMemory) { parent, count in
            let depth = depthOf[parent] ?? 0
            let span = virtualSpan(parent, count, depth: depth)
            for item in span.page.items { depthOf[item.id] = depth + 1 }
            return span
        }
        let arranged = LivingTreeArranger.arrange(model, memory: &virtualMemory)
        let layout = LivingTreeGeometer.layout(model, arranged, in: CGSize(width: 1400, height: 800))
        largest = max(largest, model.count, layout.branches.count)
        largestMemory = max(largestMemory, virtualMemory.entries)
    }
    let seconds = Date().timeIntervalSince(started) / 10
    try test(largest <= LivingTreeBudget.standard.elements && largest >= 2_000 && largestMemory <= 6 * LivingTreeBudget.standard.elements && virtualReads <= 10 * LivingTreeBudget.standard.elements,
             "living tree: a catalog of billions of entries stays within \(LivingTreeBudget.standard.elements) elements (\(largest) drawn), with bounded layout memory (\(largestMemory) entries) over repeated updates; build, arrangement and layout took \(String(format: "%.0f", seconds * 1000)) ms each")

    // MARK: Illumination
    let journal = "journal-a", t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func signal(_ node: Int64, _ sequence: Int64, from previous: Int64, to current: Int64, lowerBound: Bool = false, measured: Date? = nil) -> InventorySizeSignal {
        InventorySizeSignal(nodeID: node, generation: 1, sequence: sequence, previousAllocatedBytes: previous, allocatedBytes: current, previousMeasuredAt: t0.addingTimeInterval(-600),
                            measuredAt: measured ?? t0, previousStatus: lowerBound ? "partial" : "complete", status: lowerBound ? "partial" : "complete")
    }
    func batch(_ signals: [InventorySizeSignal], latest: Int64, resync: Bool = false, complete: Bool = true, journal id: String = journal, available: Bool = true) -> InventorySignalBatch {
        InventorySignalBatch(available: available, latestSequence: latest, signals: signals, next: available ? InventoryChangeCursor(journalID: id, sequence: complete ? latest : (signals.last?.sequence ?? latest)) : nil,
                             complete: complete, mustResynchronize: resync)
    }
    var light = LivingTreeIllumination()
    let firstRead = light.receive(batch([signal(10, 5, from: 100, to: 900)], latest: 5, resync: true), now: t0)
    try test(firstRead == .resynchronized && light.glows.isEmpty && light.cursor?.sequence == 5,
             "living tree light: the first read only takes the journal position; history is never replayed as new changes")
    let lit = light.receive(batch([signal(10, 6, from: 100_000_000, to: 120_000_000), signal(11, 7, from: 80_000_000, to: 50_000_000), signal(12, 8, from: 40, to: 40)], latest: 8), now: t0)
    try test(lit == .illuminated(2) && light.glows[10]?.trend == .growth && light.glows[11]?.trend == .reduction && light.glows[12] == nil && light.cursor?.sequence == 8,
             "living tree light: measured growth and reduction light their branches; an unchanged remeasurement lights nothing")
    let growthTone = LivingTreePalette.tone(for: .growth), reductionTone = LivingTreePalette.tone(for: .reduction)
    try test(growthTone.hue > 0.06 && growthTone.hue < 0.14 && growthTone.saturation > 0.5 && reductionTone.hue > 0.52 && reductionTone.hue < 0.64 && LivingTreePalette.branch.saturation < 0.1,
             "living tree light: growth is amber, reduction cool blue, unchanged structure neutral white")
    let early = light.intensity(of: 10, at: t0.addingTimeInterval(1), reduceMotion: false)!.value
    let later = light.intensity(of: 10, at: t0.addingTimeInterval(20), reduceMotion: false)!.value
    try test(early > later && later > 0 && light.intensity(of: 10, at: t0.addingTimeInterval(LivingTreeIllumination.duration), reduceMotion: false) == nil
             && light.isActive(at: t0.addingTimeInterval(5)) && !light.isActive(at: t0.addingTimeInterval(LivingTreeIllumination.duration + 1)),
             "living tree light: illumination fades over \(Int(LivingTreeIllumination.duration)) s and then stops; nothing animates once it is gone")
    let still1 = light.intensity(of: 10, at: t0.addingTimeInterval(1), reduceMotion: true)!.value
    let still2 = light.intensity(of: 10, at: t0.addingTimeInterval(10), reduceMotion: true)!.value
    let still3 = light.intensity(of: 10, at: t0.addingTimeInterval(20), reduceMotion: true)!.value
    try test(still1 == still2 && still3 < still2 && still3 > 0 && light.intensity(of: 10, at: t0.addingTimeInterval(LivingTreeIllumination.duration), reduceMotion: true) == nil,
             "living tree light: with Reduce Motion the light holds still and steps down in thirds instead of fading continuously")
    let complete = LivingTreeIllumination.strength(previous: 100_000_000, current: 101_000_000, confidence: .complete)
    let partialStrength = LivingTreeIllumination.strength(previous: 100_000_000, current: 101_000_000, confidence: .observedLowerBound)
    try test(complete > 0 && abs(partialStrength - complete * LivingTreeIllumination.lowerBoundFactor) < 1e-12
             && LivingTreeIllumination.strength(previous: 500_000_000_000, current: 500_000_004_096, confidence: .complete) == 0,
             "living tree light: lower-bound comparisons are softened, and a change too small to matter (4 KB of 500 GB) lights nothing")
    var replay = light
    replay.receive(batch([signal(13, 9, from: 1_000, to: 9_000, measured: t0.addingTimeInterval(-3_600))], latest: 9), now: t0)
    var duplicate = replay
    duplicate.receive(batch([signal(14, 9, from: 1_000, to: 9_000)], latest: 9), now: t0)
    try test(replay.glows[13] == nil && replay.cursor?.sequence == 9 && duplicate.glows[14] == nil,
             "living tree light: comparisons measured long ago, or at or before the cursor, are not shown as new")
    var pruned = replay
    let outcome = pruned.receive(batch([], latest: 40, resync: true), now: t0)
    try test(outcome == .resynchronized && pruned.glows == replay.glows && pruned.cursor?.sequence == 40,
             "living tree light: a cursor outside the retained history resynchronizes without inventing growth or reduction")
    var recreated = replay
    recreated.receive(batch([signal(10, 3, from: 1, to: 1_000_000)], latest: 3, journal: "journal-b"), now: t0)
    try test(recreated.glows.isEmpty && recreated.cursor?.journalID == "journal-b",
             "living tree light: a recreated journal clears the light and resynchronizes (node ids may now mean other entries)")
    var backlog = replay
    backlog.receive(batch([signal(20, 10, from: 1_000_000, to: 2_000_000)], latest: 900, complete: false), now: t0)
    var gone = replay
    gone.receive(batch([], latest: 0, available: false), now: t0)
    try test(backlog.glows[20] != nil && backlog.cursor?.sequence == 900 && gone.cursor == nil && gone.glows.isEmpty && replay.receive(nil, now: t0) == .unchanged,
             "living tree light: a backlog beyond one read is skipped (not replayed later); no journal clears the light; a failed read changes nothing")
    var flood = LivingTreeIllumination()
    flood.receive(batch([], latest: 0, resync: true), now: t0)
    flood.receive(batch((0..<10_000).map { signal(Int64(100 + $0), Int64(1 + $0), from: 1_000, to: 5_000) }, latest: 10_000), now: t0)
    try test(flood.glows.count == LivingTreeIllumination.capacity,
             "living tree light: at most \(LivingTreeIllumination.capacity) glows are kept, however many signals arrive")
    // A folder that keeps changing while lit (indexing) must not strobe: no dip back to the start of the rise, no
    // amber/blue swap on a small wobble, and a return to where it started just lets the light fade.
    var steady = LivingTreeIllumination()
    steady.receive(batch([], latest: 1, resync: true), now: t0)
    steady.receive(batch([signal(30, 2, from: 100_000_000, to: 120_000_000)], latest: 2), now: t0)
    let beforeRelight = steady.intensity(of: 30, at: t0.addingTimeInterval(5), reduceMotion: false)!.value
    steady.receive(batch([signal(30, 3, from: 120_000_000, to: 121_000_000)], latest: 3), now: t0.addingTimeInterval(5))
    let afterRelight = steady.intensity(of: 30, at: t0.addingTimeInterval(5), reduceMotion: false)!.value
    steady.receive(batch([signal(30, 4, from: 121_000_000, to: 110_000_000)], latest: 4), now: t0.addingTimeInterval(6))
    let wobble = steady.glows[30]
    steady.receive(batch([signal(30, 5, from: 110_000_000, to: 100_000_000)], latest: 5), now: t0.addingTimeInterval(7))
    try test(afterRelight >= beforeRelight && wobble?.trend == .growth && wobble?.previousBytes == 100_000_000 && wobble?.deltaBytes == 10_000_000
             && steady.glows[30]?.sequence == 4,
             "living tree light: a folder that changes again while lit keeps its light (no dip, no colour swap on a wobble) and shows the net change since it was first lit")

    let litOutside = light.isActive(at: t0.addingTimeInterval(1)) { _ in false }
    let litInside = light.isActive(at: t0.addingTimeInterval(1)) { $0 == 10 }
    try test(!litOutside && litInside, "living tree light: light on entries outside the drawn tree does not keep the view animating")

    // MARK: Change planning
    let change = { (dir: Int64, subtree: Bool) in InventoryDirectoryChange(directoryID: dir, sequence: 2, subtree: subtree) }
    func changes(_ items: [InventoryDirectoryChange], resync: Bool = false) -> InventoryChangeBatch {
        InventoryChangeBatch(available: true, journalID: journal, latestSequence: 2, generation: 1, generationStale: false, changes: items, next: InventoryChangeCursor(journalID: journal, sequence: 2), complete: true, mustResynchronize: resync)
    }
    let unrelated: Int64 = 777_777
    try test(LivingTreeRefresh.needsRebuild(changes([change(ids["Movies"]!, false)]), model: bounded, ancestors: [])
             && !LivingTreeRefresh.needsRebuild(changes([change(unrelated, false)]), model: bounded, ancestors: [])
             && LivingTreeRefresh.needsRebuild(changes([change(500, true)]), model: bounded, ancestors: [500])
             && LivingTreeRefresh.needsRebuild(changes([], resync: true), model: bounded, ancestors: [])
             && !LivingTreeRefresh.needsRebuild(changes([]), model: bounded, ancestors: [])
             && LivingTreeRefresh.needsRebuild(changes([change(1, false)]), model: unknownTree, ancestors: [])
             && { var stale = bounded; stale.generationStale = true; return LivingTreeRefresh.needsRebuild(changes([]), model: stale, ancestors: []) }()
             && { var fresh = bounded; fresh.generationStale = false; return !LivingTreeRefresh.needsRebuild(changes([]), model: fresh, ancestors: []) }(),
             "living tree updates: only committed changes to drawn folders, the trunk itself (even an empty one) or above it rebuild the tree; resynchronization and staleness that differs from the drawn snapshot rebuild it")
}

// MARK: - Camera

/// Living Tree camera tests: transforms, fit, zoom about the pointer, pan limits, focus and reveal, resizing, hit
/// testing through the camera, smoothed motion, stability through rebuilds, label placement and input
/// interpretation. Synthetic catalogs only.
func livingTreeCameraTests(_ test: (Bool, String) throws -> Void) throws {
    let wide = LivingTreeBudget(elements: 2_000, perFolder: 64, slack: 0, minimumShare: 0)
    let (catalog, ids) = standardCatalog()
    var memory = LivingTreeMemory()
    let model = catalog.build(budget: wide, memory: memory)
    let arrangement = LivingTreeArranger.arrange(model, memory: &memory)
    let geometry = LivingTreeGeometer.layout(model, arrangement, in: LivingTreeCamera.layoutSize)
    let hits = LivingTreeHitIndex(geometry)
    let extent = geometry.extent!
    let viewport = CGSize(width: 1100, height: 560)
    let framing = LivingTreeFraming(viewport: viewport, bounds: extent, axis: geometry.base.x)
    func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-6) -> Bool { hypot(a.x - b.x, a.y - b.y) <= tolerance }
    let screen = CGRect(origin: .zero, size: viewport)

    // MARK: Transforms
    let t = LivingTreeTransform(scale: 2.5, stretch: 1.2, translation: CGVector(dx: -40, dy: 13))
    let samples = [CGPoint(x: 0, y: 0), CGPoint(x: 700, y: 450), CGPoint(x: -12.5, y: 1_000), CGPoint(x: 333.3, y: -7)]
    try test(samples.allSatisfy { close(t.invert(t.apply($0)), $0) && close(LivingTreeTransform.identity.apply($0), $0) }
             && t.apply(CGRect(x: 10, y: 20, width: 30, height: 40)) == CGRect(x: 10 * 3 - 40, y: 20 * 2.5 + 13, width: 90, height: 100)
             && LivingTreeTransform.identity.widthScale == 1 && abs(LivingTreeTransform(scale: 4, translation: .zero).widthScale - 2) < 1e-12
             && LivingTreeTransform(scale: 9, stretch: 1.3, translation: .zero).widthScale == 3,
             "living tree camera: the transform round-trips points and rects; stretch widens positions only; stroke widths scale with the square root of the zoom")
    let projected = geometry.projected(t, viewport: viewport)
    let ratios = zip(geometry.branches, projected.branches).filter { $0.0.startWidth > 1 }.map { $0.1.startWidth / $0.0.startWidth }
    try test(!ratios.isEmpty && ratios.allSatisfy { abs($0 - t.widthScale) < 1e-9 } && zip(geometry.branches, projected.branches).allSatisfy { close(t.apply($0.0.end), $0.1.end) },
             "living tree camera: projection moves every tip through the transform and multiplies every width by the same factor (thickness keeps encoding size)")

    // MARK: Fit
    func fill(_ f: LivingTreeFraming) -> (fits: Bool, limiting: CGFloat, area: CGFloat) {
        let drawn = LivingTreeCamera.fit.transform(in: f).apply(f.bounds)
        // Touching the framed area on the limiting side: both vertical edges, or the side the wider half reaches
        // (the fit centres partway toward the trunk, so a width-limited tree touches one side).
        let a = f.available
        let touches = (abs(drawn.minY - a.minY) < 0.5 && abs(drawn.maxY - a.maxY) < 0.5) || abs(drawn.minX - a.minX) < 0.5 || abs(drawn.maxX - a.maxX) < 0.5
        return (a.insetBy(dx: -0.5, dy: -0.5).contains(drawn), touches ? 1 : 0,
                drawn.width * drawn.height / (f.viewport.width * f.viewport.height))
    }
    var fitResults = [(Bool, CGFloat, CGFloat, CGFloat)]()
    for size in [viewport, CGSize(width: 640, height: 640), CGSize(width: 1900, height: 560), CGSize(width: 420, height: 900)] {
        let f = LivingTreeFraming(viewport: size, bounds: extent, axis: geometry.base.x)
        let previous = LivingTreeGeometer.layout(model, arrangement, in: size).extent!
        let r = fill(f)
        fitResults.append((r.fits, r.limiting, r.area, previous.width * previous.height / (size.width * size.height)))
    }
    try test(fitResults.allSatisfy { $0.0 && $0.1 > 0.999 } && fitResults.allSatisfy { $0.2 >= $0.3 - 1e-9 } && fitResults[0].2 > fitResults[0].3 * 1.15,
             "living tree camera: the fit frames every tip and its light inside the margins, reaches the limiting side, and covers more of the canvas than the fixed crown did (\(fitResults.map { "\(Int($0.2 * 100))% vs \(Int($0.3 * 100))%" }.joined(separator: ", ")))")
    let narrow = LivingTreeFraming(viewport: CGSize(width: 420, height: 900), bounds: extent, axis: geometry.base.x)
    try test(narrow.stretch == 1 && framing.stretch > 1 && framing.stretch <= LivingTreeFraming.maximumStretch && LivingTreeFraming(viewport: CGSize(width: 4_000, height: 300), bounds: extent).stretch == LivingTreeFraming.maximumStretch,
             "living tree camera: wide canvases widen the crown sideways (at most 1.3 times); narrow ones never stretch")
    let trunkX = LivingTreeCamera.fit.transform(in: framing).apply(geometry.base).x
    try test(abs(trunkX - framing.anchor.x) <= abs(LivingTreeCamera.fit.transform(in: framing).apply(CGPoint(x: extent.midX, y: 0)).x - framing.anchor.x) + 1e-9,
             "living tree camera: the fit keeps the trunk at least as close to the middle as the crown's extent (balanced framing)")

    // MARK: Zoom about the pointer
    var anchored = true
    var camera = LivingTreeCamera.fit
    for (factor, point) in [(1.5, CGPoint(x: 550, y: 300)), (2.0, CGPoint(x: 620, y: 260)), (0.8, CGPoint(x: 500, y: 330)), (3.0, CGPoint(x: 560, y: 280))] {
        let before = camera.transform(in: framing).invert(point)
        camera = camera.zoomed(by: factor, around: point, in: framing)
        anchored = anchored && close(camera.transform(in: framing).apply(before), point, 1e-6)
    }
    try test(anchored && abs(camera.zoom - 7.2) < 1e-9,
             "living tree camera: zooming keeps the point under the pointer exactly where it was, step after step (zoom \(camera.zoom))")
    try test(LivingTreeCamera.fit.zoomed(by: 1_000, around: CGPoint(x: 10, y: 10), in: framing).zoom == LivingTreeCamera.maximumZoom
             && LivingTreeCamera.fit.zoomed(by: 0.000_1, around: CGPoint(x: 10, y: 10), in: framing).zoom == LivingTreeCamera.minimumZoom,
             "living tree camera: zoom stays between half the fit and 32 times it")

    // MARK: Pan limits
    var bounded = true
    for zoom in [0.5, 1, 8] {
        for delta in [CGVector(dx: 1e6, dy: 0), CGVector(dx: -1e6, dy: 0), CGVector(dx: 0, dy: 1e6), CGVector(dx: 0, dy: -1e6), CGVector(dx: 1e6, dy: -1e6)] {
            let c = LivingTreeCamera(zoom: zoom, center: nil).panned(by: delta, in: framing)
            let drawn = c.transform(in: framing).apply(extent)
            let overlap = drawn.intersection(screen)
            let keep = min(LivingTreeCamera.visibleMargin, 0.3 * min(viewport.width, viewport.height))
            bounded = bounded && !overlap.isNull && overlap.width >= min(keep, drawn.width) - 1e-6 && overlap.height >= min(keep, drawn.height) - 1e-6
        }
    }
    let gentle = LivingTreeCamera(zoom: 4, center: nil).panned(by: CGVector(dx: 30, dy: -20), in: framing)
    let movedBy = gentle.transform(in: framing).apply(geometry.base).x - LivingTreeCamera(zoom: 4, center: nil).transform(in: framing).apply(geometry.base).x
    try test(bounded && abs(movedBy - 30) < 1e-6,
             "living tree camera: panning moves the tree with the pointer, and however far it goes part of the tree stays on screen (at half, full and 8x zoom)")

    // MARK: Focus and reveal
    let projects = model.subtree(of: .node(ids["Projects"]!))
    let projectsRect = geometry.bounds(of: projects)!
    let focused = LivingTreeCamera.focusing(on: projectsRect, in: framing)
    let focusedRect = focused.transform(in: framing).apply(projectsRect)
    try test(focused.zoom > 1 && focused.zoom <= LivingTreeCamera.focusZoomLimit && framing.available.insetBy(dx: 30, dy: 30).contains(focusedRect)
             && abs(focusedRect.midX - framing.anchor.x) < 1 && (focusedRect.width >= framing.available.width - 80 || focusedRect.height >= framing.available.height - 80),
             "living tree camera: focusing frames a branch and everything drawn beneath it, centred and as large as fits (zoom \(String(format: "%.2f", focused.zoom)))")
    let tinyRect = geometry[.node(ids["tiny"]!)]!.bounds
    try test(LivingTreeCamera.focusing(on: tinyRect, in: framing).zoom <= LivingTreeCamera.focusZoomLimit,
             "living tree camera: focusing a single small tip stops at the focus limit")
    let visibleKey = LivingTreeKey.node(ids["Users"]!)
    let usersRect = geometry[visibleKey]!.bounds
    try test(LivingTreeCamera.fit.revealing(usersRect, in: framing) == .fit,
             "living tree camera: bringing an element that is already visible into view moves nothing")
    let away = LivingTreeCamera(zoom: 6, center: nil).panned(by: CGVector(dx: 2_000, dy: 900), in: framing)
    let revealed = away.revealing(tinyRect, in: framing)
    try test(away.transform(in: framing).apply(tinyRect).intersection(screen).isNull && screen.insetBy(dx: 27, dy: 27).contains(revealed.transform(in: framing).apply(tinyRect)) && revealed.zoom == away.zoom,
             "living tree camera: an element off screen is brought into view by panning only, keeping the zoom")

    // MARK: Resize
    let user = LivingTreeCamera.fit.zoomed(by: 3, around: CGPoint(x: 600, y: 250), in: framing).panned(by: CGVector(dx: -40, dy: 25), in: framing)
    var kept = true
    for size in [CGSize(width: 700, height: 500), CGSize(width: 1600, height: 900), CGSize(width: 1100, height: 560)] {
        let f = LivingTreeFraming(viewport: size, bounds: extent, axis: geometry.base.x)
        let c = user.clamped(in: f)
        kept = kept && c.zoom == user.zoom && c.center == user.center && close(c.transform(in: f).invert(f.anchor), user.center!, 1e-6)
    }
    try test(kept && fill(LivingTreeFraming(viewport: CGSize(width: 700, height: 500), bounds: extent, axis: geometry.base.x)).limiting == 1,
             "living tree camera: resizing keeps a chosen zoom and the place at the centre of the view; an untouched view refits to the new size")

    // MARK: Hit testing through the camera
    var tipsFound = 0, tipsChecked = 0
    for zoom in [1.0, 2.0, 4.0, 8.0] {
        let c = LivingTreeCamera.fit.zoomed(by: zoom, around: CGPoint(x: 560, y: 300), in: framing)
        let transform = c.transform(in: framing)
        let drawn = geometry.projected(transform, viewport: viewport)
        for (branch, view) in zip(geometry.branches, drawn.branches) where branch.role != .trunk && screen.contains(view.end) && LivingTreeDetail.isDrawn(branch, through: transform) {
            tipsChecked += 1
            if let key = hits.hit(view.end, transform: transform), key == branch.key || drawn[key].map({ close($0.end, view.end, 1.5) }) == true { tipsFound += 1 }
        }
    }
    try test(tipsChecked > 200 && tipsFound == tipsChecked,
             "living tree camera: under every zoom, the point of each drawn tip selects that element (or one whose tip is within 1.5 pt of it) (\(tipsFound)/\(tipsChecked))")
    // A point a few view points beside a hairline: a hit at the fit's scale, a miss when zoomed in (targets sharpen).
    let hair = geometry.branches.first { $0.depth >= 3 && $0.startWidth < 1 && $0.role == .file && hits.hit($0.point(at: 0.5)) == $0.key }!
    let normal = CGVector(dx: -hair.tangent(at: 0.5).dy, dy: hair.tangent(at: 0.5).dx)
    let mid = hair.point(at: 0.5)
    let zoomedIn = LivingTreeCamera.pinning(mid, to: CGPoint(x: 550, y: 280), zoom: 8, in: framing).transform(in: framing)
    let offset = zoomedIn.apply(CGPoint(x: mid.x + normal.dx * 2, y: mid.y + normal.dy * 2))
    try test(hits.hit(CGPoint(x: mid.x + normal.dx * 2, y: mid.y + normal.dy * 2)) != nil && hits.hit(offset, transform: zoomedIn) != hair.key
             && hits.hit(zoomedIn.apply(mid), transform: zoomedIn) == hair.key,
             "living tree camera: hit tolerance is in screen points, so zooming in makes targets precise (a point 2 layout units beside a hairline is on it at the fit, beside it at 8x)")
    let tinyScale = LivingTreeTransform(scale: 0.05, translation: .zero)
    let hidden = geometry.branches.first { !LivingTreeDetail.isDrawn($0, through: tinyScale) }!
    try test(LivingTreeDetail.isDrawn(hidden) && hits.hit(tinyScale.apply(hidden.end), transform: tinyScale) != hidden.key || hits.hit(tinyScale.apply(hidden.end), transform: tinyScale) == nil,
             "living tree camera: elements too small to draw at a scale cannot be hit there (level of detail)")
    try test(hits.hit(CGPoint(x: 2, y: 2), transform: LivingTreeCamera.fit.transform(in: framing)) == nil,
             "living tree camera: empty canvas hits nothing")

    // MARK: Motion
    var motion = LivingTreeCameraMotion()
    let pointer = CGPoint(x: 600, y: 280)
    let under = LivingTreeCamera.fit.transform(in: framing).invert(pointer)
    let wheelTarget = LivingTreeCamera.pinning(under, to: pointer, zoom: 1.728, in: framing)
    motion.move(to: wheelTarget, anchor: .init(view: pointer, content: under), in: framing)
    var drift: CGFloat = 0, frames = 0
    while motion.isMoving && frames < 1_000 {
        motion.step(1.0 / 120, in: framing); frames += 1
        drift = max(drift, hypot(motion.displayed.transform(in: framing).apply(under).x - pointer.x, motion.displayed.transform(in: framing).apply(under).y - pointer.y))
    }
    try test(motion.displayed == wheelTarget && frames > 10 && frames < 90 && drift < 1e-6,
             "living tree camera: an animated wheel zoom glides to its target in \(frames) frames (about a third of a second) with the point under the pointer still throughout")
    var back = LivingTreeCameraMotion(LivingTreeCamera(zoom: 6, center: CGPoint(x: 300, y: 200)))
    back.move(to: .fit, anchor: nil, in: framing)
    var previousGap = Double.infinity, monotone = true, steps = 0
    while back.isMoving && steps < 1_000 {
        back.step(1.0 / 120, in: framing); steps += 1
        let gap = abs(log(back.displayed.zoom))
        monotone = monotone && gap <= previousGap + 1e-12; previousGap = gap
    }
    try test(back.displayed == .fit && monotone && steps < 90,
             "living tree camera: fitting from a zoomed view eases out smoothly and ends exactly at the fit (\(steps) frames)")
    var still = LivingTreeCameraMotion(LivingTreeCamera(zoom: 3, center: CGPoint(x: 400, y: 300)))
    still.jump(to: .fit)
    try test(!still.isMoving && still.displayed == .fit && !still.step(1, in: framing),
             "living tree camera: a jump (Reduce Motion, direct manipulation) lands at once and nothing keeps stepping")

    // MARK: Stability through rebuilds
    let zoomedView = LivingTreeCamera.fit.zoomed(by: 4, around: CGPoint(x: 560, y: 300), in: framing)
    let (grown, _) = standardCatalog(tinyGrowth: 31)
    var afterMemory = memory
    let after = grown.build(budget: wide, memory: memory)
    let afterGeometry = LivingTreeGeometer.layout(after, LivingTreeArranger.arrange(after, memory: &afterMemory), in: LivingTreeCamera.layoutSize)
    let keptExtent = LivingTreeGeometry.stableExtent(afterGeometry.extent!, previous: extent)
    let afterFraming = LivingTreeFraming(viewport: viewport, bounds: keptExtent, axis: afterGeometry.base.x)
    let unmoved = geometry.branches.allSatisfy { b in afterGeometry[b.key].map { close(zoomedView.transform(in: afterFraming).apply($0.end), zoomedView.transform(in: framing).apply(b.end), 1e-6) } ?? false }
    try test(keptExtent == extent && afterFraming == framing && unmoved,
             "living tree camera: after a small measured change the rebuilt tree keeps its fit and, under a 4x camera, every tip stays exactly where it was on screen")
    let shiftedExtent = extent.insetBy(dx: -extent.width * 0.2, dy: 0)
    try test(LivingTreeGeometry.stableExtent(shiftedExtent, previous: extent) == shiftedExtent,
             "living tree camera: a tree that really grows wider refits")

    // MARK: Labels
    func measure(_ text: String, _ title: Bool) -> CGSize { CGSize(width: CGFloat(text.count) * (title ? 6.2 : 5.6), height: title ? 13 : 12) }
    var labelCounts = [Int](), labelsValid = true
    for zoom in [1.0, 2.0, 4.0] {
        let c = LivingTreeCamera.fit.zoomed(by: zoom, around: CGPoint(x: 560, y: 300), in: framing)
        let transform = c.transform(in: framing)
        let labels = LivingTreeLabeler.layout(model: model, geometry: geometry, hits: hits, transform: transform, viewport: viewport, zoom: zoom, focus: nil, measure: measure)
        let rects = labels.map { $0.rect(transform) }
        labelCounts.append(labels.count)
        labelsValid = labelsValid && labels.count <= LivingTreeLabeler.budget(zoom: zoom) && rects.allSatisfy { screen.contains($0) }
        for i in rects.indices { for j in rects.indices where j > i { labelsValid = labelsValid && !rects[i].intersects(rects[j]) } }
        labelsValid = labelsValid && zip(labels, rects).allSatisfy { LivingTreeLabeler.cost(of: $1, excluding: $0.key, hits: hits, transform: transform) <= 2 }
        labelsValid = labelsValid && labels.allSatisfy { model[$0.key]?.role != .rest || $0.title.hasSuffix("grouped items") }
    }
    // Hysteresis: placing again with the previous labels changes nothing, and a previous placement from another zoom
    // still yields valid labels.
    var stickyValid = true
    for (zoom, from) in [(1.0, 1.0), (2.0, 2.0), (1.0, 2.0), (4.0, 1.0)] {
        let transform = LivingTreeCamera.fit.zoomed(by: zoom, around: CGPoint(x: 560, y: 300), in: framing).transform(in: framing)
        let fromTransform = LivingTreeCamera.fit.zoomed(by: from, around: CGPoint(x: 560, y: 300), in: framing).transform(in: framing)
        let earlier = LivingTreeLabeler.layout(model: model, geometry: geometry, hits: hits, transform: fromTransform, viewport: viewport, zoom: from, focus: nil, measure: measure)
        let fresh = LivingTreeLabeler.layout(model: model, geometry: geometry, hits: hits, transform: transform, viewport: viewport, zoom: zoom, focus: nil, measure: measure)
        let again = LivingTreeLabeler.layout(model: model, geometry: geometry, hits: hits, transform: transform, viewport: viewport, zoom: zoom, focus: nil, previous: earlier, measure: measure)
        let rects = again.map { $0.rect(transform) }
        if zoom == from { stickyValid = stickyValid && again == fresh }
        stickyValid = stickyValid && again.count <= LivingTreeLabeler.budget(zoom: zoom) && rects.allSatisfy { screen.contains($0) }
        for i in rects.indices { for j in rects.indices where j > i { stickyValid = stickyValid && !rects[i].intersects(rects[j]) } }
    }
    try test(stickyValid, "living tree labels: labels shown last time keep their place on a rebuild (no reshuffle), and still never overlap or leave the view")
    try test(labelsValid && labelCounts[0] >= 4,
             "living tree labels: labels never overlap each other, stay inside the view, sit clear of other branches, stay within the zoom's budget and never present grouped items as one file (\(labelCounts))")
    try test(LivingTreeLabeler.budget(zoom: 1) < LivingTreeLabeler.budget(zoom: 2) && LivingTreeLabeler.budget(zoom: 2) < LivingTreeLabeler.budget(zoom: 8) && LivingTreeLabeler.budget(zoom: 32) <= 90
             && LivingTreeLabeler.minimumShare(zoom: 4) < LivingTreeLabeler.minimumShare(zoom: 1),
             "living tree labels: zooming in names smaller branches and allows more labels, never more than 90")
    let fitTransform = LivingTreeCamera.fit.transform(in: framing)
    let tinyLabels = LivingTreeLabeler.layout(model: model, geometry: geometry, hits: hits, transform: fitTransform, viewport: viewport, zoom: 1, focus: .node(ids["tiny"]!), measure: measure)
    try test(tinyLabels.first?.key == .node(ids["tiny"]!) && tinyLabels.first?.emphasized == true && tinyLabels.dropFirst().allSatisfy { !$0.emphasized },
             "living tree labels: the selection is always named (emphasized), however small")
    let (twin, twinIDs) = { () -> (TreeCatalog, [String: Int64]) in var c = TreeCatalog(); let r = c.add(nil, "", folder: true); let u = c.add(r, "Users", folder: true); let h = c.add(u, "home", folder: true)
        for i in 0..<5 { c.add(h, "f\(i)", size: 1_000_000_000) }; c.add(r, "other", size: 10_000_000); c.finalize(); return (c, ["Users": u, "home": h]) }()
    let twinModel = twin.build(budget: wide)
    var twinMemory = LivingTreeMemory()
    let twinGeometry = LivingTreeGeometer.layout(twinModel, LivingTreeArranger.arrange(twinModel, memory: &twinMemory), in: LivingTreeCamera.layoutSize)
    let twinFraming = LivingTreeFraming(viewport: viewport, bounds: twinGeometry.extent!)
    let twinLabels = LivingTreeLabeler.layout(model: twinModel, geometry: twinGeometry, hits: LivingTreeHitIndex(twinGeometry), transform: LivingTreeCamera.fit.transform(in: twinFraming), viewport: viewport, zoom: 1, focus: nil, measure: measure)
    try test(twinLabels.contains { $0.key == .node(twinIDs["Users"]!) } && !twinLabels.contains { $0.key == .node(twinIDs["home"]!) },
             "living tree labels: a folder that is nearly all of its labelled parent (Users › home) is named once")

    // Hover hysteresis: the hovered label stays hovered in the gap next to it, a different label takes over once the
    // pointer is inside it, and empty space well away from everything clears the hover.
    let hoverLabels = LivingTreeLabeler.layout(model: model, geometry: geometry, hits: hits, transform: fitTransform, viewport: viewport, zoom: 1, focus: nil, measure: measure)
    let hoverTips = hoverLabels.map { fitTransform.apply($0.tip) }
    var hoverValid = hoverLabels.count >= 2
    if hoverValid {
        let first = hoverLabels[0].rect(fitTransform), second = hoverLabels[1].rect(fitTransform)
        let resolve = { (p: CGPoint, current: LivingTreeKey?) in
            LivingTreeHover.resolve(p, current: current, labels: hoverLabels, tips: hoverTips, geometry: geometry, hits: hits, transform: fitTransform) }
        let inside = CGPoint(x: first.midX, y: first.midY)
        let justOutside = CGPoint(x: first.maxX + 2, y: first.midY)
        hoverValid = resolve(inside, nil) == hoverLabels[0].key
            && resolve(justOutside, hoverLabels[0].key) == hoverLabels[0].key
            && resolve(CGPoint(x: second.midX, y: second.midY), hoverLabels[0].key) == hoverLabels[1].key
            && LivingTreeHover.resolve(CGPoint(x: -500, y: -500), current: hoverLabels[0].key, labels: hoverLabels, tips: hoverTips, geometry: geometry, hits: hits, transform: fitTransform) == nil
    }
    try test(hoverValid, "living tree hover: the highlight holds in the gap beside its label and along its branch edge, switches only inside another label, and clears away from everything")

    // MARK: Pointer, scroll and pinch
    let folderKey = LivingTreeKey.node(ids["Projects"]!), fileKey = LivingTreeKey.node(ids["film"]!)
    let opens = { (key: LivingTreeKey) in model[key]?.node?.kind == .directory }
    var g = LivingTreeGesture()
    var actions = g.down(at: CGPoint(x: 10, y: 10), clickCount: 1, modifiers: [], target: folderKey, opens: opens)
    actions += g.dragged(to: CGPoint(x: 11, y: 11))
    actions += g.up(at: CGPoint(x: 11, y: 11), clickCount: 1, target: folderKey)
    try test(actions == [.select(folderKey)], "living tree input: a click (moving less than 3 points) selects on release")
    actions = g.down(at: CGPoint(x: 10, y: 10), clickCount: 1, modifiers: [], target: folderKey, opens: opens)
    actions += g.dragged(to: CGPoint(x: 20, y: 14)) + g.dragged(to: CGPoint(x: 35, y: 4))
    actions += g.up(at: CGPoint(x: 35, y: 4), clickCount: 1, target: folderKey)
    try test(actions == [.dragBegan, .pan(CGVector(dx: 10, dy: 4)), .pan(CGVector(dx: 15, dy: -10)), .dragEnded] && !g.isDragging,
             "living tree input: a drag pans by exactly the pointer's movement and never selects")
    try test(g.down(at: .zero, clickCount: 2, modifiers: [], target: folderKey, opens: opens) == [.open(folderKey)]
             && g.down(at: .zero, clickCount: 2, modifiers: [], target: fileKey, opens: opens) == [.focus(fileKey)]
             && g.down(at: .zero, clickCount: 2, modifiers: .option, target: folderKey, opens: opens) == [.focus(folderKey)]
             && g.down(at: .zero, clickCount: 2, modifiers: [], target: nil, opens: opens) == []
             && g.up(at: .zero, clickCount: 2, target: folderKey) == [],
             "living tree input: double-click opens a folder (subtree navigation as before), focuses a file, and Option-double-click focuses any branch")
    // Native QA NQ-4: the first click selects, which re-places labels (and may move the camera) before the second press
    // arrives; that press can then land on a neighbour's label. A double-click opens what its first click chose, and a
    // third press (hit-tested against the folder just opened) navigates nowhere.
    let neighbour = LivingTreeKey.node(ids.values.first { LivingTreeKey.node($0) != folderKey && model[.node($0)]?.node?.kind == .directory }!)
    var double = LivingTreeGesture()
    let press = CGPoint(x: 120, y: 80), nudged = CGPoint(x: 122, y: 81)
    let first = double.down(at: press, clickCount: 1, modifiers: [], target: folderKey, opens: opens) + double.up(at: press, clickCount: 1, target: folderKey)
    let second = double.down(at: nudged, clickCount: 2, modifiers: [], target: neighbour, opens: opens) + double.up(at: nudged, clickCount: 2, target: neighbour)
    let third = double.down(at: nudged, clickCount: 3, modifiers: [], target: neighbour, opens: opens) + double.up(at: nudged, clickCount: 3, target: neighbour)
    var apart = LivingTreeGesture()
    _ = apart.down(at: press, clickCount: 1, modifiers: [], target: folderKey, opens: opens) + apart.up(at: press, clickCount: 1, target: folderKey)
    let elsewhere = apart.down(at: CGPoint(x: 400, y: 300), clickCount: 2, modifiers: [], target: neighbour, opens: opens)
    try test(first == [.select(folderKey)] && second == [.open(folderKey)] && third.isEmpty && elsewhere == [.open(neighbour)],
             "living tree input: a double-click opens the folder its first click selected even if the second press lands on a neighbour's re-placed label; a triple-click navigates once (first \(first), second \(second), third \(third), elsewhere \(elsewhere))")
    let p = CGPoint(x: 300, y: 200)
    try test(LivingTreeGesture.scroll(CGVector(dx: 4, dy: -7), precise: true, modifiers: [], at: p) == .zoom(factor: exp(-7 * LivingTreeGesture.preciseZoomRate), at: p, animated: false)
             && LivingTreeGesture.scroll(CGVector(dx: 0, dy: 1), precise: false, modifiers: [], at: p) == .zoom(factor: 1.2, at: p, animated: true)
             && LivingTreeGesture.scroll(CGVector(dx: 0, dy: -10), precise: false, modifiers: [], at: p) == .zoom(factor: pow(1.2, -3), at: p, animated: true)
             && LivingTreeGesture.scroll(CGVector(dx: 0, dy: 50), precise: true, modifiers: .command, at: p) == .zoom(factor: exp(0.6), at: p, animated: false)
             && LivingTreeGesture.scroll(CGVector(dx: 2, dy: 0), precise: false, modifiers: .shift, at: p) == .pan(CGVector(dx: 32, dy: 0))
             && LivingTreeGesture.scroll(CGVector(dx: 4, dy: -7), precise: true, modifiers: .option, at: p) == .pan(CGVector(dx: 4, dy: -7))
             && LivingTreeGesture.scroll(CGVector(dx: 12, dy: 3), precise: true, modifiers: [], at: p) == .pan(CGVector(dx: 12, dy: 0))
             && LivingTreeGesture.scroll(CGVector(dx: 0, dy: 9), precise: true, modifiers: [], at: p, momentum: true) == nil
             && LivingTreeGesture.scroll(.zero, precise: true, modifiers: [], at: p) == nil
             && LivingTreeGesture.magnify(0.25, at: p) == .zoom(factor: 1.25, at: p, animated: false) && LivingTreeGesture.magnify(0, at: p) == nil,
             "living tree input: vertical scrolling zooms about the pointer from any device (wheel lines animated, pixel deltas direct); Shift/Option-scroll and sideways swipes pan; momentum does not zoom; pinch zooms")
    // Regression: smooth-scrolling mice and the Magic Mouse report precise deltas like a trackpad, and used to pan the
    // 2D tree and turn the 3D one. No scroll, of any kind, may turn the tree or select anything.
    var scrollTurnsOrSelects = 0
    for precise in [true, false] { for momentum in [true, false] { for modifiers: LivingTreeGesture.Modifiers in [[], .shift, .option, .command, [.command, .option]] {
        for delta in [CGVector(dx: 0, dy: 3), CGVector(dx: 0, dy: -40), CGVector(dx: 25, dy: -4), CGVector(dx: -1, dy: 0.5)] {
            switch LivingTreeGesture.scroll(delta, precise: precise, modifiers: modifiers, at: p, momentum: momentum) {
            case .orbit?, .select?, .open?, .focus?: scrollTurnsOrSelects += 1
            default: break
            }
        }
    } } }
    try test(scrollTurnsOrSelects == 0 && LivingTreeGesture.scroll(CGVector(dx: 0, dy: 2.5), precise: true, modifiers: [], at: p).map { if case .zoom = $0 { return true } else { return false } } == true,
             "living tree input regression: a precise (smooth-scrolling mouse) vertical scroll zooms; no scroll input in 2D or 3D orbits or selects (80 combinations)")
}

// MARK: - 3D

/// Living Tree in 3D: the dome layout, orbit and projection, yaw-independent fit, depth order and shading, hit testing
/// with the nearer branch first, orbit motion, turning input, labels and stability. Synthetic catalogs only.
func livingTree3DTests(_ test: (Bool, String) throws -> Void) throws {
    let wide = LivingTreeBudget(elements: 2_000, perFolder: 64, slack: 0, minimumShare: 0)
    let (catalog, ids) = standardCatalog()
    var memory = LivingTreeMemory()
    let model = catalog.build(budget: wide, memory: memory)
    let arrangement = LivingTreeArranger.arrange(model, memory: &memory)
    let flat = LivingTreeGeometer.layout(model, arrangement, in: LivingTreeCamera.layoutSize)
    let dome = LivingTreeGeometer3D.layout(model, arrangement)
    let viewport = CGSize(width: 1100, height: 560), screen = CGRect(origin: .zero, size: viewport)
    func length(_ v: LivingTreeVector) -> Double { (v * v).sum().squareRoot() }

    // MARK: Layout
    var again = LivingTreeMemory()
    let domeAgain = LivingTreeGeometer3D.layout(catalog.build(budget: wide, memory: again), LivingTreeArranger.arrange(catalog.build(budget: wide, memory: again), memory: &again))
    try test(dome.branches.count == model.count && Set(dome.branches.map(\.key)) == Set(model.order) && dome.branches == domeAgain.branches,
             "living tree 3d: every element is in the dome exactly once, and the same catalog always gives the same dome")
    let widthsMatch = dome.branches.allSatisfy { b in flat[b.key].map { $0.startWidth == b.startWidth && $0.sizeKnown == b.sizeKnown } ?? false }
    try test(widthsMatch, "living tree 3d: every branch has the same width as in 2D (thickness still follows indexed size; unknown sizes stay marked hairlines)")
    let aboveGround = dome.branches.allSatisfy { $0.end.y > 0 }
    let upright = dome.branches.filter { $0.role != .trunk }.allSatisfy { b in
        let d = b.end - dome.crown
        return acos(min(1, max(-1, d.y / max(length(d), 1e-9)))) <= 1.15
    }
    let trunk = dome[model.rootKey]!
    try test(aboveGround && upright && abs(trunk.end.x) < 1e-9 && abs(trunk.end.z) < 1e-9 && trunk.end.y > 0,
             "living tree 3d: the trunk rises straight to the crown and every tip grows up and out (never below the ground, never more than about 66° from vertical)")
    let spans = model[model.rootKey]!.children.compactMap { key -> (Double, Double)? in
        let azimuths = model.subtree(of: key).compactMap { dome[$0]?.azimuth }
        return azimuths.isEmpty ? nil : (azimuths.min()!, azimuths.max()!)
    }.sorted { $0.0 < $1.0 }
    try test(spans.count > 4 && zip(spans, spans.dropFirst()).allSatisfy { $0.1 <= $1.0 + 1e-9 } && spans.allSatisfy { $0.0 > -.pi && $0.1 < .pi },
             "living tree 3d: each top-level subtree keeps its own range of directions around the trunk (no interleaving)")

    // MARK: Projection
    let side = LivingTreeOrbit(yaw: 0, pitch: 0)
    let pivot = dome.pivot, R = dome.radius
    let onAxis = LivingTreeProjection.project(pivot + LivingTreeVector(100, 50, 0), orbit: side, pivot: pivot, radius: R)
    let near = LivingTreeProjection.project(pivot + LivingTreeVector(100, 0, 200), orbit: side, pivot: pivot, radius: R)
    let far = LivingTreeProjection.project(pivot + LivingTreeVector(100, 0, -200), orbit: side, pivot: pivot, radius: R)
    let turned = LivingTreeProjection.project(pivot + LivingTreeVector(100, 0, 0), orbit: LivingTreeOrbit(yaw: .pi / 2, pitch: 0), pivot: pivot, radius: R)
    try test(abs(onAxis.point.x - 100) < 1e-9 && abs(onAxis.point.y + 50) < 1e-9 && onAxis.depth == 0 && near.depth > 0 && far.depth < 0 && near.scale > 1 && far.scale < 1
             && abs(near.point.x) > abs(far.point.x) && abs(turned.point.x) < 1e-9 && turned.depth > 99,
             "living tree 3d: projection keeps the picture-plane position at the pivot's depth, enlarges what is nearer, and yaw turns the tree about its trunk")
    let orbits = [LivingTreeOrbit.standard, LivingTreeOrbit(yaw: 2.2, pitch: 0.1), LivingTreeOrbit(yaw: -1.3, pitch: 1.1)]
    var ordered = true
    for orbit in orbits {
        let g = LivingTreeProjection.geometry(dome, orbit: orbit)
        ordered = ordered && zip(g.branches, g.branches.dropFirst()).allSatisfy { $0.shade <= $1.shade + 1e-9 } && g.branches.allSatisfy { $0.shade >= 0.6 - 1e-9 && $0.shade <= 1 + 1e-9 }
            && g.index.count == g.branches.count && g.branches.enumerated().allSatisfy { g.index[$1.key] == $0 }
    }
    try test(ordered, "living tree 3d: branches are drawn far to near, dimmer with distance, and stay findable by key")
    // A tip faces the viewer after turning to it.
    let film = dome[.node(ids["Projects"]!)]!
    let facing = LivingTreeOrbit(yaw: LivingTreeOrbit.yaw(facing: film.azimuth), pitch: 0)
    let horizontal = (film.end.x * film.end.x + film.end.z * film.end.z).squareRoot()
    try test(LivingTreeProjection.project(film.end, orbit: facing, pivot: pivot, radius: R).depth >= 0.95 * horizontal,
             "living tree 3d: turning to an element brings it to the front of the tree")
    // In profile: the branch points sideways (long on screen), angled a little toward the viewer, by the smaller turn.
    var profiled = true
    for current in [-2.5, 0.0, 1.0, 2.9] {
        let yaw = LivingTreeOrbit.yaw(profile: film.azimuth, from: current)
        let view = LivingTreeOrbit(yaw: yaw, pitch: 0)
        let tip = LivingTreeProjection.project(film.end, orbit: view, pivot: pivot, radius: R), root = LivingTreeProjection.project(LivingTreeVector(0, film.end.y, 0), orbit: view, pivot: pivot, radius: R)
        let sideways = abs(tip.point.x - root.point.x) / max(horizontal, 1)
        profiled = profiled && sideways > 0.85 && tip.depth > 0 && abs(LivingTreeOrbit.wrap(yaw - current)) <= .pi / 2 + 0.36
    }
    try test(profiled, "living tree 3d: focusing turns a branch side-on (seen at full length, slightly toward the viewer) by the smaller turn")

    // MARK: Fit through a full turn
    var stable = true
    for pitch in [0.0, 0.24, 0.9] {
        let extent = LivingTreeProjection.extent(dome, pitch: pitch)
        for i in 0..<36 {
            let g = LivingTreeProjection.geometry(dome, orbit: LivingTreeOrbit(yaw: Double(i) * .pi / 18 + 0.05, pitch: pitch))
            let framing = LivingTreeFraming(viewport: viewport, bounds: extent, axis: g.base.x)
            stable = stable && extent.contains(g.extent!) && screen.insetBy(dx: -1, dy: -1).contains(LivingTreeCamera.fit.transform(in: framing).apply(g.extent!))
        }
    }
    try test(stable, "living tree 3d: the fit frames the tree over a full turn, so turning never changes the zoom or clips the tree (3 pitches × 36 yaws)")

    // MARK: Orbit
    let o = LivingTreeOrbit(yaw: 3.0, pitch: 5)
    let crossing = LivingTreeOrbit(yaw: 3.0, pitch: 0).interpolated(to: LivingTreeOrbit(yaw: -3.0, pitch: 0), 0.5)
    try test(o.pitch == LivingTreeOrbit.pitchRange.upperBound && LivingTreeOrbit(yaw: 7, pitch: 0).yaw == LivingTreeOrbit.wrap(7) && abs(abs(crossing.yaw) - .pi) < 0.01
             && abs(LivingTreeOrbit.wrap(7) - (7 - 2 * .pi)) < 1e-12,
             "living tree 3d: pitch stays between just below the horizon and nearly overhead; yaw wraps and turns the short way round")
    var turn = LivingTreeOrbitMotion(.standard)
    turn.move(to: LivingTreeOrbit.standard.rotated(yaw: 0.35, pitch: 0))
    var frames = 0
    while turn.isMoving && frames < 1_000 { turn.step(1.0 / 120); frames += 1 }
    var jumped = LivingTreeOrbitMotion(.standard)
    jumped.jump(to: LivingTreeOrbit(yaw: 1, pitch: 1))
    try test(turn.displayed == LivingTreeOrbit.standard.rotated(yaw: 0.35, pitch: 0) && frames > 10 && frames < 90 && !jumped.isMoving,
             "living tree 3d: an animated turn glides to its target and stops (\(frames) frames); a jump (Reduce Motion, dragging) lands at once")

    // MARK: Hit testing
    var checked = 0, resolved = 0
    for orbit in orbits {
        let g = LivingTreeProjection.geometry(dome, orbit: orbit)
        let hits = LivingTreeHitIndex(g)
        let framing = LivingTreeFraming(viewport: viewport, bounds: LivingTreeProjection.extent(dome, pitch: orbit.pitch), axis: g.base.x)
        let transform = LivingTreeCamera.fit.zoomed(by: 3, around: CGPoint(x: 550, y: 200), in: framing).transform(in: framing)
        let drawn = g.projected(transform, viewport: viewport)
        for (branch, view) in zip(g.branches, drawn.branches) where branch.role != .trunk && screen.contains(view.end) && LivingTreeDetail.isDrawn(branch, through: transform) {
            checked += 1
            if let key = hits.hit(view.end, transform: transform), key == branch.key || drawn[key].map({ hypot($0.end.x - view.end.x, $0.end.y - view.end.y) < 1.5 }) == true { resolved += 1 }
        }
    }
    try test(checked > 100 && resolved == checked, "living tree 3d: under several orbits at 3x, each drawn tip selects its own element (\(resolved)/\(checked))")
    let a = LivingTreeGeometry.Branch(key: .node(1), role: .file, depth: 3, start: CGPoint(x: 0, y: 0), control1: CGPoint(x: 30, y: 0), control2: CGPoint(x: 60, y: 0), end: CGPoint(x: 90, y: 0),
                                      startWidth: 2, endWidth: 1, sizeKnown: true, glow: 0, shade: 0.7)
    let b = LivingTreeGeometry.Branch(key: .node(2), role: .file, depth: 3, start: CGPoint(x: 0, y: 0.2), control1: CGPoint(x: 30, y: 0.2), control2: CGPoint(x: 60, y: 0.2), end: CGPoint(x: 90, y: 0.2),
                                      startWidth: 2, endWidth: 1, sizeKnown: true, glow: 0, shade: 1)
    let crossingGeometry = LivingTreeGeometry(size: CGSize(width: 100, height: 10), base: .zero, crown: .zero, radius: 50, trunkWidth: 2, branches: [a, b], index: [.node(1): 0, .node(2): 1])
    let crossingFar = LivingTreeGeometry(size: CGSize(width: 100, height: 10), base: .zero, crown: .zero, radius: 50, trunkWidth: 2, branches: [b, a], index: [.node(2): 0, .node(1): 1])
    try test(LivingTreeHitIndex(crossingGeometry).hit(CGPoint(x: 45, y: 0.1)) == .node(2) && LivingTreeHitIndex(crossingFar).hit(CGPoint(x: 45, y: 0.1)) == .node(2),
             "living tree 3d: where branches overlap on screen, the one nearer the viewer is selected")

    // MARK: Input
    var g = LivingTreeGesture()
    let opens = { (_: LivingTreeKey) in false }
    var actions = g.down(at: .zero, clickCount: 1, modifiers: [], target: nil, orbits: true, opens: opens) + g.dragged(to: CGPoint(x: 20, y: -10))
    actions += g.up(at: CGPoint(x: 20, y: -10), clickCount: 1, target: nil)
    var panning = LivingTreeGesture()
    let panned = panning.down(at: .zero, clickCount: 1, modifiers: .shift, target: nil, orbits: true, opens: opens) + panning.dragged(to: CGPoint(x: 20, y: -10))
    try test(actions == [.dragBegan, .orbit(yaw: 20 * LivingTreeGesture.orbitRate, pitch: -10 * LivingTreeGesture.orbitRate), .dragEnded]
             && panned == [.dragBegan, .pan(CGVector(dx: 20, dy: -10))]
             && LivingTreeGesture.rotate(90) == .orbit(yaw: -.pi / 2, pitch: 0) && LivingTreeGesture.rotate(0) == nil
             && LivingTreeGesture.scroll(CGVector(dx: 10, dy: -5), precise: true, modifiers: .shift, at: .zero) == .pan(CGVector(dx: 10, dy: -5))
             && LivingTreeGesture.scroll(CGVector(dx: 0, dy: 1), precise: false, modifiers: [], at: .zero) == .zoom(factor: 1.2, at: .zero, animated: true),
             "living tree 3d input: dragging turns the tree, Shift-drag and Shift-scroll pan, a trackpad rotation turns it, scrolling zooms")

    // MARK: Labels
    func measure(_ text: String, _ title: Bool) -> CGSize { CGSize(width: CGFloat(text.count) * (title ? 6.2 : 5.6), height: title ? 13 : 12) }
    var labelsValid = true, labelCount = 0
    for orbit in orbits {
        let g3 = LivingTreeProjection.geometry(dome, orbit: orbit)
        let framing = LivingTreeFraming(viewport: viewport, bounds: LivingTreeProjection.extent(dome, pitch: orbit.pitch), axis: g3.base.x)
        let transform = LivingTreeCamera.fit.transform(in: framing)
        let hits = LivingTreeHitIndex(g3)
        let labels = LivingTreeLabeler.layout(model: model, geometry: g3, hits: hits, transform: transform, viewport: viewport, zoom: 1, focus: nil, measure: measure)
        let rects = labels.map { $0.rect(transform) }
        labelCount += labels.count
        labelsValid = labelsValid && rects.allSatisfy { screen.contains($0) }
        for i in rects.indices { for j in rects.indices where j > i { labelsValid = labelsValid && !rects[i].intersects(rects[j]) } }
    }
    try test(labelsValid && labelCount >= 6, "living tree 3d labels: in every orientation labels stay inside the view and never overlap (\(labelCount) over 3 orbits)")

    // MARK: Stability
    let (grown, _) = standardCatalog(tinyGrowth: 31)
    var grownMemory = memory
    let after = grown.build(budget: wide, memory: memory)
    let domeAfter = LivingTreeGeometer3D.layout(after, LivingTreeArranger.arrange(after, memory: &grownMemory))
    try test(dome.branches.allSatisfy { b in domeAfter[b.key].map { $0.end == b.end && $0.start == b.start } ?? false },
             "living tree 3d: after a small measured change every branch of the dome stays exactly where it was")
}

// MARK: - Color by type

func livingTreeColorTests(_ test: (Bool, String) throws -> Void) throws {
    try test(LivingTreeCategory.file("clip.MOV") == .video && LivingTreeCategory.file("main.swift") == .development && LivingTreeCategory.file("photo.heic") == .images
             && LivingTreeCategory.file("report.pdf") == .documents && LivingTreeCategory.file("backup.zip") == .archives && LivingTreeCategory.file("song.flac") == .audio
             && LivingTreeCategory.file("Makefile") == nil && LivingTreeCategory.file("state.sqlite") == .data,
             "living tree color: files take their kind from the extension (case-insensitive); files without a known extension have none")
    try test(LivingTreeCategory.folder("node_modules") == .development && LivingTreeCategory.folder("Safari.app") == .applications && LivingTreeCategory.folder("Photos Library.photoslibrary") == .images
             && LivingTreeCategory.folder("Caches") == .data && LivingTreeCategory.folder("Projects") == nil,
             "living tree color: well-known folders and packages are colored by what they are; other folders by their contents")
    var c = TreeCatalog()
    let root = c.add(nil, "", folder: true)
    let movies = c.add(root, "Movies", folder: true)
    for i in 0..<5 { c.add(movies, "m\(i).mov", size: 1_000_000) }
    c.add(movies, "notes.txt", size: 10_000)
    let mixed = c.add(root, "Mixed", folder: true)
    c.add(mixed, "a.mov", size: 1_000_000); c.add(mixed, "b.pdf", size: 1_000_000); c.add(mixed, "c.zip", size: 1_000_000)
    let deps = c.add(root, "node_modules", folder: true)
    c.add(deps, "data.bin", size: 2_000_000)
    let unknown = c.add(root, "Opaque", folder: true)
    c.add(unknown, "blob", size: 3_000_000)
    let many = c.add(root, "Many", folder: true)
    for i in 0..<40 { c.add(many, "v\(i).mp4", size: Int64(500_000 - i)) }
    c.finalize()
    let model = c.build(budget: LivingTreeBudget(elements: 40, perFolder: 6, slack: 0, minimumShare: 0))
    let colors = LivingTreeColoring.compute(model)
    let moviesHue = colors[.node(movies)], mixedHue = colors[.node(mixed)], depsHue = colors[.node(deps)]
    try test(moviesHue?.category == .video && (moviesHue?.purity ?? 0) > 0.95 && mixedHue.map { $0.purity < 0.5 } == true
             && depsHue == LivingTreeHue(category: .development, purity: 1) && colors[.node(unknown)] == nil,
             "living tree color: a folder takes the kind that dominates its drawn contents, as strongly as it dominates; a mixed folder stays nearly neutral; unrecognized contents give no color")
    try test(colors[.rest(many)].map { $0.category == .video && abs($0.purity - (colors[.node(many)]!.purity * 0.6)) < 1e-9 } == true,
             "living tree color: grouped small items take their folder's color, quieter")
    try test(colors.present.first == .video && colors.present.contains(.development) && !colors.present.contains(.audio),
             "living tree color: the color key lists the kinds present, largest first")
}

// MARK: - Structured Explorer

/// The Structured Explorer (the Living Tree's default presentation): hierarchy, documented scale, clockwise order,
/// repeated names, camera, hit testing after zoom, depth, recentring, refresh, empty folders, selection preservation,
/// labels, keyboard movement and the renderer fallback. Synthetic catalogs only.
func structuredExplorerTests(_ test: (Bool, String) throws -> Void) throws {
    let wide = LivingTreeBudget(elements: 2_000, perFolder: 64, slack: 0, minimumShare: 0)
    let (catalog, ids) = standardCatalog()
    let model = catalog.build(budget: wide)
    let layout = StructuredExplorerLayout(model: model, depth: 3)
    let rootDepth = model[model.rootKey]!.depth

    // Hierarchy: every shown element hangs off its own parent, on the ring of its depth.
    var hierarchyOK = layout.nodes[0].key == model.rootKey && layout.nodes[0].ring == 0 && layout.nodes[0].point == .zero
    for node in layout.nodes.dropFirst() {
        let element = model[node.key]!
        hierarchyOK = hierarchyOK && layout.nodes[node.parent].key == element.parent && node.ring == element.depth - rootDepth && node.ring <= 3
        hierarchyOK = hierarchyOK && abs(hypot(node.point.x, node.point.y) - CGFloat(node.ring) * StructuredExplorerScale.ringGap) < 0.001
    }
    try test(hierarchyOK && layout.nodes.count > 20, "structured explorer: every shown element hangs off its parent, on the ring of its level (\(layout.nodes.count) shown)")

    // Shown + hidden accounts for every child of every shown folder.
    var accounted = true
    for (i, node) in layout.nodes.enumerated() where node.elided == 0 { accounted = accounted && layout.children[i].count + node.hidden == model[node.key]!.children.count }
    try test(accounted, "structured explorer: shown and +N hidden children add up to each folder's children")

    // Scale: disc area ∝ bytes above the minimum; the centre is the reference; unknown sizes never look like sizes.
    let total = model[model.rootKey]!.bytes!
    let rA = StructuredExplorerScale.radius(total / 4, of: total), rB = StructuredExplorerScale.radius(total / 16, of: total)
    try test(abs(StructuredExplorerScale.radius(total, of: total) - StructuredExplorerScale.centerRadius) < 1e-9 && abs((rA * rA) / (rB * rB) - 4) < 1e-6
             && StructuredExplorerScale.radius(1, of: total) == StructuredExplorerScale.minimumRadius && StructuredExplorerScale.radius(nil, of: total) == StructuredExplorerScale.minimumRadius
             && StructuredExplorerScale.radius(total * 2, of: total) == StructuredExplorerScale.centerRadius,
             "structured explorer scale: disc area ∝ bytes (¼ vs 1/16 → 4× area), centre = reference, tiny and unknown at the 3.5 pt minimum, never above the centre")
    var flowOK = true
    for (i, node) in layout.nodes.enumerated() where !layout.children[i].isEmpty && model[node.key]!.bytes != nil {
        let w = StructuredExplorerScale.linkWidth(model[node.key]!.bytes, of: total)
        let sum = layout.children[i].reduce(CGFloat(0)) { s, c in let x = StructuredExplorerScale.linkWidth(model[layout.nodes[c].key]!.bytes, of: total); return s + (x > StructuredExplorerScale.minimumLinkWidth ? x * x : 0) }
        flowOK = flowOK && sum <= w * w + 1e-6
    }
    try test(flowOK, "structured explorer scale: link widths conserve area — a folder's children never carry more width² than it does")

    // Order: around each parent, siblings run clockwise largest first (grouped and unmeasured last).
    var clockwise = true
    for i in layout.nodes.indices {
        let kids = layout.children[i].map { layout.nodes[$0] }
        clockwise = clockwise && zip(kids, kids.dropFirst()).allSatisfy { $0.angle < $1.angle }
        clockwise = clockwise && kids.map(\.key) == StructuredExplorerLayout.sortedChildren(of: layout.nodes[i].key, in: model).prefix(kids.count).map { $0 }
    }
    try test(clockwise, "structured explorer: siblings run clockwise from 12 o'clock, largest first, grouped and unmeasured last")

    // Determinism and refresh: the same tree lays out identically; a resized tree reorders by the new sizes.
    let again = StructuredExplorerLayout(model: catalog.build(budget: wide), depth: 3)
    try test(again.nodes == layout.nodes, "structured explorer: the same tree always lays out identically")
    var grown = catalog
    grown.resize(ids["Projects/a"]! + 1, 9_000_000_000); grown.finalize()
    let refreshed = StructuredExplorerLayout(model: grown.build(budget: wide), depth: 4)   // Projects is on ring 3
    let projects = refreshed.index[.node(ids["Projects"]!)].map { refreshed.children[$0].map { refreshed.nodes[$0].key } } ?? []
    try test(projects.first == .node(ids["Projects/a"]!), "structured explorer: after a size change the grown folder moves first in its folder")

    // Depth: fewer levels show fewer rings; more show more; the setting is clamped.
    let one = StructuredExplorerLayout(model: model, depth: 1), six = StructuredExplorerLayout(model: model, depth: 9)
    try test(one.nodes.allSatisfy { $0.ring <= 1 } && one.rings == 1 && six.depth == 6 && six.nodes.count > layout.nodes.count && one.nodes.count < layout.nodes.count,
             "structured explorer: Levels 1 shows one ring; more levels show more (clamped to 6)")

    // Recentring: a folder's own tree has it at the centre.
    let users = catalog.nodes[ids["Users"]!]!
    let usersModel = LivingTreeBuilder.build(root: users, budget: wide) { catalog.span($0, $1) }
    let usersLayout = StructuredExplorerLayout(model: usersModel, depth: 3)
    try test(usersLayout.nodes[0].key == .node(users.id) && usersLayout.nodes[0].radius == StructuredExplorerScale.centerRadius && usersLayout.index[.node(ids["Documents"]!)] != nil,
             "structured explorer: exploring a folder centres it and lays out its own contents")

    // Empty hierarchy: an empty folder is a lone centre that still answers clicks and labels.
    var empty = TreeCatalog(); empty.add(nil, "", folder: true); empty.finalize()
    let lone = StructuredExplorerLayout(model: empty.build(budget: wide), depth: 3)
    let loneT = StructuredExplorerCamera().transform(bounds: lone.bounds, size: CGSize(width: 600, height: 400))
    try test(lone.nodes.count == 1 && lone.rings == 0 && lone.bounds.width > 0 && lone.hit(loneT.apply(CGPoint.zero), transform: loneT, labels: []) == lone.rootKey,
             "structured explorer: an empty folder lays out as a lone centre that can still be selected")

    // Selection preservation: past the per-folder limit the selection is kept; past the shown levels it hangs on a spur.
    var many = TreeCatalog()
    let top = many.add(nil, "", folder: true)
    let crowd = many.add(top, "crowd", folder: true)
    var smallest: Int64 = 0
    for i in 0..<40 { smallest = many.add(crowd, "f\(i)", folder: true); many.add(smallest, "x", size: Int64(1_000_000 - i * 1_000)) }
    var chainParent = many.add(top, "chain", folder: true)
    for level in 0..<7 { chainParent = many.add(chainParent, "level\(level)", folder: true) }
    let deepFile = many.add(chainParent, "deep.bin", size: 5_000)
    many.finalize()
    let crowded = many.build(budget: LivingTreeBudget(elements: 2_000, perFolder: 64, slack: 0, minimumShare: 0))
    let plain = StructuredExplorerLayout(model: crowded, depth: 3)
    let kept = StructuredExplorerLayout(model: crowded, depth: 3, keep: .node(smallest))
    try test(plain.index[.node(smallest)] == nil && kept.index[.node(smallest)] != nil && kept.nodes[kept.index[.node(crowd)]!].hidden == 40 - StructuredExplorerLayout.perFolder - 1,
             "structured explorer: a selection beyond the 14 largest is kept on screen, and +N counts the rest")
    let spur = StructuredExplorerLayout(model: crowded, depth: 3, keep: .node(deepFile))
    let spurNode = spur[.node(deepFile)]
    try test(spurNode.map { $0.elided == crowded[.node(deepFile)]!.depth - rootDepth - 3 - 1 && spur.nodes[$0.parent].ring == 3 && $0.ring == 4 && $0.ring + $0.elided == crowded[.node(deepFile)]!.depth - rootDepth && spur.rings == 4 } == true
             && spur.shownKey(for: .node(deepFile), in: crowded) == .node(deepFile) && plain.shownKey(for: .node(deepFile), in: crowded).map { plain[$0]!.ring == 3 } == true,
             "structured explorer: a selection deeper than the shown levels hangs on a spur from its deepest shown folder (levels skipped counted)")

    // Repeated names are titled with their folder, and spoken with their path.
    var twins = TreeCatalog()
    let twinRoot = twins.add(nil, "", folder: true)
    let comfy = twins.add(twinRoot, "ComfyUI", folder: true), ollama = twins.add(twinRoot, ".ollama", folder: true)
    let m1 = twins.add(comfy, "models", folder: true), m2 = twins.add(ollama, "models", folder: true)
    twins.add(m1, "a.bin", size: 7_000_000); twins.add(m2, "b.bin", size: 9_000_000)
    twins.finalize()
    let twinModel = twins.build(budget: wide), twinLayout = StructuredExplorerLayout(model: twinModel, depth: 3)
    try test(twinLayout.title(.node(m1), in: twinModel) == "ComfyUI › models" && twinLayout.title(.node(m2), in: twinModel) == ".ollama › models"
             && twinLayout.title(.node(comfy), in: twinModel) == "ComfyUI",
             "structured explorer: repeated folder names are titled with their folder (ComfyUI › models vs .ollama › models)")

    // Camera: zoom about the pointer keeps that point fixed; limits hold; panning never loses the hierarchy.
    let size = CGSize(width: 1000, height: 640)
    var camera = StructuredExplorerCamera()
    let anchor = CGPoint(x: 700, y: 210)
    let under = camera.transform(bounds: layout.bounds, size: size).invert(anchor)
    for _ in 0..<12 { camera.zoom(by: 1.3, at: anchor, bounds: layout.bounds, size: size) }
    let kept0 = camera.transform(bounds: layout.bounds, size: size).apply(under)
    var limited = StructuredExplorerCamera(); limited.zoom(by: 1e6, at: nil, bounds: layout.bounds, size: size)
    var outer = StructuredExplorerCamera(); outer.zoom(by: 1e-6, at: nil, bounds: layout.bounds, size: size)
    var panned = StructuredExplorerCamera(); panned.pan(by: CGVector(dx: 1e7, dy: -1e7), bounds: layout.bounds, size: size)
    try test(hypot(kept0.x - anchor.x, kept0.y - anchor.y) < 0.001 && limited.zoom == StructuredExplorerCamera.zoomRange.upperBound && outer.zoom == StructuredExplorerCamera.zoomRange.lowerBound
             && panned.center.map { layout.bounds.insetBy(dx: -1, dy: -1).contains($0) } == true,
             "structured explorer camera: zoom keeps the point under the pointer exactly; zoom is limited to 40%–2400%; panning stays over the hierarchy")

    // Hit testing after zoom: every shown disc is found at its centre at the fit, 4× and 12×; empty space finds nothing.
    var hits = 0, checked = 0
    for zoom in [1.0, 4.0, 12.0] {
        for node in layout.nodes {
            var c = StructuredExplorerCamera(); c.zoom(by: zoom, at: nil, bounds: layout.bounds, size: size)
            if zoom > 1 { c.center = node.point }
            let t = c.transform(bounds: layout.bounds, size: size)
            checked += 1
            if layout.hit(t.apply(node.point), transform: t, labels: []) == node.key { hits += 1 }
        }
    }
    let fitT = StructuredExplorerCamera().transform(bounds: layout.bounds, size: size)
    try test(hits == checked && layout.hit(CGPoint(x: 3, y: 3), transform: fitT, labels: []) == nil,
             "structured explorer: every shown disc is hit at its centre at 1×, 4× and 12× (\(hits)/\(checked)); empty space selects nothing")

    // Labels: the selection is always named; nothing else overlaps; all stay inside; more appear when zoomed in.
    let selectedKey = layout.nodes[min(5, layout.nodes.count - 1)].key
    let measure = { (title: String, detail: String) in CGSize(width: CGFloat(title.count + detail.count) * 6.5 + 18, height: 18) }
    let fitLabels = layout.labels(model: model, transform: fitT, size: size, selected: selectedKey, hovered: nil, detail: { $0.bytes.map { "\($0)" } ?? "?" }, measure: measure)
    // Centre an actually unlabelled branch: zooming only at the root can legitimately show fewer labels as outer
    // rings leave the viewport, so it is not a valid test of progressive detail.
    let hiddenLabel = layout.nodes.first { node in node.ring > 1 && !fitLabels.contains { $0.key == node.key } }
    let zoomed = StructuredExplorerCamera(zoom: 8, center: hiddenLabel?.point)
    let zoomT = zoomed.transform(bounds: layout.bounds, size: size)
    let zoomLabels = layout.labels(model: model, transform: zoomT, size: size, selected: nil, hovered: nil, detail: { $0.bytes.map { "\($0)" } ?? "?" }, measure: measure)
    let free = fitLabels.filter { !$0.emphasized && $0.key != layout.rootKey }
    var overlaps = 0
    for (a, x) in free.enumerated() { for y in free.dropFirst(a + 1) where x.footprint.intersects(y.footprint) { overlaps += 1 } }
    let inside = free.allSatisfy { CGRect(origin: .zero, size: size).contains($0.footprint) }
    try test(fitLabels.first?.key == selectedKey && fitLabels.first?.emphasized == true && overlaps == 0 && inside,
             "structured explorer labels: the selection is always named first; other labels never overlap and stay inside the view (\(fitLabels.count) at the fit)")
    let visibleAtFit = Set(fitLabels.map(\.key))
    func labelPoint(_ label: StructuredExplorerLabel, x: CGFloat, y: CGFloat) -> CGPoint {
        let p = CGPoint(x: label.rect.minX + label.rect.width * x - label.anchor.x,
                        y: label.rect.minY + label.rect.height * y - label.anchor.y)
        return CGPoint(x: label.anchor.x + p.x * cos(label.angle) - p.y * sin(label.angle),
                       y: label.anchor.y + p.x * sin(label.angle) + p.y * cos(label.angle))
    }
    let labelHits = [(fitLabels, fitT), (zoomLabels, zoomT)].allSatisfy { labels, transform in
        labels.allSatisfy { label in
            [CGFloat(0.25), 0.5, 0.75].allSatisfy { x in
                layout.hit(labelPoint(label, x: x, y: 0.5), transform: transform, labels: labels) == label.key
            }
        }
    }
    try test(zoomLabels.contains { !visibleAtFit.contains($0.key) } && labelHits && (fitLabels + zoomLabels).contains { abs($0.angle) > 0.01 },
             "structured explorer labels: zooming into an unlabelled branch reveals further labels; horizontal and rotated label interiors hit their own element (fit=\(fitLabels.count), zoom=\(zoomLabels.count), revealed=\(zoomLabels.contains { !visibleAtFit.contains($0.key) }), hits=\(labelHits), rotated=\((fitLabels + zoomLabels).filter { abs($0.angle) > 0.01 }.count))")

    // Every label, including selection, hover and centre, must obey viewport and mutual collision rules.
    var labelCases = 0, labelFailures = 0
    for viewport in [CGSize(width: 640, height: 360), size] {
        for z in [0.4, 1.0, 4.0] {
            for node in layout.nodes.prefix(18) {
                var camera = StructuredExplorerCamera(zoom: z)
                camera.center = node.point
                // Place the selected disc near an edge, where its ordinary right-hand label cannot fit.
                camera.pan(by: CGVector(dx: viewport.width * 0.36, dy: viewport.height * 0.28), bounds: layout.bounds, size: viewport)
                let transform = camera.transform(bounds: layout.bounds, size: viewport)
                let labels = layout.labels(model: model, transform: transform, size: viewport, selected: node.key,
                                           hovered: layout.nodes[1].key, detail: { $0.bytes.map { "\($0)" } ?? "?" }, measure: measure)
                let view = CGRect(origin: .zero, size: viewport)
                let inBounds = labels.allSatisfy { view.contains($0.footprint) }
                let disjoint = labels.enumerated().allSatisfy { i, a in !labels.dropFirst(i + 1).contains { a.footprint.intersects($0.footprint) } }
                let selectionVisible = view.insetBy(dx: -1, dy: -1).contains(transform.apply(node.point))
                let selectionNamed = !selectionVisible || labels.contains { $0.key == node.key && $0.emphasized }
                labelCases += 1
                if !inBounds || !disjoint || !selectionNamed { labelFailures += 1 }
            }
        }
    }
    try test(labelFailures == 0, "structured explorer labels: selection, hover and centre stay inside and never overlap in edge/zoom/window cases (\(labelCases - labelFailures)/\(labelCases))")

    let smallTransform = StructuredExplorerCamera(zoom: 0.4).transform(bounds: layout.bounds, size: size)
    let smallLabels = layout.labels(model: model, transform: smallTransform, size: size, selected: nil, hovered: nil,
                                    detail: { $0.bytes.map { "\($0)" } ?? "?" }, measure: measure)
    var heavyLinkClearance = true
    for (i, node) in layout.nodes.enumerated() where node.parent >= 0 {
        let width = StructuredExplorerScale.linkWidth(model[node.key]?.bytes, of: total) * min(1.6, max(0.6, smallTransform.scale))
        guard width >= 3 else { continue }
        let radius = max(3, width / 2 + 2), curve = layout.link(i, smallTransform)
        for k in 1...15 {
            let p = curve(CGFloat(k) / 16)
            let blocked = CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)
            let ordinary = smallLabels.filter { label in
                guard let node = layout[label.key] else { return true }
                return !(node.ring == 1 && (StructuredExplorerScale.share(model[label.key]?.bytes, of: total) ?? 0) >= 0.01)
            }
            heavyLinkClearance = heavyLinkClearance && !ordinary.contains { $0.footprint.intersects(blocked) }
        }
    }
    try test(heavyLinkClearance, "structured explorer labels: ordinary labels clear sampled heavy links at 40% zoom using the drawn width")

    var majorNamed = true
    for depth in 1...6 {
        let overview = StructuredExplorerLayout(model: model, depth: depth)
        let transform = StructuredExplorerCamera().transform(bounds: overview.bounds, size: size)
        let labels = overview.labels(model: model, transform: transform, size: size, selected: model.rootKey, hovered: nil,
                                     detail: { $0.bytes.map { "\($0)" } ?? "?" }, measure: measure)
        if let largest = overview.children.first?.first.map({ overview.nodes[$0].key }) {
            majorNamed = majorNamed && labels.contains { $0.key == largest }
        }
    }
    try test(majorNamed, "structured explorer labels: the largest top-level folder stays named at every Levels setting")

    // Ring captions (native QA NQ-2: crowded at the minimum window). Placed after labels, they stay inside the view and
    // never touch a label, a disc or another caption, at compact, medium and typical canvas sizes, every Levels setting
    // and zooms from 40% to 6×. The legacy placement (widest empty arc, drawn regardless) is counted for comparison.
    let captionMeasure = { (text: String) in CGSize(width: CGFloat(text.count) * 5.2 + 2, height: 12) }
    var captionCases = 0, captionFailures = [String](), legacyCollisions = 0, captionsShown = 0
    for viewport in [CGSize(width: 560, height: 400), CGSize(width: 760, height: 480), CGSize(width: 1100, height: 600)] {
        for depth in 1...6 {
            let levels = StructuredExplorerLayout(model: model, depth: depth)
            for z in [0.4, 1.0, 2.5, 6.0] {
                var camera = StructuredExplorerCamera(zoom: z)
                if z > 1 { camera.center = levels.nodes[min(3, levels.nodes.count - 1)].point }
                let t = camera.transform(bounds: levels.bounds, size: viewport)
                let labels = levels.labels(model: model, transform: t, size: viewport, selected: levels.nodes[min(2, levels.nodes.count - 1)].key,
                                           hovered: levels.nodes[min(4, levels.nodes.count - 1)].key, detail: { $0.bytes.map { "\($0)" } ?? "?" }, measure: measure)
                let captions = levels.ringCaptions(transform: t, size: viewport, labels: labels, measure: captionMeasure)
                captionCases += 1; captionsShown += captions.count
                let view = CGRect(origin: .zero, size: viewport)
                let discs = levels.nodes.compactMap { n -> CGRect? in
                    let r = levels.screenRadius(n, t); guard r >= 2 else { return nil }
                    let c = t.apply(n.point); return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                }
                let spacing = StructuredExplorerScale.ringGap * t.scale
                let ok = captions.allSatisfy { c in view.contains(c.rect) && c.ring <= depth && !labels.contains { $0.footprint.intersects(c.rect) } && !discs.contains { $0.intersects(c.rect) } }
                    && captions.enumerated().allSatisfy { i, a in !captions.dropFirst(i + 1).contains { $0.rect.intersects(a.rect) } }
                    && (spacing >= StructuredExplorerLayout.captionRingSpacing || captions.isEmpty)
                if !ok { captionFailures.append("\(Int(viewport.width))×\(Int(viewport.height)) L\(depth) \(z)×") }
                // Legacy: every shown ring with an on-screen radius over 24 pt captioned at its widest empty arc.
                let legacyAngles = levels.ringCaptionAngles(), centre = t.apply(CGPoint.zero)
                var legacy = [CGRect]()
                if levels.rings > 0 {
                    for ring in 1...min(levels.rings, depth) {
                        let radius = CGFloat(ring) * spacing
                        guard radius > 24, let a = legacyAngles[ring] else { continue }
                        let box = captionMeasure("Level \(ring)"), p = CGPoint(x: centre.x + sin(a) * radius, y: centre.y - cos(a) * radius)
                        legacy.append(CGRect(x: p.x - box.width / 2, y: p.y - box.height / 2, width: box.width, height: box.height))
                    }
                }
                for (i, r) in legacy.enumerated() {
                    let onScreen = view.contains(CGPoint(x: r.midX, y: r.midY))
                    if onScreen && (labels.contains { $0.footprint.intersects(r) } || legacy.dropFirst(i + 1).contains { $0.intersects(r) } || discs.contains { $0.intersects(r) } || !view.contains(r)) { legacyCollisions += 1 }
                }
            }
        }
    }
    try test(captionFailures.isEmpty && captionsShown > 0,
             "structured explorer ring captions: inside the view, clear of labels, discs and each other, and absent when rings are too close (\(captionCases - captionFailures.count)/\(captionCases) cases, \(captionsShown) captions; legacy placement collided or clipped \(legacyCollisions) times) \(captionFailures.prefix(4))")

    // Adaptive density: a compact canvas names fewer secondary labels than a typical one, the selection is still named,
    // and no plate is shrunk (every label keeps its measured size).
    let typicalSize = CGSize(width: 1100, height: 600), compactSize = CGSize(width: 560, height: 400)
    let typicalT = StructuredExplorerCamera().transform(bounds: layout.bounds, size: typicalSize)
    let compactT = StructuredExplorerCamera().transform(bounds: layout.bounds, size: compactSize)
    let deepKey = layout.nodes.last { $0.ring >= 2 }?.key ?? selectedKey
    let typicalLabels = layout.labels(model: model, transform: typicalT, size: typicalSize, selected: nil, hovered: nil, detail: { $0.bytes.map { "\($0)" } ?? "?" }, measure: measure)
    let compactLabels = layout.labels(model: model, transform: compactT, size: compactSize, selected: deepKey, hovered: nil, detail: { $0.bytes.map { "\($0)" } ?? "?" }, measure: measure)
    let unshrunk = compactLabels.allSatisfy { abs($0.rect.width - measure($0.title, $0.detail).width) < 0.01 && abs($0.rect.height - 18) < 0.01 }
    let compactSelectionVisible = CGRect(origin: .zero, size: compactSize).contains(compactT.apply(layout[deepKey]!.point))
    try test(compactLabels.count <= typicalLabels.count + 1 && (!compactSelectionVisible || compactLabels.contains { $0.key == deepKey && $0.emphasized }) && unshrunk,
             "structured explorer labels: a compact canvas names fewer secondary labels than a typical one (\(compactLabels.count) incl. selection vs \(typicalLabels.count)); the selection stays named and no plate is shrunk")

    // Keyboard movement over what is shown.
    let firstChild = layout.children[0].first.map { layout.nodes[$0].key }
    let secondChild = layout.children[0].dropFirst().first.map { layout.nodes[$0].key }
    try test(layout.move(.outward, from: model.rootKey) == firstChild && layout.move(.inward, from: firstChild) == model.rootKey
             && layout.move(.nextSibling, from: firstChild) == secondChild && layout.move(.previousSibling, from: secondChild) == firstChild && layout.move(.inward, from: model.rootKey) == nil,
             "structured explorer keyboard: up goes to the largest item inside, down to the enclosing folder, left and right around the ring")

    // Fallback: the classic tree stays selectable for QA; anything else is the Structured Explorer.
    try test(LivingTreeRenderer(preference: "classic") == .classic && LivingTreeRenderer(preference: nil) == .structured && LivingTreeRenderer(preference: "structured") == .structured
             && LivingTreeRenderer(preference: "garbage") == .structured,
             "living tree renderer: Structured Explorer by default; the classic tree only when the QA preference says classic")
}
