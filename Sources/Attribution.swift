import Foundation
import CoreServices
import Darwin

// Folder-growth attribution between consecutive readings. See ATTRIBUTION.md.
//
// Each check: (1) replays FSEvents history between the previous reading's
// event marker and this reading's, (2) re-measures only the folders that
// changed (or everything, if continuity is broken), (3) reports a change only
// when a folder's previous measurement is valid at the previous reading, and
// (4) links processes to a grown folder only through files they hold open for
// writing there. Nothing reads file contents or follows symlinks.

let attributionVersion = 1
let folderChangeThreshold: Int64 = 1_000_000       // smaller changes are "unchanged"
func int64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
let correlationThreshold: Int64 = 10_000_000       // folders that must grow this much to look for processes
let maxReplayAge: TimeInterval = 6 * 3600          // older event markers are not trusted for carry-forward

// MARK: Roots

struct MonitoredRoot: Equatable { let path: String; let label: String }

func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

func defaultMonitoredRoots() -> [MonitoredRoot] {
    let items: [(String, String)] = [
        (".cache", "~/.cache"), (".codex", "~/.codex"), (".local/share", "~/.local/share"),
        ("Library/Caches", "Caches"),
        ("Library/Application Support/Claude", "Claude app data"), ("Library/Application Support/Code", "VS Code app data"), ("Library/Application Support/Cursor", "Cursor app data"),
        (".npm", "npm cache"), ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData"),
    ]
    return items.map { MonitoredRoot(path: home.appendingPathComponent($0.0).path, label: $0.1) }
}

// Optional extra roots (project build/temporary folders) from <data dir>/monitored-roots.json.
func configuredRoots(_ directory: URL) -> [MonitoredRoot] {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("monitored-roots.json")),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let items = root["roots"] as? [[String: Any]] else { return [] }
    return items.prefix(16).compactMap { item in
        guard let path = item["path"] as? String, path.hasPrefix("/") else { return nil }
        return MonitoredRoot(path: path, label: item["label"] as? String ?? (path as NSString).lastPathComponent)
    }
}

// Keeps existing, non-symlink directories inside the home folder that neither
// contain nor sit inside an already accepted root, so nothing is counted twice.
func validatedRoots(_ candidates: [MonitoredRoot], within base: String = home.path) -> (accepted: [MonitoredRoot], rejected: [[String: String]]) {
    var accepted = [MonitoredRoot](), rejected = [[String: String]]()
    let baseCanonical = canonicalPath(base) ?? base
    for candidate in candidates {
        var info = stat()
        guard lstat(candidate.path, &info) == 0 else { continue }  // absent: silently skipped
        if (info.st_mode & S_IFMT) == S_IFLNK { rejected.append(["path": candidate.path, "reason": "symlink"]); continue }
        guard (info.st_mode & S_IFMT) == S_IFDIR, let path = canonicalPath(candidate.path) else { rejected.append(["path": candidate.path, "reason": "not a folder"]); continue }
        guard path.hasPrefix(baseCanonical + "/") else { rejected.append(["path": candidate.path, "reason": "outside the home folder"]); continue }
        if let other = accepted.first(where: { path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path + "/") || $0.path == path }) {
            rejected.append(["path": candidate.path, "reason": "overlaps \(other.label)"]); continue
        }
        accepted.append(MonitoredRoot(path: path, label: candidate.label))
    }
    return (accepted, rejected)
}

// MARK: FSEvents

struct EventMarker { let eventId: UInt64; let device: String? }

func currentEventMarker(_ path: String = home.path) -> EventMarker {
    var info = stat()
    let device: String? = stat(path, &info) == 0 ? FSEventsCopyUUIDForDevice(info.st_dev).map { CFUUIDCreateString(nil, $0) as String } : nil
    return EventMarker(eventId: FSEventsGetCurrentEventId(), device: device)
}

final class FileActivity {
    let roots: [String], until: UInt64, maxEvents: Int
    // Events at or before this ID only mark folders dirty; they are not this interval's activity.
    var countFrom: UInt64 = 0
    var lastEvent = [String: UInt64]()     // latest event ID per "root\u{1}child"
    var scanned = 0
    var events = 0, historyDone = false, doneAt: Date?, lastId: UInt64 = 0, truncated = false
    var gaps = [String](), gapRoots = Set<String>(), allGap = false
    var counters = [String: [Int]]()       // "root\u{1}child" → created, modified, removed, renamed, cloned, events
    var samples = [String: [String]]()
    var distinct = Set<String>(), distinctCapped = false
    var lateDirty = [String: Set<String>]()
    init(roots: [String], until: UInt64, maxEvents: Int) { self.roots = roots; self.until = until; self.maxEvents = maxEvents }
    var finished: Bool { historyDone && (lastId >= until || Date().timeIntervalSince(doneAt ?? Date()) > 0.5) }
    static func key(_ root: String, _ child: String) -> String { root + "\u{1}" + child }

    func handle(_ path: String, _ flags: UInt32, _ id: UInt64) {
        func has(_ flag: Int) -> Bool { flags & UInt32(flag) != 0 }
        if has(kFSEventStreamEventFlagHistoryDone) { historyDone = true; doneAt = Date(); lastId = max(lastId, id); return }
        lastId = max(lastId, id)
        guard id <= until else {
            // After this reading's marker: not this interval's activity, but the
            // folder is re-measured now so it is never carried forward as unchanged.
            if let root = roots.first(where: { path.hasPrefix($0 + "/") }) {
                let relative = path.dropFirst(root.count + 1)
                lateDirty[root, default: []].insert(String(relative.split(separator: "/", maxSplits: 1).first ?? Substring(relative)))
            }
            return
        }
        if has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped) { allGap = true; gaps.append("File events were dropped by macOS"); return }
        if has(kFSEventStreamEventFlagEventIdsWrapped) { allGap = true; gaps.append("File event IDs wrapped"); return }
        guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            if has(kFSEventStreamEventFlagMustScanSubDirs) { allGap = true; gaps.append("macOS asked for a full rescan") }
            return
        }
        if path == root {
            if has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagRootChanged) || has(kFSEventStreamEventFlagMount) || has(kFSEventStreamEventFlagUnmount) {
                gapRoots.insert(root); gaps.append("\(root): full rescan required")
            }
            return
        }
        let relative = String(path.dropFirst(root.count + 1))
        let child = String(relative.split(separator: "/", maxSplits: 1).first ?? Substring(relative))
        let key = Self.key(root, child)
        lastEvent[key] = max(lastEvent[key] ?? 0, id)
        if has(kFSEventStreamEventFlagMustScanSubDirs) { gapRoots.insert(root) }
        scanned += 1
        if scanned > maxEvents * 2 { if !truncated { truncated = true; allGap = true; gaps.append("Too many file events to replay; activity is incomplete") }; return }
        guard id > countFrom else { return }
        events += 1
        if events > maxEvents { if !truncated { truncated = true; allGap = true; gaps.append("More than \(maxEvents) file events; activity is incomplete") }; return }
        var count = counters[key] ?? [0, 0, 0, 0, 0, 0]
        if has(kFSEventStreamEventFlagItemCreated) { count[0] += 1 }
        if has(kFSEventStreamEventFlagItemModified) || has(kFSEventStreamEventFlagItemInodeMetaMod) { count[1] += 1 }
        if has(kFSEventStreamEventFlagItemRemoved) { count[2] += 1 }
        if has(kFSEventStreamEventFlagItemRenamed) { count[3] += 1 }
        if has(kFSEventStreamEventFlagItemCloned) { count[4] += 1 }
        count[5] += 1
        counters[key] = count
        if distinct.count < 50_000 { distinct.insert(path) } else { distinctCapped = true }
        if samples[key, default: []].count < 5, !path.contains(".sb-") {
            var labels = [String]()
            for (flag, name) in [(kFSEventStreamEventFlagItemCreated, "created"), (kFSEventStreamEventFlagItemModified, "modified"), (kFSEventStreamEventFlagItemRemoved, "removed"), (kFSEventStreamEventFlagItemRenamed, "renamed"), (kFSEventStreamEventFlagItemCloned, "cloned")] where has(flag) { labels.append(name) }
            samples[key, default: []].append(relative + (labels.isEmpty ? "" : " [" + labels.joined(separator: ",") + "]"))
        }
    }
    // True when the folder changed after the given event ID (or after this reading's marker).
    func changed(_ root: String, _ child: String, after event: UInt64) -> Bool {
        lateDirty[root]?.contains(child) == true || (lastEvent[Self.key(root, child)] ?? 0) > event
    }
    func dirty(_ root: String) -> Set<String> {
        lateDirty[root, default: []].union(counters.keys.compactMap { key in
            let parts = key.components(separatedBy: "\u{1}")
            return parts.count == 2 && parts[0] == root ? parts[1] : nil
        })
    }
}

