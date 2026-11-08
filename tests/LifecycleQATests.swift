import Foundation
import Darwin

@main struct LifecycleQATests {
    @MainActor static func main() async throws {
        var count = 0
        func test(_ value: Bool, _ message: String) throws { try required(value, "FAIL " + message); count += 1; print("PASS " + message) }
        func refuses(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let parent = "/private/tmp/storage-monitor-lifecycle-model-" + UUID().uuidString
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: parent) }
        func fixture() throws -> LifecycleQAScope {
            let root = parent + "/" + UUID().uuidString
            for relative in ["", "home/Applications", "home/Library/Application Support/MacBook Storage Monitor", "home/Library/LaunchAgents", "fixtures/folder", "Logs", "Temporary", "Bundles"] {
                try fm.createDirectory(atPath: root + (relative.isEmpty ? "" : "/" + relative), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try Data("Disposable fixture\n".utf8).write(to: URL(fileURLWithPath: root + "/fixtures/folder/item.txt"))
            var images = [String: LifecycleQAScope.Image]()
            for role in ["V1", "V2", "Installer"] {
                let build = role == "V1" ? "1" : "2", app = URL(fileURLWithPath: root + "/Bundles/" + role + ".app")
                try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let exe = app.appendingPathComponent("Contents/MacOS/StorageMonitor")
                try Data("#!/bin/sh\n# fixture image \(build)\nprintf '%s\\n' \"$@\"\n".utf8).write(to: exe); chmod(exe.path, 0o700)
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": LifecycleQAScope.helperIdentifier, "CFBundleShortVersionString": "0.0.0", "CFBundleVersion": build], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
                images[role] = .init(sha256: try NativeQARuntime.hash(exe.path), version: "0.0.0", build: build)
            }
            let identity = try NativeQARuntime.info(root), now = Date().timeIntervalSince1970
            let profile = LifecycleQAScope.Profile(version: 1, session: UUID().uuidString.lowercased(), uid: getuid(), device: Int64(identity.st_dev), inode: UInt64(identity.st_ino), createdAt: now, expiresAt: now + 1200, images: images)
            try JSONEncoder().encode(profile).write(to: URL(fileURLWithPath: root + "/profile.json")); chmod(root + "/profile.json", 0o600)
            return try LifecycleQAScope.load(root: root, expected: root)
        }
        let scope = try fixture(), layout = MonitorInstallLayout(home: scope.home, qa: scope)
        try test(scope.labels.count == 1 && Set(scope.labels).isDisjoint(with: Set([label, baselineLabel, inventoryLabel])), "the QA scope has one UUID label (the supervisor) that never overlaps a production label")
        try test(layout.legacyLabels.isEmpty && layout.agents.count == 1, "the QA layout registers exactly one scoped agent and no legacy labels")
        try test(refuses { _ = try LifecycleQAScope.load(root: scope.root, expected: scope.root + "-other") }, "private location cannot bypass exact baked-root match")
        try test(refuses { _ = try LifecycleQAScope.load(root: scope.root + "/.", expected: scope.root + "/.") }, "lexical root alias rejected")
        try test(refuses { try LifecycleQAScope.validateEnvironment(["HOME": "/private/tmp/fake-home"]) }, "fake HOME is not a scope")
        try test(refuses { try LifecycleQAScope.validateEnvironment(["DYLD_INSERT_LIBRARIES": "fake"]) }, "loader override rejected")
        try test(refuses { try LifecycleQAScope.validateEnvironment(["STORAGE_MONITOR_UNRESTRICTED": "1"]) }, "environment-only unrestricted override rejected")
        try test(refuses { try scope.validateCurrentImage(installerOnly: true) }, "unadmitted process image cannot run installer")
        for agent in layout.agents {
            try test(agent.plist["ProgramArguments"] as? [String] == scope.workerArguments(command: "supervise"), "supervise plist contains exact scope, root and data")
            try test(agent.label == scope.labels[0] && agent.url.path.hasPrefix(scope.root + "/") && agent.plist["KeepAlive"] as? Bool == true, "supervisor label and plist stay private")
        }
        try test(["check", "initialize-baseline", "inventory-work"].allSatisfy { scope.workerArguments(command: $0).contains(scope.root) && scope.workerArguments(command: $0).contains(scope.data.path) },
                 "the supervisor's child commands carry the exact scope, fixture root and data directory")
        var calls = [[String]]()
        let control: LaunchControl = { args, _ in calls.append(args) }
        _ = try install(layout: layout, source: scope.bundle("V1"), control: control)
        try test(try NativeQARuntime.hash(scope.executable) == scope.profile.images["V1"]!.sha256, "V1 fixture executable installed by same transaction engine")
        let db = try Database(scope.database)
        try db.write("INSERT INTO readings(timestamp,container,free,used,volumes) VALUES(1,'fixture-sentinel',2,3,'[]')")
        var setup = MonitoringSetupStatus.evaluate(home: scope.home, bundledHelper: scope.bundle("Installer"), launchd: .init(loaded: Set(scope.labels), disabled: []), labels: scope.labels)
        try test(setup.state == .needsUpdate && setup.jobLabels == MonitoringSetupStatus.roleLabels(for: scope.labels[0]) && setup.helperExecutable?.path == scope.installer.path, "existing status engine detects V1/V2 fixture update and stable installer")
        try test(wakeSupervisor(.inventory, directory: scope.data, layout: layout) && fm.fileExists(atPath: SupervisorWakes.file(data: scope.data, role: .inventory).path)
                 && !fm.fileExists(atPath: SupervisorWakes.file(data: defaultData, role: .inventory).path), "periodic inventory wake is a request file inside the scoped data directory")
        try test(!wakeSupervisor(.inventory, directory: defaultData, layout: layout), "QA installation never wakes worker for production data")
        let safe = layout.guardedControl(control)
        try test(refuses { try safe(["bootout", "gui/\(getuid())/\(label)"], true) }, "control rejects production label")
        try test(refuses { try safe(["kickstart", "gui/\(getuid())/local.macbook.storage-monitor.inventory-qa"], false) }, "control rejects legacy QA label")
        try test(refuses { try safe(["bootstrap", "gui/\(getuid())", agentURL.path], false) }, "control rejects production plist")
        for (key, value) in [("Program", "/bin/false" as Any), ("EnvironmentVariables", ["DYLD_INSERT_LIBRARIES": "/outside"] as Any), ("StandardOutPath", "/private/tmp/outside.log" as Any), ("WatchPaths", ["/Users"] as Any)] {
            var forged = layout.agents[0].plist; forged[key] = value
            try PropertyListSerialization.data(fromPropertyList: forged, format: .xml, options: 0).write(to: layout.agents[0].url)
            calls.removeAll()
            try test(refuses { try safe(["bootstrap", "gui/\(getuid())", layout.agents[0].url.path], false) } && calls.isEmpty, "complete plist rejects forged \(key) before launchctl")
            try PropertyListSerialization.data(fromPropertyList: layout.agents[0].plist, format: .xml, options: 0).write(to: layout.agents[0].url)
        }
        do { _ = try install(layout: layout, source: scope.bundle("V2"), control: control, fault: { if $0 == .swapped { throw Failure("injected") } }) }
        catch { try test(String(describing: error).contains("restored"), "pre-registration failure reports rollback") }
        try test(try NativeQARuntime.hash(scope.executable) == scope.profile.images["V1"]!.sha256, "rollback restores admitted V1 executable")
        try test(try Database(scope.database).rows("SELECT container FROM readings").first?["container"] == "fixture-sentinel", "rollback preserves private history")
        _ = try install(layout: layout, source: scope.bundle("V2"), control: control)
        setup = MonitoringSetupStatus.evaluate(home: scope.home, bundledHelper: scope.bundle("Installer"), launchd: .init(loaded: Set(scope.labels), disabled: []), labels: scope.labels)
        try test(setup.state == .on, "same status engine reports current fixture version installed")
        var health = MonitoringHealthEvidence()
        let failure = LaunchdState(loaded: Set(scope.labels), disabled: [], jobs: [MonitoringSetupStatus.roleLabels(for: scope.labels[0])[2]: .init(pid: nil, lastExitStatus: 79)])
        setup.launchd = failure; health.observe(failure, at: Date(), labels: setup.jobLabels)
        try test(MonitoringHealthPresentation(setup: setup, lastSuccess: nil, evidence: health, now: Date()).state == .failed, "health reads the scoped supervisor workers")
        LifecycleQAScope.active = scope
        let externalBase = URL(fileURLWithPath: parent + "/external-refused")
        let external = ExternalVolumeControl(baseDirectory: externalBase)
        let externalUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        try test(refuses { try externalVolumeCommand("external-list", args: ["external-list"], directory: externalBase) }, "lifecycle scope refuses external-volume commands")
        try test(refuses { _ = try external.enroll(uuid: externalUUID) }, "lifecycle scope refuses external enrollment")
        try test(refuses { try external.disable(uuid: externalUUID) }, "lifecycle scope refuses external settings changes")
        try test(refuses { _ = try external.request(uuid: externalUUID, action: "refresh") }, "lifecycle scope refuses external inventory requests")
        try test(refuses { try external.signal() } && !fm.fileExists(atPath: externalBase.path), "lifecycle scope refuses external wakes before creating files")
        LifecycleQAScope.active = nil
        let deniedNotification = await MonitoringSetupAction.notifications.run(helper: scope.installer, scope: scope)
        try test(!deniedNotification.ok, "lifecycle runner rejects notification authorization")
        let action = await MonitoringSetupAction.enable.run(helper: scope.installer, scope: scope)
        try test(action.ok && action.output.contains(LifecycleQAScope.flag) && action.output.contains(scope.root), "existing action runner passes explicit typed scope to stable helper")
        let dataBefore = try Data(contentsOf: URL(fileURLWithPath: scope.database))
        _ = try lifecycleQAStatus(scope)
        try test(try Data(contentsOf: URL(fileURLWithPath: scope.database)) == dataBefore, "scoped status performs no migration, retention or history write")
        let evidence = collectIntervalEvidence(db: db, readingId: 2, readingTime: Date().timeIntervalSince1970, previous: nil, marker: currentEventMarker(scope.fixtures), roots: [.init(path: scope.fixtures, label: "fixtures")], within: scope.root, includeProcesses: false)
        try test((evidence["processes"] as? [String: Any])?["sampled"] as? Int == 0 && (try db.rows("SELECT value FROM state WHERE key='attribution_processes'")).isEmpty, "fixture check suppresses process sampling and process baseline writes")
        _ = try uninstall(layout: layout, control: control)
        try test(layout.agents.allSatisfy { !fm.fileExists(atPath: $0.url.path) } && fm.fileExists(atPath: scope.database), "disable removes only own agents and retains history")

        let expiredOriginal = try fixture(), originalLayout = MonitorInstallLayout(home: expiredOriginal.home, qa: expiredOriginal)
        _ = try install(layout: originalLayout, source: expiredOriginal.bundle("V1"), control: control)
        do { _ = try install(layout: originalLayout, source: expiredOriginal.bundle("V2"), control: control, fault: { if $0 == .migrated { throw Failure("abandoned journal") } }, rollbackOnFailure: false) } catch {}
        let profileURL = URL(fileURLWithPath: expiredOriginal.root + "/profile.json")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: profileURL)) as! [String: Any]
        raw["createdAt"] = Date().timeIntervalSince1970 - 100; raw["expiresAt"] = Date().timeIntervalSince1970 - 1
        try JSONSerialization.data(withJSONObject: raw).write(to: profileURL)
        let expired = try LifecycleQAScope.load(root: expiredOriginal.root, expected: expiredOriginal.root)
        try test(refuses { try expired.admit(command: "install") } && refuses { try expired.admit(command: "check") }, "expired profile rejects install and workers")
        LifecycleQAScope.active = expired
        try test(refuses { _ = try InventoryRequests.enqueue(database: expired.database, action: "refresh", path: expired.fixtures) }, "expired viewer cannot write inventory mailbox")
        LifecycleQAScope.active = nil
        try test(refuses { try scope.validateRequest(database: defaultData.appendingPathComponent("history.sqlite3").path, path: scope.fixtures) }, "request refuses production catalog")
        try test(refuses { try scope.validateRequest(database: scope.database, path: scope.fixtures + "/../home") }, "request refuses fixture traversal")
        try expired.admit(command: "status"); try expired.admit(command: "uninstall")
        calls.removeAll()
        _ = try uninstall(layout: .init(home: expired.home, qa: expired), control: control)
        try test(!calls.isEmpty && calls.allSatisfy { $0.first == "bootout" }, "expired interrupted uninstall never enables, bootstraps or kickstarts saved jobs")
        try test(!fm.fileExists(atPath: originalLayout.transaction.path) && originalLayout.agents.allSatisfy { !fm.fileExists(atPath: $0.url.path) }, "expired cleanup recovers journal and removes all own agents")

