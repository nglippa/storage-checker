import Foundation
import Darwin

// Migration Readiness: sparse-storage detection. Read-only.
//
// A file's logical size (st_size) is the length it reports; its allocated size (st_blocks × 512) is what the
// filesystem has actually reserved for it. A sparse file (a raw VM or container disk image, for example) can report
// hundreds of gigabytes while only tens are allocated. Some copy and migration methods write every logical byte, so
// the destination may need more space than the source's allocation suggests. This file holds the pure parts of the
// diagnostic: measurements, thresholds, classification, and the live metadata probe. Nothing here deletes,
// truncates, compacts, mounts, launches or writes anything, and nothing leaves the Mac.
//
// What the numbers do NOT mean: the apparent gap is not consumed space and not recoverable space. APFS clones,
// shared extents, snapshots, transparent compression and cloud placeholders all make allocated size an imperfect
// account of physical usage (see artifacts/storage-monitor/migration-readiness/FILESYSTEM-ACCOUNTING.md).

/// One file's (or one sparse bundle's) logical and allocated sizes.
public struct SparseAllocation: Sendable, Equatable, Hashable {
    public let logical: Int64
    public let allocated: Int64

    public init(logical: Int64, allocated: Int64) {
        self.logical = max(0, logical)
        self.allocated = max(0, allocated)
    }

    /// max(0, logical − allocated). Never negative: a preallocated file (allocated > logical) has no gap.
    public var gap: Int64 { logical > allocated ? logical - allocated : 0 }

    /// logical ÷ allocated; nil when nothing is allocated (the ratio is unbounded, not zero or infinite).
    public var ratio: Double? { allocated > 0 ? Double(logical) / Double(allocated) : nil }

    /// Whether logical ≥ `minimum` × allocated. A file with nothing allocated meets any ratio when it has a length.
    public func meetsRatio(_ minimum: Double) -> Bool {
        allocated == 0 ? logical > 0 : Double(logical) >= minimum * Double(allocated)
    }
}

/// Configurable, conservative heuristics. They are not established migration-failure thresholds: they select files
/// whose allocation differs enough from their length that a transfer could need noticeably more space.
public struct SparseStorageThresholds: Sendable, Equatable, Hashable {
    public static let gibibyte: Int64 = 1 << 30

    /// REVIEW needs all three.
    public var reviewMinimumLogical: Int64
    public var reviewMinimumGap: Int64
    public var reviewMinimumRatio: Double
    /// Below these a file is not reported at all (INFORMATIONAL needs both). The ratio floor defaults to 1 : 1 (none):
    /// a gap of 1 GiB is meaningful on its own, whatever the file's size, once compression and placeholders are excluded.
    public var reportMinimumGap: Int64
    public var reportMinimumRatio: Double

    public init(reviewMinimumLogical: Int64 = 10 * gibibyte, reviewMinimumGap: Int64 = 5 * gibibyte, reviewMinimumRatio: Double = 4,
                reportMinimumGap: Int64 = gibibyte, reportMinimumRatio: Double = 1) {
        self.reviewMinimumLogical = max(0, reviewMinimumLogical)
        self.reviewMinimumGap = max(0, reviewMinimumGap)
        self.reviewMinimumRatio = max(1, reviewMinimumRatio)
        self.reportMinimumGap = max(1, min(reportMinimumGap, max(1, reviewMinimumGap)))
        self.reportMinimumRatio = max(1, min(reportMinimumRatio, max(1, reviewMinimumRatio)))
    }

    public static let standard = SparseStorageThresholds()

    /// REVIEW, INFORMATIONAL, or nil (not reported). Unknown is decided by the caller from the verification.
    public func severity(_ allocation: SparseAllocation) -> SparseStorageSeverity? {
        guard allocation.gap >= reportMinimumGap, allocation.meetsRatio(reportMinimumRatio) else { return nil }
        if allocation.logical >= reviewMinimumLogical && allocation.gap >= reviewMinimumGap && allocation.meetsRatio(reviewMinimumRatio) { return .review }
        return .informational
    }
}

