import Foundation
import SQLite3

public enum InventoryNodeKind: String, Codable, Sendable {
    case directory, file, symlink, other
}

public enum InventoryValueStatus: String, Codable, Sendable {
    case complete
    case lowerBound = "lower_bound"
    case unknown
    case stale
}

public enum InventorySort: String, Codable, Sendable {
    case name, allocated, logical, modified
}

public enum InventoryLargestKind: String, Codable, Sendable {
    case files, directories, all
}

public struct InventoryIdentity: Codable, Hashable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let birthNanoseconds: Int64
    public let volumeUUID: String?

    public var stableKey: String {
        let volume = volumeUUID.map { "volume:\($0)" } ?? "device:\(device)"
        return "\(volume):\(inode):\(birthNanoseconds)"
    }

    public init(device: Int64, inode: UInt64, birthNanoseconds: Int64, volumeUUID: String? = nil) {
        self.device = device
        self.inode = inode
        self.birthNanoseconds = birthNanoseconds
        self.volumeUUID = volumeUUID
    }
}

public struct InventoryNode: Codable, Identifiable, Sendable {
    public let id: Int64
    public let parentID: Int64?
    public let identity: InventoryIdentity
    public let path: String
    public let name: String
    public let kind: InventoryNodeKind
    public let logicalBytes: Int64?
    public let allocatedBytes: Int64?
    // Prior observations are explicit: current-value fields remain nil while stale.
    public let previousLogicalBytes: Int64?
    public let previousAllocatedBytes: Int64?
    // Object metadata is independent of the entry’s contribution to parent totals.
    public let objectLogicalBytes: Int64?
    public let objectAllocatedBytes: Int64?
    public let directLogicalBytes: Int64
    public let directAllocatedBytes: Int64
    public let childCount: Int64
    public let descendantFiles: Int64
    public let descendantDirectories: Int64
    public let status: InventoryValueStatus
    public let coverageState: String
    // Current directory-listing activity, independent of the last committed value.
    public let listingState: String?
    public let statusReason: String?
    public let measuredAt: Date?
    public let modifiedAt: Date?
    public let generation: Int64
    public let isHardlinkAlias: Bool
    // Reserved for trustworthy inventory-to-inventory evidence. Coarse coverage history is
    // intentionally never projected into individual nodes.
    public let historicalGrowthBytes: Int64?
}

public struct InventoryPage: Codable, Sendable {
    public let items: [InventoryNode]
    public let hasMore: Bool

    public init(items: [InventoryNode], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}

/// Where an explorer page ends, in the order (allocated size descending, unmeasured last, then name
/// ignoring case, then id). The next page starts strictly after it, so pages never overlap or skip rows
/// even while the worker commits new entries.
public struct InventoryChildCursor: Codable, Hashable, Sendable {
    public let allocated: Int64?
    public let name: String
    public let id: Int64
    public init(allocated: Int64?, name: String, id: Int64) { self.allocated = allocated; self.name = name; self.id = id }
}

public struct InventoryChildPage: Sendable {
    public let items: [InventoryNode]
    /// Present when more children follow.
    public let next: InventoryChildCursor?
    public init(items: [InventoryNode], next: InventoryChildCursor?) { self.items = items; self.next = next }
}

/// The children of a folder after its first `skip` entries in explorer order: what the storage map groups
/// into "Other items". Sums the indexed values exactly; entries without a value are counted, not sized.
public struct InventoryChildRemainder: Equatable, Sendable {
    public let count: Int64
    public let allocated: Int64
    public let unmeasured: Int64
    public init(count: Int64, allocated: Int64, unmeasured: Int64) { self.count = count; self.allocated = allocated; self.unmeasured = unmeasured }
}

public struct InventoryStatus: Codable, Sendable {
    public let generation: Int64?
    public let state: String
    public let rootPath: String?
    public let totalNodes: Int64
    public let completedDirectories: Int64
    public let pendingDirectories: Int64
    public let staleDirectories: Int64
    public let unknownDirectories: Int64
    public let queuedDirectoryJobs: Int64
    public let hasReconciliationWork: Bool
    public let hasInitialDiscoveryWork: Bool
    public let progress: Double?
    public let completeness: InventoryValueStatus
    public let reason: String?
    public let updatedAt: Date?
    public let createdAt: Date?
    /// Durable first-pass milestone recorded by the inventory engine for this generation.
    public var initialCompletion: InventoryInitialCompletion = .unsupported
    public var initialCompletedAt: Date? = nil
    /// A broad recheck after an event-history gap is queued (distinct from deletion cleanup).
    public var hasEventGapRecheck = false
    /// Queued directory listings set aside because the folder changed during every attempt in the
    /// last run (for example a browser cache). Included in `queuedDirectoryJobs`; retried on each update.
    public var deferredDirectories: Int64 = 0
    /// File-event history is unavailable for this volume, so changes cannot currently be tracked.
    public var eventHistoryUnavailable = false
    /// The worker paused itself because free space fell below its safety threshold.
    public var lowSpacePaused = false
    /// While a recheck of the whole inventory runs: how far its frontier has moved through the fixed
    /// set of catalogued entries (0–1), and whether a person asked for it ("Refresh entire inventory").
    public var refreshFraction: Double?
    public var refreshIsManual = false
}

/// What the inventory attributes, and what it could not measure, for the storage accounting summary.
public struct InventoryAccounting: Sendable, Equatable {
    /// Root totals: the sum of every indexed file's own size (hard links once, clones once per file).
    public var indexedAllocated: Int64 = 0
    public var indexedLogical: Int64 = 0
    public var rootStatus = "unknown"
    /// Folders not opened because macOS privacy controls protect them (Full Disk Access would include them).
    public var protectedFolders: Int64 = 0
    /// Folders macOS refused for other reasons (owned by another user, system-protected, unreadable).
    public var unavailableFolders: Int64 = 0
    /// Individual entries whose size macOS refused inside otherwise listed folders.
    public var unreadableEntries: Int64 = 0
    /// Other file systems, cloud placeholders and Storage Monitor's own data folder, outside the index.
    public var excludedFolders: Int64 = 0
    /// What the background worker last observed for itself: "granted", "not_granted" or "unknown".
    public var fullDiskAccess: String?
    public init() {}
}

/// Generation reason written when the worker pauses for low free space; it resumes on a later wake.
public let inventoryLowSpaceReason = "paused: low disk space"

/// One worker progress sample (persisted every ~10 s of work, kept for two hours).
public struct InventoryProgressSample: Codable, Sendable, Equatable {
    public let sampledAt: Date
    public let completedListings: Int64
    public let queuedListings: Int64
    public let nodes: Int64
    public let allocatedBytes: Int64
    public init(sampledAt: Date, completedListings: Int64, queuedListings: Int64, nodes: Int64, allocatedBytes: Int64) {
        self.sampledAt = sampledAt; self.completedListings = completedListings; self.queuedListings = queuedListings
        self.nodes = nodes; self.allocatedBytes = allocatedBytes
    }
}

/// Reason on a folder whose own listing is current but whose total includes stale descendants.
public let inventoryDescendantStaleReason = "Includes earlier sizes of some subfolders that are waiting to be listed again."

/// Durable reason on a deferred directory job until its next listing attempt. Written by the worker.
public let inventoryDeferredReason = "deferred: a directory kept changing during listing"

public enum InventoryInitialCompletion: String, Codable, Sendable {
    case notStarted = "not_started"   // no generation exists
    case inProgress = "in_progress"   // first pass recorded as unfinished
    case complete                     // first pass durably recorded as finished
    case unknown                      // generation predates the milestone; not yet confirmed
    case unsupported                  // catalog written only by a worker without the milestone
}

public enum InventoryReaderError: Error, CustomStringConvertible {
    case open(String)
    case query(String)

