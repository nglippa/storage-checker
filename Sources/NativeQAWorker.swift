import Foundation
import Darwin

/// Development-only entry into the existing worker. No launchd, production configuration or default root.
func runNativeQAWorker(arguments: [String]) async throws {
    guard let runtime = try NativeQARuntime.bootstrap(arguments: arguments, bundle: nil, worker: true),
          let executable = Bundle.main.executableURL?.path, try NativeQARuntime.canonical(executable) == runtime.helper,
          let index = arguments.firstIndex(of: "--qa-owner-pid"), arguments.count > index + 1,
          let owner = Int32(arguments[index + 1]), owner > 1, owner == getppid(),
          try NativeQARuntime.hash(runtime.helper) == runtime.profile.helperSHA256 else { try NativeQARuntime.reject("worker identity or direct owner does not match") }
    let began = DispatchTime.now().uptimeNanoseconds
    let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    watchdog.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
    watchdog.setEventHandler {
        // Abrupt owner death cannot leave a persistent worker. Even a stalled invocation is capped.
        if getppid() != owner || kill(owner, 0) != 0 || DispatchTime.now().uptimeNanoseconds - began > 5_000_000_000 { _exit(79) }
    }
    watchdog.resume(); defer { watchdog.cancel() }
    try await inventoryCommand("inventory-work", args: ["inventory-work", "--root", runtime.fixtures, "--budget", "0.25", "--batch", "32"], directory: URL(fileURLWithPath: runtime.support))
}