public enum SparseStorageSeverity: String, Sendable, Codable, CaseIterable {
    /// Large logical/allocated discrepancy that may need special handling during transfer.
    case review
    /// Insufficient metadata or inaccessible storage.
    case unknown
    /// Sparse allocation detected; no specific compatibility concern established.
    case informational

    public var title: String {
        switch self {
        case .review: return "Review"
        case .unknown: return "Unknown"
        case .informational: return "Informational"
        }
    }
    /// Display order: review first, then items that could not be checked, then informational.
    public var rank: Int { switch self { case .review: return 0; case .unknown: return 1; case .informational: return 2 } }
}

public enum SparseStorageCategory: String, Sendable, Codable, CaseIterable {
    case sparseFile, diskImage, virtualization, containerRuntime, unknown

    public var title: String {
        switch self {
        case .sparseFile: return "Sparse file"
        case .diskImage: return "Disk image"
        case .virtualization: return "Virtual machine storage"
        case .containerRuntime: return "Container storage"
        case .unknown: return "Unknown"
        }
    }
}

/// What a detected item probably is, and why the app thinks so. Formats come from names and owners from locations:
/// both are inferences, never parsed or confirmed with the application.
public struct SparseStorageKind: Sendable, Equatable, Hashable {
    public let category: SparseStorageCategory
    /// The application whose storage location holds the item, inferred from the path.
    public let application: String?
    /// The disk format suggested by the name (".raw" → raw disk image). Not parsed.
    public let format: String?
    /// Plain statements of the evidence used.
    public let evidence: [String]
    public let isSparseBundle: Bool

    public init(category: SparseStorageCategory, application: String? = nil, format: String? = nil, evidence: [String] = [], isSparseBundle: Bool = false) {
        self.category = category; self.application = application; self.format = format; self.evidence = evidence; self.isSparseBundle = isSparseBundle
    }

    /// "Docker Desktop disk image", "Parallels Desktop virtual disk", "Raw disk image", "Sparse file".
    public var title: String {
        switch (application, category) {
        case (let app?, .containerRuntime), (let app?, .diskImage): return app + " disk image"
        case (let app?, .virtualization): return app + " virtual disk"
        case (let app?, _): return app + " storage file"
        case (nil, _): return format ?? category.title
        }
    }

    public func with(category: SparseStorageCategory) -> SparseStorageKind {
        SparseStorageKind(category: category, application: application, format: format, evidence: evidence, isSparseBundle: isSparseBundle)
    }
}

// MARK: Classification

public enum SparseStorageClassifier {
    /// File extensions with a known disk-image or virtual-disk convention. An extension never proves a file is sparse.
    public static let formats: [String: (name: String, category: SparseStorageCategory)] = [
        "raw": ("Raw disk image", .diskImage),
        "img": ("Disk image (.img)", .diskImage),
        "dmg": ("Disk image (.dmg)", .diskImage),
        "sparseimage": ("Sparse disk image", .diskImage),
        "sparsebundle": ("Sparse bundle", .diskImage),
        "qcow2": ("QCOW2 virtual disk", .virtualization),
        "vmdk": ("VMDK virtual disk", .virtualization),
        "vdi": ("VDI virtual disk", .virtualization),
        "vhd": ("VHD virtual disk", .virtualization),
        "vhdx": ("VHDX virtual disk", .virtualization),
        "hdd": ("Parallels virtual disk", .virtualization),
        "hds": ("Parallels virtual disk data", .virtualization),
    ]

    struct Owner {
        let application: String
        let category: SparseStorageCategory
        /// Matches lowercased path components.
        let matches: ([String]) -> Bool
        let place: String
    }

