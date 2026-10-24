import AppKit
import SwiftUI

extension Notification.Name {
    public static let tsundokuBrowserCommand = Notification.Name(
        "TsundokuBrowserCommand")
}

@MainActor var browserWindowIsKey: Bool {
    NSApp.keyWindow?.identifier?.rawValue == TsundokuWindowIdentifier.library
}

/// Native searchable manages toolbar collapse, expansion and keyboard focus.
private struct BrowserSearch: ViewModifier {
    @Binding var text: String
    let prompt: String
    @State private var presented = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: $text, isPresented: $presented, placement: .toolbar,
                prompt: prompt
            )
            .searchFocused($focused)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .tsundokuBrowserCommand)
            ) { notification in
                guard browserWindowIsKey,
                    notification.userInfo?["command"] as? String == "find"
                else { return }
                presented = true
                DispatchQueue.main.async { focused = true }
            }
    }
}

extension View {
    func browserSearch(text: Binding<String>, prompt: String) -> some View {
        modifier(BrowserSearch(text: text, prompt: prompt))
    }
}