// Replays FSEvents history for (since, until] without staying resident.
func replayFileActivity(roots: [String], since: UInt64, until: UInt64, countFrom: UInt64? = nil, timeout: TimeInterval = 10, maxEvents: Int = 200_000) -> FileActivity {
    let activity = FileActivity(roots: roots, until: until, maxEvents: maxEvents)
    activity.countFrom = countFrom ?? since
    guard !roots.isEmpty, until > since else { activity.historyDone = true; activity.doneAt = .distantPast; activity.lastId = until; return activity }
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(activity).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let activity = Unmanaged<FileActivity>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self)
        for index in 0..<count { activity.handle(list[index] as? String ?? "", flags[index], ids[index]) }
    }
    let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
    guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, roots as CFArray, since, 0, flags) else {
        activity.allGap = true; activity.gaps.append("File event stream unavailable"); return activity
    }
    let queue = DispatchQueue(label: "local.macbook.storage-monitor.fsevents")
    FSEventStreamSetDispatchQueue(stream, queue)
    if FSEventStreamStart(stream) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !queue.sync(execute: { activity.historyDone }) { Thread.sleep(forTimeInterval: 0.05) }
        // Events logged before the reading but not yet delivered would otherwise be
        // missed, and their folders wrongly carried forward as unchanged.
        if queue.sync(execute: { activity.historyDone }) { FSEventStreamFlushSync(stream) }
        while Date() < deadline && !queue.sync(execute: { activity.finished }) { Thread.sleep(forTimeInterval: 0.05) }
        FSEventStreamStop(stream)
    }
    FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
    queue.sync {}
    if !activity.historyDone { activity.allGap = true; activity.gaps.append("File event history did not finish within \(Int(timeout)) s") }
    return activity
}

// MARK: Baseline

struct ChildState: Codable {
    var logical: Int64, allocated: Int64, files: Int
    var complete: Bool, status: String
    var measuredAt: Double
    var validThrough: Int64      // last reading this value is known to describe
    var pending: Bool
    // Per-folder validity (absent in baselines written before initialization support).
    var validEvent: UInt64? = nil   // FSEvents ID at which this value is known current (taken before the walk)
    var validAt: Double? = nil      // wall time of validEvent
    var attempts: Int? = nil        // consecutive incomplete measurements
    var lastAttempt: Double? = nil
    var origin: String? = nil       // "scheduled" or "initializer"
    var everValid: Bool? = nil      // has been valid at some reading (distinguishes first measurements)

    var isPlaceholder: Bool { measuredAt == 0 }
    var unavailable: Bool { status == "failed" || (status == "partial" && !complete) }
    // Ready to be trusted at a later reading if file events show no change since validEvent.
    func hasFreshValue(at now: Double) -> Bool { complete && validEvent != nil && (validAt.map { now - $0 <= maxReplayAge } ?? false) }
    // Bounded retries: protected folders daily, repeated timeouts every 6 hours after 3 attempts.
    func retryDue(at now: Double) -> Bool {
        guard !complete, let last = lastAttempt else { return true }
        if status == "failed" || status == "partial" { return now - last >= 24 * 3600 }
        if (attempts ?? 0) >= 3 { return now - last >= 6 * 3600 }
        return true
    }
}
struct RootState: Codable {
    var children = [String: ChildState]()
    var listingValidThrough: Int64 = 0
}
struct AttributionBaseline: Codable {
    var version = 1
    var readingId: Int64
    var eventId: UInt64
    var device: String?
    var timestamp: Double
    var roots = [String: RootState]()
}
struct ProcessBaseline: Codable { var readingId: Int64; var written: [String: UInt64] }

// Baselines written before per-folder validity: a value valid at the baseline's
// reading is valid at that reading's marker.
func migrated(_ baseline: AttributionBaseline) -> AttributionBaseline {
    var copy = baseline
    for (root, var state) in copy.roots {
        for (name, var child) in state.children where child.validEvent == nil && child.validThrough == baseline.readingId && baseline.readingId > 0 && child.complete {
            child.validEvent = baseline.eventId; child.validAt = baseline.timestamp; child.everValid = true
            state.children[name] = child
        }
        copy.roots[root] = state
    }
    return copy
}

// MARK: Locks

// Serializes reads and writes of the baseline between the scheduled check and the initializer.
final class FileLock {
    let fd: Int32
    init?(_ path: String, wait: TimeInterval) {
        fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline { close(fd); return nil }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    deinit { _ = flock(fd, LOCK_UN); close(fd) }
}

func decodeState<T: Decodable>(_ db: Database, _ key: String, as type: T.Type) -> T? {
    guard let text = try? db.state(key), !text.isEmpty else { return nil }
    return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
}
func encodeState<T: Encodable>(_ db: Database, _ key: String, _ value: T) throws {
    try db.state(key, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
}

// One child of a root: a file is measured directly, a folder is walked, a symlink is not followed.
func measureChild(_ path: String, budget: TimeInterval) -> (logical: Int64, allocated: Int64, files: Int, complete: Bool, status: String, permission: Int) {
    var info = stat()
    guard lstat(path, &info) == 0 else { return (0, 0, 0, false, "absent", 0) }
    switch info.st_mode & S_IFMT {
    case S_IFLNK: return (0, 0, 0, true, "symlink not followed", 0)
    case S_IFREG:
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return (Int64(values?.fileSize ?? Int(info.st_size)), Int64(values?.totalFileAllocatedSize ?? Int(info.st_blocks) * 512), 1, true, "complete", 0)
    case S_IFDIR:
        let result = measureDirectory(DirectoryTarget(source: "attribution", label: (path as NSString).lastPathComponent, path: path), budget: budget, maxEntries: 400_000)
        return (result.logical, result.allocated, result.files, result.status == .complete, result.status.rawValue, result.permission.count)
    default: return (0, 0, 0, true, "special file", 0)
    }
}

// MARK: Processes

struct ProcessSample { let key: String; let pid: pid_t; let name: String; let written: UInt64 }

func cString<T>(_ value: T, capacity: Int) -> String {
    withUnsafePointer(to: value) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } }
}

// Same-user processes with lifetime disk-write bytes. Read-only; no signals.
func sampleUserProcesses() -> [ProcessSample] {
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var samples = [ProcessSample]()
    for pid in pids.prefix(max(0, count)) where pid > 0 {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == getuid() else { continue }
        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
        var name = cString(info.pbi_name, capacity: 32)
        if name.isEmpty { name = cString(info.pbi_comm, capacity: 17) }
        samples.append(ProcessSample(key: "\(pid):\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)", pid: pid, name: name, written: rc == 0 ? usage.ri_diskio_byteswritten : 0))
    }
    return samples
}

func executablePath(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
}

// Open files of one process under any of the given folders.
func openFiles(_ pid: pid_t, under prefixes: [String], queries: inout Int) -> [(path: String, writable: Bool)] {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
    guard got > 0 else { return [] }
    var result = [(String, Bool)]()
    for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        queries += 1
        if queries > 50_000 { break }
        var info = vnode_fdinfowithpath()
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
        let path = cString(info.pvip.vip_path, capacity: Int(MAXPATHLEN))
        if prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { result.append((path, info.pfi.fi_openflags & UInt32(FWRITE) != 0)) }
    }
    return result
}

// MARK: Collection

func tilde(_ path: String) -> String {
    let base = canonicalPath(home.path) ?? home.path
    return path.hasPrefix(base + "/") ? "~" + path.dropFirst(base.count) : path
}