    public var description: String {
        switch self {
        case .open(let message), .query(let message): return message
        }
    }
}

private let inventoryReadOnlyTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class InventoryQueryDeadline {
    let expires: Date
    init(_ seconds: TimeInterval) { expires = Date().addingTimeInterval(seconds) }
}

private let inventoryProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { pointer in
    guard let pointer else { return 1 }
    if Task.isCancelled { return 1 }
    let deadline = Unmanaged<InventoryQueryDeadline>.fromOpaque(pointer).takeUnretainedValue()
    return Date() >= deadline.expires ? 1 : 0
}

private final class InventoryReadConnection {
    var db: OpaquePointer?
    private var deadline: Unmanaged<InventoryQueryDeadline>?

    /// `deadline`: how long statements on this connection may run in total before they are interrupted.
    init(_ path: String, deadline seconds: TimeInterval = 0.25) throws {
        try Task.checkCancellation()
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            throw InventoryReaderError.open("Cannot open inventory: \(detail)")
        }
        sqlite3_busy_timeout(db, 100)
        deadline = .passRetained(InventoryQueryDeadline(seconds))
        sqlite3_progress_handler(db, 1_000, inventoryProgressCallback, deadline?.toOpaque())
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA foreign_keys=ON;", nil, nil, nil) == SQLITE_OK else {
            throw InventoryReaderError.open("Cannot configure read-only inventory")
        }
    }

    deinit {
        sqlite3_progress_handler(db, 0, nil, nil)
        deadline?.release()
        sqlite3_close(db)
    }

    func statement(_ sql: String, _ values: [Any?] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw InventoryReaderError.query(String(cString: sqlite3_errmsg(db)))
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, inventoryReadOnlyTransient)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    func scalarInt(_ sql: String, _ values: [Any?] = []) throws -> Int64 {
        let statement = try self.statement(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(db))) }
        return result == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
    }
}

