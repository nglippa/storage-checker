import Foundation
import Darwin

enum ExternalVolumeStorage {
    // Non-mutating: readers must never create a missing dataset or follow a redirected ancestor.
    static func validateLocation(_ directory: URL) throws {
        let path = directory.path
        func systemAlias(_ value: String) -> String {
            if value == "/tmp" || value.hasPrefix("/tmp/") || value == "/var" || value.hasPrefix("/var/") { return "/private" + value }
            return value
        }
        guard directory.isFileURL, path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              systemAlias(directory.resolvingSymlinksInPath().path) == systemAlias(path) else { throw ExternalVolumeError.unsafeStorage }
        // Datasets always stay on startup Data, even if a user-supplied support location points elsewhere.
        var ancestor = directory
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        var parentInfo = stat(), startupInfo = stat()
        if stat("/System/Volumes/Data", &startupInfo) == 0 {
            guard stat(ancestor.path, &parentInfo) == 0, parentInfo.st_dev == startupInfo.st_dev else { throw ExternalVolumeError.unsafeStorage }
        }
    }
    static func ensureDirectory(_ directory: URL) throws {
        try validateLocation(directory)
        let path = directory.path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw ExternalVolumeError.unsafeStorage }
        if info.st_mode & 0o777 != 0o700 {
            guard chmod(path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        }
    }
    static func validateDatabaseFile(_ path: String) throws {
        try validateLocation(URL(fileURLWithPath: path).deletingLastPathComponent())
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return }
            throw ExternalVolumeError.unsafeStorage
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw ExternalVolumeError.unsafeStorage }
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG || info.st_uid != getuid() { throw ExternalVolumeError.unsafeStorage }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try validateLocation(url.deletingLastPathComponent())
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ExternalVolumeError.unsafeStorage }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        let limit = 2_097_152
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= limit,
              let bytes = try file.read(upToCount: limit + 1), bytes.count <= limit else { throw ExternalVolumeError.unsafeStorage }
        return try JSONDecoder().decode(type, from: bytes)
    }
}

struct ExternalVolumePaths: Sendable {
    let baseDirectory: URL
    let identity: ExternalVolumeIdentity
    let capacityScope: String
    init(baseDirectory: URL, uuid: String, capacityScope: String) throws {
        self.baseDirectory = baseDirectory
        identity = try ExternalVolumeIdentity(uuid)
        self.capacityScope = try ExternalVolumeIdentity.capacityScope(capacityScope)
    }
    var externalDirectory: URL { baseDirectory.appendingPathComponent("external-volumes", isDirectory: true) }
    var inventoryDirectory: URL { externalDirectory.appendingPathComponent("volumes/" + identity.key, isDirectory: true) }
    var capacityDirectory: URL { externalDirectory.appendingPathComponent("capacity-scopes/" + ExternalVolumeIdentity.storageKey(capacityScope), isDirectory: true) }
    var inventoryDatabase: String { inventoryDirectory.appendingPathComponent("history.sqlite3").path }
    var capacityDatabase: String { capacityDirectory.appendingPathComponent("history.sqlite3").path }
    var catalogsDirectory: URL { inventoryDirectory.appendingPathComponent("catalogs", isDirectory: true) }
    var publicationURL: URL { inventoryDirectory.appendingPathComponent("publication.json") }
    func prepare() throws {
        try ExternalVolumeStorage.ensureDirectory(externalDirectory)
        try ExternalVolumeStorage.ensureDirectory(inventoryDirectory)
        try ExternalVolumeStorage.ensureDirectory(capacityDirectory)
        try ExternalVolumeStorage.validateDatabaseFile(inventoryDatabase)
        try ExternalVolumeStorage.validateDatabaseFile(capacityDatabase)
        let volumeMetadata = inventoryDirectory.appendingPathComponent("identity.json")
        if FileManager.default.fileExists(atPath: volumeMetadata.path) {
            guard try ExternalVolumeStorage.read(ExternalVolumeIdentity.self, from: volumeMetadata) == identity else { throw ExternalVolumeError.identityCollision }
        } else { try ExternalVolumeStorage.write(identity, to: volumeMetadata) }
        let scopeMetadata = capacityDirectory.appendingPathComponent("identity.json")
        if FileManager.default.fileExists(atPath: scopeMetadata.path) {
            guard try ExternalVolumeStorage.read(String.self, from: scopeMetadata) == capacityScope else { throw ExternalVolumeError.identityCollision }
        } else { try ExternalVolumeStorage.write(capacityScope, to: scopeMetadata) }
    }
}

