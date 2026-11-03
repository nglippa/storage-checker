import SwiftUI
import AppKit

/// Presentation controls only; their state has no catalog or filesystem dependency.
struct StructuredExplorerFilterControls: View {
    @ObservedObject var state: StructuredExplorerState
    /// Detected Migration Readiness items (0: the Migration Review toggle is unavailable).
    var reviewItems = 0
    let canFocus: Bool
    let canIsolate: Bool
    let isolate: () -> Void
    let showPath: () -> Void
    let clear: () -> Void
    let reset: () -> Void
    @ViewState private var custom = false
    @ViewState private var value = "1"
    @ViewState private var unit = StructuredExplorerSizeUnit.gb

    private var activeSize: String { state.filter.minimumBytes == 0 ? "All" : "≥" + AtlasText.bytes(state.filter.minimumBytes) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { sizeMenu; presentation; focus; review; pathMenu; Spacer(minLength: 4); resetButton }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) { sizeMenu; presentation; review; Spacer(minLength: 4) }
                HStack(spacing: 10) { focus; pathMenu; Spacer(minLength: 4); resetButton }
            }
        }
        .font(.caption).controlSize(.small).buttonStyle(.borderless)
        .accessibilityElement(children: .contain).accessibilityLabel("Explorer filters")
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(StructuredExplorerSizePreset.allCases, id: \.self) { preset in
                Button {
                    if let bytes = preset.bytes { state.filter.minimumBytes = bytes }
                    else { value = "1"; unit = .gb; custom = true }
                } label: {
                    if preset.bytes == state.filter.minimumBytes { Label(preset == .all ? "All" : "≥" + preset.title, systemImage: "checkmark") }
                    else { Text(preset == .all || preset == .custom ? preset.title : "≥" + preset.title) }
                }
            }
        } label: { Text("Size: \(activeSize)").monospacedDigit() }
        .fixedSize().accessibilityLabel("Minimum indexed size").accessibilityValue(activeSize)
        .help("Decimal MB and GB of indexed allocated storage. Unknown sizes only match All. No filesystem scan.")
        .popover(isPresented: $custom) { customEditor }
    }

    private var presentation: some View {
        Picker("Nonmatches", selection: $state.filter.presentation) {
            Text("Dim").tag(StructuredExplorerFilterPresentation.dim)
            Text("Hide").tag(StructuredExplorerFilterPresentation.hide)
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
        .accessibilityLabel("Nonmatching nodes").accessibilityValue(state.filter.presentation == .dim ? "Dim nonmatching" : "Hide nonmatching")
        .help("Dim keeps faded discs selectable. Hide removes their hit targets. Matching ancestors and the selection stay visible.")
    }

    private var focus: some View {
        Toggle("Focus", isOn: Binding(get: { state.filter.focus != .off }, set: { state.filter.focus = $0 ? .subtree : .off }))
            .toggleStyle(.button).disabled(!canFocus && state.filter.focus == .off)
            .accessibilityLabel("Focus on selected folder")
            .accessibilityValue(state.filter.focus == .off ? "Off" : state.filter.focus == .path ? "Path to root" : "Ancestors and descendants")
            .help("Emphasize the selected folder, its ancestors and descendants; unrelated branches fade. Select a folder first.")
    }

    private var review: some View {
        Toggle("Migration Review", isOn: $state.filter.migrationReview)
            .toggleStyle(.button).disabled(reviewItems == 0 && !state.filter.migrationReview)
            .accessibilityLabel("Migration Review")
            .accessibilityValue(state.filter.migrationReview ? "On, \(reviewItems) detected items" : "Off")
            .help(reviewItems == 0 ? "No sparse-storage items were detected in the indexed locations." :
                  "Highlight the paths to \(reviewItems == 1 ? "the detected sparse-storage item" : "\(reviewItems) detected sparse-storage items"); unrelated branches fade. Sizes still show allocated storage.")
    }

    private var pathMenu: some View {
        Menu {
            Button("Isolate This Path", action: isolate).disabled(!canIsolate)
            Button("Show Path to Root", action: showPath).disabled(!canFocus)
            Button("Focus on Selection") { state.filter.focus = .subtree }.disabled(!canFocus)
            Divider()
            Button("Clear Focus / Isolation", action: clear)
        } label: { Image(systemName: "ellipsis.circle") }
        .accessibilityLabel("Selected folder path actions")
        .help("Path actions for the selected folder; also available by right-clicking a folder disc or label.")
    }

    private var resetButton: some View {
        Button("Reset", action: reset)
            .disabled(!state.filter.isActive && state.isolatedRoot == nil && state.camera.isFit)
            .accessibilityLabel("Reset explorer filters and isolation")
            .help("All sizes, Dim, focus off, exit isolation and reset the view. Keeps Levels and restores the entry selection.")
    }

    private var customEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Minimum indexed size").font(.headline)
            HStack {
                TextField("Size", text: $value).textFieldStyle(.roundedBorder).frame(width: 120)
                    .accessibilityLabel("Custom minimum size").onSubmit(applyCustom)
                Picker("Units", selection: $unit) {
                    ForEach(StructuredExplorerSizeUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize().accessibilityLabel("Size units, decimal")
            }
            Text(StructuredExplorerThreshold.parse(value, unit: unit) == nil ? "Enter a positive decimal size within the supported range." : "1 MB = 1,000,000 bytes · 1 GB = 1,000 MB")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Cancel") { custom = false }; Button("Apply", action: applyCustom).disabled(StructuredExplorerThreshold.parse(value, unit: unit) == nil).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 290)
    }

    private func applyCustom() {
        guard let bytes = StructuredExplorerThreshold.parse(value, unit: unit) else { return }
        state.filter.minimumBytes = bytes; custom = false
    }
}

/// NSMenu retains the target through representedObject; callbacks act only on this canvas's state.
final class StructuredExplorerMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: NSMenuItem) { action() }
    static func item(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let handler = StructuredExplorerMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        item.target = handler; item.representedObject = handler; item.isEnabled = enabled
        return item
    }
}
