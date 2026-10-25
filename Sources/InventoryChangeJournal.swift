import Foundation

// Durable change journal for incremental viewers (the Living Filesystem foundation).
//
// Triggers on the catalog tables record, in the writer's own transaction, which directories'
// listings changed. Every write path that touches `inventory_nodes` is covered without being
// edited: listings, moves, aggregate recomputes, leaf-up deletions, unavailable folders and
// invalidation marks. A rolled-back transaction rolls its journal rows back with it.
//
// One row per directory, carrying the sequence of its latest change, so a reader never sees a
// directory twice in one read and the journal's size is bounded by the number of directories.
// A single-row clock holds the sequence, the retention floor and a journal identity that changes
// if the journal is ever recreated. Readers whose cursor predates the floor must resynchronize.
//
// Size signals compare two settled measurements of one node (`complete` or `partial`, with a
// value) taken after the generation's first pass. A measurement in progress is never compared.
// They describe indexed allocated bytes, never reclaimed or consumed physical space.

/// Bump when trigger or table definitions change; installed triggers are then replaced atomically.
let inventoryChangeJournalVersion: Int64 = 1

struct InventoryChangeJournalRetention {
    /// Directories kept in the journal. A reader further behind must resynchronize its visible branches.
    var directories: Int64 = 65_536
    /// Size-signal rows kept (pending baselines included).
    var signals: Int64 = 65_536
    /// Rows deleted per pruning transaction.
    var batch: Int64 = 16_384
}

let inventoryChangeJournalSchemaSQL = """
    CREATE TABLE IF NOT EXISTS inventory_change_clock (
      id INTEGER PRIMARY KEY CHECK (id=1), journal_id TEXT NOT NULL, version INTEGER NOT NULL,
      sequence INTEGER NOT NULL DEFAULT 0, retained_after INTEGER NOT NULL DEFAULT 0,
      signals_retained_after INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
      signals_generation INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS inventory_changed_directories (
      directory_id INTEGER PRIMARY KEY, generation_id INTEGER NOT NULL,
      sequence INTEGER NOT NULL, subtree_sequence INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS inventory_changed_directories_sequence ON inventory_changed_directories(sequence);
    CREATE TABLE IF NOT EXISTS inventory_size_signals (
      node_id INTEGER PRIMARY KEY, generation_id INTEGER NOT NULL, sequence INTEGER NOT NULL,
      baseline_allocated INTEGER, baseline_status TEXT, baseline_measured_at REAL,
      previous_allocated INTEGER, previous_status TEXT, previous_measured_at REAL,
      allocated INTEGER, status TEXT, measured_at REAL
    );
    CREATE INDEX IF NOT EXISTS inventory_size_signals_sequence ON inventory_size_signals(sequence);
    """

private let bump = "UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1;"

/// Records that `directory`'s listing changed (its children, or its own row).
private func listing(_ directory: String, _ generation: String) -> String {
    "INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence) SELECT \(directory),\(generation),sequence FROM inventory_change_clock WHERE id=1 AND (\(directory)) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;"
}

/// Records that state derived along `directory`'s chain changed for its whole subtree (staleness
/// from reconciliation, pruning or tombstones; paths after a directory move or rename).
private func subtree(_ directory: String, _ generation: String) -> String {
    "INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence,subtree_sequence) SELECT \(directory),\(generation),sequence,sequence FROM inventory_change_clock WHERE id=1 AND (\(directory)) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,subtree_sequence=excluded.subtree_sequence;"
}

private func settled(_ row: String) -> String { "(\(row).status IN ('complete','partial') AND \(row).total_allocated IS NOT NULL)" }
// Signals compare measurements only in the generation whose first pass completed. The worker copies that
// generation into the clock (`signals_generation`) when it records completion, so the triggers depend on no
// other table's schema.

