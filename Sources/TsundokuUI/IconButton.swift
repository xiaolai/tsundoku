import SwiftUI

/// Compact actions retain their names for tooltips, VoiceOver and UI automation.
struct IconButton: View {
    let title: String
    let systemImage: String
    var tooltip: String? = nil
    let action: () -> Void

    init(
        _ title: String, systemImage: String, tooltip: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tooltip = tooltip
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.borderless)
        .help(tooltip ?? title)
        .accessibilityLabel(title)
    }
}
