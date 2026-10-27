import Foundation
import CoreServices
import Darwin
import SQLite3

// Comprehensive filesystem coverage of the startup Data volume. See ATTRIBUTION.md §7.
//
// The volume is partitioned into "units": directories measured as one aggregate. A unit
// whose subtree has more than coverageSplitEntries entries is split into its
// subdirectories, so the partition follows where files are and stays bounded (about
// 10,000 units for 3 million files). Units are disjoint: a unit's own measurement
// excludes every unit nested inside it, so sums never count a byte twice and an
// ancestor's total is the sum of its own files and its child units.
//
// Directories that cannot or must not be measured are units too ("holes"): protected,
// consent-gated, cloud placeholders and other mounted filesystems. They are never
// walked and never silently dropped, so coverage limits stay visible.
//
// FSEvents history (one device-relative stream, so /Users/x and
// /System/Volumes/Data/Users/x are the same key) marks which units changed; only those
// are re-measured. FSEvents never gives byte counts or the writing process.

let coverageSplitEntries: Int64 = 20_000     // a larger subtree is split into its subdirectories
let coverageCheckEntries: Int64 = 80_000     // a scheduled check never walks more than this in one unit
let coverageLeafEntries: Int64 = 2_000_000   // a unit that can no longer be split
let coverageMaxDepth = 32
let coverageMaxUnits = 60_000
let coverageMaxNewHoles = 256
let dataVolumeMount = "/System/Volumes/Data"

// MARK: I/O policy

// Observational I/O: no access-time updates, never download cloud placeholders.
func applyObservationalIOPolicy() {
    _ = setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_PROCESS, IOPOL_ATIME_UPDATES_OFF)
    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
}
func withThrottledIO<T>(_ body: () throws -> T) rethrows -> T {
    let previous = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
    _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
    defer { _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, previous >= 0 ? previous : IOPOL_DEFAULT) }
    return try body()
}

// MARK: Paths and firmlinks

// /usr/share/firmlinks: "<path on the sealed system volume>\t<path inside the Data volume>".
typealias Firmlink = (source: String, target: String)
func parseFirmlinks(_ text: String) -> [Firmlink] {
    text.split(separator: "\n").compactMap { line -> Firmlink? in
        let parts = line.split(separator: "\t", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 && parts[0].hasPrefix("/") && !parts[1].isEmpty ? (parts[0], parts[1]) : nil
    }
}
let systemFirmlinks: [Firmlink] = parseFirmlinks((try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)) ?? "")

// The Data-volume-relative form of an absolute path; nil when the path is not on the Data
// volume (the sealed system volume, other volumes). Every spelling of one object maps to one key.
func dataRelative(_ path: String, mount: String = dataVolumeMount, links: [Firmlink] = systemFirmlinks) -> String? {
    // FSEvents/refresh requests can retain the stable macOS aliases after an entry disappears.
    // Normalize only these whole components; realpath would fail for the missing leaf and
    // resolving arbitrary user symlinks would change the requested inventory boundary.
    func systemAlias(_ value: String) -> String {
        if value == "/tmp" || value.hasPrefix("/tmp/") || value == "/var" || value.hasPrefix("/var/") {
            return "/private" + value
        }
        return value
    }
    var p = systemAlias(path)
    let mount = systemAlias(mount)
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    if p == mount { return "" }
    if p.hasPrefix(mount + "/") { return String(p.dropFirst(mount.count + 1)) }
    for link in links.sorted(by: { $0.source.count > $1.source.count }) where p == link.source || p.hasPrefix(link.source + "/") {
        return link.target + p.dropFirst(link.source.count)
    }
    return nil
}
// Display form: the firmlinked path people know (/Users/…), else the Data volume path.
func displayPath(_ deviceRelative: String, mount: String = dataVolumeMount, links: [Firmlink] = systemFirmlinks) -> String {
    if deviceRelative.isEmpty { return mount }
    for link in links.sorted(by: { $0.target.count > $1.target.count }) where deviceRelative == link.target || deviceRelative.hasPrefix(link.target + "/") {
        return link.source + deviceRelative.dropFirst(link.target.count)
    }
    return mount + "/" + deviceRelative
}
func parentPath(_ rel: String) -> String { rel.lastIndex(of: "/").map { String(rel[..<$0]) } ?? "" }

func fsType(_ path: String) -> String {
    var s = statfs()
    guard statfs(path, &s) == 0 else { return "unknown" }
    return withUnsafePointer(to: s.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
}
func mountSource(_ path: String) -> (on: String, from: String, type: String)? {
    var s = statfs()
    guard statfs(path, &s) == 0 else { return nil }
    func text<T>(_ value: T, _ capacity: Int) -> String { withUnsafePointer(to: value) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } } }
    return (text(s.f_mntonname, 1024), text(s.f_mntfromname, 1024), text(s.f_fstypename, 16))
}

// MARK: Region

struct CoverageRegion {
    let mount: String          // the Data volume mount point
    let prefix: String         // device-relative path of the covered root; "" is the whole volume
    let device: dev_t
    let deviceIdentifier: String
    var root: String { prefix.isEmpty ? mount : mount + "/" + prefix }
    func absolute(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }
    func deviceRelative(_ rel: String) -> String { prefix.isEmpty ? rel : (rel.isEmpty ? prefix : prefix + "/" + rel) }
    func display(_ rel: String) -> String { tilde(displayPath(deviceRelative(rel), mount: mount)) }
    // Firmlinked and Data-volume spellings, for matching open-file paths.
    func absoluteForms(_ rel: String) -> [String] { Array(Set([displayPath(deviceRelative(rel), mount: mount), absolute(rel)])) }
    // A device-relative event path as a unit-relative path; nil outside the region.
    func relative(fromDevice path: String) -> String? {
        var p = Substring(path)
        while p.hasSuffix("/") { p = p.dropLast() }
        while p.hasPrefix("/") { p = p.dropFirst() }
        if prefix.isEmpty { return String(p) }
        if p == prefix { return "" }
        return p.hasPrefix(prefix + "/") ? String(p.dropFirst(prefix.count + 1)) : nil
    }
}

func dataVolumeAllocated(_ reading: Reading) -> (device: String, allocated: Int64)? {
    guard let volumes = (try? JSONSerialization.jsonObject(with: Data(reading.volumes.utf8))) as? [[String: Any]],
          let data = volumes.first(where: { ($0["Roles"] as? [String])?.contains("Data") == true }), let device = data["DeviceIdentifier"] as? String else { return nil }
    return (device, number(data["CapacityInUse"]) ?? 0)
}

// The startup Data volume, verified to belong to the measured container when a reading is given.
// Other volumes of the container (System, VM, Preboot, Update, Recovery) are covered by APFS
// volume allocation only: the system volume is sealed and read-only, and the others keep no
// file-event history.
func startupDataRegion(_ reading: Reading?, mount: String = dataVolumeMount) -> (region: CoverageRegion?, reason: String?) {
    guard let source = mountSource(mount), source.on == mount, source.type == "apfs" else { return (nil, "No APFS Data volume is mounted at \(mount).") }
    var info = stat()
    guard stat(mount, &info) == 0 else { return (nil, "The Data volume could not be inspected.") }
    let device = source.from.hasPrefix("/dev/") ? String(source.from.dropFirst(5)) : source.from
    if let reading {
        guard let data = dataVolumeAllocated(reading) else { return (nil, "The reading has no Data-role volume.") }
        guard data.device == device else { return (nil, "The mounted Data volume (\(device)) is not the measured container's Data volume (\(data.device)).") }
    }
    return (CoverageRegion(mount: mount, prefix: "", device: info.st_dev, deviceIdentifier: device), nil)
}
// Any directory on the Data volume as its own region (tests and probes).
func coverageRegion(root path: String, mount: String = dataVolumeMount) -> CoverageRegion? {
    guard let resolved = canonicalPath(path), let rel = dataRelative(resolved, mount: mount) else { return nil }
    var a = stat(), b = stat()
    guard stat(mount, &a) == 0, stat(resolved, &b) == 0, a.st_dev == b.st_dev, let source = mountSource(mount) else { return nil }
    return CoverageRegion(mount: mount, prefix: rel, device: a.st_dev, deviceIdentifier: source.from.hasPrefix("/dev/") ? String(source.from.dropFirst(5)) : source.from)
}

// MARK: Permissions

// Full Disk Access of this process, probed by opening (never reading) folders macOS reserves for it.
// Opening one of these never shows a prompt; it simply fails without access.
func fullDiskAccessState(homePath: String = home.path) -> String {
    for path in [homePath + "/Library/Mail", homePath + "/Library/Safari", "/Library/Application Support/com.apple.TCC"] {
        var info = stat()
        guard lstat(path, &info) == 0 else { continue }
        if let dir = opendir(path) { closedir(dir); return "granted" }
        if errno == EPERM { return "not_granted" }
    }
    return "unknown"
}
// Folders that must not be opened without Full Disk Access. macOS answers an open() there
// with a consent prompt (Desktop, Documents, Downloads, iCloud, media libraries) or an
// "app data" notification (other apps' data in ~/Library), and a background walk would block
// on the prompt. Measured on macOS 27: Chrome's Application Support raised an App Data
// notification and a media library prompt followed. These folders are recorded as
// inaccessible and never opened. Inside ~/Library only Caches, Developer and Logs are walked.
// Application Support is walked only where the predefined-folder baseline proves this monitor
// already reads a folder without a prompt (a second launchd test stalled on Application Support).
struct ConsentGate: ExpressibleByArrayLiteral {
    var exact = Set<String>()
    var childrenOf = [String: Set<String>]()   // parent → children that remain allowed
    init(arrayLiteral elements: String...) { exact = Set(elements) }
    init(exact: Set<String>, childrenOf: [String: Set<String>]) { self.exact = exact; self.childrenOf = childrenOf }
    var isEmpty: Bool { exact.isEmpty && childrenOf.isEmpty }
    // True for a gated folder and anything inside one.
    func contains(_ rel: String) -> Bool {
        if isEmpty { return false }
        var path = Substring(rel)
        while !path.isEmpty {
            if exact.contains(String(path)) { return true }
            guard let slash = path.lastIndex(of: "/") else { return false }
            if let allowed = childrenOf[String(path[..<slash])], !allowed.contains(String(path[path.index(after: slash)...])) { return true }
            path = path[..<slash]
        }
        return false
    }
}
func consentGatedPaths(_ region: CoverageRegion, homePath: String = home.path, provenReadable: Set<String> = []) -> ConsentGate {
    guard let homeDevice = dataRelative(canonicalPath(homePath) ?? homePath, mount: region.mount) else { return [] }
    func rel(_ suffix: String) -> String? { region.relative(fromDevice: homeDevice + "/" + suffix) }
    let exact = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library/Mobile Documents", "Library/CloudStorage", "Library/Containers", "Library/Group Containers"].compactMap(rel)
    var children = [String: Set<String>]()
    if let library = rel("Library") { children[library] = ["Caches", "Developer", "Logs", "Application Support"] }
    let supportPath = (canonicalPath(homePath) ?? homePath) + "/Library/Application Support/"
    var gatedExact = Set(exact)
    if let support = rel("Library/Application Support") {
        let proven = Set(provenReadable.filter { $0.hasPrefix(supportPath) }.map { String($0.dropFirst(supportPath.count).split(separator: "/").first ?? "") }.filter { !$0.isEmpty })
        if proven.isEmpty { gatedExact.insert(support) } else { children[support] = proven }   // not even listed without evidence
    }
    return ConsentGate(exact: gatedExact, childrenOf: children)
}
func accessReason(_ code: Int32) -> String {
    switch code { case EPERM: return "privacy"; case EACCES: return "permissions"; case EDEADLK: return "cloud"; default: return "error:\(code)" }
}
func reasonText(_ code: String?, fda: String) -> String {
    guard let code else { return "" }
    if code.hasPrefix("filesystem:") { return "A separate \(code.dropFirst(11)) filesystem is mounted here; it is outside the startup volume." }
    if code.hasPrefix("error:") { return "Could not be read (\(String(cString: strerror(Int32(code.dropFirst(6)) ?? 0))))." }
    switch code {
    case "consent": return "Protected by macOS privacy controls. Not opened, so no permission prompt appears; Full Disk Access would include it."
    case "privacy": return fda == "granted" ? "Protected by macOS (System Integrity Protection or system policy); Full Disk Access does not cover it." : "Protected by macOS privacy controls; Full Disk Access may make it readable."
    case "permissions": return "Readable only by its owner (another user or the system); Full Disk Access does not change this."
    case "cloud": return "Cloud placeholder (not downloaded); its local allocation is part of the volume total."
    case "timed_out": return "Stopped at its time limit; retried later."
    case "split_pending": return "Grew past one measurement unit; the background job divides it."
    case "unit_limit": return "Measured as one large unit (unit limit reached)."
    case "blocked_split": return "A walk here did not return; its subfolders are being measured one by one."
    case "blocked": return "Opening it did not return (macOS may have been waiting for a permission answer); skipped and retried daily."
    default: return code
    }
}
// Predefined-folder roots this monitor has already read completely (from its own baseline).
func legacyReadableRoots(_ db: Database) -> Set<String> {
    guard let baseline = decodeState(db, "attribution_baseline", as: AttributionBaseline.self) else { return [] }
    return Set(baseline.roots.filter { $0.value.children.values.contains { $0.complete } }.map(\.key))
}
func coverageGate(_ db: Database, region: CoverageRegion, fda: String) -> ConsentGate {
    fda == "granted" ? [] : consentGatedPaths(region, provenReadable: legacyReadableRoots(db))
}