public actor InventoryReader {
    private let databasePath: String
    private let maximumPageSize = 256

    public init(path: String) { databasePath = path }

    public func root() throws -> InventoryNode? {
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection) else { return nil }
        return try fetchOne(connection, sql: Self.baseSelect + " WHERE n.generation_id=? AND n.parent_id IS NULL LIMIT 1", values: [generation])
    }

    public func node(id: Int64) throws -> InventoryNode? {
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection) else { return nil }
        return try fetchOne(connection, sql: Self.baseSelect + " WHERE n.id=? AND n.generation_id=? LIMIT 1", values: [id,generation])
    }

    // Resolve only indexed parent/name relationships. Never traverses the filesystem
    // or follows symlinks; an unindexed target returns its closest known directory.
    public func locateDirectory(path: String) throws -> (node: InventoryNode, exact: Bool) {
        let c = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(c),
              let root = try fetchOne(c, sql: Self.baseSelect + " WHERE n.generation_id=? AND n.parent_id IS NULL", values: [generation]) else { throw InventoryReaderError.query("Inventory discovery has not started yet") }
        var target = path
        while target.count > 1 && target.hasSuffix("/") { target.removeLast() }
        let data = "/System/Volumes/Data"
        if root.path.hasPrefix(data), !target.hasPrefix(data) { target = data + target }
        guard target == root.path || target.hasPrefix(root.path + "/"),
              !target.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw InventoryReaderError.query("Choose a directory inside the indexed startup Data scope") }
        let parts = target == root.path ? [] : String(target.dropFirst(root.path.count+1)).split(separator: "/")
        guard parts.count < 1024 else { throw InventoryReaderError.query("Directory path is too deep") }
        var current = root
        for part in parts {
            guard let child = try fetchOne(c, sql: Self.baseSelect + " WHERE n.generation_id=? AND n.parent_id=? AND n.name=? LIMIT 1", values: [generation,current.id,String(part)]) else { return (current,false) }
            guard child.kind == .directory else { throw InventoryReaderError.query("Inventory navigation does not follow symbolic links or files") }
            current = child
        }
        return (current,true)
    }

    public func children(parentID: Int64, offset: Int = 0, limit: Int = 100, sort: InventorySort = .name) throws -> InventoryPage {
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection) else { return InventoryPage(items: [], hasMore: false) }
        let order: String
        switch sort {
        case .name: order = "n.name COLLATE NOCASE, n.id"
        case .allocated: order = "COALESCE(n.total_allocated,-1) DESC, n.name COLLATE NOCASE, n.id"
        case .logical: order = "COALESCE(n.total_logical,-1) DESC, n.name COLLATE NOCASE, n.id"
        case .modified: order = "o.modified_at DESC, n.name COLLATE NOCASE, n.id"
        }
        return try page(connection, sql: Self.baseSelect + " WHERE n.parent_id=? AND n.generation_id=? ORDER BY \(order) LIMIT ? OFFSET ?", values: [parentID, generation, bounded(limit) + 1, max(0, offset)], limit: bounded(limit))
    }

    /// One page of a folder's children for the explorer, largest first. Keyset pagination over the
    /// `inventory_nodes_children_allocated` index: no sort, no OFFSET, and the cost of a page does not
    /// grow with the folder's size or how deep into it the page is. The folder's path and staleness are
    /// resolved once per page instead of once per row.
    public func explorerChildren(parentID: Int64, after cursor: InventoryChildCursor? = nil, limit: Int = 200) throws -> InventoryChildPage {
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection) else { return InventoryChildPage(items: [], next: nil) }
        let context = try childContext(connection, parentID: parentID, generation: generation)
        return try childPage(connection, generation: generation, context: context, parentID: parentID, after: cursor, limit: limit)
    }

    /// A folder's first `count` children (whole pages) and the exact totals of the rest, read in one SQLite
    /// read transaction: the storage map's tiles and its "Other items" group come from the same snapshot, so
    /// a commit by the worker between two separate reads cannot make them disagree.
    /// `pageLimit` bounds each page (the nested storage map reads one page of 60 per folder).
    public func explorerSpan(parentID: Int64, count: Int, pageLimit: Int = 200) throws -> (page: InventoryChildPage, remainder: InventoryChildRemainder?) {
        let connection = try InventoryReadConnection(databasePath)
        guard sqlite3_exec(connection.db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
        defer { sqlite3_exec(connection.db, "COMMIT", nil, nil, nil) }
        guard let generation = try activeGeneration(connection) else { return (InventoryChildPage(items: [], next: nil), nil) }
        let context = try childContext(connection, parentID: parentID, generation: generation)
        var items = [InventoryNode](), cursor: InventoryChildCursor? = nil
        repeat {
            let page = try childPage(connection, generation: generation, context: context, parentID: parentID, after: cursor, limit: pageLimit)
            items += page.items; cursor = page.next
        } while cursor != nil && items.count < max(1, count)
        let remainder = cursor == nil ? nil : try remainder(connection, parentID: parentID, skip: items.count)
        return (InventoryChildPage(items: items, next: cursor), remainder)
    }

    private func childPage(_ connection: InventoryReadConnection, generation: Int64, context: (path: String, stale: Bool), parentID: Int64, after cursor: InventoryChildCursor?, limit: Int) throws -> InventoryChildPage {
        let wanted = bounded(limit) + 1
        let select = Self.baseSelect.replacingOccurrences(of: " FROM inventory_nodes n JOIN", with: ",\(Self.ownStaleColumn) FROM inventory_nodes n JOIN")
        let order = " ORDER BY n.total_allocated DESC, n.name COLLATE NOCASE, n.id LIMIT ?"
        // The leading `>=` lets SQLite seek the index; the OR alone made it rescan a tier of equally
        // sized entries from its start on every page (147 ms deep in a 200k-entry folder).
        let afterName = " AND n.name >= ? COLLATE NOCASE AND (n.name > ? COLLATE NOCASE OR n.id > ?)"
        var parts: [(String, [Any?])] = []
        // `+n.generation_id` keeps SQLite on the size index: with a plain generation term it chose the
        // (generation, parent, name) index for the unmeasured tier and walked a 200k-entry folder (140 ms).
        let base = " WHERE n.parent_id=? AND +n.generation_id=?"
        switch cursor {
        case nil:
            parts = [(base, [parentID, generation])]
        case let cursor? where cursor.allocated != nil:
            parts = [(base + " AND n.total_allocated=?" + afterName, [parentID, generation, cursor.allocated, cursor.name, cursor.name, cursor.id]),
                     (base + " AND n.total_allocated<?", [parentID, generation, cursor.allocated]),
                     (base + " AND n.total_allocated IS NULL", [parentID, generation])]
        case let cursor?:
            parts = [(base + " AND n.total_allocated IS NULL" + afterName, [parentID, generation, cursor.name, cursor.name, cursor.id])]
        }
        var found = [Row]()
        for (filter, values) in parts where found.count < wanted {
            found += try rows(connection, sql: select + filter + order, values: values + [wanted - found.count], context: context)
        }
        let more = found.count > bounded(limit)
        if more { found.removeLast(found.count - bounded(limit)) }
        let next = more ? found.last.map { InventoryChildCursor(allocated: $0.sortAllocated, name: $0.node.name, id: $0.node.id) } : nil
        return InventoryChildPage(items: found.map(\.node), next: next)
    }

    /// Exact totals of a folder's children beyond the first `skip` in explorer order (allocated size
    /// descending, unmeasured last, name, id). Reads only the covering children index: about 10 ms for the
    /// 199,800 entries after the first page of a 200,000-entry folder. A parent's children always share its
    /// generation, so no per-row generation check (which cost a table lookup per entry, 244 ms) is needed.
    public func explorerRemainder(parentID: Int64, skip: Int) throws -> InventoryChildRemainder {
        try remainder(InventoryReadConnection(databasePath), parentID: parentID, skip: skip)
    }

    private func remainder(_ connection: InventoryReadConnection, parentID: Int64, skip: Int) throws -> InventoryChildRemainder {
        let statement = try connection.statement("SELECT COUNT(*),COALESCE(SUM(a),0),COALESCE(SUM(a IS NULL),0) FROM (SELECT n.total_allocated AS a FROM inventory_nodes n WHERE n.parent_id=? ORDER BY n.total_allocated DESC, n.name COLLATE NOCASE, n.id LIMIT -1 OFFSET ?)", [parentID, max(0, skip)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
        return InventoryChildRemainder(count: sqlite3_column_int64(statement, 0), allocated: sqlite3_column_int64(statement, 1), unmeasured: sqlite3_column_int64(statement, 2))
    }

    public func largest(kind: InventoryLargestKind, under: Int64? = nil, offset: Int = 0, limit: Int = 100) throws -> InventoryPage {
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection) else { return InventoryPage(items: [], hasMore: false) }
        let filter: String
        switch kind {
        case .files: filter = "AND n.kind='file'"
        case .directories: filter = "AND n.kind='directory'"
        case .all: filter = ""
        }
        if under == nil {
            return try page(connection, sql: Self.baseSelect + " WHERE n.generation_id=? AND n.parent_id IS NOT NULL \(filter) ORDER BY n.total_allocated DESC,n.id LIMIT ? OFFSET ?", values: [generation, bounded(limit) + 1, max(0, offset)], limit: bounded(limit))
        }
        let root: Int64
        if let under { root = under }
        else { root = try connection.scalarInt("SELECT id FROM inventory_nodes WHERE generation_id=? AND parent_id IS NULL LIMIT 1", [generation]) }
        guard root != 0 else { return InventoryPage(items: [], hasMore: false) }
        let estimated = try connection.scalarInt("SELECT descendant_entries FROM inventory_nodes WHERE id=?", [root])
        let direct = try connection.scalarInt("SELECT COUNT(*) FROM (SELECT 1 FROM inventory_nodes WHERE parent_id=? LIMIT 8193)", [root])
        if max(estimated, direct) > 8_192 {
            // Large subtrees must not materialize every descendant before returning a
            // page. Walk the global size index and test each candidate's short ancestry.
            // Small subtrees use the bounded descendant query below, so a tiny folder
            // does not have to search the whole disk to prove there are no more matches.
            let membership = "EXISTS(WITH RECURSIVE chain(id,parent_id,depth) AS (SELECT n.id,n.parent_id,0 UNION ALL SELECT p.id,p.parent_id,c.depth+1 FROM inventory_nodes p JOIN chain c ON p.id=c.parent_id WHERE c.depth<1023) SELECT 1 FROM chain WHERE id=?)"
            return try page(connection, sql: Self.baseSelect + " WHERE n.generation_id=? AND n.id<>? \(filter) AND \(membership) ORDER BY n.total_allocated DESC,n.id LIMIT ? OFFSET ?", values: [generation,root,root,bounded(limit)+1,max(0,offset)], limit: bounded(limit))
        }
        let sql = "WITH RECURSIVE subtree(id) AS (SELECT ? UNION ALL SELECT c.id FROM inventory_nodes c JOIN subtree s ON c.parent_id=s.id WHERE c.generation_id=?) " + Self.baseSelect + " JOIN subtree q ON q.id=n.id WHERE n.id<>? \(filter) ORDER BY COALESCE(n.total_allocated,-1) DESC,n.id LIMIT ? OFFSET ?"
        return try page(connection, sql: sql, values: [root, generation, root, bounded(limit) + 1, max(0, offset)], limit: bounded(limit))
    }

    public func search(text: String, under: Int64? = nil, offset: Int = 0, limit: Int = 100) throws -> InventoryPage {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return InventoryPage(items: [], hasMore: false) }
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection) else { return InventoryPage(items: [], hasMore: false) }
        func prefix(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        }
        var components = term.split(separator: "/").map(String.init)
        if term.hasPrefix("/") {
            let root = try fetchOne(connection, sql: Self.baseSelect + " WHERE n.generation_id=? AND n.parent_id IS NULL", values: [generation])
            guard let root else { return InventoryPage(items: [], hasMore: false) }
            if term == root.path { return InventoryPage(items: [root], hasMore: false) }
            if term.hasPrefix(root.path + "/") { components = String(term.dropFirst(root.path.count)).split(separator: "/").map(String.init) }
            var parent = root.id
            for component in components.dropLast() {
                let id = try connection.scalarInt("SELECT id FROM inventory_nodes WHERE generation_id=? AND parent_id=? AND name=? COLLATE NOCASE LIMIT 1", [generation,parent,component])
                guard id != 0 else { return InventoryPage(items: [], hasMore: false) }
                parent = id
            }
            return try page(connection, sql: Self.baseSelect + " WHERE n.generation_id=? AND n.parent_id=? AND n.name LIKE ? ESCAPE '\\' ORDER BY n.name COLLATE NOCASE,n.id LIMIT ? OFFSET ?", values: [generation,parent,prefix(components.last ?? ""),bounded(limit)+1,max(0,offset)], limit: bounded(limit))
        }
        // Prefix lookup uses the name index. Relative paths join only their named ancestors;
        // searching never constructs and sorts the paths of the entire filesystem.
        guard components.count <= 32 else { throw InventoryReaderError.query("Use an absolute path for searches deeper than 32 components") }
        var joins = "", filters = "", values: [Any?] = [generation,prefix(components.last ?? term)]
        for (i,component) in components.dropLast().reversed().enumerated() {
            let alias = "p\(i)"
            joins += " JOIN inventory_nodes \(alias) ON \(alias).id=\(i == 0 ? "n" : "p\(i-1)").parent_id"
            filters += " AND \(alias).name=? COLLATE NOCASE"; values.append(component)
        }
        if let under {
            filters += " AND EXISTS(WITH RECURSIVE chain(id,parent_id) AS (SELECT n.id,n.parent_id UNION ALL SELECT p.id,p.parent_id FROM inventory_nodes p JOIN chain c ON p.id=c.parent_id) SELECT 1 FROM chain WHERE id=?)"
            values.append(under)
        }
        values += [bounded(limit)+1,max(0,offset)]
        return try page(connection, sql: Self.baseSelect + joins + " WHERE n.generation_id=? AND n.name LIKE ? ESCAPE '\\'" + filters + " ORDER BY n.name COLLATE NOCASE,n.id LIMIT ? OFFSET ?", values: values, limit: bounded(limit))
    }

    public func breadcrumbs(id: Int64) throws -> [InventoryNode] {
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection) else { return [] }
        let sql = "WITH RECURSIVE ancestors(id,parent_id,depth) AS (SELECT id,parent_id,0 FROM inventory_nodes WHERE id=? AND generation_id=? UNION ALL SELECT n.id,n.parent_id,a.depth+1 FROM inventory_nodes n JOIN ancestors a ON a.parent_id=n.id WHERE a.depth<1023) " + Self.baseSelect + " JOIN ancestors a ON a.id=n.id ORDER BY a.depth DESC"
        return try rows(connection, sql: sql, values: [id,generation]).map(\.node)
    }

    public func status() throws -> InventoryStatus {
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection) else {
            return InventoryStatus(generation: nil, state: "uninitialized", rootPath: nil, totalNodes: 0, completedDirectories: 0, pendingDirectories: 0, staleDirectories: 0, unknownDirectories: 0, queuedDirectoryJobs: 0, hasReconciliationWork: false, hasInitialDiscoveryWork: false, progress: nil, completeness: .unknown, reason: nil, updatedAt: nil, createdAt: nil, initialCompletion: .notStarted)
        }
        // Read-only: a catalog never migrated by a milestone-aware worker reports 'unsupported'.
        let milestone = try connection.scalarInt("SELECT COUNT(*) FROM pragma_table_info('inventory_generations') WHERE name='initial_completion'") > 0
            ? try connection.statement("SELECT initial_completion,initial_completed_at FROM inventory_generations WHERE id=?", [generation]) : nil
        defer { sqlite3_finalize(milestone) }
        var initialCompletion = InventoryInitialCompletion.unsupported, initialCompletedAt: Date?
        if let milestone, sqlite3_step(milestone) == SQLITE_ROW {
            switch text(milestone, 0) {
            case "pending": initialCompletion = .inProgress
            case "complete": initialCompletion = .complete; initialCompletedAt = date(milestone, 1)
            default: initialCompletion = .unknown
            }
        }
        // A user's "Refresh entire inventory" also reconciles broadly; only event-driven passes are gaps.
        let gapRecheck = try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM inventory_reconcile WHERE generation_id=? AND reason<>'manual refresh')", [generation]) > 0
        let supportsCompletedToken = try connection.scalarInt("SELECT COUNT(*) FROM pragma_table_info('inventory_jobs') WHERE name='completed_token'") > 0
        let discovery = supportsCompletedToken ? "EXISTS(SELECT 1 FROM inventory_jobs d WHERE d.generation_id=g.id AND d.state IN ('pending','enumerating') AND d.completed_token=0 AND d.reason IS NOT '\(inventoryDeferredReason)')" : "0"
        // A deferred folder is retried on each update but is neither first-pass discovery nor active work.
        let deferred = try connection.scalarInt("SELECT COUNT(*) FROM inventory_jobs WHERE generation_id=? AND state IN ('pending','enumerating') AND reason=?", [generation, inventoryDeferredReason])
        var refresh: (fraction: Double, manual: Bool)?
        let frontier = try connection.statement("SELECT reason,last_node_id,end_node_id FROM inventory_reconcile WHERE generation_id=? ORDER BY created_at LIMIT 1", [generation])
        if sqlite3_step(frontier) == SQLITE_ROW, sqlite3_column_int64(frontier, 2) > 0 {
            refresh = (min(1, Double(sqlite3_column_int64(frontier, 1)) / Double(sqlite3_column_int64(frontier, 2))), text(frontier, 0) == "manual refresh")
        }
        sqlite3_finalize(frontier)
        let eventsUnavailable = try connection.scalarInt("SELECT COUNT(*) FROM inventory_generations WHERE id=? AND event_availability<>'available'", [generation]) > 0
        let statement = try connection.statement("SELECT g.state,g.root_path,g.reason,g.updated_at,s.total_nodes,s.completed_directories,s.pending_directories,s.stale_directories,s.unknown_directories,EXISTS(SELECT 1 FROM inventory_invalidations i WHERE i.generation_id=g.id),(SELECT COUNT(*) FROM inventory_jobs j WHERE j.generation_id=g.id AND j.state IN ('pending','enumerating')),EXISTS(SELECT 1 FROM inventory_reconcile r WHERE r.generation_id=g.id) OR EXISTS(SELECT 1 FROM inventory_prune_jobs p WHERE p.generation_id=g.id) OR EXISTS(SELECT 1 FROM inventory_tombstones t WHERE t.generation_id=g.id),g.created_at,\(discovery) FROM inventory_generations g JOIN inventory_stats s ON s.generation_id=g.id WHERE g.id=?", [generation])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
        let queued = sqlite3_column_int(statement, 9) != 0
        let jobs = sqlite3_column_int64(statement, 10), reconciliation = sqlite3_column_int(statement, 11) != 0
        let storedState = text(statement, 0) ?? "unknown"
        let state = queued || reconciliation ? "stale" : (jobs > 0 && ["complete", "partial"].contains(storedState) ? "building" : storedState), total = sqlite3_column_int64(statement, 4)
        let complete = sqlite3_column_int64(statement, 5), pending = sqlite3_column_int64(statement, 6), stale = sqlite3_column_int64(statement, 7), unknown = sqlite3_column_int64(statement, 8)
        let directoryTotal = complete + pending + stale + unknown
        let qualification: InventoryValueStatus = queued || reconciliation || stale > 0 ? .stale : (jobs > 0 || pending > 0 || unknown > 0 ? .lowerBound : (state == "complete" ? .complete : .unknown))
        return InventoryStatus(generation: generation, state: state, rootPath: text(statement, 1), totalNodes: total, completedDirectories: complete, pendingDirectories: pending, staleDirectories: stale, unknownDirectories: unknown, queuedDirectoryJobs: jobs, hasReconciliationWork: reconciliation, hasInitialDiscoveryWork: sqlite3_column_int(statement, 13) != 0, progress: qualification == .complete && jobs == 0 && directoryTotal > 0 ? 1 : nil, completeness: qualification, reason: reconciliation ? "Background reconciliation is pending; directory counters exclude unexpanded refresh work." : text(statement, 2), updatedAt: date(statement, 3), createdAt: date(statement, 12), initialCompletion: initialCompletion, initialCompletedAt: initialCompletedAt, hasEventGapRecheck: gapRecheck, deferredDirectories: deferred, eventHistoryUnavailable: eventsUnavailable, lowSpacePaused: text(statement, 2) == inventoryLowSpaceReason, refreshFraction: refresh?.fraction, refreshIsManual: refresh?.manual ?? false)
    }

    /// Root totals and coverage limits for the storage accounting summary (indexed queries only).
    public func accounting() throws -> InventoryAccounting {
        let connection = try InventoryReadConnection(databasePath)
        var result = InventoryAccounting()
        if try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='state')") > 0 {
            let statement = try connection.statement("SELECT value FROM state WHERE key='inventory_full_disk_access'")
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW { result.fullDiskAccess = text(statement, 0) }
        }
        guard let generation = try activeGeneration(connection) else { return result }
        let root = try connection.statement("SELECT COALESCE(total_allocated,0),COALESCE(total_logical,0),status FROM inventory_nodes WHERE generation_id=? AND parent_id IS NULL", [generation])
        defer { sqlite3_finalize(root) }
        if sqlite3_step(root) == SQLITE_ROW {
            result.indexedAllocated = sqlite3_column_int64(root, 0); result.indexedLogical = sqlite3_column_int64(root, 1); result.rootStatus = text(root, 2) ?? "unknown"
        }
        let limits = try connection.statement("SELECT kind,status,COALESCE(reason,''),COUNT(*) FROM inventory_nodes WHERE generation_id=? AND status IN ('unknown','excluded') GROUP BY kind,status,reason", [generation])
        defer { sqlite3_finalize(limits) }
        while sqlite3_step(limits) == SQLITE_ROW {
            let kind = text(limits, 0) ?? "", status = text(limits, 1) ?? "", reason = text(limits, 2) ?? "", count = sqlite3_column_int64(limits, 3)
            if status == "excluded" { result.excludedFolders += count }
            else if kind != "directory" { result.unreadableEntries += count }
            else if reason == "consent" || reason == "privacy" || reason == "metadata:privacy" { result.protectedFolders += count }
            else { result.unavailableFolders += count }
        }
        return result
    }

    /// The last 30 minutes of worker progress samples, oldest first; empty before any were recorded.
    public func progressSamples() throws -> [InventoryProgressSample] {
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection),
              try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='inventory_progress')") > 0 else { return [] }
        let statement = try connection.statement("SELECT sampled_at,completed_listings,queued_listings,nodes,allocated FROM inventory_progress WHERE generation_id=? AND sampled_at>=? ORDER BY sampled_at", [generation, Date().timeIntervalSince1970 - 1_800])
        defer { sqlite3_finalize(statement) }
        var samples = [InventoryProgressSample]()
        while sqlite3_step(statement) == SQLITE_ROW {
            samples.append(InventoryProgressSample(sampledAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)), completedListings: sqlite3_column_int64(statement, 1),
                                                   queuedListings: sqlite3_column_int64(statement, 2), nodes: sqlite3_column_int64(statement, 3), allocatedBytes: sqlite3_column_int64(statement, 4)))
        }
        return samples
    }

    /// Folders currently deferred because they kept changing during listing, for the status details.
    public func deferredDirectories(limit: Int = 20) throws -> [InventoryNode] {
        let connection = try InventoryReadConnection(databasePath)
        guard let generation = try activeGeneration(connection) else { return [] }
        // Driven by the few deferred jobs (primary-key lookups). A node-side generation filter let SQLite
        // scan every node of a 3-million-entry catalog, which hit the 0.25 s read deadline.
        return try rows(connection, sql: Self.baseSelect + " WHERE n.id IN (SELECT node_id FROM inventory_jobs WHERE generation_id=? AND state IN ('pending','enumerating') AND reason=?) ORDER BY n.id LIMIT ?", values: [generation, inventoryDeferredReason, bounded(limit)]).map(\.node)
    }

    private static let baseSelect = "SELECT n.id,n.parent_id,n.generation_id,n.name,n.kind,n.total_logical,n.total_allocated,n.direct_logical,n.direct_allocated,n.child_count,n.descendant_files,n.descendant_directories,n.status,n.reason,n.measured_at,o.device,o.inode,o.birth_ns,o.modified_at,(o.owner_node_id IS NOT NULL AND o.owner_node_id<>n.id) AS alias,(SELECT volume_uuid FROM inventory_generations g WHERE g.id=n.generation_id),o.logical,o.allocated,(SELECT j.state FROM inventory_jobs j WHERE j.node_id=n.id) FROM inventory_nodes n JOIN inventory_objects o ON o.id=n.object_id"

    private func bounded(_ limit: Int) -> Int { min(max(1, limit), maximumPageSize) }

    private func activeGeneration(_ connection: InventoryReadConnection) throws -> Int64? {
        guard try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='inventory_generations')") > 0 else { return nil }
        let value = try connection.scalarInt("SELECT id FROM inventory_generations WHERE active=1 ORDER BY id DESC LIMIT 1")
        return value == 0 ? nil : value
    }

    private struct Row { let node: InventoryNode; var sortAllocated: Int64? = nil }

    /// Durable work on the entry itself that makes its values stale: the per-entry half of `absolutePath`.
    private static let ownStaleColumn = "(EXISTS(SELECT 1 FROM inventory_reconcile r WHERE r.root_node_id=n.id) OR EXISTS(SELECT 1 FROM inventory_tombstones t WHERE t.node_id=n.id) OR EXISTS(SELECT 1 FROM inventory_prune_jobs p WHERE p.parent_node_id=n.id) OR (n.status='stale' AND EXISTS(SELECT 1 FROM inventory_jobs j WHERE j.node_id=n.id AND j.state IN ('pending','enumerating'))))"

    /// The path of `parentID` and whether its chain makes every child stale, with exactly the rules of
    /// `absolutePath` as seen from a child: durable work anywhere on the chain, the immediate listing of the
    /// parent (depth 1 from the child), or generation-wide gaps.
    private func childContext(_ connection: InventoryReadConnection, parentID: Int64, generation: Int64) throws -> (path: String, stale: Bool) {
        let statement = try connection.statement("WITH RECURSIVE chain(id,parent_id,name,status,depth) AS (SELECT id,parent_id,name,status,0 FROM inventory_nodes WHERE id=? UNION ALL SELECT n.id,n.parent_id,n.name,n.status,c.depth+1 FROM inventory_nodes n JOIN chain c ON c.parent_id=n.id WHERE c.depth<1023) SELECT name,EXISTS(SELECT 1 FROM inventory_reconcile r WHERE r.root_node_id=chain.id) OR EXISTS(SELECT 1 FROM inventory_tombstones t WHERE t.node_id=chain.id) OR EXISTS(SELECT 1 FROM inventory_prune_jobs p WHERE p.parent_node_id=chain.id) OR (depth=0 AND status='stale' AND EXISTS(SELECT 1 FROM inventory_jobs j WHERE j.node_id=chain.id AND j.state IN ('pending','enumerating'))) FROM chain ORDER BY depth DESC", [parentID])
        defer { sqlite3_finalize(statement) }
        var parts = [String](), stale = false, found = false
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
            found = true
            if let value = text(statement, 0), !value.isEmpty { parts.append(value) }
            if sqlite3_column_int(statement, 1) != 0 { stale = true }
        }
        guard found else { throw InventoryReaderError.query("This folder is no longer in the inventory") }
        let rootStatement = try connection.statement("SELECT root_path,event_availability,EXISTS(SELECT 1 FROM inventory_invalidations i WHERE i.generation_id=g.id) FROM inventory_generations g WHERE id=?", [generation])
        defer { sqlite3_finalize(rootStatement) }
        guard sqlite3_step(rootStatement) == SQLITE_ROW, let root = text(rootStatement, 0) else { throw InventoryReaderError.query("Inventory generation root is unavailable") }
        if text(rootStatement, 1) != "available" || sqlite3_column_int(rootStatement, 2) != 0 { stale = true }
        return (parts.isEmpty ? root : URL(fileURLWithPath: root).appendingPathComponent(parts.joined(separator: "/")).path, stale)
    }

    private func fetchOne(_ connection: InventoryReadConnection, sql: String, values: [Any?]) throws -> InventoryNode? {
        try rows(connection, sql: sql, values: values).first?.node
    }

    private func page(_ connection: InventoryReadConnection, sql: String, values: [Any?], limit: Int) throws -> InventoryPage {
        var values = try rows(connection, sql: sql, values: values).map(\.node)
        let more = values.count > limit
        if more { values.removeLast(values.count - limit) }
        return InventoryPage(items: values, hasMore: more)
    }

    private func rows(_ connection: InventoryReadConnection, sql: String, values: [Any?], context: (path: String, stale: Bool)? = nil) throws -> [Row] {
        let statement = try connection.statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var result = [Row]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
            let id = sqlite3_column_int64(statement, 0)
            let parent = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 1)
            let generation = sqlite3_column_int64(statement, 2)
            let name = text(statement, 3) ?? ""
            let kind = InventoryNodeKind(rawValue: text(statement, 4) ?? "other") ?? .other
            let rawStatus = text(statement, 12) ?? "unknown"
            var status: InventoryValueStatus
            switch rawStatus {
            case "complete": status = .complete
            case "stale": status = .stale
            case "pending", "enumerating", "partial": status = .lowerBound
            default: status = .unknown
            }
            let ancestry = try context.map { (path: $0.path + "/" + name, stale: $0.stale || sqlite3_column_int(statement, 24) != 0) }
                ?? absolutePath(connection, id: id, generation: generation)
            // Reconciliation can qualify a prior measurement as stale, but it must
            // not turn a never-measured inaccessible/excluded entry into a value.
            if ancestry.stale && status != .unknown { status = .stale }
            // Stale values are useful prior measurements when explicitly qualified.
            let known = status != .unknown && status != .stale
            let identity = InventoryIdentity(device: sqlite3_column_int64(statement, 15), inode: UInt64(bitPattern: sqlite3_column_int64(statement, 16)), birthNanoseconds: sqlite3_column_int64(statement, 17), volumeUUID: text(statement, 20))
            let node = InventoryNode(id: id, parentID: parent, identity: identity, path: ancestry.path, name: name, kind: kind, logicalBytes: known && sqlite3_column_type(statement, 5) != SQLITE_NULL ? sqlite3_column_int64(statement, 5) : nil, allocatedBytes: known && sqlite3_column_type(statement, 6) != SQLITE_NULL ? sqlite3_column_int64(statement, 6) : nil, previousLogicalBytes: status == .stale && sqlite3_column_type(statement, 5) != SQLITE_NULL ? sqlite3_column_int64(statement, 5) : nil, previousAllocatedBytes: status == .stale && sqlite3_column_type(statement, 6) != SQLITE_NULL ? sqlite3_column_int64(statement, 6) : nil, objectLogicalBytes: known && kind != .directory ? sqlite3_column_int64(statement, 21) : nil, objectAllocatedBytes: known && kind != .directory ? sqlite3_column_int64(statement, 22) : nil, directLogicalBytes: sqlite3_column_int64(statement, 7), directAllocatedBytes: sqlite3_column_int64(statement, 8), childCount: sqlite3_column_int64(statement, 9), descendantFiles: sqlite3_column_int64(statement, 10), descendantDirectories: sqlite3_column_int64(statement, 11), status: status, coverageState: status == .stale ? "stale" : rawStatus, listingState: text(statement, 23), statusReason: ancestry.stale && status == .stale ? "Filesystem history or ancestor reconciliation is incomplete; previously measured values are stale." : text(statement, 13), measuredAt: date(statement, 14), modifiedAt: date(statement, 18), generation: generation, isHardlinkAlias: sqlite3_column_int(statement, 19) != 0, historicalGrowthBytes: nil)
            result.append(Row(node: node, sortAllocated: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6)))
        }
    }

    private func absolutePath(_ connection: InventoryReadConnection, id: Int64, generation: Int64) throws -> (path: String, stale: Bool) {
        let statement = try connection.statement("WITH RECURSIVE chain(id,parent_id,name,status,depth) AS (SELECT id,parent_id,name,status,0 FROM inventory_nodes WHERE id=? UNION ALL SELECT n.id,n.parent_id,n.name,n.status,c.depth+1 FROM inventory_nodes n JOIN chain c ON c.parent_id=n.id WHERE c.depth<1023) SELECT name,status,EXISTS(SELECT 1 FROM inventory_reconcile r WHERE r.root_node_id=chain.id) OR EXISTS(SELECT 1 FROM inventory_tombstones t WHERE t.node_id=chain.id) OR EXISTS(SELECT 1 FROM inventory_prune_jobs p WHERE p.parent_node_id=chain.id) OR (depth<=1 AND status='stale' AND EXISTS(SELECT 1 FROM inventory_jobs j WHERE j.node_id=chain.id AND j.state IN ('pending','enumerating'))) FROM chain ORDER BY depth DESC", [id])
        defer { sqlite3_finalize(statement) }
        var parts = [String](), stale = false
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
            if let value = text(statement, 0), !value.isEmpty { parts.append(value) }
            // A stale aggregate can reflect a different child branch. Only durable
            // subtree work (or the immediate listing) invalidates this entry too.
            if sqlite3_column_int(statement, 2) != 0 { stale = true }
        }
        let rootStatement = try connection.statement("SELECT root_path,event_availability,EXISTS(SELECT 1 FROM inventory_invalidations i WHERE i.generation_id=g.id) FROM inventory_generations g WHERE id=?", [generation])
        defer { sqlite3_finalize(rootStatement) }
        guard sqlite3_step(rootStatement) == SQLITE_ROW, let root = text(rootStatement, 0) else { throw InventoryReaderError.query("Inventory generation root is unavailable") }
        if text(rootStatement, 1) != "available" || sqlite3_column_int(rootStatement, 2) != 0 { stale = true }
        return (parts.isEmpty ? root : URL(fileURLWithPath: root).appendingPathComponent(parts.joined(separator: "/")).path, stale)
    }

}

