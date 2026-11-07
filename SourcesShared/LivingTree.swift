import Foundation
import CoreGraphics

// Living Tree: the indexed filesystem as a bounded, organic branching structure. The current folder is the
// trunk, its folders are branches, and files and grouped small items are terminal elements. Branch thickness
// follows indexed allocated size (cross-sectional area proportional to bytes, so a folder's children never
// out-weigh it), and verified size signals briefly light a branch amber (growth) or cool blue (reduction).
//
// Everything here is free of SwiftUI so it can be tested: the builder (bounded best-first read of the catalog),
// the arranger (stable sibling order and angular sectors with hysteresis), the geometer (curves and widths for
// a canvas size), hit testing, keyboard movement and the illumination state fed by the change journal.

// MARK: Keys and elements

/// A stable identity in the tree: an inventory node, or the grouped remainder of a folder (its small items).
public enum LivingTreeKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    case node(Int64)
    /// Everything in folder `id` that is not drawn as its own element, with exact indexed totals.
    case rest(Int64)

    public var nodeID: Int64? { if case .node(let id) = self { return id } else { return nil } }
    /// The folder a grouped remainder belongs to.
    public var restFolder: Int64? { if case .rest(let id) = self { return id } else { return nil } }

    public static func < (a: LivingTreeKey, b: LivingTreeKey) -> Bool {
        switch (a, b) {
        case (.node(let x), .node(let y)), (.rest(let x), .rest(let y)): return x < y
        case (.node, .rest): return true
        case (.rest, .node): return false
        }
    }

    /// Deterministic per-key noise in 0..<1 (SplitMix64), for organic variation that never changes between runs.
    func noise(_ salt: UInt64) -> Double {
        var z: UInt64
        switch self {
        case .node(let id): z = UInt64(bitPattern: id)
        case .rest(let id): z = UInt64(bitPattern: id) ^ 0xA076_1D64_78BD_642F
        }
        z = z &+ salt &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    public var description: String {
        switch self {
        case .node(let id): return "node(\(id))"
        case .rest(let id): return "rest(\(id))"
        }
    }
}

public struct LivingTreeElement: Sendable {
    public enum Role: String, Sendable {
        /// The current folder.
        case trunk
        /// A folder: expanded (its children are drawn) or a twig (its contents are not drawn).
        case branch
        /// A file drawn on its own.
        case file
        /// The grouped remainder of a folder: small files and folders, with exact totals.
        case rest
        /// An entry without a measured size (protected, unreadable, not yet listed): never drawn as zero.
        case unmeasured
    }

    public let key: LivingTreeKey
    public let parent: LivingTreeKey?
    public let role: Role
    public let depth: Int
    /// The catalog row (nil for a grouped remainder).
    public let node: InventoryNode?
    public let name: String
    /// Indexed allocated size; nil when unknown (never zero for "unknown"). For a grouped remainder, the exact
    /// sum of its measured items (nil when none of them has a measured size).
    public let bytes: Int64?
    /// Items represented: 1, or the number of grouped items.
    public let count: Int64
    /// Grouped items without a measured size (always 0 for single entries).
    public let unmeasured: Int64
    public let status: InventoryValueStatus
    public internal(set) var children: [LivingTreeKey] = []
    /// A folder whose children were read and are drawn.
    public internal(set) var expanded = false

    public var isFolder: Bool { role == .trunk || role == .branch || (role == .unmeasured && node?.kind == .directory) }
    public var sizeKnown: Bool { bytes != nil }
}

/// How large a tree may grow. The defaults keep it near 3,000 drawn elements whatever the catalog's size.
public struct LivingTreeBudget: Sendable, Equatable {
    /// Most elements (branches and terminal elements) in one tree.
    public var elements: Int
    /// Most children of one folder drawn on their own; the rest are grouped with exact totals.
    public var perFolder: Int
    /// Extra entries read per folder so that elements drawn last time stay drawn after a small rank change.
    public var slack: Int
    public var maxDepth: Int
    /// Smallest share of the trunk drawn on its own (an element below it would be thinner than a hairline).
    public var minimumShare: Double
    /// Entries without a measured size shown as their own stub per folder (the rest are counted in the group).
    public var unmeasuredPerFolder: Int

    public init(elements: Int = 3_000, perFolder: Int = 24, slack: Int = 8, maxDepth: Int = 40, minimumShare: Double = 1.0 / 100_000, unmeasuredPerFolder: Int = 3) {
        self.elements = max(4, elements); self.perFolder = max(1, perFolder); self.slack = max(0, slack)
        self.maxDepth = max(1, maxDepth); self.minimumShare = max(0, minimumShare); self.unmeasuredPerFolder = max(0, unmeasuredPerFolder)
    }
    public static let standard = LivingTreeBudget()
}

/// What a previous tree of the same trunk remembers, so updates keep elements, order and angles where they were.
/// Bounded: pruned to the elements of the latest tree.
public struct LivingTreeMemory: Sendable, Equatable {
    public internal(set) var drawn = Set<LivingTreeKey>()
    public internal(set) var expanded = Set<Int64>()
    /// Sibling order: a position in -1…1 kept for as long as the element exists.
    public internal(set) var slots = [LivingTreeKey: Double]()
    /// Smoothed angular room; changed only when the computed room moves beyond the dead-band.
    public internal(set) var room = [LivingTreeKey: Double]()
    /// Smoothed share of the parent's bytes (reach, direction and where a branch leaves its parent follow it).
    public internal(set) var share = [LivingTreeKey: Double]()
    public init() {}
    public var entries: Int { drawn.count + expanded.count + slots.count + room.count + share.count }
}

public struct LivingTreeModel: Sendable {
    public let root: InventoryNode
    public private(set) var elements: [LivingTreeKey: LivingTreeElement]
    /// Parents before children, in the order elements were added. Used for every traversal that must be
    /// deterministic (dictionary order is not).
    public private(set) var order: [LivingTreeKey]
    public let budget: LivingTreeBudget
    /// Folder reads used to build the tree.
    public internal(set) var reads = 0
    /// True when building stopped early because the read took too long (the tree is smaller than its budget).
    public internal(set) var truncated = false
    /// Time spent in folder reads, the slowest one, and the whole snapshot (filled in by the catalog reader).
    public internal(set) var readSeconds = 0.0
    public internal(set) var slowestRead = 0.0
    public internal(set) var snapshotSeconds = 0.0
    /// The change journal's position in the same snapshot: changes after it are not yet in this tree.
    public internal(set) var journalCursor: InventoryChangeCursor?
    /// Whether the generation was qualified stale as a whole (pending invalidations, unavailable file events) in the
    /// same snapshot; a later read that differs changes every element's measurement state.
    public internal(set) var generationStale: Bool?

