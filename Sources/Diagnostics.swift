import Foundation
import Darwin

// Diagnostic snapshot schema 2.
//
// Evidence is collected in-process: swap from sysctl, VM counters from Mach,
// APFS volumes reused from the reading's complete property list, and directory
// sizes from bounded walks of a short list of known locations. Nothing here
// launches a subprocess, scans broad protected system folders, or asks for
// extra privileges. macOS permission refusals are expected and recorded as a
// count with a few examples, never as hundreds of repeated lines.

let diagnosticSchemaVersion = 2

enum CollectionStatus: String {
    case complete, partial, timedOut = "timed_out", failed, absent, skipped
}

// Counts unique refused paths and keeps only a few examples.
struct PermissionTally {
    private(set) var count = 0
    private(set) var examples = [String]()
    private var seen = Set<String>()
    mutating func add(_ path: String) {
        if seen.count < 10_000 { guard seen.insert(path).inserted else { return } }
        count += 1
        if examples.count < 3 { examples.append(path) }
    }
    mutating func merge(_ other: PermissionTally) { for path in other.examples { add(path) }; count += max(0, other.count - other.examples.count) }
    var json: [String: Any] { ["count": count, "examples": examples] }
}

struct DirectoryTarget {
    let source: String   // temporary_files | application_data | caches | developer
    let label: String
    let path: String
}

struct DirectoryMeasurement {
    let target: DirectoryTarget
    var status: CollectionStatus = .complete
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var files = 0
    var permission = PermissionTally()
    var otherErrors = 0
    var limit: String?
    var observedAt = Date().timeIntervalSince1970
    var duration: Double = 0
    var json: [String: Any] {
        var value: [String: Any] = ["source": target.source, "label": target.label, "path": target.path, "status": status.rawValue, "observed_at": observedAt, "duration_ms": Int(duration * 1000)]
        if status != .absent && status != .skipped {
            value["logical_bytes"] = logical; value["allocated_bytes"] = allocated; value["files"] = files
            value["permission_denied"] = permission.json; value["other_errors"] = otherErrors
        }
        if let limit { value["limit"] = limit }
        return value
    }
}

func isPermissionError(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
    if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
    return false
}

// Walks one directory tree without following symlinks or crossing volumes.
// Stops at the time budget or entry cap; either makes the result incomplete.
func measureDirectory(_ target: DirectoryTarget, budget: TimeInterval, maxEntries: Int = 200_000) -> DirectoryMeasurement {
    let started = Date()
    var result = DirectoryMeasurement(target: target, observedAt: started.timeIntervalSince1970)
    func finish() -> DirectoryMeasurement { result.duration = Date().timeIntervalSince(started); return result }
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else { result.status = .absent; return finish() }
    guard budget > 0 else { result.status = .skipped; result.limit = "Total diagnostic time budget exhausted before this location"; return finish() }
    guard access(target.path, R_OK | X_OK) == 0 else {
        result.permission.add(target.path); result.status = .failed; result.limit = "Location could not be opened"; return finish()
    }
    let root = URL(fileURLWithPath: target.path, isDirectory: true)
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .volumeIdentifierKey]
    let keySet = Set(keys)
    let rootVolume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    var permission = PermissionTally(), other = 0
    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { url, error in
        if isPermissionError(error) { permission.add(url.path) } else { other += 1 }
        return true
    }) else { result.status = .failed; result.limit = "Directory enumeration unavailable"; return finish() }
    let deadline = started.addingTimeInterval(budget)
    var entries = 0
    while let url = walker.nextObject() as? URL {
        entries += 1
        if entries % 64 == 0 && Date() >= deadline { result.status = .timedOut; result.limit = String(format: "Stopped at the %.0f-second time budget", budget); break }
        if entries > maxEntries { result.status = .partial; result.limit = "Stopped at the \(maxEntries)-entry limit"; break }
        guard let values = try? url.resourceValues(forKeys: keySet) else { other += 1; continue }
        if values.isDirectory == true {
            if let rootVolume, let volume = values.volumeIdentifier as? NSObject, !volume.isEqual(rootVolume) { walker.skipDescendants() }
            continue
        }
        if values.isRegularFile == true {
            result.logical += Int64(values.fileSize ?? 0)
            result.allocated += Int64(values.totalFileAllocatedSize ?? 0)
            result.files += 1
        }
    }
    result.permission = permission; result.otherErrors = other
    if result.status == .complete && (permission.count > 0 || other > 0) { result.status = .partial }
    return finish()
}

// Swap allocation (total swapfile size) and usage, exact bytes, no subprocess.
func swapObservation() -> [String: Any] {
    var usage = xsw_usage(), size = MemoryLayout<xsw_usage>.size
    let observed = Date().timeIntervalSince1970
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
        return ["status": CollectionStatus.failed.rawValue, "error_category": "sysctl", "detail": String(cString: strerror(errno)), "observed_at": observed]
    }
    return ["status": CollectionStatus.complete.rawValue, "allocated_bytes": Int64(usage.xsu_total), "used_bytes": Int64(usage.xsu_used), "free_bytes": Int64(usage.xsu_avail), "encrypted": usage.xsu_encrypted != 0, "observed_at": observed]
}

