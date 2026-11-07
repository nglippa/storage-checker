import Foundation

// Living Tree color by type. Files take the color of their kind (development, applications, video, images, audio,
// documents, archives, data and caches); folders take the color of the kind that dominates what is drawn beneath
// them, as strongly as it dominates (a mixed folder stays near the neutral branch tone). A few well-known folders
// are colored by what they are (node_modules is development whatever it holds). Grouped small items take their
// folder's color, quieter. Computed once per tree, off the main thread, from names only.

public enum LivingTreeCategory: Int, CaseIterable, Sendable, Comparable {
    case development, applications, video, images, audio, documents, archives, data

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .development: return "Development"
        case .applications: return "Apps"
        case .video: return "Video"
        case .images: return "Images"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .data: return "Data & caches"
        }
    }

    /// Restrained hues that read on the charcoal ground and stay clear of the amber (growth) and blue (reduction)
    /// change light.
    public var tone: AtlasTone {
        switch self {
        case .development: return AtlasTone(hue: 0.38, saturation: 0.50, brightness: 0.88)
        case .applications: return AtlasTone(hue: 0.69, saturation: 0.42, brightness: 0.95)
        case .video: return AtlasTone(hue: 0.79, saturation: 0.46, brightness: 0.95)
        case .images: return AtlasTone(hue: 0.94, saturation: 0.42, brightness: 0.97)
        case .audio: return AtlasTone(hue: 0.47, saturation: 0.50, brightness: 0.86)
        case .documents: return AtlasTone(hue: 0.20, saturation: 0.42, brightness: 0.92)
        case .archives: return AtlasTone(hue: 0.02, saturation: 0.50, brightness: 0.95)
        case .data: return AtlasTone(hue: 0.60, saturation: 0.12, brightness: 0.78)
        }
    }

    static let extensions: [String: LivingTreeCategory] = {
        var map = [String: LivingTreeCategory]()
        func add(_ category: LivingTreeCategory, _ names: String) { for name in names.split(separator: " ") { map[String(name)] = category } }
        add(.development, "swift js mjs cjs ts tsx jsx py pyc pyo rb go rs c h cc cpp hpp m mm java kt kts class jar scala cs php lua sh zsh bash fish pl r dart ex exs erl hs ml clj vue svelte css scss sass less wasm o rlib rmeta d map tsbuildinfo pack idx gradle pbxproj xcconfig storyboard xib nib lock toml ipynb")
        add(.applications, "dylib so bundle plugin appex kext framework app")
        add(.video, "mp4 mov m4v mkv avi webm mxf braw r3d mts m2ts wmv flv mpg mpeg 3gp prproj fcpxml")
        add(.images, "jpg jpeg png heic heif gif tif tiff raw cr2 cr3 nef arw dng orf rw2 psd psb sketch fig svg webp bmp ico icns ai eps exr xcf afphoto afdesign kra procreate")
        add(.audio, "mp3 m4a aac wav aif aiff flac ogg opus caf alac wma mid midi band logicx als sf2 exs")
        add(.documents, "pdf doc docx pages key numbers xls xlsx ppt pptx txt md markdown rtf rtfd epub csv tsv odt ods odp tex mobi azw3 note")
        add(.archives, "zip tar gz tgz bz2 xz zst 7z rar dmg iso pkg sparseimage sparsebundle xip img vmdk qcow2 vdi vhd ipsw tbz txz lz4")
        add(.data, "sqlite sqlite3 db db-wal db-shm sqlite-wal sqlite-shm realm ldb log jsonl json ndjson parquet arrow bin dat cache tmp plist")
        return map
    }()

    static let folders: [String: LivingTreeCategory] = [
        "node_modules": .development, ".git": .development, ".next": .development, "DerivedData": .development, ".venv": .development, "venv": .development,
        "__pycache__": .development, ".gradle": .development, ".cargo": .development, ".rustup": .development, ".npm": .development, "Pods": .development,
        ".pnpm-store": .development, "site-packages": .development, ".m2": .development, "target": .development,
        "Applications": .applications, "Frameworks": .applications,
        "Caches": .data, "Cache": .data, ".cache": .data, "cache": .data, "tmp": .data, ".tmp": .data, "Logs": .data, "logs": .data,
    ]

    /// The category of a file by its extension (nil: not a recognized kind).
    public static func file(_ name: String) -> LivingTreeCategory? {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : extensions[ext]
    }

    /// The category of a folder by its name or package extension (nil: decided by its contents).
    public static func folder(_ name: String) -> LivingTreeCategory? {
        if let category = folders[name] { return category }
        switch (name as NSString).pathExtension.lowercased() {
        case "app", "framework", "appex", "bundle", "plugin", "kext": return .applications
        case "photoslibrary", "photolibrary", "aplibrary": return .images
        case "fcpbundle", "imovielibrary", "tvlibrary": return .video
        case "logicx", "band", "musiclibrary": return .audio
        case "sparsebundle", "xcarchive": return .archives
        case "xcodeproj", "xcworkspace", "playground": return .development
        default: return nil
        }
    }
}

