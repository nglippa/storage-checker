import Foundation
import CryptoKit
import Darwin

/// Headless acceptance of user-authorized disposable fixtures only. No Trash enumeration, Put Back claim,
/// permanent removal, empty-Trash action or production catalog access exists in this harness.
@main struct CleanupTrashValidation {
    static func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

    static func contents(_ url: URL) throws -> [String: String] {
        let fm = FileManager.default
        var result = [String: String](), pending = [(url, "")]
        while let (path, relative) = pending.popLast() {
            var info = stat(); guard lstat(path.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
            if info.st_mode & S_IFMT == S_IFDIR {
                result[relative] = "directory"
                for child in try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
                    pending.append((child, relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent))
                }
            } else if info.st_mode & S_IFMT == S_IFLNK {
                result[relative] = "symlink:" + (try fm.destinationOfSymbolicLink(atPath: path.path))
            } else { result[relative] = try digest(path) }
        }
        return result
    }

    static func main() throws {
        let fm = FileManager.default
        let parent = ProcessInfo.processInfo.environment["STORAGE_MONITOR_TRASH_FIXTURE_PARENT"] ?? "/private/tmp"
        guard parent == "/private/tmp" || parent == "/tmp" else { throw CocoaError(.fileWriteInvalidFileName) }
        let root = URL(fileURLWithPath: parent + "/storage-monitor-trash-validation-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var passed = 0, failed = 0
        try cleanupTrashSafetyTests(root.appendingPathComponent("policy-fixtures")) { ok, message in
            print("\(ok ? "PASS" : "FAIL") \(message)"); if ok { passed += 1 } else { failed += 1 }
        }
        print("TRASH SAFETY: \(passed) passed, \(failed) failed. Retained disposable fixture root: \(root.path)")
        guard failed == 0 else { exit(1) }
        if CommandLine.arguments.contains("--real-use-checks") {
            let executable = root.appendingPathComponent("disposable-running-sleep")
            try fm.copyItem(atPath: "/bin/sleep", toPath: executable.path)
            let process = Process(); process.executableURL = executable; process.arguments = ["3"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
            let observation = ProcessObservation.currentUserSafety()
            let decision = CleanupTrashPolicy.prepare(node: try trashSafetyNode(executable.path), environment: .current())
            if case .blocked(let reason) = decision, observation.runs(within: executable.path) {
                print("REAL ACTIVE USE: PASS kernel-observed disposable running executable blocked: \(reason)")
            } else { print("REAL ACTIVE USE: FAIL running fixture not observed and blocked"); exit(1) }
        }
        guard CommandLine.arguments.contains("--real-trash") else { return }
        let fixtures = root.appendingPathComponent("real-fixtures")
        try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String = "Known disposable Storage Monitor QA checksum data.\n") throws -> URL {
            let url = fixtures.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url); return url
        }
        let ordinary = try file("ordinary-" + UUID().uuidString + ".txt")
        let spaces = try file("file with spaces " + UUID().uuidString + ".txt")
        let unicode = try file("café-猫-" + UUID().uuidString + ".txt")
        let directory = fixtures.appendingPathComponent("ordinary-directory-" + UUID().uuidString)
        _ = try file(directory.lastPathComponent + "/one.txt"); _ = try file(directory.lastPathComponent + "/two.txt")
        let nested = fixtures.appendingPathComponent("nested-directory-" + UUID().uuidString)
        _ = try file(nested.lastPathComponent + "/a/b/c/nested.txt")
        let project = fixtures.appendingPathComponent("candidate-project-" + UUID().uuidString)
        _ = try file(project.lastPathComponent + "/package.json", "{}")
        _ = try file(project.lastPathComponent + "/package-lock.json", "{}")
        _ = try file(project.lastPathComponent + "/node_modules/fixture.txt")
        let candidate = project.appendingPathComponent("node_modules")
        let referent = try file("unrelated-referent-must-stay.txt", "Unrelated disposable referent remains untouched.\n")
        let link = fixtures.appendingPathComponent("symbolic-link-" + UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: referent)
        let sentinelIdentity = try trashSafetyNode(referent.path).identity
        let sentinelDigest = try digest(referent)
        let items = [("ordinary file/checksum", ordinary), ("spaces filename", spaces), ("Unicode filename", unicode),
                     ("ordinary directory", directory), ("nested directory", nested), ("review candidate", candidate), ("symlink itself", link)]
        var records = [[String: Any]]()
        var originalManifest = [String: [String: String]]()
        for (_, url) in items { originalManifest[url.path] = try contents(url) }
        // Persist expected bytes outside all movable targets before any system operation.
        try JSONSerialization.data(withJSONObject: originalManifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("original-content-manifest.json"))
        let environment = ArtifactEnvironment.current()
        for (label, url) in items {
            let node = try trashSafetyNode(url.path)
            var record: [String: Any] = ["case": label, "original": url.path, "identity": node.identity.stableKey,
                                        "finderPutBack": "UNVERIFIED", "physicalRecovery": "UNVERIFIED; not measured", "residualPathRace": "Accepted; not eliminated"]
            switch CleanupTrashPolicy.prepare(node: node, environment: environment) {
            case .blocked(let reason): record["result"] = "BLOCKED"; record["reason"] = reason; failed += 1
            case .ready(let confirmation):
                // --real-trash is the explicit QA invocation; product users authorize through the native sheet.
                let outcome = CleanupTrashPolicy.perform(confirmation: confirmation, overrideAccepted: true, environment: environment)
                switch outcome {
                case .moved(let path):
                    if let path {
                        let restoredContents = try contents(URL(fileURLWithPath: path))
                        let matched = restoredContents == originalManifest[url.path]
                        record["trashDestination"] = path; record["contentsAndChecksumsMatch"] = matched
                        record["originalAbsent"] = (try? trashSafetyNode(url.path)) == nil
                        record["result"] = matched && (try? trashSafetyNode(url.path)) == nil ? "VERIFIED" : "FAILED_VERIFICATION"
                        if record["result"] as? String != "VERIFIED" { failed += 1 }
                    } else { record["result"] = "UNVERIFIED_DESTINATION"; failed += 1 }
                case .refused(let reason): record["result"] = "REFUSED"; record["reason"] = reason; failed += 1
                case .failed(let reason): record["result"] = "FAILED_OR_UNCERTAIN"; record["reason"] = reason; failed += 1
                }
            }
            records.append(record)
            // Preserve the actual resulting URL even if a later case fails. Never enumerate unrelated Trash.
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("real-trash-results.json"))
        }
        let unrelatedIntact = (try? trashSafetyNode(referent.path).identity) == sentinelIdentity && (try? digest(referent)) == sentinelDigest
        if !unrelatedIntact { failed += 1 }
        print("REAL TRASH: \(items.count - records.filter { $0["result"] as? String != "VERIFIED" }.count)/\(items.count) verified moves; unrelated referent preserved: \(unrelatedIntact)")
        print("Retained report: \(root.appendingPathComponent("real-trash-results.json").path). All moved fixtures remain in system Trash; no permanent deletion or Put Back automation occurred.")
        if failed > 0 { exit(1) }
    }
}