    public var rootKey: LivingTreeKey { .node(root.id) }
    public var count: Int { elements.count }
    public var trunkBytes: Int64? { elements[rootKey]?.bytes }
    public subscript(key: LivingTreeKey) -> LivingTreeElement? { elements[key] }

    init(root: InventoryNode, trunk: LivingTreeElement, budget: LivingTreeBudget) {
        self.root = root; self.budget = budget
        elements = [trunk.key: trunk]; order = [trunk.key]
    }

    mutating func add(_ element: LivingTreeElement) {
        elements[element.key] = element
        order.append(element.key)
        if let parent = element.parent { elements[parent]?.children.append(element.key) }
    }

    mutating func markExpanded(_ key: LivingTreeKey) { elements[key]?.expanded = true }

    /// Folders whose children are drawn (the trunk included): a change to any of their listings changes the tree.
    public var expandedFolders: Set<Int64> { Set(order.compactMap { key in elements[key]!.expanded ? key.nodeID : nil }) }

    /// Inventory nodes drawn as their own element.
    public var nodeIDs: Set<Int64> { Set(order.compactMap(\.nodeID)) }

    /// From the trunk to `key`, both included.
    public func ancestry(of key: LivingTreeKey) -> [LivingTreeKey] {
        var chain = [LivingTreeKey](), current: LivingTreeKey? = key
        while let next = current, let element = elements[next], chain.count <= budget.maxDepth + 1 { chain.append(next); current = element.parent }
        return chain.reversed()
    }

    /// `key` and everything drawn beneath it.
    public func subtree(of key: LivingTreeKey) -> [LivingTreeKey] {
        guard elements[key] != nil else { return [] }
        var result = [key], index = 0
        while index < result.count { result += elements[result[index]]?.children ?? []; index += 1 }
        return result
    }

    /// Where an inventory node appears in the tree: its own element; the grouped remainder of its folder when
    /// that folder is expanded; otherwise the nearest drawn ancestor. `parentOf` gives known parents (at most 64
    /// steps are followed). Nil when the node is not beneath the trunk as far as is known.
    public func displayKey(forNode id: Int64, parentOf: (Int64) -> Int64?) -> LivingTreeKey? {
        if elements[.node(id)] != nil { return .node(id) }
        var child = id, steps = 0
        while let parent = parentOf(child), steps < 64 {
            if let folder = elements[.node(parent)] {
                if folder.expanded, elements[.rest(parent)] != nil, child == id { return .rest(parent) }
                return .node(parent)
            }
            child = parent; steps += 1
        }
        return nil
    }
}

// MARK: Building

/// Builds the tree by best-first expansion: the largest folder whose children are not drawn yet is read next,
/// until the element budget is used. Each read returns a folder's first entries in explorer order (largest first)
/// and the exact totals of everything after them, so every folder's grouped remainder is exact.
public enum LivingTreeBuilder {
    public typealias Span = (page: InventoryChildPage, remainder: InventoryChildRemainder?)

    /// - Parameters:
    ///   - root: the trunk (the current folder).
    ///   - pinned: the chain from a trunk child down to an entry that must be drawn (a revealed selection), read in
    ///     the same snapshot. Pinned folders are expanded first and the entry is drawn even when small.
    ///   - memory: the previous tree's memory, for hysteresis (elements drawn last time are kept with a lower
    ///     threshold; folders expanded last time keep a higher priority).
    ///   - shouldContinue: checked before each read; false stops early (the tree is then marked `truncated`).
    ///   - span: reads `count` entries of a folder and the exact remainder after them.
    public static func build(root: InventoryNode, pinned: [InventoryNode] = [], budget: LivingTreeBudget = .standard, memory: LivingTreeMemory = LivingTreeMemory(),
                             shouldContinue: () -> Bool = { true }, span: (Int64, Int) throws -> Span) rethrows -> LivingTreeModel {
        let rootWeight = InventoryMapPlan.weight(root)
        let trunk = LivingTreeElement(key: .node(root.id), parent: nil, role: .trunk, depth: 0, node: root, name: root.parentID == nil ? "Startup Data" : root.name,
                                      bytes: rootWeight, count: 1, unmeasured: 0, status: root.status)
        var model = LivingTreeModel(root: root, trunk: trunk, budget: budget)
        let scale = Double(max(rootWeight ?? 0, 1))
        let pinnedIDs = Set(pinned.map(\.id))
        var pinnedChild = [Int64: InventoryNode]()
        for node in pinned { if let parent = node.parentID { pinnedChild[parent] = node } }

        func expandable(_ node: InventoryNode, depth: Int) -> Bool {
            node.kind == .directory && node.childCount > 0 && node.status != .unknown && depth < budget.maxDepth
        }
        var queue = LivingTreeQueue()
        if expandable(root, depth: 0) { queue.push(.infinity, root.id) }

        while let folder = queue.pop() {
            let remaining = budget.elements - model.count
            guard remaining >= 2 else { break }
            guard shouldContinue() else { model.truncated = true; break }
            let folderKey = LivingTreeKey.node(folder)
            guard let parentElement = model[folderKey] else { continue }
            let depth = parentElement.depth + 1
            let read = try span(folder, budget.perFolder + budget.slack)
            model.reads += 1

            // One element is kept for the grouped remainder.
            let capacity = remaining - 1
            var drawn = [InventoryNode](), stubs = [InventoryNode](), grouped = [InventoryNode]()
            for (rank, child) in read.page.items.enumerated() {
                let isPinned = pinnedIDs.contains(child.id)
                let room = drawn.count + stubs.count < capacity
                if let weight = InventoryMapPlan.weight(child) {
                    let wasDrawn = memory.drawn.contains(.node(child.id))
                    let share = Double(weight) / scale
                    let threshold = budget.minimumShare * (wasDrawn ? 0.6 : 1)
                    let ranked = rank < budget.perFolder || (wasDrawn && rank < budget.perFolder + budget.slack)
                    if room && (isPinned || (ranked && share >= threshold && weight > 0)) { drawn.append(child) } else { grouped.append(child) }
                } else if room && (isPinned || (stubs.count < budget.unmeasuredPerFolder && rank < budget.perFolder + budget.slack)) {
                    stubs.append(child)
                } else { grouped.append(child) }
            }
            // A pinned entry beyond the entries read is taken out of the exact remainder and drawn.
            var beyond = read.remainder
            if let pin = pinnedChild[folder], !read.page.items.contains(where: { $0.id == pin.id }), let rest = beyond, rest.count > 0, drawn.count + stubs.count < capacity {
                let weight = InventoryMapPlan.weight(pin)
                beyond = InventoryChildRemainder(count: rest.count - 1, allocated: max(0, rest.allocated - (weight ?? 0)), unmeasured: max(0, rest.unmeasured - (weight == nil ? 1 : 0)))
                if weight == nil { stubs.append(pin) } else { drawn.append(pin) }
            }

            for child in drawn {
                let isFolder = child.kind == .directory
                model.add(LivingTreeElement(key: .node(child.id), parent: folderKey, role: isFolder ? .branch : .file, depth: depth, node: child, name: child.name,
                                            bytes: InventoryMapPlan.weight(child), count: 1, unmeasured: 0, status: child.status))
                guard isFolder, expandable(child, depth: depth), let weight = InventoryMapPlan.weight(child) else { continue }
                let share = Double(weight) / scale
                if pinnedIDs.contains(child.id) { queue.push(.infinity, child.id) }
                // A folder too small for its contents to be visible stays a twig.
                else if share >= budget.minimumShare * 4 { queue.push(Double(weight) * (memory.expanded.contains(child.id) ? 1.5 : 1), child.id) }
            }
            for child in stubs {
                model.add(LivingTreeElement(key: .node(child.id), parent: folderKey, role: .unmeasured, depth: depth, node: child, name: child.name,
                                            bytes: nil, count: 1, unmeasured: 1, status: child.status))
            }
            let count = Int64(grouped.count) + (beyond?.count ?? 0)
            if count > 0 {
                let measured = grouped.compactMap(InventoryMapPlan.weight)
                let unmeasured = Int64(grouped.count - measured.count) + (beyond?.unmeasured ?? 0)
                let bytes = measured.reduce(Int64(0), +) + (beyond?.allocated ?? 0)
                model.add(LivingTreeElement(key: .rest(folder), parent: folderKey, role: .rest, depth: depth, node: nil, name: "Other items",
                                            bytes: unmeasured == count ? nil : bytes, count: count, unmeasured: unmeasured,
                                            status: parentElement.status == .complete ? .complete : parentElement.status))
            }
            model.markExpanded(folderKey)
        }
        return model
    }
}

