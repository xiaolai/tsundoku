import AppKit
import SwiftUI
import TsundokuUI

/// The menu bar is declared by scenes. These commands replace the hand-built
/// `NSMenu`, keep the existing labels and shortcuts, and take their enabled
/// state from `BrowserMenuState`.
struct TsundokuCommands: Commands {
    @ObservedObject var delegate: AppDelegate

    private var state: BrowserMenuState { delegate.browserMenuState }

    var body: some Commands {
        // The generated Window -> Library item bypasses openLibrary(), so a
        // cold open can stay on the spinner and a reopen loses live polling.
        // The old Window menu had no such item; the status menu is the entry.
        CommandGroup(replacing: .singleWindowList) {}

        CommandGroup(after: .newItem) {
            Button("Open Book Annotations") {
                delegate.performBrowserCommand("open")
            }
            .keyboardShortcut("o")
            .disabled(!state.canOpenBook)

            Button("Import Library") { delegate.importFromMenu() }
                .keyboardShortcut("r")
                .disabled(!state.canImport)

            Button("Export Annotation Results…") {
                delegate.performBrowserCommand("export")
            }
            .keyboardShortcut("e")
            .disabled(!state.annotations)

            Button("Saved AI Notes…") { delegate.showSavedNotes() }
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                delegate.performResponderAction(#selector(NSText.cut(_:)))
            }
            .keyboardShortcut("x")
            .disabled(!delegate.canCut)

            Button("Copy") { delegate.copyFromMenu() }
                .keyboardShortcut("c")

            Button("Paste") {
                delegate.performResponderAction(#selector(NSText.paste(_:)))
            }
            .keyboardShortcut("v")
            .disabled(!delegate.canPaste)

            Button("Select All") { delegate.selectAllFromMenu() }
                .keyboardShortcut("a")
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { delegate.performBrowserCommand("find") }
                .keyboardShortcut("f")
                .disabled(!state.libraryOrAnnotations)
        }

        CommandGroup(after: .sidebar) {
            Button("Cards") { delegate.performBrowserCommand("cards") }
                .keyboardShortcut("1")
                .disabled(!state.annotations)

            Button("List") { delegate.performBrowserCommand("list") }
                .keyboardShortcut("2")
                .disabled(!state.annotations)

            Divider()

            Button("Show / Hide Sidebar") {
                delegate.performBrowserCommand("sidebar")
            }
            .disabled(!state.browserActive)

            Button("Show / Hide Inspector") {
                delegate.performBrowserCommand("inspector")
            }
            .keyboardShortcut("i")
            .disabled(!state.libraryOrAnnotations)

            Button("Back to Books") {
                delegate.performBrowserCommand("back")
            }
            .keyboardShortcut("[")
            .disabled(!state.canGoBack)
        }
    }
}