func collectIntervalEvidence(db: Database, readingId: Int64, readingTime: Double, previous: (id: Int64, time: Double)?, marker: EventMarker,
                             roots candidates: [MonitoredRoot], within base: String = home.path, budget: TimeInterval = 25, replayTimeout: TimeInterval = 10, processBudget: TimeInterval = 3,
                             now: () -> Date = Date.init, simulateActivityGap: Bool = false, includeProcesses: Bool = true, lockPath: String? = nil, lockWait: TimeInterval = 45) -> [String: Any] {
    let started = now()
    let (roots, rejected) = validatedRoots(candidates, within: base)
    let previousId = previous?.id ?? -1
    // The initializer may be checkpointing; wait briefly, never indefinitely.
    var lock: FileLock?
    if let lockPath {
        lock = FileLock(lockPath, wait: lockWait)
        if lock == nil {
            return ["version": attributionVersion, "reading_id": readingId, "previous_reading_id": previous.map { NSNumber(value: $0.id) } ?? NSNull(), "collected_at": started.timeIntervalSince1970,
                    "folders": ["status": "busy", "reason": "Folder baseline was being updated; folder evidence skipped for this reading."], "file_activity": ["status": "unavailable", "reason": "Skipped while the folder baseline was busy."],
                    "processes": ["status": "skipped"], "duration_ms": Int(now().timeIntervalSince(started) * 1000)]
        }
    }
    defer { _ = lock }
    var baseline = decodeState(db, "attribution_baseline", as: AttributionBaseline.self).map(migrated)
    if baseline?.version != 1 { baseline = nil }
    let deviceMatches = baseline != nil && marker.device != nil && baseline!.device == marker.device

    // 1. File activity. The replay window reaches back to the oldest folder value still
    //    trusted, so folders measured between readings are validated too. Interval
    //    statistics count only events after the previous reading's marker.
    let intervalStart: UInt64? = {
        guard let baseline, deviceMatches, baseline.readingId == previousId, previousId > 0, readingTime - baseline.timestamp <= maxReplayAge, baseline.eventId <= marker.eventId else { return nil }
        return baseline.eventId
    }()
    var oldestValid: UInt64?
    if deviceMatches {
        for (_, rootState) in baseline!.roots { for (_, child) in rootState.children where child.hasFreshValue(at: readingTime) {
            if let event = child.validEvent, event <= marker.eventId { oldestValid = min(oldestValid ?? event, event) }
        } }
        if let start = intervalStart { oldestValid = min(oldestValid ?? start, start) }
    }
    var activity: FileActivity?
    var activityJSON: [String: Any] = ["status": "unavailable"]
    if let since = oldestValid {
        let replay = replayFileActivity(roots: roots.map(\.path), since: since, until: marker.eventId, countFrom: intervalStart ?? marker.eventId, timeout: replayTimeout)
        if simulateActivityGap { replay.allGap = true; replay.gaps.append("Simulated gap (self-test)") }
        activity = replay
    }
    if let replay = activity, let start = intervalStart {
        let status = replay.allGap || !replay.gapRoots.isEmpty ? "gap" : "complete"
        var groups = replay.counters.map { key, count -> [String: Any] in
            let parts = key.components(separatedBy: "\u{1}")
            return ["path": tilde(parts[0] + "/" + parts[1]), "created": count[0], "modified": count[1], "removed": count[2], "renamed": count[3], "cloned": count[4], "events": count[5]]
        }
        groups.sort { ($0["events"] as! Int) > ($1["events"] as! Int) }
        activityJSON = ["status": status, "device_uuid": marker.device ?? "", "since_event": start, "until_event": marker.eventId, "events": replay.events,
                        "distinct_paths": replay.distinct.count, "distinct_paths_capped": replay.distinctCapped, "truncated": replay.truncated,
                        "groups": Array(groups.prefix(25)), "gaps": Array(Set(replay.gaps)).sorted().prefix(10).map { $0 }]
    } else {
        let reason: String
        if baseline == nil { reason = "No event marker from an earlier reading yet; file activity starts with the next interval." }
        else if marker.device == nil || !deviceMatches { reason = "The file event database changed (volume UUID differs), so history before this reading is not continuous." }
        else if baseline!.readingId != previousId { reason = "The previous reading has no event marker, so this interval's history cannot be bounded." }
        else if readingTime - baseline!.timestamp > maxReplayAge { reason = "The previous marker is more than 6 hours old; macOS may have purged that history, so all folders were re-measured." }
        else { reason = "File event IDs went backwards." }
        activityJSON = ["status": "unavailable", "reason": reason]
    }
    func rootContinuous(_ root: String) -> Bool { activity.map { !$0.allGap && !$0.gapRoots.contains(root) && $0.historyDone } ?? false }

    // 2. Folder measurements.
    var state = baseline?.roots ?? [:]
    let deadline = started.addingTimeInterval(budget)
    var changes = [[String: Any]](), incomparable = [[String: Any]](), rootSummaries = [[String: Any]]()
    var measuredCount = 0, carriedCount = 0, pendingCount = 0, firstCount = 0, deferredCount = 0, fullRoots = [String]()
    struct Work { let root: String; let child: String; let priority: Int }
    var work = [Work](), listings = [String: Set<String>](), trusted = Set<String>()
    for root in roots {
        let rootState = state[root.path] ?? RootState()
        let continuous = rootContinuous(root.path)
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
        let listing = Set(names.prefix(3000))
        listings[root.path] = listing
        if !continuous { fullRoots.append(root.label) }
        for name in listing {
            let key = root.path + "\u{1}" + name
            guard let child = rootState.children[name], !child.isPlaceholder else { work.append(Work(root: root.path, child: name, priority: 1)); continue }  // new or never measured
            if child.complete && continuous && child.hasFreshValue(at: readingTime) && !(activity?.changed(root.path, name, after: child.validEvent!) ?? true) {
                trusted.insert(key)                                         // unchanged since its own measurement
                if started.timeIntervalSince1970 - child.measuredAt > 6 * 3600 { work.append(Work(root: root.path, child: name, priority: 3)) }
            } else if child.complete { work.append(Work(root: root.path, child: name, priority: 0)) }   // changed, gap, or stale
            else if child.retryDue(at: readingTime) { work.append(Work(root: root.path, child: name, priority: 2)) }
            else { deferredCount += 1 }                                       // protected or repeatedly timed out
        }
    }
    // Deduplicate, keep the highest priority, cap drift refreshes at 20 per check.
    var seen = Set<String>(), queue = [Work](), refreshes = 0
    for item in work.sorted(by: { $0.priority < $1.priority }) where seen.insert(item.root + "\u{1}" + item.child).inserted {
        if item.priority == 3 { refreshes += 1; if refreshes > 20 { continue } }
        queue.append(item)
    }
    var measured = Set<String>()
    for item in queue {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0.05 else { break }
        let path = item.root + "/" + item.child
        let walkMarker = currentEventMarker(item.root)
        let result = measureChild(path, budget: min(remaining, 15))
        measuredCount += 1
        measured.insert(item.root + "\u{1}" + item.child)
        var rootState = state[item.root] ?? RootState()
        let old = rootState.children[item.child]
        if result.status == "absent" { rootState.children[item.child] = nil; state[item.root] = rootState; continue }  // vanished since listing
        let attempts = result.complete ? 0 : (old?.attempts ?? 0) + 1
        var fresh = ChildState(logical: result.logical, allocated: result.allocated, files: result.files, complete: result.complete, status: result.status, measuredAt: now().timeIntervalSince1970, validThrough: readingId, pending: !result.complete,
                               validEvent: result.complete ? walkMarker.eventId : nil, validAt: result.complete ? now().timeIntervalSince1970 : nil, attempts: attempts, lastAttempt: now().timeIntervalSince1970, origin: "scheduled", everValid: true)
        if result.complete && walkMarker.device != marker.device { fresh.validEvent = nil }
        func record(_ kind: String, before: ChildState?) {
            let dl = fresh.logical - (before?.logical ?? 0), da = fresh.allocated - (before?.allocated ?? 0)
            guard abs(dl) >= folderChangeThreshold || abs(da) >= folderChangeThreshold else { return }
            changes.append(["root": tilde(item.root), "path": tilde(path), "child": item.child, "kind": kind,
                            "before_logical": before?.logical ?? 0, "after_logical": fresh.logical, "before_allocated": before?.allocated ?? 0, "after_allocated": fresh.allocated,
                            "before_files": before?.files ?? 0, "after_files": fresh.files, "before_measured_at": before?.measuredAt ?? 0, "after_measured_at": fresh.measuredAt])
        }
        if let old, !old.isPlaceholder, old.everValid == true || old.validThrough > 0 {
            if old.validThrough == previousId && old.complete && fresh.complete { record(fresh.allocated >= old.allocated ? "grew" : "shrank", before: old) }
            else if old.validThrough != previousId { incomparable.append(["path": tilde(path), "reason": "Not measured at the previous reading"]) }
            else { incomparable.append(["path": tilde(path), "reason": "Incomplete measurement (\(fresh.complete ? old.status : fresh.status))"]) }
        } else if old == nil && rootState.listingValidThrough == previousId && previousId > 0 && fresh.complete {
            record("new", before: nil)                                        // appeared during the interval
        } else {
            firstCount += 1                                                   // first measurement: a baseline, never growth
        }
        rootState.children[item.child] = fresh
        state[item.root] = rootState
    }
    // Carry forward trusted folders, mark unreached work pending, and record removals.
    for root in roots {
        guard var rootState = state[root.path] ?? (listings[root.path] != nil ? RootState() : nil), let listing = listings[root.path] else { pendingCount += state[root.path]?.children.count ?? 0; continue }
        for (name, var child) in rootState.children {
            let key = root.path + "\u{1}" + name
            if !listing.contains(name) {
                // Only a folder valid at the previous reading can show a removal; others vanish silently.
                if child.validThrough == previousId && child.complete && previousId > 0 && (abs(child.allocated) >= folderChangeThreshold || abs(child.logical) >= folderChangeThreshold) {
                    changes.append(["root": tilde(root.path), "path": tilde(root.path + "/" + name), "child": name, "kind": "removed", "before_logical": child.logical, "after_logical": Int64(0), "before_allocated": child.allocated, "after_allocated": Int64(0),
                                    "before_files": child.files, "after_files": 0, "before_measured_at": child.measuredAt, "after_measured_at": now().timeIntervalSince1970])
                }
                rootState.children[name] = nil; continue
            }
            if measured.contains(key) { continue }
            if trusted.contains(key) {
                if child.everValid != true { firstCount += 1 }
                child.validThrough = readingId; child.validEvent = marker.eventId; child.validAt = readingTime; child.pending = false; child.everValid = true
                carriedCount += 1
            } else if child.complete || child.isPlaceholder || child.retryDue(at: readingTime) { child.pending = true; pendingCount += 1 }
            rootState.children[name] = child
        }
        for name in listing where rootState.children[name] == nil {
            rootState.children[name] = ChildState(logical: 0, allocated: 0, files: 0, complete: false, status: "not yet measured", measuredAt: 0, validThrough: 0, pending: true)
            pendingCount += 1
        }
        rootState.listingValidThrough = readingId
        state[root.path] = rootState
        let children = rootState.children.values
        let current = children.filter { $0.validThrough == readingId && $0.complete }
        rootSummaries.append(["path": tilde(root.path), "label": root.label, "children": children.count, "current_children": current.count,
                              "logical": current.reduce(Int64(0)) { $0 + $1.logical }, "allocated": current.reduce(Int64(0)) { $0 + $1.allocated },
                              "complete": current.count == children.count,
                              "permission_limited": children.filter(\.unavailable).count])
    }
    for root in state.keys where !roots.contains(where: { $0.path == root }) { state[root] = nil }  // roots no longer monitored
    changes.sort { abs(int64($0["after_allocated"]) - int64($0["before_allocated"])) > abs(int64($1["after_allocated"]) - int64($1["before_allocated"])) }
    let folderStatus = previousId <= 0 || baseline == nil ? "baseline_only" : (incomparable.isEmpty && pendingCount == 0 ? "complete" : "partial")

    // 3. Process correlation: only through writable files inside grown folders.
    let processStarted = now()
    let samples = includeProcesses ? sampleUserProcesses() : []
    let priorProcesses = decodeState(db, "attribution_processes", as: ProcessBaseline.self)
    let priorWritten = priorProcesses?.readingId == previousId ? priorProcesses!.written : [:]
    let grown = changes.filter { ["grew", "new"].contains($0["kind"] as! String) && max(int64($0["after_allocated"]) - int64($0["before_allocated"]), int64($0["after_logical"]) - int64($0["before_logical"])) >= correlationThreshold }
    let base = canonicalPath(home.path) ?? home.path
    let grownPaths = grown.map { ($0["path"] as! String).hasPrefix("~") ? base + ($0["path"] as! String).dropFirst() : $0["path"] as! String }
    var correlations = [[String: Any]](), queries = 0, processStatus = !includeProcesses ? "skipped" : (grownPaths.isEmpty ? "not_needed" : "complete")
    if !grownPaths.isEmpty {
        for sample in samples where sample.pid != getpid() {
            if now().timeIntervalSince(processStarted) > processBudget || queries > 50_000 { processStatus = "partial"; break }
            let files = openFiles(sample.pid, under: grownPaths, queries: &queries)
            let writable = files.filter(\.writable)
            guard !writable.isEmpty else { continue }
            for folder in grownPaths where writable.contains(where: { $0.path.hasPrefix(folder + "/") || $0.path == folder }) {
                let inFolder = files.filter { $0.path.hasPrefix(folder + "/") || $0.path == folder }
                var entry: [String: Any] = ["pid": Int(sample.pid), "name": sample.name, "executable": tilde(executablePath(sample.pid)), "folder": tilde(folder),
                                            "open_files": inFolder.count, "writable_files": inFolder.filter(\.writable).count, "example": tilde(inFolder.first(where: \.writable)!.path)]
                if let before = priorWritten[sample.key], sample.written >= before { entry["bytes_written_interval"] = Int64(sample.written - before) }
                correlations.append(entry)
            }
        }
        correlations.sort { ($0["writable_files"] as! Int) > ($1["writable_files"] as! Int) }
    }
    if includeProcesses { try? encodeState(db, "attribution_processes", ProcessBaseline(readingId: readingId, written: Dictionary(samples.map { ($0.key, $0.written) }, uniquingKeysWith: { a, _ in a }))) }

    // 4. Samples of changed paths, grown folders first.
    var pathSamples = [String]()
    if let activity {
        let order = changes.compactMap { change -> String? in
            guard let root = roots.first(where: { tilde($0.path) == change["root"] as? String }) else { return nil }
            return FileActivity.key(root.path, change["child"] as! String)
        } + activity.samples.keys.sorted()
        for key in order where pathSamples.count < 15 {
            let parts = key.components(separatedBy: "\u{1}")
            for sample in activity.samples[key] ?? [] where pathSamples.count < 15 && !pathSamples.contains(tilde(parts[0]) + "/" + sample) { pathSamples.append(tilde(parts[0]) + "/" + sample) }
        }
    }
    activityJSON["samples"] = pathSamples

    // 5. Persist the baseline for the next interval, and the coverage summary.
    let next = AttributionBaseline(readingId: readingId, eventId: marker.eventId, device: marker.device, timestamp: readingTime, roots: state)
    try? encodeState(db, "attribution_baseline", next)
    let degraded: String? = baseline == nil ? nil : (activity == nil ? (activityJSON["reason"] as? String) : ((activity!.allGap || !activity!.gapRoots.isEmpty) ? "File-change history had a gap; affected folders are re-measured." : nil))
    saveLifecycle(db, baselineLifecycle(next, roots: roots, at: readingTime, degraded: degraded, previous: decodeLifecycle(db)))

    var evidence: [String: Any] = [
        "version": attributionVersion, "reading_id": readingId, "previous_reading_id": previous.map { NSNumber(value: $0.id) } ?? NSNull(), "collected_at": started.timeIntervalSince1970,
        "interval": ["start": previous.map { NSNumber(value: $0.time) } ?? NSNull(), "end": readingTime],
        "folders": ["status": folderStatus, "method": fullRoots.isEmpty ? "incremental" : (fullRoots.count == roots.count ? "full" : "mixed"), "full_rescan_roots": fullRoots,
                    "measured": measuredCount, "carried": carriedCount, "pending": pendingCount, "first_measurements": firstCount, "deferred": deferredCount, "roots": rootSummaries,
                    "changes": Array(changes.prefix(40)), "changes_total": changes.count,
                    "incomparable": Array(incomparable.prefix(20)), "incomparable_total": incomparable.count, "rejected_roots": rejected],
        "file_activity": activityJSON,
        "processes": ["status": processStatus, "sampled": samples.count, "method": includeProcesses ? "open files (proc_pidfdinfo) and disk-write counters (proc_pid_rusage) of same-user processes" : "Suppressed for disposable lifecycle QA",
                      "correlations": Array(correlations.prefix(10))],
        "duration_ms": Int(now().timeIntervalSince(started) * 1000),
    ]
    // Keep each row bounded.
    if json(evidence).utf8.count > 24_000 {
        var folders = evidence["folders"] as! [String: Any]
        folders["changes"] = Array(changes.prefix(15)); folders["incomparable"] = Array(incomparable.prefix(5))
        evidence["folders"] = folders
        activityJSON["groups"] = Array((activityJSON["groups"] as? [[String: Any]] ?? []).prefix(8)); activityJSON["samples"] = Array(pathSamples.prefix(5))
        evidence["file_activity"] = activityJSON
    }
    return evidence
}

