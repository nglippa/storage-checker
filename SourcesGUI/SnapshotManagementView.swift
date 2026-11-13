import SwiftUI

struct SnapshotManagementView: View {
    @ObservedObject var history: ViewerStore
    @StateObject private var model: SnapshotManagementModel
    @State private var showCreate = false
    @State private var showPolicy = false
    @State private var preview: SnapshotDeletionPreview?
    @State private var pending: SnapshotServiceRequest?
    @State private var confirmation = ""
    @State private var confirmOperation = false
    @State private var confirmEnable = false
    @State private var confirmDisable = false
    @State private var confirmTimeMachine = false
    @State private var selectedTab = "inventory"
    @FocusState private var searchFocused: Bool
    init(history: ViewerStore) { self.history = history; _model = StateObject(wrappedValue: SnapshotManagementModel(isQA: history.configuration.isQA)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Snapshot Management").font(.title2).bold()
                Spacer()
                Button("History & Monitoring") { history.section = "history" }
                Button("Reload", systemImage: "arrow.clockwise") { model.reload(); model.loadTimeMachineHistory() }.disabled(model.busy || model.tmBusy).keyboardShortcut("r")
            }
            HStack {
                Text("Request Time Machine snapshots or review per-volume recovery points.").foregroundStyle(.secondary)
                Spacer()
                Button("Request Time Machine Snapshot…") { confirmTimeMachine = true }
                    .disabled(model.tmBusy || model.isQA)
                    .accessibilityIdentifier("snapshots.timeMachine.request")
            }
            if model.tmBusy { ProgressView("Reading history or requesting a Time Machine snapshot…").controlSize(.small) }
            if let error = model.tmError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("snapshots.timeMachine.error") }
            HStack(alignment: .top) {
                Image(systemName: model.available ? "lock.shield" : "exclamationmark.shield")
                Text(model.serviceStatus).textSelection(.enabled).accessibilityIdentifier("snapshots.serviceStatus")
                Spacer()
                if model.available { Button("Disable Helper…") { confirmDisable = true }.disabled(model.busy) }
                else { Button("Enable Snapshot Helper…") { confirmEnable = true }.disabled(model.isQA || model.compatibility() != nil) }
            }.font(.callout)
            Divider()
            HStack {
                Picker("Volume", selection: $model.volumeID) {
                    if model.response.volumes.isEmpty { Text("No local APFS volumes available").tag("") }
                    ForEach(model.response.volumes) { volume in Text(volume.name + (volume.compatibilityIssue == nil ? "" : " — observation only")).tag(volume.id) }
                }.frame(maxWidth: 500).accessibilityIdentifier("snapshots.volume")
                Spacer()
                Button("Create Snapshot…", systemImage: "plus") { showCreate = true }.disabled(model.volume?.compatibilityIssue != nil || model.volume == nil || model.busy).keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Schedule & Retention…") { showPolicy = true }.disabled(model.volume == nil || model.busy)
            }
            if let volume = model.volume {
                Text("\(volume.id) · \(volume.mountPath.isEmpty ? "Not mounted" : volume.mountPath)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let issue = volume.compatibilityIssue { Label(issue, systemImage: "info.circle").font(.callout) }
            }
            if let issue = model.response.inventoryErrors[model.volumeID] { Text("Inventory unavailable: \(issue). No snapshot absence is inferred.").foregroundStyle(.secondary) }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("snapshots.error") }
            if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled).accessibilityIdentifier("snapshots.result") }
            if model.busy { ProgressView("Reading or managing snapshots…").controlSize(.small) }
            Picker("Snapshot section", selection: $selectedTab) {
                Text("Inventory & Details").tag("inventory")
                Text("Comparison").tag("comparison")
                Text("Activity History").tag("activity")
                Text("Time Machine Requests").tag("timeMachine")
            }.pickerStyle(.segmented).accessibilityIdentifier("snapshots.section")
            switch selectedTab {
            case "comparison": comparison
            case "activity": activity
            case "timeMachine": timeMachineHistory
            default: inventory
            }
        }
        .padding(20)
        .task { model.reload(); model.loadTimeMachineHistory() }
        .onChange(of: model.volumeID) { _, _ in model.selected = []; model.search = "" }
        .onChange(of: model.search) { _, _ in model.selected.formIntersection(Set(model.visibleInventory.map(\.id))) }
        .background(Button("Search Snapshots") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden())
        .sheet(isPresented: $showCreate) { SnapshotCreationSheet(model: model) }
        .sheet(isPresented: $showPolicy) { SnapshotPolicySheet(model: model) }
        .sheet(isPresented: $model.tmNeedsAcknowledgement) { SnapshotTimeMachineAcknowledgementSheet(model: model) }
        .sheet(item: $preview) { plan in
            VStack(alignment: .leading, spacing: 16) {
                Text("Review snapshot deletion").font(.title2).bold()
                Text("\(plan.records.count) managed recovery points will be permanently removed. Their restoration states will be lost. Shared APFS blocks mean no exact recovered-space amount is promised.")
                Text(plan.reason).foregroundStyle(.secondary)
                List(plan.records) { record in
                    VStack(alignment: .leading) { Text(record.label).bold(); Text(record.name); Text("UUID \(record.snapshotUUID)").font(.caption) }.textSelection(.enabled)
                }.frame(minHeight: 150, maxHeight: 300)
                Text("This one-use preview expires after two minutes. The helper rechecks ownership and protection before every deletion.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", role: .cancel) { preview = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Permanently Delete \(plan.records.count) Snapshots", role: .destructive) {
                        preview = nil
                        model.perform(.init(action: .deletePreview, volumeUUID: plan.volumeUUID, token: plan.id))
                    }.disabled(plan.records.isEmpty || !model.canMutate)
                }
            }.padding(24).frame(width: 640)
        }
        .confirmationDialog(confirmation, isPresented: $confirmOperation, titleVisibility: .visible) {
            Button("Continue") { if let pending { model.perform(pending) }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        }
        .confirmationDialog("Request a Time Machine local snapshot?", isPresented: $confirmTimeMachine, titleVisibility: .visible) {
            Button("Request Time Machine Snapshot") { selectedTab = "timeMachine"; model.requestTimeMachineSnapshot() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(timeMachineSnapshotScope) }
        .confirmationDialog("Enable the privileged snapshot helper?", isPresented: $confirmEnable, titleVisibility: .visible) {
            Button("Enable Helper") { model.enableService() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("macOS may require administrator approval in Login Items. The helper can manage only Storage Monitor-owned snapshots on supported volumes. All volume schedules remain disabled until explicitly configured.") }
        .confirmationDialog("Disable the snapshot helper?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Disable Helper") { model.disableService() }; Button("Cancel", role: .cancel) {}
        } message: { Text("Scheduled creation and retention will stop. Existing snapshots and their ownership records remain intact. Finish comparisons before disabling.") }
    }
    private var inventory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search snapshot name, label or UUID", text: $model.search).focused($searchFocused).textFieldStyle(.roundedBorder).accessibilityLabel("Search snapshots").accessibilityIdentifier("snapshots.search")
                Button("Compare Selected") { model.compareSelected() }.disabled(!model.canMutate || model.selected.count != 2 || model.selectedRecords.count != 2)
                Button("Preview Deletion…") {
                    model.perform(.init(action: .previewManual, volumeUUID: model.volumeID, snapshotIDs: model.selectedRecords.map(\.id))) { preview = $0.preview }
                }.disabled(!model.canMutate || model.selected.isEmpty || model.selectedRecords.count != model.selected.count)
                Button("Preview Retention…") { model.perform(.init(action: .previewRetention, volumeUUID: model.volumeID)) { preview = $0.preview } }.disabled(!model.canMutate)
            }
            Table(model.visibleInventory, selection: $model.selected) {
                TableColumn("Snapshot") { native in
                    VStack(alignment: .leading) {
                        Text(model.record(native)?.label ?? native.name).lineLimit(2)
                        Text(native.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.accessibilityElement(children: .combine)
                }.width(min: 260, ideal: 420)
                TableColumn("Ownership") { native in Text(model.record(native) == nil ? ((model.available || model.isQA) ? "Not managed here" : "Ownership unverified") : "Storage Monitor") }.width(min: 110, ideal: 150)
                TableColumn("Created") { native in
                    if let record = model.record(native) { Text(record.createdAt, format: .dateTime.year().month().day().hour().minute()) }
                    else { Text("Unknown") }
                }.width(min: 100, ideal: 160)
                TableColumn("Protection") { native in Text(model.record(native)?.protected == true ? "Protected" : model.record(native)?.excludedFromRetention == true ? "Retention excluded" : "—") }.width(min: 100, ideal: 150)
                TableColumn("Exclusive size") { _ in Text("Unknown") }.width(95)
            }.accessibilityLabel("Snapshot inventory").accessibilityIdentifier("snapshots.inventory")
            if model.inventory.isEmpty && !model.busy {
                Text(model.volume?.compatibilityIssue == nil ? "No snapshot entries are available for this volume. Check inventory status before interpreting this as absence." : "Management inventory is not queried for unsupported volumes. Use History & Monitoring for existing system snapshot evidence.").font(.callout).foregroundStyle(.secondary)
            }
            if let native = model.inventory.first(where: { model.selected.contains($0.id) }), model.selected.count == 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(native.name).font(.callout).textSelection(.enabled)
                    Text("XID: \(native.xid.map(String.init) ?? "Unknown") · Purgeable flag: \(native.purgeable.map { $0 ? "Yes" : "No" } ?? "Unknown") · Exact reclaimable storage: Unknown").font(.caption).foregroundStyle(.secondary)
                    if let record = model.record(native) {
                        HStack {
                            Button(record.protected ? "Unprotect…" : "Protect Snapshot") { ask(.init(action: .protect, volumeUUID: model.volumeID, snapshotIDs: [record.id], protected: !record.protected), title: record.protected ? "Allow this recovery point to become eligible for deletion?" : "Protect this recovery point from manual and automatic deletion?") }
                            Button(record.excludedFromRetention ? "Include in Retention…" : "Exclude from Retention") { ask(.init(action: .protect, volumeUUID: model.volumeID, snapshotIDs: [record.id], excluded: !record.excludedFromRetention), title: "Change this snapshot's automatic retention exclusion?") }
                        }.disabled(!model.canMutate)
                    } else { Text((model.available || model.isQA) ? "Time Machine, system and other snapshots cannot be adopted or deleted here." : "Ownership cannot be verified while the helper is unavailable. Native names alone never authorize adoption or deletion.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            let uncertain = model.records.filter { $0.state == .quarantined }
            if !uncertain.isEmpty {
                DisclosureGroup("Interrupted or uncertain operations (\(uncertain.count))") {
                    ForEach(uncertain) { record in
                        HStack { Text("\(record.label) · ownership quarantined"); Spacer(); Button("Review Recovery…") { ask(.init(action: .recover, volumeUUID: model.volumeID, snapshotIDs: [record.id]), title: "Recheck this durable operation intent? A matching existing snapshot will be protected; missing snapshots are finalized absent.") }.disabled(!model.canMutate) }
                    }
                }
            }
            Text("\(model.visibleInventory.count) of \(model.inventory.count) entries. Command-created names include an ownership identifier plus your label. Creation times for managed snapshots are application-recorded request times. Snapshot sizes and recovered bytes are not inferred from file totals.").font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 12)
    }
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = model.comparison {
                Text("\(result.changes.count) reported changes · \(result.leftEntries) earlier / \(result.rightEntries) later entries").font(.headline)
                Text(result.metadataCoverageComplete ? "Metadata scan completed within its limits." : "Incomplete coverage — one-sided entries are unverified, not proven additions/removals.").foregroundStyle(.secondary)
                Text("\(result.contentUnverifiedFiles) file observations without content hashes. \(result.accounting)").font(.callout)
                HStack { TextField("Search comparison paths", text: $model.comparisonSearch).accessibilityLabel("Search comparison results"); Button("Export JSON…") { model.exportComparison() } }
                List(result.changes.filter { model.comparisonSearch.isEmpty || $0.path.localizedCaseInsensitiveContains(model.comparisonSearch) }) { change in
                    HStack { Text(change.kind.rawValue).frame(width: 140, alignment: .leading); Text(change.path).textSelection(.enabled); Spacer() }.accessibilityElement(children: .combine)
                }
                ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("Select two managed snapshots in Inventory & Details, then choose Compare Selected.").font(.headline)
                Text("The helper mounts both snapshots read-only. File inspection runs with your account's permissions. Symlinks and other mounted filesystems are not traversed. Large, unreadable or over-budget file contents remain unverified; file metadata does not measure exclusive APFS blocks.").foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(.top, 12)
    }
    private var activity: some View {
        List(model.response.activities.filter { $0.volumeUUID == model.volumeID }) { item in
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(item.action.capitalized).bold(); Text(item.status); Spacer(); Text(item.at, format: .dateTime.month().day().hour().minute().second()) }
                Text(item.detail).textSelection(.enabled)
                if let delta = item.observedCapacityChange { Text("Observed nearby physical free-space change: \(ByteCountFormatter.string(fromByteCount: delta, countStyle: .decimal)). Shared container; not exact recovered snapshot bytes.").font(.caption).foregroundStyle(.secondary) }
            }.accessibilityElement(children: .combine)
        }.accessibilityLabel("Snapshot management activity history")
    }
    private var timeMachineHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Requests across all APFS volumes included in Time Machine").font(.headline)
            Text("macOS chooses snapshot names. These records contain only tmutil's reported date token; Time Machine controls retention and deletion.").font(.callout).foregroundStyle(.secondary)
            if model.isQA {
                Text("Read-only QA session. Time Machine requests are disabled and live request history is not opened.").font(.callout)
            }
            if model.tmActivities.isEmpty && !model.tmBusy {
                Text(model.tmError == nil ? "No Time Machine snapshot requests recorded here." : "Time Machine request history is unavailable. Reload after resolving the error.").foregroundStyle(.secondary).accessibilityIdentifier("snapshots.timeMachine.empty")
                Spacer()
            } else {
                List(model.tmActivities) { item in SnapshotTimeMachineActivityRow(item: item) }
                    .accessibilityLabel("Time Machine snapshot request history")
                    .accessibilityIdentifier("snapshots.timeMachine.history")
            }
        }.padding(.top, 12)
    }
    private func ask(_ request: SnapshotServiceRequest, title: String) { pending = request; confirmation = title; confirmOperation = true }
}

