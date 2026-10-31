import Foundation
import CoreGraphics

private func filterNode(_ id: Int64, parent: Int64?, _ name: String, folder: Bool, bytes: Int64?) -> InventoryNode {
    InventoryNode(id: id, parentID: parent, identity: .init(device: 1, inode: UInt64(id), birthNanoseconds: 1),
                  path: "/fixture/\(name)-\(id)", name: name, kind: folder ? .directory : .file,
                  logicalBytes: bytes, allocatedBytes: bytes, previousLogicalBytes: nil, previousAllocatedBytes: nil,
                  objectLogicalBytes: nil, objectAllocatedBytes: nil, directLogicalBytes: 0, directAllocatedBytes: 0,
                  childCount: 0, descendantFiles: 0, descendantDirectories: 0, status: bytes == nil ? .unknown : .complete,
                  coverageState: bytes == nil ? "inaccessible" : "complete", listingState: nil, statusReason: nil,
                  measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
}

private struct FilteringFixture {
    let model: LivingTreeModel
    let root: LivingTreeKey = .node(1)
    let large: LivingTreeKey = .node(2)
    let medium: LivingTreeKey = .node(3)
    let unknown: LivingTreeKey = .node(4)
    let file: LivingTreeKey = .node(5)
    let deep1: LivingTreeKey = .node(6)
    let deep2: LivingTreeKey = .node(7)
    let selected: LivingTreeKey = .node(8)
    let duplicateA: LivingTreeKey = .node(9)
    let duplicateB: LivingTreeKey = .node(10)
    let rest: LivingTreeKey = .rest(2)

    init() {
        let rootNode = filterNode(1, parent: nil, "root", folder: true, bytes: 10_000_000_000)
        let trunk = LivingTreeElement(key: .node(1), parent: nil, role: .trunk, depth: 0, node: rootNode,
                                      name: "root", bytes: 10_000_000_000, count: 1, unmeasured: 0, status: .complete)
        var model = LivingTreeModel(root: rootNode, trunk: trunk, budget: .init(elements: 100, perFolder: 50, slack: 0, maxDepth: 20, minimumShare: 0))
        func element(_ id: Int64, parent: LivingTreeKey, name: String, folder: Bool, bytes: Int64?, depth: Int) -> LivingTreeElement {
            let node = filterNode(id, parent: parent.nodeID, name, folder: folder, bytes: bytes)
            return LivingTreeElement(key: .node(id), parent: parent, role: folder ? (bytes == nil ? .unmeasured : .branch) : .file,
                                     depth: depth, node: node, name: name, bytes: bytes, count: 1, unmeasured: bytes == nil ? 1 : 0,
                                     status: bytes == nil ? .unknown : .complete)
        }
        model.add(element(2, parent: .node(1), name: "Large", folder: true, bytes: 6_000_000_000, depth: 1))
        model.add(element(3, parent: .node(1), name: "Medium", folder: true, bytes: 500_000_000, depth: 1))
        model.add(element(4, parent: .node(1), name: "Unknown", folder: true, bytes: nil, depth: 1))
        model.add(element(5, parent: .node(1), name: "large.dat", folder: false, bytes: 2_000_000_000, depth: 1))
        model.add(element(6, parent: .node(2), name: "Deep", folder: true, bytes: 90_000_000, depth: 2))
        model.add(element(7, parent: .node(6), name: "Deeper", folder: true, bytes: 80_000_000, depth: 3))
        model.add(element(8, parent: .node(7), name: "selected.bin", folder: false, bytes: 10_000_000, depth: 4))
        model.add(element(9, parent: .node(2), name: "models", folder: true, bytes: 700_000_000, depth: 2))
        model.add(element(10, parent: .node(3), name: "models", folder: true, bytes: 200_000_000, depth: 2))
        model.add(LivingTreeElement(key: .rest(2), parent: .node(2), role: .rest, depth: 2, node: nil, name: "Other items",
                                    bytes: 300_000_000, count: 12, unmeasured: 0, status: .complete))
        self.model = model
    }
}

func structuredExplorerFilteringTests(_ test: (Bool, String) throws -> Void) throws {
    try test(StructuredExplorerSizePreset.all.bytes == 0 && StructuredExplorerSizePreset.gb1.bytes == 1_000_000_000
             && StructuredExplorerSizeUnit.mb.multiplier == 1_000_000 && StructuredExplorerSizeUnit.gb.multiplier == 1_000_000_000,
             "structured filtering: presets and units use decimal bytes")
    try test(StructuredExplorerThreshold.parse("0.000001", unit: .mb) == 1
             && StructuredExplorerThreshold.parse("1", unit: .gb) == 1_000_000_000
             && StructuredExplorerThreshold.parse("1.9999999999", unit: .gb) == 1_999_999_999,
             "structured filtering: custom decimals floor exact decimal products at the one-byte boundary")
    let invalid = ["", "0", "-1", "+1", "1e3", "NaN", "infinity", ".", "1.2.3", "1٢", "1²"]
    try test(invalid.allSatisfy { StructuredExplorerThreshold.parse($0, unit: .mb) == nil }
             && StructuredExplorerThreshold.parse("9223372036854.775808", unit: .mb) == nil,
             "structured filtering: invalid, nonpositive, scientific and overflowing custom values are rejected")

    let fixture = FilteringFixture(), model = fixture.model
    let layout = StructuredExplorerLayout(model: model, depth: 4)
    let baseline = StructuredExplorerVisibility(layout: layout, model: model, filter: .init(), selection: nil)
    try test(!StructuredExplorerFilter().isActive && baseline.visible == Set(layout.nodes.map(\.key))
             && layout.nodes.allSatisfy { baseline.opacity($0.key) == 1 && baseline.labelOpacity($0.key) == 1 },
             "structured filtering: All, Dim and focus off preserve the original visible appearance")
    try test(baseline.matching.contains(fixture.unknown) && baseline.visible.contains(fixture.rest),
             "structured filtering: All includes unknown nodes and retains grouped remainder geometry")
    let allGroup = StructuredExplorerVisibility(layout: layout, model: model, filter: .init(), selection: fixture.rest)
    try test(!allGroup.selectedBelowThreshold, "structured filtering: selecting grouped context under All never claims it is below a filter")
    for delta: Int64 in [-1, 0, 1] {
        let result = StructuredExplorerVisibility(layout: layout, model: model,
            filter: .init(minimumBytes: 500_000_000 + delta), selection: nil)
        try test(result.matching.contains(fixture.medium) == (delta <= 0),
                 "structured filtering: 500 MB boundary delta \(delta) uses exact inclusive integer comparison")
    }

    let threshold = StructuredExplorerFilter(minimumBytes: 500_000_000, presentation: .dim, focus: .off)
    let dim = StructuredExplorerVisibility(layout: layout, model: model, filter: threshold, selection: fixture.selected)
    try test(dim.matching.contains(fixture.large) && dim.matching.contains(fixture.medium) && dim.matching.contains(fixture.file)
             && !dim.matching.contains(fixture.deep1) && !dim.matching.contains(fixture.unknown) && !dim.matching.contains(fixture.rest),
             "structured filtering: threshold matches real allocated sizes exactly, including files, but not unknown or grouped sums")
    try test(dim.visible.count == layout.nodes.count && dim.opacity(fixture.deep1) == 0.8 && dim.opacity(fixture.rest) == 0.2
             && dim.opacity(fixture.selected) == 1 && dim.selectedBelowThreshold
             && dim.prominent.contains(fixture.large) && dim.prominent.contains(fixture.file) && dim.prominent.contains(fixture.selected),
             "structured filtering: dim retains geometry, strengthens necessary context and selection, and fades unrelated nodes")
    try test(dim.availableFolders == 7 && dim.visibleFolders == 7 && dim.matchingFolders == 3 && dim.contextFolders == 2,
             "structured filtering: counts include current real folder nodes only and separate matches from context")

    let hidden = StructuredExplorerVisibility(layout: layout, model: model,
        filter: .init(minimumBytes: 500_000_000, presentation: .hide, focus: .off), selection: fixture.selected)
    try test(hidden.visible.contains(fixture.root) && hidden.visible.contains(fixture.selected) && hidden.visible.contains(fixture.deep1)
             && !hidden.visible.contains(fixture.unknown) && !hidden.visible.contains(fixture.rest),
             "structured filtering: hide removes nonmatches before focus while preserving actual match and selection ancestor chains")
    let hideFocus = StructuredExplorerVisibility(layout: layout, model: model,
        filter: .init(minimumBytes: 500_000_000, presentation: .hide, focus: .subtree), selection: fixture.large)
    try test(!hideFocus.visible.contains(fixture.deep1) && hideFocus.visible.contains(fixture.duplicateA)
             && !hideFocus.visible.contains(fixture.duplicateB) && hideFocus.opacity(fixture.medium) == 0.2,
             "structured filtering: hide precedes subtree focus, and duplicate folder names retain separate identities")
    let impossible = StructuredExplorerVisibility(layout: layout, model: model,
        filter: .init(minimumBytes: Int64.max, presentation: .hide, focus: .off), selection: nil)
    try test(impossible.noMatches && impossible.visible == [fixture.root] && impossible.visibleFolders == 0,
             "structured filtering: an empty threshold result retains only navigation root and reports no matches")

    let subtree = StructuredExplorerVisibility(layout: layout, model: model,
        filter: .init(minimumBytes: 0, presentation: .dim, focus: .subtree), selection: fixture.large)
    let path = StructuredExplorerVisibility(layout: layout, model: model,
        filter: .init(minimumBytes: 0, presentation: .dim, focus: .path), selection: fixture.selected)
    try test(subtree.prominent.contains(fixture.duplicateA) && subtree.opacity(fixture.medium) == 0.2
             && path.prominent == [fixture.root, fixture.large, fixture.deep1, fixture.deep2, fixture.selected]
             && path.opacity(fixture.duplicateA) == 0.2,
             "structured filtering: subtree and path focus use real descendants and ancestors and recede unrelated branches")

    let isolated = StructuredExplorerLayout(model: model, depth: 2, root: fixture.large)
    let fallback = StructuredExplorerLayout(model: model, depth: 2, root: fixture.file)
    try test(isolated.rootKey == fixture.large && isolated.nodes.first?.key == fixture.large
             && isolated.nodes.allSatisfy { model.ancestry(of: $0.key).contains(fixture.large) }
             && isolated[fixture.large]?.radius == StructuredExplorerScale.centerRadius
             && fallback.rootKey == model.rootKey,
             "structured filtering: isolation validates a real folder, uses its own total and excludes outside paths")
    let fullChain = StructuredExplorerLayout(model: model, depth: 1, keep: fixture.selected, root: fixture.large, keepFullAncestry: true)
    let chain = [fixture.large, fixture.deep1, fixture.deep2, fixture.selected]
    try test(fullChain.nodes.map(\.key) == chain + [fixture.duplicateA, fixture.rest]
             || chain.allSatisfy { fullChain.index[$0] != nil },
             "structured filtering: full-ancestry selection retention keeps every actual direct parent beyond Levels")
    try test(zip(chain.dropFirst(), chain).allSatisfy { child, parent in
        guard let i = fullChain.index[child], let p = fullChain.index[parent] else { return false }
        return fullChain.nodes[i].parent == p && fullChain.nodes[i].elided == 0
    }, "structured filtering: deep retained selection chains never fabricate shortcut parents")
    try test(model[fixture.root]?.bytes == 10_000_000_000 && model[fixture.large]?.bytes == 6_000_000_000
             && model.nodeIDs == Set([1,2,3,4,5,6,7,8,9,10]),
             "structured filtering: filtering and isolation leave model IDs and accounting totals unchanged")

    let allowed: Set<LivingTreeKey> = [fixture.root, fixture.large, fixture.deep1]
    let transform = StructuredExplorerCamera().transform(bounds: layout.bounds, size: CGSize(width: 320, height: 220))
    if let hiddenNode = layout[fixture.medium] {
        try test(layout.hit(transform.apply(hiddenNode.point), transform: transform, labels: [], allowed: allowed) != fixture.medium,
                 "structured filtering: hidden discs cannot steal pointer hits")
    }
    try test(layout.move(.outward, from: fixture.root, allowed: allowed) == fixture.large
             && layout.move(.nextSibling, from: fixture.large, allowed: allowed) == nil
             && layout.move(.inward, from: fixture.deep1, allowed: allowed) == fixture.large,
             "structured filtering: keyboard movement visits only allowed direct hierarchy targets")
    let measure = { (title: String, detail: String) in CGSize(width: CGFloat(title.count + detail.count) * 5 + 12, height: 16) }
    let labels = layout.labels(model: model, transform: transform, size: CGSize(width: 320, height: 220), selected: fixture.deep1,
                               hovered: nil, detail: { $0.bytes.map(String.init) ?? "?" }, measure: measure,
                               allowed: allowed, preferred: [fixture.deep1])
    try test(labels.allSatisfy { allowed.contains($0.key) } && labels.contains { $0.key == fixture.deep1 && $0.emphasized }
             && labels.enumerated().allSatisfy { i, a in !labels.dropFirst(i + 1).contains { a.footprint.intersects($0.footprint) } },
             "structured filtering: minimum-window labels exclude hidden geometry and prioritize preferred candidates without collisions")
}

#if STRUCTURED_FILTER_TEST_MAIN
@main private struct StructuredExplorerFilteringTestMain {
    static func main() throws {
        var failures = [String]()
        try structuredExplorerFilteringTests { passed, message in
            print("\(passed ? "PASS" : "FAIL") \(message)")
            if !passed { failures.append(message) }
        }
        if !failures.isEmpty { print("FAILED \(failures.count)"); exit(1) }
    }
}
#endif