/// Keeps the clock's signal generation equal to the active generation whose first pass is complete (0: none).
let inventorySignalGenerationSyncSQL = "UPDATE inventory_change_clock SET signals_generation=COALESCE((SELECT id FROM inventory_generations WHERE active=1 AND initial_completion='complete' ORDER BY id DESC LIMIT 1),0) WHERE id=1 AND signals_generation IS NOT COALESCE((SELECT id FROM inventory_generations WHERE active=1 AND initial_completion='complete' ORDER BY id DESC LIMIT 1),0)"
/// Node columns a viewer displays. `measured_at` is deliberately not watched: every re-sum refreshes it, so
/// watching it would journal every ancestor on every commit; it is read again whenever anything else changes.
private let watchedColumns = ["parent_id", "name", "object_id", "kind", "status", "reason", "total_allocated", "total_logical", "child_count", "descendant_files", "descendant_directories", "descendant_entries"]
private let watchedObjectColumns = ["kind", "logical", "allocated", "link_count", "modified_at"]

/// (name, definition) of every journal trigger. Names are stable; definitions follow the version.
let inventoryChangeJournalTriggers: [(String, String)] = [
    ("inventory_change_node_insert", """
     CREATE TRIGGER inventory_change_node_insert AFTER INSERT ON inventory_nodes BEGIN
       \(bump) \(listing("COALESCE(NEW.parent_id,NEW.id)", "NEW.generation_id"))
     END
     """),
    ("inventory_change_node_delete", """
     CREATE TRIGGER inventory_change_node_delete AFTER DELETE ON inventory_nodes BEGIN
       \(bump) \(listing("OLD.parent_id", "OLD.generation_id"))
       \(listing("CASE WHEN OLD.kind='directory' THEN OLD.id END", "OLD.generation_id"))
       DELETE FROM inventory_size_signals WHERE node_id=OLD.id;
     END
     """),
    // One update trigger does all the work for a node row. SQLite evaluates a trigger's WHEN inside the trigger
    // program, so every matching trigger costs a sub-program call per updated row even when nothing changed; one
    // trigger keeps the cost for a re-seen, unchanged row to a single call. The size-signal statements are
    // conditional on their own WHERE clauses:
    //  - baseline: a settled node starts being remeasured; its last settled value is kept (the row's sequence is the
    //    sequence of its last comparison, so starting a remeasurement never republishes an earlier comparison);
    //  - direct: one settled value replaced by another (a file rewritten, an ancestor re-summed);
    //  - resolved: a remeasurement settled; it is compared with the baseline kept when it began.
    ("inventory_change_node_update", """
     CREATE TRIGGER inventory_change_node_update AFTER UPDATE OF \(watchedColumns.joined(separator: ",")) ON inventory_nodes
     WHEN \(watchedColumns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")) BEGIN
       \(bump) \(listing("OLD.parent_id", "NEW.generation_id"))
       \(listing("CASE WHEN NEW.parent_id IS NOT OLD.parent_id THEN NEW.parent_id END", "NEW.generation_id"))
       \(listing("CASE WHEN NEW.kind='directory' THEN NEW.id END", "NEW.generation_id"))
       \(subtree("CASE WHEN NEW.kind='directory' AND (OLD.parent_id IS NOT NEW.parent_id OR OLD.name IS NOT NEW.name) THEN NEW.id END", "NEW.generation_id"))
       INSERT INTO inventory_size_signals(node_id,generation_id,sequence,baseline_allocated,baseline_status,baseline_measured_at)
         SELECT NEW.id,NEW.generation_id,sequence,OLD.total_allocated,OLD.status,OLD.measured_at FROM inventory_change_clock
         WHERE id=1 AND signals_generation=NEW.generation_id AND \(settled("OLD")) AND NOT \(settled("NEW"))
         ON CONFLICT(node_id) DO UPDATE SET generation_id=excluded.generation_id,
           baseline_allocated=excluded.baseline_allocated,baseline_status=excluded.baseline_status,baseline_measured_at=excluded.baseline_measured_at;
       INSERT INTO inventory_size_signals(node_id,generation_id,sequence,previous_allocated,previous_status,previous_measured_at,allocated,status,measured_at)
         SELECT NEW.id,NEW.generation_id,sequence,OLD.total_allocated,OLD.status,OLD.measured_at,NEW.total_allocated,NEW.status,NEW.measured_at FROM inventory_change_clock
         WHERE id=1 AND signals_generation=NEW.generation_id AND \(settled("OLD")) AND \(settled("NEW")) AND OLD.total_allocated<>NEW.total_allocated
         ON CONFLICT(node_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,
           previous_allocated=excluded.previous_allocated,previous_status=excluded.previous_status,previous_measured_at=excluded.previous_measured_at,
           allocated=excluded.allocated,status=excluded.status,measured_at=excluded.measured_at,
           baseline_allocated=NULL,baseline_status=NULL,baseline_measured_at=NULL;
       UPDATE inventory_size_signals SET generation_id=NEW.generation_id,sequence=(SELECT sequence FROM inventory_change_clock WHERE id=1),
         previous_allocated=baseline_allocated,previous_status=baseline_status,previous_measured_at=baseline_measured_at,
         allocated=NEW.total_allocated,status=NEW.status,measured_at=NEW.measured_at,
         baseline_allocated=NULL,baseline_status=NULL,baseline_measured_at=NULL
       WHERE node_id=NEW.id AND baseline_allocated IS NOT NULL AND NOT \(settled("OLD")) AND \(settled("NEW"))
         AND (SELECT signals_generation FROM inventory_change_clock WHERE id=1)=NEW.generation_id;
     END
     """),
    // Object metadata (size, modified date, link count) is shown on every name of the object, including hard-link
    // aliases whose own node row does not change: each of their folders is journaled.
    ("inventory_change_object_update", """
     CREATE TRIGGER inventory_change_object_update AFTER UPDATE OF \(watchedObjectColumns.joined(separator: ",")) ON inventory_objects
     WHEN \(watchedObjectColumns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")) BEGIN
       \(bump)
       INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence)
         SELECT n.parent_id,n.generation_id,c.sequence FROM inventory_nodes n INDEXED BY inventory_nodes_object, inventory_change_clock c
         WHERE c.id=1 AND n.object_id=NEW.id AND n.parent_id IS NOT NULL
         ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
     END
     """),
    ("inventory_change_reconcile_insert", "CREATE TRIGGER inventory_change_reconcile_insert AFTER INSERT ON inventory_reconcile BEGIN \(bump) \(subtree("NEW.root_node_id", "NEW.generation_id")) END"),
    ("inventory_change_reconcile_delete", "CREATE TRIGGER inventory_change_reconcile_delete AFTER DELETE ON inventory_reconcile BEGIN \(bump) \(subtree("OLD.root_node_id", "OLD.generation_id")) END"),
    ("inventory_change_prune_insert", "CREATE TRIGGER inventory_change_prune_insert AFTER INSERT ON inventory_prune_jobs BEGIN \(bump) \(subtree("NEW.parent_node_id", "NEW.generation_id")) END"),
    ("inventory_change_prune_delete", "CREATE TRIGGER inventory_change_prune_delete AFTER DELETE ON inventory_prune_jobs BEGIN \(bump) \(subtree("OLD.parent_node_id", "OLD.generation_id")) END"),
    ("inventory_change_tombstone_insert", """
     CREATE TRIGGER inventory_change_tombstone_insert AFTER INSERT ON inventory_tombstones BEGIN
       \(bump) \(subtree("NEW.node_id", "NEW.generation_id"))
       \(listing("(SELECT parent_id FROM inventory_nodes WHERE id=NEW.node_id)", "NEW.generation_id"))
     END
     """),
    ("inventory_change_tombstone_delete", """
     CREATE TRIGGER inventory_change_tombstone_delete AFTER DELETE ON inventory_tombstones BEGIN
       \(bump) \(subtree("OLD.node_id", "OLD.generation_id"))
       \(listing("(SELECT parent_id FROM inventory_nodes WHERE id=OLD.node_id)", "OLD.generation_id"))
     END
     """)
]