// MARK: Lifecycle

struct InitializerProgress: Codable {
    var startedAt: Double
    var finishedAt: Double?
    var status: String              // running | terminal | interrupted | time_limit | busy | deferred
    var measurements = 0            // folder measurements (one bounded walk each)
    var reconciliations = 0         // re-measurements after file activity during initialization
    var peakMemoryBytes: Int64?
}
struct BaselineLifecycle: Codable {
    var state: String               // not_initialized | initializing | ready | partial | degraded
    var discovered = 0, baselined = 0, pending = 0, incomplete = 0, unavailable = 0
    var comparableNext = 0          // folders valid at the latest reading (comparable for the next interval)
    var degradedReason: String?
    var updatedAt: Double
    var initializer: InitializerProgress?
}
func decodeLifecycle(_ db: Database) -> BaselineLifecycle? { decodeState(db, "attribution_lifecycle", as: BaselineLifecycle.self) }
func saveLifecycle(_ db: Database, _ value: BaselineLifecycle) { try? encodeState(db, "attribution_lifecycle", value) }

// Coverage, from per-folder state. Never counts an unmeasured folder as baselined.
func baselineLifecycle(_ baseline: AttributionBaseline?, roots: [MonitoredRoot], at now: Double, degraded: String?, previous: BaselineLifecycle?) -> BaselineLifecycle {
    var value = BaselineLifecycle(state: "not_initialized", updatedAt: now, initializer: previous?.initializer)
    guard let baseline else { return value }
    let monitored = Set(roots.map(\.path))
    for (root, rootState) in baseline.roots where monitored.contains(root) {
        for (_, child) in rootState.children {
            value.discovered += 1
            if child.complete && child.validThrough == baseline.readingId && baseline.readingId > 0 { value.comparableNext += 1 }
            if child.complete && child.hasFreshValue(at: now) { value.baselined += 1 }
            else if child.complete || child.isPlaceholder { value.pending += 1 }
            else if child.unavailable { value.unavailable += 1 }
            else if (child.attempts ?? 0) >= 3 { value.incomplete += 1 }
            else { value.pending += 1 }
        }
    }
    value.degradedReason = degraded
    if degraded != nil && value.baselined > 0 { value.state = "degraded" }
    else if value.pending > 0 || value.discovered == 0 { value.state = "initializing" }
    else if value.incomplete + value.unavailable > 0 { value.state = "partial" }
    else { value.state = "ready" }
    return value
}

// MARK: Initializer

struct InitializerOptions {
    var sliceBudget: TimeInterval = 8          // measuring time per checkpoint while holding the baseline lock
    var perChildBudget: TimeInterval = 30
    var maxDuration: TimeInterval = 1800
    var pause: TimeInterval = 1                // yield between slices
    var reconcileRounds = 3
    var stopAfterMeasurements: Int?            // tests: simulate interruption
    var onMeasured: ((String) -> Void)?        // tests: filesystem activity during initialization
    var simulateGap = false
    var coverageSplit: Int64 = coverageSplitEntries   // comprehensive coverage: entries before a unit is split (tests use small trees)
}

func peakMemoryBytes() -> Int64 { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Int64(usage.ru_maxrss) }

