import Foundation

// Migration Readiness wording. Every sentence is grounded in the measured metadata or in how copy tools are documented
// to behave; nothing predicts a migration outcome, recommends deleting application storage, or excludes anything from
// a backup or migration. Kept in shared code so tests can check the wording.

public enum SparseStorageGuidance {
    /// The headline consequence, phrased as a possibility.
    public static let reviewHeadline = "Potential migration compatibility issue"

    /// One paragraph about this item's measurements, for the Overview and the Inspector.
    public static func explanation(_ item: SparseStorageItem, bytes: (Int64) -> String) -> String {
        let logical = bytes(item.allocation.logical), allocated = bytes(item.allocation.allocated)
        let noun = item.kind.isSparseBundle ? "sparse bundle's band files" : (item.kind.category == .sparseFile || item.kind.category == .unknown ? "file" : nounFor(item.kind))
        switch item.severity {
        case .review:
            return "Although this \(noun) reports \(logical) of logical size, about \(allocated) is currently allocated on disk. Some transfer methods may require more destination space than the current allocation suggests, or may not preserve sparse allocation."
        case .informational:
            return "This \(noun) reports \(logical) of logical size; about \(allocated) is allocated on disk. Sparse allocation was detected; no specific compatibility concern is established."
        case .unknown:
            return "The inventory recorded \(logical) of logical size and \(allocated) allocated for this \(noun), but it could not be checked on disk now. Treat these values as unconfirmed."
        }
    }

    static func nounFor(_ kind: SparseStorageKind) -> String {
        switch kind.category {
        case .virtualization: return "virtual disk"
        case .diskImage, .containerRuntime: return "disk image"
        case .sparseFile, .unknown: return "file"
        }
    }

    /// Category-specific considerations, most important first.
    public static func considerations(_ kind: SparseStorageKind) -> [String] {
        var items = [String]()
        let app = kind.application
        switch kind.category {
        case .containerRuntime:
            items = [
                "Container images, volumes and databases can all live inside this one disk image.",
                "Its logical size is the most it currently reports; its allocated size is what is stored now. Both describe the same file.",
                "Before migrating, review the storage that \(app ?? "the container application") manages, using its own settings or commands.",
                "Back up or export data you need, such as volumes and databases, with \(app ?? "the application")'s own tools.",
                "Do not delete or move this file by hand while \(app ?? "the application") uses it.",
            ]
        case .virtualization:
            items = [
                "Virtual disks are often sparse: they report a large size while storing only what the virtual machine has written.",
                "A virtual disk can contain an entire operating system, its applications and documents.",
                "Use \(app.map { $0 + "'s" } ?? "the virtualization application's") documented procedure to move or export virtual machines.",
            ]
        case .diskImage, .sparseFile, .unknown:
            items = [
                "Copy tools differ: some preserve sparse allocation, others write every logical byte to the destination.",
                "If you are unsure how a tool copies, make sure the destination has room for the logical size.",
            ]
            if app != nil { items.append("This file is in \(app!)'s storage; manage it with \(app!).") }
        }
        if kind.isSparseBundle {
            items.insert("A sparse bundle's capacity is a limit, not stored data; copying it transfers its band files.", at: 0)
        }
        return items
    }

    /// Always shown with any detail.
    public static let general = [
        "These are filesystem measurements, not a confirmed migration incompatibility.",
        "Storage Monitor cannot predict whether Migration Assistant or another tool will succeed, and does not exclude anything from backups or migrations.",
        "The apparent gap is neither space in use nor space that can be recovered.",
    ]

    public static func dataSafety(_ kind: SparseStorageKind) -> String {
        switch kind.category {
        case .containerRuntime, .virtualization:
            return "Deleting a container or virtual machine disk image can destroy application data, databases or entire virtual machines. Storage Monitor offers no delete action for these items; manage them in their application."
        case .diskImage:
            return "A disk image can hold a whole volume of files. Storage Monitor offers no delete action here; open it with the application that created it to review its contents."
        case .sparseFile, .unknown:
            return "This file may belong to an application. Storage Monitor offers no delete action here; keep it unless you know what it holds."
        }
    }

    /// "9.8 : 1", or a statement when nothing is allocated.
    public static func ratio(_ allocation: SparseAllocation) -> String {
        guard let ratio = allocation.ratio else { return allocation.logical > 0 ? "Nothing allocated" : "Not applicable (empty file)" }
        return (ratio >= 100 ? ratio.formatted(.number.precision(.fractionLength(0))) : ratio.formatted(.number.precision(.fractionLength(1)))) + " : 1"
    }
}
