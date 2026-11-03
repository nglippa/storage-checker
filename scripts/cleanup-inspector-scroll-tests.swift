import AppKit
import SwiftUI

private struct ScrollRegressionError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func settle(_ host: NSView, seconds: Double) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func allScrollViews(in view: NSView) -> [NSScrollView] {
    let own = (view as? NSScrollView).map { [$0] } ?? []
    return own + view.subviews.flatMap { allScrollViews(in: $0) }
}

private func node(at url: URL, id: Int64, allocatedBytes: Int64? = nil) throws -> InventoryNode {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw ScrollRegressionError(description: "fixture metadata unavailable: \(url.path)")
    }
    return InventoryNode(
        id: id,
        parentID: 0,
        identity: InventoryIdentity(
            device: Int64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            birthNanoseconds: Int64(metadata.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_birthtimespec.tv_nsec),
            volumeUUID: nil
        ),
        path: url.path,
        name: url.lastPathComponent,
        kind: metadata.st_mode & S_IFMT == S_IFDIR ? .directory : .file,
        logicalBytes: Int64(metadata.st_size),
        allocatedBytes: allocatedBytes ?? Int64(metadata.st_blocks) * 512,
        previousLogicalBytes: nil,
        previousAllocatedBytes: nil,
        objectLogicalBytes: nil,
        objectAllocatedBytes: nil,
        directLogicalBytes: 0,
        directAllocatedBytes: 0,
        childCount: 0,
        descendantFiles: 4,
        descendantDirectories: 1,
        status: .complete,
        coverageState: "complete",
        listingState: nil,
        statusReason: nil,
        measuredAt: Date(),
        modifiedAt: nil,
        generation: 1,
        isHardlinkAlias: false,
        historicalGrowthBytes: nil
    )
}