private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
}

private func date(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
}

// MARK: Change feed

extension InventoryReader {
    /// Most changed directories one `changes` read returns.
    public static let maximumChangeRead = 4_096
    /// Most nodes one `sizeSignals(nodeIDs:)` read accepts.
    public static let maximumSignalLookup = 512

    /// Directories whose committed catalog state changed after `cursor`, in one read snapshot: the latest
    /// sequence, the retention floor and the rows all describe the same moment, so no change committed
    /// between two reads is missed and none is returned twice. Bounded by `limit` (an index range scan).
    public func changes(since cursor: InventoryChangeCursor?, limit: Int = 2_048) throws -> InventoryChangeBatch {
        let connection = try InventoryReadConnection(databasePath)
        guard sqlite3_exec(connection.db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
        defer { sqlite3_exec(connection.db, "COMMIT", nil, nil, nil) }
        guard let clock = try changeClock(connection) else {
            return InventoryChangeBatch(available: false, journalID: nil, latestSequence: 0, generation: nil, generationStale: false, changes: [], next: nil, complete: true, mustResynchronize: true)
        }
        let generation = try activeGeneration(connection)
        let generationStale = try generation.map { try connection.scalarInt("SELECT event_availability<>'available' OR EXISTS(SELECT 1 FROM inventory_invalidations i WHERE i.generation_id=g.id) FROM inventory_generations g WHERE id=?", [$0]) != 0 } ?? false
        let latest = InventoryChangeCursor(journalID: clock.journal, sequence: clock.sequence)
        guard let cursor, cursor.journalID == clock.journal, cursor.sequence >= clock.retainedAfter, cursor.sequence <= clock.sequence else {
            return InventoryChangeBatch(available: true, journalID: clock.journal, latestSequence: clock.sequence, generation: generation, generationStale: generationStale, changes: [], next: latest, complete: true, mustResynchronize: true)
        }
        let wanted = min(max(8, limit), Self.maximumChangeRead)
        var changes = [InventoryDirectoryChange]()
        if let generation, cursor.sequence < clock.sequence {
            let statement = try connection.statement("SELECT directory_id,sequence,subtree_sequence>? FROM inventory_changed_directories WHERE sequence>? AND generation_id=? ORDER BY sequence LIMIT ?", [cursor.sequence, cursor.sequence, generation, wanted + 1])
            defer { sqlite3_finalize(statement) }
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
                changes.append(InventoryDirectoryChange(directoryID: sqlite3_column_int64(statement, 0), sequence: sqlite3_column_int64(statement, 1), subtree: sqlite3_column_int(statement, 2) != 0))
            }
        }
        let (kept, complete) = Self.truncated(changes, limit: wanted, sequence: \.sequence)
        let next = complete ? latest : kept.last.map { InventoryChangeCursor(journalID: clock.journal, sequence: $0.sequence) } ?? cursor
        return InventoryChangeBatch(available: true, journalID: clock.journal, latestSequence: clock.sequence, generation: generation, generationStale: generationStale, changes: kept, next: next, complete: complete, mustResynchronize: false)
    }

