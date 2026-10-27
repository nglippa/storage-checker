import Foundation
import Darwin
import SQLite3

private let inventoryTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let inventoryStatsUpdateTriggerGuard = "WHEN OLD.kind<>NEW.kind OR OLD.status<>NEW.status"
private let inventoryStatsUpdateTriggerSQL = """
CREATE TRIGGER IF NOT EXISTS inventory_nodes_stats_update AFTER UPDATE OF kind,status ON inventory_nodes
WHEN OLD.kind<>NEW.kind OR OLD.status<>NEW.status BEGIN
  UPDATE inventory_stats SET
    completed_directories=completed_directories-CASE WHEN OLD.kind='directory' AND OLD.status='complete' THEN 1 ELSE 0 END+CASE WHEN NEW.kind='directory' AND NEW.status='complete' THEN 1 ELSE 0 END,
    pending_directories=pending_directories-CASE WHEN OLD.kind='directory' AND OLD.status IN ('pending','enumerating') THEN 1 ELSE 0 END+CASE WHEN NEW.kind='directory' AND NEW.status IN ('pending','enumerating') THEN 1 ELSE 0 END,
    stale_directories=stale_directories-CASE WHEN OLD.kind='directory' AND OLD.status='stale' THEN 1 ELSE 0 END+CASE WHEN NEW.kind='directory' AND NEW.status='stale' THEN 1 ELSE 0 END,
    unknown_directories=unknown_directories-CASE WHEN OLD.kind='directory' AND OLD.status IN ('unknown','inaccessible','excluded','partial') THEN 1 ELSE 0 END+CASE WHEN NEW.kind='directory' AND NEW.status IN ('unknown','inaccessible','excluded','partial') THEN 1 ELSE 0 END
  WHERE generation_id=NEW.generation_id;
END
"""

enum InventoryEngineError: Error, CustomStringConvertible {
    case sqlite(String)
    case invalidRoot(String)

    var description: String {
        switch self {
        case .sqlite(let message), .invalidRoot(let message): return message
        }
    }
}

struct InventoryRunOptions {
    var serviceRequests = false
    var maxDuration: TimeInterval = 25
    var batchSize = 256
    var stopAfterEntries: Int? = nil
    var cancelFile: String? = nil
    var pause: TimeInterval = 0

    init(maxDuration: TimeInterval = 25, batchSize: Int = 256, stopAfterEntries: Int? = nil, cancelFile: String? = nil, pause: TimeInterval = 0, serviceRequests: Bool = false) {
        self.maxDuration = max(0, maxDuration)
        self.batchSize = min(max(1, batchSize), 256)
        self.stopAfterEntries = stopAfterEntries
        self.cancelFile = cancelFile
        self.pause = max(0, pause)
        self.serviceRequests = serviceRequests
    }
}

/// Milliseconds the inventory worker waits for another process's lock before reporting it busy.
let inventoryWorkerBusyTimeout: Int32 = 30_000
/// Changed-during-listing restarts of one directory before a run stops retrying it.
let inventoryChangedRetryLimit = 3
/// Listing sequences reserved per commit; one durable commit per listing start dominated scan time.
let inventorySequenceBlock: Int64 = 64
/// Completed sibling listings buffered into one commit (each commit costs two fsyncs in rollback-
/// journal mode). The 0.1 s age flush still bounds how long results wait to become visible.
let inventoryGroupedListingLimit = 32, inventoryGroupedEntryLimit = 2_048
// `inventoryDeferredReason` (SourcesShared) is both the run reason when only continuously changing
// directories remain, so the worker idles instead of spinning, and the durable reason on each
// deferred job until its next listing attempt clears it.

struct InventoryRunResult {
    let outcome: String
    let generation: Int64?
    let entries: Int
    let directories: Int
    let pending: Int64
    let reason: String?
    /// The run stopped at its time or entry limit while listings it could have run were still queued.
    /// Only this asks launchd for another slice; queued event work, deferred folders and paused
    /// runs wait for the next scheduled wake instead.
    var runnableWorkRemains = false
}

struct InventoryEventCursor {
    let eventID: UInt64
    let deviceIdentifier: String
    let acknowledgedAt: Double
    var bootSession = ""
    var awakeAt: Double = 0

    /// Age checked against the replay window. fseventsd trims history by the volume of events
    /// recorded, and almost none are recorded while the Mac sleeps, so within one boot session
    /// only awake time counts (CLOCK_UPTIME_RAW stops during sleep; dark wakes still count).
    /// After a restart, or for a cursor written before awake time was stored, wall time is used.
    func age(now: Double = Date().timeIntervalSince1970, clock: InventoryAwakeClock = .current) -> TimeInterval {
        if !bootSession.isEmpty, bootSession == clock.bootSession, awakeAt <= clock.uptime { return clock.uptime - awakeAt }
        return now - acknowledgedAt
    }
}

struct InventoryAwakeClock {
    let bootSession: String
    let uptime: Double

    static var current: InventoryAwakeClock {
        #if INVENTORY_TESTS
        if let inventoryAwakeClockOverride { return inventoryAwakeClockOverride }
        #endif
        var size = 0, session = ""
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [UInt8](repeating: 0, count: size)
            if sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 { session = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return InventoryAwakeClock(bootSession: session, uptime: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000)
    }
}
#if INVENTORY_TESTS
var inventoryAwakeClockOverride: InventoryAwakeClock?
#endif

private final class InventoryConnection {
    var db: OpaquePointer?
    private var statements = [String: OpaquePointer]()
    /// Aggregate recompute starts deferred to the end of the current transaction (see `coalescingAggregates`).
    var collectedAggregates: [Int64: Double]?
    /// Seconds the last re-sum of a folder took, kept only for slow (very wide) folders.
    var slowRecomputeSeconds = [Int64: Double]()
    /// Listing sequences reserved by this worker connection (see `beginInventoryListing`).
    var reservedSequences: (next: Int64, last: Int64, generation: Int64)?
    private let profile = InventoryProfile.current
    private var lastWriterYield = DispatchTime.now().uptimeNanoseconds

    init(_ path: String, create: Bool = true) throws {
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            throw InventoryEngineError.sqlite("Cannot open inventory database: \(detail)")
        }
        // The worker waits for the scheduled check's short commits instead of abandoning a slice
        // (D9) or failing at startup when launchd starts every agent at once (D10).
        sqlite3_busy_timeout(db, inventoryWorkerBusyTimeout)
        try exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;")
    }

    deinit { for statement in statements.values { sqlite3_finalize(statement) }; sqlite3_close(db) }

    func exec(_ sql: String) throws {
        let began = profile == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        defer { if let profile { profile.nanoseconds["sqlite_exec", default: 0] += DispatchTime.now().uptimeNanoseconds - began } }
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw InventoryEngineError.sqlite(message(code)) }
    }

    func statement(_ sql: String, _ values: [Any?] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        let code: Int32
        if let cached = statements[sql] { result = cached; sqlite3_reset(cached); sqlite3_clear_bindings(cached); code = SQLITE_OK }
        else {
            code = sqlite3_prepare_v2(db, sql, -1, &result, nil)
            if let result, code == SQLITE_OK {
                if statements.count >= 64, let key = statements.keys.first, let old = statements.removeValue(forKey: key) { sqlite3_finalize(old) }
                statements[sql] = result
            }
        }
        guard code == SQLITE_OK, let result else { throw InventoryEngineError.sqlite(message(code)) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as Int64: sqlite3_bind_int64(result, index, value)
            case let value as UInt64: sqlite3_bind_int64(result, index, Int64(bitPattern: value))
            case let value as Int: sqlite3_bind_int64(result, index, Int64(value))
            case let value as Double: sqlite3_bind_double(result, index, value)
            case let value as String: sqlite3_bind_text(result, index, value, -1, inventoryTransient)
            default: sqlite3_bind_null(result, index)
            }
        }
        return result
    }

    @discardableResult
    func write(_ sql: String, _ values: [Any?] = []) throws -> Int64 {
        let began = profile == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        profile?.add("sql_write_statements")
        defer { if let profile { profile.nanoseconds["sqlite_statements", default: 0] += DispatchTime.now().uptimeNanoseconds - began } }
        let statement = try self.statement(sql, values)
        defer { sqlite3_reset(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw InventoryEngineError.sqlite(message(code)) }
        return sqlite3_last_insert_rowid(db)
    }

    func rows(_ sql: String, _ values: [Any?] = []) throws -> [[String: String]] {
        let began = profile == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        profile?.add("sql_read_statements")
        defer { if let profile { profile.nanoseconds["sqlite_statements", default: 0] += DispatchTime.now().uptimeNanoseconds - began } }
        let statement = try self.statement(sql, values)
        defer { sqlite3_reset(statement) }
        var output = [[String: String]]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return output }
            guard code == SQLITE_ROW else { throw InventoryEngineError.sqlite(message(code)) }
            var row = [String: String]()
            for column in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, column) {
                    row[String(cString: sqlite3_column_name(statement, column))] = String(cString: value)
                }
            }
            output.append(row)
        }
    }

    /// Rows changed by the most recent write on this connection.
    var changes: Int32 { sqlite3_changes(db) }
    func scalar(_ sql: String, _ values: [Any?] = []) throws -> Int64 {
        Int64(try rows(sql, values).first?.values.first ?? "") ?? 0
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        // Give waiting monitor writes a regular unlocked window. Background timer
        // coalescing can turn even a 2 ms sleep into ~50-90 ms, so frequent yields dominate
        // background indexing (19% of a measured first pass at 200 ms). Transactions remain
        // bounded; yield once per second at a commit boundary, outside the writer lock, which
        // stays far inside the monitor's 10 s busy timeout.
        defer {
            if DispatchTime.now().uptimeNanoseconds - lastWriterYield >= 1_000_000_000 {
                let began = DispatchTime.now().uptimeNanoseconds
                usleep(2_000)
                profile?.nanoseconds["scheduling_delay", default: 0] += DispatchTime.now().uptimeNanoseconds - began
                lastWriterYield = DispatchTime.now().uptimeNanoseconds
            }
        }
        let lockStart = profile == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        do { try exec("BEGIN IMMEDIATE") }
        catch { if let profile { profile.add("lock_failures"); profile.nanoseconds["lock_acquisition", default: 0] += DispatchTime.now().uptimeNanoseconds - lockStart }; throw error }
        if let profile { profile.nanoseconds["lock_acquisition", default: 0] += DispatchTime.now().uptimeNanoseconds - lockStart }
        let committedCounts = profile?.counts
        do {
            let value = try body()
            let commitStart = profile == nil ? 0 : DispatchTime.now().uptimeNanoseconds
            try exec("COMMIT")
            if let profile { profile.nanoseconds["transaction_commit", default: 0] += DispatchTime.now().uptimeNanoseconds - commitStart; profile.add("transactions_committed"); profile.observedCommit() }
            return value
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            if let committedCounts, let profile {
                for key in ["new_entries_committed", "entries_remeasured_committed", "entries_pruned_committed", "listings_completed", "jobs_skipped_satisfied"] { profile.counts[key] = committedCounts[key] }
                profile.add("transactions_rolled_back")
            }
            throw error
        }
    }

    private func message(_ code: Int32) -> String {
        let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        return (code == SQLITE_BUSY || code == SQLITE_LOCKED ? "Inventory database busy: " : "SQLite inventory error: ") + detail
    }
}

