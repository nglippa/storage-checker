import Foundation
import Darwin
import SQLite3

// Transactional install/update of the background monitor (PACKAGING.md → Updates).
//
// An update needs no copy of the history catalog unless the new code changes its schema: the
// database is snapshotted as an APFS clone (constant time and space) while every agent is stopped
// and SQLite's shared lock is held, the new code's migration is applied inside the transaction, and
// the snapshot is kept only when that migration changed the schema. A journal in the data directory
// records each phase; a failure, or an interruption found by the next install or uninstall, puts
// back the previous app, its LaunchAgents and (only if a migration ran) the database.

struct InstallJournal: Codable {
    enum Phase: String, Codable, CaseIterable, Comparable {
        case begun, stopped, snapshotted, swapped, migrated, registering, registered
        static func < (a: Phase, b: Phase) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }
    var phase: Phase
    var startedAt: Double
    var hadApp: Bool
    var savedAgents: [String: String]     // saved file name → original path (canonical agents and duplicates)
    var snapshot = false
    var schemaBefore: String?
}

extension MonitorInstallLayout {
    func validateQABoundary(journal: InstallJournal? = nil) throws {
        guard let qa else { return }
        guard home.path == qa.home.path, data.path == qa.data.path, app.path == qa.app.path else { try LifecycleQAScope.refuse("layout differs from admitted scope") }
        try qa.validateStorage()
        for role in ["Installer", "V1", "V2"] { try qa.validateBundle(qa.bundle(role), roles: [role]) }
        for bundle in [app, previousApp] where fm.fileExists(atPath: bundle.path) { try qa.validateBundle(bundle) }
        let expected = agents.map(\.plist)
        for agent in agents where fm.fileExists(atPath: agent.url.path) { try qa.validateAgent(agent.url.path, expected: expected) }
        for duplicate in duplicateAgents { try qa.validateAgent(duplicate.path, expected: expected) }
        if let journal { for (name, original) in journal.savedAgents { try qa.validateSavedAgent(name: name, original: original, expected: expected) } }
    }
    func guardedControl(_ control: @escaping LaunchControl) -> LaunchControl {
        guard let qa else { return control }
        return { arguments, acceptable in
            try self.validateQABoundary()
            let domain = "gui/\(getuid())", targets = qa.labels.map { domain + "/" + $0 }
            let service = arguments.count == 2 && ["enable", "bootout", "print", "kickstart"].contains(arguments[0]) && targets.contains(arguments[1])
            let bootstrap = arguments.count == 3 && arguments[0] == "bootstrap" && arguments[1] == domain && qa.labels.map({ qa.agentURL($0).path }).contains(arguments[2])
            guard service || bootstrap else { try LifecycleQAScope.refuse("launchctl escaped owned labels/plists") }
            if qa.expired && !["bootout", "print"].contains(arguments[0]) { try LifecycleQAScope.refuse("expired lease cannot register or start services") }
            if bootstrap { try qa.validateAgent(arguments[2], expected: self.agents.map(\.plist)) }
            try control(arguments, acceptable)
        }
    }
    var transaction: URL { data.appendingPathComponent("install-transaction") }
    var journal: URL { transaction.appendingPathComponent("journal.json") }
    var snapshot: URL { transaction.appendingPathComponent("history.snapshot.sqlite3") }
    var previousApp: URL { app.deletingLastPathComponent().appendingPathComponent(".MacBook Storage Monitor.previous.app") }
    var history: URL { data.appendingPathComponent("history.sqlite3") }
    /// Agent files carrying one of this monitor's labels under another name: duplicates launchd would
    /// load beside (or instead of) the canonical agent, often pointing at a stale program.
    var duplicateAgents: [URL] {
        let folder = home.appendingPathComponent("Library/LaunchAgents")
        let labels = Set(agents.map(\.label)), canonical = Set(agents.map(\.url.lastPathComponent))
        return ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".plist") && !canonical.contains($0) }.map { folder.appendingPathComponent($0) }
            .filter { ((NSDictionary(contentsOf: $0) as? [String: Any])?["Label"] as? String).map(labels.contains) ?? false }
    }
}

/// Schema of a database without opening it for writing (opening through `Database` would migrate it).
func schemaFingerprint(_ path: String) throws -> String {
    var db: OpaquePointer?; defer { sqlite3_close(db) }
    try required(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "Cannot open \(path)")
    sqlite3_busy_timeout(db, 10_000)
    var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
    try required(sqlite3_prepare_v2(db, "SELECT type||' '||name||' '||COALESCE(sql,'') FROM sqlite_master ORDER BY type,name", -1, &stmt, nil) == SQLITE_OK, "Cannot read schema of \(path)")
    var lines = [String]()
    while true {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return lines.joined(separator: "\n") }
        try required(rc == SQLITE_ROW, "Cannot read schema of \(path)")
        lines.append(String(cString: sqlite3_column_text(stmt, 0)))
    }
}