/// Max-priority queue of folders to expand. Ties are broken by id so that building is deterministic.
struct LivingTreeQueue {
    private var heap = [(priority: Double, id: Int64)]()
    private func above(_ a: (priority: Double, id: Int64), _ b: (priority: Double, id: Int64)) -> Bool { a.priority != b.priority ? a.priority > b.priority : a.id < b.id }
    mutating func push(_ priority: Double, _ id: Int64) {
        heap.append((priority, id))
        var i = heap.count - 1
        while i > 0 { let p = (i - 1) / 2; guard above(heap[i], heap[p]) else { break }; heap.swapAt(i, p); i = p }
    }
    mutating func pop() -> Int64? {
        guard !heap.isEmpty else { return nil }
        let top = heap[0].id
        heap.swapAt(0, heap.count - 1); heap.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var best = i
            if l < heap.count && above(heap[l], heap[best]) { best = l }
            if r < heap.count && above(heap[r], heap[best]) { best = r }
            if best == i { return top }
            heap.swapAt(i, best); i = best
        }
    }
}

// MARK: Arrangement (independent of the canvas size)

/// Where each element grows: an angular sector nested in its parent's (so sibling subtrees never share a
/// direction), the angle of its tip, how far into its depth band it reaches, and where it leaves its parent.
public struct LivingTreeArrangement: Sendable, Equatable {
    public struct Placement: Sendable, Equatable {
        /// Sector bounds and tip direction, in radians from straight up (negative is left).
        public let lower: Double, upper: Double, angle: Double
        /// 0…1 within the element's depth band.
        public let reach: Double
        /// Where the element leaves its parent's curve (curve parameter, 0.7…1).
        public let stagger: Double
        /// -1…1, a gentle sideways bend.
        public let bend: Double
        /// The smoothed share of the parent's bytes (kept within the dead-band, so small changes do not move it).
        public var share: Double = 1
    }
    public let placements: [LivingTreeKey: Placement]
    /// Each folder's drawn children from left to right.
    public let siblings: [LivingTreeKey: [LivingTreeKey]]
}

public enum LivingTreeArranger {
    public typealias Placement = LivingTreeArrangement.Placement
    /// The crown spreads this far each side of vertical.
    public static let fan = 1.38
    /// Relative change of a child's computed angular room below which its previous room is kept.
    public static let roomDeadBand = 0.15
    /// Absolute change (a fraction of the parent's span) below which the previous room or share is kept too. A small
    /// folder's room follows how many elements are drawn beneath it, which a rebuild can change by a few; without this,
    /// such a change would cross the relative dead-band and nudge every sibling laid after it.
    public static let absoluteDeadBand = 0.01