// Deliberately invoked by the inventory worker. Database.init does not migrate or touch these
// tables during ordinary capacity readings.
func initializeInventorySchema(databasePath: String) throws {
    let connection = try InventoryConnection(databasePath)
    try connection.exec("""
        CREATE TABLE IF NOT EXISTS inventory_generations (
          id INTEGER PRIMARY KEY, root_path TEXT NOT NULL, root_device INTEGER NOT NULL,
          root_inode INTEGER NOT NULL, root_birth_ns INTEGER NOT NULL, state TEXT NOT NULL,
          reason TEXT, operational_path TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL, active INTEGER NOT NULL DEFAULT 0
          ,volume_uuid TEXT,
          event_availability TEXT NOT NULL DEFAULT 'available', event_reason TEXT,
          inventory_sequence INTEGER NOT NULL DEFAULT 0, cleanup_sequence INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX IF NOT EXISTS inventory_one_active ON inventory_generations(active) WHERE active=1;
        CREATE TABLE IF NOT EXISTS inventory_objects (
          id INTEGER PRIMARY KEY, device INTEGER NOT NULL, inode INTEGER NOT NULL, birth_ns INTEGER NOT NULL,
          kind TEXT NOT NULL, logical INTEGER NOT NULL, allocated INTEGER NOT NULL, link_count INTEGER NOT NULL,
          modified_at REAL NOT NULL, changed_ns INTEGER NOT NULL, owner_node_id INTEGER,
          UNIQUE(device,inode,birth_ns)
        );
        CREATE TABLE IF NOT EXISTS inventory_nodes (
          id INTEGER PRIMARY KEY, generation_id INTEGER NOT NULL REFERENCES inventory_generations(id) ON DELETE CASCADE,
          parent_id INTEGER REFERENCES inventory_nodes(id) ON DELETE CASCADE, object_id INTEGER NOT NULL REFERENCES inventory_objects(id),
          name TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, reason TEXT,
          direct_logical INTEGER NOT NULL DEFAULT 0, direct_allocated INTEGER NOT NULL DEFAULT 0,
          total_logical INTEGER, total_allocated INTEGER, child_count INTEGER NOT NULL DEFAULT 0,
          descendant_files INTEGER NOT NULL DEFAULT 0, descendant_directories INTEGER NOT NULL DEFAULT 0,
          descendant_entries INTEGER NOT NULL DEFAULT 0,
          measured_at REAL, seen_token INTEGER NOT NULL DEFAULT 0,
          UNIQUE(generation_id,parent_id,name)
        );
        CREATE UNIQUE INDEX IF NOT EXISTS inventory_root_unique ON inventory_nodes(generation_id) WHERE parent_id IS NULL;
        CREATE INDEX IF NOT EXISTS inventory_nodes_parent ON inventory_nodes(generation_id,parent_id,name COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS inventory_nodes_object ON inventory_nodes(object_id);
        CREATE INDEX IF NOT EXISTS inventory_nodes_children ON inventory_nodes(parent_id,name COLLATE NOCASE,id);
        CREATE INDEX IF NOT EXISTS inventory_nodes_children_allocated ON inventory_nodes(parent_id,total_allocated DESC,name COLLATE NOCASE,id);
        CREATE INDEX IF NOT EXISTS inventory_nodes_largest_all ON inventory_nodes(generation_id,total_allocated DESC,id);
        CREATE INDEX IF NOT EXISTS inventory_nodes_largest_file ON inventory_nodes(generation_id,kind,total_allocated DESC) WHERE kind='file';
        CREATE INDEX IF NOT EXISTS inventory_nodes_largest_directory ON inventory_nodes(generation_id,kind,total_allocated DESC) WHERE kind='directory';
        CREATE INDEX IF NOT EXISTS inventory_nodes_name ON inventory_nodes(generation_id,name COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS inventory_nodes_status ON inventory_nodes(generation_id,kind,status);
        CREATE INDEX IF NOT EXISTS inventory_nodes_kind_id ON inventory_nodes(generation_id,kind,id);
        CREATE TABLE IF NOT EXISTS inventory_stats (
          generation_id INTEGER PRIMARY KEY REFERENCES inventory_generations(id) ON DELETE CASCADE,
          total_nodes INTEGER NOT NULL DEFAULT 0, completed_directories INTEGER NOT NULL DEFAULT 0,
          pending_directories INTEGER NOT NULL DEFAULT 0, stale_directories INTEGER NOT NULL DEFAULT 0,
          unknown_directories INTEGER NOT NULL DEFAULT 0
        );
        CREATE TRIGGER IF NOT EXISTS inventory_nodes_stats_insert AFTER INSERT ON inventory_nodes BEGIN
          UPDATE inventory_stats SET total_nodes=total_nodes+1,
            completed_directories=completed_directories+CASE WHEN NEW.kind='directory' AND NEW.status='complete' THEN 1 ELSE 0 END,
            pending_directories=pending_directories+CASE WHEN NEW.kind='directory' AND NEW.status IN ('pending','enumerating') THEN 1 ELSE 0 END,
            stale_directories=stale_directories+CASE WHEN NEW.kind='directory' AND NEW.status='stale' THEN 1 ELSE 0 END,
            unknown_directories=unknown_directories+CASE WHEN NEW.kind='directory' AND NEW.status IN ('unknown','inaccessible','excluded','partial') THEN 1 ELSE 0 END
          WHERE generation_id=NEW.generation_id;
        END;
        CREATE TRIGGER IF NOT EXISTS inventory_nodes_stats_delete AFTER DELETE ON inventory_nodes BEGIN
          UPDATE inventory_stats SET total_nodes=MAX(0,total_nodes-1),
            completed_directories=MAX(0,completed_directories-CASE WHEN OLD.kind='directory' AND OLD.status='complete' THEN 1 ELSE 0 END),
            pending_directories=MAX(0,pending_directories-CASE WHEN OLD.kind='directory' AND OLD.status IN ('pending','enumerating') THEN 1 ELSE 0 END),
            stale_directories=MAX(0,stale_directories-CASE WHEN OLD.kind='directory' AND OLD.status='stale' THEN 1 ELSE 0 END),
            unknown_directories=MAX(0,unknown_directories-CASE WHEN OLD.kind='directory' AND OLD.status IN ('unknown','inaccessible','excluded','partial') THEN 1 ELSE 0 END)
          WHERE generation_id=OLD.generation_id;
        END;
        \(inventoryStatsUpdateTriggerSQL);
        CREATE TABLE IF NOT EXISTS inventory_jobs (
          node_id INTEGER PRIMARY KEY REFERENCES inventory_nodes(id) ON DELETE CASCADE,
          generation_id INTEGER NOT NULL, state TEXT NOT NULL, cookie INTEGER NOT NULL DEFAULT 0,
          listing_token INTEGER NOT NULL DEFAULT 0, snapshot_device INTEGER, snapshot_inode INTEGER,
          snapshot_birth_ns INTEGER, snapshot_mtime_ns INTEGER, snapshot_ctime_ns INTEGER,
          attempts INTEGER NOT NULL DEFAULT 0, reason TEXT, updated_at REAL NOT NULL,
          listing_sequence INTEGER NOT NULL DEFAULT 0, completed_sequence INTEGER NOT NULL DEFAULT 0,
          completed_token INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS inventory_jobs_pending ON inventory_jobs(generation_id,state,updated_at,node_id);
        CREATE TABLE IF NOT EXISTS inventory_focus (
          generation_id INTEGER NOT NULL REFERENCES inventory_generations(id) ON DELETE CASCADE,
          path TEXT NOT NULL, requested_at REAL NOT NULL, expires_at REAL NOT NULL,
          source TEXT NOT NULL DEFAULT 'interactive', PRIMARY KEY(generation_id,path)
        );
        CREATE TABLE IF NOT EXISTS inventory_invalidations (
          id INTEGER PRIMARY KEY, generation_id INTEGER, absolute_path TEXT, reason TEXT NOT NULL,
          gap INTEGER NOT NULL DEFAULT 0, event_id INTEGER, created_at REAL NOT NULL,
          request_sequence INTEGER NOT NULL DEFAULT 0, end_node_id INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS inventory_progress (
          generation_id INTEGER NOT NULL, sampled_at REAL NOT NULL, completed_listings INTEGER NOT NULL,
          queued_listings INTEGER NOT NULL, nodes INTEGER NOT NULL, allocated INTEGER NOT NULL,
          PRIMARY KEY(generation_id,sampled_at)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS inventory_event_cursor (
          device TEXT PRIMARY KEY, event_id INTEGER NOT NULL, acknowledged_at REAL NOT NULL,
          boot_session TEXT NOT NULL DEFAULT '', awake_at REAL NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS inventory_reconcile (
          root_node_id INTEGER PRIMARY KEY REFERENCES inventory_nodes(id) ON DELETE CASCADE,
          generation_id INTEGER NOT NULL, reason TEXT NOT NULL, created_at REAL NOT NULL,
          last_node_id INTEGER NOT NULL DEFAULT 0, end_node_id INTEGER NOT NULL DEFAULT 0,
          request_sequence INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS inventory_tombstones (
          node_id INTEGER PRIMARY KEY REFERENCES inventory_nodes(id) ON DELETE CASCADE,
          generation_id INTEGER NOT NULL, created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS inventory_tombstones_generation ON inventory_tombstones(generation_id,node_id);
        CREATE TABLE IF NOT EXISTS inventory_prune_jobs (
          parent_node_id INTEGER PRIMARY KEY REFERENCES inventory_nodes(id) ON DELETE CASCADE,
          generation_id INTEGER NOT NULL, seen_token INTEGER NOT NULL, last_node_id INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL, cleanup_epoch INTEGER NOT NULL DEFAULT 0,
          authority_kind TEXT NOT NULL DEFAULT 'legacy', authority_object_id INTEGER,
          authority_sequence INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS inventory_tombstone_claims (
          cleanup_epoch INTEGER NOT NULL, node_id INTEGER NOT NULL REFERENCES inventory_nodes(id) ON DELETE CASCADE,
          root_node_id INTEGER NOT NULL,
          parent_node_id INTEGER NOT NULL, generation_id INTEGER NOT NULL, created_at REAL NOT NULL,
          PRIMARY KEY(cleanup_epoch,node_id)
        );
        CREATE INDEX IF NOT EXISTS inventory_tombstone_claims_generation ON inventory_tombstone_claims(generation_id,cleanup_epoch,node_id);
        CREATE INDEX IF NOT EXISTS inventory_tombstone_claims_node ON inventory_tombstone_claims(node_id);
        CREATE INDEX IF NOT EXISTS inventory_tombstone_claims_root ON inventory_tombstone_claims(root_node_id,cleanup_epoch);
        """)
    let statsTrigger = try connection.rows("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='inventory_nodes_stats_update'").first?["sql"] ?? ""
    if !statsTrigger.contains(inventoryStatsUpdateTriggerGuard) {
        // CREATE TRIGGER IF NOT EXISTS cannot update an installed definition. Replace
        // the legacy no-op-writing trigger once, atomically, without touching counters.
        try connection.transaction {
            try connection.exec("DROP TRIGGER IF EXISTS inventory_nodes_stats_update")
            try connection.exec(inventoryStatsUpdateTriggerSQL)
        }
    }
    if try !connection.rows("PRAGMA table_info(inventory_reconcile)").contains(where: { $0["name"] == "last_node_id" }) {
        try connection.exec("ALTER TABLE inventory_reconcile ADD COLUMN last_node_id INTEGER NOT NULL DEFAULT 0")
    }
    if try !connection.rows("PRAGMA table_info(inventory_reconcile)").contains(where: { $0["name"] == "end_node_id" }) {
        try connection.exec("ALTER TABLE inventory_reconcile ADD COLUMN end_node_id INTEGER NOT NULL DEFAULT 0")
        // An interrupted legacy pass has no historical catalog boundary. Capture the
        // current maximum conservatively so it remains complete but stops chasing nodes
        // discovered after this migration.
        try connection.exec("UPDATE inventory_reconcile SET end_node_id=COALESCE((SELECT MAX(id) FROM inventory_nodes),0) WHERE end_node_id=0")
    }
    if try !connection.rows("PRAGMA table_info(inventory_nodes)").contains(where: { $0["name"] == "descendant_entries" }) {
        try connection.exec("ALTER TABLE inventory_nodes ADD COLUMN descendant_entries INTEGER NOT NULL DEFAULT 0")
    }
    if try !connection.rows("PRAGMA table_info(inventory_generations)").contains(where: { $0["name"] == "volume_uuid" }) {
        try connection.exec("ALTER TABLE inventory_generations ADD COLUMN volume_uuid TEXT")
    }
    if try !connection.rows("PRAGMA table_info(inventory_generations)").contains(where: { $0["name"] == "event_availability" }) {
        try connection.exec("ALTER TABLE inventory_generations ADD COLUMN event_availability TEXT NOT NULL DEFAULT 'available'")
    }
    if try !connection.rows("PRAGMA table_info(inventory_generations)").contains(where: { $0["name"] == "event_reason" }) {
        try connection.exec("ALTER TABLE inventory_generations ADD COLUMN event_reason TEXT")
    }
    // Forward-only lifecycle columns are added atomically. Defaults deliberately do not
    // certify legacy listings or cleanup markers; they are adopted only after local validation.
    let lifecycleColumns: [(String,String,String)] = [
        ("inventory_generations","inventory_sequence","INTEGER NOT NULL DEFAULT 0"),
        ("inventory_generations","cleanup_sequence","INTEGER NOT NULL DEFAULT 0"),
        ("inventory_jobs","listing_sequence","INTEGER NOT NULL DEFAULT 0"),
        ("inventory_jobs","completed_sequence","INTEGER NOT NULL DEFAULT 0"),
        ("inventory_jobs","completed_token","INTEGER NOT NULL DEFAULT 0"),
        ("inventory_invalidations","request_sequence","INTEGER NOT NULL DEFAULT 0"),
        ("inventory_invalidations","end_node_id","INTEGER NOT NULL DEFAULT 0"),
        ("inventory_reconcile","request_sequence","INTEGER NOT NULL DEFAULT 0"),
        ("inventory_prune_jobs","cleanup_epoch","INTEGER NOT NULL DEFAULT 0"),
        ("inventory_prune_jobs","authority_kind","TEXT NOT NULL DEFAULT 'legacy'"),
        ("inventory_prune_jobs","authority_object_id","INTEGER"),
        ("inventory_prune_jobs","authority_sequence","INTEGER NOT NULL DEFAULT 0"),
        // First-pass milestone. Generations that predate it are 'unknown', never 'pending':
        // their history cannot prove whether a first pass ever finished.
        ("inventory_generations","initial_completion","TEXT NOT NULL DEFAULT 'unknown'"),
        ("inventory_generations","initial_completed_at","REAL"),
        // Awake-time cursor age. An empty boot session keeps the wall-clock rule for old cursors.
        ("inventory_event_cursor","boot_session","TEXT NOT NULL DEFAULT ''"),
        ("inventory_event_cursor","awake_at","REAL NOT NULL DEFAULT 0")
    ]
    var missing = [(String,String,String)]()
    for item in lifecycleColumns where try !connection.rows("PRAGMA table_info(\(item.0))").contains(where: { $0["name"] == item.1 }) { missing.append(item) }
    if !missing.isEmpty {
        try connection.transaction {
            for (table,column,definition) in missing { try connection.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)") }
            try connection.exec("""
                CREATE TABLE IF NOT EXISTS inventory_tombstone_claims (
                  cleanup_epoch INTEGER NOT NULL, node_id INTEGER NOT NULL REFERENCES inventory_nodes(id) ON DELETE CASCADE,
                  root_node_id INTEGER NOT NULL,
                  parent_node_id INTEGER NOT NULL, generation_id INTEGER NOT NULL, created_at REAL NOT NULL,
                  PRIMARY KEY(cleanup_epoch,node_id)
                );
                CREATE INDEX IF NOT EXISTS inventory_tombstone_claims_generation ON inventory_tombstone_claims(generation_id,cleanup_epoch,node_id);
                CREATE INDEX IF NOT EXISTS inventory_tombstone_claims_node ON inventory_tombstone_claims(node_id);
                CREATE INDEX IF NOT EXISTS inventory_tombstone_claims_root ON inventory_tombstone_claims(root_node_id,cleanup_epoch);
                """)
        }
    }
    // Keeps the never-listed-directory test O(1) even behind a large refresh backlog.
    try connection.exec("CREATE INDEX IF NOT EXISTS inventory_jobs_first_listing ON inventory_jobs(generation_id) WHERE completed_token=0 AND state IN ('pending','enumerating')")
    // A retained request predates this migration, but its legacy listings cannot
    // prove freshness. Give that work a conservative boundary now; only listings
    // begun after adoption may satisfy it. Never rewrite legacy completions.
    try connection.transaction {
        if try connection.scalar("SELECT (SELECT COUNT(*) FROM inventory_reconcile WHERE request_sequence=0)+(SELECT COUNT(*) FROM inventory_invalidations WHERE request_sequence=0)") > 0 {
            try adoptLegacyInventoryRequests(connection)
        }
    }
    try installInventoryChangeJournal(connection)
    _ = chmod(databasePath, 0o600)
}

/// Adds the change journal to an existing catalog: new tables and triggers only, no rewrite of
/// existing rows. Readers start without a cursor and resynchronize their visible branches once.
/// Triggers are (re)installed atomically whenever the installed journal version differs.
private func installInventoryChangeJournal(_ connection: InventoryConnection) throws {
    #if INVENTORY_TESTS
    if inventoryChangeJournalDisabledForBenchmark { return }
    #endif
    let installed = try connection.scalar("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='inventory_change_clock')") > 0
        ? try connection.scalar("SELECT COALESCE((SELECT version FROM inventory_change_clock WHERE id=1),0)") : 0
    let names = inventoryChangeJournalTriggers.map { "'\($0.0)'" }.joined(separator: ",")
    let triggers = try connection.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN (\(names))")
    guard installed != inventoryChangeJournalVersion || triggers != Int64(inventoryChangeJournalTriggers.count) else {
        try connection.exec(inventorySignalGenerationSyncSQL); return
    }
    try connection.transaction {
        try connection.exec(inventoryChangeJournalSchemaSQL)
        try connection.write("INSERT OR IGNORE INTO inventory_change_clock(id,journal_id,version,created_at) VALUES (1,?,?,?)", [UUID().uuidString, inventoryChangeJournalVersion, Date().timeIntervalSince1970])
        for (name, definition) in inventoryChangeJournalTriggers {
            try connection.exec("DROP TRIGGER IF EXISTS \(name)")
            try connection.exec(definition)
        }
        try connection.write("UPDATE inventory_change_clock SET version=? WHERE id=1", [inventoryChangeJournalVersion])
        try connection.exec(inventorySignalGenerationSyncSQL)
    }
}

/// Bounds the journal. The oldest directories (and size signals) beyond the retention limits are
/// deleted, a bounded batch per transaction, and the floor is raised to the newest deleted
/// sequence, so a reader whose cursor predates it learns that it must resynchronize. Pruning starts
/// only a quarter above the limit, so a busy catalog does not prune on every call.
@discardableResult
private func pruneInventoryChangeJournal(_ connection: InventoryConnection, retention: InventoryChangeJournalRetention = InventoryChangeJournalRetention()) throws -> Int64 {
    guard try connection.scalar("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='inventory_change_clock')") > 0 else { return 0 }
    var removed: Int64 = 0
    for (table, floor, keep) in [("inventory_changed_directories", "retained_after", retention.directories), ("inventory_size_signals", "signals_retained_after", retention.signals)] {
        var excess = try connection.scalar("SELECT COUNT(*) FROM \(table)") - keep
        guard excess > keep / 4 else { continue }
        while excess > 0 {
            let step = min(excess, max(1, retention.batch))
            try connection.transaction {
                let cutoff = try connection.scalar("SELECT sequence FROM \(table) ORDER BY sequence LIMIT 1 OFFSET ?", [step - 1])
                try connection.write("DELETE FROM \(table) WHERE sequence<=?", [cutoff])
                removed += Int64(connection.changes)
                try connection.write("UPDATE inventory_change_clock SET \(floor)=MAX(\(floor),?) WHERE id=1", [cutoff])
            }
            excess -= step
        }
    }
    InventoryProfile.current?.add("journal_rows_pruned", removed)
    return removed
}

#if INVENTORY_TESTS
/// Benchmarks only: measure the worker without the journal (A/B write amplification).
var inventoryChangeJournalDisabledForBenchmark = false

func inventoryPruneChangeJournalForTesting(databasePath: String, retention: InventoryChangeJournalRetention) throws -> Int64 {
    try pruneInventoryChangeJournal(try InventoryConnection(databasePath, create: false), retention: retention)
}
#endif

private func adoptLegacyInventoryRequests(_ connection: InventoryConnection) throws {
            try connection.write("UPDATE inventory_generations SET inventory_sequence=inventory_sequence+1 WHERE id IN (SELECT generation_id FROM inventory_reconcile WHERE request_sequence=0 UNION SELECT generation_id FROM inventory_invalidations WHERE request_sequence=0)")
            for table in ["inventory_reconcile", "inventory_invalidations"] {
                try connection.write("UPDATE \(table) SET request_sequence=(SELECT inventory_sequence FROM inventory_generations WHERE id=\(table).generation_id),end_node_id=CASE WHEN end_node_id=0 THEN COALESCE((SELECT MAX(id) FROM inventory_nodes),0) ELSE end_node_id END WHERE request_sequence=0 AND generation_id IS NOT NULL")
            }
}

private struct InventoryDirectorySnapshot: Equatable {
    let device: Int64, inode: UInt64, birth: Int64, mtime: Int64, ctime: Int64
    init(device: Int64, inode: UInt64, birth: Int64, mtime: Int64, ctime: Int64) {
        self.device = device; self.inode = inode; self.birth = birth; self.mtime = mtime; self.ctime = ctime
    }
    init(_ value: stat) {
        let metadata = InventoryFilesystemMetadata(value)
        device = metadata.device; inode = metadata.inode; birth = metadata.birthNanoseconds
        mtime = Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec)
        ctime = metadata.changedNanoseconds
    }
}

private struct InventoryEntryMetadata {
    let name: String
    let metadata: InventoryFilesystemMetadata
    let traversable: Bool
    let reason: String?
}

private struct InventoryJob {
    let node: Int64, generation: Int64, root: String, relative: String
    let identity: InventoryIdentity
    let token: Int64
    let listingSequence: Int64
    let snapshot: InventoryDirectorySnapshot?
    let parent: Int64?
}

private struct InventoryCompletedListing {
    let job: InventoryJob
    let entries: [InventoryEntryMetadata]
    let snapshot: InventoryDirectorySnapshot
    let measuredAt: Double
}

private enum InventoryBatchResult {
    case batch(entries: [InventoryEntryMetadata], ended: Bool, snapshot: InventoryDirectorySnapshot)
    case unavailable(reason: String, snapshot: InventoryDirectorySnapshot?)
    case changed
}

private final class InventoryOpenDirectory {
    let handle: UnsafeMutablePointer<DIR>
    let snapshot: InventoryDirectorySnapshot
    let path: String
    var replayingCommittedPrefix: Bool

    /// Why an open failed: a real error (with its errno), or the folder changed while it was being
    /// opened. A change must be retried and counted toward deferral, never reported as unreadable.
    enum Failure: Error { case error(Int32), changed }
    private(set) static var lastFailure: Failure = .changed

    init?(path: String, expected: InventoryDirectorySnapshot?) {
        self.path = path
        replayingCommittedPrefix = expected != nil
        var before = stat()
        guard lstat(path, &before) == 0 else { Self.lastFailure = .error(errno); return nil }
        guard let handle = opendir(path) else { Self.lastFailure = .error(errno); return nil }
        let snapshot = InventoryDirectorySnapshot(before)
        var opened = stat()
        guard fstat(dirfd(handle), &opened) == 0 else { Self.lastFailure = .error(errno); closedir(handle); return nil }
        guard InventoryDirectorySnapshot(opened) == snapshot, expected == nil || expected == snapshot else {
            Self.lastFailure = .changed; closedir(handle); return nil
        }
        self.handle = handle; self.snapshot = snapshot
    }

    deinit { closedir(handle) }
}

