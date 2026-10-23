import AppKit
import SwiftUI

/// A modeless, selection-following inspector. A separate native panel avoids
/// macOS 27's nested split-view constraint loop when the library is narrowed.
struct InspectorPanel<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let content: Content

    init(
        isPresented: Binding<Bool>, title: String,
        @ViewBuilder content: () -> Content
    ) {
        _isPresented = isPresented
        self.title = title
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
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private weak var parentWindow: NSWindow?
    private var finishing = false

    func update(parent: NSWindow?) {
        guard let parent else { return }
        guard binding?.wrappedValue == true else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 580),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered, defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier(
                "TsundokuInspector")
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 280, height: 320)
            panel.delegate = self
            let hosting = NSHostingView(rootView: content)
            panel.contentView = hosting
            self.hosting = hosting
            self.panel = panel
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
    }

    func finish() {
        finishing = true
        NotificationCenter.default.removeObserver(self)
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