// The handful of VM counters that relate to storage; vm_stat prints dozens more.
func vmObservation() -> [String: Any] {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let observed = Date().timeIntervalSince1970
    let status = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) } }
    guard status == KERN_SUCCESS else { return ["status": CollectionStatus.failed.rawValue, "error_category": "mach", "detail": "host_statistics64 returned \(status)", "observed_at": observed] }
    return ["status": CollectionStatus.complete.rawValue, "page_size_bytes": Int64(vm_kernel_page_size), "free_pages": Int64(stats.free_count), "active_pages": Int64(stats.active_count), "inactive_pages": Int64(stats.inactive_count), "wired_pages": Int64(stats.wire_count), "compressor_pages": Int64(stats.compressor_page_count), "swapins": Int64(stats.swapins), "swapouts": Int64(stats.swapouts), "observed_at": observed]
}

// This user's own /private/var/folders/xx/yyyy directory (parent of T, C, X).
func darwinUserFolder() -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer)).deletingLastPathComponent().path
}

// Signing clones sit directly inside X, T or C. One directory listing each;
// no recursive search and nothing outside this user's own folder.
func signingCloneCandidates(in folder: String) -> [String] {
    var found = [String]()
    for child in ["X", "T", "C"] {
        let parent = (folder as NSString).appendingPathComponent(child)
        for name in ((try? fm.contentsOfDirectory(atPath: parent)) ?? []).sorted() where name.lowercased().contains("code_sign_clone") {
            found.append((parent as NSString).appendingPathComponent(name))
        }
    }
    return Array(found.prefix(4))
}

func defaultDirectoryTargets() -> [DirectoryTarget] {
    var targets = [DirectoryTarget]()
    if let folder = darwinUserFolder() {
        targets += signingCloneCandidates(in: folder).map { DirectoryTarget(source: "temporary_files", label: "Chrome signing clone", path: $0) }
        targets.append(DirectoryTarget(source: "temporary_files", label: "User temporary folder", path: (folder as NSString).appendingPathComponent("T")))
    }
    // Known, bounded locations. App containers and browser profiles are left
    // alone: macOS protects them and reading them could prompt the user.
    let known: [(String, String, String)] = [
        ("application_data", "Claude Desktop VM bundles", "Library/Application Support/Claude/vm_bundles"),
        ("application_data", "Claude Code VM", "Library/Application Support/Claude/claude-code-vm"),
        ("caches", "Google cache", "Library/Caches/Google"),
        ("caches", "Homebrew cache", "Library/Caches/Homebrew"),
        ("developer", "Xcode DerivedData", "Library/Developer/Xcode/DerivedData"),
        ("developer", "npm cache", ".npm/_cacache"),
    ]
    targets += known.map { DirectoryTarget(source: $0.0, label: $0.1, path: home.appendingPathComponent($0.2).path) }
    return targets
}

func diagnosticSnapshot(_ current: Reading, targets: [DirectoryTarget]? = nil, totalBudget: TimeInterval = 40, perTarget: TimeInterval = 6) -> String {
    let started = Date(), deadline = started.addingTimeInterval(totalBudget)
    var collectors = [[String: Any]]()

    // APFS: the reading already parsed diskutil's complete, untruncated plist.
    let volumes = (try? JSONSerialization.jsonObject(with: Data(current.volumes.utf8))) as? [[String: Any]]
    collectors.append(["source": "apfs", "status": (volumes == nil ? CollectionStatus.failed : .complete).rawValue,
                       "detail": volumes.map { "Reused the reading's complete APFS property list (\($0.count) volumes); no second diskutil call" } ?? "Stored volume list could not be parsed",
                       "observed_at": current.timestamp])

    let swap = swapObservation()
    collectors.append(["source": "swap", "status": swap["status"] ?? "failed", "detail": swap["detail"] ?? "sysctl vm.swapusage", "observed_at": swap["observed_at"] ?? started.timeIntervalSince1970])
    let vm = vmObservation()
    collectors.append(["source": "vm", "status": vm["status"] ?? "failed", "detail": vm["detail"] ?? "host_statistics64", "observed_at": vm["observed_at"] ?? started.timeIntervalSince1970])

    var directories = [[String: Any]](), permission = PermissionTally()
    var counts = [CollectionStatus: Int]()
    for target in targets ?? defaultDirectoryTargets() {
        let measurement = measureDirectory(target, budget: min(perTarget, deadline.timeIntervalSinceNow))
        counts[measurement.status, default: 0] += 1
        if measurement.status == .absent { continue }
        permission.merge(measurement.permission)
        directories.append(measurement.json)
    }
    let incomplete = (counts[.partial] ?? 0) + (counts[.timedOut] ?? 0) + (counts[.failed] ?? 0) + (counts[.skipped] ?? 0)
    var detail = ["\(directories.count) locations measured"]
    if incomplete > 0 { detail.append("\(incomplete) incomplete") }
    if let absent = counts[.absent], absent > 0 { detail.append("\(absent) optional locations not present") }
    collectors.append(["source": "directories", "status": (incomplete == 0 ? CollectionStatus.complete : .partial).rawValue, "detail": detail.joined(separator: "; "), "permission_denied": permission.json, "observed_at": started.timeIntervalSince1970, "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])

    let result: [String: Any] = [
        "schema_version": diagnosticSchemaVersion,
        "timestamp": iso(current.timestamp),
        "physical_container": ["uuid": current.container, "free_bytes": current.free, "used_bytes": current.used],
        "volumes": volumes ?? [],
        "swap": swap, "vm": vm, "directories": directories, "collectors": collectors,
        "commands": [[String: Any]](),
        "interpretation": "CapacityFree and ceiling minus free are physical APFS container allocation. Volume CapacityInUse is APFS-reported allocation. Directory logical and allocated sizes are not additive and do not identify exclusive physical allocation: clones, compression, snapshots and shared extents prevent that. Incomplete directory totals are lower bounds and are never compared.",
    ]
    return json(result)
}
