import Foundation

func externalVolumeCommand(_ command: String, args: [String], directory: URL) throws {
    guard NativeQARuntime.active == nil else { try NativeQARuntime.reject("External commands are outside the native QA fixture") }
    let control = ExternalVolumeControl(baseDirectory: directory)
    func uuid() throws -> String {
        guard args.count > 1 else { throw Failure("A volume UUID is required") }
        return try ExternalVolumeIdentity(args[1]).uuid
    }
    func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    switch command {
    case "external-discover":
        let observations = ExternalVolumeDiscovery.discover()
        try ExternalVolumeObservationStore(baseDirectory: directory).write(observations)
        try output(observations)
    case "external-list": try output(ExternalVolumeRegistry(baseDirectory: directory).read())
    case "external-enable": try output(control.enroll(uuid: uuid(), replaceBacking: args.contains("--replace-backing")))
    case "external-disable": try control.disable(uuid: uuid())
    case "external-pause", "external-resume", "external-refresh":
        let action = String(command.dropFirst("external-".count))
        var path: String?
        if let i = args.firstIndex(of: "--path"), i + 1 < args.count { path = args[i + 1] }
        _ = try control.request(uuid: uuid(), action: action, path: path)
    case "external-check":
        let observations = ExternalVolumeDiscovery.discover()
        try ExternalVolumeObservationStore(baseDirectory: directory).write(observations)
        try ExternalCapacityMonitoring.sample(baseDirectory: directory, observations: observations)
    default: throw Failure("Unknown external-volume command")
    }
}