func runInventory(databasePath: String, directory: URL, region: CoverageRegion, options: InventoryRunOptions = InventoryRunOptions(), fdaOverride: String? = nil, gatedOverride: ConsentGate? = nil, cancelled: @escaping () -> Bool = { false }) -> InventoryRunResult {
    do {
        if let runtime = NativeQARuntime.active {
            guard databasePath == runtime.database, directory.path == runtime.support, region.root == runtime.fixtures else { try NativeQARuntime.reject("worker database/root does not match profile") }
            try runtime.validateStorage()
        }
        try initializeInventorySchema(databasePath: databasePath)
        guard let lock = FileLock(directory.appendingPathComponent("inventory.lock").path, wait: 0) else {
            return InventoryRunResult(outcome: "busy", generation: nil, entries: 0, directories: 0, pending: 0, reason: "Another inventory worker is active")
        }
        defer { withExtendedLifetime(lock) {} }
        let streams = InventoryStreamStore()
        defer { streams.removeAll() }
        applyObservationalIOPolicy()
        let connection = try InventoryConnection(databasePath)
        let initialMarker = currentEventMarker(region.root)
        if let device = initialMarker.device, try loadInventoryEventCursor(connection: connection, deviceIdentifier: device) == nil {
            try acknowledgeInventoryEventCursor(connection, device: device, eventID: initialMarker.eventId, at: Date().timeIntervalSince1970)
        }
        let operationalPath = dataRelative(directory.path, mount: region.mount).flatMap { region.relative(fromDevice: $0) }.map { region.absolute($0) } ?? directory.path
        let root = try prepareInventoryRoot(connection, region: region, operationalPath: operationalPath)
        try applyInventoryInvalidations(connection, generation: root.generation, rootNode: root.node, rootPath: region.root)
        try expandInventoryReconcile(connection, generation: root.generation, limit: 256)
        // Also the bounded legacy step: an 'unknown' generation is confirmed from durable
        // lifecycle state here, without relisting anything.
        var initialRecorded = try recordInitialInventoryCompletionIfReady(connection, generation: root.generation)
        var lastInitialCheck = DispatchTime.now().uptimeNanoseconds
        if options.maxDuration > 0,
           options.cancelFile.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true,
           try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_jobs WHERE generation_id=? AND state IN ('pending','enumerating'))", [root.generation]) > 0 {
            try connection.write("UPDATE inventory_generations SET state='building',reason=NULL,updated_at=? WHERE id=?", [Date().timeIntervalSince1970,root.generation])
        }
        var gate = gatedOverride ?? (fdaOverride == "granted" ? [] : consentGatedPaths(region))
        if let operational = inventoryRelativePath(operationalPath, root: region.root) { gate.exact.insert(operational) }
        var deadline = Date().addingTimeInterval(options.maxDuration)
        var lastSpaceCheck: UInt64 = 0, lastProgressSample: UInt64 = 0
        var entries = 0, directories = 0, reason: String?
        var completed = [InventoryCompletedListing](), bufferedEntries = 0
        var interactiveStreak = 0
        // A directory written continuously (a browser cache) changes during every listing.
        // Retrying it immediately spins until the budget expires; after a few attempts it
        // stays durably pending and stale, and a later run (or its next event) retries it.
        var changedRestarts = [Int64: Int](), deferred = Set<Int64>(), drained = false
        // Seed only a new startup-volume generation. No filesystem probing pass and no
        // jobs are duplicated: these bounded hints resolve through discovered parents.
        if region.root == dataVolumeMount,
           try connection.scalar("SELECT listing_token FROM inventory_jobs WHERE node_id=?", [root.node]) == 0 {
            let user = FileManager.default.homeDirectoryForCurrentUser.path
            for path in ["/Applications", user + "/Downloads", user + "/Documents", user + "/Movies", user + "/Library/Developer", user + "/Library/Caches"] {
                try requestInventoryFocus(databasePath: databasePath, path: path, source: "initial")
            }
        }
        var lastRequestService = DispatchTime.now().uptimeNanoseconds
        func serviceRequests() throws {
            if options.serviceRequests, DispatchTime.now().uptimeNanoseconds - lastRequestService >= 250_000_000 {
                try consumeInventoryRequests(database: databasePath, directory: directory, region: region)
                lastRequestService = DispatchTime.now().uptimeNanoseconds
            }
        }
        // Every restart of a changed folder counts toward its retry limit, whether the change was
        // seen while reading or when a buffered listing was revalidated before its commit.
        func noteChangedDuringListing(_ node: Int64) throws {
            changedRestarts[node, default: 0] += 1
            guard changedRestarts[node]! >= inventoryChangedRetryLimit else { return }
            deferred.insert(node)
            // Durable until the next run's first attempt resets the job's reason. The viewer
            // counts it, and it does not hold back the first-pass milestone.
            try connection.write("UPDATE inventory_jobs SET reason=? WHERE node_id=? AND state='pending'", [inventoryDeferredReason, node])
            try connection.write("UPDATE inventory_nodes SET reason=? WHERE id=?", [inventoryDeferredReason, node])
        }
        func flushCompletedListings() throws {
            guard !completed.isEmpty else { return }
            let ready = completed
            completed.removeAll(keepingCapacity: true); bufferedEntries = 0
            var valid = [InventoryCompletedListing]()
            // Revalidate observations outside the writer transaction. A buffered
            // listing cannot certify a directory that changed while another was read.
            for item in ready {
                let path = item.job.relative.isEmpty ? item.job.root : item.job.root + "/" + item.job.relative
                try NativeQARuntime.active?.validateRequest(path, action: "refresh")
                var value = stat()
                let unchanged = withThrottledIO { lstat(path, &value) == 0 && InventoryDirectorySnapshot(value) == item.snapshot }
                if unchanged { valid.append(item) }
                else {
                    try restartInventoryJob(connection, job: item.job, reason: "directory changed before listing commit")
                    try noteChangedDuringListing(item.job.node)
                }
            }
            guard !valid.isEmpty else { return }
            try connection.transaction {
                try coalescingAggregates(connection, generation: root.generation) {
                    for item in valid {
                        try persistInventoryBatchBody(connection, job: item.job, entries: item.entries, ended: true, snapshot: item.snapshot, now: item.measuredAt)
                    }
                }
            }
            entries += valid.reduce(0) { $0 + $1.entries.count }; directories += valid.count
        }
        while Date() < deadline {
            try serviceRequests()
            if cancelled() || options.cancelFile.map({ FileManager.default.fileExists(atPath: $0) }) == true {
                reason = "cancelled"; break
            }
            let tick = DispatchTime.now().uptimeNanoseconds
            if tick - lastSpaceCheck >= 5_000_000_000 {
                lastSpaceCheck = tick
                if inventoryLowOnSpace(directory) { reason = inventoryLowSpaceReason; break }
            }
            if tick - lastProgressSample >= 10_000_000_000 {
                lastProgressSample = tick
                try flushCompletedListings()
                try recordInventoryProgress(connection, generation: root.generation, rootNode: root.node)
                try pruneInventoryChangeJournal(connection)
            }
            // Long slices record the milestone soon after first discovery drains.
            if !initialRecorded, DispatchTime.now().uptimeNanoseconds - lastInitialCheck >= 30_000_000_000 {
                initialRecorded = try recordInitialInventoryCompletionIfReady(connection, generation: root.generation)
                lastInitialCheck = DispatchTime.now().uptimeNanoseconds
            }
            if let stop = options.stopAfterEntries, entries + bufferedEntries >= stop { reason = "entry limit"; break }
            if let first = completed.first {
                if Date().timeIntervalSince1970 - first.measuredAt >= 0.1 { try flushCompletedListings() }
                else if try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_invalidations WHERE generation_id=?)", [root.generation]) > 0 { try flushCompletedListings() }
            }
            // Service a bounded page even while the initial crawl has pending jobs.
            // Waiting for an empty job queue can starve events for the entire crawl.
            if completed.isEmpty { try applyInventoryInvalidations(connection, generation: root.generation, rootNode: root.node, rootPath: region.root, limit: 64) }
            let focused = try focusedInventoryNode(connection, generation: root.generation, root: region.root).flatMap { deferred.contains($0) ? nil : $0 }
            if let focused, completed.contains(where: { $0.job.node == focused }) { try flushCompletedListings(); continue }
            let useFocus = interactiveStreak < 3 && focused != nil
            guard let job = try nextInventoryJob(connection, generation: root.generation, excluding: completed.map { $0.job.node } + deferred, preferred: useFocus ? focused : nil) else {
                if !completed.isEmpty { try flushCompletedListings(); continue }
                if try connection.scalar("SELECT COUNT(*) FROM inventory_invalidations WHERE generation_id=?", [root.generation]) > 0 {
                    try applyInventoryInvalidations(connection, generation: root.generation, rootNode: root.node, rootPath: region.root)
                    continue
                }
                if try connection.scalar("SELECT COUNT(*) FROM inventory_reconcile WHERE generation_id=?", [root.generation]) > 0 {
                    try expandInventoryReconcile(connection, generation: root.generation, limit: 256); continue
                }
                if try processInventoryTombstones(connection, generation: root.generation, limit: 256) { continue }
                drained = true
                break
            }
            // Buffered listings are not in the database yet. Flush and reselect before reading a folder
            // that is an ancestor or descendant of one; listings of unrelated folders share a commit
            // (one commit per parent folder dominated first-pass time). Moved folders never buffer.
            if completed.contains(where: { inventoryPathsRelated($0.job.relative, job.relative) }) {
                try flushCompletedListings(); continue
            }
            if useFocus { interactiveStreak += 1; InventoryProfile.current?.add("interactive_quanta") }
            else { interactiveStreak = 0; InventoryProfile.current?.add("background_quanta") }
            let absolute = job.relative.isEmpty ? job.root : job.root + "/" + job.relative
            try NativeQARuntime.active?.validateRequest(absolute, action: "refresh")
            InventoryProfile.current?.add("job_quanta")
            var activeJob = try beginInventoryListing(connection, job: job)
            var keepListing = true
            var batchesThisTurn = 0
            while keepListing && Date() < deadline {
                try serviceRequests()
                if cancelled() || options.cancelFile.map({ FileManager.default.fileExists(atPath: $0) }) == true { reason = "cancelled"; break }
                let plannedToken = activeJob.snapshot == nil ? activeJob.token + 1 : activeJob.token
                // A macOS directory open can wait indefinitely for privacy services.
                // Reuse coverage's process watchdog; never hold a writer transaction
                // during this I/O. Persist the gap before launchd retries other jobs.
                let watchedNode = activeJob.node, watchedGeneration = activeJob.generation
                WalkWatchdog.shared.begin(path: absolute, allowed: 60) {
                    do { try markInventoryIOBlocked(databasePath: databasePath, node: watchedNode, generation: watchedGeneration) }
                    catch { fputs("Storage Monitor: could not persist blocked inventory directory: \(error)\n", stderr) }
                }
                // Drained per batch for the same reason as the request mailbox: the run never returns to
                // a run loop, so Foundation temporaries would otherwise live until the worker exits.
                let result = autoreleasepool { withThrottledIO { readInventoryBatch(path: absolute, operationalPath: operationalPath, region: region, relative: activeJob.relative, identity: activeJob.identity, gate: gate, fdaGranted: fdaOverride == "granted", expected: activeJob.snapshot, deadline: &deadline, streams: streams, limit: min(options.batchSize, max(1, (options.stopAfterEntries ?? Int.max) - entries - bufferedEntries)), cancelled: {
                    cancelled() || options.cancelFile.map { FileManager.default.fileExists(atPath: $0) } == true
                }, seen: { name in
                    activeJob.snapshot != nil && ((try? connection.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE generation_id=? AND parent_id=? AND name=? AND seen_token=?", [activeJob.generation, activeJob.node, name, plannedToken])) ?? 0) > 0
                }) } }
                WalkWatchdog.shared.end()
                switch result {
                case .changed:
                    streams.values[absolute] = nil
                    try flushCompletedListings()
                    try restartInventoryJob(connection, job: activeJob, reason: "directory changed during listing"); keepListing = false
                    try noteChangedDuringListing(activeJob.node)
                case .unavailable(let unavailable, _):
                    streams.values[absolute] = nil
                    try flushCompletedListings()
                    if unavailable == "identity_changed", activeJob.parent == nil {
                        // Keep this root job pending. A retry can establish a new
                        // generation without certifying the previous root object.
                        throw InventoryEngineError.invalidRoot("Inventory root identity changed; initialization must resume against the current root")
                    }
                    try finishUnavailableInventoryJob(connection, job: activeJob, reason: unavailable); directories += 1; keepListing = false
                case .batch(let batch, let ended, let snapshot):
                    var groupable = false
                    if ended { groupable = try inventoryListingCanShareCommit(connection, job: activeJob, entries: batch) }
                    if groupable {
                        if bufferedEntries + batch.count > inventoryGroupedEntryLimit { try flushCompletedListings() }
                        completed.append(InventoryCompletedListing(job: activeJob, entries: batch, snapshot: snapshot, measuredAt: Date().timeIntervalSince1970))
                        bufferedEntries += batch.count
                        if completed.count >= inventoryGroupedListingLimit || bufferedEntries >= inventoryGroupedEntryLimit { try flushCompletedListings() }
                    } else {
                        try flushCompletedListings()
                        try persistInventoryBatch(connection, job: activeJob, entries: batch, ended: ended, snapshot: snapshot, now: Date().timeIntervalSince1970)
                        entries += batch.count
                        if ended { directories += 1 }
                    }
                    activeJob = InventoryJob(node: activeJob.node, generation: activeJob.generation, root: activeJob.root, relative: activeJob.relative, identity: activeJob.identity, token: plannedToken, listingSequence: activeJob.listingSequence, snapshot: snapshot, parent: activeJob.parent)
                    if ended { keepListing = false }
                }
                if let stop = options.stopAfterEntries, entries + bufferedEntries >= stop { reason = "entry limit"; keepListing = false }
                batchesThisTurn += 1
                // Preempt only when focus work exists. Keep at most four open handles;
                // closed checkpoints safely replay committed names after interruption.
                if batchesThisTurn >= 2, try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_focus WHERE generation_id=? AND expires_at>?)", [root.generation,Date().timeIntervalSince1970]) > 0 {
                    keepListing = false
                    if streams.values.count > 4 {
                        for key in streams.values.keys.filter({ $0 != absolute }).sorted().prefix(streams.values.count - 4) { streams.values[key] = nil }
                    }
                }
                if options.pause > 0 {
                    if let profile = InventoryProfile.current { profile.timed("scheduling_delay") { Thread.sleep(forTimeInterval: options.pause) } }
                    else { Thread.sleep(forTimeInterval: options.pause) }
                }
            }
        }
        try flushCompletedListings()
        if drained, reason == nil, !deferred.isEmpty { reason = inventoryDeferredReason }
        if lastProgressSample > 0 { try recordInventoryProgress(connection, generation: root.generation, rootNode: root.node) }
        try pruneInventoryChangeJournal(connection)
        try applyInventoryInvalidations(connection, generation: root.generation, rootNode: root.node, rootPath: region.root, limit: 64)
        try expandInventoryReconcile(connection, generation: root.generation, limit: 256)
        if !initialRecorded { initialRecorded = try recordInitialInventoryCompletionIfReady(connection, generation: root.generation) }
        let pending = try connection.scalar("SELECT COUNT(*) FROM inventory_jobs WHERE generation_id=? AND state IN ('pending','enumerating')", [root.generation])
        let stale = try connection.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE generation_id=? AND status IN ('stale','pending','enumerating')", [root.generation])
        let reconciling = try connection.scalar("SELECT COUNT(*) FROM inventory_reconcile WHERE generation_id=?", [root.generation])
        let tombstones = try connection.scalar("SELECT (SELECT COUNT(*) FROM inventory_tombstones WHERE generation_id=?)+(SELECT COUNT(*) FROM inventory_prune_jobs WHERE generation_id=?)", [root.generation, root.generation])
        let invalidations = try connection.scalar("SELECT COUNT(*) FROM inventory_invalidations WHERE generation_id=?", [root.generation])
        let event = try connection.rows("SELECT event_availability,event_reason FROM inventory_generations WHERE id=?", [root.generation]).first ?? [:]
        let eventAvailability = event["event_availability"] ?? "available"
        let eventReason = event["event_reason"] ?? "File-event history identity unavailable"
        let durableWorkDrained = pending == 0 && reconciling == 0 && tombstones == 0 && invalidations == 0
        if eventAvailability == "unavailable_stale" && durableWorkDrained {
            try connection.write("UPDATE inventory_nodes SET status='stale',reason=? WHERE id=?", [eventReason,root.node])
            try connection.write("UPDATE inventory_generations SET state='stale',reason=?,updated_at=? WHERE id=?", [eventReason,Date().timeIntervalSince1970,root.generation])
            return InventoryRunResult(outcome: "stale", generation: root.generation, entries: entries, directories: directories, pending: 0, reason: eventReason)
        }
        if eventAvailability == "unavailable_reconciling" && durableWorkDrained && stale == 0 {
            try connection.transaction {
                try connection.write("UPDATE inventory_nodes SET status='stale',reason=? WHERE id=?", [eventReason,root.node])
                try connection.write("UPDATE inventory_generations SET event_availability='unavailable_stale',state='stale',reason=?,updated_at=? WHERE id=?", [eventReason,Date().timeIntervalSince1970,root.generation])
            }
            return InventoryRunResult(outcome: "stale", generation: root.generation, entries: entries, directories: directories, pending: 0, reason: eventReason)
        }
        let actionableComplete = pending == 0 && stale == 0 && reconciling == 0 && tombstones == 0 && invalidations == 0
        let unknown = try connection.scalar("SELECT unknown_directories FROM inventory_stats WHERE generation_id=?", [root.generation])
        let terminalState = unknown > 0 ? "partial" : "complete"
        try connection.write("UPDATE inventory_generations SET state=?,reason=?,updated_at=? WHERE id=?", [actionableComplete ? terminalState : (reason == "cancelled" || reason == inventoryLowSpaceReason ? "paused" : "building"), actionableComplete && unknown == 0 ? nil : (reason ?? (unknown > 0 ? "Some directories are unavailable; totals are observed allocation and may be lower bounds." : nil)), Date().timeIntervalSince1970, root.generation])
        // Another slice is requested only when this one stopped at its limit with listings it could
        // still run. Drained runs (deferred folders, unreadable folders, event work queued at the
        // end) wait for the next scheduled or event-driven wake.
        var result = InventoryRunResult(outcome: actionableComplete ? terminalState : "interrupted", generation: root.generation, entries: entries, directories: directories, pending: pending, reason: reason)
        result.runnableWorkRemains = !drained && (reason == nil || reason == "entry limit") && !actionableComplete && !durableWorkDrained
        return result
    } catch {
        return InventoryRunResult(outcome: String(describing: error).contains("busy") ? "busy" : "failed", generation: nil, entries: 0, directories: 0, pending: 0, reason: String(describing: error))
    }
}