// A walk that does not return (an open() waiting on a permission answer cannot be interrupted)
// would hold the locks and stop monitoring. The watchdog marks that unit "blocked" through its
// own connection and ends the process; launchd and the next check carry on without it.
final class WalkWatchdog {
    static let shared = WalkWatchdog()
    private let lock = NSRecursiveLock()
    private var current: (path: String, limit: Date, interval: TimeInterval, recover: () -> Void)?
    private var started = false
    var onStall: ((String) -> Void)?
    var exitOnStall = true                      // tests observe instead of exiting
    func begin(db: String, unit: Int64, path: String, allowed: TimeInterval) {
        begin(path: path, allowed: allowed + 60) {
            // Preserve coverage's existing recovery: split recursive units, skip blocked listings.
            if let db = try? Database(db) { try? db.write("UPDATE coverage_units SET state = CASE WHEN kind='tree' THEN 'pending' ELSE 'inaccessible' END, reason = CASE WHEN kind='tree' THEN 'blocked_split' ELSE 'blocked' END, kind='split', complete=0, valid_reading=NULL, last_attempt=? WHERE id=?", [Date().timeIntervalSince1970, unit]) }
        }
    }
    func begin(path: String, allowed: TimeInterval, recover: @escaping () -> Void) {
        lock.lock(); current = (path, Date().addingTimeInterval(allowed), allowed, recover); let start = !started; started = true; lock.unlock()
        if start { Thread.detachNewThread { self.watch() } }
    }
    func end() { lock.lock(); current = nil; lock.unlock() }
    // Inventory's replay can be long but productive. Bound inactivity rather than
    // total elapsed time; coverage retains its original fixed walk deadline.
    func progress() {
        lock.lock(); defer { lock.unlock() }
        if var c = current { c.limit = Date().addingTimeInterval(c.interval); current = c }
    }
    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: 5)
            lock.lock()
            guard let c = current, Date() > c.limit else { lock.unlock(); continue }
            // Claim expiry while holding the same lock as begin/end. Keep it through
            // recovery so a returned walk cannot start new work before process exit.
            current = nil
            // A recursive unit is divided so its subfolders are tried one by one, converging on the
            // folder that blocks; a listing that blocks makes the unit itself inaccessible.
            c.recover()
            onStall?(c.path)
            fputs("Storage Monitor: walk of \(c.path) did not return; marked blocked\n", stderr)
            if exitOnStall { _exit(75) }
            lock.unlock()
        }
    }
}

let fullDiskAccessGuidance = "To widen coverage, open System Settings → Privacy & Security → Full Disk Access, click +, and add ~/Applications/MacBook Storage Monitor.app (the background monitor). Storage Monitor never requests this itself; without it, monitoring continues and protected folders are reported as inaccessible."

// MARK: Units

struct CoverageUnit {
    var id: Int64
    var path: String                  // relative to the region root; "" is the root
    var parent: Int64?
    var depth: Int
    var kind = "tree"                 // tree: walked recursively (minus nested units) · split: own files only, subdirectories are units
    var state = "discovered"          // discovered | baselined | pending | deferred | inaccessible | stale | reconcile | excluded
    var reason: String?
    var inode: Int64?
    var logical: Int64 = 0, allocated: Int64 = 0, files: Int64 = 0, entries: Int64 = 0   // own measurement
    var complete = false
    var measuredAt: Double?
    var validEvent: Int64?            // FSEvents ID taken before the walk; the value is current as of this event
    var validAt: Double?
    var validReading: Int64?          // last reading this value is known to describe (nil: none)
    var firstValidReading: Int64?     // first reading at which it described a reading
    var listingReading: Int64?        // split units: last reading at which the child listing was known current
    var discoveredAt: Double
    var attempts: Int64 = 0
    var lastAttempt: Double?
    var needsSplit = false
    var aggLogical: Int64 = 0, aggAllocated: Int64 = 0, aggFiles: Int64 = 0, aggComplete = false, aggHoles: Int64 = 0
    var isHole: Bool { state == "inaccessible" || state == "excluded" }
    var name: String { path.split(separator: "/").last.map(String.init) ?? "" }
    func validAtReading(_ reading: Int64?) -> Bool { reading != nil && state == "baselined" && complete && validReading == reading }
    func freshAt(_ time: Double) -> Bool { state == "baselined" && complete && validEvent != nil && (validAt.map { time - $0 <= maxReplayAge && $0 <= time + 60 } ?? false) }
    // Bounded retries: protected folders daily, repeated timeouts every 6 hours after 3 attempts.
    func retryDue(at now: Double, fda: String) -> Bool {
        guard let last = lastAttempt else { return true }
        if state == "excluded" { return false }
        if reason == "consent" { return fda == "granted" }
        if state == "inaccessible" { return now - last >= 24 * 3600 }
        if attempts >= 3 { return now - last >= 6 * 3600 }
        return true
    }
}

final class CoverageStore {
    private(set) var units = [Int64: CoverageUnit]()
    private(set) var byPath = [String: Int64]()
    private(set) var children = [Int64: Set<Int64>]()
    private(set) var changed = Set<Int64>()
    private(set) var removed = Set<Int64>()
    private var nextId: Int64 = 1
    var count: Int { units.count }
    var root: CoverageUnit? { byPath[""].flatMap { units[$0] } }
    subscript(id: Int64) -> CoverageUnit? { units[id] }

    static let columns = "id,path,parent,depth,kind,state,reason,inode,logical,allocated,files,entries,complete,measured_at,valid_event,valid_at,valid_reading,first_valid_reading,listing_reading,discovered_at,attempts,last_attempt,needs_split,agg_logical,agg_allocated,agg_files,agg_complete,agg_holes"

