import Foundation
import Combine
import AppKit
import CoreFoundation
import SQLite3
import Darwin

/// Called by the executable entry point, before constructing the SwiftUI App or any StateObject.
enum NativeQABootstrap {
    static var session: NativeQASessionLock?
    static func prepare() throws -> NativeQARuntime? {
        let runtime = try NativeQARuntime.bootstrap(arguments: CommandLine.arguments, bundle: Bundle.main.bundleIdentifier)
        guard let runtime else { return nil }
        session = try NativeQASessionLock(runtime)
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false, "NSRecentDocumentsLimit": 0])
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
        return runtime
    }
    static func redirectLogs(_ runtime: NativeQARuntime) throws {
        let output = try runtime.openLog("viewer.log")
        dup2(output.fileDescriptor, STDOUT_FILENO); dup2(output.fileDescriptor, STDERR_FILENO)
        try output.close()
        let metadata: [String: Any] = ["qa_runtime": runtime.destinations(), "pid": getpid(), "qa_bundle_domain": Bundle.main.bundleIdentifier ?? "unknown"]
        let line = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: line + Data([10]))
    }
    static func verifyOnly(_ runtime: NativeQARuntime) throws {
        guard Bundle.main.bundleIdentifier == NativeQARuntime.bundleIdentifier else { try NativeQARuntime.reject("wrong preference application domain") }
        let key = "nativeQA.bootstrap.probe", value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        guard UserDefaults.standard.synchronize(),
              let saved = CFPreferencesCopyAppValue(key as CFString, NativeQARuntime.bundleIdentifier as CFString) as? String, saved == value else { try NativeQARuntime.reject("QA preference domain readback failed") }
        UserDefaults.standard.removeObject(forKey: key); _ = UserDefaults.standard.synchronize()
        guard NSWindow.instancesRespond(to: #selector(NSWindow.disableSnapshotRestoration)), NSApplication.instancesRespond(to: #selector(NSApplication.disableRelaunchOnLogin)) else { try NativeQARuntime.reject("required AppKit restoration controls unavailable") }
        guard NSApp == nil else { try NativeQARuntime.reject("headless bootstrap unexpectedly initialized NSApplication") }
        _ = try InventoryRequests.enqueue(database: runtime.database, action: "refresh", path: runtime.fixtures)
        let probe = URL(fileURLWithPath: runtime.temporary).appendingPathComponent("bootstrap-temp-" + UUID().uuidString)
        try Data("contained temporary probe".utf8).write(to: probe)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(runtime.database, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(connection); try NativeQARuntime.reject("QA catalog unavailable") }
        defer { sqlite3_close(connection) }
        var proposedTemp: UnsafeMutablePointer<CChar>?
        guard sqlite3_file_control(connection, "main", SQLITE_FCNTL_TEMPFILENAME, &proposedTemp) == SQLITE_OK, let proposedTemp else { try NativeQARuntime.reject("SQLite VFS temporary filename unavailable") }
        let vfsTemporaryPath = String(cString: proposedTemp); sqlite3_free(proposedTemp)
        guard vfsTemporaryPath.hasPrefix(runtime.temporary + "/") else { try NativeQARuntime.reject("SQLite VFS temporary filename escapes QA root") }
        guard sqlite3_exec(connection, "CREATE TABLE IF NOT EXISTS native_qa_probe(value TEXT); BEGIN IMMEDIATE; INSERT INTO native_qa_probe VALUES('isolated');", nil, nil, nil) == SQLITE_OK else { try NativeQARuntime.reject("QA transaction probe failed") }
        try runtime.validateStorage() // Includes any DELETE journal created by the real SQLite transaction.
        guard sqlite3_exec(connection, "ROLLBACK;", nil, nil, nil) == SQLITE_OK else { try NativeQARuntime.reject("QA transaction rollback failed") }
        var result: [String: Any] = ["status": "VERIFIED HEADLESS BOOTSTRAP ONLY", "destinations": runtime.destinations(), "bundle_identifier": Bundle.main.bundleIdentifier!, "foundation_temporary_directory": FileManager.default.temporaryDirectory.path, "qa_preference_readback": true, "sqlite_transaction_sidecar_containment": true, "sqlite_vfs_temporary_filename": vfsTemporaryPath, "nsapplication_initialized": false, "native_window_launched": false]
        result["os_managed_exceptions"] = ["~/Library/Preferences/" + NativeQARuntime.bundleIdentifier + ".plist (CFPreferences daemon)", "~/Library/Caches/" + NativeQARuntime.bundleIdentifier + " (framework-managed only; application URL cache disabled)", "OS framework per-user temporary directory: " + FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + " (TMPDIR does not redirect Foundation here; app-controlled state never uses this API)", "FileManager-managed Trash for explicitly confirmed registered fixtures only"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}

/// Nonpersistent, bounded invocations of the existing inventory worker, owned by this viewer.
final class NativeQAWorker: ObservableObject, @unchecked Sendable {
    @Published private(set) var failure: String?
    static let shared = NativeQAWorker()
    private let lock = NSLock()
    private var child: Process?
    private var loop: Task<Void, Never>?
    private var stopped = true
    private var generation: UInt64 = 0
    func start(_ runtime: NativeQARuntime) {
        lock.lock(); defer { lock.unlock() }
        guard stopped else { return }
        stopped = false; generation &+= 1; let epoch = generation
        DispatchQueue.main.async { self.failure = nil }
        loop = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try self.runOne(runtime, epoch: epoch) }
                catch {
                    let message = String(describing: error)
                    DispatchQueue.main.async { self.failure = message }
                    let data = Data(("QA worker stopped: \(error)\n").utf8)
                    if let handle = try? runtime.openLog("worker-errors.log") { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close() }
                    return
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func runOne(_ runtime: NativeQARuntime, epoch: UInt64) throws {
        try runtime.validateStorage()
        guard try NativeQARuntime.hash(runtime.helper) == runtime.profile.helperSHA256 else { try NativeQARuntime.reject("worker changed before spawn") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.helper)
        process.arguments = ["inventory-work", "--qa-runtime-root", runtime.root, "--qa-owner-pid", String(getpid())]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": runtime.temporary + "/", "SQLITE_TMPDIR": runtime.temporary]
        let output = try runtime.openLog("worker.log"); try output.seekToEnd()
        process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        lock.lock()
        guard !stopped, generation == epoch, !Task.isCancelled else { lock.unlock(); try output.close(); return }
        do { try process.run(); child = process; lock.unlock() }
        catch { lock.unlock(); try? output.close(); throw error }
        process.waitUntilExit(); try output.close()
        lock.lock(); if child === process { child = nil }; lock.unlock()
        lock.lock(); let inactive = stopped || generation != epoch; lock.unlock()
        guard [0,75].contains(process.terminationStatus) || inactive else { try NativeQARuntime.reject("fixture worker exited \(process.terminationStatus)") }
    }
    func stopAndWait() {
        lock.lock(); stopped = true; generation &+= 1; loop?.cancel(); loop = nil; let process = child
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
        if let process {
            let until = Date().addingTimeInterval(1)
            while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) } // Only our still-owned child.
            process.waitUntilExit()
        }
    }
}
