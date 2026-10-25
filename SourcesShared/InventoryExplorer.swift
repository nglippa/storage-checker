import Foundation

/// One visible line of the explorer outline: an entry, or a placeholder under a folder whose children are
/// loading, failed, empty, or continue beyond the loaded pages.
public struct InventoryExplorerRow: Identifiable, Sendable {
    public enum Content: Sendable {
        case node(InventoryNode)
        case loading
        case more(loaded: Int, total: Int64)
        /// The folder's loaded span reached `perFolderLimit`; the rest is reachable through the rankings.
        case limit(loaded: Int, total: Int64)
        case empty
        /// No indexed children because the folder itself is not fully listed (protected, unreadable, not yet
        /// listed): never presented as an empty folder.
        case unavailable(String)
        case failed(String)
    }
    /// Entry rows use the node id; placeholders use negative ids derived from their folder, so they never
    /// collide with entries and stay stable across reloads.
    public let id: Int64
    public let parent: Int64
    public let depth: Int
    public let content: Content

    public var node: InventoryNode? { if case .node(let node) = content { return node } else { return nil } }
}

/// Expansion, lazily loaded pages, selection and keyboard behavior of the explorer, independent of SwiftUI.
/// Only folders the person expanded are loaded, one bounded page at a time; nothing walks the catalog.
public struct InventoryExplorerState: Sendable {
    public struct Children: Sendable {
        public var items: [InventoryNode]
        public var next: InventoryChildCursor?
        var used: UInt64
    }

    public private(set) var rootID: Int64?
    public private(set) var expanded = Set<Int64>()
    public private(set) var children = [Int64: Children]()
    public private(set) var loading = Set<Int64>()
    public private(set) var failures = [Int64: String]()
    public var selection: Int64?
    /// Upper bound on cached entries. Pages of collapsed folders are dropped first (least recently used);
    /// expanded folders, the root and the selection's ancestors are kept.
    public let rowBudget: Int
    /// Largest entries kept per folder. Beyond this a folder is a long tail of small items, and loading
    /// it all would make memory grow with the widest folder (200,000 entries on the Mac mini; about 2.3 KB per cached entry).
    public let perFolderLimit: Int
    private var nodes = [Int64: InventoryNode]()
    private var clock: UInt64 = 0

    public init(rowBudget: Int = 12_000, perFolderLimit: Int = 5_000) {
        self.rowBudget = rowBudget; self.perFolderLimit = min(perFolderLimit, rowBudget)
    }

    /// Whether another page of `parent` may be requested.
    public func canLoadMore(_ parent: Int64) -> Bool {
        guard let list = children[parent], list.next != nil, !loading.contains(parent) else { return false }
        return list.items.count < perFolderLimit
    }

    public var cachedRows: Int { children.values.reduce(0) { $0 + $1.items.count } }
    public func node(_ id: Int64) -> InventoryNode? { nodes[id] }

    // MARK: Navigation

    /// Shows `root`'s contents. Returning to an ancestor keeps what was loaded and selects the child on the
    /// path that was left, so the place you came from stays highlighted.
    public mutating func setRoot(_ root: InventoryNode, cameFrom previous: [InventoryNode] = []) {
        nodes[root.id] = root
        guard root.id != rootID else { return }
        // The root is shown expanded without being recorded as expanded: a folder that was the root earlier
        // must not stay pinned in memory (navigating 1,000 folders kept 16,914 rows against a 12,000 budget).
        rootID = root.id
        if let index = previous.firstIndex(where: { $0.id == root.id }), index + 1 < previous.count {
            selection = previous[index + 1].id
        } else if let selection, !isDescendant(selection, of: root.id) {
            self.selection = nil
        }
    }

    /// Folders whose next page should be requested now: the root when nothing is loaded yet.
    public var pendingLoads: [Int64] {
        guard let rootID, children[rootID] == nil, !loading.contains(rootID), failures[rootID] == nil else { return [] }
        return [rootID]
    }

    public func isExpanded(_ id: Int64) -> Bool { expanded.contains(id) }

