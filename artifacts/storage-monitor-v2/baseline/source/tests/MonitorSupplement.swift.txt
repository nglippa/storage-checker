import Foundation
import Darwin

// Independent remaining components. The complete self-test remains mandatory.
// Baseline's concurrent-write child and install's isolated startup worker must
// use the real dispatcher instead of recursively starting this runner. Refuse
// unrelated commands and any helper missing its explicit disposable paths.
@main struct MonitorSupplement {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if !args.isEmpty {
                func suiteParent(_ path: String, suite: String, leaves: [String]) -> String? {
                    guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
                    let url = URL(fileURLWithPath: path), parent = url.deletingLastPathComponent()
                    let prefix = "storage-monitor-" + suite + "-"
                    guard leaves.contains(url.lastPathComponent),
                          ["/tmp", "/private/tmp"].contains(parent.deletingLastPathComponent().path),
                          parent.lastPathComponent.hasPrefix(prefix),
                          UUID(uuidString: String(parent.lastPathComponent.dropFirst(prefix.count))) != nil else { return nil }
                    return parent.path
                }
                let stateWriter = args.count == 3 && args[0] == "stress-state-writes" && args[2] == "400"
                    && suiteParent(args[1], suite: "init", leaves: ["shared.sqlite3"]) != nil
                var startupWorker = false
                if (args.count == 5 || args.count == 7), args[0] == "inventory-work", args[1] == "--root", args[3] == "--data-dir",
                   let parent = suiteParent(args[2], suite: "install", leaves: ["startup-root", "missing"]),
                   suiteParent(args[4], suite: "install", leaves: ["startup-state"]) == parent {
                    startupWorker = args.count == 5 || (args[5] == "--budget" && args[6] == "30")
                }
                try required(stateWriter || startupWorker, "Unsupported supplemental helper command")
                try await runMain()
                return
            }
            var count = 0
            func test(_ ok: Bool, _ message: String) throws {
                try required(ok, "FAIL: \(message)")
                count += 1
                print("PASS \(message)")
            }
            try baselineInitializationSelfTest(test)
            try coverageSelfTest(test)
            try inventorySelfTest(test)
            try installSelfTest(test)
            print("\(count) supplemental monitor tests passed")
        } catch {
            fputs("Monitor supplement: \(error)\n", stderr)
            exit(1)
        }
    }
}
