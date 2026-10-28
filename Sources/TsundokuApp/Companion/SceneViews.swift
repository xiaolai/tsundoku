import AppKit
import SwiftUI
import TsundokuUI

/// The persistent status-bar label. It carries the shortcut-test feedback
/// symbol and installs the scene actions for AppKit-originated opens.
struct MenuBarLabel: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: delegate.feedbackSymbol)
            .accessibilityLabel(
                delegate.feedbackNote.isEmpty ? "Tsundoku" : delegate.feedbackNote)
            .onAppear {
                delegate.installSceneActions(
                    openWindow: openWindow, openSettings: openSettings)
            }
    }
}

struct StatusMenuView: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Button("Show Companion") { delegate.showCompanion() }
                .disabled(!delegate.readerPresent || delegate.panelOpen)
            Button("Hide Companion") { delegate.hideCompanion() }
                .disabled(!delegate.panelOpen)
            Divider()
            Button("Library…") { delegate.showLibrarySection() }
                .keyboardShortcut("o")
            Button("Settings…") { delegate.openSettings() }
                .keyboardShortcut(",")
            if let release = delegate.updateChecker.availableRelease {
                Button("Update Available: \(release.version)…") {
                    delegate.updateChecker.openReleasePage()
                }
            } else {
                Button(
                    delegate.updateChecker.isChecking
                        ? "Checking for Updates…" : "Check for Updates…"
                ) {
                    delegate.updateChecker.check()
                }
                .disabled(delegate.updateChecker.isChecking)
            }
            Divider()
            Toggle(
                "Start at Login",
                isOn: Binding(
                    get: { delegate.launchAtLogin },
                    set: { delegate.setLaunchAtLogin($0) }))
            Button("Test Shortcut…") { delegate.testShortcut() }
            if !delegate.feedbackNote.isEmpty {
                Button(delegate.feedbackNote) {}
                    .disabled(true)
            }
            Divider()
            Button("Quit Tsundoku") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear {
            delegate.installSceneActions(
                openWindow: openWindow, openSettings: openSettings)
        }
    }
}

struct LibrarySceneView: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let model = delegate.appModel {
                RootView(model: model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            WindowConfigurator { window in
                delegate.configureLibraryWindow(window)
            })
        .onAppear {
            delegate.installSceneActions(
                openWindow: openWindow, openSettings: openSettings)
            delegate.setLibraryVisible(true)
        }
        .onDisappear {
            delegate.setLibraryVisible(false)
        }
    }
}

struct SettingsSceneView: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject private var navigation: SettingsNavigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init(delegate: AppDelegate) {
        _delegate = ObservedObject(wrappedValue: delegate)
        _navigation = ObservedObject(wrappedValue: delegate.settingsNavigation)
    }

    private var pane: Binding<SettingsPane> {
        Binding(
            get: { navigation.selectedPane },
            set: { navigation.select($0) })
    }

    /// The old controller sized each pane explicitly. A Settings scene opened
    /// before the model exists first lays out a spinner; without a fixed
    /// height the window stays at that height after the content arrives.
    /// One height for every pane. Per-pane heights made the window jump on
    /// every tab change, and the panes scroll anyway.
    private func paneHeight(_ pane: SettingsPane) -> CGFloat { 620 }

    var body: some View {
        Group {
            if let model = delegate.appModel {
                TabView(selection: pane) {
                    ForEach(SettingsPane.allCases) { pane in
                        SettingsView(
                            model: model, pane: pane,
                            navigation: navigation,
                            providerState: delegate.providerState,
                            updateChecker: delegate.updateChecker
                        )
                        .tabItem {
                            Label(pane.rawValue, systemImage: pane.symbol)
                        }
                        .tag(pane)
                    }
                }
                .frame(width: 640, height: paneHeight(navigation.selectedPane))
            } else {
                ProgressView()
            }
        }
        .background(
            WindowConfigurator { window in
                delegate.configureSettingsWindow(window)
            })
        .onAppear {
            delegate.settingsSceneAppeared()
            delegate.installSceneActions(
                openWindow: openWindow, openSettings: openSettings)
            delegate.setSettingsVisible(true, dismiss: { dismiss() })
        }
        .onDisappear {
            delegate.setSettingsVisible(false)
        }
    }
}