private let timeMachineSnapshotScope = "macOS creates a Time Machine local snapshot of every APFS volume included in Time Machine, not just the selected volume. macOS chooses the names; Storage Monitor records only the date token tmutil reports. Time Machine controls retention and deletion; Storage Monitor will not delete or manage these snapshots. The request may take up to two minutes."

private struct SnapshotTimeMachineActivityRow: View {
    let item: TimeMachineSnapshotActivity
    @State private var showOutput = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.outcome == .reportedCreated ? "reported created" : item.outcome.rawValue).bold()
            Text("Started: \(item.startedAt.formatted(date: .abbreviated, time: .standard))").font(.callout)
            Text("Finished: \(item.finishedAt?.formatted(date: .abbreviated, time: .standard) ?? "Not recorded")").font(.callout)
            Text("Reported date token: \(item.returnedTimestampToken ?? "None") · Exit code: \(item.exitCode.map(String.init) ?? "Not recorded")").font(.caption).foregroundStyle(.secondary)
            Button(showOutput ? "Hide Command Output" : "Show Command Output") { showOutput.toggle() }
                .accessibilityIdentifier("snapshots.timeMachine.output")
            if showOutput {
                Text(item.output.isEmpty ? "No output recorded." : item.output)
                    .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.textSelection(.enabled).padding(.vertical, 4)
    }
}

