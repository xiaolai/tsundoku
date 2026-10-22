import SwiftUI

/// A toolbar search control that starts as a magnifier button and expands
/// into a field when used. SwiftUI's native macOS search item cannot be
/// collapsed by default (`SearchToolbarBehavior.minimize` is unavailable on
/// macOS), so this uses standard controls to get that behavior.
struct ToolbarSearch: View {
    @Binding var text: String
    let prompt: String

    @State private var expanded = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if expanded {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(prompt, text: $text)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .frame(width: 180)
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .onExitCommand {
                    text = ""
                    collapse()
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused && text.isEmpty {
                        collapse()
                    }
                }
            } else {
                Button {
                    expanded = true
                    DispatchQueue.main.async {
                        focused = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search")
                .accessibilityLabel("Search")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: expanded)
    }

    private func collapse() {
        expanded = false
        focused = false
    }
}