    /// Storage locations documented by each application, matched by folder name anywhere in the path, so no user's
    /// home directory is assumed. A match says only where the item is.
    static let owners: [Owner] = [
        Owner(application: "Docker Desktop", category: .containerRuntime, matches: { $0.contains("com.docker.docker") || $0.contains("group.com.docker") }, place: "Docker Desktop's data folder (com.docker.docker)"),
        Owner(application: "OrbStack", category: .containerRuntime, matches: { $0.contains(".orbstack") || $0.contains { $0.hasSuffix(".dev.orbstack") } }, place: "OrbStack's data folder"),
        Owner(application: "Rancher Desktop", category: .containerRuntime, matches: { $0.contains("rancher-desktop") }, place: "Rancher Desktop's data folder"),
        Owner(application: "Podman", category: .containerRuntime, matches: { parts in zip(parts, parts.dropFirst()).contains { $0 == "podman" && $1 == "machine" } }, place: "a Podman machine folder"),
        Owner(application: "Colima", category: .containerRuntime, matches: { $0.contains(".colima") }, place: "Colima's data folder (.colima)"),
        Owner(application: "Lima", category: .containerRuntime, matches: { $0.contains(".lima") }, place: "Lima's data folder (.lima)"),
        Owner(application: "Parallels Desktop", category: .virtualization, matches: { $0.contains { $0.hasSuffix(".pvm") } }, place: "a Parallels virtual machine bundle (.pvm)"),
        Owner(application: "VMware Fusion", category: .virtualization, matches: { $0.contains { $0.hasSuffix(".vmwarevm") } }, place: "a VMware Fusion virtual machine bundle (.vmwarevm)"),
        Owner(application: "UTM", category: .virtualization, matches: { $0.contains { $0.hasSuffix(".utm") } || $0.contains("com.utmapp.utm") }, place: "a UTM virtual machine"),
        Owner(application: "VirtualBox", category: .virtualization, matches: { $0.contains("virtualbox vms") }, place: "VirtualBox's machines folder"),
        Owner(application: "Tart", category: .virtualization, matches: { $0.contains(".tart") }, place: "Tart's data folder (.tart)"),
    ]

    /// Classifies by path only (no file is opened). `isDirectory` is true only for a sparse bundle candidate.
    public static func classify(path: String, isDirectory: Bool) -> SparseStorageKind {
        let parts = ArtifactPaths.components(path).map { $0.lowercased() }
        let name = parts.last ?? ""
        let ext = (name as NSString).pathExtension
        let format = formats[ext]
        var evidence = [String]()
        if let format { evidence.append("Its name ends in .\(ext), the usual extension for a \(format.name.lowercased()). The format was not read or verified.") }
        let bundle = isDirectory && ext == "sparsebundle"
        if bundle { evidence.append("A sparse bundle stores its contents as many band files inside one folder.") }
        if let owner = owners.first(where: { $0.matches(Array(parts.dropLast())) || (isDirectory && $0.matches(parts)) }) {
            evidence.append("It is inside \(owner.place). The owning application is inferred from this location.")
            return SparseStorageKind(category: owner.category, application: owner.application, format: format?.name, evidence: evidence, isSparseBundle: bundle)
        }
        if let format { return SparseStorageKind(category: format.category, format: format.name, evidence: evidence, isSparseBundle: bundle) }
        return SparseStorageKind(category: .sparseFile, evidence: evidence, isSparseBundle: bundle)
    }
}

// MARK: Locations

public enum SparseStorageLocations {
    /// Locations macOS guards with privacy consent (or that may be cloud placeholders). The worker does not open them
    /// without Full Disk Access; the viewer never checks files there on its own, so no permission prompt appears.
    static let protectedRelative = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library"]
    /// Inside ~/Library only these are opened without consent (the worker's own rule).
    static let libraryAllowed: Set<String> = ["Caches", "Developer", "Logs"]
    /// iCloud Drive and File Provider storage: a large file here may be a placeholder whose data is not local.
    static let cloudRelative = [["Library", "Mobile Documents"], ["Library", "CloudStorage"]]

    /// True when a live check of `path` could raise a macOS privacy prompt.
    public static func isProtected(_ path: String, home: String?) -> Bool {
        guard let rest = relativeToHome(path, home: home) else { return false }
        guard let first = rest.first, protectedRelative.contains(first) else { return false }
        if first == "Library" { return !(rest.count >= 2 && libraryAllowed.contains(rest[1])) }
        return true
    }

    public static func isCloud(_ path: String, home: String?) -> Bool {
        guard let rest = relativeToHome(path, home: home) else { return false }
        return cloudRelative.contains { rest.count > $0.count && Array(rest.prefix($0.count)) == $0 }
    }

