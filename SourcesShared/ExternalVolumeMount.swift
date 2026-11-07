import Foundation
import Darwin

struct ExternalMountIdentity: Codable, Equatable, Sendable {
    var volumeUUID: String
    var device: Int64
    var inode: UInt64
    var birthSeconds: Int64
    var birthNanoseconds: Int64
    var source: String
    var mountPath: String
}

enum ExternalMountProbe {
    // No process and no directory enumeration. A mount that disappeared must not fall back to its parent filesystem.
    static func read(_ path: String) throws -> ExternalMountIdentity {
        var info = stat(), filesystem = statfs()
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              statfs(path, &filesystem) == 0 else { throw ExternalVolumeError.unsupported("The external volume is disconnected or unavailable.") }
        func text<T>(_ value: T) -> String {
            withUnsafePointer(to: value) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
        }
        let mounted = text(filesystem.f_mntonname), source = text(filesystem.f_mntfromname)
        guard mounted == path, source.hasPrefix("/dev/"),
              let raw = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw ExternalVolumeError.unsupported("The selected mount identity is unavailable.")
        }
        return ExternalMountIdentity(volumeUUID: try ExternalVolumeIdentity(raw).uuid, device: Int64(info.st_dev), inode: UInt64(info.st_ino),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec), source: source, mountPath: mounted)
    }
}

enum ExternalLivePath {
    static func resolve(_ catalogPath: String, catalogRoot: String, descriptor: ExternalVolumeDescriptor) throws -> String {
        let observed = try ExternalMountProbe.read(descriptor.mountPath)
        guard observed.volumeUUID == (try descriptor.identity().uuid), observed.device == descriptor.device, observed == descriptor.mountIdentity,
              !catalogRoot.isEmpty, catalogPath == catalogRoot || catalogPath.hasPrefix(catalogRoot + "/") else { throw ExternalVolumeError.invalidIdentity }
        let relative = String(catalogPath.dropFirst(catalogRoot.count))
        guard !relative.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw ExternalVolumeError.invalidIdentity }
        return descriptor.mountPath + relative
    }
}
