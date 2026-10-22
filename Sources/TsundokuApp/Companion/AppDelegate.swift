import AppKit
import ApplicationServices
import SwiftUI
import TsundokuCore
import TsundokuUI

@main
enum TsundokuMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = CompanionSettingsStore()
    private let permissions = PermissionsModel()
    private var companion: CompanionController!
    private let watcher = ReaderWatcher()
    private let hotKey = GlobalHotKey()
    private var statusItem: StatusItemController!
    private var artifacts: ArtifactsWindowController!
    private var onboardingWindow: NSWindow?
    private var appModel: AppModel?
    private var loginStatus = ""
    private var hotKeyTestArmed = false
    private var appliedHotKey: CompanionHotKey?
    private var appliedLaunchAtLogin: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        startDiagnostics(arguments)
        applyAppearance(arguments)
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        artifacts = ArtifactsWindowController { [weak self] in
            self?.ensureAppModel() ?? AppModel()
        }
        companion = CompanionController(
            settings: settings, permissions: permissions,
            appModelFactory: { [weak self] in
                self?.ensureAppModel() ?? AppModel()
            })
        companion.statusProvider = { [weak self] in
            self?.shellStatus() ?? [:]
        }
        companion.onPresentationChange = { [weak self] _, _ in
            self?.updateStatusItem()
        }
        companion.start()

        watcher.onSnapshot = { [weak self] snapshot in
            self?.companion.readerChanged(snapshot)
        }
        watcher.onFullScreenChange = { [weak self] fullScreen in
            self?.companion.fullScreenChanged(fullScreen)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        configureStatusItem()
        configureHotKey()
        settings.onChange = { [weak self] settings in
            self?.applySettings(settings, userInitiated: true)
        }
        if arguments.contains("--register-login-item") {
            settings.settings.launchAtLogin = true
        }
        if arguments.contains("--unregister-login-item") {
            settings.settings.launchAtLogin = false
        }
        applySettings(settings.settings, userInitiated: false)

        if !arguments.contains("--shell-only") {
            applyForcedReader(arguments)
            watcher.start()
        }

        if permissions.missing,
            !arguments.contains("--no-onboarding")
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                [weak self] in
                self?.showOnboarding()
            }
        }

        runLaunchArguments(arguments)
        logLaunch(arguments)
    }

    func applicationWillTerminate(_ notification: Notification) {
        companion?.writeState()
        // Stopping the watcher emits a nil snapshot, which would overwrite the
        // state this run is meant to leave behind as evidence.
        watcher.onSnapshot = nil
        watcher.onFullScreenChange = nil
        watcher.stop()
        companion?.stop()
        hotKey.uninstall()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        TsundokuDiagnostics.shared.event("terminate")
        TsundokuDiagnostics.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    /// Re-opening the app (Launchpad, `open`) shows the artifacts manager.
    /// The companion panel alone does not count as the library being open.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if artifacts?.isVisible != true {
            openLibrary()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissions.refresh()
        refreshLoginItemStatus()
        companion?.writeState()
    }

    /// The user may approve the login item in System Settings while the app
    /// runs; the cached status must follow the real service state.
    private func refreshLoginItemStatus() {
        let status = LoginItem.statusText
        guard status != settings.loginItemStatus else { return }
        loginStatus = status
        settings.loginItemStatus = status
        updateStatusItem()
        TsundokuDiagnostics.shared.event(
            "login_item_refreshed", ["status": status])
    }

    // MARK: - Model

    private func ensureAppModel() -> AppModel {
        if let appModel { return appModel }
        let model = AppModel()
        model.companionSettings = settings
        model.permissions = permissions
        model.openCompanion = { [weak self, weak model] in
            guard let self, let model else { return }
            guard self.companion.canShowPanel else {
                model.post(
                    "Open a book in Kindle or Apple Books first. The companion "
                        + "appears only while a reader window is focused.")
                return
            }
            self.companion.showPanel()
        }
        appModel = model
        TsundokuDiagnostics.shared.event("app_model_created")
        return model
    }

    // MARK: - Services

    private func configureStatusItem() {
        statusItem = StatusItemController()
        statusItem.onShowCompanion = { [weak self] in
            self?.companion.showPanel()
        }
        statusItem.onHideCompanion = { [weak self] in
            self?.companion.closePanel()
        }
        statusItem.onOpenLibrary = { [weak self] in
            self?.openLibrary()
        }
        statusItem.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        statusItem.onOpenOnboarding = { [weak self] in
            self?.showOnboarding()
        }
        statusItem.onToggleLaunchAtLogin = { [weak self] in
            guard let self else { return }
            self.settings.settings.launchAtLogin.toggle()
        }
        statusItem.onTestShortcut = { [weak self] in
            self?.armHotKeyTest()
        }
        statusItem.onQuit = {
            NSApp.terminate(nil)
        }
        updateStatusItem()
    }

    private func configureHotKey() {
        hotKey.onPress = { [weak self] in
            guard let self else { return }
            let wasArmed = self.hotKeyTestArmed
            self.companion.togglePanel()
            guard wasArmed else { return }
            self.hotKeyTestArmed = false
            self.settings.hotKeyTestNote = "The shortcut reached Tsundoku."
            TsundokuDiagnostics.shared.event("hotkey_test_fired")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showHotKeyTestResult()
            }
        }
    }

    private func showHotKeyTestResult() {
        let alert = NSAlert()
        alert.messageText = "Shortcut received"
        alert.informativeText =
            "Tsundoku received \(settings.settings.hotKey.displayName) and "
            + (companion.isPanelOpen
                ? "opened the companion."
                : "ran the action, but no reader was available.")
            + "\n\nIf the other app also reacted, macOS delivered the "
            + "shortcut to both; no app can detect that in advance."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func applySettings(
        _ new: CompanionSettings, userInitiated: Bool
    ) {
        guard companion != nil, statusItem != nil else { return }
        if appliedHotKey != new.hotKey {
            let status = hotKey.install(new.hotKey)
            settings.hotKeyConflict = status != noErr
            settings.hotKeyStatus =
                status == noErr
                ? "Registered: \(new.hotKey.displayName)"
                : "Registration failed (OSStatus \(status)). Choose another "
                    + "shortcut."
            appliedHotKey = new.hotKey
            TsundokuDiagnostics.shared.event(
                "settings_applied",
                [
                    "hotkey_status": Int(status),
                    "hotkey": new.hotKey.displayName,
                ])
        }
        if appliedLaunchAtLogin != new.launchAtLogin {
            loginStatus = LoginItem.setEnabled(
                new.launchAtLogin, openApproval: userInitiated)
            settings.loginItemStatus = loginStatus
            appliedLaunchAtLogin = new.launchAtLogin
            TsundokuDiagnostics.shared.event(
                "login_item_applied", ["status": loginStatus])
        }
        companion.settingsChanged(new)
        updateStatusItem()
    }

    private func updateStatusItem() {
        statusItem?.update(
            panelOpen: companion?.isPanelOpen ?? false,
            readerPresent: companion?.canShowPanel ?? false,
            launchAtLogin: settings.settings.launchAtLogin)
    }

    private func armHotKeyTest() {
        let alert = NSAlert()
        alert.messageText = "Test \(settings.settings.hotKey.displayName)"
        alert.informativeText =
            "Click I'm Ready, then press the shortcut while another app is "
            + "frontmost. Tsundoku will report whether it received the key. "
            + "If the other app also reacts, macOS delivered it to both and "
            + "neither app can tell."
        alert.addButton(withTitle: "I'm Ready")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hotKeyTestArmed = true
        settings.hotKeyTestNote =
            "Press \(settings.settings.hotKey.displayName) now while "
            + "another app is frontmost."
        TsundokuDiagnostics.shared.event(
            "hotkey_test_armed",
            ["shortcut": settings.settings.hotKey.displayName])
    }

    // MARK: - Windows

    private func openLibrary(useRequestedSection: Bool = false) {
        // The launch argument applies once, on the launch open. The Library
        // menu action and reopen events must always show the library.
        let section =
            useRequestedSection ? (requestedSection ?? .library) : .library
        artifacts.show(section: section, importLibrary: true)
        if let model = artifacts.modelIfCreated() {
            model.startLivePolling()
        }
    }

    private var requestedSection: AppModel.Section? {
        guard let index = CommandLine.arguments.firstIndex(of: "--section"),
            CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        let raw = CommandLine.arguments[index + 1]
        if let section = AppModel.Section(rawValue: raw) {
            return section
        }
        if raw == "annotations" { return .highlights }
        return nil
    }

    private func openSettings() {
        artifacts.show(section: .settings, importLibrary: false)
    }

    private func showOnboarding() {
        permissions.refresh()
        if let onboardingWindow {
            onboard(onboardingWindow)
            return
        }
        let view = CompanionOnboardingView(
            permissions: permissions, settings: settings,
            onOpenLoginItemSettings: { LoginItem.openSettings() },
            onClose: { [weak self] in self?.closeOnboarding() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Tsundoku"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        TsundokuDiagnostics.shared.event(
            "onboarding_shown",
            [
                "accessibility": permissions.accessibility,
                "screen_recording": permissions.screenRecording,
            ])
        onboard(window)
    }

    private func onboard(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        permissions.refresh()
        TsundokuDiagnostics.shared.event(
            "onboarding_closed",
            [
                "accessibility": permissions.accessibility,
                "screen_recording": permissions.screenRecording,
            ])
    }

    @objc private func spaceChanged() {
        companion?.spaceChanged()
    }

    @objc private func settingsFromMenu() {
        openSettings()
    }

    // MARK: - Launch arguments

    private func startDiagnostics(_ arguments: [String]) {
        guard
            let index = arguments.firstIndex(of: "--diagnostics"),
            arguments.indices.contains(index + 1)
        else { return }
        TsundokuDiagnostics.shared.start(path: arguments[index + 1])
    }

    private func applyAppearance(_ arguments: [String]) {
        guard
            let index = arguments.firstIndex(of: "--appearance"),
            arguments.indices.contains(index + 1)
        else { return }
        switch arguments[index + 1] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    private func applyForcedReader(_ arguments: [String]) {
        guard
            let index = arguments.firstIndex(of: "--reader"),
            arguments.indices.contains(index + 1)
        else { return }
        switch arguments[index + 1].lowercased() {
        case "kindle": watcher.forcedKind = .kindle
        case "books", "applebooks", "apple-books":
            watcher.forcedKind = .appleBooks
        default: break
        }
    }

    private func runLaunchArguments(_ arguments: [String]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            [weak self] in
            guard let self else { return }
            if arguments.contains("--open-library") {
                self.openLibrary(useRequestedSection: true)
            } else if arguments.contains("--open-settings") {
                self.openSettings()
            }
            if arguments.contains("--show-companion")
                || arguments.contains("--demo-panel")
            {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.companion.showPanel()
                }
            }
            if arguments.contains("--demo-capture") {
                self.openLibrary()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.appModel?.startCapture(pages: 2)
                }
            }
            if arguments.contains("--demo-notice") {
                self.openLibrary()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.appModel?.post(
                        "Imported 2,923 books and 7,148 annotations.")
                }
            }
            if arguments.contains("--track-reading") {
                self.openLibrary()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if self.appModel?.trackedBookID == nil {
                        self.appModel?.toggleTracking()
                    }
                }
            }
            if arguments.contains("--window-debug") {
                self.logWindows("window_debug")
            }
        }

        if let index = arguments.firstIndex(of: "--duration"),
            arguments.indices.contains(index + 1),
            let seconds = Double(arguments[index + 1])
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                self.logWindows("duration_elapsed")
                self.companion.writeState()
                TsundokuDiagnostics.shared.event("duration_elapsed")
                NSApp.terminate(nil)
            }
        }
    }

    private func logLaunch(_ arguments: [String]) {
        TsundokuDiagnostics.shared.event(
            "launch",
            [
                "bundle_path": Bundle.main.bundlePath,
                "bundle_id": Bundle.main.bundleIdentifier ?? "",
                "arguments": arguments,
                "parent_pid": Int(getppid()),
                "activation_policy": NSApp.activationPolicy().rawValue,
                "app_active": NSApp.isActive,
                "accessibility": AXIsProcessTrusted(),
                "screen_recording": CGPreflightScreenCaptureAccess(),
                "login_item_status": LoginItem.statusText,
                "app_windows": NSApp.windows.count,
            ])
        logWindows("after_launch")
        companion.writeState()
    }

    private func logWindows(_ reason: String) {
        let rows = NSApp.windows.map { window in
            [
                "class": String(describing: type(of: window)),
                "title": window.title,
                "visible": window.isVisible,
                "is_panel": window is NSPanel,
                "number": window.windowNumber,
                "level": window.level.rawValue,
            ] as [String: Any]
        }
        TsundokuDiagnostics.shared.event(
            "app_windows",
            [
                "reason": reason,
                "count": rows.count,
                "activation_policy": NSApp.activationPolicy().rawValue,
                "windows": rows,
            ])
    }

    private func shellStatus() -> [String: Any] {
        [
            "hotkey_status": Int(hotKey.registrationStatus),
            "hotkey_registered": hotKey.isRegistered,
            "hotkey_shortcut": settings.settings.hotKey.displayName,
            "hotkey_conflict": settings.hotKeyConflict,
            "login_item": loginStatus.isEmpty
                ? LoginItem.statusText : loginStatus,
            "launch_at_login": settings.settings.launchAtLogin,
            "artifacts_window_visible": artifacts?.isVisible ?? false,
            "app_model_created": appModel != nil,
            "onboarding_visible": onboardingWindow?.isVisible ?? false,
            "diagnostics_dropped_events":
                TsundokuDiagnostics.shared.droppedEventCount,
            "diagnostics_last_error":
                TsundokuDiagnostics.shared.lastError ?? "",
        ]
    }

    // MARK: - Main menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About Tsundoku",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(settingsFromMenu),
            keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Tsundoku",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        for (title, selector, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            editMenu.addItem(
                withTitle: title, action: selector, keyEquivalent: key)
        }

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