    static func relativeToHome(_ path: String, home: String?) -> [String]? {
        let parts = ArtifactPaths.components(path)
        let homeParts = (home.map(ArtifactPaths.components)) ?? ArtifactPaths.home(of: path).map(ArtifactPaths.components) ?? []
        guard !homeParts.isEmpty, parts.count > homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts else { return nil }
        return Array(parts.dropFirst(homeParts.count))
    }

    /// Replaces the home folder with "~" for display and shared diagnostics.
    public static func redacted(_ path: String, home: String?) -> String {
        guard let rest = relativeToHome(path, home: home) else { return ArtifactPaths.logical(path) }
        return (["~"] + rest).joined(separator: "/")
    }
}

// MARK: Live metadata

/// One lstat of a candidate (never follows symlinks). Flags expose transparent compression and cloud placeholders,
/// both of which make allocated size smaller than logical size without the file being sparse.
public struct SparseStorageLiveMetadata: Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64
    public let birthNanoseconds: Int64
    public let kind: InventoryNodeKind
    public let logical: Int64
    public let allocated: Int64
    public let compressed: Bool
    public let dataless: Bool

    public init(device: Int64, inode: UInt64, birthNanoseconds: Int64, kind: InventoryNodeKind, logical: Int64, allocated: Int64, compressed: Bool = false, dataless: Bool = false) {
        self.device = device; self.inode = inode; self.birthNanoseconds = birthNanoseconds; self.kind = kind
        self.logical = logical; self.allocated = allocated; self.compressed = compressed; self.dataless = dataless
    }

    public init(_ value: stat) {
        let metadata = InventoryFilesystemMetadata(value)
        self.init(device: metadata.device, inode: metadata.inode, birthNanoseconds: metadata.birthNanoseconds, kind: metadata.kind,
                  logical: metadata.logicalBytes, allocated: metadata.allocatedBytes,
                  compressed: value.st_flags & UInt32(UF_COMPRESSED) != 0, dataless: metadata.isCloudPlaceholder)
    }

    public var allocation: SparseAllocation { SparseAllocation(logical: logical, allocated: allocated) }
}

/// A sparse bundle's own description of itself (its Info.plist), read without mounting it.
public struct SparseBundleInfo: Sendable, Equatable {
    /// The bundle's maximum capacity ("size"), which is not the space its bands use.
    public let capacity: Int64?
    public let bandSize: Int64?

    public init(capacity: Int64?, bandSize: Int64?) { self.capacity = capacity; self.bandSize = bandSize }

    /// Parses the plist; unknown or malformed values are nil, never guessed.
    public static func parse(_ data: Data) -> SparseBundleInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        func integer(_ key: String) -> Int64? { (plist[key] as? NSNumber).map(\.int64Value).flatMap { $0 > 0 ? $0 : nil } }
        return SparseBundleInfo(capacity: integer("size"), bandSize: integer("band-size"))
    }
}

/// The filesystem access the detector is allowed: lstat and one bounded read of a sparse bundle's Info.plist.
/// Injectable so tests can simulate permission failures and changes between reads.
public struct SparseStorageProbe: Sendable {
    public let metadata: @Sendable (String) -> Result<SparseStorageLiveMetadata, SparseStorageProbeError>
    public let bundleInfo: @Sendable (String) -> SparseBundleInfo?

    public init(metadata: @escaping @Sendable (String) -> Result<SparseStorageLiveMetadata, SparseStorageProbeError>,
                bundleInfo: @escaping @Sendable (String) -> SparseBundleInfo?) {
        self.metadata = metadata; self.bundleInfo = bundleInfo
    }

    public static let live = SparseStorageProbe(metadata: { path in
        var value = stat()
        guard lstat(path, &value) == 0 else { return .failure(SparseStorageProbeError(code: errno)) }
        return .success(SparseStorageLiveMetadata(value))
    }, bundleInfo: { bundle in
        // Info.plist only: no band is opened, nothing is mounted. Refuses links and anything over 64 KB.
        let path = bundle + "/Info.plist"
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size > 0, value.st_size <= 65_536 else { return nil }
        var data = Data(count: Int(value.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, Int(value.st_size)) }
        guard count > 0 else { return nil }
        return SparseBundleInfo.parse(data.prefix(count))
    })
}

