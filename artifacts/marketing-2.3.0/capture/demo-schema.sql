CREATE TABLE readings (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, container TEXT NOT NULL, free INTEGER NOT NULL, used INTEGER NOT NULL, volumes TEXT NOT NULL);
CREATE INDEX readings_time ON readings(timestamp);
CREATE TABLE alerts (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, severity TEXT NOT NULL, reasons TEXT NOT NULL, free INTEGER NOT NULL, delta INTEGER, notification TEXT NOT NULL);
CREATE TABLE diagnostics (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, snapshot TEXT NOT NULL);
CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE interval_evidence (reading_id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, evidence TEXT NOT NULL);
CREATE TABLE coverage_units (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, parent INTEGER, depth INTEGER NOT NULL, kind TEXT NOT NULL, state TEXT NOT NULL, reason TEXT, inode INTEGER, logical INTEGER NOT NULL DEFAULT 0, allocated INTEGER NOT NULL DEFAULT 0, files INTEGER NOT NULL DEFAULT 0, entries INTEGER NOT NULL DEFAULT 0, complete INTEGER NOT NULL DEFAULT 0, measured_at REAL, valid_event INTEGER, valid_at REAL, valid_reading INTEGER, first_valid_reading INTEGER, listing_reading INTEGER, discovered_at REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_attempt REAL, needs_split INTEGER NOT NULL DEFAULT 0, agg_logical INTEGER NOT NULL DEFAULT 0, agg_allocated INTEGER NOT NULL DEFAULT 0, agg_files INTEGER NOT NULL DEFAULT 0, agg_complete INTEGER NOT NULL DEFAULT 0, agg_holes INTEGER NOT NULL DEFAULT 0);
CREATE INDEX coverage_units_parent ON coverage_units(parent);
CREATE TABLE coverage_epochs (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, reading_id INTEGER, scope TEXT NOT NULL, detail TEXT NOT NULL);
CREATE TABLE inventory_generations (
  id INTEGER PRIMARY KEY, root_path TEXT NOT NULL, root_device INTEGER NOT NULL,
  root_inode INTEGER NOT NULL, root_birth_ns INTEGER NOT NULL, state TEXT NOT NULL,
  reason TEXT, operational_path TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL, active INTEGER NOT NULL DEFAULT 0
  ,volume_uuid TEXT,
  event_availability TEXT NOT NULL DEFAULT 'available', event_reason TEXT,
  inventory_sequence INTEGER NOT NULL DEFAULT 0, cleanup_sequence INTEGER NOT NULL DEFAULT 0
, initial_completion TEXT NOT NULL DEFAULT 'unknown', initial_completed_at REAL);
CREATE UNIQUE INDEX inventory_one_active ON inventory_generations(active) WHERE active=1;
CREATE TABLE inventory_objects (
  id INTEGER PRIMARY KEY, device INTEGER NOT NULL, inode INTEGER NOT NULL, birth_ns INTEGER NOT NULL,
  kind TEXT NOT NULL, logical INTEGER NOT NULL, allocated INTEGER NOT NULL, link_count INTEGER NOT NULL,
  modified_at REAL NOT NULL, changed_ns INTEGER NOT NULL, owner_node_id INTEGER,
  UNIQUE(device,inode,birth_ns)
);
CREATE TABLE inventory_nodes (
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
CREATE UNIQUE INDEX inventory_root_unique ON inventory_nodes(generation_id) WHERE parent_id IS NULL;
CREATE INDEX inventory_nodes_parent ON inventory_nodes(generation_id,parent_id,name COLLATE NOCASE);
CREATE INDEX inventory_nodes_object ON inventory_nodes(object_id);
CREATE INDEX inventory_nodes_children ON inventory_nodes(parent_id,name COLLATE NOCASE,id);
CREATE INDEX inventory_nodes_children_allocated ON inventory_nodes(parent_id,total_allocated DESC,name COLLATE NOCASE,id);
CREATE INDEX inventory_nodes_largest_all ON inventory_nodes(generation_id,total_allocated DESC,id);
CREATE INDEX inventory_nodes_largest_file ON inventory_nodes(generation_id,kind,total_allocated DESC) WHERE kind='file';
CREATE INDEX inventory_nodes_largest_directory ON inventory_nodes(generation_id,kind,total_allocated DESC) WHERE kind='directory';
CREATE INDEX inventory_nodes_name ON inventory_nodes(generation_id,name COLLATE NOCASE);
CREATE INDEX inventory_nodes_status ON inventory_nodes(generation_id,kind,status);
CREATE INDEX inventory_nodes_kind_id ON inventory_nodes(generation_id,kind,id);
CREATE TABLE inventory_stats (
  generation_id INTEGER PRIMARY KEY REFERENCES inventory_generations(id) ON DELETE CASCADE,
  total_nodes INTEGER NOT NULL DEFAULT 0, completed_directories INTEGER NOT NULL DEFAULT 0,
  pending_directories INTEGER NOT NULL DEFAULT 0, stale_directories INTEGER NOT NULL DEFAULT 0,
  unknown_directories INTEGER NOT NULL DEFAULT 0
);
CREATE TRIGGER inventory_nodes_stats_insert AFTER INSERT ON inventory_nodes BEGIN
  UPDATE inventory_stats SET total_nodes=total_nodes+1,
    completed_directories=completed_directories+CASE WHEN NEW.kind='directory' AND NEW.status='complete' THEN 1 ELSE 0 END,
    pending_directories=pending_directories+CASE WHEN NEW.kind='directory' AND NEW.status IN ('pending','enumerating') THEN 1 ELSE 0 END,
    stale_directories=stale_directories+CASE WHEN NEW.kind='directory' AND NEW.status='stale' THEN 1 ELSE 0 END,
    unknown_directories=unknown_directories+CASE WHEN NEW.kind='directory' AND NEW.status IN ('unknown','inaccessible','excluded','partial') THEN 1 ELSE 0 END
  WHERE generation_id=NEW.generation_id;
END;
CREATE TRIGGER inventory_nodes_stats_delete AFTER DELETE ON inventory_nodes BEGIN
  UPDATE inventory_stats SET total_nodes=MAX(0,total_nodes-1),
    completed_directories=MAX(0,completed_directories-CASE WHEN OLD.kind='directory' AND OLD.status='complete' THEN 1 ELSE 0 END),
    pending_directories=MAX(0,pending_directories-CASE WHEN OLD.kind='directory' AND OLD.status IN ('pending','enumerating') THEN 1 ELSE 0 END),
    stale_directories=MAX(0,stale_directories-CASE WHEN OLD.kind='directory' AND OLD.status='stale' THEN 1 ELSE 0 END),
    unknown_directories=MAX(0,unknown_directories-CASE WHEN OLD.kind='directory' AND OLD.status IN ('unknown','inaccessible','excluded','partial') THEN 1 ELSE 0 END)
  WHERE generation_id=OLD.generation_id;
END;
CREATE TRIGGER inventory_nodes_stats_update AFTER UPDATE OF kind,status ON inventory_nodes
WHEN OLD.kind<>NEW.kind OR OLD.status<>NEW.status BEGIN
  UPDATE inventory_stats SET
    completed_directories=completed_directories-CASE WHEN OLD.kind='directory' AND OLD.status='complete' THEN 1 ELSE 0 END+CASE WHEN NEW.kind='directory' AND NEW.status='complete' THEN 1 ELSE 0 END,
    pending_directories=pending_directories-CASE WHEN OLD.kind='directory' AND OLD.status IN ('pending','enumerating') THEN 1 ELSE 0 END+CASE WHEN NEW.kind='directory' AND NEW.status IN ('pending','enumerating') THEN 1 ELSE 0 END,
    stale_directories=stale_directories-CASE WHEN OLD.kind='directory' AND OLD.status='stale' THEN 1 ELSE 0 END+CASE WHEN NEW.kind='directory' AND NEW.status='stale' THEN 1 ELSE 0 END,
    unknown_directories=unknown_directories-CASE WHEN OLD.kind='directory' AND OLD.status IN ('unknown','inaccessible','excluded','partial') THEN 1 ELSE 0 END+CASE WHEN NEW.kind='directory' AND NEW.status IN ('unknown','inaccessible','excluded','partial') THEN 1 ELSE 0 END
  WHERE generation_id=NEW.generation_id;
END;
CREATE TABLE inventory_jobs (
  node_id INTEGER PRIMARY KEY REFERENCES inventory_nodes(id) ON DELETE CASCADE,
  generation_id INTEGER NOT NULL, state TEXT NOT NULL, cookie INTEGER NOT NULL DEFAULT 0,
  listing_token INTEGER NOT NULL DEFAULT 0, snapshot_device INTEGER, snapshot_inode INTEGER,
  snapshot_birth_ns INTEGER, snapshot_mtime_ns INTEGER, snapshot_ctime_ns INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0, reason TEXT, updated_at REAL NOT NULL,
  listing_sequence INTEGER NOT NULL DEFAULT 0, completed_sequence INTEGER NOT NULL DEFAULT 0,
  completed_token INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX inventory_jobs_pending ON inventory_jobs(generation_id,state,updated_at,node_id);
CREATE TABLE inventory_focus (
  generation_id INTEGER NOT NULL REFERENCES inventory_generations(id) ON DELETE CASCADE,
  path TEXT NOT NULL, requested_at REAL NOT NULL, expires_at REAL NOT NULL,
  source TEXT NOT NULL DEFAULT 'interactive', PRIMARY KEY(generation_id,path)
);
CREATE TABLE inventory_invalidations (
  id INTEGER PRIMARY KEY, generation_id INTEGER, absolute_path TEXT, reason TEXT NOT NULL,
  gap INTEGER NOT NULL DEFAULT 0, event_id INTEGER, created_at REAL NOT NULL,
  request_sequence INTEGER NOT NULL DEFAULT 0, end_node_id INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE inventory_progress (
  generation_id INTEGER NOT NULL, sampled_at REAL NOT NULL, completed_listings INTEGER NOT NULL,
  queued_listings INTEGER NOT NULL, nodes INTEGER NOT NULL, allocated INTEGER NOT NULL,
  PRIMARY KEY(generation_id,sampled_at)
) WITHOUT ROWID;
CREATE TABLE inventory_event_cursor (
  device TEXT PRIMARY KEY, event_id INTEGER NOT NULL, acknowledged_at REAL NOT NULL,
  boot_session TEXT NOT NULL DEFAULT '', awake_at REAL NOT NULL DEFAULT 0
);
CREATE TABLE inventory_reconcile (
  root_node_id INTEGER PRIMARY KEY REFERENCES inventory_nodes(id) ON DELETE CASCADE,
  generation_id INTEGER NOT NULL, reason TEXT NOT NULL, created_at REAL NOT NULL,
  last_node_id INTEGER NOT NULL DEFAULT 0, end_node_id INTEGER NOT NULL DEFAULT 0,
  request_sequence INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE inventory_tombstones (
  node_id INTEGER PRIMARY KEY REFERENCES inventory_nodes(id) ON DELETE CASCADE,
  generation_id INTEGER NOT NULL, created_at REAL NOT NULL
);
CREATE INDEX inventory_tombstones_generation ON inventory_tombstones(generation_id,node_id);
CREATE TABLE inventory_prune_jobs (
  parent_node_id INTEGER PRIMARY KEY REFERENCES inventory_nodes(id) ON DELETE CASCADE,
  generation_id INTEGER NOT NULL, seen_token INTEGER NOT NULL, last_node_id INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL, cleanup_epoch INTEGER NOT NULL DEFAULT 0,
  authority_kind TEXT NOT NULL DEFAULT 'legacy', authority_object_id INTEGER,
  authority_sequence INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE inventory_tombstone_claims (
  cleanup_epoch INTEGER NOT NULL, node_id INTEGER NOT NULL REFERENCES inventory_nodes(id) ON DELETE CASCADE,
  root_node_id INTEGER NOT NULL,
  parent_node_id INTEGER NOT NULL, generation_id INTEGER NOT NULL, created_at REAL NOT NULL,
  PRIMARY KEY(cleanup_epoch,node_id)
);
CREATE INDEX inventory_tombstone_claims_generation ON inventory_tombstone_claims(generation_id,cleanup_epoch,node_id);
CREATE INDEX inventory_tombstone_claims_node ON inventory_tombstone_claims(node_id);
CREATE INDEX inventory_tombstone_claims_root ON inventory_tombstone_claims(root_node_id,cleanup_epoch);
CREATE INDEX inventory_jobs_first_listing ON inventory_jobs(generation_id) WHERE completed_token=0 AND state IN ('pending','enumerating');
CREATE TABLE inventory_change_clock (
  id INTEGER PRIMARY KEY CHECK (id=1), journal_id TEXT NOT NULL, version INTEGER NOT NULL,
  sequence INTEGER NOT NULL DEFAULT 0, retained_after INTEGER NOT NULL DEFAULT 0,
  signals_retained_after INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
  signals_generation INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE inventory_changed_directories (
  directory_id INTEGER PRIMARY KEY, generation_id INTEGER NOT NULL,
  sequence INTEGER NOT NULL, subtree_sequence INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX inventory_changed_directories_sequence ON inventory_changed_directories(sequence);
CREATE TABLE inventory_size_signals (
  node_id INTEGER PRIMARY KEY, generation_id INTEGER NOT NULL, sequence INTEGER NOT NULL,
  baseline_allocated INTEGER, baseline_status TEXT, baseline_measured_at REAL,
  previous_allocated INTEGER, previous_status TEXT, previous_measured_at REAL,
  allocated INTEGER, status TEXT, measured_at REAL
);
CREATE INDEX inventory_size_signals_sequence ON inventory_size_signals(sequence);
CREATE TRIGGER inventory_change_node_insert AFTER INSERT ON inventory_nodes BEGIN
  UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1; INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence) SELECT COALESCE(NEW.parent_id,NEW.id),NEW.generation_id,sequence FROM inventory_change_clock WHERE id=1 AND (COALESCE(NEW.parent_id,NEW.id)) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
END;
CREATE TRIGGER inventory_change_node_delete AFTER DELETE ON inventory_nodes BEGIN
  UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1; INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence) SELECT OLD.parent_id,OLD.generation_id,sequence FROM inventory_change_clock WHERE id=1 AND (OLD.parent_id) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
  INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence) SELECT CASE WHEN OLD.kind='directory' THEN OLD.id END,OLD.generation_id,sequence FROM inventory_change_clock WHERE id=1 AND (CASE WHEN OLD.kind='directory' THEN OLD.id END) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
  DELETE FROM inventory_size_signals WHERE node_id=OLD.id;
END;
CREATE TRIGGER inventory_change_node_update AFTER UPDATE OF parent_id,name,object_id,kind,status,reason,total_allocated,total_logical,child_count,descendant_files,descendant_directories,descendant_entries ON inventory_nodes
WHEN OLD.parent_id IS NOT NEW.parent_id OR OLD.name IS NOT NEW.name OR OLD.object_id IS NOT NEW.object_id OR OLD.kind IS NOT NEW.kind OR OLD.status IS NOT NEW.status OR OLD.reason IS NOT NEW.reason OR OLD.total_allocated IS NOT NEW.total_allocated OR OLD.total_logical IS NOT NEW.total_logical OR OLD.child_count IS NOT NEW.child_count OR OLD.descendant_files IS NOT NEW.descendant_files OR OLD.descendant_directories IS NOT NEW.descendant_directories OR OLD.descendant_entries IS NOT NEW.descendant_entries BEGIN
  UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1; INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence) SELECT OLD.parent_id,NEW.generation_id,sequence FROM inventory_change_clock WHERE id=1 AND (OLD.parent_id) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
  INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence) SELECT CASE WHEN NEW.parent_id IS NOT OLD.parent_id THEN NEW.parent_id END,NEW.generation_id,sequence FROM inventory_change_clock WHERE id=1 AND (CASE WHEN NEW.parent_id IS NOT OLD.parent_id THEN NEW.parent_id END) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
  INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence) SELECT CASE WHEN NEW.kind='directory' THEN NEW.id END,NEW.generation_id,sequence FROM inventory_change_clock WHERE id=1 AND (CASE WHEN NEW.kind='directory' THEN NEW.id END) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
  INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence,subtree_sequence) SELECT CASE WHEN NEW.kind='directory' AND (OLD.parent_id IS NOT NEW.parent_id OR OLD.name IS NOT NEW.name) THEN NEW.id END,NEW.generation_id,sequence,sequence FROM inventory_change_clock WHERE id=1 AND (CASE WHEN NEW.kind='directory' AND (OLD.parent_id IS NOT NEW.parent_id OR OLD.name IS NOT NEW.name) THEN NEW.id END) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,subtree_sequence=excluded.subtree_sequence;
  INSERT INTO inventory_size_signals(node_id,generation_id,sequence,baseline_allocated,baseline_status,baseline_measured_at)
    SELECT NEW.id,NEW.generation_id,sequence,OLD.total_allocated,OLD.status,OLD.measured_at FROM inventory_change_clock
    WHERE id=1 AND signals_generation=NEW.generation_id AND (OLD.status IN ('complete','partial') AND OLD.total_allocated IS NOT NULL) AND NOT (NEW.status IN ('complete','partial') AND NEW.total_allocated IS NOT NULL)
    ON CONFLICT(node_id) DO UPDATE SET generation_id=excluded.generation_id,
      baseline_allocated=excluded.baseline_allocated,baseline_status=excluded.baseline_status,baseline_measured_at=excluded.baseline_measured_at;
  INSERT INTO inventory_size_signals(node_id,generation_id,sequence,previous_allocated,previous_status,previous_measured_at,allocated,status,measured_at)
    SELECT NEW.id,NEW.generation_id,sequence,OLD.total_allocated,OLD.status,OLD.measured_at,NEW.total_allocated,NEW.status,NEW.measured_at FROM inventory_change_clock
    WHERE id=1 AND signals_generation=NEW.generation_id AND (OLD.status IN ('complete','partial') AND OLD.total_allocated IS NOT NULL) AND (NEW.status IN ('complete','partial') AND NEW.total_allocated IS NOT NULL) AND OLD.total_allocated<>NEW.total_allocated
    ON CONFLICT(node_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,
      previous_allocated=excluded.previous_allocated,previous_status=excluded.previous_status,previous_measured_at=excluded.previous_measured_at,
      allocated=excluded.allocated,status=excluded.status,measured_at=excluded.measured_at,
      baseline_allocated=NULL,baseline_status=NULL,baseline_measured_at=NULL;
  UPDATE inventory_size_signals SET generation_id=NEW.generation_id,sequence=(SELECT sequence FROM inventory_change_clock WHERE id=1),
    previous_allocated=baseline_allocated,previous_status=baseline_status,previous_measured_at=baseline_measured_at,
    allocated=NEW.total_allocated,status=NEW.status,measured_at=NEW.measured_at,
    baseline_allocated=NULL,baseline_status=NULL,baseline_measured_at=NULL
  WHERE node_id=NEW.id AND baseline_allocated IS NOT NULL AND NOT (OLD.status IN ('complete','partial') AND OLD.total_allocated IS NOT NULL) AND (NEW.status IN ('complete','partial') AND NEW.total_allocated IS NOT NULL)
    AND (SELECT signals_generation FROM inventory_change_clock WHERE id=1)=NEW.generation_id;
END;
CREATE TRIGGER inventory_change_object_update AFTER UPDATE OF kind,logical,allocated,link_count,modified_at ON inventory_objects
WHEN OLD.kind IS NOT NEW.kind OR OLD.logical IS NOT NEW.logical OR OLD.allocated IS NOT NEW.allocated OR OLD.link_count IS NOT NEW.link_count OR OLD.modified_at IS NOT NEW.modified_at BEGIN
  UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1;
  INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence)
    SELECT n.parent_id,n.generation_id,c.sequence FROM inventory_nodes n INDEXED BY inventory_nodes_object, inventory_change_clock c
    WHERE c.id=1 AND n.object_id=NEW.id AND n.parent_id IS NOT NULL
    ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
