import Foundation
import CryptoKit
import Darwin

struct SnapshotFileEntry: Codable, Equatable, Sendable {
    var type: String
    var logicalBytes: Int64
    var modified: Date
    var permissions: UInt16
    var owner: UInt32
    var group: UInt32
    var linkDestination: String?
    var sha256: String?
}
struct SnapshotFileChange: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case added, removed, modified, metadata, unverifiedPresence }
    var path: String
    var kind: Kind
    var before: SnapshotFileEntry?
    var after: SnapshotFileEntry?
    var id: String { path }
}
struct SnapshotFileComparison: Codable, Sendable {
    var performedAt = Date()
    var sourceVolumeUUID: String? = nil
    var leftSnapshotUUID: String? = nil
    var rightSnapshotUUID: String? = nil
    var changes: [SnapshotFileChange]
    var leftEntries: Int
    var rightEntries: Int
    var metadataCoverageComplete: Bool
    var contentUnverifiedFiles: Int
    var warnings: [String]
    var accounting = "File logical sizes and metadata are not APFS exclusive, shared or reclaimable bytes. Equal metadata without two hashes does not establish equal file contents."
    static func compare(left: URL, right: URL, maximumEntries: Int = 100_000, seconds: TimeInterval = 30, hashLimit: Int64 = 16 * 1024 * 1024, totalHashLimit: Int64 = 256 * 1024 * 1024, requireReadOnlySnapshots: Bool = false, cancelled: () -> Bool = { false }) throws -> Self {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var warnings = [String](), complete = true, unverified = 0
        func warn(_ text: String) { if warnings.count < 40 { warnings.append(text) } }
        func scan(_ inputRoot: URL) throws -> [String: SnapshotFileEntry] {
            let root = inputRoot
            var remainingHash = totalHashLimit / 2
            var rootStat = stat()
            try lifecycleRequire(lstat(root.path, &rootStat) == 0 && (rootStat.st_mode & S_IFMT) == S_IFDIR, "Comparison root must be an accessible directory, not a symlink.")
            let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            try lifecycleRequire(rootFD >= 0, "Comparison root could not be held open safely: \(root.path) (\(errno)).")
            defer { close(rootFD) }
            var fsBefore = statfs()
            try lifecycleRequire(fstatfs(rootFD, &fsBefore) == 0 && (!requireReadOnlySnapshots || fsBefore.f_flags & UInt32(MNT_RDONLY) != 0), "Comparison snapshot mount is missing or not read-only.")
            var entries = [String: SnapshotFileEntry]()
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in
                complete = false
                if warnings.count < 20 { warn("A directory could not be read with your account's permissions.") }
                return true
            }) else { throw SnapshotLifecycleError.refused("Cannot enumerate comparison root.") }
            while let url = enumerator.nextObject() as? URL {
                if cancelled() { throw SnapshotLifecycleError.refused("Comparison cancelled. Partial results were discarded.") }
                if entries.count >= maximumEntries || ProcessInfo.processInfo.systemUptime >= deadline {
                    complete = false; warn("Comparison stopped at the entry/time limit; missing paths must not be interpreted as proven additions or removals."); break
                }
                let path = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
                var info = stat()
                guard lstat(url.path, &info) == 0 else { complete = false; warn("Metadata unavailable for \(path.prefix(160))."); continue }
                if info.st_dev != rootStat.st_dev { enumerator.skipDescendants(); complete = false; warn("A different mounted filesystem was excluded."); continue }
                let mode = info.st_mode & S_IFMT
                let type = mode == S_IFDIR ? "directory" : mode == S_IFREG ? "file" : mode == S_IFLNK ? "symlink" : "special"
                if type != "directory" { enumerator.skipDescendants() }
                let link = type == "symlink" ? (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) : nil
                var hash: String?
                if type == "file" {
                    if info.st_size <= hashLimit && info.st_size <= remainingHash {
                        // O_NOFOLLOW also closes the symlink substitution window for non-snapshot test roots.
                        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                        if fd >= 0 {
                            defer { close(fd) }
                            var opened = stat()
                            if fstat(fd, &opened) == 0 && opened.st_ino == info.st_ino && opened.st_dev == info.st_dev && (opened.st_mode & S_IFMT) == S_IFREG {
                                var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 65536), total: Int64 = 0, valid = true
                                while true {
                                    if cancelled() { throw SnapshotLifecycleError.refused("Comparison cancelled.") }
                                    if ProcessInfo.processInfo.systemUptime >= deadline { valid = false; complete = false; break }
                                    let count = read(fd, &buffer, buffer.count)
                                    if count == 0 { break }
                                    if count < 0 { valid = false; break }
                                    total += Int64(count)
                                    if total > hashLimit || total > remainingHash { valid = false; break }
                                    digest.update(data: Data(buffer.prefix(count)))
                                }
                                remainingHash = max(0, remainingHash - total)
                                var after = stat()
                                if valid && fstat(fd, &after) == 0 && after.st_size == opened.st_size && after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec {
                                    hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
                                }
                            }
                        }
                    }
                    if hash == nil { unverified += 1 }
                }
                entries[path] = SnapshotFileEntry(type: type, logicalBytes: info.st_size, modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec)/1e9), permissions: UInt16(info.st_mode & 0o7777), owner: info.st_uid, group: info.st_gid, linkDestination: link, sha256: hash)
            }
            var rootAfter = stat(), fsAfter = statfs()
            try lifecycleRequire(lstat(root.path, &rootAfter) == 0 && rootAfter.st_dev == rootStat.st_dev && rootAfter.st_ino == rootStat.st_ino && fstatfs(rootFD, &fsAfter) == 0 && fsBefore.f_fsid.val.0 == fsAfter.f_fsid.val.0 && fsBefore.f_fsid.val.1 == fsAfter.f_fsid.val.1 && (!requireReadOnlySnapshots || fsAfter.f_flags & UInt32(MNT_RDONLY) != 0), "Comparison mount changed while scanning. Results discarded.")
            return entries
        }
        let a = try scan(left), b = try scan(right)
        var changes = [SnapshotFileChange]()
        for path in Set(a.keys).union(b.keys).sorted() {
            let before = a[path], after = b[path]
            if before == nil { changes.append(.init(path: path, kind: complete ? .added : .unverifiedPresence, before: nil, after: after)) }
            else if after == nil { changes.append(.init(path: path, kind: complete ? .removed : .unverifiedPresence, before: before, after: nil)) }
            else if let before, let after {
                var beforeMetadata = before, afterMetadata = after
                beforeMetadata.sha256 = nil; afterMetadata.sha256 = nil
                let hashesDiffer = before.sha256 != nil && after.sha256 != nil && before.sha256 != after.sha256
                if beforeMetadata == afterMetadata && !hashesDiffer { continue }
                let content = before.type != after.type || before.logicalBytes != after.logicalBytes || before.linkDestination != after.linkDestination || (before.sha256 != nil && after.sha256 != nil && before.sha256 != after.sha256)
                changes.append(.init(path: path, kind: content ? .modified : .metadata, before: before, after: after))
            }
        }
        return Self(changes: changes, leftEntries: a.count, rightEntries: b.count, metadataCoverageComplete: complete, contentUnverifiedFiles: unverified, warnings: Array(warnings.prefix(40)))
    }
}
