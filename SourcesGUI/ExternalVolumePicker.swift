import SwiftUI

struct ExternalVolumePicker: View {
    @ObservedObject var store: ViewerStore
    @State private var managing = false
    var body: some View {
        HStack(spacing: 6) {
            Picker("Drive", selection: Binding(get: { store.target.uuid ?? "startup" }, set: { store.selectTarget($0 == "startup" ? nil : $0) })) {
                Text("Internal storage").tag("startup")
                ForEach(store.externalSettings.volumes.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { saved in
                    Text(displayName(saved) + (saved.enabled ? "" : " (disabled)")).tag(saved.volumeUUID)
                }
            }.pickerStyle(.menu).frame(maxWidth: 230).accessibilityIdentifier("storage.drive")
            Button { managing.toggle(); store.refreshTargets(); store.refreshExternalRuntimeStatus(force: true) } label: { Image(systemName: "externaldrive") }
                .help("Manage external drives").accessibilityLabel("Manage external drives").accessibilityIdentifier("storage.manageDrives")
                .popover(isPresented: $managing) { management }
        }
    }
    private var management: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("External drives").font(.headline)
            Text("Chosen drives resume automatically when they reconnect.")
                .font(.callout).foregroundStyle(.secondary)
            setupSteps
            if let error = store.externalError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.externalSettings.volumes.values.sorted { $0.name < $1.name }) { saved in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(saved.name).font(.body.weight(.medium))
                            Text(status(saved)).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("View") { store.selectTarget(saved.volumeUUID); managing = false }
                                Group {
                                if saved.enabled {
                                    Button(saved.indexingPaused ? "Resume indexing" : "Pause indexing") { store.externalControl(saved.indexingPaused ? "resume" : "pause", uuid: saved.volumeUUID) }
                                    Button("Disable") { store.externalControl("disable", uuid: saved.volumeUUID) }
                                } else { Button("Enable") { store.externalControl("enable", uuid: saved.volumeUUID) } }
                                if backingChanged(saved) { Button("Re-enroll changed drive") { store.externalControl("reenroll", uuid: saved.volumeUUID) } }
                                }.disabled(!store.externalSupportReady)
                            }.controlSize(.small)
                        }
                        Divider()
                    }
                    ForEach(unregistered, id: \.mountPath) { drive in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(drive.name).font(.body.weight(.medium))
                                Spacer()
                                Button("Enable monitoring & indexing") { if let uuid = try? drive.identity().uuid { store.externalControl("enable", uuid: uuid) } }
                                    .controlSize(.small).disabled(!store.externalSupportReady || reason(drive) != nil)
                            }
                            Text(reason(drive) ?? (drive.filesystem.uppercased() + " · connected, not monitored"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if store.externalSettings.volumes.isEmpty && unregistered.isEmpty {
                        Text("No external drives discovered. Connect an APFS, HFS+ or exFAT drive, then refresh.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxHeight: 360)
            HStack {
                Button("Refresh connected drives") { store.externalControl("discover") }.disabled(!store.externalSupportReady)
                Spacer(); Button("Done") { managing = false }
            }
            Text("Pause stops indexing only. Disable stops both indexing and capacity monitoring; saved data is kept.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 480)
    }
    /// The linking procedure as explicit, checkable steps, so a first-time user knows exactly what to do next.
    private var setupSteps: some View {
        let ready = store.externalSupportReady
        let connected = !(store.externalObservations?.descriptors ?? []).isEmpty
        let linked = store.externalSettings.volumes.values.contains { $0.enabled }
        return VStack(alignment: .leading, spacing: 8) {
            step(1, done: ready, "Turn on background monitoring",
                 ready ? "Background monitoring is running." : store.externalSupportMessage + " In Settings, click “Enable Background Monitoring…” (or “Update…” / “Repair…”) and approve the prompt. If macOS later asks, allow Storage Monitor in System Settings → General → Login Items.") {
                if !ready { SettingsLink { Text("Open Settings") }.controlSize(.small) }
            }
            step(2, done: connected, "Connect the drive",
                 connected ? "A drive is connected." : "Plug in an APFS, HFS+ or exFAT drive and wait for it to appear in Finder, then click “Refresh connected drives” below.") { EmptyView() }
            step(3, done: linked, "Link it",
                 linked ? "At least one drive is linked." : "Click “Enable monitoring & indexing” next to the drive in the list below. If macOS asks for access to removable volumes, click Allow.") { EmptyView() }
            step(4, done: linked && store.target.uuid != nil, "View it",
                 "Choose the drive from the Drive menu in the toolbar (or click “View” below). The first index can take a while on a large drive.") { EmptyView() }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain).accessibilityIdentifier("storage.driveSetupSteps")
    }
    private func step<Action: View>(_ number: Int, done: Bool, _ title: String, _ detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Step \(number), done" : "Step \(number)")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }
    private var unregistered: [ExternalVolumeDescriptor] {
        (store.externalObservations?.descriptors ?? []).filter { drive in
            guard let uuid = try? drive.identity().uuid else { return true }
            return store.externalSettings.volumes[uuid] == nil
        }.sorted { $0.name < $1.name }
    }
    private func reason(_ drive: ExternalVolumeDescriptor) -> String? {
        if let uuid = try? drive.identity().uuid,
           (store.externalObservations?.descriptors.filter { (try? $0.identity().uuid) == uuid }.count ?? 0) > 1 {
            return ExternalVolumeError.ambiguousIdentity.localizedDescription
        }
        return drive.eligibilityReason
    }
    private func backingChanged(_ saved: ExternalVolumeRegistration) -> Bool {
        guard let match = store.externalObservations?.descriptors.first(where: { (try? $0.identity().uuid) == saved.volumeUUID }),
              let backing = try? match.normalizedBacking() else { return false }
        return backing != saved.backingUUIDs || (try? match.capacityScope()) != saved.capacityScope
    }
    private func displayName(_ saved: ExternalVolumeRegistration) -> String {
        let matches = store.externalObservations?.descriptors.filter { (try? $0.identity().uuid) == saved.volumeUUID } ?? []
        return matches.count == 1 ? matches[0].name : saved.name
    }
    private func status(_ saved: ExternalVolumeRegistration) -> String {
        if !saved.enabled { return "Monitoring disabled · saved data retained" }
        if backingChanged(saved) { return "Backing identity changed · explicit re-enrollment required" }
        if store.externalObservations?.descriptors.contains(where: { (try? $0.identity().uuid) == saved.volumeUUID }) != true { return "Disconnected · saved catalog available" }
        return saved.indexingPaused ? "Indexing paused · capacity monitoring active" : "Monitoring & indexing enabled"
    }
}