// Builds a complete baseline without waiting for scheduled checks. Each folder keeps its
// own measurement time and FSEvents marker; nothing is assigned a shared timestamp.
// Returns the outcome and the resulting coverage.
func initializeBaseline(dbPath: String, directory: URL, roots candidates: [MonitoredRoot], within base: String = home.path, options: InitializerOptions = InitializerOptions()) -> (outcome: String, lifecycle: BaselineLifecycle?) {
    guard let worker = FileLock(directory.appendingPathComponent("initializer.lock").path, wait: 0) else { return ("already_running", nil) }
    defer { _ = worker }
    // Low Power Mode: keep going, but more gently (shorter slices, longer pauses).
    var options = options
    if ProcessInfo.processInfo.isLowPowerModeEnabled && options.pause > 0 { options.sliceBudget = min(options.sliceBudget, 4); options.pause = max(options.pause, 5) }
    let started = Date()
    var progress = InitializerProgress(startedAt: started.timeIntervalSince1970, status: "running")
    var measuredThisRun = [String: UInt64]()           // key → validEvent, for reconciliation
    var rounds = 0, outcome = "terminal", lifecycle: BaselineLifecycle?
    let (roots, _) = validatedRoots(candidates, within: base)
    loop: while true {
        if Date().timeIntervalSince(started) > options.maxDuration { outcome = "time_limit"; break }
        guard let lock = FileLock(directory.appendingPathComponent("attribution.lock").path, wait: 60), let db = try? Database(dbPath) else { outcome = "busy"; break }
        let marker = currentEventMarker(roots.first?.path ?? home.path)
        var baseline = decodeState(db, "attribution_baseline", as: AttributionBaseline.self).map(migrated) ?? AttributionBaseline(readingId: 0, eventId: 0, device: marker.device, timestamp: 0)
        if baseline.device != marker.device {                // event database changed: per-folder markers are void
            for (root, var rootState) in baseline.roots { for name in rootState.children.keys { rootState.children[name]?.validEvent = nil; rootState.children[name]?.validAt = nil }; baseline.roots[root] = rootState }
            baseline.device = marker.device
        }
        // Current listings: new folders get placeholders; deleted folders are dropped (no negative growth is recorded here).
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            let listing = Set(names.prefix(3000))
            var rootState = baseline.roots[root.path] ?? RootState()
            for name in listing where rootState.children[name] == nil { rootState.children[name] = ChildState(logical: 0, allocated: 0, files: 0, complete: false, status: "not yet measured", measuredAt: 0, validThrough: 0, pending: true) }
            for name in rootState.children.keys where !listing.contains(name) { rootState.children[name] = nil; measuredThisRun[root.path + "\u{1}" + name] = nil }
            baseline.roots[root.path] = rootState
        }
        let now = Date().timeIntervalSince1970
        func needsWork(_ child: ChildState) -> Bool {
            if child.isPlaceholder { return true }
            if child.complete { return !child.hasFreshValue(at: now) }
            if child.unavailable { return child.lastAttempt == nil || child.retryDue(at: now) }
            return (child.attempts ?? 0) < 3 || child.retryDue(at: now)
        }
        var queue = [(String, String)]()
        for root in roots { for (name, child) in baseline.roots[root.path]?.children ?? [:] where needsWork(child) { queue.append((root.path, name)) } }
        queue.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }

        // Reconcile: folders measured earlier in this run that changed afterwards are measured again.
        if queue.isEmpty, !measuredThisRun.isEmpty, rounds < options.reconcileRounds, let since = measuredThisRun.values.min() {
            rounds += 1
            let replay = replayFileActivity(roots: roots.map(\.path), since: since, until: marker.eventId, countFrom: marker.eventId)
            if options.simulateGap { replay.allGap = true }
            for (key, event) in measuredThisRun {
                let parts = key.components(separatedBy: "\u{1}")
                guard parts.count == 2 else { continue }
                if replay.allGap || replay.gapRoots.contains(parts[0]) || !replay.historyDone || replay.changed(parts[0], parts[1], after: event) {
                    baseline.roots[parts[0]]?.children[parts[1]]?.validEvent = nil
                    baseline.roots[parts[0]]?.children[parts[1]]?.validAt = nil
                    queue.append((parts[0], parts[1])); progress.reconciliations += 1
                }
            }
            measuredThisRun = [:]
        }
        if queue.isEmpty {
            try? encodeState(db, "attribution_baseline", baseline)
            progress.status = "terminal"; progress.finishedAt = Date().timeIntervalSince1970; progress.peakMemoryBytes = peakMemoryBytes()
            var value = baselineLifecycle(baseline, roots: roots, at: Date().timeIntervalSince1970, degraded: nil, previous: decodeLifecycle(db)); value.initializer = progress
            saveLifecycle(db, value); lifecycle = value
            break loop
        }
        // One slice of measurements, then a checkpoint.
        let sliceEnd = Date().addingTimeInterval(options.sliceBudget)
        var interrupted = false
        for (root, name) in queue {
            if Date() >= sliceEnd { break }
            let walkMarker = currentEventMarker(root)
            let result = measureChild(root + "/" + name, budget: options.perChildBudget)
            progress.measurements += 1
            let key = root + "\u{1}" + name
            let old = baseline.roots[root]?.children[name]
            if result.status == "absent" { baseline.roots[root]?.children[name] = nil; measuredThisRun[key] = nil }
            else {
                let at = Date().timeIntervalSince1970
                // validThrough stays unmatched: this value describes the walk time, not any reading.
                var fresh = ChildState(logical: result.logical, allocated: result.allocated, files: result.files, complete: result.complete, status: result.status, measuredAt: at, validThrough: Int64.min, pending: !result.complete,
                                       validEvent: nil, validAt: nil, attempts: result.complete ? 0 : (old?.attempts ?? 0) + 1, lastAttempt: at, origin: "initializer", everValid: old?.everValid)
                if result.complete && walkMarker.device == baseline.device { fresh.validEvent = walkMarker.eventId; fresh.validAt = at; measuredThisRun[key] = walkMarker.eventId }
                baseline.roots[root]?.children[name] = fresh
            }
            options.onMeasured?(key)
            if let stop = options.stopAfterMeasurements, progress.measurements >= stop { interrupted = true; break }
        }
        try? encodeState(db, "attribution_baseline", baseline)       // durable checkpoint
        progress.peakMemoryBytes = peakMemoryBytes()
        var value = baselineLifecycle(baseline, roots: roots, at: Date().timeIntervalSince1970, degraded: nil, previous: decodeLifecycle(db)); value.initializer = progress
        saveLifecycle(db, value); lifecycle = value
        _ = lock
        if interrupted { outcome = "interrupted"; break }
        Thread.sleep(forTimeInterval: options.pause)
    }
    if outcome != "terminal", let db = try? Database(dbPath), var value = decodeLifecycle(db) {
        progress.status = outcome; progress.peakMemoryBytes = peakMemoryBytes()
        value.initializer = progress; saveLifecycle(db, value); lifecycle = value
    }
    return (outcome, lifecycle)
}

// MARK: Self-test