    static func load(_ db: Database) throws -> CoverageStore {
        let store = CoverageStore()
        var stmt: OpaquePointer?
        try required(sqlite3_prepare_v2(db.db, "SELECT \(columns) FROM coverage_units", -1, &stmt, nil) == SQLITE_OK, "SQLite prepare failed: coverage_units")
        defer { sqlite3_finalize(stmt) }
        func i(_ c: Int32) -> Int64? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, c) }
        func d(_ c: Int32) -> Double? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, c) }
        func s(_ c: Int32) -> String? { sqlite3_column_text(stmt, c).map { String(cString: $0) } }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            try required(rc == SQLITE_ROW, "SQLite read failed: coverage_units")
            var u = CoverageUnit(id: i(0)!, path: s(1) ?? "", parent: i(2), depth: Int(i(3) ?? 0), discoveredAt: d(19) ?? 0)
            u.kind = s(4) ?? "tree"; u.state = s(5) ?? "discovered"; u.reason = s(6); u.inode = i(7)
            u.logical = i(8) ?? 0; u.allocated = i(9) ?? 0; u.files = i(10) ?? 0; u.entries = i(11) ?? 0; u.complete = i(12) == 1
            u.measuredAt = d(13); u.validEvent = i(14); u.validAt = d(15); u.validReading = i(16); u.firstValidReading = i(17); u.listingReading = i(18)
            u.attempts = i(20) ?? 0; u.lastAttempt = d(21); u.needsSplit = i(22) == 1
            u.aggLogical = i(23) ?? 0; u.aggAllocated = i(24) ?? 0; u.aggFiles = i(25) ?? 0; u.aggComplete = i(26) == 1; u.aggHoles = i(27) ?? 0
            store.insert(u)
            store.nextId = max(store.nextId, u.id + 1)
        }
        return store
    }
    private func insert(_ unit: CoverageUnit) {
        units[unit.id] = unit; byPath[unit.path] = unit.id
        if let parent = unit.parent { children[parent, default: []].insert(unit.id) }
    }
    // Writes changed and removed units in bounded transactions.
    func save(_ db: Database, chunk: Int = 1000) throws {
        var upsert: OpaquePointer?, delete: OpaquePointer?
        let placeholders = Array(repeating: "?", count: 28).joined(separator: ",")
        try required(sqlite3_prepare_v2(db.db, "INSERT OR REPLACE INTO coverage_units(\(Self.columns)) VALUES(\(placeholders))", -1, &upsert, nil) == SQLITE_OK, "SQLite prepare failed: coverage upsert")
        try required(sqlite3_prepare_v2(db.db, "DELETE FROM coverage_units WHERE id=?", -1, &delete, nil) == SQLITE_OK, "SQLite prepare failed: coverage delete")
        defer { sqlite3_finalize(upsert); sqlite3_finalize(delete) }
        func bind(_ s: OpaquePointer?, _ index: Int32, _ value: Any?) {
            switch value {
            case let v as Int64: sqlite3_bind_int64(s, index, v)
            case let v as Int: sqlite3_bind_int64(s, index, Int64(v))
            case let v as Bool: sqlite3_bind_int64(s, index, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(s, index, v)
            case let v as String: sqlite3_bind_text(s, index, v, -1, transient)
            default: sqlite3_bind_null(s, index)
            }
        }
        func step(_ s: OpaquePointer?) throws { defer { sqlite3_reset(s); sqlite3_clear_bindings(s) }; try required(sqlite3_step(s) == SQLITE_DONE, "SQLite write failed: coverage_units: \(String(cString: sqlite3_errmsg(db.db)))") }
        var work: [(Bool, Int64)] = removed.map { (false, $0) } + changed.subtracting(removed).map { (true, $0) }
        work.sort { !$0.0 && $1.0 }   // deletions first
        var index = 0
        while index < work.count {
            try db.exec("BEGIN IMMEDIATE")
            do {
                for (isUpsert, id) in work[index..<min(work.count, index + chunk)] {
                    if !isUpsert { bind(delete, 1, id); try step(delete); continue }
                    guard let u = units[id] else { continue }
                    let values: [Any?] = [u.id, u.path, u.parent, Int64(u.depth), u.kind, u.state, u.reason, u.inode, u.logical, u.allocated, u.files, u.entries, u.complete,
                                          u.measuredAt, u.validEvent, u.validAt, u.validReading, u.firstValidReading, u.listingReading, u.discoveredAt, u.attempts, u.lastAttempt, u.needsSplit,
                                          u.aggLogical, u.aggAllocated, u.aggFiles, u.aggComplete, u.aggHoles]
                    for (i, v) in values.enumerated() { bind(upsert, Int32(i + 1), v) }
                    try step(upsert)
                }
                try db.exec("COMMIT")
            } catch { try? db.exec("ROLLBACK"); throw error }
            index += chunk
        }
        changed = []; removed = []
    }
    func update(_ unit: CoverageUnit) { if let old = units[unit.id], old.path != unit.path { byPath[old.path] = nil; byPath[unit.path] = unit.id }; units[unit.id] = unit; changed.insert(unit.id) }
    func modify(_ id: Int64, _ change: (inout CoverageUnit) -> Void) { guard var u = units[id] else { return }; change(&u); update(u) }

    // The deepest unit containing a path (the root always exists once discovery started).
    func deepest(_ rel: String) -> Int64? {
        var p = Substring(rel)
        while true {
            if let id = byPath[String(p)] { return id }
            if p.isEmpty { return nil }
            p = p.lastIndex(of: "/").map { p[..<$0] } ?? ""
        }
    }
    @discardableResult
    func create(path: String, state: String = "discovered", reason: String? = nil, inode: Int64? = nil, at now: Double) -> CoverageUnit {
        if let existing = byPath[path], let unit = units[existing] { return unit }
        let parent = path.isEmpty ? nil : deepest(parentPath(path))
        let depth = path.isEmpty ? 0 : path.split(separator: "/").count
        var unit = CoverageUnit(id: nextId, path: path, parent: parent, depth: depth, discoveredAt: now)
        unit.state = state; unit.reason = reason; unit.inode = inode
        if state == "inaccessible" || state == "excluded" { unit.lastAttempt = now }
        nextId += 1
        insert(unit); changed.insert(unit.id)
        // Units already inside the new one now belong to it.
        if let parent {
            for child in children[parent] ?? [] where child != unit.id {
                if let c = units[child], c.path.hasPrefix(path + "/") { reparent(child, to: unit.id) }
            }
        }
        return unit
    }
    private func reparent(_ id: Int64, to parent: Int64?) {
        guard var u = units[id] else { return }
        if let old = u.parent { children[old]?.remove(id) }
        u.parent = parent
        if let parent { children[parent, default: []].insert(id) }
        units[id] = u; changed.insert(id)
    }
    func descendants(_ id: Int64) -> [Int64] {
        var result = [Int64](), stack = Array(children[id] ?? [])
        while let next = stack.popLast() { result.append(next); stack += Array(children[next] ?? []) }
        return result
    }
    func remove(_ id: Int64) {
        for child in descendants(id) + [id] {
            guard let u = units[child] else { continue }
            units[child] = nil; byPath[u.path] = nil; children[child] = nil
            if let p = u.parent { children[p]?.remove(child) }
            changed.remove(child); removed.insert(child)
        }
    }
    // Directory rename or move: the unit and its descendants keep their identity and values.
    func move(_ id: Int64, to newPath: String) {
        guard let unit = units[id], unit.path != newPath, byPath[newPath] == nil else { return }
        let old = unit.path
        for child in [id] + descendants(id) {
            guard var u = units[child] else { continue }
            byPath[u.path] = nil
            u.path = newPath + u.path.dropFirst(old.count)
            u.depth = u.path.split(separator: "/").count
            byPath[u.path] = child; units[child] = u; changed.insert(child)
        }
        reparent(id, to: deepest(parentPath(newPath)))
        // Units that now sit inside the moved one.
        if let parent = units[id]?.parent { for child in children[parent] ?? [] where child != id { if let c = units[child], c.path.hasPrefix(newPath + "/") { reparent(child, to: id) } } }
    }
    // Ancestor aggregates: own measurement plus all child units. Holes add nothing and are counted.
    func aggregate() {
        func visit(_ id: Int64) -> (Int64, Int64, Int64, Bool, Int64) {
            guard var u = units[id] else { return (0, 0, 0, true, 0) }
            var total = u.isHole ? (Int64(0), Int64(0), Int64(0), true, Int64(1)) : (u.logical, u.allocated, u.files, u.complete && u.state == "baselined", Int64(0))
            for child in children[id] ?? [] { let c = visit(child); total = (total.0 + c.0, total.1 + c.1, total.2 + c.2, total.3 && c.3, total.4 + c.4) }
            if (u.aggLogical, u.aggAllocated, u.aggFiles, u.aggComplete, u.aggHoles) != total {
                (u.aggLogical, u.aggAllocated, u.aggFiles, u.aggComplete, u.aggHoles) = total
                units[id] = u; changed.insert(id)
            }
            return total
        }
        if let root = byPath[""] { _ = visit(root) }
    }
}

// MARK: Walking

struct UnitWalk {
    enum Status: String { case complete, exceeded, timedOut = "timed_out", denied, absent, notDirectory = "not_directory", otherFilesystem = "other_filesystem" }
    var status = Status.complete
    var error: Int32 = 0
    var filesystem = ""
    var inode: Int64 = 0
    var logical: Int64 = 0, allocated: Int64 = 0, files: Int64 = 0, entries: Int64 = 0, directories: Int64 = 0
    var hardLinks = 0, unreadable = 0
    var holes = [(rel: String, state: String, reason: String, inode: Int64)]()
    var holesCapped = false
    var nestedSeen = Set<String>()
    var subdirectories = [(rel: String, inode: Int64, hole: (state: String, reason: String)?)]()
}

// One unit's own measurement. A split unit (ownOnly) counts the files directly inside it and
// lists its subdirectories; a tree unit walks everything except nested units. Never follows
// symlinks, crosses into another filesystem, opens consent-gated folders, or reads contents.
// Hard-linked files are counted once per walk. Allocation is st_blocks × 512 (data fork).
func walkUnit(_ region: CoverageRegion, _ rel: String, isUnit: (String) -> Bool, gated: ConsentGate, ownOnly: Bool, maxEntries: Int64, deadline: Date) -> UnitWalk {
    var walk = UnitWalk()
    let path = region.absolute(rel)
    var info = stat()
    guard lstat(path, &info) == 0 else { walk.status = (errno == ENOENT || errno == ENOTDIR) ? .absent : .denied; walk.error = errno; return walk }
    guard (info.st_mode & S_IFMT) == S_IFDIR else { walk.status = .notDirectory; return walk }
    walk.inode = Int64(bitPattern: UInt64(info.st_ino))
    if info.st_dev != region.device { walk.status = .otherFilesystem; walk.filesystem = fsType(path); return walk }
    if info.st_flags & UInt32(SF_DATALESS) != 0 { walk.status = .denied; walk.error = EDEADLK; return walk }
    if gated.contains(rel) { walk.status = .denied; walk.error = -1; return walk }
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
    defer { free(argv[0]) }
    guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { walk.status = .denied; walk.error = errno; return walk }
    defer { fts_close(fts) }
    let base = path.utf8.count + 1
    var linked = Set<UInt64>()
    func regionRel(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        let sub = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(entry.pointee.fts_path).assumingMemoryBound(to: UInt8.self), count: Int(entry.pointee.fts_pathlen)).dropFirst(base), as: UTF8.self)
        return rel.isEmpty ? sub : rel + "/" + sub
    }
    func hole(_ r: String, _ state: String, _ reason: String, _ inode: Int64) {
        if walk.holes.count < coverageMaxNewHoles { walk.holes.append((r, state, reason, inode)) } else { walk.holesCapped = true }
    }
    loop: while let entry = fts_read(fts) {
        let level = Int(entry.pointee.fts_level), info = Int32(entry.pointee.fts_info)
        if level == 0 {
            if info == FTS_DNR || info == FTS_ERR { walk.status = .denied; walk.error = entry.pointee.fts_errno; break loop }
            continue
        }
        if info == FTS_DP { continue }
        if info != FTS_DNR {
            walk.entries += 1
            if walk.entries > maxEntries { walk.status = .exceeded; break loop }
            if walk.entries & 511 == 0 && Date() >= deadline { walk.status = .timedOut; break loop }
        }
        switch info {
        case FTS_D:
            walk.directories += 1
            let st = entry.pointee.fts_statp.pointee
            let r = regionRel(entry), inode = Int64(bitPattern: UInt64(st.st_ino))
            if isUnit(r) {
                walk.nestedSeen.insert(r); fts_set(fts, entry, Int32(FTS_SKIP))
                if ownOnly { walk.subdirectories.append((r, inode, nil)) }
                continue
            }
            var holeInfo: (state: String, reason: String)?
            if gated.contains(r) { holeInfo = ("inaccessible", "consent") }
            else if st.st_dev != region.device { holeInfo = ("excluded", "filesystem:" + fsType(region.absolute(r))) }
            else if st.st_flags & UInt32(SF_DATALESS) != 0 { holeInfo = ("excluded", "cloud") }
            if ownOnly { walk.subdirectories.append((r, inode, holeInfo)); fts_set(fts, entry, Int32(FTS_SKIP)); continue }
            if let h = holeInfo { hole(r, h.state, h.reason, inode); fts_set(fts, entry, Int32(FTS_SKIP)) }
        case FTS_DNR:
            let inode = Int64(bitPattern: UInt64(entry.pointee.fts_statp.pointee.st_ino))
            hole(regionRel(entry), entry.pointee.fts_errno == EDEADLK ? "excluded" : "inaccessible", accessReason(entry.pointee.fts_errno), inode)
        case FTS_F:
            let st = entry.pointee.fts_statp.pointee
            if st.st_nlink > 1 && linked.count < 200_000 && !linked.insert(UInt64(st.st_ino)).inserted { walk.hardLinks += 1; continue }
            walk.files += 1; walk.logical += Int64(st.st_size); walk.allocated += inventoryAllocatedBytes(st)
        case FTS_SL, FTS_SLNONE, FTS_DEFAULT:
            walk.allocated += inventoryAllocatedBytes(entry.pointee.fts_statp.pointee)
        case FTS_NS, FTS_ERR:
            if entry.pointee.fts_errno != ENOENT { walk.unreadable += 1 }
        default: break   // FTS_DC (not possible with FTS_PHYSICAL), FTS_DOT
        }
    }
    return walk
}

