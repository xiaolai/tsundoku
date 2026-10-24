import AppKit
import TsundokuCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let showItem = NSMenuItem()
    private let hideItem = NSMenuItem()
    private let launchItem = NSMenuItem()
    private let shortcutFeedback = NSMenuItem()
    private var feedbackTask: Task<Void, Never>?

    var onShowCompanion: (() -> Void)?
    var onHideCompanion: (() -> Void)?
    var onOpenLibrary: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onTestShortcut: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "eyeglasses",
            accessibilityDescription: "Tsundoku")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Tsundoku"
        // The enabled state is authoritative: NSMenu's automatic validation
        // would re-enable items the companion intentionally disabled.
        menu.autoenablesItems = false
        buildMenu()
        statusItem.menu = menu
        TsundokuDiagnostics.shared.event(
            "status_item_created",
            ["visible": statusItem.isVisible])
    }

    private func buildMenu() {
        showItem.title = "Show Companion"
        showItem.target = self
        showItem.action = #selector(showCompanion)
        menu.addItem(showItem)

        hideItem.title = "Hide Companion"
        hideItem.target = self
        hideItem.action = #selector(hideCompanion)
        menu.addItem(hideItem)
        menu.addItem(.separator())

        menu.addItem(
            item("Library…", #selector(openLibrary), key: "o"))
        menu.addItem(
            item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())

        launchItem.title = "Start at Login"
        launchItem.target = self
        launchItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchItem)

        menu.addItem(
            item("Test Shortcut…", #selector(testShortcut), key: ""))
        shortcutFeedback.isEnabled = false
        shortcutFeedback.isHidden = true
        menu.addItem(shortcutFeedback)
        menu.addItem(.separator())
        menu.addItem(item("Quit Tsundoku", #selector(quit), key: "q"))
    }

    private func item(
        _ title: String, _ action: Selector, key: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func update(
        panelOpen: Bool, readerPresent: Bool, launchAtLogin: Bool
    ) {
        showItem.isEnabled = readerPresent && !panelOpen
        hideItem.isEnabled = panelOpen
        launchItem.state = launchAtLogin ? .on : .off
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        launchItem.state = enabled ? .on : .off
    }

    func showShortcutFeedback(_ text: String, success: Bool?) {
        feedbackTask?.cancel()
        shortcutFeedback.title = text; shortcutFeedback.isHidden = false
        statusItem.button?.toolTip = text
        statusItem.button?.setAccessibilityValue(text)
        if let success {
            statusItem.button?.image = NSImage(systemSymbolName: success ? "checkmark.circle" : "exclamationmark.circle",
                accessibilityDescription: text)
            feedbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self else { return }
                self.statusItem.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Tsundoku")
                self.statusItem.button?.image?.isTemplate = true
                self.statusItem.button?.toolTip = "Tsundoku"
            }
        }
    }

    @objc private func showCompanion() { onShowCompanion?() }
    @objc private func hideCompanion() { onHideCompanion?() }
    @objc private func openLibrary() { onOpenLibrary?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin?() }
    @objc private func testShortcut() { onTestShortcut?() }
    @objc private func quit() { onQuit?() }
}
