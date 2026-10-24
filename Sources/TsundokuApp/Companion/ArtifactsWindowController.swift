import AppKit
import SwiftUI
import TsundokuCore
import TsundokuUI

/// The artifacts manager: one window, created only when the user asks for it.
///
/// Replaces the launch-time `WindowGroup`. It hosts the existing `RootView`, so
/// the library, annotations, history, exports and settings are unchanged.
@MainActor
final class ArtifactsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: AppModel?
    private let makeModel: () -> AppModel

    init(makeModel: @escaping () -> AppModel) {
        self.makeModel = makeModel
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func modelIfCreated() -> AppModel? { model }

    func show(section: AppModel.Section? = nil, importLibrary: Bool) {
        let model = ensureModel()
        if let section { model.section = section }
        model.activate(importLibrary: importLibrary)
        let window = ensureWindow(model: model)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        TsundokuDiagnostics.shared.event(
            "artifacts_window_shown",
            [
                "section": model.section.rawValue,
                "import_requested": importLibrary,
                "window_visible": window.isVisible,
                "activation_policy": NSApp.activationPolicy().rawValue,
            ])
    }

    func close() {
        window?.close()
    }

    private func ensureModel() -> AppModel {
        if let model { return model }
        let model = makeModel()
        self.model = model
        return model
    }

    private func ensureWindow(model: AppModel) -> NSWindow {
        if let window { return window }
        let hosting = NSHostingView(rootView: RootView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered, defer: false)
        window.title = ""
        window.identifier = NSUserInterfaceItemIdentifier("TsundokuLibrary")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.minSize = NSSize(width: 760, height: 540)
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("TsundokuArtifacts")
        self.window = window
        roundContent(of: window)
        TsundokuDiagnostics.shared.event(
            "artifacts_window_created",
            ["windows": NSApp.windows.count])
        return window
    }

    /// macOS 27 draws a full-size SwiftUI host square; the SwiftUI
    /// `WindowGroup` this window replaces needed the same correction. Earlier
    /// systems draw their own shape, so they are left alone.
    private func roundContent(of window: NSWindow) {
        guard #available(macOS 27.0, *) else { return }
        guard
            !window.styleMask.contains(.fullScreen),
            window.styleMask.contains(.fullSizeContentView),
            let content = window.contentView
        else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        roundContent(of: window)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.contentView?.layer?.cornerRadius = 0
        window.contentView?.layer?.masksToBounds = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        roundContent(of: window)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stopLivePolling()
        TsundokuDiagnostics.shared.event("artifacts_window_closed")
    }
}