    /// Arranges `model`, reusing and then updating `memory` (sibling slots and smoothed room). Deterministic: the
    /// same model and memory always give the same arrangement.
    public static func arrange(_ model: LivingTreeModel, memory: inout LivingTreeMemory) -> LivingTreeArrangement {
        // Terminal elements in each subtree, bottom-up over the deterministic order.
        var leaves = [LivingTreeKey: Double]()
        for key in model.order.reversed() {
            let children = model[key]!.children
            leaves[key] = children.isEmpty ? 1 : children.reduce(0) { $0 + leaves[$1]! }
        }
        var placements = [LivingTreeKey: Placement]()
        var siblings = [LivingTreeKey: [LivingTreeKey]]()
        placements[model.rootKey] = Placement(lower: -fan, upper: fan, angle: 0, reach: 1, stagger: 1, bend: 0)
        var slots = [LivingTreeKey: Double](), room = [LivingTreeKey: Double](), smoothedShare = [LivingTreeKey: Double]()
        /// Keeps the remembered value while the new one stays within the dead-band of it.
        func smoothed(_ raw: Double, _ kept: Double?) -> Double {
            if let kept, kept > 0, abs(raw - kept) / kept < roomDeadBand || abs(raw - kept) < absoluteDeadBand { return kept }
            return raw
        }

        for key in model.order {
            let element = model[key]!
            guard !element.children.isEmpty, let parent = placements[key] else { continue }
            let children = element.children
            let weights = children.map { Double(max(0, model[$0]!.bytes ?? 0)) }
            let weightSum = weights.reduce(0, +), leafSum = children.reduce(0) { $0 + leaves[$1]! }
            let n = Double(children.count)

            // Order: a remembered slot, or (new elements) the weight rank placed centre-out, so the heaviest child
            // continues near the parent's direction and lighter ones alternate outwards.
            let ranked = children.indices.sorted { weights[$0] != weights[$1] ? weights[$0] > weights[$1] : children[$0] < children[$1] }
            let side: Double = key.noise(1) < 0.5 ? 1 : -1
            for (rank, index) in ranked.enumerated() {
                let child = children[index]
                if let kept = memory.slots[child] { slots[child] = kept; continue }
                let step = Double((rank + 1) / 2) * (rank % 2 == 1 ? side : -side)
                slots[child] = step / n + (child.noise(2) - 0.5) * 1e-6
            }
            let ordered = children.indices.sorted { slots[children[$0]]! != slots[children[$1]]! ? slots[children[$0]]! < slots[children[$1]]! : children[$0] < children[$1] }
            siblings[key] = ordered.map { children[$0] }

            // Room: half the share of visible elements beneath, half the share of bytes, with a floor; smoothed.
            var shares = [Double](repeating: 0, count: children.count)
            for (index, child) in children.enumerated() {
                let raw = max(0.5 * leaves[child]! / max(leafSum, 1) + 0.5 * (weightSum > 0 ? weights[index] / weightSum : 1 / n), 0.2 / n)
                room[child] = smoothed(raw, memory.room[child])
                shares[index] = room[child]!
            }
            // Summed in the stable left-to-right order, so a change in size ranks cannot shift sectors by rounding.
            let total = ordered.reduce(0.0) { $0 + shares[$1] }
            var cursor = parent.lower
            let width = parent.upper - parent.lower
            for index in ordered {
                let child = children[index], childElement = model[child]!
                let span = width * shares[index] / total
                let lower = cursor, upper = cursor + span
                cursor = upper
                let share = smoothed(weightSum > 0 ? weights[index] / weightSum : 0, memory.share[child])
                smoothedShare[child] = share
                // Organic variation inside the sector, and a pull of heavy children toward the parent's direction.
                var angle = (lower + upper) / 2 + (child.noise(3) - 0.5) * 0.3 * span
                angle += (parent.angle - angle) * 0.3 * share
                let margin = 0.12 * span
                angle = min(max(angle, lower + margin), upper - margin)
                let root = sqrt(share)
                var reach: Double
                switch childElement.role {
                case .branch: reach = childElement.children.isEmpty ? 0.5 + 0.35 * root : 0.74 + 0.26 * root
                case .file, .rest: reach = 0.34 + 0.4 * root
                case .unmeasured: reach = 0.36
                case .trunk: reach = 1
                }
                reach = min(1, max(0.22, reach + (child.noise(4) - 0.5) * 0.12))
                // Where it leaves its parent: near the tip, a little lower for small branches close to the trunk.
                // Deep folders fork at their tip, so many small siblings fan out instead of running as parallel strands.
                let spread = childElement.depth == 1 ? 0.16 : (childElement.depth == 2 ? 0.12 : 0.04)
                let stagger = min(1, max(0.8, 1 - spread * (1 - root) * (0.35 + 0.65 * child.noise(5))))
                placements[child] = Placement(lower: lower, upper: upper, angle: angle, reach: reach, stagger: stagger, bend: (child.noise(6) - 0.5) * 2, share: share)
            }
        }
        // Remember this tree (bounded to its elements).
        memory.slots = slots
        memory.room = room
        memory.share = smoothedShare
        memory.drawn = Set(model.order)
        memory.expanded = model.expandedFolders
        return LivingTreeArrangement(placements: placements, siblings: siblings)
    }
}

// MARK: Geometry (for one canvas size)

public struct LivingTreeGeometry: Sendable {
    public struct Branch: Sendable, Equatable {
        public let key: LivingTreeKey
        public let role: LivingTreeElement.Role
        public let depth: Int
        /// A cubic curve from where the element leaves its parent to its tip.
        public let start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint
        public let startWidth: CGFloat, endWidth: CGFloat
        /// False when the element has no measured size: its width is a hairline, not a size.
        public let sizeKnown: Bool
        /// Radius of the soft light at the tip of a terminal element or twig; 0 at a fork.
        public let glow: CGFloat
        /// Depth shading in a 3D view: 1 nearest the viewer (and always in 2D), lower further away.
        public var shade: CGFloat = 1

        public func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x, y: a * start.y + b * control1.y + c * control2.y + d * end.y)
        }
        /// Unit tangent at `t`.
        public func tangent(at t: CGFloat) -> CGVector {
            let u = 1 - t
            let dx = 3 * u * u * (control1.x - start.x) + 6 * u * t * (control2.x - control1.x) + 3 * t * t * (end.x - control2.x)
            let dy = 3 * u * u * (control1.y - start.y) + 6 * u * t * (control2.y - control1.y) + 3 * t * t * (end.y - control2.y)
            let length = max(1e-9, (dx * dx + dy * dy).squareRoot())
            return CGVector(dx: dx / length, dy: dy / length)
        }
        public func width(at t: CGFloat) -> CGFloat { startWidth + (endWidth - startWidth) * t }
        public var bounds: CGRect {
            let xs = [start.x, control1.x, control2.x, end.x], ys = [start.y, control1.y, control2.y, end.y]
            let pad = max(startWidth, endWidth) / 2 + glow
            return CGRect(x: xs.min()! - pad, y: ys.min()! - pad, width: xs.max()! - xs.min()! + 2 * pad, height: ys.max()! - ys.min()! + 2 * pad)
        }
    }

    public let size: CGSize
    /// Where the trunk meets the ground, the crown's centre and its radius.
    public let base: CGPoint, crown: CGPoint, radius: CGFloat
    public let trunkWidth: CGFloat
    /// Parents before children.
    public let branches: [Branch]
    public let index: [LivingTreeKey: Int]
    /// 3D: a ring on the ground under the crown (an orientation cue); empty in 2D.
    public var ground: [CGPoint] = []
    public subscript(key: LivingTreeKey) -> Branch? { index[key].map { branches[$0] } }

    /// The area covered by `keys` (an element and its subtree, for example).
    public func bounds(of keys: [LivingTreeKey]) -> CGRect? {
        keys.compactMap { self[$0]?.bounds }.reduce(nil as CGRect?) { partial, next in partial.map { $0.union(next) } ?? next }
    }
}

