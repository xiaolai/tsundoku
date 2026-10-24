import AppKit
import SwiftUI

/// A modeless, selection-following inspector. A separate native panel avoids
/// macOS 27's nested split-view constraint loop when the library is narrowed.
struct InspectorPanel<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let content: Content
    let initialSize: NSSize
    let keepsVisibleWhenInactive: Bool

    init(
        isPresented: Binding<Bool>, title: String,
        initialSize: NSSize = NSSize(width: 340, height: 580),
        keepsVisibleWhenInactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        _isPresented = isPresented
        self.title = title
        self.initialSize = initialSize
        self.keepsVisibleWhenInactive = keepsVisibleWhenInactive
        self.content = content()
    }

    func makeCoordinator() -> InspectorPanelCoordinator {
        InspectorPanelCoordinator()
    }

    func makeNSView(context: Context) -> InspectorAnchorView {
        InspectorAnchorView()
    }

    func updateNSView(_ view: InspectorAnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.binding = $isPresented
        coordinator.content = AnyView(content)
        coordinator.title = title
        coordinator.initialSize = initialSize
        coordinator.keepsVisibleWhenInactive = keepsVisibleWhenInactive
        view.windowChanged = { [weak coordinator] window in
            coordinator?.update(parent: window)
        }
        coordinator.update(parent: view.window)
    }

    static func dismantleNSView(
        _ view: InspectorAnchorView, coordinator: InspectorPanelCoordinator
    ) {
        view.windowChanged = nil
        coordinator.finish()
    }
}

final class InspectorAnchorView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

@MainActor final class InspectorPanelCoordinator: NSObject, NSWindowDelegate {
    var binding: Binding<Bool>?
    var content = AnyView(EmptyView())
    var title = "Inspector"
    var initialSize = NSSize(width: 340, height: 580)
    var keepsVisibleWhenInactive = false
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private weak var parentWindow: NSWindow?
    private var finishing = false

    func update(parent: NSWindow?) {
        guard let parent else { return }
        guard binding?.wrappedValue == true else {
            panel?.orderOut(nil)
            if let panel { parentWindow?.removeChildWindow(panel) }
            parentWindow = nil
            NotificationCenter.default.removeObserver(self)
            return
        }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: keepsVisibleWhenInactive
                    ? [.titled, .closable, .utilityWindow]
                    : [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered, defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier(
                TsundokuWindowIdentifier.inspector)
            // The access guide must never cover the foreground System Settings app.
            panel.isFloatingPanel = !keepsVisibleWhenInactive
            if keepsVisibleWhenInactive { panel.level = .normal }
            panel.hidesOnDeactivate = !keepsVisibleWhenInactive
            panel.becomesKeyOnlyIfNeeded = !keepsVisibleWhenInactive
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 280, height: 320)
            panel.delegate = self
            let hosting = NSHostingView(rootView: content)
            panel.contentView = hosting
            self.hosting = hosting
            self.panel = panel
            if keepsVisibleWhenInactive {
                NSWorkspace.shared.notificationCenter.addObserver(self,
                    selector: #selector(workspaceActivated(_:)),
                    name: NSWorkspace.didActivateApplicationNotification, object: nil)
            }
            let visible = parent.screen?.visibleFrame ?? parent.frame
            panel.setFrameOrigin(
                NSPoint(
                    x: min(
                        parent.frame.maxX + 8, visible.maxX - panel.frame.width),
                    y: max(visible.minY, parent.frame.maxY - panel.frame.height)
                ))
        }
        guard let panel else { return }
        panel.title = title
        hosting?.rootView = content
        if parentWindow !== parent {
            NotificationCenter.default.removeObserver(self)
            parentWindow?.removeChildWindow(panel)
            parentWindow = parent
            parent.addChildWindow(panel, ordered: .above)
            NotificationCenter.default.addObserver(
                self, selector: #selector(parentBecameKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: parent)
            NotificationCenter.default.addObserver(
                self, selector: #selector(parentWillClose(_:)),
                name: NSWindow.willCloseNotification, object: parent)
        }
        if parent.isVisible && !panel.isVisible { panel.orderFront(nil) }
        if keepsVisibleWhenInactive { avoidSystemSettings() }
    }

    func windowWillClose(_ notification: Notification) {
        guard !finishing, let binding else { return }
        if let panel { parentWindow?.removeChildWindow(panel) }
        parentWindow = nil
        NotificationCenter.default.removeObserver(self)
        DispatchQueue.main.async { binding.wrappedValue = false }
    }

    @objc private func parentBecameKey(_ notification: Notification) {
        update(parent: notification.object as? NSWindow)
    }

    @objc private func parentWillClose(_ notification: Notification) {
        panel?.orderOut(nil)
        if keepsVisibleWhenInactive, let binding {
            DispatchQueue.main.async { binding.wrappedValue = false }
        }
    }

    @objc private func workspaceActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.bundleIdentifier == "com.apple.systempreferences" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.avoidSystemSettings()
        }
    }

    private func avoidSystemSettings() {
        guard let panel, let screen = panel.screen ?? parentWindow?.screen,
            let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let frames: [NSRect] = windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == settings.processIdentifier,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        guard frames.contains(where: { $0.intersects(panel.frame) }) else { return }
        panel.setFrameOrigin(PanelPlacement.origin(size: panel.frame.size,
            visible: screen.visibleFrame, avoiding: frames, preferred: panel.frame.origin))
    }

    func finish() {
        finishing = true
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.delegate = nil
            panel.close()
        }
        panel = nil
        hosting = nil
        parentWindow = nil
    }
}

enum PanelPlacement {
    static func origin(size: NSSize, visible: NSRect, avoiding obstacles: [NSRect], preferred: NSPoint) -> NSPoint {
        func clamped(_ point: NSPoint) -> NSPoint {
            NSPoint(x: max(visible.minX, min(point.x, visible.maxX - size.width)),
                y: max(visible.minY, min(point.y, visible.maxY - size.height)))
        }
        var candidates = [preferred]
        for rect in obstacles {
            candidates += [NSPoint(x: rect.maxX + 12, y: preferred.y),
                NSPoint(x: rect.minX - size.width - 12, y: preferred.y),
                NSPoint(x: preferred.x, y: rect.maxY + 12),
                NSPoint(x: preferred.x, y: rect.minY - size.height - 12)]
        }
        candidates += [NSPoint(x: visible.minX, y: visible.minY),
            NSPoint(x: visible.maxX - size.width, y: visible.maxY - size.height)]
        return candidates.map(clamped).filter { point in
            !obstacles.contains { $0.intersects(NSRect(origin: point, size: size)) }
        }.min { a, b in
            hypot(a.x - preferred.x, a.y - preferred.y) < hypot(b.x - preferred.x, b.y - preferred.y)
        } ?? clamped(preferred)
    }
}