// MARK: File events

final class CoverageActivity {
    // Inventory reuses this replay while acknowledging its own durable consumer cursor.
    var onEvent: ((String, UInt32, UInt64) -> Void)?
    let store: CoverageStore, region: CoverageRegion
    let until: UInt64
    var countFrom: UInt64 = 0                 // interval statistics count only events after this ID
    var lastEvent = [Int64: UInt64]()          // unit → latest event ID at or before `until`
    var late = Set<Int64>()                    // units with events after the reading's marker
    var listingDirty = Set<Int64>()
    var mustScan = [String]()                  // macOS asked for a rescan below these paths
    var counters = [Int64: [Int]]()            // unit → created, modified, removed, renamed, cloned, events
    var holeEvents = [Int64: Int]()
    var createdDirectories = Set<String>()     // directories created or renamed in during the interval
    var renamedUnits = Set<Int64>()
    var renamedNames = [Int64: Set<String>]()   // file names seen in rename events, per unit (bounded)
    var samples = [Int64: [String]]()
    var events = 0, outside = 0
    var historyDone = false, doneAt: Date?, lastId: UInt64 = 0
    var allGap = false, gaps = [String]()
    // Inventory distinguishes actual loss of event coverage from an unfinished or unavailable
    // replay (retried from the same cursor); coverage keeps treating every case as allGap.
    var lossDetected = false, timedOut = false, streamUnavailable = false
    /// Set only after FSEventStreamFlushSync returned following HistoryDone: every event generated
    /// before the stream was created has then been delivered, whatever order IDs arrived in.
    var flushed = false
    var lastDelivery: Date?                    // any callback, history or live: the replay is progressing
    init(store: CoverageStore, region: CoverageRegion, until: UInt64) { self.store = store; self.region = region; self.until = until }
    var finished: Bool { historyDone && (lastId >= until || Date().timeIntervalSince(doneAt ?? Date()) > 0.5) }

    func handle(_ path: String, _ flags: UInt32, _ id: UInt64) {
        lastDelivery = Date()
        onEvent?(path, flags, id)
        func has(_ flag: Int) -> Bool { flags & UInt32(flag) != 0 }
        if has(kFSEventStreamEventFlagHistoryDone) { historyDone = true; doneAt = Date(); lastId = max(lastId, id); return }
        lastId = max(lastId, id)
        if has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped) { if id <= until { allGap = true; lossDetected = true; gaps.append("File events were dropped by macOS") }; return }
        if has(kFSEventStreamEventFlagEventIdsWrapped) { allGap = true; lossDetected = true; gaps.append("File event IDs wrapped"); return }
        guard let rel = region.relative(fromDevice: path) else { outside += 1; return }
        guard let unitId = store.deepest(rel), let unit = store[unitId] else { return }
        if has(kFSEventStreamEventFlagRootChanged) && rel.isEmpty { allGap = true; lossDetected = true; gaps.append("The monitored root changed"); return }
        if has(kFSEventStreamEventFlagMustScanSubDirs) {
            if rel.isEmpty { allGap = true; lossDetected = true; gaps.append("macOS asked for a full rescan") } else { mustScan.append(rel); gaps.append("macOS asked for a rescan of \(region.display(rel))") }
        }
        let isDir = has(kFSEventStreamEventFlagItemIsDir)
        let structural = isDir && (has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved) || has(kFSEventStreamEventFlagItemRenamed)) || has(kFSEventStreamEventFlagMount) || has(kFSEventStreamEventFlagUnmount)
        let parentUnit = structural ? store.deepest(parentPath(rel)) : nil
        guard id <= until else {
            // After the reading: not this interval's activity, but never carried forward as unchanged.
            late.insert(unitId); if let parentUnit { late.insert(parentUnit) }
            return
        }
        if unit.isHole { if id > countFrom { holeEvents[unitId, default: 0] += 1 }; return }
        lastEvent[unitId] = max(lastEvent[unitId] ?? 0, id)
        if let parentUnit { listingDirty.insert(parentUnit); lastEvent[parentUnit] = max(lastEvent[parentUnit] ?? 0, id) }
        if has(kFSEventStreamEventFlagItemRenamed) {
            renamedUnits.insert(unitId); if let parentUnit { renamedUnits.insert(parentUnit) }
            if renamedNames[unitId, default: []].count < 256, let name = rel.split(separator: "/").last { renamedNames[unitId, default: []].insert(String(name)) }
        }
        guard id > countFrom else { return }
        if isDir && (has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRenamed)) { createdDirectories.insert(rel) }
        events += 1
        var count = counters[unitId] ?? [0, 0, 0, 0, 0, 0]
        if has(kFSEventStreamEventFlagItemCreated) { count[0] += 1 }
        if has(kFSEventStreamEventFlagItemModified) || has(kFSEventStreamEventFlagItemInodeMetaMod) { count[1] += 1 }
        if has(kFSEventStreamEventFlagItemRemoved) { count[2] += 1 }
        if has(kFSEventStreamEventFlagItemRenamed) { count[3] += 1 }
        if has(kFSEventStreamEventFlagItemCloned) { count[4] += 1 }
        count[5] += 1
        counters[unitId] = count
        if samples[unitId, default: []].count < 3, !path.contains(".sb-") {
            var labels = [String]()
            for (flag, name) in [(kFSEventStreamEventFlagItemCreated, "created"), (kFSEventStreamEventFlagItemModified, "modified"), (kFSEventStreamEventFlagItemRemoved, "removed"), (kFSEventStreamEventFlagItemRenamed, "renamed"), (kFSEventStreamEventFlagItemCloned, "cloned")] where has(flag) { labels.append(name) }
            samples[unitId, default: []].append(region.display(rel) + (labels.isEmpty ? "" : " [" + labels.joined(separator: ",") + "]"))
        }
    }
    func underRescan(_ rel: String) -> Bool { mustScan.contains { rel == $0 || rel.hasPrefix($0 + "/") || $0.hasPrefix(rel.isEmpty ? "" : rel + "/") } }
}

// With `whileDelivering`, `timeout` bounds a stall rather than the whole replay: a replay that
// keeps delivering is not abandoned before `ceiling` (inventory retries would redo all of it).
func replayDeadline(started: Date, lastDelivery: Date?, timeout: TimeInterval, whileDelivering: Bool, ceiling: TimeInterval) -> Date {
    guard whileDelivering else { return started.addingTimeInterval(timeout) }
    return min(started.addingTimeInterval(max(timeout, ceiling)), max(started, lastDelivery ?? started).addingTimeInterval(timeout))
}

// Replays this device's FSEvents history for (since, until] without staying resident. Paths are
// device-relative, so every firmlinked spelling of an object arrives as one path.
func replayCoverage(_ activity: CoverageActivity, since: UInt64, timeout: TimeInterval, whileDelivering: Bool = false, ceiling: TimeInterval = 0) {
    // Nothing can have been generated in an empty interval: the boundary is trivially complete.
    guard activity.until > since else { activity.historyDone = true; activity.flushed = true; activity.doneAt = .distantPast; activity.lastId = activity.until; return }
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(activity).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let activity = Unmanaged<CoverageActivity>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self)
        for index in 0..<count { activity.handle(list[index] as? String ?? "", flags[index], ids[index]) }
    }
    let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
    guard let stream = FSEventStreamCreateRelativeToDevice(kCFAllocatorDefault, callback, &context, activity.region.device, [activity.region.prefix] as CFArray, since, 0, flags) else {
        activity.allGap = true; activity.streamUnavailable = true; activity.gaps.append("File event stream unavailable"); return
    }
    let queue = DispatchQueue(label: "local.macbook.storage-monitor.coverage-events")
    FSEventStreamSetDispatchQueue(stream, queue)
    if FSEventStreamStart(stream) {
        let started = Date()
        var deadline = started.addingTimeInterval(timeout)
        func waiting() -> Bool {
            queue.sync {
                deadline = replayDeadline(started: started, lastDelivery: activity.lastDelivery, timeout: timeout, whileDelivering: whileDelivering, ceiling: ceiling)
                return !activity.historyDone && Date() < deadline
            }
        }
        while waiting() { Thread.sleep(forTimeInterval: 0.05) }
        if queue.sync(execute: { activity.historyDone }) { FSEventStreamFlushSync(stream); activity.flushed = true }
        while Date() < deadline && !queue.sync(execute: { activity.finished }) { Thread.sleep(forTimeInterval: 0.05) }
        FSEventStreamStop(stream)
    } else { activity.streamUnavailable = true }
    FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
    queue.sync {}
    if !activity.historyDone { activity.allGap = true; activity.timedOut = true; activity.gaps.append("File event history did not finish within \(Int(timeout)) s") }
}

// MARK: Measurement pass

// Applies walks to the store. In a scheduled check (readingId set) it also records changes
// against values valid at the previous reading; the initializer only establishes values.
final class CoveragePass {
    let store: CoverageStore, region: CoverageRegion, gated: ConsentGate
    let readingId: Int64?, previousId: Int64?
    var databasePath: String?                   // enables the stall watchdog
    let createdDuringInterval: (String) -> Bool
    let continuous: Bool
    var changes = [[String: Any]](), incomparable = [[String: Any]](), moves = [[String: Any]]()
    var measured = 0, firstMeasurements = 0, splits = 0, newHoles = 0
    var measuredUnits = [Int64: Int64]()        // unit → walk event, for reconciliation
    private var vanished = [CoverageUnit]()      // with descendants, before removal
    private var vanishedValues = [Int64: (logical: Int64, allocated: Int64, files: Int64, comparable: Bool)]()
    private var newDirectories = [(rel: String, inode: Int64, hole: (state: String, reason: String)?)]()
    private(set) var createdUnits = [Int64]()
    private var listingValidBefore = [Int64: Bool]()   // split units: listing current at the previous reading, before this pass re-listed it
    private(set) var movedFrom = [Int64: (path: String, logical: Int64, allocated: Int64, files: Int64, measuredAt: Double?, comparable: Bool)]()
    init(store: CoverageStore, region: CoverageRegion, gated: ConsentGate, readingId: Int64? = nil, previousId: Int64? = nil, continuous: Bool = false, createdDuringInterval: @escaping (String) -> Bool = { _ in false }) {
        self.store = store; self.region = region; self.gated = gated; self.readingId = readingId; self.previousId = previousId; self.continuous = continuous; self.createdDuringInterval = createdDuringInterval
    }
    var isCheck: Bool { readingId != nil }