public enum LivingTreeGeometer {
    public static let minimumWidth: CGFloat = 0.6
    /// The trunk's width in the fixed layout space (2D and 3D alike), so equal sizes are equally thick in both.
    public static let maximumTrunkWidth: CGFloat = 26
    /// Each depth band is this fraction of the previous one: deeper levels are progressively shorter.
    public static let bandRatio = 0.7

    /// Radius of depth `d` as a fraction of the crown radius (0 at the crown's centre, approaching 1).
    public static func ring(_ depth: Int) -> Double { 1 - pow(bandRatio, Double(max(0, depth))) }

    /// Width for an indexed size: proportional to the square root of the share of the trunk, so cross-sectional
    /// area is proportional to bytes and a folder's children together are never thicker than the folder. Nil
    /// for an unknown size (drawn as a marked hairline, never as zero).
    public static func width(bytes: Int64?, trunkBytes: Int64?, trunkWidth: CGFloat) -> CGFloat? {
        guard let bytes else { return nil }
        guard let trunk = trunkBytes, trunk > 0 else { return minimumWidth }
        let share = min(1, max(0, Double(bytes) / Double(trunk)))
        return max(minimumWidth, trunkWidth * CGFloat(share.squareRoot()))
    }

    public static func layout(_ model: LivingTreeModel, _ arrangement: LivingTreeArrangement, in size: CGSize) -> LivingTreeGeometry {
        let w = max(size.width, 40), h = max(size.height, 40)
        let ground = h - 14, top: CGFloat = 16, side: CGFloat = 18
        let trunkRatio: CGFloat = 0.34
        let reachLow = CGFloat(-cos(LivingTreeArranger.fan))   // how far below the crown's centre the widest branches end
        let radius = max(10, min((w / 2 - side) / CGFloat(sin(LivingTreeArranger.fan)), (ground - top) / (1 + trunkRatio)))
        let crown = CGPoint(x: w / 2, y: ground - max(trunkRatio * radius, reachLow * radius + 10))
        let base = CGPoint(x: w / 2, y: ground)
        // Wide enough that the √share widths of large and small branches differ visibly (Users at 70% of the disk
        // against Applications at 6% read 0.83 and 0.25 of this), small enough that the trunk never dominates.
        let trunkWidth = min(maximumTrunkWidth, max(7, min(w, h) * 0.03))
        let trunkBytes = model.trunkBytes

        var branches = [LivingTreeGeometry.Branch](), index = [LivingTreeKey: Int]()
        branches.reserveCapacity(model.count)
        // Deep in the crown a folder's sector can be wide while its children's depth band is short; spread across the
        // whole sector they would form a flat comb along the rim. Each folder's children are drawn closer to its own
        // direction instead, at most `lateral` times as far sideways as the band is deep. The factor never grows
        // going down the tree, so every subtree stays inside its ancestors' span and siblings never cross.
        let lateral = 1.6
        var angle = [LivingTreeKey: Double](), squeeze = [LivingTreeKey: Double]()
        angle[model.rootKey] = 0; squeeze[model.rootKey] = 1
        func direction(_ angle: Double) -> CGVector { CGVector(dx: CGFloat(sin(angle)), dy: CGFloat(-cos(angle))) }
        func normalized(_ v: CGVector) -> CGVector { let l = max(1e-9, (v.dx * v.dx + v.dy * v.dy).squareRoot()); return CGVector(dx: v.dx / l, dy: v.dy / l) }

        for key in model.order {
            let element = model[key]!
            guard let placement = arrangement.placements[key] else { continue }
            if element.role == .trunk {
                // A gently curved trunk with a flared base.
                let lean = CGFloat(key.noise(7) - 0.5) * radius * 0.05
                let height = base.y - crown.y
                let trunk = LivingTreeGeometry.Branch(key: key, role: .trunk, depth: 0, start: base,
                                                      control1: CGPoint(x: base.x + lean, y: base.y - height * 0.38), control2: CGPoint(x: crown.x - lean, y: crown.y + height * 0.36), end: crown,
                                                      startWidth: element.sizeKnown ? trunkWidth * 1.35 : minimumWidth * 2, endWidth: element.sizeKnown ? trunkWidth * 0.9 : minimumWidth * 2,
                                                      sizeKnown: element.sizeKnown, glow: element.children.isEmpty ? 6 : 0)
                index[key] = branches.count; branches.append(trunk)
                continue
            }
            guard let parentKey = element.parent, let parentIndex = index[parentKey], let parentPlacement = arrangement.placements[parentKey],
                  let parentAngle = angle[parentKey], let parentSqueeze = squeeze[parentKey] else { continue }
            let parent = branches[parentIndex]
            let ownAngle = parentAngle + (placement.angle - parentPlacement.angle) * parentSqueeze
            angle[key] = ownAngle
            if !element.children.isEmpty {
                let half = max(1e-6, (placement.upper - placement.lower) / 2)
                let band = ring(element.depth + 1) - ring(element.depth), middle = (ring(element.depth + 1) + ring(element.depth)) / 2
                squeeze[key] = min(parentSqueeze, min(1, lateral * band / (middle * half)))
            }
            let t = CGFloat(placement.stagger)
            let start = parent.point(at: t)
            let inner = ring(element.depth - 1), outer = ring(element.depth)
            let rho = CGFloat(inner + (outer - inner) * placement.reach) * radius
            let radial = direction(ownAngle)
            let end = CGPoint(x: crown.x + radial.dx * rho, y: crown.y + radial.dy * rho)
            let chord = CGVector(dx: end.x - start.x, dy: end.y - start.y)
            let length = max(1, (chord.dx * chord.dx + chord.dy * chord.dy).squareRoot())
            let along = normalized(chord)
            let parentDirection = parent.tangent(at: t)
            let leave = normalized(CGVector(dx: 0.4 * parentDirection.dx + 0.6 * along.dx, dy: 0.4 * parentDirection.dy + 0.6 * along.dy))
            // Near the trunk branches arrive turning outward; deep twigs in narrow sectors stay close to their chord,
            // so a crowded folder fans out instead of forming a row of parallel hooks.
            let outward: CGFloat = element.depth <= 2 ? 0.5 : 0.15
            let arrive = normalized(CGVector(dx: outward * radial.dx + (1 - outward) * along.dx, dy: outward * radial.dy + (1 - outward) * along.dy))
            let normal = CGVector(dx: -along.dy, dy: along.dx), bend = CGFloat(placement.bend) * (element.depth <= 2 ? 0.06 : 0.03) * length
            let control1 = CGPoint(x: start.x + leave.dx * 0.36 * length + normal.dx * bend, y: start.y + leave.dy * 0.36 * length + normal.dy * bend)
            let control2 = CGPoint(x: end.x - arrive.dx * 0.32 * length + normal.dx * bend, y: end.y - arrive.dy * 0.32 * length + normal.dy * bend)

            let width = Self.width(bytes: element.bytes, trunkBytes: trunkBytes, trunkWidth: trunkWidth)
            let startWidth = width ?? minimumWidth
            let forks = !element.children.isEmpty
            let endWidth = forks ? startWidth * 0.8 : max(minimumWidth * 0.5, startWidth * 0.36)
            var glow: CGFloat = 0
            if !forks {
                if let bytes = element.bytes, let trunk = trunkBytes, trunk > 0 {
                    glow = min(7, 1.4 + 5.5 * CGFloat(pow(min(1, max(0, Double(bytes) / Double(trunk))), 0.35)))
                } else { glow = 1.2 }
            }
            index[key] = branches.count
            branches.append(LivingTreeGeometry.Branch(key: key, role: element.role, depth: element.depth, start: start, control1: control1, control2: control2, end: end,
                                                      startWidth: startWidth, endWidth: endWidth, sizeKnown: width != nil, glow: glow))
        }
        return LivingTreeGeometry(size: CGSize(width: w, height: h), base: base, crown: crown, radius: radius, trunkWidth: trunkWidth, branches: branches, index: index)
    }
}