    /// Expands a folder. Returns true when its first page must be loaded.
    @discardableResult
    public mutating func expand(_ id: Int64) -> Bool {
        guard let node = nodes[id], node.kind == .directory else { return false }
        expanded.insert(id)
        touch(id)
        return children[id] == nil && !loading.contains(id)
    }

    /// Collapses a folder. A selection inside it moves to the folder, as in Finder.
    public mutating func collapse(_ id: Int64) {
        guard id != rootID else { return }
        expanded.remove(id)
        if let selection, selection != id, isDescendant(selection, of: id) { self.selection = id }
    }

    public mutating func beginLoading(_ parent: Int64) { loading.insert(parent); failures[parent] = nil }

    /// Appends a page (or replaces the folder's pages when `replacing`). Entries already present are
    /// updated in place, never duplicated.
    public mutating func receive(parent: Int64, page: InventoryChildPage, replacing: Bool = false) {
        loading.remove(parent)
        failures[parent] = nil
        var current = replacing ? Children(items: [], next: nil, used: 0) : (children[parent] ?? Children(items: [], next: nil, used: 0))
        var index = [Int64: Int](minimumCapacity: current.items.count)
        for (i, item) in current.items.enumerated() { index[item.id] = i }
        for item in page.items {
            nodes[item.id] = item
            if let i = index[item.id] { current.items[i] = item }
            else { index[item.id] = current.items.count; current.items.append(item) }
        }
        if replacing, let previous = children[parent] {
            // Entries that left the reloaded span release their cached rows, so repeated refreshes of a busy
            // folder do not accumulate rows. The selection and folders with loaded pages are kept.
            let present = Set(page.items.map(\.id))
            for item in previous.items where !present.contains(item.id) && item.id != selection && children[item.id] == nil { nodes[item.id] = nil }
        }
        current.next = page.next
        children[parent] = current
        touch(parent)
        evictIfNeeded()
    }

    public mutating func fail(parent: Int64, message: String) {
        loading.remove(parent)
        failures[parent] = message
    }

    /// The folder's own entry was refreshed (for example its size changed); keeps its loaded pages.
    public mutating func update(_ node: InventoryNode) { nodes[node.id] = node }

    /// Entries that no longer exist are removed together with anything loaded beneath them.
    public mutating func remove(_ id: Int64) {
        for (parent, var list) in children {
            if let i = list.items.firstIndex(where: { $0.id == id }) { list.items.remove(at: i); children[parent] = list }
        }
        drop(id)
        nodes[id] = nil
        if selection == id { selection = nil }
    }

    // MARK: Visible rows

    /// The flattened outline: the root's children, and recursively the children of expanded folders.
    public var rows: [InventoryExplorerRow] {
        guard let rootID else { return [] }
        var result = [InventoryExplorerRow]()
        append(children: rootID, depth: 0, into: &result)
        return result
    }

    private func append(children parent: Int64, depth: Int, into result: inout [InventoryExplorerRow]) {
        let slot = -(parent * 4)
        if let message = failures[parent] {
            result.append(InventoryExplorerRow(id: slot - 1, parent: parent, depth: depth, content: .failed(message))); return
        }
        guard let list = children[parent] else {
            result.append(InventoryExplorerRow(id: slot - 2, parent: parent, depth: depth, content: .loading)); return
        }
        if list.items.isEmpty && list.next == nil {
            let content: InventoryExplorerRow.Content
            if let folder = nodes[parent], folder.status != .complete { content = .unavailable(InventoryNodePresentation.coverage(folder)) }
            else { content = .empty }
            result.append(InventoryExplorerRow(id: slot - 3, parent: parent, depth: depth, content: content)); return
        }
        for item in list.items {
            result.append(InventoryExplorerRow(id: item.id, parent: parent, depth: depth, content: .node(item)))
            if item.kind == .directory && expanded.contains(item.id) { append(children: item.id, depth: depth + 1, into: &result) }
        }
        if list.next != nil {
            let total = nodes[parent]?.childCount ?? Int64(list.items.count)
            let content: InventoryExplorerRow.Content = list.items.count >= perFolderLimit ? .limit(loaded: list.items.count, total: total) : .more(loaded: list.items.count, total: total)
            result.append(InventoryExplorerRow(id: slot - 4, parent: parent, depth: depth, content: content))
        }
    }