END;
CREATE TRIGGER inventory_change_reconcile_insert AFTER INSERT ON inventory_reconcile BEGIN UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1; INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence,subtree_sequence) SELECT NEW.root_node_id,NEW.generation_id,sequence,sequence FROM inventory_change_clock WHERE id=1 AND (NEW.root_node_id) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,subtree_sequence=excluded.subtree_sequence; END;
CREATE TRIGGER inventory_change_reconcile_delete AFTER DELETE ON inventory_reconcile BEGIN UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1; INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence,subtree_sequence) SELECT OLD.root_node_id,OLD.generation_id,sequence,sequence FROM inventory_change_clock WHERE id=1 AND (OLD.root_node_id) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,subtree_sequence=excluded.subtree_sequence; END;
CREATE TRIGGER inventory_change_prune_insert AFTER INSERT ON inventory_prune_jobs BEGIN UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1; INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence,subtree_sequence) SELECT NEW.parent_node_id,NEW.generation_id,sequence,sequence FROM inventory_change_clock WHERE id=1 AND (NEW.parent_node_id) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,subtree_sequence=excluded.subtree_sequence; END;
CREATE TRIGGER inventory_change_prune_delete AFTER DELETE ON inventory_prune_jobs BEGIN UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1; INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence,subtree_sequence) SELECT OLD.parent_node_id,OLD.generation_id,sequence,sequence FROM inventory_change_clock WHERE id=1 AND (OLD.parent_node_id) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,subtree_sequence=excluded.subtree_sequence; END;
CREATE TRIGGER inventory_change_tombstone_insert AFTER INSERT ON inventory_tombstones BEGIN
  UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1; INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence,subtree_sequence) SELECT NEW.node_id,NEW.generation_id,sequence,sequence FROM inventory_change_clock WHERE id=1 AND (NEW.node_id) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,subtree_sequence=excluded.subtree_sequence;
  INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence) SELECT (SELECT parent_id FROM inventory_nodes WHERE id=NEW.node_id),NEW.generation_id,sequence FROM inventory_change_clock WHERE id=1 AND ((SELECT parent_id FROM inventory_nodes WHERE id=NEW.node_id)) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
END;
CREATE TRIGGER inventory_change_tombstone_delete AFTER DELETE ON inventory_tombstones BEGIN
  UPDATE inventory_change_clock SET sequence=sequence+1 WHERE id=1; INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence,subtree_sequence) SELECT OLD.node_id,OLD.generation_id,sequence,sequence FROM inventory_change_clock WHERE id=1 AND (OLD.node_id) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence,subtree_sequence=excluded.subtree_sequence;
  INSERT INTO inventory_changed_directories(directory_id,generation_id,sequence) SELECT (SELECT parent_id FROM inventory_nodes WHERE id=OLD.node_id),OLD.generation_id,sequence FROM inventory_change_clock WHERE id=1 AND ((SELECT parent_id FROM inventory_nodes WHERE id=OLD.node_id)) IS NOT NULL ON CONFLICT(directory_id) DO UPDATE SET generation_id=excluded.generation_id,sequence=excluded.sequence;
END;