// MARK: Hit testing

/// Finds the element under a point: the closest curve (measured from its edge) within a tolerance, with thinner,
/// deeper elements preferred when several are equally close. Curves are bucketed in a grid, so a lookup checks
/// only nearby segments.
public struct LivingTreeHitIndex: Sendable {
    private struct Segment: Sendable { let a: CGPoint, b: CGPoint, halfWidth: CGFloat, branch: Int, tip: Bool }
    private let cell: CGFloat
    private let buckets: [Int64: [Int32]]
    private let segments: [Segment]
    private let geometry: LivingTreeGeometry
    private let maxHalfWidth: CGFloat
    public let tolerance: CGFloat

    public init(_ geometry: LivingTreeGeometry, cell: CGFloat = 24, tolerance: CGFloat = 4) {
        self.geometry = geometry; self.cell = cell; self.tolerance = tolerance
        var segments = [Segment](), buckets = [Int64: [Int32]]()
        var widest: CGFloat = 0
        for (number, branch) in geometry.branches.enumerated() {
            let steps = 8
            var previous = branch.start
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = branch.point(at: t)
                // A tip is a little easier to hit than its width.
                let half = max(branch.width(at: t - 0.5 / CGFloat(steps)) / 2, step == steps ? min(branch.glow, 3) : 0)
                segments.append(Segment(a: previous, b: point, halfWidth: half, branch: number, tip: step == steps))
                widest = max(widest, half)
                let pad = half + tolerance
                let minX = Int64(floor((min(previous.x, point.x) - pad) / cell)), maxX = Int64(floor((max(previous.x, point.x) + pad) / cell))
                let minY = Int64(floor((min(previous.y, point.y) - pad) / cell)), maxY = Int64(floor((max(previous.y, point.y) + pad) / cell))
                for x in minX...maxX { for y in minY...maxY { buckets[(x << 32) ^ (y & 0xFFFF_FFFF), default: []].append(Int32(segments.count - 1)) } }
                previous = point
            }
        }
        self.segments = segments; self.buckets = buckets; maxHalfWidth = widest
    }

    public var segmentCount: Int { segments.count }

    /// The element at `point` in layout space (no camera).
    public func hit(_ point: CGPoint) -> LivingTreeKey? {
        nearest(point, transform: .identity, tolerance: tolerance, detail: false, tips: true)?.key
    }

    /// The element nearest to view point `point` when drawn through `transform`, scored in view points: the distance
    /// from its drawn edge (layout distance × scale minus layout half-width × width scale) within `tolerance`.
    /// - Parameters:
    ///   - detail: skip elements left out at this scale (level of detail).
    ///   - tips: a point on an element's tip belongs to it even over a thicker branch, and the thinner, deeper
    ///     element wins a tie (hit testing). Otherwise the widest element within reach is returned (occupancy).
    func nearest(_ point: CGPoint, transform: LivingTreeTransform, tolerance: CGFloat, detail: Bool, tips: Bool, widest: Bool = false) -> (key: LivingTreeKey, width: CGFloat)? {
        let s = transform.scale, ws = transform.widthScale
        guard s > 0 else { return nil }
        let p = transform.invert(point)
        // Buckets are padded by each segment's half-width plus the build tolerance in layout units; zoomed out (or with
        // a wider reach than that) neighbouring cells are searched as well. Distances are then measured on screen.
        let extra = max(0, tolerance / s - self.tolerance + max(0, ws / s - 1) * maxHalfWidth)
        let x0 = Int64(floor((p.x - extra) / cell)), x1 = Int64(floor((p.x + extra) / cell))
        let y0 = Int64(floor((p.y - extra) / cell)), y1 = Int64(floor((p.y + extra) / cell))
        var best: (score: CGFloat, depth: Int, width: CGFloat, branch: Int)?
        for x in x0...x1 {
            for y in y0...y1 {
                guard let candidates = buckets[(x << 32) ^ (y & 0xFFFF_FFFF)] else { continue }
                for number in candidates {
                    let segment = segments[Int(number)]
                    let a = transform.apply(segment.a), b = transform.apply(segment.b)
                    let half = segment.halfWidth * ws
                    let score = Self.distance(point, a, b) - half
                    guard score <= tolerance else { continue }
                    let branch = geometry.branches[segment.branch]
                    if detail && !LivingTreeDetail.isDrawn(branch, through: transform) { continue }
                    let width = branch.startWidth * ws
                    if widest {
                        if best == nil || width > best!.width { best = (score, branch.depth, width, segment.branch) }
                        continue
                    }
                    // A point on an element's tip belongs to that element, even where a thicker branch passes beneath it.
                    // Where tips crowd together, the nearest tip wins.
                    let toTip = hypot(point.x - b.x, point.y - b.y)
                    let onTip = tips && segment.tip && toTip <= max(3, half)
                    let candidate = (score: onTip ? toTip - 100 : max(0, score), depth: branch.depth, width: width, branch: segment.branch)
                    if let current = best {
                        // Inside two curves at once (a twig crossing its thick parent): the thinner, deeper one wins.
                        // In a 3D view the branch nearer the viewer wins first.
                        let nearer = branch.shade - geometry.branches[current.branch].shade
                        let tie = abs(candidate.score - current.score) <= 0.5
                        let better = candidate.score < current.score - 0.5 || (tie && nearer > 0.05)
                            || (tie && abs(nearer) <= 0.05 && (candidate.depth > current.depth || (candidate.depth == current.depth && candidate.width < current.width)))
                        if better { best = candidate }
                    } else { best = candidate }
                }
            }
        }
        return best.map { (geometry.branches[$0.branch].key, $0.width) }
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared)) : 0
        let x = a.x + t * dx - p.x, y = a.y + t * dy - p.y
        return (x * x + y * y).squareRoot()
    }
}