@main
private struct CleanupInspectorScrollTests {
    @MainActor
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)

        var failures = [String]()
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() { print("PASS \(message)") }
            else { failures.append(message); print("FAIL \(message)") }
        }

        do {
            guard CommandLine.arguments.count == 2 else {
                throw ScrollRegressionError(description: "usage: cleanup-inspector-scroll-tests /private/tmp/work")
            }
            let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let home = work.appendingPathComponent("home", isDirectory: true)
            let dependencies = home.appendingPathComponent("project/node_modules", isDirectory: true)
            let otherDependencies = home.appendingPathComponent("other/node_modules", isDirectory: true)
            let manager = FileManager.default
            try manager.createDirectory(at: dependencies.appendingPathComponent("package", isDirectory: true), withIntermediateDirectories: true)
            try manager.createDirectory(at: otherDependencies, withIntermediateDirectories: true)
            try Data("{\"name\":\"fixture\"}".utf8).write(to: home.appendingPathComponent("project/package.json"))
            try Data("{}".utf8).write(to: home.appendingPathComponent("project/package-lock.json"))
            try Data("{}".utf8).write(to: dependencies.appendingPathComponent(".package-lock.json"))
            try Data(String(repeating: "fixture", count: 2_000).utf8).write(to: dependencies.appendingPathComponent("package/index.js"))
            try Data("{}".utf8).write(to: otherDependencies.appendingPathComponent(".package-lock.json"))
            try Data("{\"name\":\"other-fixture\"}".utf8).write(to: home.appendingPathComponent("other/package.json"))
            try Data("{}".utf8).write(to: home.appendingPathComponent("other/package-lock.json"))

            let subject = try node(at: dependencies, id: 101)
            let other = try node(at: otherDependencies, id: 202)
            let environment = ArtifactEnvironment(
                home: home.path,
                pathDirectories: [],
                processes: { ProcessObservation(executables: [], workingDirectories: [], inspected: 10, unreadable: 0) },
                git: nil
            )
            let inspection = ArtifactInspector.inspect(subject, environment: environment)
            guard inspection.classification != nil, inspection.assessment?.status == .reviewCandidate else {
                throw ScrollRegressionError(description: "synthetic node_modules fixture did not produce a review candidate")
            }

            let browser = InventoryBrowserModel(database: work.appendingPathComponent("unused-catalog.sqlite3").path, readiness: ViewerReadiness(output: nil))
            let cleanup = browser.cleanup
            cleanup.beginQueueReview(subject)
            cleanup.acceptQueueReview(inspection, node: subject)
            guard let previewTask = cleanup.loadPreview(subject) else {
                throw ScrollRegressionError(description: "review candidate did not offer a cleanup preview")
            }
            await previewTask.value
            guard cleanup.preview != nil else {
                throw ScrollRegressionError(description: "cleanup preview did not finish for the synthetic fixture")
            }

            let root = InventoryInspectorView(
                browser: browser,
                explorer: browser.explorer,
                reviewSubject: subject,
                showsTrash: false,
                usesQueueEvidence: true
            )
            .frame(width: 390, height: 520)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 390, height: 520)
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 390, height: 520),
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            await settle(host, seconds: 0.6)

            guard let scroll = allScrollViews(in: host).max(by: {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            }) else {
                throw ScrollRegressionError(description: "real Inspector produced no NSScrollView")
            }
            let initialDocumentHeight = scroll.documentView?.frame.height ?? 0
            let viewportHeight = scroll.contentView.bounds.height
            let maximumOffset = initialDocumentHeight - viewportHeight
            guard maximumOffset > 100 else {
                throw ScrollRegressionError(description: "Inspector document underfilled: document=\(initialDocumentHeight), viewport=\(viewportHeight), max=\(maximumOffset)")
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            await settle(host, seconds: 0.2)
            let before = scroll.contentView.bounds.origin.y
            guard before > 100 else {
                throw ScrollRegressionError(description: "Inspector could not establish a deep offset: \(before)")
            }

            var idleMinimum = before
            let idleDeadline = Date().addingTimeInterval(0.35)
            while Date() < idleDeadline {
                host.layoutSubtreeIfNeeded()
                idleMinimum = min(idleMinimum, scroll.contentView.bounds.origin.y)
                try? await Task.sleep(for: .milliseconds(10))
            }
            check(idleMinimum >= before - 2, "idle Inspector preserves a deep scroll offset")

            cleanup.beginQueueReview(subject)
            var minimum = scroll.contentView.bounds.origin.y
            var minimumDocumentHeight = initialDocumentHeight
            let examiningDeadline = Date().addingTimeInterval(0.35)
            while Date() < examiningDeadline {
                host.layoutSubtreeIfNeeded()
                minimum = min(minimum, scroll.contentView.bounds.origin.y)
                minimumDocumentHeight = min(minimumDocumentHeight, scroll.documentView?.frame.height ?? 0)
                try? await Task.sleep(for: .milliseconds(10))
            }
            let previewSurvivedBegin = cleanup.preview != nil
            cleanup.acceptQueueReview(inspection, node: subject)
            let acceptedDeadline = Date().addingTimeInterval(0.35)
            while Date() < acceptedDeadline {
                host.layoutSubtreeIfNeeded()
                minimum = min(minimum, scroll.contentView.bounds.origin.y)
                minimumDocumentHeight = min(minimumDocumentHeight, scroll.documentView?.frame.height ?? 0)
                try? await Task.sleep(for: .milliseconds(10))
            }
            let after = scroll.contentView.bounds.origin.y
            print(String(format: "same-node: offset before %.1f, minimum %.1f, after %.1f; document initial %.1f, minimum %.1f", before, minimum, after, initialDocumentHeight, minimumDocumentHeight))
            check(minimum >= before - 2, "same-node queue revalidation never collapses or clamps a deep Inspector offset")
            check(minimumDocumentHeight >= initialDocumentHeight - 2, "same-node queue revalidation keeps the Inspector document height stable")
            check(previewSurvivedBegin && cleanup.preview != nil, "same-node queue revalidation preserves the open cleanup preview")

            let remeasured = try node(at: dependencies, id: subject.id, allocatedBytes: 8_192)
            cleanup.beginQueueReview(subject)
            cleanup.acceptQueueReview(inspection, node: remeasured)
            await settle(host, seconds: 0.35)
            check(cleanup.preview?.indexedBytes == 8_192,
                  "a completed queue refresh rebuilds the preview from its returned row measurement")

            let replacement = try node(at: otherDependencies, id: subject.id)
            let replacementInspection = ArtifactInspector.inspect(replacement, environment: environment)
            guard replacementInspection.assessment?.status == .reviewCandidate else {
                throw ScrollRegressionError(description: "replacement fixture did not produce a review candidate")
            }
            cleanup.beginQueueReview(subject)
            cleanup.acceptQueueReview(replacementInspection, node: replacement)
            check(cleanup.preview == nil,
                  "an object replacement discovered during refresh closes the old object's preview")

            cleanup.beginQueueReview(subject)
            cleanup.acceptQueueReview(inspection, node: subject)
            await cleanup.loadPreview(subject)?.value
            cleanup.beginQueueReview(subject)
            cleanup.finishQueueReviewFailure()
            let failedReviewBlocked: Bool = {
                if case .blocked = cleanup.trashDecision(subject) { return true }
                return false
            }()
            check(cleanup.inspection == nil && cleanup.preview == nil && failedReviewBlocked,
                  "failed queue revalidation discards retained evidence and cannot offer Trash")

            cleanup.beginQueueReview(subject)
            cleanup.acceptQueueReview(inspection, node: subject)
            await cleanup.loadPreview(subject)?.value
            cleanup.beginQueueReview(replacement)
            check(cleanup.inspection == nil && cleanup.preview == nil && cleanup.inspecting == replacement.id,
                  "a replaced filesystem object with the same catalog ID clears stale evidence and preview")

            cleanup.beginQueueReview(subject)
            cleanup.acceptQueueReview(inspection, node: subject)
            await cleanup.loadPreview(subject)?.value
            cleanup.beginQueueReview(other)
            check(cleanup.inspection == nil && cleanup.preview == nil && cleanup.inspecting == other.id,
                  "a different queue selection clears stale evidence and preview")
            window.contentView = nil
        } catch {
            failures.append(String(describing: error))
            print("FAIL \(error)")
        }

        if failures.isEmpty {
            print("PASS cleanup Inspector scroll regression")
            exit(0)
        }
        print("FAILED \(failures.count) assertion(s)")
        for failure in failures { print(" - \(failure)") }
        exit(1)
    }
}
