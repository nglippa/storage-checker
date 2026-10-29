import SwiftUI

/// A small native visual vocabulary, shared by the browser and monitoring views.
/// Values are in points; semantic system colors retain contrast in either appearance.
enum StorageDesign {
    static let compactGap: CGFloat = 8
    static let rowGap: CGFloat = 12
    static let sectionGap: CGFloat = 20
    static let gutter: CGFloat = 20
    static let inspectorWidth: CGFloat = 320
    static let valueFont = Font.system(size: 28, weight: .semibold).monospacedDigit()
}

/// A whole-row, keyboard-accessible disclosure. Evidence is revealed, never summarized as approval.
struct InspectorDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The content appears at once and only the chevron turns: animating the insertion faded the content in at
            // full size while the rows below were still sliding down, so the two overlapped mid-animation.
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isExpanded)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide \(title.lowercased())")
            if isExpanded { content() }
        }
    }
}