private func prepareInventoryRoot(_ connection: InventoryConnection, region: CoverageRegion, operationalPath: String) throws -> (generation: Int64, node: Int64) {
    var rootStat = stat()
    guard lstat(region.root, &rootStat) == 0, rootStat.st_dev == region.device, rootStat.st_mode & S_IFMT == S_IFDIR else {
        throw InventoryEngineError.invalidRoot("Inventory root is unavailable or outside its filesystem")
    }
    let metadata = InventoryFilesystemMetadata(rootStat), now = Date().timeIntervalSince1970
    let volumeUUID = try? URL(fileURLWithPath: region.root).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    if let existing = try connection.rows("SELECT g.id,g.volume_uuid,n.id AS node,o.device,o.inode,o.birth_ns FROM inventory_generations g JOIN inventory_nodes n ON n.generation_id=g.id AND n.parent_id IS NULL JOIN inventory_objects o ON o.id=n.object_id WHERE g.active=1 LIMIT 1").first,
       Int64(existing["device"] ?? "") == metadata.device, UInt64(existing["inode"] ?? "") == metadata.inode, Int64(existing["birth_ns"] ?? "") == metadata.birthNanoseconds,
       existing["volume_uuid"] == nil || volumeUUID == nil || existing["volume_uuid"] == volumeUUID {
        let generation = Int64(existing["id"]!)!
        try connection.write("UPDATE inventory_generations SET operational_path=?,volume_uuid=COALESCE(?,volume_uuid) WHERE id=?", [operationalPath, volumeUUID, generation])
        if try connection.scalar("SELECT COUNT(*) FROM inventory_stats WHERE generation_id=?", [generation]) == 0 {
        try connection.write("INSERT OR IGNORE INTO inventory_stats(generation_id,total_nodes,completed_directories,pending_directories,stale_directories,unknown_directories) SELECT ?,COUNT(*),SUM(CASE WHEN kind='directory' AND status='complete' THEN 1 ELSE 0 END),SUM(CASE WHEN kind='directory' AND status IN ('pending','enumerating') THEN 1 ELSE 0 END),SUM(CASE WHEN kind='directory' AND status='stale' THEN 1 ELSE 0 END),SUM(CASE WHEN kind='directory' AND status IN ('unknown','inaccessible','excluded','partial') THEN 1 ELSE 0 END) FROM inventory_nodes WHERE generation_id=?", [generation, generation])
        }
        return (generation, Int64(existing["node"]!)!)
    }
    return try connection.transaction {
        try connection.write("UPDATE inventory_generations SET active=0,state='superseded',updated_at=? WHERE active=1", [now])
        try connection.write("UPDATE inventory_objects SET owner_node_id=NULL")
        let generation = try connection.write("INSERT INTO inventory_generations(root_path,root_device,root_inode,root_birth_ns,state,operational_path,created_at,updated_at,active,volume_uuid,initial_completion) VALUES (?,?,?,?,?,?,?,?,1,?,'pending')", [region.root, metadata.device, metadata.inode, metadata.birthNanoseconds, "building", operationalPath, now, now, volumeUUID])
        try connection.write("INSERT INTO inventory_stats(generation_id) VALUES (?)", [generation])
        let object = try upsertInventoryObject(connection, metadata).id
        let node = try connection.write("INSERT INTO inventory_nodes(generation_id,parent_id,object_id,name,kind,status,reason,direct_logical,direct_allocated,total_logical,total_allocated,measured_at) VALUES (?,NULL,?,'','directory','pending',NULL,0,0,NULL,NULL,?)", [generation, object, now])
        try connection.write("UPDATE inventory_objects SET owner_node_id=COALESCE(owner_node_id,?) WHERE id=?", [node, object])
        try connection.write("INSERT INTO inventory_jobs(node_id,generation_id,state,updated_at) VALUES (?,?,'pending',?)", [node, generation, now])
        return (generation, node)
    }
}

// First-pass completion invariant (INVENTORY-COMPLETION-LIFECYCLE.md). For the active generation:
// its root has a job; no directory job awaiting or inside its first listing remains
// (pending/enumerating with completed_token=0, which includes interrupted and paused first
// listings); no unapplied invalidation remains; and no traversable directory node lacks the
// job that would list it. Unavailable directories finish as recorded 'unknown'/'excluded' nodes,
// so accessible discovery can complete without Full Disk Access. Reconciliation, refresh and
// cleanup backlogs re-list already-listed folders and do not block or later reset the milestone.
// A directory deferred because it changed during every listing attempt (a browser cache) stays
// pending, stale and counted by the viewer; it does not keep the whole inventory in its first pass.
private func initialInventoryDiscoveryDrained(_ connection: InventoryConnection, generation: Int64) throws -> Bool {
    try connection.scalar("""
        SELECT EXISTS(SELECT 1 FROM inventory_generations g JOIN inventory_nodes r ON r.generation_id=g.id AND r.parent_id IS NULL
                      JOIN inventory_jobs rj ON rj.node_id=r.id WHERE g.id=? AND g.active=1)
          AND NOT EXISTS(SELECT 1 FROM inventory_jobs INDEXED BY inventory_jobs_first_listing WHERE generation_id=? AND completed_token=0 AND state IN ('pending','enumerating') AND reason IS NOT ?)
          AND NOT EXISTS(SELECT 1 FROM inventory_invalidations WHERE generation_id=?)
        """, [generation, generation, inventoryDeferredReason, generation]) == 1
}

private func inventoryHasUnlistedDirectoryNodes(_ connection: InventoryConnection, generation: Int64) throws -> Bool {
    try connection.scalar("""
        SELECT EXISTS(SELECT 1 FROM inventory_nodes n WHERE n.generation_id=? AND n.kind='directory' AND (
          (n.status IN ('pending','enumerating') AND NOT EXISTS(SELECT 1 FROM inventory_jobs j WHERE j.node_id=n.id AND j.state IN ('pending','enumerating')))
          OR (n.status NOT IN ('unknown','excluded','inaccessible') AND NOT EXISTS(SELECT 1 FROM inventory_jobs j WHERE j.node_id=n.id))))
        """, [generation]) == 1
}

/// Records the durable first-pass milestone once; returns whether it is recorded. Idempotent.
/// The full node scan runs outside the writer lock (only this lock-holding worker creates
/// nodes or jobs); job and invalidation state is re-verified inside the same transaction as
/// the write, so a concurrent request or interrupted commit cannot leave a premature marker.
@discardableResult
private func recordInitialInventoryCompletionIfReady(_ connection: InventoryConnection, generation: Int64) throws -> Bool {
    let current = try connection.rows("SELECT initial_completion FROM inventory_generations WHERE id=?", [generation]).first?["initial_completion"]
    if current == "complete" { return true }
    guard try initialInventoryDiscoveryDrained(connection, generation: generation),
          try !inventoryHasUnlistedDirectoryNodes(connection, generation: generation) else { return false }
    return try connection.transaction {
        guard try initialInventoryDiscoveryDrained(connection, generation: generation) else { return false }
        _ = try connection.write("UPDATE inventory_generations SET initial_completion='complete',initial_completed_at=? WHERE id=? AND active=1 AND initial_completion<>'complete'", [Date().timeIntervalSince1970, generation])
        // From here on, settled remeasurements of this generation become growth/reduction signals.
        if try connection.scalar("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='inventory_change_clock')") > 0 { try connection.exec(inventorySignalGenerationSyncSQL) }
        return true
    }
}

#if INVENTORY_TESTS
@discardableResult
func recordInitialInventoryCompletionForTesting(databasePath: String, generation: Int64) throws -> Bool {
    try recordInitialInventoryCompletionIfReady(InventoryConnection(databasePath, create: false), generation: generation)
}
#endif

// Focus changes scheduling only. It never resets a job, listing token, or event boundary.
func requestInventoryFocus(databasePath: String, path: String, source: String = "interactive", requestedAt: TimeInterval? = nil) throws {
    guard inventorySchemaExists(databasePath: databasePath) else { return }
    let c = try InventoryConnection(databasePath, create: false)
    guard let g = try c.rows("SELECT id,root_path FROM inventory_generations WHERE active=1").first,
          let generation = g["id"].flatMap(Int64.init), let root = g["root_path"] else { return }
    var target = path
    if let r = dataRelative(root), let p = dataRelative(path), r.isEmpty || p == r || p.hasPrefix(r + "/") { target = dataVolumeMount + "/" + p }
    guard target == root || target.hasPrefix(root + "/"),
          !target.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
          target.utf8.count <= 4096 else { throw InventoryEngineError.invalidRoot("Focus path is outside the inventory scope") }
    let now = Date().timeIntervalSince1970
    let requested = requestedAt ?? now
    guard now >= requested && now-requested <= 300 else { return }
    try c.transaction {
        try c.write("DELETE FROM inventory_focus WHERE expires_at<=? OR generation_id<>?", [now,generation])
        try c.write("INSERT INTO inventory_focus(generation_id,path,requested_at,expires_at,source) VALUES (?,?,?,?,?) ON CONFLICT(generation_id,path) DO UPDATE SET requested_at=excluded.requested_at,expires_at=excluded.expires_at,source=CASE WHEN inventory_focus.source='interactive' THEN 'interactive' ELSE excluded.source END", [generation,target,requested,requested+300,source])
        try c.write("DELETE FROM inventory_focus WHERE rowid IN (SELECT rowid FROM inventory_focus WHERE generation_id=? ORDER BY (source='interactive') DESC,requested_at DESC,path LIMIT -1 OFFSET 16)", [generation])
    }
}

private func focusedInventoryNode(_ c: InventoryConnection, generation: Int64, root: String) throws -> Int64? {
    let now = Date().timeIntervalSince1970
    for row in try c.rows("SELECT path FROM inventory_focus WHERE generation_id=? AND expires_at>? ORDER BY (source='interactive') DESC,CASE WHEN source='interactive' THEN -requested_at ELSE requested_at END,path LIMIT 16", [generation,now]) {
        let path = row["path"]!
        if let match = inventoryNodeForPath(c, generation: generation, root: root, absolute: path),
           try c.scalar("SELECT EXISTS(SELECT 1 FROM inventory_nodes n JOIN inventory_jobs j ON j.node_id=n.id WHERE n.id=? AND n.kind='directory' AND j.state IN ('pending','enumerating'))", [match.node]) > 0 {
            let nonDirectory = try c.scalar("WITH RECURSIVE chain(id,parent_id,kind) AS (SELECT id,parent_id,kind FROM inventory_nodes WHERE id=? UNION ALL SELECT n.id,n.parent_id,n.kind FROM inventory_nodes n JOIN chain p ON n.id=p.parent_id) SELECT EXISTS(SELECT 1 FROM chain WHERE kind<>'directory')", [match.node]) > 0
            if !nonDirectory { return match.node }
        }
        // Complete, inaccessible, absent, deleted, or a symlink: navigation is never
        // permission to relist valid data, follow a link, or retry protected content.
        try c.write("DELETE FROM inventory_focus WHERE generation_id=? AND path=?", [generation,path])
    }
    return nil
}

private func nextInventoryJob(_ connection: InventoryConnection, generation: Int64, excluding: [Int64] = [], preferred: Int64? = nil) throws -> InventoryJob? {
    let exclusion = excluding.isEmpty ? "" : " AND node_id NOT IN (" + Array(repeating: "?", count: excluding.count).joined(separator: ",") + ")"
    let preferredFilter = preferred == nil ? "" : " AND node_id=?"
    guard let row = try connection.rows("""
        WITH RECURSIVE selected AS (
          SELECT * FROM inventory_jobs WHERE generation_id=? AND state IN ('pending','enumerating')\(exclusion)\(preferredFilter) ORDER BY updated_at,node_id LIMIT 1
        ), paths(id,parent_id,path,depth) AS (
          SELECT n.id,n.parent_id,n.name,0 FROM inventory_nodes n JOIN selected j ON n.id=j.node_id
          UNION ALL SELECT n.id,n.parent_id,CASE WHEN n.name='' THEN paths.path ELSE n.name||'/'||paths.path END,paths.depth+1
          FROM inventory_nodes n JOIN paths ON n.id=paths.parent_id WHERE paths.depth<1023
        )
        SELECT j.node_id,j.generation_id,g.root_path,paths.path,j.listing_token,j.listing_sequence,o.device,o.inode,o.birth_ns,
               j.snapshot_device,j.snapshot_inode,j.snapshot_birth_ns,j.snapshot_mtime_ns,j.snapshot_ctime_ns,target.parent_id AS job_parent
        FROM selected j JOIN paths ON paths.parent_id IS NULL JOIN inventory_nodes target ON target.id=j.node_id
        JOIN inventory_objects o ON o.id=target.object_id JOIN inventory_generations g ON g.id=j.generation_id
        LIMIT 1
        """, [generation as Any?] + excluding.map { $0 as Any? } + (preferred.map { [$0 as Any?] } ?? [])).first else { return nil }
    let snapshot: InventoryDirectorySnapshot?
    if let device = Int64(row["snapshot_device"] ?? ""), let inode = UInt64(row["snapshot_inode"] ?? ""), let birth = Int64(row["snapshot_birth_ns"] ?? ""), let mtime = Int64(row["snapshot_mtime_ns"] ?? ""), let ctime = Int64(row["snapshot_ctime_ns"] ?? "") {
        snapshot = InventoryDirectorySnapshot(device: device, inode: inode, birth: birth, mtime: mtime, ctime: ctime)
    } else { snapshot = nil }
    let identity = InventoryIdentity(device: Int64(row["device"]!)!, inode: UInt64(row["inode"]!)!, birthNanoseconds: Int64(row["birth_ns"]!)!)
    return InventoryJob(node: Int64(row["node_id"]!)!, generation: generation, root: row["root_path"]!, relative: row["path"] ?? "", identity: identity, token: Int64(row["listing_token"] ?? "0") ?? 0, listingSequence: Int64(row["listing_sequence"] ?? "0") ?? 0, snapshot: snapshot, parent: row["job_parent"].flatMap(Int64.init))
}

private func beginInventoryListing(_ connection: InventoryConnection, job: InventoryJob) throws -> InventoryJob {
    guard job.snapshot == nil else { InventoryProfile.current?.add("checkpoint_quanta"); return job }
    InventoryProfile.current?.add("listings_attempted")
    let profile = InventoryProfile.current
    if let profile {
        let row = try connection.rows("SELECT reason,completed_token FROM inventory_jobs WHERE node_id=?", [job.node]).first ?? [:]
        let cause = row["reason"] ?? ""
        if cause == "Filesystem activity" { profile.add("jobs_retried_event") }
        else if cause.localizedCaseInsensitiveContains("gap") { profile.add("jobs_retried_event_gap") }
        if (Int64(row["completed_token"] ?? "0") ?? 0) > 0 { profile.add("listings_repeated") }
    }
    // A listing's sequence must be committed (visible to the viewer's request boundary) before the
    // directory is read, and must exceed every sequence issued before the listing began. One
    // commit reserves a block of unique sequences, used in order while no other writer has
    // advanced the counter; otherwise a new block is reserved. Requests captured after the
    // reservation require a later sequence, so the block can only make freshness conservative.
    // With no committed checkpoint there are no old observations to retain; the first batch's
    // commit stores this sequence on the job, and an interrupted attempt simply starts again.
    let current = try connection.scalar("SELECT inventory_sequence FROM inventory_generations WHERE id=?", [job.generation])
    let sequence: Int64, last: Int64
    if let block = connection.reservedSequences, block.generation == job.generation, block.last == current, block.next <= block.last {
        sequence = block.next; last = block.last
    } else {
        last = try connection.transaction {
            try connection.write("UPDATE inventory_generations SET inventory_sequence=inventory_sequence+? WHERE id=?", [inventorySequenceBlock, job.generation])
            return try connection.scalar("SELECT inventory_sequence FROM inventory_generations WHERE id=?", [job.generation])
        }
        sequence = last - inventorySequenceBlock + 1
        InventoryProfile.current?.add("sequence_blocks_reserved")
    }
    connection.reservedSequences = (next: sequence + 1, last: last, generation: job.generation)
    return InventoryJob(node: job.node, generation: job.generation, root: job.root, relative: job.relative,
                        identity: job.identity, token: job.token, listingSequence: sequence,
                        snapshot: job.snapshot, parent: job.parent)
}

private final class InventoryStreamStore {
    var values = [String: InventoryOpenDirectory]()
    func removeAll() { values.removeAll() }
}