public struct SparseStorageProbeError: Error, Sendable, Equatable {
    public let code: Int32
    public init(code: Int32) { self.code = code }
    public var missing: Bool { code == ENOENT || code == ENOTDIR }
}

/// What the live check found, compared with the indexed values.
public enum SparseStorageVerification: Sendable, Equatable {
    /// lstat matched the indexed identity and sizes.
    case confirmed(Date)
    /// Same file, but its sizes changed since it was indexed; the live values are used.
    case changedSinceIndexed(Date)
    /// A different file (or a link, or a folder) is now at this path; it will be rechecked after the next index update.
    case replaced(Date)
    /// Not checked live; indexed values are shown. The reason is user-facing.
    case notChecked(String)
    /// macOS refused the check (permissions or privacy).
    case inaccessible(Int32)

    public var checkedAt: Date? {
        switch self {
        case .confirmed(let date), .changedSinceIndexed(let date), .replaced(let date): return date
        case .notChecked, .inaccessible: return nil
        }
    }

    public var summary: String {
        switch self {
        case .confirmed: return "Checked on disk; matches the index."
        case .changedSinceIndexed: return "Checked on disk; changed since it was indexed. Current values are shown."
        case .replaced: return "A different item is now at this path. It will be rechecked after the next index update."
        case .notChecked(let reason): return reason
        case .inaccessible(let code): return "macOS did not allow checking this file (\(String(cString: strerror(code))))."
        }
    }
}

/// The verified result for one candidate, or why it is not reported.
public enum SparseStorageEvaluation: Sendable, Equatable {
    case reported(severity: SparseStorageSeverity, allocation: SparseAllocation, verification: SparseStorageVerification)
    /// Below the reporting thresholds (on the live values when checked).
    case notSparse
    case missing
    /// Transparent filesystem compression, not sparse allocation.
    case compressed
    /// A cloud placeholder whose data is not on this Mac.
    case cloudPlaceholder
}

public enum SparseStorageEvaluator {
    /// Applies the live check to the indexed values. Live values win when the identity matches; an identity change,
    /// a refusal, or a stale-only measurement can never produce REVIEW on its own.
    public static func evaluate(indexed: SparseAllocation, identity: InventoryIdentity, live: Result<SparseStorageLiveMetadata, SparseStorageProbeError>?,
                                skipReason: String?, thresholds: SparseStorageThresholds, now: Date = Date()) -> SparseStorageEvaluation {
        if let skipReason {
            guard let severity = thresholds.severity(indexed) else { return .notSparse }
            return .reported(severity: severity, allocation: indexed, verification: .notChecked(skipReason))
        }
        switch live {
        case nil:
            guard let severity = thresholds.severity(indexed) else { return .notSparse }
            return .reported(severity: severity, allocation: indexed, verification: .notChecked("Not checked on disk."))
        case .failure(let error):
            if error.missing { return .missing }
            // UNKNOWN only where the indexed values would call for review; a refused check of a smaller item stays
            // INFORMATIONAL (with the refusal shown), so it does not lead the Overview.
            guard let indexedSeverity = thresholds.severity(indexed) else { return .notSparse }
            return .reported(severity: indexedSeverity == .review ? .unknown : .informational, allocation: indexed, verification: .inaccessible(error.code))
        case .success(let metadata):
            guard metadata.kind == .file, metadata.device == identity.device, metadata.inode == identity.inode, metadata.birthNanoseconds == identity.birthNanoseconds else {
                guard let indexedSeverity = thresholds.severity(indexed) else { return .notSparse }
                return .reported(severity: indexedSeverity == .review ? .unknown : .informational, allocation: indexed, verification: .replaced(now))
            }
            if metadata.dataless { return .cloudPlaceholder }
            if metadata.compressed { return .compressed }
            let allocation = metadata.allocation
            guard let severity = thresholds.severity(allocation) else { return .notSparse }
            return .reported(severity: severity, allocation: allocation, verification: allocation == indexed ? .confirmed(now) : .changedSinceIndexed(now))
        }
    }
}
