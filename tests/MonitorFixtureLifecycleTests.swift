import Foundation

@main struct MonitorFixtureLifecycleTests {
    static func main() throws {
        let fm = FileManager.default
        let root = monitorSelfTestFixture("lifecycle-test")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("must-disappear.txt")
        let survivor = root.appendingPathComponent("diagnostic.txt")
        try Data("unlink fixture".utf8).write(to: target)
        try Data("retained diagnostic".utf8).write(to: survivor)
        var count = 0
        func check(_ ok: Bool, _ message: String) throws {
            guard ok else { throw NSError(domain: "MonitorFixtureLifecycle", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            count += 1; print("PASS \(message)")
        }
        let parent = ProcessInfo.processInfo.environment["STORAGE_MONITOR_TEST_FIXTURE_PARENT"] == "/tmp" ? "/tmp" : "/private/tmp"
        try check(root.path.hasPrefix(parent + "/storage-monitor-lifecycle-test-"), "fixture uses requested isolated alias")
        try fm.removeItem(at: target)
        try check(!fm.fileExists(atPath: target.path), "in-test unlink creates absence regardless of retention")
        finishMonitorSelfTestFixture(root)
        let keep = ProcessInfo.processInfo.environment["STORAGE_MONITOR_KEEP_TEST_FIXTURES"] == "1"
        try check(fm.fileExists(atPath: root.path) == keep, "top-level teardown obeys explicit retention")
        try check(!keep || (try Data(contentsOf: survivor)) == Data("retained diagnostic".utf8), "retained diagnostic contents remain intact")
        print("\(count) monitor fixture lifecycle tests passed")
    }
}