private func readInventoryBatch(path: String, operationalPath: String, region: CoverageRegion, relative: String, identity: InventoryIdentity, gate: ConsentGate, fdaGranted: Bool, expected: InventoryDirectorySnapshot?, deadline: inout Date, streams: InventoryStreamStore, limit: Int, cancelled: () -> Bool, seen: (String) -> Bool) -> InventoryBatchResult {
    let profile = InventoryProfile.current
    func metadata<T>(_ body: () -> T) -> T { if let profile { return profile.timed("filesystem_metadata", body) }; return body() }
    func enumeration<T>(_ body: () -> T) -> T { if let profile { return profile.timed("directory_enumeration", body) }; return body() }
    var before = stat()
    guard metadata({ lstat(path, &before) }) == 0 else { return .unavailable(reason: errno == ENOENT ? "absent" : accessReason(errno), snapshot: nil) }
    let beforeMetadata = InventoryFilesystemMetadata(before), snapshot = InventoryDirectorySnapshot(before)
    guard beforeMetadata.identity == identity else { return .unavailable(reason: "identity_changed", snapshot: snapshot) }
    guard beforeMetadata.kind == .directory else { return .unavailable(reason: "not a directory", snapshot: snapshot) }
    guard before.st_dev == region.device else { return .unavailable(reason: "filesystem:" + fsType(path), snapshot: snapshot) }
    guard !beforeMetadata.isCloudPlaceholder else { return .unavailable(reason: "cloud", snapshot: snapshot) }
    if path == operationalPath { return .unavailable(reason: "inventory_metadata", snapshot: snapshot) }
    guard !inventoryConsentDenied(relative, region: region, gate: gate, fdaGranted: fdaGranted) else { return .unavailable(reason: "consent", snapshot: snapshot) }
    if let expected, expected != snapshot { return .changed }
    let stream: InventoryOpenDirectory
    if let current = streams.values[path], current.snapshot == snapshot { stream = current }
    else {
        streams.values[path] = nil
        if streams.values.count >= 4, let victim = streams.values.keys.sorted().first { streams.values[victim] = nil }
        guard let opened = enumeration({ InventoryOpenDirectory(path: path, expected: expected) }) else {
            if expected == nil, case .error(let code) = InventoryOpenDirectory.lastFailure { return .unavailable(reason: code == ENOENT ? "absent" : accessReason(code), snapshot: snapshot) }
            return .changed
        }
        streams.values[path] = opened; stream = opened
    }
    WalkWatchdog.shared.progress()
    var entries = [InventoryEntryMetadata](), ended = false
    var inspected = 0
    // POSIX directory cookies cannot survive a closed handle. Reopening safely replays
    // committed names. Charge this finite prefix replay separately from NEW work, or a
    // large prefix could consume every worker budget forever without adding an entry.
    // Memory and transaction bounds stay fixed; cancellation is sampled during replay.
    var replayProfileStart: UInt64? = stream.replayingCommittedPrefix ? DispatchTime.now().uptimeNanoseconds : nil
    defer { if let began = replayProfileStart { profile?.nanoseconds["checkpoint_replay", default: 0] += DispatchTime.now().uptimeNanoseconds - began } }
    var replayStarted: Date? = stream.replayingCommittedPrefix ? Date() : nil
    defer { if let replayStarted { deadline.addTimeInterval(Date().timeIntervalSince(replayStarted)) } }
    while entries.count < limit {
        WalkWatchdog.shared.progress()
        inspected += 1
        if inspected & 255 == 0 {
            if cancelled() { break }
            if !stream.replayingCommittedPrefix && Date() >= deadline { break }
        }
        errno = 0
        guard let entry = enumeration({ readdir(stream.handle) }) else { ended = errno == 0; break }
        let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        if seen(name) { profile?.add("prefix_names_replayed"); continue }
        if let started = replayStarted {
            deadline.addTimeInterval(Date().timeIntervalSince(started)); replayStarted = nil
            stream.replayingCommittedPrefix = false
            if let began = replayProfileStart { profile?.nanoseconds["checkpoint_replay", default: 0] += DispatchTime.now().uptimeNanoseconds - began; replayProfileStart = nil }
        }
        var value = stat()
        guard metadata({ fstatat(dirfd(stream.handle), name, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { streams.values[path] = nil; return .changed }
            // Listing names does not imply each entry's metadata is readable. A protected entry
            // (for example /private/var/db/DifferentialPrivacy) is recorded on its own as unreadable
            // and unmeasured; the rest of the readable folder is still listed and measured.
            let code = errno
            entries.append(InventoryEntryMetadata(name: name, metadata: InventoryFilesystemMetadata(unreadableEntry: UInt64(entry.pointee.d_ino), type: entry.pointee.d_type, device: Int64(before.st_dev)),
                                                  traversable: false, reason: "metadata:" + accessReason(code)))
            profile?.add("entries_metadata_unreadable")
            continue
        }
        let metadata = InventoryFilesystemMetadata(value)
        let childRelative = relative.isEmpty ? name : relative + "/" + name
        var traversable = metadata.kind == .directory && metadata.device == Int64(region.device) && !metadata.isCloudPlaceholder
        var reason: String?
        if metadata.kind == .directory {
            if metadata.device != Int64(region.device) { traversable = false; reason = "filesystem:" + fsType(path + "/" + name) }
            else if metadata.isCloudPlaceholder { traversable = false; reason = "cloud" }
            else if region.absolute(childRelative) == operationalPath { traversable = false; reason = "inventory_metadata" }
            else if inventoryConsentDenied(childRelative, region: region, gate: gate, fdaGranted: fdaGranted) { traversable = false; reason = "consent" }
        }
        entries.append(InventoryEntryMetadata(name: name, metadata: metadata, traversable: traversable, reason: reason))
    }
    var after = stat()
    guard metadata({ fstat(dirfd(stream.handle), &after) }) == 0, InventoryDirectorySnapshot(after) == snapshot else { streams.values[path] = nil; return .changed }
    if ended { streams.values[path] = nil }
    return .batch(entries: entries, ended: ended, snapshot: snapshot)
}

private func inventoryConsentDenied(_ relative: String, region: CoverageRegion, gate: ConsentGate, fdaGranted: Bool) -> Bool {
    if gate.contains(relative) { return true }
    guard !fdaGranted else { return false }
    let devicePath = region.deviceRelative(relative)
    let components = devicePath.split(separator: "/").map(String.init)
    guard components.count >= 3, components[0] == "Users" else { return false }
    if components[1] == FileManager.default.homeDirectoryForCurrentUser.lastPathComponent { return false }
    let suffix = Array(components.dropFirst(2))
    if ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"].contains(suffix[0]) { return true }
    if suffix[0] != "Library" { return false }
    guard suffix.count > 1 else { return false }
    return !["Caches", "Developer", "Logs"].contains(suffix[1])
}

private func inventoryRelativePath(_ path: String, root: String) -> String? {
    var clean = path
    while clean.count > 1 && clean.hasSuffix("/") { clean.removeLast() }
    if clean == root { return "" }
    return clean.hasPrefix(root + "/") ? String(clean.dropFirst(root.count + 1)) : nil
}

/// One sample per ~10 s of work, kept for two hours, so the viewer's rate and time estimate
/// survive the gaps between worker slices. Deferred folders are not counted as queued work.
private func recordInventoryProgress(_ connection: InventoryConnection, generation: Int64, rootNode: Int64) throws {
    let now = Date().timeIntervalSince1970
    try connection.transaction {
        _ = try connection.write("""
            INSERT OR REPLACE INTO inventory_progress(generation_id,sampled_at,completed_listings,queued_listings,nodes,allocated)
            SELECT ?,?,(SELECT COUNT(*) FROM inventory_jobs WHERE generation_id=? AND state='complete'),
                   (SELECT COUNT(*) FROM inventory_jobs WHERE generation_id=? AND state IN ('pending','enumerating') AND reason IS NOT ?),
                   COALESCE((SELECT total_nodes FROM inventory_stats WHERE generation_id=?),0),
                   COALESCE((SELECT total_allocated FROM inventory_nodes WHERE id=?),0)
            """, [generation, now, generation, generation, inventoryDeferredReason, generation, rootNode])
        _ = try connection.write("DELETE FROM inventory_progress WHERE generation_id=? AND sampled_at<?", [generation, now - 7_200])
    }
}

#if INVENTORY_TESTS
var inventoryAvailableSpaceOverride: (available: Int64, capacity: Int64)?
#endif

/// Free space below which indexing pauses, so the catalog cannot grow into a nearly full disk:
/// 1% of the volume, at least 2 GB and at most 5 GB (2.6 GB on a 256 GB Mac).
func inventoryLowSpaceThreshold(capacity: Int64) -> Int64 { min(5_000_000_000, max(2_000_000_000, capacity / 100)) }

/// Uses the space available for important work (it counts purgeable space macOS can reclaim).
func inventoryLowOnSpace(_ directory: URL) -> Bool {
    var space: (available: Int64, capacity: Int64)?
    #if INVENTORY_TESTS
    space = inventoryAvailableSpaceOverride
    #endif
    if space == nil, let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
       let available = values.volumeAvailableCapacityForImportantUsage, let capacity = values.volumeTotalCapacity {
        space = (available, Int64(capacity))
    }
    guard let space else { return false }   // unknown: never block indexing on a failed query
    return space.available < inventoryLowSpaceThreshold(capacity: space.capacity)
}

/// Whether one relative path is the other or contains it ("" is the inventory root).
func inventoryPathsRelated(_ a: String, _ b: String) -> Bool {
    a == b || a.isEmpty || b.isEmpty || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
}

private func inventoryListingCanShareCommit(_ connection: InventoryConnection, job: InventoryJob, entries: [InventoryEntryMetadata]) throws -> Bool {
    for entry in entries where entry.metadata.kind == .directory {
        // Include every status and non-traversable entry, just like persistence.
        // Moving an existing directory must commit before any old-path job is read.
        if let existing = try connection.rows("SELECT n.parent_id,n.name FROM inventory_objects o JOIN inventory_nodes n INDEXED BY inventory_nodes_object ON n.object_id=o.id WHERE o.device=? AND o.inode=? AND o.birth_ns=? AND n.generation_id=? AND n.kind='directory' LIMIT 1", [entry.metadata.device,entry.metadata.inode,entry.metadata.birthNanoseconds,job.generation]).first,
           existing["parent_id"].flatMap(Int64.init) != job.node || existing["name"] != entry.name { return false }
    }
    return true
}

private func persistInventoryBatch(_ connection: InventoryConnection, job: InventoryJob, entries: [InventoryEntryMetadata], ended: Bool, snapshot: InventoryDirectorySnapshot, now: Double) throws {
    try connection.transaction {
        try coalescingAggregates(connection, generation: job.generation) {
            try persistInventoryBatchBody(connection, job: job, entries: entries, ended: ended, snapshot: snapshot, now: now)
        }
    }
}

private func nextInventoryCleanupEpoch(_ connection: InventoryConnection, generation: Int64) throws -> Int64 {
    try connection.write("UPDATE inventory_generations SET cleanup_sequence=cleanup_sequence+1 WHERE id=?", [generation])
    return try connection.scalar("SELECT cleanup_sequence FROM inventory_generations WHERE id=?", [generation])
}

private func persistInventoryBatchBody(_ connection: InventoryConnection, job: InventoryJob, entries: [InventoryEntryMetadata], ended: Bool, snapshot: InventoryDirectorySnapshot, now: Double) throws {
    let profile = InventoryProfile.current
    var affectedParents = Set<Int64>()
    let token: Int64
    if job.snapshot == nil {
        token = job.token + 1
        try connection.write("UPDATE inventory_jobs SET state='enumerating',cookie=0,listing_token=?,listing_sequence=?,snapshot_device=?,snapshot_inode=?,snapshot_birth_ns=?,snapshot_mtime_ns=?,snapshot_ctime_ns=?,reason=NULL,updated_at=? WHERE node_id=?", [token, job.listingSequence, snapshot.device, snapshot.inode, snapshot.birth, snapshot.mtime, snapshot.ctime, now, job.node])
        // A folder previously recorded as unreadable is readable now: it is measured again from here.
        try connection.write("UPDATE inventory_nodes SET status='pending',reason=NULL WHERE id=? AND status='unknown'", [job.node])
    } else { token = job.token }
    // A folder with no catalogued children yet (a first listing) cannot already hold any of these
    // names, which readdir reports once each: skip the per-entry lookup of an existing node.
    let parentHadChildren = try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_nodes WHERE parent_id=?)", [job.node]) > 0
    for entry in entries {
        let unreadable = entry.reason?.hasPrefix("metadata:") == true
        // An entry whose metadata is refused keeps the object of the node already at that name:
        // its identity is not known to have changed, and its earlier object must not be replaced.
        let retained: Int64? = unreadable ? try connection.rows("SELECT object_id FROM inventory_nodes WHERE generation_id=? AND parent_id=? AND name=? AND kind=?", [job.generation, job.node, entry.name, entry.metadata.kind.rawValue]).first.flatMap { Int64($0["object_id"] ?? "") } : nil
        let objectUpdate = try retained.map { InventoryObjectUpsert(id: $0, accountingChanged: false) } ?? upsertInventoryObject(connection, entry.metadata)
        let object = objectUpdate.id
        let state = entry.metadata.kind == .directory ? (entry.traversable ? "pending" : (entry.reason?.hasPrefix("filesystem:") == true || entry.reason == "cloud" || entry.reason == "inventory_metadata" ? "excluded" : "unknown")) : (unreadable ? "unknown" : "complete")
        let qualification = entry.metadata.kind == .file && entry.metadata.linkCount > 1 ? "Hard-link allocation is counted once across observed names; other links may exist outside this inventory." : entry.reason
        var nodeID: Int64, nodeIsExisting = true
        if parentHadChildren, let existing = try connection.rows("SELECT id,object_id,status,reason,kind FROM inventory_nodes WHERE generation_id=? AND parent_id=? AND name=?", [job.generation, job.node, entry.name]).first {
            profile?.add("entries_remeasured_committed")
            nodeID = Int64(existing["id"]!)!
            let oldObject = Int64(existing["object_id"]!)!
            if oldObject != object {
                // A reused pathname is a new object. Reset its directory checkpoint;
                // completed work for the old inode cannot certify the replacement, including
                // the first-listing token the first-pass milestone relies on.
                try connection.write("UPDATE inventory_jobs SET state='pending',listing_sequence=0,snapshot_device=NULL,snapshot_inode=NULL,snapshot_birth_ns=NULL,snapshot_mtime_ns=NULL,snapshot_ctime_ns=NULL,completed_token=0,updated_at=? WHERE node_id=?", [now,nodeID])
                if entry.metadata.kind != .directory {
                    if try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_nodes WHERE parent_id=?)", [nodeID]) > 0 {
                        let epoch = try nextInventoryCleanupEpoch(connection, generation: job.generation)
                        try connection.write("INSERT INTO inventory_prune_jobs(parent_node_id,generation_id,seen_token,created_at,cleanup_epoch,authority_kind,authority_object_id,authority_sequence) VALUES (?,?,-1,?,?,?,?,?) ON CONFLICT(parent_node_id) DO UPDATE SET seen_token=-1,last_node_id=0,created_at=excluded.created_at,cleanup_epoch=excluded.cleanup_epoch,authority_kind=excluded.authority_kind,authority_object_id=excluded.authority_object_id,authority_sequence=excluded.authority_sequence", [nodeID,job.generation,now,epoch,"replacement",object,job.listingSequence])
                    } else {
                        try connection.write("DELETE FROM inventory_prune_jobs WHERE parent_node_id=?", [nodeID])
                    }
                    try connection.write("DELETE FROM inventory_jobs WHERE node_id=?", [nodeID])
                }
            }
            let effectiveState = oldObject != object && entry.metadata.kind == .directory ? "stale" : (oldObject == object && entry.metadata.kind == .directory && entry.traversable ? (existing["status"] ?? state) : state)
            let effectiveReason = oldObject == object && entry.metadata.kind == .directory && entry.traversable ? existing["reason"] : qualification
            if entry.metadata.kind == .directory && oldObject == object {
                // Seeing a directory entry again does not remeasure its subtree. Retain its
                // aggregate values and measurement timestamp until its own listing runs.
                // The observation token is written on its own; the displayed columns only when they change, so an
                // unchanged entry does not run the change-journal trigger (most re-listed entries are unchanged).
                try connection.write("UPDATE inventory_nodes SET seen_token=? WHERE id=?", [token,nodeID])
                try connection.write("UPDATE inventory_nodes SET status=?,reason=? WHERE id=? AND (status IS NOT ? OR reason IS NOT ?)", [effectiveState,effectiveReason,nodeID,effectiveState,effectiveReason])
            } else {
                // A file's totals are its object's bytes only for the object's owner; other names (hard links) carry
                // zero. Writing the owner-adjusted value directly keeps an unchanged alias from passing through a
                // transient value that would read as growth and then reduction.
                let owner = entry.metadata.kind == .directory ? nodeID : try connection.scalar("SELECT COALESCE(owner_node_id,?) FROM inventory_objects WHERE id=?", [nodeID, object])
                let logical: Int64? = entry.metadata.kind == .directory ? nil : (owner == nodeID ? entry.metadata.logicalBytes : 0)
                let allocated: Int64? = entry.metadata.kind == .directory ? nil : (owner == nodeID ? entry.metadata.allocatedBytes : 0)
                try connection.write("UPDATE inventory_nodes SET seen_token=?,measured_at=? WHERE id=?", [token, now, nodeID])
                try connection.write("UPDATE inventory_nodes SET object_id=?,kind=?,status=?,reason=?,total_logical=?,total_allocated=? WHERE id=? AND (object_id IS NOT ? OR kind IS NOT ? OR status IS NOT ? OR reason IS NOT ? OR total_logical IS NOT ? OR total_allocated IS NOT ?)", [object, entry.metadata.kind.rawValue, effectiveState, effectiveReason, logical, allocated, nodeID, object, entry.metadata.kind.rawValue, effectiveState, effectiveReason, logical, allocated])
                if entry.metadata.kind != .directory {
                    try connection.write("UPDATE inventory_nodes SET child_count=0,descendant_files=0,descendant_directories=0,descendant_entries=0,status=CASE WHEN EXISTS(SELECT 1 FROM inventory_prune_jobs WHERE parent_node_id=?) THEN 'stale' ELSE status END WHERE id=? AND (child_count<>0 OR descendant_files<>0 OR descendant_directories<>0 OR descendant_entries<>0 OR (status<>'stale' AND EXISTS(SELECT 1 FROM inventory_prune_jobs WHERE parent_node_id=?)))", [nodeID,nodeID,nodeID])
                }
            }
            if entry.metadata.kind != .directory, oldObject == object, existing["status"] == "stale",
               try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_nodes WHERE parent_id=?)", [nodeID]) > 0 {
                let epoch = try nextInventoryCleanupEpoch(connection, generation: job.generation)
                try connection.write("INSERT INTO inventory_prune_jobs(parent_node_id,generation_id,seen_token,created_at,cleanup_epoch,authority_kind,authority_object_id,authority_sequence) VALUES (?,?,-1,?,?,'replacement',?,?) ON CONFLICT(parent_node_id) DO UPDATE SET last_node_id=0,cleanup_epoch=excluded.cleanup_epoch,authority_kind='replacement',authority_object_id=excluded.authority_object_id,authority_sequence=excluded.authority_sequence", [nodeID,job.generation,now,epoch,object,job.listingSequence])
                try connection.write("UPDATE inventory_nodes SET status='stale' WHERE id=?", [nodeID])
            }
            if oldObject != object, let parent = try repairInventoryOwner(connection, object: oldObject, generation: job.generation) { affectedParents.insert(parent) }
        } else if entry.metadata.kind == .directory, let moved = try connection.rows("SELECT n.id,n.parent_id FROM inventory_nodes n INDEXED BY inventory_nodes_object WHERE n.generation_id=? AND n.object_id=? AND n.kind='directory' LIMIT 1", [job.generation, object]).first {
            // Without the object-index hint, SQLite can prefer the generation/kind
            // index and scan every known directory for each newly discovered inode.
            profile?.add("entries_remeasured_committed")
            nodeID = Int64(moved["id"]!)!
            if try !wouldCreateInventoryCycle(connection, node: nodeID, parent: job.node) {
                try connection.write("UPDATE inventory_nodes SET parent_id=?,name=?,seen_token=? WHERE id=?", [job.node, entry.name, token, nodeID])
                if let previousParent = moved["parent_id"].flatMap(Int64.init) { affectedParents.insert(previousParent) }
            } else { continue }
        } else {
            profile?.add("new_entries_committed")
            // A new object's first node becomes its owner, so its direct values are the object's own.
            let owns = objectUpdate.isNew
            nodeIsExisting = false
            nodeID = try connection.write("INSERT INTO inventory_nodes(generation_id,parent_id,object_id,name,kind,status,reason,total_logical,total_allocated,seen_token,measured_at,direct_logical,direct_allocated) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", [job.generation, job.node, object, entry.name, entry.metadata.kind.rawValue, state, qualification, entry.metadata.kind == .directory ? nil : entry.metadata.logicalBytes, entry.metadata.kind == .directory ? nil : entry.metadata.allocatedBytes, token, now, owns ? entry.metadata.logicalBytes : 0, owns ? entry.metadata.allocatedBytes : 0])
        }
        // Tombstones cascade with their node, so a node inserted just now cannot have one.
        if nodeIsExisting { try connection.write("DELETE FROM inventory_tombstones WHERE node_id=?", [nodeID]) }
        try connection.write("UPDATE inventory_objects SET owner_node_id=COALESCE(owner_node_id,?) WHERE id=?", [nodeID, object])
        if unreadable {
            // Size unknown: no totals, and no contribution to the folder beyond marking it partial.
            try connection.write("UPDATE inventory_nodes SET total_logical=NULL,total_allocated=NULL,direct_logical=0,direct_allocated=0 WHERE id=?", [nodeID])
        } else if !objectUpdate.isNew || nodeIsExisting {
            // A new object has exactly this node, already written with the owner's values above.
            try syncInventoryObjectAccounting(connection, object: object)
        }
        if objectUpdate.accountingChanged,
           let ownerParent = try connection.rows("SELECT n.parent_id FROM inventory_objects o JOIN inventory_nodes n ON n.id=o.owner_node_id WHERE o.id=?", [object]).first?["parent_id"].flatMap(Int64.init),
           ownerParent != job.node {
            affectedParents.insert(ownerParent)
        }
        if entry.metadata.kind == .directory && entry.traversable {
            try connection.write("INSERT INTO inventory_jobs(node_id,generation_id,state,updated_at) VALUES (?,?,'pending',?) ON CONFLICT(node_id) DO UPDATE SET state=CASE WHEN inventory_jobs.state='complete' THEN inventory_jobs.state ELSE 'pending' END,listing_sequence=CASE WHEN inventory_jobs.state='complete' THEN inventory_jobs.listing_sequence ELSE 0 END,updated_at=excluded.updated_at", [nodeID, job.generation, now])
        }
    }
    for parent in affectedParents { try recomputeInventoryAncestors(connection, from: parent, generation: job.generation, measuredAt: now) }
    if ended {
        profile?.add("listings_completed")
        if try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_nodes WHERE parent_id=? AND seen_token<>?)", [job.node,token]) > 0 {
            let epoch = try nextInventoryCleanupEpoch(connection, generation: job.generation)
            try connection.write("INSERT INTO inventory_prune_jobs(parent_node_id,generation_id,seen_token,created_at,cleanup_epoch,authority_kind,authority_object_id,authority_sequence) VALUES (?,?,?,?,?,'listing',NULL,?) ON CONFLICT(parent_node_id) DO UPDATE SET seen_token=excluded.seen_token,last_node_id=0,created_at=excluded.created_at,cleanup_epoch=excluded.cleanup_epoch,authority_kind='listing',authority_object_id=NULL,authority_sequence=excluded.authority_sequence", [job.node, job.generation, token, now, epoch, job.listingSequence])
        } else { try connection.write("DELETE FROM inventory_prune_jobs WHERE parent_node_id=?", [job.node]) }
        try connection.write("UPDATE inventory_jobs SET state='complete',cookie=0,completed_sequence=?,completed_token=?,listing_sequence=0,snapshot_device=NULL,snapshot_inode=NULL,snapshot_birth_ns=NULL,snapshot_mtime_ns=NULL,snapshot_ctime_ns=NULL,updated_at=? WHERE node_id=?", [job.listingSequence,token,now, job.node])
        try recomputeInventoryAncestors(connection, from: job.node, generation: job.generation, measuredAt: now)
        connection.slowRecomputeSeconds[job.node] = nil
    } else {
        try connection.write("UPDATE inventory_jobs SET state='enumerating',cookie=0,updated_at=? WHERE node_id=?", [now, job.node])
        try connection.write("UPDATE inventory_nodes SET status=CASE WHEN status='stale' THEN 'stale' ELSE 'enumerating' END,reason='listing incomplete' WHERE id=?", [job.node])
        // Publish the first useful partial size promptly, then at most once a second, or less often
        // when re-summing this folder is itself slow: the interval is ten times the last re-sum, so a
        // folder with hundreds of thousands of entries no longer re-sums on every batch (quadratic).
        let interval = max(1, 10 * (connection.slowRecomputeSeconds[job.node] ?? 0))
        if try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_nodes WHERE id=? AND (total_allocated IS NULL OR measured_at IS NULL OR measured_at<?))", [job.node,now-interval]) > 0 {
            try recomputeInventoryAncestors(connection, from: job.node, generation: job.generation, measuredAt: now)
        }
    }
    try connection.write("UPDATE inventory_generations SET updated_at=? WHERE id=?", [now, job.generation])
}