private struct SnapshotTimeMachineAcknowledgementSheet: View {
    @ObservedObject var model: SnapshotManagementModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review uncertain Time Machine requests").font(.title2).bold()
            Text("These requests may have created snapshots. Their outcome is unknown and they have not been retried. Acknowledge them before making a new request.")
            List(model.tmUncertainActivities) { item in SnapshotTimeMachineActivityRow(item: item) }
                .frame(minHeight: 160, maxHeight: 280)
            Text(timeMachineSnapshotScope).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Acknowledge and Request Another Snapshot") {
                    dismiss()
                    model.requestTimeMachineSnapshot(acknowledgeUncertain: true)
                }.disabled(model.tmBusy || model.isQA || model.tmUncertainActivities.isEmpty)
            }
        }.padding(24).frame(width: 680)
    }
}

private struct SnapshotCreationSheet: View {
    @ObservedObject var model: SnapshotManagementModel
    @Environment(\.dismiss) var dismiss
    @State private var label = "Manual Snapshot"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create APFS snapshot").font(.title2).bold()
            Text(model.volume?.name ?? "Select a volume").font(.headline)
            TextField("Snapshot name", text: $label).accessibilityIdentifier("snapshots.create.name")
            Text("The native name includes your name after a unique Storage Monitor ownership prefix. A snapshot captures this volume only. It can preserve blocks as files change; it is not an independent backup.").foregroundStyle(.secondary)
            if !model.available { Text(model.serviceStatus).font(.callout) }
            HStack { Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Create Snapshot") { let volume = model.volumeID; dismiss(); model.perform(.init(action: .create, volumeUUID: volume, label: label)) }.disabled(!model.canMutate || label.isEmpty || label.utf8.count > 80 || label.contains("/")).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520)
    }
}
private struct SnapshotPolicySheet: View {
    @ObservedObject var model: SnapshotManagementModel
    @Environment(\.dismiss) var dismiss
    @State private var policy = SnapshotPolicy()
    @State private var pressureGB = 0
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule & Retention").font(.title2).bold()
            Text(model.volume?.name ?? "Volume unavailable").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $policy.enabled) { Text("Enable automatic snapshots on this volume").fixedSize(horizontal: false, vertical: true) }.accessibilityIdentifier("snapshots.schedule.enabled")
                HStack {
                    Text("Frequency"); Spacer()
                    Picker("Frequency", selection: $policy.interval) { ForEach(SnapshotInterval.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden().frame(width: 180)
                }
                if policy.interval == .custom { SnapshotPolicyNumber(label: "Interval in minutes (15–525600)", value: $policy.customIntervalMinutes) }
                SnapshotPolicyNumber(label: "Maximum managed snapshot count", value: $policy.maximumCount)
                SnapshotPolicyNumber(label: "Maximum age in days", value: $policy.maximumAgeDays)
                SnapshotPolicyNumber(label: "Pause creation below physical free GB (0 = off)", value: $pressureGB)
                Toggle(isOn: $policy.retentionEnabled) { Text("Allow automatic deletion under this retention policy").fixedSize(horizontal: false, vertical: true) }.accessibilityIdentifier("snapshots.retention.enabled")
            }
            Text("Hourly, daily and weekly are elapsed intervals, not calendar alarms. Missed periods become one attempt after wake; disconnected volumes are skipped. Automatic retention runs only after a scheduled attempt, only on verified owned snapshots. Protected/excluded snapshots and the newest recovery point are kept; they can prevent reaching the count limit.").font(.callout).foregroundStyle(.secondary)
            Text("Preview Retention in the inventory shows currently proposed deletions. Low free space pauses creation and does not authorize extra deletions beyond these age/count rules.").font(.callout)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Policy…") { confirm = true }.disabled(!model.available || model.isQA || model.busy || pressureGB < 0 || pressureGB > 1_000_000 || (try? policy.validate()) == nil)
            }
        }.padding(24).frame(width: 620)
        .onAppear { policy = model.policy; pressureGB = Int((policy.minimumFreeBytes ?? 0) / 1_000_000_000) }
        .confirmationDialog("Apply this snapshot policy?", isPresented: $confirm, titleVisibility: .visible) {
            Button(policy.enabled ? "Enable Schedule and Save Policy" : "Save with Schedule Disabled") {
                guard (0...1_000_000).contains(pressureGB) else { model.error = "Free-space threshold must be between 0 and 1,000,000 GB."; return }
                policy.minimumFreeBytes = pressureGB > 0 ? Int64(pressureGB) * 1_000_000_000 : nil
                let request = SnapshotServiceRequest(action: .savePolicy, volumeUUID: model.volumeID, policy: policy)
                dismiss(); model.perform(request)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Automatic creation: \(policy.enabled ? "ON" : "OFF"). Automatic permanent deletion: \(policy.retentionEnabled && policy.enabled ? "ON, verified owned snapshots only" : "OFF"). Maximum \(policy.maximumCount) snapshots and \(policy.maximumAgeDays) days, subject to protection/exclusions.") }
    }
}

private struct SnapshotPolicyNumber: View {
    let label: String
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 16) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            TextField(label, value: $value, format: .number).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 140).accessibilityLabel(label)
        }
    }
}