/// An element's color: its category and how strongly it belongs to it (0…1).
public struct LivingTreeHue: Equatable, Sendable {
    public let category: LivingTreeCategory
    public let purity: Double
    public init(category: LivingTreeCategory, purity: Double) { self.category = category; self.purity = purity }
}

public struct LivingTreeColoring: Sendable {
    public let hues: [LivingTreeKey: LivingTreeHue]
    /// Bytes of each category among drawn elements (the legend lists the categories present, largest first).
    public let totals: [LivingTreeCategory: Int64]
    public subscript(key: LivingTreeKey) -> LivingTreeHue? { hues[key] }
    public static let empty = LivingTreeColoring(hues: [:], totals: [:])

    /// The legend: categories with a visible share of the tree, largest first.
    public var present: [LivingTreeCategory] {
        let total = max(1, totals.values.reduce(0, +))
        return totals.filter { Double($0.value) / Double(total) >= 0.003 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    public static func compute(_ model: LivingTreeModel) -> LivingTreeColoring {
        let count = LivingTreeCategory.allCases.count
        var vectors = [LivingTreeKey: [Int64]]()
        var hues = [LivingTreeKey: LivingTreeHue]()
        var totals = [LivingTreeCategory: Int64]()
        // Children before parents.
        for key in model.order.reversed() {
            guard let element = model[key] else { continue }
            var vector = [Int64](repeating: 0, count: count)
            let bytes = element.bytes ?? 0
            switch element.role {
            case .file:
                if let category = LivingTreeCategory.file(element.name) { vector[category.rawValue] = bytes; hues[key] = LivingTreeHue(category: category, purity: 1) }
            case .branch, .trunk, .unmeasured:
                if element.role != .trunk, let category = LivingTreeCategory.folder(element.name) {
                    vector[category.rawValue] = bytes
                    hues[key] = LivingTreeHue(category: category, purity: 1)
                } else {
                    for child in element.children { if let v = vectors[child] { for i in 0..<count { vector[i] += v[i] } } }
                    let known = vector.reduce(0, +)
                    if known > 0, let top = vector.indices.max(by: { vector[$0] < vector[$1] }) {
                        // Dominance among recognized bytes, discounted when most of the folder is not recognized.
                        let share = Double(vector[top]) / Double(known)
                        let coverage = bytes > 0 ? min(1, Double(known) / Double(bytes) * 2) : 1
                        hues[key] = LivingTreeHue(category: LivingTreeCategory(rawValue: top)!, purity: share * coverage)
                    }
                }
            case .rest:
                break
            }
            vectors[key] = vector
        }
        // Totals for the key: a well-known folder counts whole (its contents are not counted again); other recognized
        // files count by their own kind.
        var inside = Set<LivingTreeKey>()
        for key in model.order {
            guard let element = model[key] else { continue }
            if let parent = element.parent, inside.contains(parent) { inside.insert(key); continue }
            if element.role != .trunk, element.role != .file, element.role != .rest, let category = LivingTreeCategory.folder(element.name) {
                totals[category, default: 0] += element.bytes ?? 0; inside.insert(key)
            } else if element.role == .file, let category = LivingTreeCategory.file(element.name) { totals[category, default: 0] += element.bytes ?? 0 }
        }
        // Grouped small items take their folder's color, quieter.
        for key in model.order { if case .rest(let folder) = key, let hue = hues[.node(folder)] { hues[key] = LivingTreeHue(category: hue.category, purity: hue.purity * 0.6) } }
        return LivingTreeColoring(hues: hues, totals: totals)
    }
}
