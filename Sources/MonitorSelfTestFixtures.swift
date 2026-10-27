import Foundation

// Self-test lifecycle only. Retention preserves the final diagnostic tree, not every
// intermediate object: unlink/FSEvents/open-deleted tests must still really unlink
// their own disposable objects. Never interpose removeItem throughout a source copy.
func monitorSelfTestFixture(_ suite: String) -> URL {
    let requested = ProcessInfo.processInfo.environment["STORAGE_MONITOR_TEST_FIXTURE_PARENT"]
    let parent = requested == "/tmp" ? "/tmp" : "/private/tmp"
    return URL(fileURLWithPath: parent + "/storage-monitor-\(suite)-\(UUID().uuidString)")
}

func finishMonitorSelfTestFixture(_ root: URL) {
    if ProcessInfo.processInfo.environment["STORAGE_MONITOR_KEEP_TEST_FIXTURES"] == "1" {
        print("RETAINED self-test fixture: \(root.path)")
    } else {
        try? FileManager.default.removeItem(at: root)
    }
}