private struct InventoryObjectUpsert {
    let id: Int64
    let accountingChanged: Bool
    var isNew = false
}

private func upsertInventoryObject(_ connection: InventoryConnection, _ metadata: InventoryFilesystemMetadata) throws -> InventoryObjectUpsert {
    let values: [Any?] = [metadata.device, metadata.inode, metadata.birthNanoseconds, metadata.kind.rawValue, metadata.logicalBytes, metadata.allocatedBytes, metadata.linkCount, metadata.modifiedAt, metadata.changedNanoseconds]
    // Most objects in a first pass are new: one insert. Only an existing object (another name for
    // it, or a re-listing) is read and updated, and reports whether its accounting changed.
    let inserted = try connection.write("INSERT INTO inventory_objects(device,inode,birth_ns,kind,logical,allocated,link_count,modified_at,changed_ns) VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(device,inode,birth_ns) DO NOTHING", values)
    if connection.changes == 1 { return InventoryObjectUpsert(id: inserted, accountingChanged: false, isNew: true) }
    guard let existing = try connection.rows("SELECT id,logical,allocated FROM inventory_objects WHERE device=? AND inode=? AND birth_ns=?", [metadata.device, metadata.inode, metadata.birthNanoseconds]).first,
          let id = Int64(existing["id"] ?? "") else { throw Failure("Inventory object vanished during upsert") }
    // Only a changed object is rewritten (its change is journaled for every name that shows it).
    let fields = Array(values.dropFirst(3))
    _ = try connection.write("UPDATE inventory_objects SET kind=?,logical=?,allocated=?,link_count=?,modified_at=?,changed_ns=? WHERE id=? AND (kind IS NOT ? OR logical IS NOT ? OR allocated IS NOT ? OR link_count IS NOT ? OR modified_at IS NOT ? OR changed_ns IS NOT ?)", fields + [id] + fields)
    let changed = Int64(existing["logical"] ?? "") != metadata.logicalBytes || Int64(existing["allocated"] ?? "") != metadata.allocatedBytes
    return InventoryObjectUpsert(id: id, accountingChanged: changed)
}

@discardableResult private func repairInventoryOwner(_ connection: InventoryConnection, object: Int64, generation: Int64) throws -> Int64? {
    let owner = try connection.scalar("SELECT owner_node_id FROM inventory_objects WHERE id=?", [object])
    let ownerExists = owner == 0 ? 0 : try connection.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE id=? AND object_id=?", [owner, object])
    if owner == 0 || ownerExists == 0 {
        let replacement = try connection.scalar("SELECT MIN(id) FROM inventory_nodes WHERE generation_id=? AND object_id=?", [generation, object])
        try connection.write("UPDATE inventory_objects SET owner_node_id=? WHERE id=?", [replacement == 0 ? nil : replacement, object])
        try syncInventoryObjectAccounting(connection, object: object)
        if replacement != 0, let parent = try connection.rows("SELECT parent_id FROM inventory_nodes WHERE id=?", [replacement]).first?["parent_id"].flatMap(Int64.init) {
            return parent
        }
        return nil
    }
    try syncInventoryObjectAccounting(connection, object: object)
    return nil
}

private func syncInventoryObjectAccounting(_ connection: InventoryConnection, object: Int64) throws {
    // Only the owner node carries the object's bytes; every other name for it carries zero. Rows already holding
    // those values are not rewritten, so re-seeing an unchanged file does not run the change-journal trigger.
    guard let values = try connection.rows("SELECT COALESCE(owner_node_id,0) AS owner,logical,allocated FROM inventory_objects WHERE id=?", [object]).first,
          let owner = Int64(values["owner"] ?? ""), let logical = Int64(values["logical"] ?? ""), let allocated = Int64(values["allocated"] ?? "") else { return }
    try connection.write("""
        UPDATE inventory_nodes SET direct_logical=CASE WHEN id=?1 THEN ?2 ELSE 0 END,direct_allocated=CASE WHEN id=?1 THEN ?3 ELSE 0 END,
          total_logical=CASE WHEN id=?1 THEN ?2 ELSE 0 END,total_allocated=CASE WHEN id=?1 THEN ?3 ELSE 0 END
        WHERE object_id=?4 AND kind<>'directory' AND (direct_logical IS NOT CASE WHEN id=?1 THEN ?2 ELSE 0 END OR direct_allocated IS NOT CASE WHEN id=?1 THEN ?3 ELSE 0 END
          OR total_logical IS NOT CASE WHEN id=?1 THEN ?2 ELSE 0 END OR total_allocated IS NOT CASE WHEN id=?1 THEN ?3 ELSE 0 END)
        """, [owner, logical, allocated, object])
}

private func wouldCreateInventoryCycle(_ connection: InventoryConnection, node: Int64, parent: Int64) throws -> Bool {
    try connection.scalar("WITH RECURSIVE ancestors(id) AS (SELECT ? UNION ALL SELECT n.parent_id FROM inventory_nodes n JOIN ancestors a ON n.id=a.id WHERE n.parent_id IS NOT NULL) SELECT COUNT(*) FROM ancestors WHERE id=?", [parent, node]) > 0
}

private func recomputeInventoryAncestors(_ connection: InventoryConnection, from node: Int64, generation: Int64, measuredAt: Double) throws {
    if connection.collectedAggregates != nil {
        connection.collectedAggregates![node] = max(connection.collectedAggregates![node] ?? 0, measuredAt); return
    }
    try recomputeInventoryAggregates(connection, starts: [node: measuredAt], generation: generation)
}

/// Runs `body` with its aggregate recomputes deferred to one pass at the end (same transaction).
/// Listings committed together share ancestors; each ancestor is then recomputed once, not once
/// per listing, which dominated aggregate time during a first pass.
private func coalescingAggregates<T>(_ connection: InventoryConnection, generation: Int64, _ body: () throws -> T) throws -> T {
    connection.collectedAggregates = [:]
    defer { connection.collectedAggregates = nil }
    let value = try body()
    let starts = connection.collectedAggregates ?? [:]
    connection.collectedAggregates = nil
    if !starts.isEmpty { try recomputeInventoryAggregates(connection, starts: starts, generation: generation) }
    return value
}

/// Recomputes every node on the starts' ancestor chains exactly once, deepest first. A directory's
/// values derive only from its children's rows, so the result equals walking each chain in turn.
private func recomputeInventoryAggregates(_ connection: InventoryConnection, starts: [Int64: Double], generation: Int64) throws {
    let profile = InventoryProfile.current, began = DispatchTime.now().uptimeNanoseconds
    profile?.add("aggregate_calls")
    defer { if let profile { profile.nanoseconds["directory_aggregates", default: 0] += DispatchTime.now().uptimeNanoseconds - began } }
    let measuredAt = starts.values.max() ?? Date().timeIntervalSince1970
    var rows = [Int64: [String: String]](), depthOf = [Int64: Int]()
    for start in starts.keys.sorted() where depthOf[start] == nil {
        var chain = [Int64](), current: Int64? = start
        while let id = current, depthOf[id] == nil, chain.count < 1024 {
            guard let row = try connection.rows("SELECT parent_id,object_id,kind,status,reason FROM inventory_nodes WHERE id=? AND generation_id=?", [id, generation]).first else { current = nil; break }
            rows[id] = row; chain.append(id); current = Int64(row["parent_id"] ?? "")
        }
        // Depth below the root (or below where this chain joined one already walked).
        var depth = current.flatMap { depthOf[$0] }.map { $0 + 1 } ?? 0
        for id in chain.reversed() { depthOf[id] = depth; depth += 1 }
    }
    for id in depthOf.keys.sorted(by: { (depthOf[$0]!, $0) > (depthOf[$1]!, $1) }) {
        let started = DispatchTime.now().uptimeNanoseconds
        try recomputeInventoryNode(connection, id: id, row: rows[id]!, generation: generation, measuredAt: measuredAt)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        if seconds >= 0.05 { connection.slowRecomputeSeconds[id] = seconds }
        else if connection.slowRecomputeSeconds[id] != nil { connection.slowRecomputeSeconds[id] = nil }
    }
}

private func recomputeInventoryNode(_ connection: InventoryConnection, id: Int64, row: [String: String], generation: Int64, measuredAt: Double) throws {
    if row["kind"] != "directory" {
        let pruning = try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_prune_jobs WHERE parent_node_id=?)", [id]) > 0
        try connection.write("UPDATE inventory_nodes SET status=?,reason=?,child_count=0,descendant_files=0,descendant_directories=0,descendant_entries=0 WHERE id=?", [pruning ? "stale" : "complete", pruning ? "Previous directory contents are being removed from the index." : nil,id])
        return
    }
    // An unreadable directory is not an empty, fully measured directory. Its own totals
    // remain unknown even while propagating that uncertainty into its ancestors.
    if ["unknown", "inaccessible", "excluded"].contains(row["status"] ?? "") { return }
    let values = try connection.rows("""
        SELECT COUNT(*) AS children,
         COALESCE(SUM(CASE WHEN c.kind='file' THEN CASE WHEN o.owner_node_id=c.id THEN 1 ELSE 0 END ELSE c.descendant_files END),0) AS files,
         COALESCE(SUM(CASE WHEN c.kind='directory' THEN 1+c.descendant_directories ELSE 0 END),0) AS dirs,
         COUNT(*)+COALESCE(SUM(CASE WHEN c.kind='directory' THEN c.descendant_entries ELSE 0 END),0) AS entries,
         COALESCE(SUM(CASE WHEN c.kind<>'directory' THEN COALESCE(c.total_logical,0) ELSE 0 END),0) AS direct_logical,
         COALESCE(SUM(CASE WHEN c.kind<>'directory' THEN COALESCE(c.total_allocated,0) ELSE 0 END),0) AS direct_allocated,
         COALESCE(SUM(CASE WHEN c.kind='directory' THEN COALESCE(c.total_logical,0) ELSE 0 END),0) AS child_logical,
         COALESCE(SUM(CASE WHEN c.kind='directory' THEN COALESCE(c.total_allocated,0) ELSE 0 END),0) AS child_allocated,
         COALESCE(SUM(CASE WHEN c.status='complete' THEN 0 ELSE 1 END),0) AS uncertain
         ,COALESCE(SUM(CASE WHEN c.status='stale' THEN 1 ELSE 0 END),0) AS stale
        FROM inventory_nodes c JOIN inventory_objects o ON o.id=c.object_id WHERE c.parent_id=? AND c.generation_id=?
        """, [id, generation]).first!
    let directLogical = Int64(values["direct_logical"] ?? "0")!
    let directAllocated = Int64(values["direct_allocated"] ?? "0")!
    let uncertain = Int64(values["uncertain"] ?? "0")! > 0
    let unfinished = try connection.scalar("SELECT COUNT(*) FROM inventory_jobs WHERE node_id=? AND state IN ('pending','enumerating')", [id]) > 0
    let pruning = try connection.scalar("SELECT EXISTS(SELECT 1 FROM inventory_prune_jobs WHERE parent_node_id=?)", [id]) > 0
    let refreshing = try unfinished && (connection.scalar("SELECT completed_token>0 OR attempts>0 OR listing_token>1 FROM inventory_jobs WHERE node_id=?", [id])) > 0
    let ownStale = pruning || refreshing, stale = ownStale || Int64(values["stale"] ?? "0")! > 0
    // A folder that is stale only because some descendants are (one deferred cache, say) is a current
    // listing whose total includes earlier sizes; the viewer shows it differently from a stale folder (D11).
    let staleReason = ownStale ? "Deletion or descendant reconciliation is pending; previous totals are stale." : inventoryDescendantStaleReason
    try connection.write("UPDATE inventory_nodes SET direct_logical=?,direct_allocated=?,total_logical=?,total_allocated=?,child_count=?,descendant_files=?,descendant_directories=?,descendant_entries=?,status=?,reason=?,measured_at=? WHERE id=?", [directLogical, directAllocated, directLogical + Int64(values["child_logical"] ?? "0")!, directAllocated + Int64(values["child_allocated"] ?? "0")!, Int64(values["children"] ?? "0")!, Int64(values["files"] ?? "0")!, Int64(values["dirs"] ?? "0")!, Int64(values["entries"] ?? "0")!, stale ? "stale" : (unfinished ? "pending" : (uncertain ? "partial" : "complete")), stale ? staleReason : (uncertain ? "Observed file allocation only; one or more descendants are incomplete. Shared APFS extents may be counted more than once." : nil), measuredAt, id])
}

private func restartInventoryJob(_ connection: InventoryConnection, job: InventoryJob, reason: String) throws {
    let retryProfile = InventoryProfile.current, retryBegan = DispatchTime.now().uptimeNanoseconds
    defer { if let retryProfile { retryProfile.nanoseconds["retry_overhead", default: 0] += DispatchTime.now().uptimeNanoseconds - retryBegan } }
    InventoryProfile.current?.add("listings_retried_changed")
    let now = Date().timeIntervalSince1970
    try connection.transaction {
        try connection.write("UPDATE inventory_jobs SET state='pending',cookie=0,listing_token=listing_token+1,listing_sequence=0,snapshot_device=NULL,snapshot_inode=NULL,snapshot_birth_ns=NULL,snapshot_mtime_ns=NULL,snapshot_ctime_ns=NULL,attempts=attempts+1,reason=?,updated_at=? WHERE node_id=?", [reason, now, job.node])
        try connection.write("UPDATE inventory_nodes SET status='stale',reason=? WHERE id=?", [reason, job.node])
        if let parent = try connection.rows("SELECT parent_id FROM inventory_nodes WHERE id=?", [job.node]).first?["parent_id"].flatMap(Int64.init) {
            try connection.write("INSERT INTO inventory_jobs(node_id,generation_id,state,updated_at) VALUES (?,?,'pending',?) ON CONFLICT(node_id) DO UPDATE SET state='pending',listing_sequence=0,snapshot_device=NULL,updated_at=excluded.updated_at", [parent,job.generation,now])
        }
    }
}

private func finishUnavailableInventoryJob(_ connection: InventoryConnection, job: InventoryJob, reason: String) throws {
    try finishUnavailableInventoryJob(connection, node: job.node, generation: job.generation, reason: reason)
}

func markInventoryIOBlocked(databasePath: String, node: Int64, generation: Int64) throws {
    let connection = try InventoryConnection(databasePath, create: false)
    try finishUnavailableInventoryJob(connection, node: node, generation: generation, reason: "blocked")
}

private func finishUnavailableInventoryJob(_ connection: InventoryConnection, node: Int64, generation: Int64, reason: String) throws {
    InventoryProfile.current?.add("listings_unavailable")
    let now = Date().timeIntervalSince1970
    try connection.transaction {
        try connection.write("UPDATE inventory_jobs SET state='complete',listing_sequence=0,reason=?,updated_at=? WHERE node_id=?", [reason, now, node])
        try connection.write("UPDATE inventory_nodes SET status=?,reason=?,total_logical=NULL,total_allocated=NULL,measured_at=? WHERE id=?", [reason.hasPrefix("filesystem:") || reason == "cloud" || reason == "inventory_metadata" ? "excluded" : "unknown", reason, now, node])
        if let parent = try connection.rows("SELECT parent_id FROM inventory_nodes WHERE id=?", [node]).first?["parent_id"].flatMap(Int64.init) {
            if reason == "absent" || reason == "identity_changed" {
                // A missing/replaced child cannot repair its own namespace identity.
                // Retire its old retry and relist the parent; otherwise repeated
                // descendant retries keep postponing the ancestor that repairs them.
                try connection.write("INSERT INTO inventory_jobs(node_id,generation_id,state,reason,updated_at) VALUES (?,?,'pending',?,?) ON CONFLICT(node_id) DO UPDATE SET state='pending',cookie=0,listing_sequence=0,snapshot_device=NULL,snapshot_inode=NULL,snapshot_birth_ns=NULL,snapshot_mtime_ns=NULL,snapshot_ctime_ns=NULL,reason=excluded.reason,updated_at=excluded.updated_at", [parent,generation,reason == "absent" ? "child absent" : "child identity changed",now])
            }
            try recomputeInventoryAncestors(connection, from: parent, generation: generation, measuredAt: now)
        }
    }
}