    // MARK: Keyboard

    public enum Key: Sendable { case up, down, left, right }
    public enum KeyResult: Equatable, Sendable { case none, moved, expanded(needsLoad: Bool), collapsed }

    /// Finder-style outline keys: up and down move between entry rows; right expands a folder or moves into
    /// its first child; left collapses an expanded folder or moves to the parent folder.
    public mutating func handle(_ key: Key) -> KeyResult {
        let entries = rows.compactMap { row -> (id: Int64, parent: Int64)? in row.node == nil ? nil : (row.id, row.parent) }
        guard !entries.isEmpty else { return .none }
        guard let selection, let position = entries.firstIndex(where: { $0.id == selection }) else {
            self.selection = entries.first?.id; return .moved
        }
        switch key {
        case .up:
            guard position > 0 else { return .none }
            self.selection = entries[position - 1].id; return .moved
        case .down:
            guard position + 1 < entries.count else { return .none }
            self.selection = entries[position + 1].id; return .moved
        case .right:
            guard let node = nodes[selection], node.kind == .directory else { return .none }
            if !expanded.contains(selection) { return .expanded(needsLoad: expand(selection)) }
            if let first = children[selection]?.items.first { self.selection = first.id; return .moved }
            return .none
        case .left:
            if expanded.contains(selection) { collapse(selection); return .collapsed }
            let parent = entries[position].parent
            guard parent != rootID else { return .none }
            self.selection = parent; return .moved
        }
    }

    // MARK: Refresh

    /// Folders to reload after the inventory changed, with how many entries are loaded in each so the
    /// reload can fetch the same span. Collapsed folders are reloaded only when expanded again.
    public var reloadPlan: [(parent: Int64, count: Int)] {
        children.compactMap { parent, list in expanded.contains(parent) || parent == rootID ? (parent, list.items.count) : nil }
            .sorted { $0.parent < $1.parent }
    }

    /// Marks collapsed folders' pages as outdated, so expanding them again loads fresh pages.
    public mutating func invalidateCollapsed() {
        for parent in children.keys where !expanded.contains(parent) && parent != rootID { discardPage(parent) }
    }

    /// Entries cached for display (rows of loaded pages plus the folders and selection they hang from).
    public var cachedNodeCount: Int { nodes.count }

    /// Drops a folder's loaded pages and releases its entries' cached rows, except the selection, its ancestors,
    /// and entries that are themselves folders with pages or expansion state.
    private mutating func discardPage(_ parent: Int64) {
        guard let list = children.removeValue(forKey: parent) else { return }
        var keep = Set<Int64>()
        if let selection { keep.insert(selection); var current = nodes[selection]?.parentID; while let id = current, keep.insert(id).inserted { current = nodes[id]?.parentID } }
        if let rootID { keep.insert(rootID) }
        for item in list.items where !keep.contains(item.id) && children[item.id] == nil && !expanded.contains(item.id) { nodes[item.id] = nil }
    }

    // MARK: Incremental refresh

    /// Folders with loaded pages, visible or not.
    public var loadedFolders: Set<Int64> { Set(children.keys) }

    /// Whether `id` is one of `ancestors` or lies beneath one of them, by the cached parent chain.
    public func isAtOrBeneath(_ id: Int64, _ ancestors: Set<Int64>) -> Bool {
        if ancestors.contains(id) { return true }
        var current = nodes[id]?.parentID, steps = 0
        while let parent = current, steps < 1024 {
            if ancestors.contains(parent) { return true }
            current = nodes[parent]?.parentID; steps += 1
        }
        return false
    }

    /// The visible part of `reloadPlan` that a change feed affects: folders whose listing changed, and folders
    /// at or beneath a directory whose subtree changed. Everything else keeps its loaded pages untouched.
    public func refreshTargets(listing: Set<Int64>, subtrees: Set<Int64>) -> [(parent: Int64, count: Int)] {
        reloadPlan.filter { listing.contains($0.parent) || (!subtrees.isEmpty && isAtOrBeneath($0.parent, subtrees)) }
    }