func attributionSelfTest(_ test: (Bool, String) throws -> Void) throws {
    // FSEvents records /private/tmp; the per-user temporary folder is not used here.
    let sandbox = monitorSelfTestFixture("attribution").path
    let rootA = sandbox + "/rootA"
    defer { _ = chmod(rootA + "/c_locked", 0o700); finishMonitorSelfTestFixture(URL(fileURLWithPath: sandbox)) }
    func dir(_ name: String) throws { try fm.createDirectory(atPath: rootA + "/" + name, withIntermediateDirectories: true) }
    func write(_ path: String, _ bytes: Int) throws { try Data(count: bytes).write(to: URL(fileURLWithPath: rootA + "/" + path)) }
    func append(_ path: String, _ bytes: Int) throws { let h = try FileHandle(forWritingTo: URL(fileURLWithPath: rootA + "/" + path)); try h.seekToEnd(); try h.write(contentsOf: Data(count: bytes)); try h.close() }
    for name in ["c_create", "c_grow", "c_delete", "c_move_src", "c_move_dst", "c_clone", "c_sparse", "c_idle", "c_locked", "w1", "w2", "nested"] { try dir(name) }
    try write("c_grow/log.bin", 1_000_000); try write("c_delete/old.bin", 5_000_000); try write("c_move_src/item.bin", 4_000_000)
    try write("c_clone/source.bin", 3_000_000); try write("c_idle/keep.bin", 2_000_000); try write("c_locked/secret.bin", 10); try write("top.bin", 2_000_000)
    _ = chmod(rootA + "/c_locked", 0)
    try fm.createSymbolicLink(atPath: sandbox + "/link", withDestinationPath: rootA)
    let dbPath = sandbox + "/attr.sqlite3"
    let roots = [MonitoredRoot(path: rootA, label: "A"), MonitoredRoot(path: rootA + "/nested", label: "nested"), MonitoredRoot(path: sandbox + "/link", label: "link")]
    func collect(_ id: Int64, previous: (Int64, Double)?) throws -> [String: Any] {
        let db = try Database(dbPath)   // reopened every time, as separate launchd runs do
        Thread.sleep(forTimeInterval: 1.2)  // let fseventsd record the preceding writes
        let marker = currentEventMarker(rootA)
        return collectIntervalEvidence(db: db, readingId: id, readingTime: Date().timeIntervalSince1970, previous: previous.map { (id: $0.0, time: $0.1) }, marker: marker, roots: roots, within: "/private/tmp")
    }
    func folders(_ e: [String: Any]) -> [String: Any] { e["folders"] as? [String: Any] ?? [:] }
    func change(_ e: [String: Any], _ child: String) -> [String: Any]? { (folders(e)["changes"] as? [[String: Any]])?.first { $0["child"] as? String == child } }
    func delta(_ c: [String: Any]?, _ kind: String = "allocated") -> Int64 { guard let c else { return 0 }; return int64(c["after_" + kind]) - int64(c["before_" + kind]) }

    let first = try collect(1, previous: nil)
    let rejected = (folders(first)["rejected_roots"] as? [[String: String]] ?? []).map { $0["reason"] ?? "" }
    try test(rejected.contains { $0.hasPrefix("overlaps") } && rejected.contains("symlink"), "nested and symlinked roots are rejected (no double counting, no symlink following)")
    try test(folders(first)["status"] as? String == "baseline_only" && (folders(first)["changes"] as? [Any])?.isEmpty == true, "first measurement is only a baseline; no growth inferred from one snapshot")
    try test((first["file_activity"] as? [String: Any])?["status"] as? String == "unavailable", "no file activity claimed before an event marker exists")

    // Changes during interval 1 → 2.
    try dir("c_create"); try write("c_create/new.bin", 3_000_000)
    try append("c_grow/log.bin", 12_000_000)
    try fm.removeItem(atPath: rootA + "/c_delete/old.bin")
    try fm.moveItem(atPath: rootA + "/c_move_src/item.bin", toPath: rootA + "/c_move_dst/item.bin")
    _ = copyfile(rootA + "/c_clone/source.bin", rootA + "/c_clone/copy.bin", nil, copyfile_flags_t(COPYFILE_CLONE))
    let sparse = open(rootA + "/c_sparse/sparse.bin", O_CREAT | O_WRONLY, 0o600); _ = pwrite(sparse, "x", 1, 500_000_000); close(sparse)
    try write("w1/a.bin", 0); try write("w2/b.bin", 0)
    let group = DispatchGroup()
    for (name, bytes) in [("w1", 3_000_000), ("w2", 5_000_000)] { DispatchQueue.global().async(group: group) { for _ in 0..<10 { try? append(name == "w1" ? "w1/a.bin" : "w2/b.bin", bytes / 10) } } }
    group.wait()
    try dir("c_new"); try write("c_new/fresh.bin", 2_000_000)
    // A process holding a file open for writing inside a grown folder.
    let holder = Process(); holder.executableURL = URL(fileURLWithPath: "/bin/sh"); holder.arguments = ["-c", "exec 3>>'\(rootA)/c_grow/log.bin'; exec /bin/sleep 30"]
    try holder.run(); defer { holder.terminate(); holder.waitUntilExit() }
    Thread.sleep(forTimeInterval: 0.5)

    let second = try collect(2, previous: (1, 0))
    try test(delta(change(second, "c_create"), "logical") == 3_000_000, "file creation measured as folder growth")
    try test(delta(change(second, "c_grow"), "logical") == 12_000_000 && change(second, "c_grow")?["kind"] as? String == "grew", "file growth measured")
    try test(delta(change(second, "c_delete"), "logical") == -5_000_000 && change(second, "c_delete")?["kind"] as? String == "shrank", "file deletion measured as shrinkage")
    try test(delta(change(second, "c_move_src"), "logical") == -4_000_000 && delta(change(second, "c_move_dst"), "logical") == 4_000_000, "move between folders shows as shrink plus growth, not net new storage")
    try test(delta(change(second, "c_clone"), "logical") >= 3_000_000, "APFS clone appears as logical folder growth (documented: not physical)")
    let sparseChange = change(second, "c_sparse")
    try test(delta(sparseChange, "logical") >= 500_000_000 && delta(sparseChange) < 1_000_000, "sparse file: large logical growth, tiny allocated growth, both recorded")
    try test(delta(change(second, "w1"), "logical") == 3_000_000 && delta(change(second, "w2"), "logical") == 5_000_000, "simultaneous writers into separate folders measured independently")
    try test(change(second, "c_new")?["kind"] as? String == "new" && delta(change(second, "c_new"), "logical") == 2_000_000, "folder created during the interval reported as new")
    try test(change(second, "c_idle") == nil && (folders(second)["carried"] as? Int ?? 0) >= 1, "untouched folder carried forward without re-measuring")
    try test((folders(second)["deferred"] as? Int ?? 0) >= 1 && change(second, "c_locked") == nil, "permission-denied folder is deferred as unavailable, never a change or a retry every check")
    let activity = second["file_activity"] as? [String: Any] ?? [:]
    let groups = activity["groups"] as? [[String: Any]] ?? []
    try test(activity["status"] as? String == "complete" && groups.contains { ($0["path"] as? String ?? "").hasSuffix("c_create") && ($0["created"] as? Int ?? 0) >= 1 }, "file activity replayed from FSEvents history between readings")
    try test(groups.contains { ($0["path"] as? String ?? "").hasSuffix("c_clone") && ($0["cloned"] as? Int ?? 0) >= 1 }, "clone flagged in file activity")
    try test(groups.contains { ($0["path"] as? String ?? "").hasSuffix("c_delete") && ($0["removed"] as? Int ?? 0) >= 1 } && groups.contains { ($0["path"] as? String ?? "").hasSuffix("c_move_dst") && ($0["renamed"] as? Int ?? 0) >= 1 }, "deletion and rename flagged in file activity")
    try test(!groups.contains { ($0["path"] as? String ?? "").hasSuffix("c_idle") }, "no activity invented for untouched folders")
    let correlations = (second["processes"] as? [String: Any])?["correlations"] as? [[String: Any]] ?? []
    try test(correlations.contains { ($0["folder"] as? String ?? "").hasSuffix("c_grow") && ($0["writable_files"] as? Int ?? 0) >= 1 }, "process holding a writable file in a grown folder is correlated")
    try test(!correlations.contains { ($0["folder"] as? String ?? "").hasSuffix("c_new") }, "no process linked to a grown folder without open-file evidence")
    try test(json(second).utf8.count < 24_000, "evidence row is bounded (\(json(second).utf8.count) bytes)")
    holder.terminate(); holder.waitUntilExit()

    // Quiet interval: incremental and cheap.
    let quiet = try collect(3, previous: (2, 0))
    try test((quiet["folders"] as? [String: Any])?["method"] as? String == "incremental" && (folders(quiet)["changes"] as? [Any])?.isEmpty == true, "quiet interval reports no changes")
    try test((folders(quiet)["measured"] as? Int ?? 99) <= 1 && (quiet["duration_ms"] as? Int ?? 9999) < 1500, "quiet interval re-measures only pending folders (\(folders(quiet)["measured"] ?? -1) measured, \(quiet["duration_ms"] ?? -1) ms)")

    // FSEvents continuity break: full rescan, still comparable with the previous reading.
    let gapDB = try Database(dbPath)
    if var baseline = decodeState(gapDB, "attribution_baseline", as: AttributionBaseline.self) { baseline.device = "00000000-0000-0000-0000-000000000000"; try encodeState(gapDB, "attribution_baseline", baseline) }
    try write("c_create/more.bin", 2_000_000)
    let gap = try collect(4, previous: (3, 0))
    try test((gap["file_activity"] as? [String: Any])?["status"] as? String == "unavailable" && folders(gap)["method"] as? String == "full", "FSEvents database change detected; folders fully re-measured")
    try test(delta(change(gap, "c_create"), "logical") == 2_000_000, "growth still measured across an event gap, from folder sizes valid at the previous reading")
    try test(folders(gap)["carried"] as? Int == 0, "after an event-database change nothing is carried forward as unchanged")

    // Safeguard: a gap inside otherwise continuous history carries nothing forward.
    try write("c_idle/drift.bin", 3_000_000)   // a change the gap would hide
    func collectWith(_ id: Int64, previous: (Int64, Double), gap: Bool = false, readingTime: Double = Date().timeIntervalSince1970) throws -> [String: Any] {
        let db = try Database(dbPath); Thread.sleep(forTimeInterval: 1.2)
        return collectIntervalEvidence(db: db, readingId: id, readingTime: readingTime, previous: (id: previous.0, time: previous.1), marker: currentEventMarker(rootA), roots: roots, within: "/private/tmp", simulateActivityGap: gap)
    }
    let gapped = try collectWith(41, previous: (4, 0), gap: true)
    try test((gapped["file_activity"] as? [String: Any])?["status"] as? String == "gap" && folders(gapped)["carried"] as? Int == 0 && folders(gapped)["method"] as? String == "full", "FSEvents gap: every folder re-measured, none assumed unchanged")
    try test(delta(change(gapped, "c_idle"), "logical") == 3_000_000, "change during a gap is still found by re-measuring")
    // Safeguard: an old marker (possible purged history) is not trusted.
    let stale = try collectWith(42, previous: (41, 0), readingTime: Date().timeIntervalSince1970 + maxReplayAge + 60)
    try test((stale["file_activity"] as? [String: Any])?["status"] as? String == "unavailable" && folders(stale)["carried"] as? Int == 0, "event marker older than 6 h: no carry-forward")
    // Safeguard: events written just before the reading are delivered (flush), so the folder is re-measured.
    try write("c_idle/late.bin", 2_000_000)
    let db43 = try Database(dbPath)
    let late = collectIntervalEvidence(db: db43, readingId: 43, readingTime: Date().timeIntervalSince1970 + maxReplayAge + 60, previous: (id: 42, time: 0), marker: currentEventMarker(rootA), roots: roots, within: "/private/tmp")
    try test(delta(change(late, "c_idle"), "logical") == 2_000_000, "change made immediately before the reading is not missed")

    // A reading without evidence in between: nothing can be compared.
    try write("c_create/even-more.bin", 2_000_000)
    let skipped = try collect(60, previous: (59, 0))
    try test((folders(skipped)["changes"] as? [Any])?.isEmpty == true && (folders(skipped)["incomparable_total"] as? Int ?? 0) > 0, "after a missed collection, changes are not invented across a longer interval")

    // Event cap.
    let before = FSEventsGetCurrentEventId()
    for index in 0..<20 { try write("c_idle/burst-\(index).bin", 10) }
    Thread.sleep(forTimeInterval: 1.2)
    let capped = replayFileActivity(roots: [canonicalPath(rootA)!], since: before, until: FSEventsGetCurrentEventId(), maxEvents: 5)
    try test(capped.truncated && capped.allGap, "event cap marks activity incomplete")

    // Retention follows readings.
    let retained = try Database(dbPath)
    try retained.write("INSERT INTO interval_evidence(reading_id,timestamp,evidence) VALUES(?,?,?)", [Int64(424242), 0.0, "{}"])
    try retained.retain(Date().timeIntervalSince1970)
    try test(try retained.rows("SELECT * FROM interval_evidence WHERE reading_id=424242").isEmpty, "attribution rows are removed with their reading")
}

