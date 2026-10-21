import AppKit
import SwiftUI
import KindlingUI

@main
struct KindlingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    private let hotKey = HotKeyManager()

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--appearance"),
            CommandLine.arguments.indices.contains(index + 1),
            let appearance = appearanceArgument(
                CommandLine.arguments[index + 1])
        {
            NSApplication.shared.appearance = appearance
        }
    }

    private func appearanceArgument(_ value: String) -> NSAppearance? {
        switch value {
        case "dark": NSAppearance(named: .darkAqua)
        case "light": NSAppearance(named: .aqua)
        default: nil
        }
    }

    var body: some Scene {
        WindowGroup("Kindling") {
            RootView(model: model)
                .onAppear {
                    model.refreshPermissions()
                    hotKey.onPress = {
                        AIPanelController.shared.show(app: model)
                    }
                    hotKey.install()
                    if CommandLine.arguments.contains("--demo-panel") {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 2.5
                        ) {
                            AIPanelController.shared.show(app: model)
                        }
                    }
                    if CommandLine.arguments.contains("--track-reading") {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 2.0
                        ) {
                            if model.trackedBookID == nil {
                                model.toggleTracking()
                            }
                        }
                    }
                    if CommandLine.arguments.contains("--demo-capture") {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 3.0
                        ) {
                            model.startCapture(pages: 2)
                        }
                    }
                    if CommandLine.arguments.contains("--demo-notice") {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 1.5
                        ) {
                            model.post(
                                "Imported 2,923 books and 7,148 annotations.")
                        }
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Ask About This Page") {
                    AIPanelController.shared.show(app: model)
                }
                Button("Refresh Library") {
                    model.importLibrary()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--appearance"),
            CommandLine.arguments.indices.contains(index + 1)
        {
            switch CommandLine.arguments[index + 1] {
            case "dark":
                NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light":
                NSApp.appearance = NSAppearance(named: .aqua)
            default:
                break
            }
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    window.appearance = NSApp.appearance
                }
            }
            for delay in [0.6, 1.6, 2.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    for window in NSApp.windows {
                        window.appearance = NSApp.appearance
                    }
                }
            }
        }
        // SwiftUI adds .fullSizeContentView, so the content reaches the square
        // screen edge. Keep the full-size layout but clip the content to the
        // system window radius and make the window background clear.
        DispatchQueue.main.async {
            Self.roundMainWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            Self.roundMainWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            Self.roundMainWindows()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil,
            queue: .main
        ) { _ in
            Self.roundMainWindows()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            window.contentView?.layer?.cornerRadius = 0
            window.contentView?.layer?.masksToBounds = false
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil,
            queue: .main
        ) { _ in
            Self.roundMainWindows()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if CommandLine.arguments.contains("--window-debug") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for window in NSApp.windows where window.isVisible {
                    let content = window.contentView
                    NSLog(
                        "KINDOW style=%lu opaque=%d transparentTitlebar=%d "
                            + "fullSize=%d layer=%d corner=%.1f masks=%d "
                            + "frame=%@ bg=%@",
                        window.styleMask.rawValue,
                        window.isOpaque ? 1 : 0,
                        window.titlebarAppearsTransparent ? 1 : 0,
                        window.styleMask.contains(.fullSizeContentView)
                            ? 1 : 0,
                        content?.wantsLayer == true ? 1 : 0,
                        content?.layer?.cornerRadius ?? -1,
                        content?.layer?.masksToBounds == true ? 1 : 0,
                        NSStringFromRect(window.frame),
                        String(describing: window.backgroundColor))
                    if #available(macOS 27.0, *) {
                        NSLog(
                            "KINDOW cornerConfig=%@ radii=%@",
                            String(describing: content?.cornerConfiguration),
                            String(describing: content?.effectiveCornerRadii))
                    }
                    if let toolbar = window.toolbar {
                        for item in toolbar.items {
                            NSLog(
                                "KINTOOL id=%@ class=%@",
                                item.itemIdentifier.rawValue,
                                String(describing: type(of: item)))
                        }
                    }
                }
            }
        }
    }

    private static func roundMainWindows() {
        // macOS 27 draws SwiftUI full-size windows square. Earlier systems
        // draw their own window shape, so they must be left alone.
        guard #available(macOS 27.0, *) else { return }
        for window in NSApp.windows
        where window.isVisible
            && !(window is NSPanel)
            && !window.styleMask.contains(.fullScreen)
            && window.styleMask.contains(.fullSizeContentView)
        {
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            guard let content = window.contentView else { continue }
            content.wantsLayer = true
            content.layer?.cornerRadius = 16
            content.layer?.masksToBounds = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}