/// A committed state of the database at `target`. A read inside a transaction holds SQLite's shared
/// lock, so no writer can change the file (a hot journal is rolled back first) while it is cloned.
/// Off APFS the clone is replaced by a full copy through SQLite's backup API. Returns "clone" or "copy".
@discardableResult
func snapshotDatabase(_ source: URL, to target: URL) throws -> String {
    var db: OpaquePointer?; defer { sqlite3_close(db) }
    try required(sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, "Cannot open history for a snapshot")
    sqlite3_busy_timeout(db, 10_000)
    try required(sqlite3_exec(db, "BEGIN; SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK, "History is busy: \(String(cString: sqlite3_errmsg(db)))")
    defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
    try? fm.removeItem(at: target)
    // In WAL mode committed pages may live only in the -wal file, which a clone of the main file
    // would miss: such a database is always copied through the backup API.
    var mode: OpaquePointer?
    let wal = sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &mode, nil) == SQLITE_OK && sqlite3_step(mode) == SQLITE_ROW
        && sqlite3_column_text(mode, 0).map { String(cString: $0).lowercased() } == "wal"
    sqlite3_finalize(mode)
    var method = "clone"
    if wal || clonefile(source.path, target.path, 0) != 0 {
        method = "copy"
        var to: OpaquePointer?; defer { sqlite3_close(to) }
        try required(sqlite3_open(target.path, &to) == SQLITE_OK, "Cannot create the history snapshot")
        guard let backup = sqlite3_backup_init(to, "main", db, "main") else { throw Failure("Snapshot could not start: \(String(cString: sqlite3_errmsg(to)))") }
        let step = sqlite3_backup_step(backup, -1); sqlite3_backup_finish(backup)
        try required(step == SQLITE_DONE, "Snapshot did not complete (\(step))")
        // A snapshot is one self-contained file, whatever mode the source uses.
        try required(sqlite3_exec(to, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK, "Cannot finalize the history snapshot")
    }
    _ = chmod(target.path, 0o600)
    try required(try schemaFingerprint(target.path) == schemaFingerprint(source.path), "The history snapshot does not match the database")
    return method
}

struct InstallTransaction {
    let layout: MonitorInstallLayout
    let control: LaunchControl
    var journal: InstallJournal
    var domain: String { "gui/\(getuid())" }

    static func load(_ layout: MonitorInstallLayout, control: @escaping LaunchControl) -> InstallTransaction? {
        guard let data = try? Data(contentsOf: layout.journal) else { return nil }
        // An unreadable journal still means an interrupted update: roll back from what is on disk.
        let journal = (try? JSONDecoder().decode(InstallJournal.self, from: data))
            ?? InstallJournal(phase: .begun, startedAt: 0, hadApp: fm.fileExists(atPath: layout.previousApp.path) || fm.fileExists(atPath: layout.app.path), savedAgents: [:])
        return InstallTransaction(layout: layout, control: control, journal: journal)
    }

    /// Records the prior state durably before anything changes.
    static func begin(_ layout: MonitorInstallLayout, control: @escaping LaunchControl) throws -> InstallTransaction {
        try layout.validateQABoundary()
        try privateDirectory(layout.transaction)
        var saved = [String: String]()
        for (index, url) in (layout.agents.map(\.url) + layout.legacyAgents.map(\.url) + layout.duplicateAgents).enumerated() where fm.fileExists(atPath: url.path) {
            let name = "agent-\(index).plist"
            try fm.copyItem(at: url, to: layout.transaction.appendingPathComponent(name)); saved[name] = url.path
        }
        var transaction = InstallTransaction(layout: layout, control: control,
                                             journal: InstallJournal(phase: .begun, startedAt: Date().timeIntervalSince1970, hadApp: fm.fileExists(atPath: layout.app.path), savedAgents: saved))
        try transaction.advance(.begun)
        return transaction
    }

    mutating func advance(_ phase: InstallJournal.Phase) throws {
        try layout.validateQABoundary(journal: journal)
        journal.phase = phase
        try JSONEncoder().encode(journal).write(to: layout.journal, options: .atomic)
        _ = chmod(layout.journal.path, 0o600)
    }

    /// The supervisor and, if an earlier version installed them, the separate baseline and inventory agents.
    func stopAgents() throws { for label in layout.labels + layout.legacyLabels { try control(["bootout", "\(domain)/\(label)"], true) } }

    /// Idempotent: finishing an already partly committed transaction is safe.
    func commit() throws -> [String] {
        try layout.validateQABoundary(journal: journal)
        var notes = [String]()
        if journal.snapshot, fm.fileExists(atPath: layout.snapshot.path) {
            if let before = journal.schemaBefore, (try? schemaFingerprint(layout.history.path)) == before {
                try fm.removeItem(at: layout.snapshot)
                notes.append("History schema unchanged by this update; no backup was needed.")
            } else {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                let kept = layout.data.appendingPathComponent("history.pre-update-\(stamp).sqlite3")
                if fm.fileExists(atPath: kept.path) { try fm.removeItem(at: kept) }   // superseded: only the newest is kept
                try fm.moveItem(at: layout.snapshot, to: kept)
                let older = ((try? fm.contentsOfDirectory(atPath: layout.data.path)) ?? []).filter { $0.hasPrefix("history.pre-update-") && $0.hasSuffix(".sqlite3") && $0 != kept.lastPathComponent }
                for name in older { try? fm.removeItem(at: layout.data.appendingPathComponent(name)) }
                notes.append("This update migrated the history schema; the pre-update snapshot is kept at \(kept.path)")
            }
        }
        if fm.fileExists(atPath: layout.previousApp.path) { try fm.removeItem(at: layout.previousApp) }
        try fm.removeItem(at: layout.transaction)
        return notes
    }

    /// Restores the state recorded by `begin`. The database is restored only before `registering`:
    /// from the first bootstrap on, a started agent may have written to it, and migrations are
    /// additive, so the previous helper runs against the migrated database instead. (`registered`
    /// is committed, never rolled back.)
    func rollback(restart: Bool = true) throws -> [String] {
        try layout.validateQABoundary(journal: journal)
        try stopAgents()
        var notes = [String]()
        if fm.fileExists(atPath: layout.previousApp.path) {
            if fm.fileExists(atPath: layout.app.path) { try fm.removeItem(at: layout.app) }
            try fm.moveItem(at: layout.previousApp, to: layout.app)
            notes.append("Restored the previous background monitor.")
        } else if !journal.hadApp, journal.phase >= .swapped, fm.fileExists(atPath: layout.app.path) {
            try fm.removeItem(at: layout.app)
        }
        if journal.snapshot, fm.fileExists(atPath: layout.snapshot.path) {
            if let before = journal.schemaBefore, (try? schemaFingerprint(layout.history.path)) == before {
                try fm.removeItem(at: layout.snapshot)
            } else if journal.phase >= .registering {
                let kept = layout.data.appendingPathComponent("history.pre-update-\(Int(journal.startedAt)).sqlite3")
                if fm.fileExists(atPath: kept.path) { try fm.removeItem(at: kept) }
                try fm.moveItem(at: layout.snapshot, to: kept)
                notes.append("Kept history as written after the update started (background tasks may have recorded new data); the pre-update snapshot is at \(kept.path)")
            } else {
                // A partial migration's journal belongs to the replaced file: remove it first.
                let hot = URL(fileURLWithPath: layout.history.path + "-journal")
                if fm.fileExists(atPath: hot.path) { try fm.removeItem(at: hot) }
                _ = try fm.replaceItemAt(layout.history, withItemAt: layout.snapshot)
                notes.append("Restored history from the pre-update snapshot (the interrupted migration was undone).")
            }
        }
        let saved = Set(journal.savedAgents.values)
        for agent in layout.agents where !saved.contains(agent.url.path) && fm.fileExists(atPath: agent.url.path) { try fm.removeItem(at: agent.url) }
        for (name, original) in journal.savedAgents {
            let copy = layout.transaction.appendingPathComponent(name), target = URL(fileURLWithPath: original)
            guard fm.fileExists(atPath: copy.path) else { continue }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: copy, to: target)
        }
        try fm.removeItem(at: layout.transaction)
        // Only agents the person had enabled before are registered again. Files are already restored,
        // so a launchd refusal here is reported for Repair rather than undoing the restoration.
        let restorable = layout.agents.map { ($0.label, $0.url) } + layout.legacyAgents.map { ($0.label, $0.url) }
        for (agentLabel, agentFile) in restorable where restart && !((layout.qa?.expired) ?? false) && saved.contains(agentFile.path) {
            do {
                try control(["enable", "\(domain)/\(agentLabel)"], false)
                try control(["bootstrap", domain, agentFile.path], false)
            } catch { notes.append("Could not restart \(agentLabel) (\(error)); choose Repair in Settings → Background Monitoring.") }
        }
        return notes
    }
}

/// Finishes or reverts an install interrupted by a crash, kill or power loss.
func recoverInterruptedInstall(layout: MonitorInstallLayout, control: @escaping LaunchControl, restart: Bool = true) throws -> [String] {
    guard let transaction = InstallTransaction.load(layout, control: control) else { return [] }
    try layout.validateQABoundary(journal: transaction.journal)
    if transaction.journal.phase == .registered {
        return ["Completed an interrupted update."] + (try transaction.commit())
    }
    return ["Reverted an interrupted update."] + (try transaction.rollback(restart: restart))
}