func baselineInitializationSelfTest(_ test: (Bool, String) throws -> Void) throws {
    let sandbox = monitorSelfTestFixture("init").path
    defer { _ = chmod(sandbox + "/messy/locked", 0o700); finishMonitorSelfTestFixture(URL(fileURLWithPath: sandbox)) }
    func make(_ root: String, _ children: [String: Int]) throws {
        for (name, bytes) in children {
            if name.hasSuffix(".bin") { try fm.createDirectory(atPath: sandbox + "/" + root, withIntermediateDirectories: true); try Data(count: bytes).write(to: URL(fileURLWithPath: sandbox + "/" + root + "/" + name)) }
            else { try fm.createDirectory(atPath: sandbox + "/" + root + "/" + name, withIntermediateDirectories: true); try Data(count: bytes).write(to: URL(fileURLWithPath: sandbox + "/" + root + "/" + name + "/data.bin")) }
        }
    }
    func roots(_ name: String) -> [MonitoredRoot] { [MonitoredRoot(path: sandbox + "/" + name, label: name)] }
    func dir(_ name: String) -> URL { let url = URL(fileURLWithPath: sandbox + "/state-" + name); try? privateDirectory(url); return url }
    func db(_ name: String) -> String { dir(name).appendingPathComponent("history.sqlite3").path }
    var fast = InitializerOptions(); fast.pause = 0
    func baseline(_ name: String) -> AttributionBaseline? { (try? Database(db(name))).flatMap { decodeState($0, "attribution_baseline", as: AttributionBaseline.self) } }
    func child(_ name: String, _ root: String, _ child: String) -> ChildState? { baseline(name)?.roots[canonicalPath(sandbox + "/" + root)!]?.children[child] }
    let notificationsBefore = notificationRequests

    // 1–2. Clean first initialization: every accessible folder, no scheduled check needed.
    try make("clean", ["a": 1_000_000, "b": 2_000_000, "c": 3_000_000, "top.bin": 500_000])
    let clean = initializeBaseline(dbPath: db("clean"), directory: dir("clean"), roots: roots("clean"), within: "/private/tmp", options: fast)
    try test(clean.outcome == "terminal" && clean.lifecycle?.state == "ready", "initialization completes without a scheduled check (state \(clean.lifecycle?.state ?? "?"))")
    try test(clean.lifecycle?.discovered == 4 && clean.lifecycle?.baselined == 4 && clean.lifecycle?.pending == 0, "every accessible folder baselined (\(clean.lifecycle?.baselined ?? -1) of \(clean.lifecycle?.discovered ?? -1))")
    let a = child("clean", "clean", "a")
    try test(a?.validEvent != nil && a?.validAt != nil && a?.validThrough == Int64.min && a?.origin == "initializer", "each folder keeps its own measurement marker; none is tied to a reading")
    let times = Set(["a", "b", "c"].compactMap { child("clean", "clean", $0)?.measuredAt })
    try test(times.count == 3, "folders keep individual measurement times (no shared baseline timestamp)")

    // 14. First scheduled check after initialization: no re-walk, no growth, first measurements.
    func scheduled(_ name: String, _ id: Int64, previous: (Int64, Double)?, time: Double = Date().timeIntervalSince1970, gap: Bool = false) throws -> [String: Any] {
        let database = try Database(db(name)); Thread.sleep(forTimeInterval: 1.2)
        return collectIntervalEvidence(db: database, readingId: id, readingTime: time, previous: previous.map { (id: $0.0, time: $0.1) }, marker: currentEventMarker(sandbox), roots: roots(name), within: "/private/tmp", simulateActivityGap: gap, lockPath: dir(name).appendingPathComponent("attribution.lock").path)
    }
    func folders(_ e: [String: Any]) -> [String: Any] { e["folders"] as? [String: Any] ?? [:] }
    let first = try scheduled("clean", 1, previous: nil)
    try test(folders(first)["measured"] as? Int == 0 && folders(first)["carried"] as? Int == 4, "first scheduled check trusts initializer values without re-walking (\(folders(first)["measured"] ?? -1) measured)")
    try test((folders(first)["changes"] as? [Any])?.isEmpty == true && folders(first)["first_measurements"] as? Int == 4, "first measurement is never growth (4 first measurements, 0 changes)")
    // 15. Valid growth after the baseline is established.
    try Data(count: 3_000_000).write(to: URL(fileURLWithPath: sandbox + "/clean/a/more.bin"))
    let second = try scheduled("clean", 2, previous: (1, 0))
    let grew = (folders(second)["changes"] as? [[String: Any]])?.first { $0["child"] as? String == "a" }
    try test(grew != nil && int64(grew?["after_logical"]) - int64(grew?["before_logical"]) == 3_000_000 && folders(second)["carried"] as? Int == 3, "growth after initialization is measured exactly; untouched folders carried")
    // 16. Historical evidence is never rewritten by initialization.
    let history = try Database(db("clean"))
    try history.write("INSERT OR REPLACE INTO interval_evidence(reading_id,timestamp,evidence) VALUES(?,?,?)", [Int64(2), 0.0, json(second)])
    let stored = try history.rows("SELECT evidence FROM interval_evidence WHERE reading_id=2").first?["evidence"]
    _ = initializeBaseline(dbPath: db("clean"), directory: dir("clean"), roots: roots("clean"), within: "/private/tmp", options: fast)
    try test(try Database(db("clean")).rows("SELECT evidence FROM interval_evidence WHERE reading_id=2").first?["evidence"] == stored, "historical interval evidence is unchanged by a later initialization")
    // 9. Stale per-folder markers are not trusted.
    let stale = try scheduled("clean", 3, previous: (2, 0), time: Date().timeIntervalSince1970 + maxReplayAge + 60)
    try test(folders(stale)["carried"] as? Int == 0 && (folders(stale)["measured"] as? Int ?? 0) == 4, "markers older than 6 h are re-measured, never carried")
    // Degraded: an FSEvents gap after initialization.
    let gapped = try scheduled("clean", 4, previous: (3, 0), gap: true)
    try test(folders(gapped)["carried"] as? Int == 0 && decodeLifecycle(try Database(db("clean")))?.state == "degraded", "FSEvents gap after initialization: nothing carried, coverage reported degraded")

    // 3–4. Interrupted midway, then resumed without repeating finished work.
    try make("resume", ["f1": 10_000, "f2": 10_000, "f3": 10_000, "f4": 10_000, "f5": 10_000, "f6": 10_000])
    var interrupt = fast; interrupt.stopAfterMeasurements = 2
    let partial = initializeBaseline(dbPath: db("resume"), directory: dir("resume"), roots: roots("resume"), within: "/private/tmp", options: interrupt)
    try test(partial.outcome == "interrupted" && partial.lifecycle?.state == "initializing" && partial.lifecycle?.baselined == 2 && partial.lifecycle?.pending == 4, "interrupted initialization reports progress (2 of 6) and stays initializing")
    let resumed = initializeBaseline(dbPath: db("resume"), directory: dir("resume"), roots: roots("resume"), within: "/private/tmp", options: fast)
    try test(resumed.outcome == "terminal" && resumed.lifecycle?.baselined == 6 && resumed.lifecycle?.initializer?.measurements == 4, "resume after restart measures only the remaining 4 folders")

    // 5–7. Creation, modification and deletion during initialization.
    try make("busy", ["m1": 100_000, "m2": 100_000, "m3": 100_000, "gone": 100_000])
    let busyRoot = canonicalPath(sandbox + "/busy")!
    var duringInit = fast
    duringInit.onMeasured = { key in
        if key == busyRoot + "\u{1}m1" {
            try? fm.createDirectory(atPath: sandbox + "/busy/created", withIntermediateDirectories: true)
            try? Data(count: 200_000).write(to: URL(fileURLWithPath: sandbox + "/busy/created/new.bin"))
            try? Data(count: 2_000_000).write(to: URL(fileURLWithPath: sandbox + "/busy/m1/grown.bin"))   // m1 already measured
            try? fm.removeItem(atPath: sandbox + "/busy/gone")
            Thread.sleep(forTimeInterval: 1.2)
        }
    }
    let busy = initializeBaseline(dbPath: db("busy"), directory: dir("busy"), roots: roots("busy"), within: "/private/tmp", options: duringInit)
    let m1 = child("busy", "busy", "m1")
    try test(busy.outcome == "terminal" && child("busy", "busy", "created")?.complete == true, "folder created during initialization gets its own baseline")
    try test(m1?.logical == 2_100_000 && (busy.lifecycle?.initializer?.reconciliations ?? 0) >= 1, "folder modified after its measurement is reconciled (stored \(m1?.logical ?? -1) bytes, actual 2,100,000)")
    try test(child("busy", "busy", "gone") == nil && busy.lifecycle?.discovered == 4, "folder deleted during initialization is dropped")
    let afterDelete = try scheduled("busy", 1, previous: nil)
    try test(!((folders(afterDelete)["changes"] as? [[String: Any]]) ?? []).contains { $0["kind"] as? String == "removed" }, "deleted folder produces no negative growth")

    // 8. FSEvents gap during initialization: earlier measurements are re-measured, not trusted.
    try make("gap", ["g1": 10_000, "g2": 10_000])
    var gapOptions = fast; gapOptions.simulateGap = true
    let gapRun = initializeBaseline(dbPath: db("gap"), directory: dir("gap"), roots: roots("gap"), within: "/private/tmp", options: gapOptions)
    try test(gapRun.outcome == "terminal" && gapRun.lifecycle?.initializer?.reconciliations == 6 && gapRun.lifecycle?.initializer?.measurements == 8, "gap during initialization re-measures every affected folder, bounded to 3 rounds")

    // 10–12. Permission-denied and timed-out folders: recorded separately, retried with limits.
    try make("messy", ["ok": 10_000, "locked": 10_000])
    for index in 0..<600 { fm.createFile(atPath: sandbox + "/messy/big-\(index % 3)", contents: nil) }   // placeholder files replaced below
    for index in 0..<3 { try? fm.removeItem(atPath: sandbox + "/messy/big-\(index)") }
    try fm.createDirectory(atPath: sandbox + "/messy/big", withIntermediateDirectories: true)
    for index in 0..<3000 { fm.createFile(atPath: sandbox + "/messy/big/\(index)", contents: Data([1])) }
    _ = chmod(sandbox + "/messy/locked", 0)
    var slow = fast; slow.perChildBudget = 0.000_001
    let messy = initializeBaseline(dbPath: db("messy"), directory: dir("messy"), roots: roots("messy"), within: "/private/tmp", options: slow)
    try test(messy.outcome == "terminal" && messy.lifecycle?.state == "partial" && messy.lifecycle?.unavailable == 1 && messy.lifecycle?.incomplete == 1 && messy.lifecycle?.baselined == 1, "permission-denied and timed-out folders recorded separately (partial: 1 baselined, 1 unavailable, 1 incomplete)")
    try test(child("messy", "messy", "big")?.attempts == 3 && child("messy", "messy", "big")?.complete == false, "timed-out folder stops after 3 attempts and is never marked complete")
    let again = initializeBaseline(dbPath: db("messy"), directory: dir("messy"), roots: roots("messy"), within: "/private/tmp", options: slow)
    try test(again.outcome == "terminal" && again.lifecycle?.initializer?.measurements == 0, "no retry loop: a second run measures nothing")
    let messyCheck = try scheduled("messy", 1, previous: nil)
    try test(folders(messyCheck)["deferred"] as? Int == 2 && folders(messyCheck)["measured"] as? Int == 0, "scheduled checks defer unavailable and exhausted folders instead of retrying every 30 minutes")

    // 13. One worker at a time.
    let held = FileLock(dir("clean").appendingPathComponent("initializer.lock").path, wait: 0)
    try test(held != nil && initializeBaseline(dbPath: db("clean"), directory: dir("clean"), roots: roots("clean"), within: "/private/tmp", options: fast).outcome == "already_running", "a second initializer exits immediately")
    _ = held
    // 17. A busy baseline never blocks the scheduled check indefinitely.
    let busyLock = FileLock(dir("clean").appendingPathComponent("attribution.lock").path, wait: 0)
    let clock = Date()
    let skipped = collectIntervalEvidence(db: try Database(db("clean")), readingId: 9, readingTime: Date().timeIntervalSince1970, previous: nil, marker: currentEventMarker(sandbox), roots: roots("clean"), within: "/private/tmp", lockPath: dir("clean").appendingPathComponent("attribution.lock").path, lockWait: 0.5)
    try test(folders(skipped)["status"] as? String == "busy" && Date().timeIntervalSince(clock) < 3, "scheduled check skips folder evidence after a bounded wait while the baseline is busy")
    _ = busyLock
    // 18. Initialization never notifies.
    try test(notificationRequests == notificationsBefore, "no notifications during initialization")

    // 20. Baselines written before this change are migrated, not discarded.
    let legacy = "{\"version\":1,\"readingId\":26,\"eventId\":500,\"device\":\"U\",\"timestamp\":1000,\"roots\":{\"/r\":{\"listingValidThrough\":26,\"children\":{\"x\":{\"logical\":5,\"allocated\":8,\"files\":1,\"complete\":true,\"status\":\"complete\",\"measuredAt\":900,\"validThrough\":26,\"pending\":false},\"y\":{\"logical\":0,\"allocated\":0,\"files\":0,\"complete\":false,\"status\":\"failed\",\"measuredAt\":900,\"validThrough\":26,\"pending\":true}}}}}"
    let decoded = try JSONDecoder().decode(AttributionBaseline.self, from: Data(legacy.utf8))
    let upgraded = migrated(decoded)
    try test(upgraded.roots["/r"]?.children["x"]?.validEvent == 500 && upgraded.roots["/r"]?.children["y"]?.validEvent == nil, "existing baselines decode and migrate (valid folders keep their reading marker)")
    let legacyLifecycle = baselineLifecycle(upgraded, roots: [MonitoredRoot(path: "/r", label: "r")], at: 1500, degraded: nil, previous: nil)
    try test(legacyLifecycle.baselined == 1 && legacyLifecycle.unavailable == 1 && legacyLifecycle.state == "partial", "coverage computed for migrated baselines")

    // 6. Both agents writing one database: separate processes, real SQLite locking.
    let sharedPath = sandbox + "/shared.sqlite3"
    let shared = try Database(sharedPath)
    let writer = Process(); writer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0].hasPrefix("/") ? CommandLine.arguments[0] : Bundle.main.executablePath!)
    writer.arguments = ["stress-state-writes", sharedPath, "400"]
    let output = Pipe(); writer.standardOutput = output
    try writer.run()
    var scheduledFailures = 0
    for index in 0..<200 {
        do {
            try shared.exec("BEGIN IMMEDIATE")
            try shared.write("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES(?,?,?,?,?)", [Double(index), "C", Int64(1), Int64(1), "[]"])
            try shared.state("conditions", "free_below_25gb")
            try shared.exec("COMMIT")
        } catch { scheduledFailures += 1; try? shared.exec("ROLLBACK") }
    }
    writer.waitUntilExit()
    let writerReport = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let integrity = try shared.rows("PRAGMA integrity_check").first?.values.first ?? ""
    try test(scheduledFailures == 0 && writerReport.contains("failures=0") && integrity == "ok" && (try shared.rows("SELECT count(*) AS n FROM readings").first?["n"]) == "200", "concurrent agent writes: 0 failures in 200 transactions and 400 state writes; integrity ok")

    // 7. Install backup: verified copy, bounded retention.
    let backupDir = URL(fileURLWithPath: sandbox + "/backup-test"); try privateDirectory(backupDir)
    let original = try Database(backupDir.appendingPathComponent("history.sqlite3").path)
    try original.write("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES(?,?,?,?,?)", [1.0, "C", Int64(5), Int64(5), "[]"])
    var made = [String]()
    for _ in 0..<4 { if let url = try backupDatabase(backupDir) { made.append(url.lastPathComponent) }; Thread.sleep(forTimeInterval: 1.1) }
    let kept = ((try? fm.contentsOfDirectory(atPath: backupDir.path)) ?? []).filter { $0.hasPrefix("history.install-backup-") }
    let restored = try Database(backupDir.appendingPathComponent(made.last!).path)
    try test(kept.count == 3 && (try restored.rows("SELECT count(*) AS n FROM readings").first?["n"]) == "1", "install backup is verified and the 3 newest are kept")

    // Launch agent: one-shot, background, self-terminating; the scheduled agent is unchanged.
    let agent = baselineAgentPlist("/x/StorageMonitor", "/x/data")
    try test(agent["StartCalendarInterval"] == nil && (agent["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false && agent["LowPriorityIO"] as? Bool == true && (agent["ProgramArguments"] as? [String])?[1] == "initialize-baseline", "initializer agent runs at load, exits when done, background I/O priority")
    try test((agentPlist("/x/StorageMonitor", "/x/data")["StartCalendarInterval"] as? [[String: Int]]) == [["Minute": 0], ["Minute": 30]], "scheduled monitoring agent unchanged (:00/:30)")
}
