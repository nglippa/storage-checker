import Foundation
import Darwin

struct ExternalVolumeObservations: Codable, Equatable, Sendable {
    var version = 1
    var sampledAt: Date
    var descriptors: [ExternalVolumeDescriptor]
    var error: String?
    var sampledUptime: TimeInterval?
    var bootSession: String?

    static let hostBootSession: String? = {
        var length = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 0, length <= 4096 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }()

    init(sampledAt: Date, descriptors: [ExternalVolumeDescriptor], error: String?,
         sampledUptime: TimeInterval? = ProcessInfo.processInfo.systemUptime, bootSession: String? = Self.hostBootSession) {
        self.sampledAt = sampledAt
        self.descriptors = descriptors
        self.error = error
        self.sampledUptime = sampledUptime; self.bootSession = bootSession
    }
}

typealias ExternalVolumeObservationCatalog = ExternalVolumeObservations

struct ExternalVolumeObservationStore: Sendable {
    let baseDirectory: URL
    var url: URL { baseDirectory.appendingPathComponent("external-volumes/observations.json") }

    func read() throws -> ExternalVolumeObservations? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try ExternalVolumeStorage.read(ExternalVolumeObservations.self, from: url)
        guard value.version == 1, value.sampledAt.timeIntervalSinceReferenceDate.isFinite,
              value.sampledUptime.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw ExternalVolumeError.invalidRegistry }
        return value
    }

    func write(_ value: ExternalVolumeObservations) throws {
        guard value.version == 1 else { throw ExternalVolumeError.invalidRegistry }
        try ExternalVolumeStorage.ensureDirectory(url.deletingLastPathComponent())
        let lock = open(url.deletingLastPathComponent().appendingPathComponent("observations.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ExternalVolumeError.unsafeStorage }
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), flock(lock, LOCK_EX) == 0 else { throw ExternalVolumeError.unsafeStorage }
        if let previous = try? read() {
            if let boot = previous.bootSession, boot == value.bootSession,
               let before = previous.sampledUptime, let after = value.sampledUptime {
                if before > after { return }
            } else if previous.bootSession == value.bootSession, previous.sampledAt > value.sampledAt,
                      previous.sampledAt < Date().addingTimeInterval(60) { return }
        }
        try ExternalVolumeStorage.write(value, to: url)
    }
}