    /// Growth/reduction comparisons recorded after `cursor`, oldest first. Only comparisons of two settled
    /// measurements are returned; a remeasurement in progress is not. Bounded by `limit`.
    public func sizeSignals(since cursor: InventoryChangeCursor?, limit: Int = 1_024) throws -> InventorySignalBatch {
        let connection = try InventoryReadConnection(databasePath)
        guard sqlite3_exec(connection.db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
        defer { sqlite3_exec(connection.db, "COMMIT", nil, nil, nil) }
        guard let clock = try changeClock(connection) else {
            return InventorySignalBatch(available: false, latestSequence: 0, signals: [], next: nil, complete: true, mustResynchronize: true)
        }
        let latest = InventoryChangeCursor(journalID: clock.journal, sequence: clock.sequence)
        guard let cursor, cursor.journalID == clock.journal, cursor.sequence >= clock.signalsRetainedAfter, cursor.sequence <= clock.sequence else {
            return InventorySignalBatch(available: true, latestSequence: clock.sequence, signals: [], next: latest, complete: true, mustResynchronize: true)
        }
        let wanted = min(max(8, limit), Self.maximumChangeRead)
        var signals = [InventorySizeSignal]()
        if let generation = try activeGeneration(connection) {
            signals = try readSignals(connection, where: "sequence>? AND generation_id=? ORDER BY sequence LIMIT ?", [cursor.sequence, generation, wanted + 1])
        }
        let (kept, complete) = Self.truncated(signals, limit: wanted, sequence: \.sequence)
        let next = complete ? latest : kept.last.map { InventoryChangeCursor(journalID: clock.journal, sequence: $0.sequence) } ?? cursor
        return InventorySignalBatch(available: true, latestSequence: clock.sequence, signals: kept, next: next, complete: complete, mustResynchronize: false)
    }

    /// The latest comparison for each of `nodeIDs` that has one (at most `maximumSignalLookup` ids are read).
    public func sizeSignals(nodeIDs: [Int64]) throws -> [Int64: InventorySizeSignal] {
        let connection = try InventoryReadConnection(databasePath)
        guard try changeClock(connection) != nil, let generation = try activeGeneration(connection) else { return [:] }
        var result = [Int64: InventorySizeSignal]()
        let ids = Array(Set(nodeIDs).prefix(Self.maximumSignalLookup))
        for start in stride(from: 0, to: ids.count, by: 128) {
            let chunk = Array(ids[start..<min(ids.count, start + 128)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for signal in try readSignals(connection, where: "generation_id=? AND node_id IN (\(marks))", [generation] + chunk) { result[signal.nodeID] = signal }
        }
        return result
    }

    private struct ChangeClock { let journal: String; let sequence: Int64; let retainedAfter: Int64; let signalsRetainedAfter: Int64 }

    private func changeClock(_ connection: InventoryReadConnection) throws -> ChangeClock? {
        guard try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='inventory_change_clock')") > 0 else { return nil }
        let statement = try connection.statement("SELECT journal_id,sequence,retained_after,signals_retained_after FROM inventory_change_clock WHERE id=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let journal = text(statement, 0) else { return nil }
        return ChangeClock(journal: journal, sequence: sqlite3_column_int64(statement, 1), retainedAfter: sqlite3_column_int64(statement, 2), signalsRetainedAfter: sqlite3_column_int64(statement, 3))
    }

    private func readSignals(_ connection: InventoryReadConnection, where clause: String, _ values: [Any?]) throws -> [InventorySizeSignal] {
        let statement = try connection.statement("SELECT node_id,generation_id,sequence,previous_allocated,allocated,previous_measured_at,measured_at,previous_status,status FROM inventory_size_signals WHERE previous_allocated IS NOT NULL AND allocated IS NOT NULL AND " + clause, values)
        defer { sqlite3_finalize(statement) }
        var result = [InventorySizeSignal]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
            result.append(InventorySizeSignal(nodeID: sqlite3_column_int64(statement, 0), generation: sqlite3_column_int64(statement, 1), sequence: sqlite3_column_int64(statement, 2), previousAllocatedBytes: sqlite3_column_int64(statement, 3), allocatedBytes: sqlite3_column_int64(statement, 4), previousMeasuredAt: date(statement, 5), measuredAt: date(statement, 6), previousStatus: text(statement, 7) ?? "", status: text(statement, 8) ?? ""))
        }
    }

    /// Keeps at most `limit` rows, never splitting rows that share one sequence across two reads (a cursor
    /// continues strictly after a sequence). `complete` is false when rows were left for the next read.
    static func truncated<T>(_ rows: [T], limit: Int, sequence: KeyPath<T, Int64>) -> (kept: [T], complete: Bool) {
        guard rows.count > limit else { return (rows, true) }
        let boundary = rows[limit][keyPath: sequence]
        return (Array(rows.prefix(limit).filter { $0[keyPath: sequence] < boundary }), false)
    }
}

// MARK: Living Tree

extension InventoryReader {
    /// The longest a Living Tree read may hold its snapshot. Building stops adding folders at 60% of it, so the read
    /// ends well inside it; the worker's commits wait at most this long (its busy timeout is 30 s).
    public static let livingTreeDeadline: TimeInterval = 0.5

    /// The Living Tree of folder `rootID`, built from one read snapshot: every folder's drawn children and the exact
    /// totals of its grouped remainder describe the same committed moment. Bounded by `budget` (about 3,000
    /// elements and as many folder reads at most). `reveal` names an entry that must be drawn even when small (a
    /// selection made elsewhere); it is ignored unless it lies beneath the trunk.
    public func livingTree(rootID: Int64, budget: LivingTreeBudget = .standard, memory: LivingTreeMemory = LivingTreeMemory(), reveal: Int64? = nil) throws -> LivingTreeModel {
        let started = Date()
        let connection = try InventoryReadConnection(databasePath, deadline: Self.livingTreeDeadline)
        guard sqlite3_exec(connection.db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(connection.db))) }
        defer { sqlite3_exec(connection.db, "COMMIT", nil, nil, nil) }
        guard let generation = try activeGeneration(connection) else { throw InventoryReaderError.query("Inventory discovery has not started yet") }
        guard let root = try fetchOne(connection, sql: Self.baseSelect + " WHERE n.id=? AND n.generation_id=? LIMIT 1", values: [rootID, generation]) else {
            throw InventoryReaderError.query("This folder is no longer in the inventory")
        }
        var pinned = [InventoryNode]()
        if let reveal, reveal != rootID {
            let sql = "WITH RECURSIVE ancestors(id,parent_id,depth) AS (SELECT id,parent_id,0 FROM inventory_nodes WHERE id=? AND generation_id=? UNION ALL SELECT n.id,n.parent_id,a.depth+1 FROM inventory_nodes n JOIN ancestors a ON a.parent_id=n.id WHERE a.depth<1023) " + Self.baseSelect + " JOIN ancestors a ON a.id=n.id ORDER BY a.depth DESC"
            let chain = try rows(connection, sql: sql, values: [reveal, generation]).map(\.node)
            if let trunk = chain.firstIndex(where: { $0.id == rootID }) { pinned = Array(chain[(trunk + 1)...]) }
        }
        var slowest = 0.0, total = 0.0
        var model = try LivingTreeBuilder.build(root: root, pinned: pinned, budget: budget, memory: memory,
                                                shouldContinue: { Date().timeIntervalSince(started) < Self.livingTreeDeadline * 0.6 }) { parent, count in
            let spanStarted = Date()
            defer { let seconds = Date().timeIntervalSince(spanStarted); total += seconds; slowest = max(slowest, seconds) }
            let context = try childContext(connection, parentID: parent, generation: generation)
            var items = [InventoryNode](), cursor: InventoryChildCursor? = nil
            repeat {
                let page = try childPage(connection, generation: generation, context: context, parentID: parent, after: cursor, limit: min(count - items.count, maximumPageSize))
                items += page.items; cursor = page.next
            } while cursor != nil && items.count < count
            let remainder = cursor == nil ? nil : try remainder(connection, parentID: parent, skip: items.count)
            return (InventoryChildPage(items: items, next: cursor), remainder)
        }
        model.readSeconds = total; model.slowestRead = slowest; model.snapshotSeconds = Date().timeIntervalSince(started)
        if let clock = try changeClock(connection) { model.journalCursor = InventoryChangeCursor(journalID: clock.journal, sequence: clock.sequence) }
        model.generationStale = try connection.scalarInt("SELECT event_availability<>'available' OR EXISTS(SELECT 1 FROM inventory_invalidations i WHERE i.generation_id=g.id) FROM inventory_generations g WHERE id=?", [generation]) != 0
        return model
    }
}