    private func change(_ kind: String, _ unit: CoverageUnit, before: (logical: Int64, allocated: Int64, files: Int64, measuredAt: Double?), after: (logical: Int64, allocated: Int64, files: Int64, measuredAt: Double?), from: String? = nil) {
        let dl = after.logical - before.logical, da = after.allocated - before.allocated
        guard abs(dl) >= folderChangeThreshold || abs(da) >= folderChangeThreshold || kind == "moved" else { return }
        let top = unit.path.split(separator: "/").first.map(String.init) ?? ""
        var entry: [String: Any] = ["root": region.display(top), "path": region.display(unit.path), "rel": unit.path, "child": unit.name, "unit": unit.id, "kind": kind,
                                    "scope": unit.kind == "split" ? "files directly inside" : "folder",
                                    "before_logical": before.logical, "after_logical": after.logical, "before_allocated": before.allocated, "after_allocated": after.allocated,
                                    "before_files": before.files, "after_files": after.files, "before_measured_at": before.measuredAt ?? 0, "after_measured_at": after.measuredAt ?? 0]
        if let from { entry["moved_from"] = region.display(from) }
        changes.append(entry)
    }
    private func notComparable(_ unit: CoverageUnit, _ reason: String) { if isCheck { incomparable.append(["path": region.display(unit.path), "reason": reason]) } }

    // Measures one unit. Returns false when the walk could not establish a value.
    @discardableResult
    func measure(_ id: Int64, maxEntries: Int64, deadline: Date, allowSplit: Bool, now: () -> Date = Date.init) -> Bool {
        guard let unit = store[id] else { return false }
        let walkEvent = Int64(bitPattern: FSEventsGetCurrentEventId())
        let ownOnly = unit.kind == "split"
        if let databasePath { WalkWatchdog.shared.begin(db: databasePath, unit: id, path: region.display(unit.path), allowed: max(0, deadline.timeIntervalSinceNow)) }
        let walk = withThrottledIO { walkUnit(region, unit.path, isUnit: { [store] in $0 != unit.path && store.byPath[$0] != nil }, gated: gated, ownOnly: ownOnly, maxEntries: ownOnly ? Int64.max : maxEntries, deadline: deadline) }
        if databasePath != nil { WalkWatchdog.shared.end() }
        measured += 1
        let at = now().timeIntervalSince1970
        let before = unit
        if listingValidBefore[id] == nil { listingValidBefore[id] = unit.kind == "split" && previousId != nil && (unit.listingReading == previousId || unit.validAtReading(previousId)) }
        switch walk.status {
        case .absent, .notDirectory:
            vanish(id); return false
        case .otherFilesystem, .denied:
            let state = walk.status == .otherFilesystem || walk.error == EDEADLK ? "excluded" : "inaccessible"
            let reason = walk.status == .otherFilesystem ? "filesystem:" + walk.filesystem : (walk.error == -1 ? "consent" : accessReason(walk.error))
            for child in store.descendants(id) { store.remove(child) }
            store.modify(id) { $0.state = state; $0.reason = reason; $0.complete = false; $0.kind = "tree"; $0.attempts += 1; $0.lastAttempt = at; $0.validEvent = nil; $0.validAt = nil; $0.validReading = nil; $0.inode = walk.inode }
            if before.state == "baselined" { notComparable(before, reasonText(reason, fda: "")) }
            return false
        case .timedOut:
            store.modify(id) { $0.attempts += 1; $0.lastAttempt = at; $0.complete = false; $0.state = $0.attempts >= 3 ? "deferred" : "pending"; $0.reason = "timed_out"; $0.validReading = nil }
            notComparable(before, "Stopped at its time limit")
            return false
        case .exceeded:
            if allowSplit && unit.depth < coverageMaxDepth && store.count < coverageMaxUnits {
                store.modify(id) { $0.kind = "split"; $0.needsSplit = false; $0.reason = nil }
                splits += 1
                return measure(id, maxEntries: maxEntries, deadline: deadline, allowSplit: allowSplit, now: now)
            }
            if allowSplit && maxEntries < coverageLeafEntries {
                store.modify(id) { $0.reason = "unit_limit" }
                return measure(id, maxEntries: coverageLeafEntries, deadline: deadline, allowSplit: false, now: now)
            }
            store.modify(id) { $0.needsSplit = true; $0.state = "pending"; $0.reason = "split_pending"; $0.lastAttempt = at; $0.validReading = nil; $0.complete = false }
            notComparable(before, "Grew past one measurement unit; divided by the background job")
            return false
        case .complete: break
        }
        store.modify(id) { u in
            u.logical = walk.logical; u.allocated = walk.allocated; u.files = walk.files; u.entries = walk.entries; u.inode = walk.inode
            u.complete = true; u.state = "baselined"; if u.reason != "unit_limit" { u.reason = nil }; u.attempts = 0; u.lastAttempt = at; u.measuredAt = at
            u.validEvent = walkEvent; u.validAt = at; u.validReading = readingId; u.needsSplit = false
            if let readingId { if u.firstValidReading == nil { u.firstValidReading = readingId }; if u.kind == "split" { u.listingReading = readingId } }
            else { u.listingReading = nil }
        }
        measuredUnits[id] = walkEvent
        // Child units this walk should have reached but did not: gone. A listing (split unit) sees
        // only direct subdirectories; deeper units are re-parented when those are created.
        for child in store.children[id] ?? [] {
            guard let c = store[child], !c.path.isEmpty, !walk.nestedSeen.contains(c.path) else { continue }
            if ownOnly && (parentPath(c.path) != unit.path || walk.subdirectories.contains(where: { $0.rel == c.path })) { continue }
            vanish(child)
        }
        for h in walk.holes { store.create(path: h.rel, state: h.state, reason: h.reason, inode: h.inode, at: at); newHoles += 1 }
        if ownOnly {
            for sub in walk.subdirectories {
                if let existing = store.byPath[sub.rel] {
                    // A known unit that is now another filesystem or a placeholder is re-checked by its own walk.
                    if let hole = sub.hole, store[existing]?.state != hole.state { store.modify(existing) { $0.state = "pending" } }
                    continue
                }
                newDirectories.append(sub)
            }
        }
        guard isCheck else { return true }
        let after = store[id]!
        let afterValues = (after.logical, after.allocated, after.files, after.measuredAt)
        if let moved = movedFrom[id] {
            if moved.comparable { change("moved", after, before: (moved.logical, moved.allocated, moved.files, moved.measuredAt), after: afterValues, from: moved.path) }
            else { notComparable(after, "Moved; earlier size not comparable") }
        } else if !walk.holes.isEmpty || walk.holesCapped {
            notComparable(after, "A protected or separate subfolder appeared inside it")
        } else if before.kind != after.kind {
            notComparable(after, "Divided into smaller units")
        } else if before.validAtReading(previousId) {
            change(after.allocated >= before.allocated ? "grew" : "shrank", after, before: (before.logical, before.allocated, before.files, before.measuredAt), after: afterValues)
        } else if createdUnits.contains(id), continuous, let parent = after.parent, listingValidBefore[parent] ?? (store[parent]?.listingReading == previousId), createdDuringInterval(after.path) {
            change("new", after, before: (0, 0, 0, nil), after: afterValues)
        } else if before.firstValidReading == nil || before.state == "discovered" {
            firstMeasurements += 1
        } else {
            notComparable(after, before.validReading == nil ? "Not measured at the previous reading" : "Incomplete at the previous reading")
        }
        return true
    }

    private func vanish(_ id: Int64) {
        guard let unit = store[id] else { return }
        let all = [id] + store.descendants(id)
        var logical: Int64 = 0, allocated: Int64 = 0, files: Int64 = 0, comparable = true
        for member in all { guard let u = store[member] else { continue }; if u.isHole { continue }; logical += u.logical; allocated += u.allocated; files += u.files; comparable = comparable && u.validAtReading(previousId) }
        vanished.append(unit); vanishedValues[id] = (logical, allocated, files, comparable)
    }

    // Resolves renames (same directory inode reappearing elsewhere), removals and new directories.
    func finish(at now: Double) {
        var byInode = [Int64: CoverageUnit]()
        for unit in vanished { if let inode = unit.inode, inode != 0 { byInode[inode] = unit } }
        var matched = Set<Int64>()
        for dir in newDirectories where store.byPath[dir.rel] == nil {
            if dir.hole == nil, let old = byInode[dir.inode], !matched.contains(old.id), store[old.id] != nil, !dir.rel.hasPrefix(old.path + "/") {
                matched.insert(old.id)
                let values = vanishedValues[old.id]!
                movedFrom[old.id] = (old.path, values.logical, values.allocated, values.files, old.measuredAt, values.comparable)
                store.move(old.id, to: dir.rel)
                for member in [old.id] + store.descendants(old.id) { store.modify(member) { if !$0.isHole { $0.state = "pending" } } }
                moves.append(["from": region.display(old.path), "to": region.display(dir.rel), "allocated": values.allocated])
                continue
            }
            let unit = store.create(path: dir.rel, state: dir.hole?.state ?? "discovered", reason: dir.hole?.reason, inode: dir.inode, at: now)
            if dir.hole != nil { newHoles += 1 } else { createdUnits.append(unit.id) }
        }
        for unit in vanished where !matched.contains(unit.id) && store[unit.id] != nil {
            let values = vanishedValues[unit.id]!
            if isCheck {
                if values.comparable { change("removed", unit, before: (values.logical, values.allocated, values.files, unit.measuredAt), after: (0, 0, 0, now)) }
                else if !unit.isHole && unit.state != "discovered" { notComparable(unit, "Removed; earlier size not comparable") }
            }
            store.remove(unit.id)
        }
        vanished = []; vanishedValues = [:]; newDirectories = []
    }
}

// MARK: Lifecycle

struct CoverageNote: Codable, Equatable { var path: String; var state: String; var reason: String; var detail: String }
struct CoverageLifecycle: Codable {
    var version = 1
    var state: String                 // not_initialized | initializing | ready | partial | degraded
    var region: String?, regionDevice: String?, eventDevice: String?
    var units = 0, baselined = 0, discovered = 0, pending = 0, deferred = 0, inaccessible = 0, excluded = 0, stale = 0, reconcile = 0, splitPending = 0
    var monitored = 0                 // units valid at the latest reading (incrementally monitored)
    var measuredLogical: Int64 = 0, measuredAllocated: Int64 = 0, measuredFiles: Int64 = 0
    var fullDiskAccess = "unknown"
    var establishedAt: Double?        // initial coverage first reached a terminal state
    var comprehensiveSince: Double?, comprehensiveSinceReading: Int64?
    var lastReconciledAt: Double?     // the initializer last finished with no remaining work
    var lastContinuousAt: Double?     // the last check whose file history was continuous
    var lastCheckAt: Double?, lastCheckReading: Int64?
    var nextRetryAt: Double?
    var degradedReason: String?
    var notes = [CoverageNote]()      // inaccessible and excluded regions (first 40, shallowest first)
    var updatedAt: Double
    var initializer: InitializerProgress?
    var actionable: Int { discovered + pending + stale + reconcile + splitPending }
}
func decodeCoverageLifecycle(_ db: Database) -> CoverageLifecycle? { decodeState(db, "coverage_lifecycle", as: CoverageLifecycle.self) }
func saveCoverageLifecycle(_ db: Database, _ value: CoverageLifecycle) { try? encodeState(db, "coverage_lifecycle", value) }
struct CoverageCursor: Codable { var readingId: Int64; var eventId: UInt64; var device: String?; var timestamp: Double }

