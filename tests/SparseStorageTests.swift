import Foundation
import Darwin

// Migration Readiness: pure model tests (allocation arithmetic, thresholds, classification, protected locations,
// live-check evaluation, sparse bundle metadata, wording) plus the live probe against real APFS files created under
// /private/tmp. Synthetic values are labelled as such; filesystem facts come from files created here.

private let GiB = SparseStorageThresholds.gibibyte

func sparseStorageModelTests(_ scratch: URL, _ test: (Bool, String) throws -> Void) throws {
    // MARK: Allocation arithmetic (synthetic values)
    let sparse = SparseAllocation(logical: 460 * GiB, allocated: 45 * GiB)
    try test(sparse.gap == 415 * GiB && abs((sparse.ratio ?? 0) - 460.0 / 45.0) < 1e-9, "sparse storage: gap is logical − allocated and ratio is logical ÷ allocated")
    let full = SparseAllocation(logical: 4096, allocated: 4096)
    try test(full.gap == 0 && full.ratio == 1, "sparse storage: a fully allocated file has no gap and a 1 : 1 ratio")
    let empty = SparseAllocation(logical: 0, allocated: 0)
    try test(empty.gap == 0 && empty.ratio == nil && !empty.meetsRatio(1.25) && SparseStorageGuidance.ratio(empty) == "Not applicable (empty file)",
             "sparse storage: a zero-byte file has no gap, no ratio and never meets a ratio")
    let unallocated = SparseAllocation(logical: 12 * GiB, allocated: 0)
    try test(unallocated.ratio == nil && unallocated.meetsRatio(1_000_000) && unallocated.gap == 12 * GiB && SparseStorageGuidance.ratio(unallocated) == "Nothing allocated",
             "sparse storage: zero allocation is handled without dividing by zero (unbounded ratio)")
    let preallocated = SparseAllocation(logical: 1_000, allocated: 8_192)
    try test(preallocated.gap == 0 && SparseAllocation(logical: -5, allocated: -1) == SparseAllocation(logical: 0, allocated: 0),
             "sparse storage: preallocation never produces a negative gap; negative inputs are clamped")
    try test(SparseStorageGuidance.ratio(SparseAllocation(logical: 98, allocated: 10)) == "9.8 : 1", "sparse storage: ratios read as \"9.8 : 1\"")

    // MARK: Thresholds and boundaries (synthetic values)
    let t = SparseStorageThresholds.standard
    try test(t.reviewMinimumLogical == 10 * GiB && t.reviewMinimumGap == 5 * GiB && t.reviewMinimumRatio == 4 && t.reportMinimumGap == GiB,
             "sparse storage: default thresholds are 10 GiB logical, 5 GiB gap, 4 : 1 (review) and 1 GiB gap (reported)")
    try test(t.severity(SparseAllocation(logical: 10 * GiB, allocated: 10 * GiB / 4)) == .review
             && t.severity(SparseAllocation(logical: 10 * GiB, allocated: 10 * GiB / 4 + 1)) == .informational
             && t.severity(SparseAllocation(logical: 10 * GiB - 1, allocated: 0)) == .informational,
             "sparse storage: review boundary is inclusive at exactly 10 GiB and 4 : 1; one byte past either is informational")
    let custom = SparseStorageThresholds(reviewMinimumLogical: GiB, reviewMinimumGap: 5 * GiB, reviewMinimumRatio: 1)
    try test(custom.severity(SparseAllocation(logical: 6 * GiB, allocated: GiB)) == .review
             && custom.severity(SparseAllocation(logical: 6 * GiB, allocated: GiB + 1)) == .informational,
             "sparse storage: the gap boundary is inclusive (custom thresholds isolate it)")
    try test(t.severity(SparseAllocation(logical: 5 * GiB, allocated: 4 * GiB)) == .informational
             && t.severity(SparseAllocation(logical: 5 * GiB, allocated: 4 * GiB + 1)) == nil
             && t.severity(SparseAllocation(logical: GiB - 1, allocated: 0)) == nil && t.reportMinimumRatio == 1,
             "sparse storage: the reporting floor (1 GiB gap, no ratio floor by default) is inclusive; below it nothing is reported")
    let ratioFloor = SparseStorageThresholds(reportMinimumRatio: 1.25)
    try test(ratioFloor.severity(SparseAllocation(logical: 5 * GiB, allocated: 4 * GiB)) == .informational
             && ratioFloor.severity(SparseAllocation(logical: 500 * GiB, allocated: 450 * GiB)) == nil,
             "sparse storage: an optional reporting ratio floor is inclusive (5 : 4 meets 1.25 : 1; 500 : 450 does not)")
    try test(t.severity(SparseAllocation(logical: 20 * GiB, allocated: 20 * GiB - 4_096)) == nil && t.severity(SparseAllocation(logical: 500 * GiB, allocated: 450 * GiB)) == .informational
             && t.severity(SparseAllocation(logical: 460 * GiB, allocated: 300 * GiB)) == .informational,
             "sparse storage: close logical and allocated sizes are not reported; a large gap at a low ratio is informational, not review")
    let clamped = SparseStorageThresholds(reviewMinimumLogical: -1, reviewMinimumGap: 2, reviewMinimumRatio: 0.5, reportMinimumGap: 10, reportMinimumRatio: 9)
    try test(clamped.reviewMinimumRatio == 1 && clamped.reportMinimumGap <= clamped.reviewMinimumGap && clamped.reportMinimumRatio <= clamped.reviewMinimumRatio,
             "sparse storage: configured thresholds are clamped so the reporting floor never exceeds review")

    // MARK: Classification (paths only; no file is opened)
    for user in ["alice", "bob"] {
        let docker = SparseStorageClassifier.classify(path: "/Users/\(user)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", isDirectory: false)
        try test(docker.category == .containerRuntime && docker.application == "Docker Desktop" && docker.format == "Raw disk image" && docker.title == "Docker Desktop disk image",
                 "sparse storage: Docker Desktop's disk image is identified from its documented location for any user (\(user))")
    }
    let dataVolume = SparseStorageClassifier.classify(path: "/System/Volumes/Data/Users/x/.orbstack/data/data.img", isDirectory: false)
    try test(dataVolume.application == "OrbStack" && dataVolume.category == .containerRuntime, "sparse storage: OrbStack storage is identified through the Data volume path")
    let kinds: [(String, SparseStorageCategory, String?)] = [
        ("/Users/x/Parallels/Windows 11.pvm/harddisk.hdd/harddisk.hdd.0.{5fbaabe3}.hds", .virtualization, "Parallels Desktop"),
        ("/Users/x/Virtual Machines.localized/Ubuntu.vmwarevm/Virtual Disk.vmdk", .virtualization, "VMware Fusion"),
        ("/Users/x/Library/Containers/com.utmapp.UTM/Data/Documents/Linux.utm/Data/disk.qcow2", .virtualization, "UTM"),
        ("/Users/x/.lima/default/diffdisk", .containerRuntime, "Lima"),
        ("/Users/x/.colima/_lima/colima/diffdisk", .containerRuntime, "Colima"),
        ("/Users/x/.local/share/containers/podman/machine/applehv/podman-machine-default-arm64.raw", .containerRuntime, "Podman"),
        ("/Users/x/.tart/vms/sonoma/disk.img", .virtualization, "Tart"),
        ("/Users/x/VMs/server.qcow2", .virtualization, nil),
        ("/Users/x/VMs/old.vdi", .virtualization, nil),
        ("/Users/x/Images/backup.sparseimage", .diskImage, nil),
        ("/Users/x/Images/disk.raw", .diskImage, nil),
        ("/Users/x/data/blob.bin", .sparseFile, nil),
        ("/Users/x/data/unknown.xyz", .sparseFile, nil),
    ]
    for (path, category, app) in kinds {
        let kind = SparseStorageClassifier.classify(path: path, isDirectory: false)
        try test(kind.category == category && kind.application == app, "sparse storage: \((path as NSString).lastPathComponent) → \(category.rawValue)\(app.map { " (\($0))" } ?? "")")
    }
    let unsupported = SparseStorageClassifier.classify(path: "/Users/x/data/unknown.xyz", isDirectory: false)
    try test(unsupported.format == nil && unsupported.evidence.isEmpty && unsupported.title == "Sparse file", "sparse storage: an unsupported format is reported only as a sparse file, without a guessed format")
    try test(SparseStorageClassifier.classify(path: "/Users/x/Downloads/com.docker.docker", isDirectory: false).application == nil,
             "sparse storage: a file merely named like an application folder is not attributed to it")
    let bundle = SparseStorageClassifier.classify(path: "/Users/x/Backups/Old.sparsebundle", isDirectory: true)
    try test(bundle.isSparseBundle && bundle.category == .diskImage && bundle.format == "Sparse bundle", "sparse storage: a .sparsebundle folder is a sparse bundle disk image")
    try test(SparseStorageClassifier.classify(path: "/Users/x/a.raw", isDirectory: false).evidence.allSatisfy { $0.contains("not read or verified") || $0.contains("inferred") },
             "sparse storage: evidence states that formats are not read and owners are inferred")

    // MARK: Protected and cloud locations
    let home = "/Users/x"
    let protected = ["/Users/x/Documents/a.raw", "/Users/x/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "/Users/x/Library/Application Support/foo/disk.img", "/System/Volumes/Data/Users/x/Desktop/b.img"]
    let open = ["/Users/x/Library/Caches/c.img", "/Users/x/Library/Developer/d.img", "/Users/x/.orbstack/data/data.img", "/Users/Shared/e.img", "/Applications/f.img", "/Users/x/Parallels/W.pvm/h.hds"]
    try test(protected.allSatisfy { SparseStorageLocations.isProtected($0, home: home) } && open.allSatisfy { !SparseStorageLocations.isProtected($0, home: home) },
             "sparse storage: privacy-protected locations are never checked live; caches, developer data and dot-folders are")
    try test(SparseStorageLocations.isCloud("/Users/x/Library/Mobile Documents/com~apple~CloudDocs/v.mov", home: home) && SparseStorageLocations.isCloud("/Users/x/Library/CloudStorage/Dropbox/v.mov", home: home)
             && !SparseStorageLocations.isCloud("/Users/x/Movies/v.mov", home: home), "sparse storage: iCloud Drive and File Provider folders are cloud locations")
    try test(SparseStorageLocations.redacted("/System/Volumes/Data/Users/x/.orbstack/data/data.img", home: home) == "~/.orbstack/data/data.img"
             && SparseStorageLocations.redacted("/Applications/x.img", home: home) == "/Applications/x.img", "sparse storage: paths under the home folder are redacted to ~")

    // MARK: Evaluation of live checks (synthetic metadata)
    let identity = InventoryIdentity(device: 7, inode: 99, birthNanoseconds: 1_000)
    let indexed = SparseAllocation(logical: 460 * GiB, allocated: 45 * GiB)
    func metadata(inode: UInt64 = 99, kind: InventoryNodeKind = .file, logical: Int64 = 460 * GiB, allocated: Int64 = 45 * GiB, compressed: Bool = false, dataless: Bool = false) -> Result<SparseStorageLiveMetadata, SparseStorageProbeError> {
        .success(SparseStorageLiveMetadata(device: 7, inode: inode, birthNanoseconds: 1_000, kind: kind, logical: logical, allocated: allocated, compressed: compressed, dataless: dataless))
    }
    let now = Date(timeIntervalSince1970: 1_000)
    func evaluate(_ live: Result<SparseStorageLiveMetadata, SparseStorageProbeError>?, skip: String? = nil) -> SparseStorageEvaluation {
        SparseStorageEvaluator.evaluate(indexed: indexed, identity: identity, live: live, skipReason: skip, thresholds: t, now: now)
    }
    try test(evaluate(metadata()) == .reported(severity: .review, allocation: indexed, verification: .confirmed(now)), "sparse storage: a live check that matches the index confirms the item")
    let grown = SparseAllocation(logical: 460 * GiB, allocated: 200 * GiB)
    try test(evaluate(metadata(allocated: 200 * GiB)) == .reported(severity: .informational, allocation: grown, verification: .changedSinceIndexed(now)),
             "sparse storage: metadata that changed after indexing is re-evaluated on the live values")
    try test(evaluate(metadata(allocated: 460 * GiB)) == .notSparse, "sparse storage: a file that became fully allocated is no longer reported")
    try test(evaluate(metadata(inode: 100)) == .reported(severity: .unknown, allocation: indexed, verification: .replaced(now))
             && evaluate(metadata(kind: .symlink)) == .reported(severity: .unknown, allocation: indexed, verification: .replaced(now)),
             "sparse storage: a replaced file, or a symbolic link now at the path, is UNKNOWN and never followed")
    try test(evaluate(.failure(SparseStorageProbeError(code: EACCES))) == .reported(severity: .unknown, allocation: indexed, verification: .inaccessible(EACCES))
             && evaluate(.failure(SparseStorageProbeError(code: EPERM))) == .reported(severity: .unknown, allocation: indexed, verification: .inaccessible(EPERM)),
             "sparse storage: an inaccessible file is UNKNOWN with its indexed values, never REVIEW")
    let small = SparseAllocation(logical: 3 * GiB, allocated: GiB)
    try test(SparseStorageEvaluator.evaluate(indexed: small, identity: identity, live: .failure(SparseStorageProbeError(code: EACCES)), skipReason: nil, thresholds: t, now: now)
             == .reported(severity: .informational, allocation: small, verification: .inaccessible(EACCES)),
             "sparse storage: a refused check of an informational-sized item stays INFORMATIONAL (UNKNOWN is kept for review-sized items)")
    try test(evaluate(.failure(SparseStorageProbeError(code: ENOENT))) == .missing && evaluate(.failure(SparseStorageProbeError(code: ENOTDIR))) == .missing,
             "sparse storage: a file deleted since indexing is dropped as missing")
    try test(evaluate(metadata(dataless: true)) == .cloudPlaceholder && evaluate(metadata(compressed: true)) == .compressed,
             "sparse storage: cloud placeholders and transparently compressed files are not mistaken for sparse files")
    let skipped = evaluate(nil, skip: "protected")
    try test(skipped == .reported(severity: .review, allocation: indexed, verification: .notChecked("protected")), "sparse storage: an item that cannot be checked without a prompt keeps its indexed severity, marked not checked")

    // MARK: Sparse bundle metadata (synthetic plists)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleInfoDictionaryVersion": "6.0", "band-size": 8_388_608, "size": 1_099_511_627_776, "diskimage-bundle-type": "com.apple.diskimage.sparsebundle"], format: .xml, options: 0)
    try test(SparseBundleInfo.parse(plist) == SparseBundleInfo(capacity: 1_099_511_627_776, bandSize: 8_388_608), "sparse storage: a sparse bundle's capacity and band size come from its Info.plist")
    let partial = try PropertyListSerialization.data(fromPropertyList: ["size": -4], format: .xml, options: 0)
    try test(SparseBundleInfo.parse(partial) == SparseBundleInfo(capacity: nil, bandSize: nil) && SparseBundleInfo.parse(Data("not a plist".utf8)) == nil,
             "sparse storage: missing, invalid or malformed bundle metadata stays unknown")

    // MARK: Wording
    let item = SparseStorageItem(node: sparseTestNode(1, "/Users/x/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"), ancestors: [], kind: SparseStorageClassifier.classify(path: "/Users/x/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", isDirectory: false),
                                 severity: .review, indexed: indexed, allocation: indexed, verification: .confirmed(now), bundle: nil)
    let decimal = { (b: Int64) in "\(b / 1_000_000_000) GB" }
    let explanation = SparseStorageGuidance.explanation(item, bytes: decimal)
    try test(explanation.contains("493 GB of logical size") && explanation.contains("about 48 GB is currently allocated") && explanation.contains("may require"),
             "sparse storage: the explanation states measured logical and allocated sizes and a possibility, not a prediction")
    var wording = [explanation, SparseStorageGuidance.reviewHeadline] + SparseStorageGuidance.general
    for category in SparseStorageCategory.allCases {
        let kind = SparseStorageKind(category: category, application: category == .containerRuntime ? "Docker Desktop" : nil)
        wording += SparseStorageGuidance.considerations(kind) + [SparseStorageGuidance.dataSafety(kind)]
    }
    let forbidden = ["will fail", "guarantee", "safe to delete", "you can delete", "free up", "reclaim", "docker system prune", "compact", "exclude it"]
    try test(wording.allSatisfy { line in !forbidden.contains { line.lowercased().contains($0) } },
             "sparse storage: no wording predicts failure, promises recovery, or recommends deleting, pruning, compacting or excluding")
    try test(SparseStorageGuidance.dataSafety(item.kind).contains("can destroy application data") && SparseStorageGuidance.dataSafety(item.kind).contains("no delete action"),
             "sparse storage: data-safety guidance warns that deleting container or VM images can destroy data")
    try test(SparseStorageGuidance.considerations(item.kind).contains { $0.contains("Back up or export") } && SparseStorageGuidance.considerations(SparseStorageKind(category: .virtualization, application: "UTM")).contains { $0.contains("UTM's documented procedure") },
             "sparse storage: guidance points to backup/export and to the application's own migration procedure")

    // MARK: Report summary and coverage (synthetic)
    var coverage = SparseStorageCoverage(); coverage.inventoryAvailable = true; coverage.inventoryIncomplete = false
    let clear = SparseStorageReport(items: [], reviewCount: 0, unknownCount: 0, informationalCount: 0, coverage: coverage, thresholds: t, generation: 1, filesystem: "apfs", completedAt: now, pass: .full)
    try test(clear.summary == "No large sparse-storage discrepancies detected in scanned locations." && clear.headline == nil && clear.coverage.isComplete && clear.coverage.notes.isEmpty,
             "sparse storage: with nothing detected the summary is limited to scanned locations")
    let absent = SparseStorageReport(items: [], reviewCount: 0, unknownCount: 0, informationalCount: 0, coverage: SparseStorageCoverage(), thresholds: t, generation: nil, filesystem: nil, completedAt: now, pass: .full)
    try test(absent.summary == "Waiting for disk inventory; nothing checked yet" && !absent.coverage.isComplete,
             "sparse storage: absent inventory never reports a successful clean result")
    var measuringCoverage = coverage; measuringCoverage.inventoryIncomplete = true
    let measuring = SparseStorageReport(items: [], reviewCount: 0, unknownCount: 0, informationalCount: 0, coverage: measuringCoverage, thresholds: t, generation: 1, filesystem: "apfs", completedAt: now, pass: .full)
    try test(measuring.summary.contains("in scanned locations") && !measuring.coverage.isComplete,
             "sparse storage: a started incomplete inventory limits the clean result to scanned locations")
    coverage.inventoryIncomplete = true; coverage.protectedFolders = 3
    coverage.limitedLocations = [.init(application: "Docker Desktop", path: "~/Library/Containers/com.docker.docker", state: .protected, installed: true)]
    let limited = SparseStorageReport(items: [item], reviewCount: 1, unknownCount: 0, informationalCount: 0, coverage: coverage, thresholds: t, generation: 1, filesystem: "apfs", completedAt: now, pass: .full)
    try test(!limited.coverage.isComplete && limited.coverage.notes.count == 3 && limited.coverage.notes[1].contains("Docker Desktop is installed, but its storage folder is protected")
             && limited.summary == "1 item to review" && limited.headline?.id == 1,
             "sparse storage: incomplete coverage is stated, including an installed application's protected storage")

    // MARK: Live probe on real APFS files (created here; never followed or opened beyond lstat)
    let folder = scratch.appendingPathComponent("sparse-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sparsePath = folder.appendingPathComponent("image.raw").path
    try makeSparseFile(sparsePath, logical: 64 << 20, written: 4_096)
    let fullPath = folder.appendingPathComponent("full.bin").path
    try Data(repeating: 0xA5, count: 1 << 20).write(to: URL(fileURLWithPath: fullPath))
    let linkPath = folder.appendingPathComponent("link.raw").path
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: sparsePath)
    if case .success(let live) = SparseStorageProbe.live.metadata(sparsePath), case .success(let whole) = SparseStorageProbe.live.metadata(fullPath),
       case .success(let link) = SparseStorageProbe.live.metadata(linkPath) {
        try test(live.logical == 64 << 20 && live.allocated < 1 << 20 && live.kind == .file && !live.compressed && !live.dataless,
                 "sparse storage (APFS): an ftruncated file reports 64 MiB logical and under 1 MiB allocated (\(live.allocated) bytes)")
        try test(whole.logical == 1 << 20 && whole.allocated >= 1 << 20, "sparse storage (APFS): a written file is fully allocated (\(whole.allocated) bytes)")
        try test(link.kind == .symlink && link.logical < 1_024, "sparse storage (APFS): the probe reads a symbolic link itself and never follows it")
    } else { try test(false, "sparse storage (APFS): the live probe could read the fixture files") }
    try test(SparseStorageProbe.live.metadata(folder.appendingPathComponent("absent").path) == .failure(SparseStorageProbeError(code: ENOENT)), "sparse storage (APFS): a missing file reports ENOENT")
}

/// A file with `logical` length and only `written` bytes of data at its start (APFS keeps the rest unallocated).
func makeSparseFile(_ path: String, logical: Int64, written: Int) throws {
    let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    let data = [UInt8](repeating: 0x5A, count: written)
    guard write(fd, data, data.count) == data.count, ftruncate(fd, off_t(logical)) == 0, fsync(fd) == 0 else { throw POSIXError(.EIO) }
}

func sparseTestNode(_ id: Int64, _ path: String, kind: InventoryNodeKind = .file) -> InventoryNode {
    InventoryNode(id: id, parentID: nil, identity: .init(device: 7, inode: 99, birthNanoseconds: 1_000), path: path, name: (path as NSString).lastPathComponent, kind: kind,
                  logicalBytes: nil, allocatedBytes: nil, previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil,
                  directLogicalBytes: 0, directAllocatedBytes: 0, childCount: 0, descendantFiles: 0, descendantDirectories: 0, status: .complete,
                  coverageState: "complete", listingState: nil, statusReason: nil, measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
}
