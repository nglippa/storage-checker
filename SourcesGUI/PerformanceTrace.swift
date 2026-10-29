import Foundation
import os

/// Navigation timing. Signposts are always emitted (visible in Instruments under Points of Interest, free when no
/// tool records them). QA viewers launched with `--perf-log <absolute path>` also append one line per mark to that
/// file, and record every main-thread run-loop pass longer than 50 ms, so a native session can be measured from
/// inside the process instead of from screenshots.
@MainActor enum PerformanceTrace {
    private static let signposter = OSSignposter(subsystem: "local.macbook.storage-monitor.viewer", category: .pointsOfInterest)
    private static let started = ProcessInfo.processInfo.systemUptime
    private static var output: FileHandle? = {
        let args = CommandLine.arguments
        guard ViewerConfiguration.current.isQA, let i = args.firstIndex(of: "--perf-log"), args.count > i + 1, args[i + 1].hasPrefix("/") else { return nil }
        let path = args[i + 1]
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    static var isLogging: Bool { output != nil }
    /// The latest navigation mark, so the run-loop observer can report when its first frame was committed.
    private static var pendingFrame: (name: String, at: Double)?
    private static var passStarted: Double?
    private static var observer: CFRunLoopObserver?

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// A point event. `frame: true` also reports when the run-loop pass that handles it ends (the first frame).
    static func mark(_ name: StaticString, _ detail: @autoclosure () -> String = "", frame: Bool = false) {
        signposter.emitEvent(name)
        guard output != nil else { return }
        let text = detail()
        write("\(name)\(text.isEmpty ? "" : " " + text)")
        if frame { pendingFrame = ("\(name)", now()) }
    }

    /// Times `body` as a signpost interval and, when logging, one line with its duration.
    static func measure<T>(_ name: StaticString, _ detail: @autoclosure () -> String = "", _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = now()
        defer {
            signposter.endInterval(name, state)
            if output != nil { write(String(format: "%@ %.1fms %@", "\(name)", (now() - start) * 1000, detail())) }
        }
        return try await body()
    }

    static func startStallMonitor() {
        guard output != nil, observer == nil else { return }
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            MainActor.assumeIsolated {
                let time = now()
                if activity == .afterWaiting { passStarted = time; return }
                if let started = passStarted, time - started > 0.05 { write(String(format: "main.stall %.0fms", (time - started) * 1000)) }
                passStarted = nil
                if let pending = pendingFrame { pendingFrame = nil; write(String(format: "frame.committed %@ +%.0fms", pending.name, (time - pending.at) * 1000)) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func write(_ line: String) {
        guard let output else { return }
        output.write(Data(String(format: "%.4f %@\n", now() - started, line).utf8))
    }
}