func coverageLifecycle(_ store: CoverageStore, region: CoverageRegion, fda: String, eventDevice: String?, at now: Double, previous: CoverageLifecycle?, degraded: String? = nil, latestReading: Int64? = nil) -> CoverageLifecycle {
    var value = previous ?? CoverageLifecycle(state: "not_initialized", updatedAt: now)
    value.updatedAt = now; value.region = region.display(""); value.regionDevice = region.deviceIdentifier; value.fullDiskAccess = fda
    if let eventDevice { value.eventDevice = eventDevice }
    value.units = store.count
    (value.baselined, value.discovered, value.pending, value.deferred, value.inaccessible, value.excluded, value.stale, value.reconcile, value.splitPending, value.monitored) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    (value.measuredLogical, value.measuredAllocated, value.measuredFiles) = (0, 0, 0)
    var notes = [CoverageUnit](), nextRetry: Double?
    for unit in store.units.values {
        switch unit.state {
        case "baselined": value.baselined += 1; value.measuredLogical += unit.logical; value.measuredAllocated += unit.allocated; value.measuredFiles += unit.files
        case "discovered": value.discovered += 1
        case "pending": if unit.needsSplit { value.splitPending += 1 } else { value.pending += 1 }
        case "deferred": value.deferred += 1
        case "inaccessible": value.inaccessible += 1; notes.append(unit)
        case "excluded": value.excluded += 1; notes.append(unit)
        case "stale": value.stale += 1
        case "reconcile": value.reconcile += 1
        default: value.pending += 1
        }
        if let latestReading, unit.validAtReading(latestReading) { value.monitored += 1 }
        if ["inaccessible", "deferred"].contains(unit.state), unit.reason != "consent", let last = unit.lastAttempt {
            let due = last + (unit.state == "inaccessible" ? 24 * 3600 : 6 * 3600)
            nextRetry = min(nextRetry ?? due, due)
        }
    }
    value.nextRetryAt = nextRetry
    value.notes = notes.sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }.prefix(40).map { CoverageNote(path: region.display($0.path), state: $0.state, reason: $0.reason ?? "", detail: reasonText($0.reason, fda: fda)) }
    value.degradedReason = degraded
    if store.count == 0 { value.state = "not_initialized" }
    else if value.establishedAt == nil { value.state = value.actionable > 0 ? "initializing" : "ready" }
    else if value.stale + value.reconcile > 0 || degraded != nil { value.state = "degraded" }
    else { value.state = value.inaccessible + value.deferred > 0 ? "partial" : "ready" }   // pending work is reported as a count
    if value.establishedAt == nil && value.state != "initializing" && store.count > 0 { value.establishedAt = now }
    if value.state == "ready" && value.inaccessible + value.deferred > 0 { value.state = "partial" }
    return value
}

// Coverage mode, from <data dir>/coverage.json ({"mode":"folders"} keeps the predefined folders only).
func coverageMode(_ directory: URL) -> String {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("coverage.json")),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let mode = root["mode"] as? String, ["folders", "comprehensive"].contains(mode) else { return "comprehensive" }
    return mode
}
// Work the background initializer should pick up now.
func coverageNeedsWork(_ db: Database, at now: Double = Date().timeIntervalSince1970) -> Bool {
    guard let value = decodeCoverageLifecycle(db) else { return true }
    if value.actionable > 0 || value.state == "not_initialized" || value.state == "degraded" { return true }
    return value.nextRetryAt.map { $0 <= now } ?? false
}
// Records a change in evidence scope, so history shows when comprehensive monitoring began.
func recordCoverageEpoch(_ db: Database, scope: String, readingId: Int64?, at time: Double, detail: String) {
    let last = (try? db.rows("SELECT scope FROM coverage_epochs ORDER BY id DESC LIMIT 1"))?.first?["scope"]
    guard last != scope else { return }
    try? db.write("INSERT INTO coverage_epochs(timestamp,reading_id,scope,detail) VALUES(?,?,?,?)", [time, readingId as Any, scope, detail])
}

// MARK: Initializer

// Builds and repairs comprehensive coverage in checkpointed, low-priority slices: discovers
// the partition top-down, measures each unit with its own FSEvents marker, re-measures units
// that changed while it ran, and retries protected or slow units on a bounded schedule.
// It never records readings, alerts, interval evidence or notifications.
func initializeCoverage(dbPath: String, directory: URL, region: CoverageRegion, options: InitializerOptions = InitializerOptions(), fdaOverride: String? = nil, gatedOverride: ConsentGate? = nil) -> (outcome: String, lifecycle: CoverageLifecycle?) {
    guard let worker = FileLock(directory.appendingPathComponent("initializer.lock").path, wait: 0) else { return ("already_running", nil) }
    defer { _ = worker }
    applyObservationalIOPolicy()
    var options = options
    if ProcessInfo.processInfo.isLowPowerModeEnabled && options.pause > 0 { options.sliceBudget = min(options.sliceBudget, 4); options.pause = max(options.pause, 5) }
    let started = Date()
    var progress = InitializerProgress(startedAt: started.timeIntervalSince1970, status: "running")
    var measuredThisRun = [Int64: Int64]()
    var rounds = 0, outcome = "terminal", lifecycle: CoverageLifecycle?
    loop: while true {
        if Date().timeIntervalSince(started) > options.maxDuration { outcome = "time_limit"; break }
        guard let lock = FileLock(directory.appendingPathComponent("attribution.lock").path, wait: 60), let db = try? Database(dbPath), let store = try? CoverageStore.load(db) else { outcome = "busy"; break }
        let now = Date().timeIntervalSince1970
        let marker = currentEventMarker(region.root)
        let fda = fdaOverride ?? fullDiskAccessState()
        let gated = gatedOverride ?? coverageGate(db, region: region, fda: fda)
        let previous = decodeCoverageLifecycle(db)
        if store.root == nil { store.create(path: "", at: now) }
        // A different event database voids every per-unit marker.
        if let device = previous?.eventDevice, device != marker.device {
            for unit in store.units.values where unit.validEvent != nil { store.modify(unit.id) { $0.validEvent = nil; $0.validAt = nil; if $0.state == "baselined" { $0.state = "reconcile" } } }
        }
        // Consent-gated folders become measurable when Full Disk Access is granted.
        if fda == "granted" { for unit in store.units.values where unit.reason == "consent" { store.modify(unit.id) { $0.state = "discovered"; $0.reason = nil } } }
        func needsWork(_ u: CoverageUnit) -> Bool {
            if u.needsSplit { return true }
            switch u.state {
            case "discovered", "pending", "stale", "reconcile": return true
            case "baselined": return !u.freshAt(now)
            case "deferred", "inaccessible": return u.retryDue(at: now, fda: fda)
            default: return false
            }
        }
        var queue = store.units.values.filter(needsWork).sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }.map(\.id)
        // Reconcile: units measured earlier in this run that changed afterwards are measured again.
        if queue.isEmpty, !measuredThisRun.isEmpty, rounds < options.reconcileRounds, let since = measuredThisRun.values.min() {
            rounds += 1
            let activity = CoverageActivity(store: store, region: region, until: marker.eventId)
            activity.countFrom = marker.eventId
            replayCoverage(activity, since: UInt64(since), timeout: 20)
            if options.simulateGap { activity.allGap = true }
            for (id, event) in measuredThisRun {
                guard let unit = store[id], !unit.isHole else { continue }
                if activity.allGap || !activity.historyDone || activity.underRescan(unit.path) || (activity.lastEvent[id] ?? 0) > UInt64(event) || activity.late.contains(id) {
                    store.modify(id) { $0.state = "reconcile"; $0.validEvent = nil; $0.validAt = nil }
                    queue.append(id); progress.reconciliations += 1
                }
            }
            measuredThisRun = [:]
        }
        if queue.isEmpty {
            store.aggregate()
            try? store.save(db)
            progress.status = "terminal"; progress.finishedAt = Date().timeIntervalSince1970; progress.peakMemoryBytes = peakMemoryBytes()
            var value = coverageLifecycle(store, region: region, fda: fda, eventDevice: marker.device, at: Date().timeIntervalSince1970, previous: previous)
            value.lastReconciledAt = Date().timeIntervalSince1970; value.initializer = progress
            saveCoverageLifecycle(db, value); lifecycle = value
            break loop
        }
        let pass = CoveragePass(store: store, region: region, gated: gated)
        pass.databasePath = dbPath
        let sliceEnd = Date().addingTimeInterval(options.sliceBudget)
        var interrupted = false
        for id in queue {
            if Date() >= sliceEnd { break }
            guard store[id] != nil else { continue }
            pass.measure(id, maxEntries: options.coverageSplit, deadline: Date().addingTimeInterval(options.perChildBudget), allowSplit: true)
            progress.measurements += 1
            if let path = store[id]?.path { options.onMeasured?(path) }
            if let stop = options.stopAfterMeasurements, progress.measurements >= stop { interrupted = true; break }
        }
        pass.finish(at: Date().timeIntervalSince1970)
        for (id, event) in pass.measuredUnits { measuredThisRun[id] = event }
        store.aggregate()
        try? store.save(db)   // durable checkpoint
        progress.peakMemoryBytes = peakMemoryBytes()
        var value = coverageLifecycle(store, region: region, fda: fda, eventDevice: marker.device, at: Date().timeIntervalSince1970, previous: previous)
        value.initializer = progress
        saveCoverageLifecycle(db, value); lifecycle = value
        _ = lock
        if interrupted { outcome = "interrupted"; break }
        Thread.sleep(forTimeInterval: options.pause)
    }
    if outcome != "terminal", let db = try? Database(dbPath), var value = decodeCoverageLifecycle(db) {
        progress.status = outcome; progress.peakMemoryBytes = peakMemoryBytes()
        value.initializer = progress; saveCoverageLifecycle(db, value); lifecycle = value
    }
    return (outcome, lifecycle)
}

// MARK: Processes