        let escaped = try fixture(), escapedLayout = MonitorInstallLayout(home: escaped.home, qa: escaped)
        _ = try install(layout: escapedLayout, source: escaped.bundle("V1"), control: control)
        do { _ = try install(layout: escapedLayout, source: escaped.bundle("V2"), control: control, fault: { if $0 == .swapped { throw Failure("interrupted") } }, rollbackOnFailure: false) } catch {}
        var journal = try JSONDecoder().decode(InstallJournal.self, from: Data(contentsOf: escapedLayout.journal))
        journal.savedAgents["agent-0.plist"] = agentURL.path
        try JSONEncoder().encode(journal).write(to: escapedLayout.journal)
        calls.removeAll()
        try test(refuses { _ = try uninstall(layout: escapedLayout, control: control) } && calls.isEmpty, "escaped recovery target rejected before launchctl or file restoration")
        let linked = try fixture()
        try fm.createSymbolicLink(atPath: linked.data.appendingPathComponent("history.sqlite3-journal").path, withDestinationPath: defaultData.path)
        try test(refuses { try linked.validateStorage() }, "symlinked operational sidecar rejected")
        let hardlinked = try fixture()
        try fm.linkItem(atPath: hardlinked.fixtures + "/folder/item.txt", toPath: hardlinked.root + "/hardlink")
        try test(refuses { try hardlinked.validateStorage() }, "hard-linked fixture rejected")
        let swapped = try fixture()
        try Data("substituted executable".utf8).write(to: swapped.bundle("V2").appendingPathComponent("Contents/MacOS/StorageMonitor"))
        try test(refuses { _ = try LifecycleQAScope.load(root: swapped.root, expected: swapped.root) }, "source-image substitution fails immutable profile pin")
        let switched = try fixture(), switchedLayout = MonitorInstallLayout(home: switched.home, qa: switched)
        try fm.removeItem(at: switched.bundle("V1"))
        try fm.copyItem(at: switched.bundle("V2"), to: switched.bundle("V1"))
        calls.removeAll()
        try test(refuses { _ = try install(layout: switchedLayout, source: switched.bundle("V1"), control: control) } && calls.isEmpty, "source role cannot be swapped for another admitted image before transaction")
        try test(try await runLifecycleQACommand(arguments: ["test", "help"]) == false, "normal production dispatch remains independent when no QA flag supplied")
        do { _ = try await runLifecycleQACommand(arguments: ["test", "install", "--lifecycle-qa-unrestricted"]) }
        catch { try test(true, "malformed lifecycle request rejects before production fallback") }
        print("\(count) lifecycle QA model/safety checks passed; no real launchctl or GUI executed")
    }
}