    /// Drops the loaded pages of collapsed folders the change feed affects; unaffected collapsed folders keep
    /// their pages and reopen without a read.
    public mutating func invalidateCollapsed(listing: Set<Int64>, subtrees: Set<Int64>) {
        for parent in children.keys where !expanded.contains(parent) && parent != rootID
            && (listing.contains(parent) || (!subtrees.isEmpty && isAtOrBeneath(parent, subtrees))) { discardPage(parent) }
    }

    /// The entry ids each folder showed, for telling a vanished selection apart after a refresh.
    public func shownEntries(_ folders: [Int64]) -> [Int64: Set<Int64>] {
        var result = [Int64: Set<Int64>]()
        for folder in folders { if let list = children[folder] { result[folder] = Set(list.items.map(\.id)) } }
        return result
    }

    /// Applies one visible-branch refresh. Reloaded folders replace their spans in place (expansion and the
    /// selection are kept by id); deleted folders are removed with everything beneath them; failed folders keep
    /// what they showed. A deleted selection moves to its closest remaining folder, as Finder does.
    /// A folder whose loaded span changed while it was being re-read (another page arrived, or a load is in flight) is
    /// not overwritten with the older span; it is returned so the caller refreshes it again.
    @discardableResult
    public mutating func apply(_ result: InventoryVisibleRefreshResult) -> [Int64] {
        var superseded = [Int64]()
        for folder in result.folders where children[folder.parent] != nil {
            guard children[folder.parent]?.items.count == folder.loaded, !loading.contains(folder.parent) else { superseded.append(folder.parent); continue }
            receive(parent: folder.parent, page: folder.page, replacing: true)
            if let node = folder.node { update(node) }
        }
        for id in result.deleted { removeDeleted(id) }
        if let gone = result.selectionDeleted, selection == gone { removeDeleted(gone) }
        if let moved = result.selectionNode, selection == moved.id { update(moved) }
        evictIfNeeded()
        return superseded
    }

    /// Removes an entry that no longer exists. A selection on it, or beneath it, moves to the nearest
    /// ancestor that is still loaded (the root at worst) instead of being cleared or left dangling.
    public mutating func removeDeleted(_ id: Int64) {
        var fallback: Int64? = nil
        if let selection, isAtOrBeneath(selection, [id]) {
            var current = nodes[id]?.parentID, steps = 0
            while let candidate = current, steps < 1024 {
                if candidate == rootID || children[candidate] != nil { fallback = candidate; break }
                current = nodes[candidate]?.parentID; steps += 1
            }
            if fallback == nil { fallback = rootID }
        }
        let previous = selection.flatMap { isAtOrBeneath($0, [id]) ? $0 : nil }
        remove(id)
        if let previous {
            selection = fallback == rootID ? nil : fallback
            if previous != fallback { nodes[previous] = nil }
        }
    }

    // MARK: Helpers

    private mutating func touch(_ id: Int64) { clock &+= 1; children[id]?.used = clock }

    private func isDescendant(_ id: Int64, of ancestor: Int64) -> Bool {
        var current = nodes[id]?.parentID, steps = 0
        while let parent = current, steps < 1024 {
            if parent == ancestor { return true }
            current = nodes[parent]?.parentID; steps += 1
        }
        return false
    }

    private mutating func drop(_ parent: Int64) {
        guard let list = children.removeValue(forKey: parent) else { return }
        expanded.remove(parent)
        for item in list.items {
            if item.kind == .directory { drop(item.id) }
            if item.id != selection { nodes[item.id] = nil }
        }
    }

    private mutating func evictIfNeeded() {
        var total = cachedRows
        guard total > rowBudget else { return }
        var keep = Set<Int64>(expanded)
        if let rootID { keep.insert(rootID) }
        var current = selection.flatMap { nodes[$0]?.parentID }
        while let id = current { keep.insert(id); current = nodes[id]?.parentID }
        for (parent, list) in children.sorted(by: { $0.value.used < $1.value.used }) where !keep.contains(parent) {
            guard total > rowBudget else { break }
            total -= list.items.count
            drop(parent)
        }
    }
}
