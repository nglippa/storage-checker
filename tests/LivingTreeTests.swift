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