struct ExternalVolumeRegistry: Sendable {
    let baseDirectory: URL
    var directory: URL { baseDirectory.appendingPathComponent("external-volumes", isDirectory: true) }
    var registryURL: URL { directory.appendingPathComponent("registry.json") }
    func read() throws -> ExternalVolumeRegistryDocument {
        var info = stat()
        if lstat(registryURL.path, &info) != 0 {
            if errno == ENOENT { return ExternalVolumeRegistryDocument() }
            throw ExternalVolumeError.invalidRegistry
        }
        let document: ExternalVolumeRegistryDocument
        do { document = try ExternalVolumeStorage.read(ExternalVolumeRegistryDocument.self, from: registryURL) }
        catch { throw ExternalVolumeError.invalidRegistry }
        guard document.version == 1 else { throw ExternalVolumeError.invalidRegistry }
        var scopeBackings = [String: [String]]()
        for (key, value) in document.volumes {
            guard (try? ExternalVolumeIdentity(key).uuid) == key,
                  value.volumeUUID == key, value.revision <= document.revision,
                  (try? ExternalVolumeIdentity.capacityScope(value.capacityScope)) == value.capacityScope,
                  (try? Set(value.backingUUIDs.map { try ExternalVolumeIdentity($0).uuid }).sorted()) == value.backingUUIDs else { throw ExternalVolumeError.invalidRegistry }
            if value.capacityScope.hasPrefix("filesystem:"), value.capacityScope != "filesystem:" + key { throw ExternalVolumeError.invalidRegistry }
            if !value.backingUUIDs.isEmpty {
                if let known = scopeBackings[value.capacityScope], known != value.backingUUIDs { throw ExternalVolumeError.invalidRegistry }
                scopeBackings[value.capacityScope] = value.backingUUIDs
            }
        }
        return document
    }
    @discardableResult func enroll(_ descriptor: ExternalVolumeDescriptor, replaceBacking: Bool = false) throws -> ExternalVolumeRegistration {
        if let reason = descriptor.eligibilityReason { throw ExternalVolumeError.unsupported(reason) }
        let uuid = try descriptor.identity().uuid, backing = try descriptor.normalizedBacking(), scope = try descriptor.capacityScope()
        return try update { document in
            if !backing.isEmpty, document.volumes.values.contains(where: {
                $0.volumeUUID != uuid && $0.capacityScope == scope && !$0.backingUUIDs.isEmpty && $0.backingUUIDs != backing
            }) { throw ExternalVolumeError.ambiguousIdentity }
            if let saved = document.volumes[uuid], !replaceBacking,
               saved.capacityScope != scope || !saved.backingUUIDs.isEmpty && saved.backingUUIDs != backing { throw ExternalVolumeError.changedBacking }
            let value = ExternalVolumeRegistration(volumeUUID: uuid, name: descriptor.name, backingUUIDs: backing, capacityScope: scope,
                                                   enabled: true, indexingPaused: document.volumes[uuid]?.indexingPaused ?? false, revision: document.revision)
            document.volumes[uuid] = value
            return value
        }
    }
    @discardableResult func setEnabled(uuid: String, enabled: Bool) throws -> ExternalVolumeRegistration {
        try change(uuid) { $0.enabled = enabled }
    }
    @discardableResult func setIndexingPaused(uuid: String, paused: Bool) throws -> ExternalVolumeRegistration {
        try change(uuid) { $0.indexingPaused = paused }
    }
    func validate(_ descriptor: ExternalVolumeDescriptor) throws {
        let uuid = try descriptor.identity().uuid
        guard let saved = try read().volumes[uuid] else { throw ExternalVolumeError.invalidIdentity }
        guard saved.capacityScope == (try descriptor.capacityScope()) else { throw ExternalVolumeError.changedBacking }
        if !saved.backingUUIDs.isEmpty, try saved.backingUUIDs != descriptor.normalizedBacking() { throw ExternalVolumeError.changedBacking }
    }
    private func change(_ raw: String, _ body: (inout ExternalVolumeRegistration) -> Void) throws -> ExternalVolumeRegistration {
        let uuid = try ExternalVolumeIdentity(raw).uuid
        return try update { document in
            guard var value = document.volumes[uuid] else { throw ExternalVolumeError.invalidIdentity }
            body(&value); value.revision = document.revision; document.volumes[uuid] = value
            return value
        }
    }
    private func update<T>(_ body: (inout ExternalVolumeRegistryDocument) throws -> T) throws -> T {
        try ExternalVolumeStorage.ensureDirectory(directory)
        let descriptor = open(directory.appendingPathComponent("registry.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ExternalVolumeError.unsafeStorage }
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == getuid(),
              flock(descriptor, LOCK_EX) == 0 else { throw ExternalVolumeError.unsafeStorage }
        var document = try read()
        guard document.revision < UInt64.max else { throw ExternalVolumeError.invalidRegistry }
        document.revision += 1
        let result = try body(&document)
        try ExternalVolumeStorage.write(document, to: registryURL)
        return result
    }
}
