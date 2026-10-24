import AppKit
import SwiftUI

/// AppKit callbacks (the hot key, launch arguments, onboarding) must open
/// SwiftUI scenes. `openWindow` and `openSettings` only exist in a view's
/// environment, so the first always-present scene view installs them here.
/// A request that arrives first is queued, not dropped.
@MainActor
final class SceneWindowBridge {
    private var openLibraryAction: (() -> Void)?
    private var openSettingsAction: (() -> Void)?
    private var dismissSettingsAction: (() -> Void)?
    private var pendingLibrary = false
    private var pendingSettings = false

    func install(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        openLibraryAction = { openWindow(id: LibraryScene.id) }
        openSettingsAction = { openSettings() }
        if pendingLibrary {
            pendingLibrary = false
            openLibraryAction?()
        }
        if pendingSettings {
            pendingSettings = false
            openSettingsAction?()
        }
    }

    func openLibrary() {
        guard let openLibraryAction else {
            pendingLibrary = true
            return
        }
        openLibraryAction()
    }

    func openSettings() {
        guard let openSettingsAction else {
            pendingSettings = true
            return
        }
        openSettingsAction()
    }

    func setDismissSettings(_ action: (() -> Void)?) {
        dismissSettingsAction = action
    }

    func dismissSettings() {
        dismissSettingsAction?()
    }
}

/// SwiftUI's `Window` scene has no hook for the window itself. This reads the
/// hosting window so the app can assign the stable identifier used by menu
/// enablement, apply the macOS 27 content rounding, and observe closure.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.configure = configure
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.configure = configure
        view.report()
    }

    final class WindowReaderView: NSView {
        var configure: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        func report() {
            configure?(window)
        }
    }
}