func requestInventoryRefresh(databasePath: String, paths: [String], reason: String = "manual refresh", requiredSequence: Int64? = nil, endNodeID: Int64? = nil) throws {
    guard inventorySchemaExists(databasePath: databasePath) else { return }
    try invalidateInventory(databasePath: databasePath, paths: paths, eventID: nil, gap: true, reason: reason, requiredSequence: requiredSequence, endNodeID: endNodeID)
}

func inventoryRequestBoundaryIsCurrent(databasePath: String, boundary: InventoryRequestBoundary) throws -> Bool {
    let connection = try InventoryConnection(databasePath, create: false)
    return try connection.scalar("SELECT COUNT(*) FROM inventory_generations WHERE active=1 AND id=? AND created_at=?", [boundary.generation,boundary.generationCreatedAt]) == 1
}

func loadInventoryEventCursor(databasePath: String, deviceIdentifier: String) throws -> InventoryEventCursor? {
    guard inventorySchemaExists(databasePath: databasePath) else { return nil }
    return try loadInventoryEventCursor(connection: InventoryConnection(databasePath, create: false), deviceIdentifier: deviceIdentifier)
}

private func loadInventoryEventCursor(connection: InventoryConnection, deviceIdentifier: String) throws -> InventoryEventCursor? {
    guard let row = try connection.rows("SELECT event_id,acknowledged_at,boot_session,awake_at FROM inventory_event_cursor WHERE device=?", [deviceIdentifier]).first,
          let event = Int64(row["event_id"] ?? ""), let timestamp = Double(row["acknowledged_at"] ?? "") else { return nil }
    return InventoryEventCursor(eventID: UInt64(bitPattern: event), deviceIdentifier: deviceIdentifier, acknowledgedAt: timestamp,
                                bootSession: row["boot_session"] ?? "", awakeAt: Double(row["awake_at"] ?? "") ?? 0)
}

private func acknowledgeInventoryEventCursor(_ connection: InventoryConnection, device: String, eventID: UInt64, at now: Double) throws {
    let clock = InventoryAwakeClock.current
    try connection.write("INSERT INTO inventory_event_cursor(device,event_id,acknowledged_at,boot_session,awake_at) VALUES (?,?,?,?,?) ON CONFLICT(device) DO UPDATE SET event_id=excluded.event_id,acknowledged_at=excluded.acknowledged_at,boot_session=excluded.boot_session,awake_at=excluded.awake_at",
                         [device, Int64(bitPattern: eventID), now, clock.bootSession, clock.uptime])
}

// A missing FSEvents volume identity is different from a replay gap: repeatedly queuing a full
// reconciliation cannot restore the identity and would keep launchd walking the volume forever.
// These transitions are generation-local and atomic with their one required invalidation.
func noteInventoryEventIdentityUnavailable(databasePath: String, reason: String) throws {
    guard inventorySchemaExists(databasePath: databasePath) else { return }
    let connection = try InventoryConnection(databasePath, create: false)
    let now = Date().timeIntervalSince1970
    try connection.transaction {
        guard let row = try connection.rows("SELECT id,event_availability FROM inventory_generations WHERE active=1 ORDER BY id DESC LIMIT 1").first,
              let generation = Int64(row["id"] ?? ""), row["event_availability"] == "available" else { return }
        try connection.write("UPDATE inventory_generations SET inventory_sequence=inventory_sequence+1 WHERE id=?", [generation])
        let sequence = try connection.scalar("SELECT inventory_sequence FROM inventory_generations WHERE id=?", [generation])
        let end = try connection.scalar("SELECT COALESCE(MAX(id),0) FROM inventory_nodes")
        try connection.write("UPDATE inventory_generations SET event_availability='unavailable_reconciling',event_reason=?,state='building',reason=?,updated_at=? WHERE id=?", [reason,reason,now,generation])
        try connection.write("INSERT INTO inventory_invalidations(generation_id,absolute_path,reason,gap,event_id,created_at,request_sequence,end_node_id) VALUES (?,NULL,?,1,NULL,?,?,?)", [generation,reason,now,sequence,end])
    }
}

@discardableResult
func noteInventoryEventIdentityAvailable(databasePath: String, deviceIdentifier: String, eventID: UInt64, reason: String) throws -> Bool {
    guard inventorySchemaExists(databasePath: databasePath) else { return false }
    let connection = try InventoryConnection(databasePath, create: false)
    let now = Date().timeIntervalSince1970
    return try connection.transaction {
        guard let row = try connection.rows("SELECT id,event_availability FROM inventory_generations WHERE active=1 ORDER BY id DESC LIMIT 1").first,
              let generation = Int64(row["id"] ?? ""), row["event_availability"] != "available" else { return false }
        try connection.write("UPDATE inventory_generations SET inventory_sequence=inventory_sequence+1 WHERE id=?", [generation])
        let sequence = try connection.scalar("SELECT inventory_sequence FROM inventory_generations WHERE id=?", [generation])
        let end = try connection.scalar("SELECT COALESCE(MAX(id),0) FROM inventory_nodes")
        // No trustworthy cursor spans the identity outage. Reconcile once from the durable
        // inventory and establish the new cursor in the same commit.
        try connection.write("UPDATE inventory_generations SET event_availability='available',event_reason=NULL,state='building',reason=?,updated_at=? WHERE id=?", [reason,now,generation])
        try connection.write("INSERT INTO inventory_invalidations(generation_id,absolute_path,reason,gap,event_id,created_at,request_sequence,end_node_id) VALUES (?,NULL,?,1,?,?,?,?)", [generation,reason,Int64(bitPattern: eventID),now,sequence,end])
        try acknowledgeInventoryEventCursor(connection, device: deviceIdentifier, eventID: eventID, at: now)
        return true
    }
}

func invalidateInventory(databasePath: String, paths: [String], eventID: UInt64?, gap: Bool, reason: String, deviceIdentifier: String = "default", requiredSequence: Int64? = nil, endNodeID: Int64? = nil) throws {
    guard inventorySchemaExists(databasePath: databasePath) else { return }
    let connection = try InventoryConnection(databasePath, create: false)
    let now = Date().timeIntervalSince1970
    try connection.transaction {
        try adoptLegacyInventoryRequests(connection)
        let generation = try connection.scalar("SELECT id FROM inventory_generations WHERE active=1 ORDER BY id DESC LIMIT 1")
        guard generation != 0 else { return }
        let sequence: Int64
        if let requiredSequence {
            try connection.write("UPDATE inventory_generations SET inventory_sequence=MAX(inventory_sequence,?) WHERE id=?", [requiredSequence,generation])
            sequence = requiredSequence
        } else {
            try connection.write("UPDATE inventory_generations SET inventory_sequence=inventory_sequence+1 WHERE id=?", [generation])
            sequence = try connection.scalar("SELECT inventory_sequence FROM inventory_generations WHERE id=?", [generation])
        }
        let boundary: Int64
        if gap { boundary = try endNodeID ?? connection.scalar("SELECT COALESCE(MAX(id),0) FROM inventory_nodes") }
        else { boundary = 0 }
        let operational = try connection.rows("SELECT operational_path FROM inventory_generations WHERE id=?", [generation]).first?["operational_path"]
        for path in paths.prefix(4_096) {
            if let operational, path == operational || path.hasPrefix(operational + "/") { continue }
            try connection.write("INSERT INTO inventory_invalidations(generation_id,absolute_path,reason,gap,event_id,created_at,request_sequence,end_node_id) VALUES (?,?,?,?,?,?,?,?)", [generation, path, reason, gap ? 1 : 0, eventID.map { Int64(bitPattern: $0) }, now, sequence, boundary])
        }
        if (gap && paths.isEmpty) || paths.count > 4_096 { try connection.write("INSERT INTO inventory_invalidations(generation_id,absolute_path,reason,gap,event_id,created_at,request_sequence,end_node_id) VALUES (?,NULL,?,1,?,?,?,?)", [generation, paths.count > 4_096 ? "Invalidation path limit exceeded; full reconciliation required" : reason, eventID.map { Int64(bitPattern: $0) }, now, sequence, boundary]) }
        if let eventID { try acknowledgeInventoryEventCursor(connection, device: deviceIdentifier, eventID: eventID, at: now) }
    }
}

private func applyInventoryInvalidations(_ connection: InventoryConnection, generation: Int64, rootNode: Int64, rootPath: String, limit: Int = 256) throws {
    let profile = InventoryProfile.current, began = DispatchTime.now().uptimeNanoseconds
    defer { if let profile { profile.nanoseconds["invalidation_application", default: 0] += DispatchTime.now().uptimeNanoseconds - began } }
    let invalidations = try connection.rows("SELECT id,absolute_path,reason,gap,request_sequence,end_node_id FROM inventory_invalidations WHERE generation_id=? ORDER BY id LIMIT ?", [generation,limit])
    guard !invalidations.isEmpty else { return }
    let now = Date().timeIntervalSince1970
    try connection.transaction {
        for item in invalidations {
            profile?.add("invalidations_applied")
            let gap = item["gap"] == "1", reason = item["reason"] ?? "changed"
            let sequence = Int64(item["request_sequence"] ?? "0") ?? 0
            let absolute = item["absolute_path"]
            let match = absolute.flatMap { inventoryNodeForPath(connection, generation: generation, root: rootPath, absolute: $0) }
            let target = match?.node ?? rootNode
            let kind = try connection.rows("SELECT kind,parent_id FROM inventory_nodes WHERE id=?", [target]).first
            let node = match?.exact == true && kind?["kind"] != "directory" ? (Int64(kind?["parent_id"] ?? "") ?? target) : target
            let alreadyCovered = sequence > 0 ? try connection.scalar("SELECT COUNT(*) FROM inventory_jobs WHERE node_id=? AND state='complete' AND reason IS NULL AND completed_sequence>=?", [node,sequence]) > 0 : false
            if alreadyCovered { profile?.add("jobs_skipped_satisfied") }
            if !alreadyCovered {
                // Only a measured folder becomes "previously measured". A never-listed, unreadable or
                // excluded folder keeps its honest status and reason; its listing simply runs again.
                try connection.write("UPDATE inventory_nodes SET status=CASE WHEN status IN ('unknown','excluded','pending') THEN status ELSE 'stale' END,reason=CASE WHEN status IN ('unknown','excluded','pending') THEN reason ELSE ? END WHERE id=?", [reason, node])
                // A selected-folder refresh uses the existing indexed FIFO queue's
                // head, without creating another scanner or a new scheduling loop.
                // Bounded postponement: further activity never moves an already queued folder back in
                // the FIFO queue, so a folder that changes all the time still reaches its first
                // listing. A deferred folder keeps its marker until that listing runs.
                try connection.write("INSERT INTO inventory_jobs(node_id,generation_id,state,reason,updated_at) VALUES (?,?,'pending',?,?) ON CONFLICT(node_id) DO UPDATE SET state='pending',cookie=0,listing_sequence=0,snapshot_device=NULL,snapshot_inode=NULL,snapshot_birth_ns=NULL,snapshot_mtime_ns=NULL,snapshot_ctime_ns=NULL,reason=CASE WHEN inventory_jobs.state IN ('pending','enumerating') AND inventory_jobs.reason=? THEN inventory_jobs.reason ELSE excluded.reason END,updated_at=CASE WHEN inventory_jobs.state IN ('pending','enumerating') THEN MIN(inventory_jobs.updated_at,excluded.updated_at) ELSE excluded.updated_at END", [node, generation, reason, reason == "manual refresh" ? 0.0 : now, inventoryDeferredReason])
            }
            if gap {
                // A second history gap can affect directories already reconciled by
                // the first pass. Restart its durable frontier rather than certifying
                // the previously visited prefix with an older event boundary.
                let storedEnd = Int64(item["end_node_id"] ?? "0") ?? 0
                let end = storedEnd > 0 ? storedEnd : try connection.scalar("SELECT COALESCE(MAX(id),0) FROM inventory_nodes")
                try connection.write("""
                    INSERT INTO inventory_reconcile(root_node_id,generation_id,reason,created_at,end_node_id,request_sequence)
                    VALUES (?,?,?,?,?,?) ON CONFLICT(root_node_id) DO UPDATE SET
                      last_node_id=CASE WHEN excluded.request_sequence>inventory_reconcile.request_sequence THEN 0 ELSE inventory_reconcile.last_node_id END,
                      end_node_id=MAX(inventory_reconcile.end_node_id,excluded.end_node_id),
                      request_sequence=MAX(inventory_reconcile.request_sequence,excluded.request_sequence),
                      reason=CASE WHEN excluded.request_sequence>=inventory_reconcile.request_sequence THEN excluded.reason ELSE inventory_reconcile.reason END,
                      created_at=CASE WHEN excluded.request_sequence>=inventory_reconcile.request_sequence THEN excluded.created_at ELSE inventory_reconcile.created_at END
                    """, [target, generation, reason, now, end, sequence])
            }
            try connection.write("DELETE FROM inventory_invalidations WHERE id=?", [Int64(item["id"]!)!])
        }
    }
}

private func inventoryNodeForPath(_ connection: InventoryConnection, generation: Int64, root: String, absolute: String) -> (node: Int64, exact: Bool)? {
    var path = absolute
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    // Scoped inventories store their canonical Data-volume path, while callers may receive the
    // equivalent firmlinked display spelling (for example /private instead of /System/Volumes/Data/private).
    if path != root && !path.hasPrefix(root + "/"),
       let rootRelative = dataRelative(root), let pathRelative = dataRelative(path),
       pathRelative == rootRelative || pathRelative.hasPrefix(rootRelative + "/") {
        path = dataVolumeMount + "/" + pathRelative
    }
    guard path == root || path.hasPrefix(root + "/") else { return nil }
    let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
    var node = (try? connection.scalar("SELECT id FROM inventory_nodes WHERE generation_id=? AND parent_id IS NULL", [generation])) ?? 0
    for component in relative.split(separator: "/").map(String.init) {
        guard let child = try? connection.scalar("SELECT id FROM inventory_nodes WHERE generation_id=? AND parent_id=? AND name=?", [generation, node, component]), child != 0 else { return node == 0 ? nil : (node, false) }
        node = child
    }
    return node == 0 ? nil : (node, true)
}

private func expandInventoryReconcile(_ connection: InventoryConnection, generation: Int64, limit: Int) throws {
    let profile = InventoryProfile.current
    guard let reconcile = try connection.rows("SELECT root_node_id,reason,last_node_id,end_node_id,request_sequence FROM inventory_reconcile WHERE generation_id=? ORDER BY created_at LIMIT 1", [generation]).first else { return }
    let root = Int64(reconcile["root_node_id"]!)!, last = Int64(reconcile["last_node_id"] ?? "0") ?? 0
    var end = Int64(reconcile["end_node_id"] ?? "0") ?? 0
    let reason = reconcile["reason"] ?? "event history gap", requestSequence = Int64(reconcile["request_sequence"] ?? "0") ?? 0, now = Date().timeIntervalSince1970
    if end == 0 {
        // SQL fixtures and interrupted pre-horizon builds may omit the new field.
        // Capture a finite conservative boundary before discovering candidates.
        end = try connection.scalar("SELECT COALESCE(MAX(id),0) FROM inventory_nodes")
        try connection.write("UPDATE inventory_reconcile SET end_node_id=? WHERE root_node_id=? AND end_node_id=0", [end,root])
    }
    let fullRoot = try connection.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE id=? AND parent_id IS NULL", [root]) == 1
    // Candidate discovery is outside the writer transaction. Full-volume gaps use an indexed
    // monotonically advancing range; completed jobs are never rediscovered in the same pass.
    let candidates: [[String:String]]
    if fullRoot {
        candidates = try connection.rows("SELECT id FROM inventory_nodes WHERE generation_id=? AND kind='directory' AND id>? AND id<=? ORDER BY id LIMIT ?", [generation,last,end,limit])
    } else {
        candidates = try connection.rows("SELECT n.id,EXISTS(WITH RECURSIVE chain(id,parent_id) AS (SELECT n.id,n.parent_id UNION ALL SELECT p.id,p.parent_id FROM inventory_nodes p JOIN chain c ON c.parent_id=p.id) SELECT 1 FROM chain WHERE id=?) AS included FROM (SELECT id,parent_id FROM inventory_nodes WHERE generation_id=? AND kind='directory' AND id>? AND id<=? ORDER BY id LIMIT ?) n", [root,generation,last,end,limit])
    }
    try connection.transaction {
        guard try connection.scalar("SELECT COUNT(*) FROM inventory_reconcile WHERE root_node_id=? AND generation_id=? AND last_node_id=? AND end_node_id=? AND request_sequence=?", [root,generation,last,end,requestSequence]) > 0 else { return }
        for row in candidates {
            if !fullRoot && row["included"] != "1" { continue }
            let id = Int64(row["id"]!)!
            profile?.add("refresh_candidates_checked")
            if requestSequence > 0, try connection.scalar("SELECT COUNT(*) FROM inventory_jobs WHERE node_id=? AND state='complete' AND reason IS NULL AND completed_sequence>=?", [id,requestSequence]) > 0 { profile?.add("jobs_skipped_satisfied"); continue }
            try connection.write("UPDATE inventory_nodes SET status='stale',reason=? WHERE id=?", [reason,id])
            try connection.write("INSERT INTO inventory_jobs(node_id,generation_id,state,reason,updated_at) VALUES (?,?,'pending',?,?) ON CONFLICT(node_id) DO UPDATE SET state='pending',listing_sequence=0,snapshot_device=NULL,reason=excluded.reason,updated_at=CASE WHEN inventory_jobs.updated_at=0 THEN 0 ELSE excluded.updated_at END", [id,generation,reason,now])
        }
        if let maximum = candidates.compactMap({ Int64($0["id"] ?? "") }).max() {
            try connection.write("UPDATE inventory_reconcile SET last_node_id=? WHERE root_node_id=?", [maximum,root])
        } else { try connection.write("DELETE FROM inventory_reconcile WHERE root_node_id=?", [root]) }
    }
}

// Pruning is two-phase so a directory rename can be observed at its new parent before the old
// namespace entry is removed. Discovery and leaf deletion are each capped at 256 rows per short
// transaction; no cascading deletion of a large subtree is issued.
private func removeInventoryClaim(_ connection: InventoryConnection, epoch: Int64, node: Int64) throws {
    try connection.write("DELETE FROM inventory_tombstone_claims WHERE cleanup_epoch=? AND node_id=?", [epoch,node])
    try connection.write("DELETE FROM inventory_tombstones WHERE node_id=? AND NOT EXISTS(SELECT 1 FROM inventory_tombstone_claims WHERE node_id=?)", [node,node])
}