// Same-user processes, read-only: files held open for writing inside grown units, and regular
// files on this volume that are open but already deleted (their space is still allocated).
func coverageProcesses(db: Database, region: CoverageRegion, grown: [(label: String, prefixes: [String])], readingId: Int64, previousId: Int64?, budget: TimeInterval) -> [String: Any] {
    let started = Date()
    let samples = sampleUserProcesses()
    let prior = decodeState(db, "attribution_processes", as: ProcessBaseline.self)
    let priorWritten = prior.flatMap { $0.readingId == previousId && previousId != nil ? $0.written : nil } ?? [:]
    var correlations = [[String: Any]](), queries = 0, status = "complete"
    var deleted = [String: (pid: Int, name: String, files: Int, bytes: Int64)](), deletedSeen = Set<String>(), deletedBytes: Int64 = 0, deletedFiles = 0
    let device = UInt32(truncatingIfNeeded: region.device)
    scan: for sample in samples where sample.pid != getpid() {
        if Date().timeIntervalSince(started) > budget || queries > 50_000 { status = "partial"; break }
        let size = proc_pidinfo(sample.pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { continue }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
        let got = proc_pidinfo(sample.pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { continue }
        var inGrown = [String: (open: Int, writable: Int, example: String)]()
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            queries += 1
            if queries > 50_000 { status = "partial"; break scan }
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(sample.pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
            let st = info.pvip.vip_vi.vi_stat
            if st.vst_nlink == 0 && (st.vst_mode & UInt16(S_IFMT)) == UInt16(S_IFREG) && st.vst_dev == device {
                let key = "\(st.vst_dev):\(st.vst_ino)"
                if deletedSeen.insert(key).inserted {
                    let bytes = st.vst_blocks * 512
                    deletedBytes += bytes; deletedFiles += 1
                    var entry = deleted[sample.key] ?? (Int(sample.pid), sample.name, 0, 0); entry.files += 1; entry.bytes += bytes; deleted[sample.key] = entry
                }
            }
            guard !grown.isEmpty else { continue }
            let path = cString(info.pvip.vip_path, capacity: Int(MAXPATHLEN))
            let writable = info.pfi.fi_openflags & UInt32(FWRITE) != 0
            for folder in grown where folder.prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                var e = inGrown[folder.label] ?? (0, 0, path); e.open += 1; if writable { e.writable += 1; if e.writable == 1 { e.example = path } }; inGrown[folder.label] = e
            }
        }
        for (label, e) in inGrown where e.writable > 0 {
            var entry: [String: Any] = ["pid": Int(sample.pid), "name": sample.name, "executable": tilde(executablePath(sample.pid)), "folder": label, "open_files": e.open, "writable_files": e.writable, "example": tilde(e.example)]
            if let before = priorWritten[sample.key], sample.written >= before { entry["bytes_written_interval"] = Int64(sample.written - before) }
            correlations.append(entry)
        }
    }
    correlations.sort { ($0["writable_files"] as! Int) > ($1["writable_files"] as! Int) }
    try? encodeState(db, "attribution_processes", ProcessBaseline(readingId: readingId, written: Dictionary(samples.map { ($0.key, $0.written) }, uniquingKeysWith: { a, _ in a })))
    let holders = deleted.values.sorted { $0.bytes > $1.bytes }.prefix(5).map { ["pid": $0.pid, "name": $0.name, "files": $0.files, "allocated_bytes": $0.bytes] as [String: Any] }
    return ["status": grown.isEmpty ? (status == "complete" ? "not_needed" : status) : status, "sampled": samples.count,
            "method": "open files (proc_pidfdinfo) and disk-write counters (proc_pid_rusage) of same-user processes",
            "correlations": Array(correlations.prefix(10)),
            "open_deleted": ["status": status, "files": deletedFiles, "allocated_bytes": deletedBytes, "holders": holders,
                             "note": "Deleted files still held open by same-user processes; their space is freed when the process closes them. Other users' and system processes are not visible."]]
}

// MARK: Scheduled evidence

// Measured growth concentrated under one directory: the deepest ancestor holding at least
// three quarters of the measured change in one direction.
func concentration(_ changes: [[String: Any]], region: CoverageRegion, growth: Bool) -> [String: Any]? {
    let relevant = changes.filter { c in
        let kind = c["kind"] as? String ?? "", delta = int64(c["after_allocated"]) - int64(c["before_allocated"])
        return !["moved", "moved_in", "moved_out"].contains(kind) && (growth ? delta > 0 : delta < 0)
    }
    let total = relevant.reduce(Int64(0)) { $0 + abs(int64($1["after_allocated"]) - int64($1["before_allocated"])) }
    guard total >= folderChangeThreshold else { return nil }
    var sums = [String: Int64]()
    for c in relevant {
        let delta = abs(int64(c["after_allocated"]) - int64(c["before_allocated"]))
        var path = c["rel"] as? String ?? ""
        while true { sums[path, default: 0] += delta; if path.isEmpty { break }; path = parentPath(path) }
    }
    // The volume root says nothing about where the change happened.
    let best = sums.filter { !$0.key.isEmpty && Double($0.value) >= 0.75 * Double(total) }.max { $0.key.split(separator: "/").count < $1.key.split(separator: "/").count }
    guard let best else { return nil }
    return ["path": region.display(best.key), "allocated": best.value, "total": total, "share": Double(best.value) / Double(total)]
}

// Pairs a shrink and a growth of matching size in units whose rename events name the same
// file: a move within the volume, not new storage. Similar sizes alone are not evidence.
func pairMoves(_ changes: inout [[String: Any]], renamed: [Int64: Set<String>]) -> [[String: Any]] {
    func delta(_ c: [String: Any]) -> Int64 { int64(c["after_allocated"]) - int64(c["before_allocated"]) }
    func names(_ i: Int) -> Set<String> { renamed[int64(changes[i]["unit"])] ?? [] }
    var pairs = [[String: Any]](), used = Set<Int>()
    let candidates = changes.indices.filter { !names($0).isEmpty && ["grew", "shrank", "new", "removed"].contains(changes[$0]["kind"] as? String ?? "") }
    for out in candidates where delta(changes[out]) < 0 && !used.contains(out) {
        let size = -delta(changes[out])
        if let into = candidates.filter({ !used.contains($0) && $0 != out && delta(changes[$0]) > 0 && !names($0).isDisjoint(with: names(out)) }).min(by: { abs(delta(changes[$0]) - size) < abs(delta(changes[$1]) - size) }),
           abs(delta(changes[into]) - size) <= max(65_536, size / 100) {
            used.insert(out); used.insert(into)
            changes[out]["kind"] = "moved_out"; changes[into]["kind"] = "moved_in"
            changes[out]["paired_with"] = changes[into]["path"]; changes[into]["paired_with"] = changes[out]["path"]
            pairs.append(["from": changes[out]["path"] ?? "", "to": changes[into]["path"] ?? "", "allocated": size])
        }
    }
    return pairs
}

// Evidence for one reading interval from comprehensive coverage. Nil until coverage has been
// established (the predefined-folder evidence is used instead).
func collectCoverageEvidence(db: Database, readingId: Int64, readingTime: Double, previous: (id: Int64, time: Double)?, marker: EventMarker, region: CoverageRegion, volumeAllocated: Int64? = nil,
                             budget: TimeInterval = 25, replayTimeout: TimeInterval = 15, processBudget: TimeInterval = 3, now: () -> Date = Date.init,
                             simulateGap: Bool = false, lockPath: String? = nil, lockWait: TimeInterval = 45, fdaOverride: String? = nil, gatedOverride: ConsentGate? = nil, checkEntries: Int64 = coverageCheckEntries) -> [String: Any]? {
    let started = now()
    var lock: FileLock?
    if let lockPath {
        lock = FileLock(lockPath, wait: lockWait)
        if lock == nil {
            guard decodeCoverageLifecycle(db)?.establishedAt != nil else { return nil }
            return ["version": attributionVersion, "reading_id": readingId, "previous_reading_id": previous.map { NSNumber(value: $0.id) } ?? NSNull(), "collected_at": started.timeIntervalSince1970,
                    "coverage": ["scope": "comprehensive", "level": "unavailable"],
                    "folders": ["status": "busy", "scope": "comprehensive", "reason": "Filesystem coverage was being updated; evidence skipped for this reading."],
                    "file_activity": ["status": "unavailable", "reason": "Skipped while filesystem coverage was busy."], "processes": ["status": "skipped"], "duration_ms": Int(now().timeIntervalSince(started) * 1000)]
        }
    }
    defer { _ = lock }
    applyObservationalIOPolicy()
    guard let previousLifecycle = decodeCoverageLifecycle(db), previousLifecycle.establishedAt != nil, let store = try? CoverageStore.load(db), store.root != nil else { return nil }
    let fda = fdaOverride ?? fullDiskAccessState()
    let gated = gatedOverride ?? coverageGate(db, region: region, fda: fda)
    let previousId = previous?.id
    let cursor = decodeState(db, "coverage_cursor", as: CoverageCursor.self)
    let deviceMatches = marker.device != nil && previousLifecycle.eventDevice == marker.device

    // 1. File activity. The replay reaches back to the oldest unit value still trusted, so units
    //    measured between readings are validated too; statistics count only this interval.
    let intervalStart: UInt64? = {
        guard let cursor, deviceMatches, cursor.device == marker.device, cursor.readingId == previousId, readingTime - cursor.timestamp <= maxReplayAge, cursor.eventId <= marker.eventId else { return nil }
        return cursor.eventId
    }()
    var since = intervalStart
    if deviceMatches { for unit in store.units.values where unit.freshAt(readingTime) { if let event = unit.validEvent, UInt64(event) <= marker.eventId { since = min(since ?? UInt64(event), UInt64(event)) } } }
    let activity = CoverageActivity(store: store, region: region, until: marker.eventId)
    activity.countFrom = intervalStart ?? marker.eventId
    var unavailableReason: String?
    if let since { replayCoverage(activity, since: since, timeout: min(replayTimeout, budget * 0.6)) }
    else {
        activity.allGap = true
        unavailableReason = !deviceMatches ? "The file event database changed (volume UUID differs), so earlier history is not continuous." : "No trusted event marker remains; every unit must be re-measured."
    }
    if simulateGap { activity.allGap = true; activity.gaps.append("Simulated gap (self-test)") }
    let continuous = activity.historyDone && !activity.allGap

    // 2. Classify units: trusted (no activity since their own measurement) or needing work.
    let pass = CoveragePass(store: store, region: region, gated: gated, readingId: readingId, previousId: previousId, continuous: continuous && intervalStart != nil, createdDuringInterval: { activity.createdDirectories.contains($0) })
    pass.databasePath = sqlite3_db_filename(db.db, "main").map { String(cString: $0) }
    var trusted = Set<Int64>()
    struct Work { let id: Int64; let priority: Int; let weight: Int64 }
    var work = [Work]()
    for unit in store.units.values where !unit.isHole {
        let events = activity.counters[unit.id]?[5] ?? 0
        if unit.needsSplit { continue }   // the background job divides it
        if continuous, unit.freshAt(readingTime), let event = unit.validEvent, (activity.lastEvent[unit.id] ?? 0) <= UInt64(event), !activity.late.contains(unit.id), !activity.underRescan(unit.path) {
            trusted.insert(unit.id); continue
        }
        switch unit.state {
        case "baselined", "pending": work.append(Work(id: unit.id, priority: (activity.lastEvent[unit.id] != nil || activity.late.contains(unit.id)) ? 0 : 2, weight: events > 0 ? Int64(events) : unit.aggAllocated / 1_000_000))
        case "discovered": work.append(Work(id: unit.id, priority: 1, weight: 0))
        case "stale", "reconcile": work.append(Work(id: unit.id, priority: 3, weight: unit.aggAllocated))
        default:              // deferred: the background job retries on its schedule; never compared
            if intervalStart != nil { pass.incomparable.append(["path": region.display(unit.path), "reason": reasonText(unit.reason ?? "timed_out", fda: fda)]) }
        }
    }
    work.sort { $0.priority == $1.priority ? $0.weight > $1.weight : $0.priority < $1.priority }
    let deadline = started.addingTimeInterval(budget)
    var reached = Set<Int64>()
    func run(_ ids: [Int64]) {
        for id in ids {
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0.05 else { break }
            guard store[id] != nil else { continue }
            reached.insert(id)
            pass.measure(id, maxEntries: checkEntries, deadline: now().addingTimeInterval(min(remaining, 10)), allowSplit: false, now: now)
        }
    }
    run(work.map(\.id))
    pass.finish(at: now().timeIntervalSince1970)
    // New and moved directories found by re-listing, measured now when budget remains.
    let moved = Set(pass.movedFrom.keys.flatMap { [$0] + store.descendants($0) })
    run(pass.createdUnits.filter { !reached.contains($0) } + Array(moved))
    pass.finish(at: now().timeIntervalSince1970)

    // 3. Carry forward trusted units; mark the rest.
    var carried = 0
    for id in trusted {
        guard let unit = store[id], !reached.contains(id), unit.state == "baselined" else { continue }
        if unit.firstValidReading == nil { pass.firstMeasurements += 1 }
        else if intervalStart != nil && unit.validReading != previousId {
            // Re-measured between readings (background job): its change over this interval is unknown.
            pass.incomparable.append(["path": region.display(unit.path), "reason": "Re-measured between readings; comparable from the next reading"])
        }
        store.modify(id) { $0.validReading = readingId; $0.validEvent = Int64(bitPattern: marker.eventId); $0.validAt = readingTime; if $0.firstValidReading == nil { $0.firstValidReading = readingId }; if $0.kind == "split" { $0.listingReading = readingId } }
        carried += 1
    }
    var pendingCount = 0
    for unit in store.units.values where !unit.isHole && !trusted.contains(unit.id) && unit.validReading != readingId {
        if unit.state == "baselined" || unit.state == "pending" {
            store.modify(unit.id) { $0.state = continuous ? "pending" : ($0.freshAt(readingTime) || !deviceMatches ? "reconcile" : "stale") }
            if unit.validAtReading(previousId) { pass.incomparable.append(["path": region.display(unit.path), "reason": "Not re-measured within this check's time budget"]) }
        }
        if ["pending", "discovered", "stale", "reconcile"].contains(store[unit.id]?.state ?? "") { pendingCount += 1 }
    }
    store.aggregate()
    try? store.save(db)
    try? encodeState(db, "coverage_cursor", CoverageCursor(readingId: readingId, eventId: marker.eventId, device: marker.device, timestamp: readingTime))

    // 4. Changes: moves, concentration, and process correlation.
    var changes = pass.changes
    let filePairs = pairMoves(&changes, renamed: activity.renamedNames)
    changes.sort { abs(int64($0["after_allocated"]) - int64($0["before_allocated"])) > abs(int64($1["after_allocated"]) - int64($1["before_allocated"])) }
    let baselineOnly = intervalStart == nil || previousLifecycle.comprehensiveSince == nil
    let folderStatus = baselineOnly ? "baseline_only" : (pass.incomparable.isEmpty && pendingCount == 0 && continuous ? "complete" : "partial")
    let grownUnits = changes.filter { ["grew", "new", "moved"].contains($0["kind"] as? String ?? "") && max(int64($0["after_allocated"]) - int64($0["before_allocated"]), int64($0["after_logical"]) - int64($0["before_logical"])) >= correlationThreshold }
    let grown = grownUnits.prefix(20).compactMap { c -> (label: String, prefixes: [String])? in (c["rel"] as? String).map { (c["path"] as? String ?? "", region.absoluteForms($0)) } }
    let processes = coverageProcesses(db: db, region: region, grown: grown, readingId: readingId, previousId: previousId, budget: processBudget)

    // 5. Lifecycle, epoch and evidence.
    var lifecycle = coverageLifecycle(store, region: region, fda: fda, eventDevice: marker.device ?? previousLifecycle.eventDevice, at: readingTime, previous: previousLifecycle,
                                      degraded: continuous ? nil : (unavailableReason ?? "File-change history had a gap; affected units are re-measured."), latestReading: readingId)
    lifecycle.lastCheckAt = readingTime; lifecycle.lastCheckReading = readingId
    if continuous { lifecycle.lastContinuousAt = readingTime }
    if lifecycle.comprehensiveSince == nil {
        lifecycle.comprehensiveSince = readingTime; lifecycle.comprehensiveSinceReading = readingId
        recordCoverageEpoch(db, scope: "comprehensive", readingId: readingId, at: readingTime, detail: "Comprehensive filesystem coverage of \(region.display("")) began; earlier intervals used predefined monitored folders.")
    }
    saveCoverageLifecycle(db, lifecycle)

    let level = baselineOnly ? "baseline_only" : (folderStatus == "complete" ? "comprehensive" : "partial")
    let roots = store.children[store.byPath[""]!].map { Array($0) }?.compactMap { store[$0] }.filter { !$0.isHole }.sorted { $0.aggAllocated > $1.aggAllocated }.prefix(12).map { u -> [String: Any] in
        ["path": region.display(u.path), "label": u.name, "children": store.descendants(u.id).count, "allocated": u.aggAllocated, "logical": u.aggLogical, "complete": u.aggComplete, "permission_limited": Int(u.aggHoles)]
    } ?? []
    var groups = activity.counters.compactMap { id, count -> [String: Any]? in
        guard let unit = store[id] else { return nil }
        return ["path": region.display(unit.path), "created": count[0], "modified": count[1], "removed": count[2], "renamed": count[3], "cloned": count[4], "events": count[5]]
    }
    groups.sort { ($0["events"] as! Int) > ($1["events"] as! Int) }
    var samples = [String]()
    let sampleOrder = changes.compactMap { $0["unit"] as? Int64 } + activity.counters.sorted { $0.value[5] > $1.value[5] }.map(\.key)
    for id in sampleOrder where samples.count < 15 { for sample in activity.samples[id] ?? [] where samples.count < 15 && !samples.contains(sample) { samples.append(sample) } }
    let holeActivity = activity.holeEvents.sorted { $0.value > $1.value }.prefix(8).compactMap { id, n -> [String: Any]? in store[id].map { ["path": region.display($0.path), "events": n, "reason": $0.reason ?? ""] } }
    var activityJSON: [String: Any] = continuous || since != nil ? [
        "status": continuous ? "complete" : "gap", "device_uuid": marker.device ?? "", "since_event": intervalStart.map { NSNumber(value: $0) } ?? NSNull(), "until_event": marker.eventId,
        "events": activity.events, "distinct_paths": activity.events, "distinct_paths_capped": false, "truncated": false,
        "groups": Array(groups.prefix(25)), "gaps": Array(Set(activity.gaps)).sorted().prefix(10).map { $0 }, "samples": samples,
    ] : ["status": "unavailable", "reason": unavailableReason ?? "File event history unavailable."]
    if intervalStart == nil && activityJSON["status"] as? String != "unavailable" { activityJSON["status"] = "unavailable"; activityJSON["reason"] = "No event marker from the previous reading; file activity starts with the next interval." }
    let measuredAllocated = store.units.values.filter { $0.validAtReading(readingId) }.reduce(Int64(0)) { $0 + $1.allocated }
    var coverage: [String: Any] = [
        "scope": "comprehensive", "level": level, "region": region.display(""), "volume_device": region.deviceIdentifier, "units": store.count,
        "monitored": lifecycle.monitored, "baselined": lifecycle.baselined, "inaccessible": lifecycle.inaccessible, "excluded": lifecycle.excluded,
        "pending": pendingCount, "deferred": lifecycle.deferred, "full_disk_access": fda, "comprehensive_since": lifecycle.comprehensiveSince ?? readingTime,
        "measured_allocated": measuredAllocated, "volume_allocated": volumeAllocated.map { NSNumber(value: $0) } ?? NSNull(),
        "inaccessible_examples": lifecycle.notes.prefix(10).map { ["path": $0.path, "state": $0.state, "reason": $0.reason, "detail": $0.detail] },
        "inaccessible_activity": ["events": activity.holeEvents.values.reduce(0, +), "regions": holeActivity],
        "outside_events": activity.outside,
        "interpretation": "Measured sizes are file sizes (logical) and st_blocks allocation per unit, with hard links counted once per unit. They are not APFS physical allocation: clones, compression, snapshots, purgeable space and open-but-deleted files make them differ, and other container volumes are covered by APFS volume figures only.",
    ]
    if !continuous { coverage["gap_reason"] = unavailableReason ?? Array(Set(activity.gaps)).sorted().first ?? "File history incomplete" }
    let growthConcentration: Any = concentration(changes, region: region, growth: true) ?? NSNull()
    let reductionConcentration: Any = concentration(changes, region: region, growth: false) ?? NSNull()
    let method: String = continuous ? "incremental" : (pass.measured > 0 ? "full" : "deferred")
    let rescanRoots: [String] = continuous ? [] : [region.display("")]
    var folders: [String: Any] = ["status": folderStatus, "scope": "comprehensive", "method": method, "full_rescan_roots": rescanRoots]
    folders["measured"] = pass.measured; folders["carried"] = carried; folders["pending"] = pendingCount
    folders["first_measurements"] = pass.firstMeasurements; folders["deferred"] = lifecycle.deferred; folders["splits"] = pass.splits
    folders["roots"] = roots; folders["changes"] = Array(changes.prefix(40)); folders["changes_total"] = changes.count
    folders["incomparable"] = Array(pass.incomparable.prefix(20)); folders["incomparable_total"] = pass.incomparable.count
    folders["moves"] = Array((pass.moves + filePairs).prefix(10))
    folders["concentration"] = ["growth": growthConcentration, "reduction": reductionConcentration] as [String: Any]
    folders["rejected_roots"] = [[String: String]]()
    let previousReading: Any = previous.map { NSNumber(value: $0.id) } ?? NSNull()
    let intervalStartTime: Any = previous.map { NSNumber(value: $0.time) } ?? NSNull()
    var evidence: [String: Any] = ["version": attributionVersion, "reading_id": readingId, "previous_reading_id": previousReading, "collected_at": started.timeIntervalSince1970]
    evidence["interval"] = ["start": intervalStartTime, "end": readingTime] as [String: Any]
    evidence["coverage"] = coverage
    evidence["folders"] = folders
    evidence["file_activity"] = activityJSON
    evidence["processes"] = processes
    evidence["duration_ms"] = Int(now().timeIntervalSince(started) * 1000)
    // Keep each row bounded.
    if json(evidence).utf8.count > 32_000 {
        var folders = evidence["folders"] as! [String: Any]
        folders["changes"] = Array(changes.prefix(15)); folders["incomparable"] = Array(pass.incomparable.prefix(5)); folders["roots"] = Array(roots.prefix(6))
        evidence["folders"] = folders
        activityJSON["groups"] = Array(groups.prefix(8)); activityJSON["samples"] = Array(samples.prefix(5)); evidence["file_activity"] = activityJSON
    }
    return evidence
}
