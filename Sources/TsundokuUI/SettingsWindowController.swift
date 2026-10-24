import AppKit
import Combine
import SwiftUI

/// One retained, modeless native Settings window. Toolbar panes preserve the
/// AppKit application lifecycle and keep library navigation out of Settings.
@MainActor public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let navigation: SettingsNavigation
    private var subscriptions: [AnyCancellable] = []
    private let tabs: SettingsTabController
    private let provider: ProviderSettingsState

    public init(model: AppModel, navigation: SettingsNavigation, providerState: ProviderSettingsState? = nil) {
        self.navigation = navigation
        provider = providerState ?? ProviderSettingsState()
        tabs = SettingsTabController(model: model, navigation: navigation)
        super.init(window: nil)
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let hosting = NSHostingController(rootView: SettingsView(model: model, pane: pane,
                navigation: navigation, providerState: provider))
            hosting.title = pane.rawValue
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = pane.rawValue
            item.label = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.rawValue)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("TsundokuSettings")
        window.contentViewController = tabs
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("TsundokuSettings")
        if !window.setFrameUsingName("TsundokuSettings") { window.center() }
        self.window = window
        tabs.select(navigation.selectedPane)
        navigation.$selectedPane.removeDuplicates().sink { [weak tabs] pane in tabs?.select(pane) }.store(in: &subscriptions)
        model.objectWillChange.sink { [weak tabs] _ in
            DispatchQueue.main.async { tabs?.refreshSize() }
        }.store(in: &subscriptions)
        navigation.objectWillChange.sink { [weak tabs] _ in
            DispatchQueue.main.async { tabs?.refreshSize() }
        }.store(in: &subscriptions)
        model.permissions?.objectWillChange.sink { [weak tabs] _ in
            DispatchQueue.main.async { tabs?.refreshSize() }
        }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public func prepareForTermination() { provider.invalidateTest() }
    public var isVisible: Bool { window?.isVisible == true }
    public func present() {
        tabs.select(navigation.selectedPane)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    public func windowWillClose(_ notification: Notification) { navigation.windowClosed() }
}

@MainActor private final class SettingsTabController: NSTabViewController {
    private let navigation: SettingsNavigation
    private let model: AppModel
    private var selecting = false
    private var ready = false
    init(model: AppModel, navigation: SettingsNavigation) { self.model = model; self.navigation = navigation; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func select(_ pane: SettingsPane) {
        guard let index = SettingsPane.allCases.firstIndex(of: pane) else { return }
        selecting = true
        if selectedTabViewItemIndex != index { selectedTabViewItemIndex = index }
        selecting = false
        ready = true
        fit(pane)
    }
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let name = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: name) else { return }
        if ready && !selecting { navigation.select(pane) }
        fit(pane)
    }
    func refreshSize() { fit(navigation.selectedPane) }
    private func fit(_ pane: SettingsPane) {
        guard let window = view.window else { return }
        window.title = pane.rawValue
        let height: CGFloat = switch pane {
        case .companion: 330
        case .access: model.permissions?.libraryStatus == .blocked || model.permissions?.libraryRegistrationInProgress == true ? 620 : navigation.intent != nil ? 620 : 500
        case .ai: model.settings.provider == .http ? 460 : 340
        case .data: 480
        case .about: 150
        }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 760)
        let size = NSSize(width: min(640, visible.width - 32), height: min(height, visible.height - 100))
        let top = window.frame.maxY
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(window.frame.width - frame.width) > 1 || abs(window.frame.height - frame.height) > 1 else { return }
        let proposed = NSRect(x: window.frame.minX, y: top - frame.height, width: frame.width, height: frame.height)
        window.setFrame(SettingsWindowGeometry.constrain(proposed, to: visible), display: true, animate: false)
    }
}

enum SettingsWindowGeometry {
    static func constrain(_ frame: NSRect, to visible: NSRect) -> NSRect {
        NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
            y: min(max(frame.minY, visible.minY), visible.maxY - frame.height), width: frame.width, height: frame.height)
    }
}