// CROSS JOIN keeps the short ancestor chain outer. Left to the planner, SQLite scanned all of
// inventory_jobs per claim (0.34 s at 480,000 jobs), and cleanup consumed whole worker slices.
let inventoryNewerObservationSQL = "WITH RECURSIVE chain(id,parent_id) AS (SELECT id,parent_id FROM inventory_nodes WHERE id=? UNION ALL SELECT n.id,n.parent_id FROM inventory_nodes n JOIN chain c ON c.parent_id=n.id WHERE c.id<>?) SELECT COUNT(*) FROM chain CROSS JOIN inventory_jobs j ON j.node_id=chain.id WHERE j.state='complete' AND j.reason IS NULL AND j.completed_sequence>?"

private func inventoryClaimIsAuthoritative(_ connection: InventoryConnection, epoch: Int64, node: Int64, root: Int64, parent: Int64, generation: Int64) throws -> Bool {
    guard let authority = try connection.rows("SELECT seen_token,authority_kind,authority_object_id,authority_sequence FROM inventory_prune_jobs WHERE parent_node_id=? AND generation_id=? AND cleanup_epoch=?", [parent,generation,epoch]).first else { return false }
    let kind = authority["authority_kind"] ?? "legacy", token = Int64(authority["seen_token"] ?? "0") ?? 0
    let sequence = Int64(authority["authority_sequence"] ?? "0") ?? 0
    if kind == "listing" {
        guard try connection.scalar("SELECT COUNT(*) FROM inventory_jobs WHERE node_id=? AND state='complete' AND reason IS NULL AND completed_token=? AND listing_token=?", [parent,token,token]) > 0,
              try connection.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE id=? AND parent_id=? AND seen_token<>?", [root,parent,token]) > 0 else { return false }
    } else if kind == "replacement", let object = Int64(authority["authority_object_id"] ?? "") {
        guard try connection.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE id=? AND object_id=? AND kind<>'directory'", [parent,object]) > 0,
              try connection.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE id=? AND parent_id=?", [root,parent]) > 0 else { return false }
    } else { return false }
    // A moved descendant is no longer within the obsolete root. A successful newer
    // own listing anywhere on the chain is also stronger evidence than this cleanup.
    let membership = try connection.scalar("WITH RECURSIVE chain(id,parent_id) AS (SELECT id,parent_id FROM inventory_nodes WHERE id=? UNION ALL SELECT n.id,n.parent_id FROM inventory_nodes n JOIN chain c ON c.parent_id=n.id) SELECT COUNT(*) FROM chain WHERE id=?", [node,root]) > 0
    guard membership else { return false }
    let newer = try connection.scalar(inventoryNewerObservationSQL, [node,root,sequence])
    if newer > 0 {
        // Presence observed after the absence listing invalidates this origin.
        // Reobserve its parent before certifying the namespace or its totals.
        try connection.write("DELETE FROM inventory_prune_jobs WHERE parent_node_id=? AND cleanup_epoch=?", [parent,epoch])
        let containing = try connection.rows("SELECT parent_id FROM inventory_nodes WHERE id=?", [parent]).first?["parent_id"].flatMap(Int64.init)
        let repairNode = kind == "replacement" ? containing : parent
        try connection.write("UPDATE inventory_nodes SET status='stale',reason='Newer descendant observation requires parent repair' WHERE id=?", [parent])
        if let repairNode {
            try connection.write("UPDATE inventory_jobs SET state='pending',listing_sequence=0,snapshot_device=NULL,reason='Newer descendant observation requires parent repair',updated_at=? WHERE node_id=?", [Date().timeIntervalSince1970,repairNode])
            try connection.write("UPDATE inventory_nodes SET status='stale',reason='Newer descendant observation requires parent repair' WHERE id=?", [repairNode])
            if let ancestor = try connection.rows("SELECT parent_id FROM inventory_nodes WHERE id=?", [repairNode]).first?["parent_id"].flatMap(Int64.init) {
                try recomputeInventoryAncestors(connection, from: ancestor, generation: generation, measuredAt: Date().timeIntervalSince1970)
            }
        }
        return false
    }
    return true
}

private func processInventoryTombstones(_ connection: InventoryConnection, generation: Int64, limit: Int, parentFilter: Int64? = nil) throws -> Bool {
    let profile = InventoryProfile.current, began = DispatchTime.now().uptimeNanoseconds
    profile?.add("cleanup_steps")
    defer { if let profile { profile.nanoseconds["cleanup_execution", default: 0] += DispatchTime.now().uptimeNanoseconds - began } }
    let filter = parentFilter == nil ? "" : " AND parent_node_id=?"
    let filterValues: [Any?] = parentFilter.map { [$0] } ?? []
    // Legacy tombstones have no immutable origin. Never delete their nodes; retire a
    // bounded page and schedule their current parents for observation instead.
    let legacy = try connection.rows("SELECT t.node_id,n.parent_id FROM inventory_tombstones t LEFT JOIN inventory_nodes n ON n.id=t.node_id WHERE t.generation_id=? AND NOT EXISTS(SELECT 1 FROM inventory_tombstone_claims c WHERE c.node_id=t.node_id) LIMIT ?", [generation,limit])
    if !legacy.isEmpty {
        try connection.transaction {
            let now = Date().timeIntervalSince1970
            for row in legacy {
                let node = Int64(row["node_id"]!)!
                if let parent = row["parent_id"].flatMap(Int64.init) {
                    try connection.write("INSERT INTO inventory_jobs(node_id,generation_id,state,updated_at) VALUES (?,?,'pending',?) ON CONFLICT(node_id) DO UPDATE SET state='pending',listing_sequence=0,snapshot_device=NULL,updated_at=excluded.updated_at", [parent,generation,now])
                }
                try connection.write("DELETE FROM inventory_tombstones WHERE node_id=?", [node])
            }
        }
        return true
    }
    // Adopt only locally provable legacy markers. A mismatched completed token is the
    // stale-marker case: retire it without touching namespace rows.
    if let legacyPrune = try connection.rows("SELECT parent_node_id,seen_token FROM inventory_prune_jobs WHERE generation_id=? AND cleanup_epoch=0\(filter) ORDER BY created_at LIMIT 1", [generation] + filterValues).first {
        let parent = Int64(legacyPrune["parent_node_id"]!)!, token = Int64(legacyPrune["seen_token"]!)!
        try connection.transaction {
            guard try connection.scalar("SELECT COUNT(*) FROM inventory_prune_jobs WHERE parent_node_id=? AND cleanup_epoch=0 AND seen_token=?", [parent,token]) > 0 else { return }

            let epoch = try nextInventoryCleanupEpoch(connection, generation: generation)
            if token >= 0, try connection.scalar("SELECT COUNT(*) FROM inventory_jobs WHERE node_id=? AND state='complete' AND reason IS NULL AND listing_token=?", [parent,token]) > 0 {
                try connection.write("UPDATE inventory_jobs SET completed_token=CASE WHEN completed_token=0 THEN listing_token ELSE completed_token END WHERE node_id=?", [parent])
                let sequence = try connection.scalar("SELECT completed_sequence FROM inventory_jobs WHERE node_id=?", [parent])
                try connection.write("UPDATE inventory_prune_jobs SET cleanup_epoch=?,authority_kind='listing',authority_object_id=NULL,authority_sequence=? WHERE parent_node_id=? AND cleanup_epoch=0", [epoch,sequence,parent])
            } else if token == -1, let row = try connection.rows("SELECT object_id FROM inventory_nodes WHERE id=? AND kind<>'directory'", [parent]).first, let object = Int64(row["object_id"] ?? "") {
                try connection.write("UPDATE inventory_prune_jobs SET cleanup_epoch=?,authority_kind='replacement',authority_object_id=?,authority_sequence=0 WHERE parent_node_id=? AND cleanup_epoch=0", [epoch,object,parent])
            } else {
                try connection.write("DELETE FROM inventory_prune_jobs WHERE parent_node_id=? AND cleanup_epoch=0", [parent])
                try recomputeInventoryAncestors(connection, from: parent, generation: generation, measuredAt: Date().timeIntervalSince1970)
            }
        }
        return true
    }
    let orphans = try connection.rows("SELECT c.cleanup_epoch,c.node_id FROM inventory_tombstone_claims c LEFT JOIN inventory_prune_jobs p ON p.parent_node_id=c.parent_node_id AND p.cleanup_epoch=c.cleanup_epoch WHERE c.generation_id=? AND p.parent_node_id IS NULL LIMIT ?", [generation,limit])
    if !orphans.isEmpty {
        try connection.transaction {
            for row in orphans { try removeInventoryClaim(connection, epoch: Int64(row["cleanup_epoch"]!)!, node: Int64(row["node_id"]!)!) }
        }
        return true
    }
    if let prune = try connection.rows("SELECT parent_node_id,seen_token,last_node_id,cleanup_epoch FROM inventory_prune_jobs WHERE generation_id=? AND cleanup_epoch>0 AND last_node_id>=0\(filter) ORDER BY created_at LIMIT 1", [generation] + filterValues).first {
        let parent = Int64(prune["parent_node_id"]!)!, token = Int64(prune["seen_token"]!)!, last = Int64(prune["last_node_id"]!)!, epoch = Int64(prune["cleanup_epoch"]!)!
        try connection.transaction {
            guard try connection.scalar("SELECT COUNT(*) FROM inventory_prune_jobs WHERE parent_node_id=? AND cleanup_epoch=?", [parent,epoch]) > 0 else { return }
            let authoritative = try connection.scalar("SELECT COUNT(*) FROM inventory_prune_jobs p JOIN inventory_nodes n ON n.id=p.parent_node_id LEFT JOIN inventory_jobs j ON j.node_id=p.parent_node_id WHERE p.parent_node_id=? AND p.cleanup_epoch=? AND ((p.authority_kind='listing' AND j.state='complete' AND j.reason IS NULL AND j.completed_token=p.seen_token AND j.listing_token=p.seen_token) OR (p.authority_kind='replacement' AND n.kind<>'directory' AND n.object_id=p.authority_object_id))", [parent,epoch]) > 0
            guard authoritative else {
                try connection.write("DELETE FROM inventory_prune_jobs WHERE parent_node_id=? AND cleanup_epoch=?", [parent,epoch])
                return
            }
            let nodes = try connection.rows("SELECT id FROM inventory_nodes WHERE generation_id=? AND parent_id=? AND seen_token<>? AND id>? ORDER BY id LIMIT ?", [generation,parent,token,last,limit]).compactMap { Int64($0["id"] ?? "") }
            let now = Date().timeIntervalSince1970
            for node in nodes {
                try connection.write("INSERT OR IGNORE INTO inventory_tombstone_claims(cleanup_epoch,node_id,root_node_id,parent_node_id,generation_id,created_at) VALUES (?,?,?,?,?,?)", [epoch,node,node,parent,generation,now])
                try connection.write("INSERT OR IGNORE INTO inventory_tombstones(node_id,generation_id,created_at) VALUES (?,?,?)", [node,generation,now])
            }
            if let maximum = nodes.max() { try connection.write("UPDATE inventory_prune_jobs SET last_node_id=? WHERE parent_node_id=? AND cleanup_epoch=?", [maximum,parent,epoch]) }
            else { try connection.write("UPDATE inventory_prune_jobs SET last_node_id=-1 WHERE parent_node_id=? AND cleanup_epoch=?", [parent,epoch]) }
        }
        return true
    }
    let leaves = try connection.rows("SELECT c.cleanup_epoch,c.node_id,c.root_node_id,c.parent_node_id,n.object_id,n.parent_id FROM inventory_tombstone_claims c JOIN inventory_nodes n ON n.id=c.node_id WHERE c.generation_id=? AND NOT EXISTS(SELECT 1 FROM inventory_nodes child WHERE child.parent_id=n.id) ORDER BY c.node_id LIMIT ?", [generation,limit])
    if !leaves.isEmpty {
        try connection.transaction {
            // Event evidence committed before this deletion transaction has priority.
            // The worker will apply it on the next outer iteration.
            guard try connection.scalar("SELECT COUNT(*) FROM inventory_invalidations WHERE generation_id=?", [generation]) == 0 else { return }
            var repaired = Set<Int64>(), parents = Set<Int64>()
            for row in leaves {
                let epoch = Int64(row["cleanup_epoch"]!)!, node = Int64(row["node_id"]!)!, root = Int64(row["root_node_id"]!)!, parent = Int64(row["parent_node_id"]!)!
                guard let current = try connection.rows("SELECT object_id,parent_id FROM inventory_nodes WHERE id=? AND NOT EXISTS(SELECT 1 FROM inventory_nodes child WHERE child.parent_id=inventory_nodes.id)", [node]).first else { continue }
                guard try inventoryClaimIsAuthoritative(connection, epoch: epoch, node: node, root: root, parent: parent, generation: generation) else { try removeInventoryClaim(connection, epoch: epoch, node: node); continue }
                if let object = Int64(current["object_id"] ?? "") { repaired.insert(object) }
                if let currentParent = Int64(current["parent_id"] ?? "") { parents.insert(currentParent) }
                try connection.write("DELETE FROM inventory_nodes WHERE id=?", [node])
                profile?.add("entries_pruned_committed")
            }
            for object in repaired { if let parent = try repairInventoryOwner(connection, object: object, generation: generation) { parents.insert(parent) } }
            for parent in parents where try connection.scalar("SELECT COUNT(*) FROM inventory_nodes WHERE id=?", [parent]) > 0 { try recomputeInventoryAncestors(connection, from: parent, generation: generation, measuredAt: Date().timeIntervalSince1970) }
        }
        return true
    }
    if let frontier = try connection.rows("SELECT c.cleanup_epoch,c.node_id,c.root_node_id,c.parent_node_id FROM inventory_tombstone_claims c WHERE c.generation_id=? AND EXISTS(SELECT 1 FROM inventory_nodes n WHERE n.parent_id=c.node_id AND NOT EXISTS(SELECT 1 FROM inventory_tombstone_claims queued WHERE queued.cleanup_epoch=c.cleanup_epoch AND queued.node_id=n.id)) ORDER BY c.created_at DESC,c.node_id DESC LIMIT 1", [generation]).first {
        let epoch = Int64(frontier["cleanup_epoch"]!)!, node = Int64(frontier["node_id"]!)!, root = Int64(frontier["root_node_id"]!)!, parent = Int64(frontier["parent_node_id"]!)!
        try connection.transaction {
            guard try inventoryClaimIsAuthoritative(connection, epoch: epoch, node: node, root: root, parent: parent, generation: generation) else { try removeInventoryClaim(connection, epoch: epoch, node: node); return }
            let children = try connection.rows("SELECT id FROM inventory_nodes n WHERE parent_id=? AND NOT EXISTS(SELECT 1 FROM inventory_tombstone_claims queued WHERE queued.cleanup_epoch=? AND queued.node_id=n.id) ORDER BY id LIMIT ?", [node,epoch,limit]).compactMap { Int64($0["id"] ?? "") }
            let now = Date().timeIntervalSince1970
            for child in children {
                try connection.write("INSERT OR IGNORE INTO inventory_tombstone_claims(cleanup_epoch,node_id,root_node_id,parent_node_id,generation_id,created_at) VALUES (?,?,?,?,?,?)", [epoch,child,root,parent,generation,now])
                try connection.write("INSERT OR IGNORE INTO inventory_tombstones(node_id,generation_id,created_at) VALUES (?,?,?)", [child,generation,now])
            }
        }
        return true
    }
    let completed = try connection.rows("SELECT p.parent_node_id,p.cleanup_epoch FROM inventory_prune_jobs p WHERE p.generation_id=? AND p.last_node_id=-1\(filter) AND NOT EXISTS(SELECT 1 FROM inventory_tombstone_claims c WHERE c.cleanup_epoch=p.cleanup_epoch) LIMIT ?", [generation] + filterValues + [limit]).compactMap { row -> (Int64,Int64)? in
        guard let parent = Int64(row["parent_node_id"] ?? ""), let epoch = Int64(row["cleanup_epoch"] ?? "") else { return nil }; return (parent,epoch)
    }
    guard !completed.isEmpty else { return false }
    try connection.transaction {
        for (parent,epoch) in completed {
            try connection.write("DELETE FROM inventory_prune_jobs WHERE parent_node_id=? AND cleanup_epoch=?", [parent,epoch])
            try recomputeInventoryAncestors(connection, from: parent, generation: generation, measuredAt: Date().timeIntervalSince1970)
        }
    }
    return true
}

// One bounded SQL-only maintenance step. Tests and offline verification use the
// optional parent filter to exercise a preserved cleanup authority without walking
// unrelated filesystem jobs or cleanup markers.
func inventoryMaintenanceStep(databasePath: String, generation: Int64, parentNode: Int64? = nil, limit: Int = 256) throws -> Bool {
    let connection = try InventoryConnection(databasePath, create: false)
    return try processInventoryTombstones(connection, generation: generation, limit: min(256,max(1,limit)), parentFilter: parentNode)
}

func inventoryNeedsWork(databasePath: String) -> Bool {
    guard inventorySchemaExists(databasePath: databasePath), let connection = try? InventoryConnection(databasePath, create: false) else { return false }
    guard let generation = try? connection.scalar("SELECT id FROM inventory_generations WHERE active=1"), generation != 0 else { return false }
    return ((try? connection.scalar("SELECT COUNT(*) FROM inventory_jobs WHERE generation_id=? AND state IN ('pending','enumerating')", [generation])) ?? 0) > 0 || ((try? connection.scalar("SELECT COUNT(*) FROM inventory_invalidations WHERE generation_id=?", [generation])) ?? 0) > 0 || ((try? connection.scalar("SELECT COUNT(*) FROM inventory_reconcile WHERE generation_id=?", [generation])) ?? 0) > 0 || ((try? connection.scalar("SELECT (SELECT COUNT(*) FROM inventory_tombstones WHERE generation_id=?)+(SELECT COUNT(*) FROM inventory_prune_jobs WHERE generation_id=?)", [generation,generation])) ?? 0) > 0
}

private func inventorySchemaExists(databasePath: String) -> Bool {
    guard FileManager.default.fileExists(atPath: databasePath) else { return false }
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return false }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='inventory_generations'", -1, &statement, nil) == SQLITE_OK else { return false }
    return sqlite3_step(statement) == SQLITE_ROW
}

func cancelInventory(directory: URL) throws {
    let path = directory.appendingPathComponent("inventory.cancel")
    try Data("cancel\n".utf8).write(to: path, options: .atomic)
    _ = chmod(path.path, 0o600)
}