// MARK: Keyboard movement

public enum LivingTreeNavigation {
    public enum Move: Sendable { case towardTips, towardTrunk, previousSibling, nextSibling }

    /// The element a key press moves to. Toward the tips goes to the largest child; toward the trunk to the
    /// parent; siblings follow their left-to-right order and stop at the ends.
    public static func move(_ move: Move, from key: LivingTreeKey?, in model: LivingTreeModel, arrangement: LivingTreeArrangement) -> LivingTreeKey? {
        guard let key, let element = model[key] else { return model.rootKey }
        switch move {
        case .towardTips:
            return element.children.max { a, b in
                let x = model[a]!.bytes ?? -1, y = model[b]!.bytes ?? -1
                return x != y ? x < y : a > b
            } ?? key
        case .towardTrunk:
            return element.parent ?? key
        case .previousSibling, .nextSibling:
            guard let parent = element.parent, let row = arrangement.siblings[parent], let position = row.firstIndex(of: key) else { return key }
            let next = position + (move == .nextSibling ? 1 : -1)
            return row.indices.contains(next) ? row[next] : key
        }
    }
}

// MARK: Living change signals

/// Brief, truthful illumination from the inventory's committed size signals. Only comparisons of two settled
/// measurements (`InventorySizeSignal`) light anything; raw file events never do. The first read, a cursor outside
/// the retained history and a recreated journal resynchronize silently: history is never replayed as new events.
/// Bounded: a cursor and at most `capacity` glows.
public struct LivingTreeIllumination: Sendable, Equatable {
    public struct Glow: Sendable, Equatable {
        public let trend: InventorySizeSignal.Trend
        /// 0…1: the size of the change relative to the earlier size, reduced for lower-bound comparisons.
        public let strength: Double
        public let confidence: InventorySizeSignal.Confidence
        public let deltaBytes: Int64
        public let previousBytes: Int64
        public let bytes: Int64
        /// When the viewer first saw this comparison: the fade starts here.
        public let observed: Date
        public let sequence: Int64
    }
    public enum Outcome: Equatable, Sendable { case unchanged, resynchronized, unavailable, illuminated(Int) }

    /// How long a change stays lit.
    public static let duration: TimeInterval = 36
    /// How long a new light takes to rise to full.
    public static let rise: TimeInterval = 0.6
    /// Comparisons measured longer ago than this are not shown as new (a viewer that was closed or asleep).
    public static let replayHorizon: TimeInterval = 300
    public static let capacity = 2_048
    /// Strength multiplier for a comparison that covers only the observable part of a subtree.
    public static let lowerBoundFactor = 0.45
    /// Changes weaker than this are not shown at all.
    public static let threshold = 0.06

    public private(set) var cursor: InventoryChangeCursor?
    public private(set) var glows = [Int64: Glow]()
    public private(set) var resynchronizations = 0

    public init() {}

    /// The change's visual strength: logarithmic in the change relative to the earlier size (one hundred-
    /// thousandth is nothing, about 3% or more is full), reduced for lower-bound comparisons.
    public static func strength(previous: Int64, current: Int64, confidence: InventorySizeSignal.Confidence) -> Double {
        let delta = abs(Double(current) - Double(previous))
        guard delta > 0 else { return 0 }
        let relative = delta / Double(max(previous, 1))
        let magnitude = min(1, max(0, (log10(relative) + 5) / 3.5))
        let value = magnitude * (confidence == .complete ? 1 : lowerBoundFactor)
        return value < threshold ? 0 : value
    }

