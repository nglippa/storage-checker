import Foundation
import Darwin

// Shared metadata semantics for inventory and aggregate coverage. The values describe
// directory entries without reading file contents. Symlinks must be supplied by lstat(2)
// or fstatat(2) with AT_SYMLINK_NOFOLLOW.
struct InventoryFilesystemMetadata {
    let device: Int64
    let inode: UInt64
    let birthNanoseconds: Int64
    let modifiedAt: Double
    let changedNanoseconds: Int64
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let kind: InventoryNodeKind
    let linkCount: UInt64
    let isCloudPlaceholder: Bool

    init(_ value: stat) {
        device = Int64(value.st_dev)
        inode = UInt64(value.st_ino)
        birthNanoseconds = Int64(value.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_birthtimespec.tv_nsec)
        modifiedAt = Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000
        changedNanoseconds = Int64(value.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(value.st_ctimespec.tv_nsec)
        logicalBytes = max(0, Int64(value.st_size))
        allocatedBytes = max(0, Int64(value.st_blocks)) * 512
        linkCount = UInt64(value.st_nlink)
        isCloudPlaceholder = value.st_flags & UInt32(SF_DATALESS) != 0
        switch value.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
    }

    /// An entry whose own metadata macOS refuses (EPERM/EACCES) inside a readable folder, such as
    /// /private/var/db/DifferentialPrivacy. Only its name, inode and type are known; it is recorded
    /// as unknown, with no size, so its folder's totals remain an explicit lower bound.
    init(unreadableEntry inode: UInt64, type: UInt8, device: Int64) {
        self.device = device; self.inode = inode
        birthNanoseconds = 0; modifiedAt = 0; changedNanoseconds = 0
        logicalBytes = 0; allocatedBytes = 0; linkCount = 1; isCloudPlaceholder = false
        switch Int32(type) {
        case DT_DIR: kind = .directory
        case DT_REG: kind = .file
        case DT_LNK: kind = .symlink
        default: kind = .other
        }
    }

    var identity: InventoryIdentity {
        InventoryIdentity(device: device, inode: inode, birthNanoseconds: birthNanoseconds)
    }
}

func inventoryAllocatedBytes(_ value: stat) -> Int64 {
    max(0, Int64(value.st_blocks)) * 512
}