    @discardableResult
    public mutating func receive(_ batch: InventorySignalBatch?, now: Date) -> Outcome {
        // A failed read changes nothing; the same cursor is read again next time.
        guard let batch else { return .unchanged }
        guard batch.available, let next = batch.next else { cursor = nil; glows.removeAll(); return .unavailable }
        // Another journal (a recreated catalog): node ids may now mean other entries.
        if let cursor, cursor.journalID != next.journalID { glows.removeAll() }
        guard !batch.mustResynchronize, let current = cursor, current.journalID == next.journalID else {
            cursor = next; resynchronizations += 1
            return .resynchronized
        }
        var lit = 0
        for signal in batch.signals where signal.sequence > current.sequence && signal.trend != .unchanged {
            let strength = Self.strength(previous: signal.previousAllocatedBytes, current: signal.allocatedBytes, confidence: signal.confidence)
            guard strength > 0 else { continue }
            if let measured = signal.measuredAt, now.timeIntervalSince(measured) > Self.replayHorizon { continue }
            // A folder that changes again while still lit (every few seconds during indexing) keeps its light: it must
            // not drop back to the start of the rise, or swap amber/blue on every small wobble. The light then shows the
            // net change since it was first lit, and restarts its fade without dimming.
            if let existing = glows[signal.nodeID], now.timeIntervalSince(existing.observed) < Self.duration {
                let confidence: InventorySizeSignal.Confidence = existing.confidence == .complete && signal.confidence == .complete ? .complete : signal.confidence
                let net = Self.strength(previous: existing.previousBytes, current: signal.allocatedBytes, confidence: confidence)
                guard net > 0 else { continue }  // back to where it started: let the current light fade out
                let age = now.timeIntervalSince(existing.observed)
                glows[signal.nodeID] = Glow(trend: signal.allocatedBytes >= existing.previousBytes ? .growth : .reduction, strength: net, confidence: confidence,
                                            deltaBytes: signal.allocatedBytes - existing.previousBytes, previousBytes: existing.previousBytes, bytes: signal.allocatedBytes,
                                            observed: age < Self.rise ? existing.observed : now.addingTimeInterval(-Self.rise), sequence: signal.sequence)
                lit += 1
                continue
            }
            glows[signal.nodeID] = Glow(trend: signal.trend, strength: strength, confidence: signal.confidence, deltaBytes: signal.deltaBytes,
                                        previousBytes: signal.previousAllocatedBytes, bytes: signal.allocatedBytes, observed: now, sequence: signal.sequence)
            lit += 1
        }
        // A backlog larger than one read is skipped, not replayed later as new.
        cursor = batch.complete ? next : InventoryChangeCursor(journalID: next.journalID, sequence: batch.latestSequence)
        expire(at: now)
        if glows.count > Self.capacity {
            let keep = glows.sorted { $0.value.observed != $1.value.observed ? $0.value.observed > $1.value.observed : $0.key < $1.key }.prefix(Self.capacity)
            glows = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return lit > 0 ? .illuminated(lit) : .unchanged
    }

    /// The light on `node` at `now`: rises briefly, then fades smoothly. With Reduce Motion it does not move: it
    /// holds and steps down in thirds (redrawn every few seconds), then disappears.
    public func intensity(of node: Int64, at now: Date, reduceMotion: Bool) -> (trend: InventorySizeSignal.Trend, value: Double)? {
        guard let glow = glows[node] else { return nil }
        let age = now.timeIntervalSince(glow.observed)
        guard age >= 0, age < Self.duration else { return nil }
        let remaining = 1 - age / Self.duration
        let value: Double
        if reduceMotion { value = glow.strength * (ceil(remaining * 3) / 3) }
        else { value = glow.strength * min(1, age / Self.rise + 0.2) * pow(remaining, 1.6) }
        return value > 0.001 ? (glow.trend, value) : nil
    }

    /// Whether anything is still lit.
    public func isActive(at now: Date) -> Bool { glows.values.contains { now.timeIntervalSince($0.observed) < Self.duration } }

    /// Whether anything drawn is still lit: the view animates only then, so light on entries outside the tree never
    /// keeps it redrawing.
    public func isActive(at now: Date, drawn: (Int64) -> Bool) -> Bool {
        glows.contains { now.timeIntervalSince($0.value.observed) < Self.duration && drawn($0.key) }
    }

    public mutating func expire(at now: Date) { glows = glows.filter { now.timeIntervalSince($0.value.observed) < Self.duration } }
}

// MARK: Palette

/// Restrained light on a deep charcoal ground: neutral warm white for structure, amber for measured growth,
/// cool blue for measured reduction. Opacity encodes depth and measurement state, never size.
public enum LivingTreePalette {
    public static let branch = AtlasTone(hue: 0.11, saturation: 0.05, brightness: 0.95)
    public static let tip = AtlasTone(hue: 0.12, saturation: 0.08, brightness: 1.0)
    public static let growth = AtlasTone(hue: 0.105, saturation: 0.72, brightness: 1.0)
    public static let reduction = AtlasTone(hue: 0.575, saturation: 0.5, brightness: 1.0)

    public static func tone(for trend: InventorySizeSignal.Trend) -> AtlasTone {
        switch trend {
        case .growth: return growth
        case .reduction: return reduction
        case .unchanged: return branch
        }
    }

    /// Branches fade gently toward the tips; an earlier (stale) size is quieter and a partial one slightly
    /// quieter; an unknown size is a faint marked hairline.
    public static func opacity(depth: Int, status: InventoryValueStatus, sizeKnown: Bool) -> Double {
        opacity(depth: depth, status: status, sizeKnown: sizeKnown, zoom: 1)
    }

    /// As above, with the fade toward the tips weakening as the view zooms in (relative to the fit), so finer
    /// structure comes out when it is inspected closely.
    public static func opacity(depth: Int, status: InventoryValueStatus, sizeKnown: Bool, zoom: Double) -> Double {
        guard sizeKnown else { return zoom > 1 ? min(0.5, 0.34 + 0.05 * log2(zoom)) : 0.34 }
        let fade = Double(max(0, depth - 1)) / (1 + 0.6 * log2(max(1, zoom)))
        var value = depth == 0 ? 0.84 : max(0.28, 0.78 * pow(0.88, fade))
        switch status {
        case .stale: value *= 0.6
        case .lowerBound: value *= 0.88
        default: break
        }
        return value
    }
}

// MARK: Change planning

public enum LivingTreeRefresh {
    /// Whether committed changes alter the drawn tree: a changed listing of a folder whose children are drawn, or a
    /// subtree change at or above any drawn folder (`ancestors`: the trunk's ancestors), any change to the trunk's own
    /// listing (an empty folder gaining its first entry), or generation-wide staleness that differs from the drawn
    /// snapshot's, which changes every element's measurement state.
    public static func needsRebuild(_ batch: InventoryChangeBatch, model: LivingTreeModel, ancestors: Set<Int64>) -> Bool {
        if !batch.available || batch.mustResynchronize || !batch.complete { return true }
        if let drawn = model.generationStale, drawn != batch.generationStale { return true }
        let folders = model.expandedFolders
        for change in batch.changes {
            if change.directoryID == model.root.id || folders.contains(change.directoryID) { return true }
            if change.subtree && (ancestors.contains(change.directoryID) || model.elements[.node(change.directoryID)] != nil) { return true }
        }
        return false
    }
}
