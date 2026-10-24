import AppKit
import ApplicationServices
import Carbon
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let settings = CompanionSettingsStore()
    private let permissions = PermissionsModel()
    private var companion: CompanionController!
    private let watcher = ReaderWatcher()
    private let hotKey = GlobalHotKey()
    private var statusItem: StatusItemController!
    private var artifacts: ArtifactsWindowController!
    private let settingsNavigation = SettingsNavigation()
    private var settingsWindow: SettingsWindowController?
    private var appModel: AppModel?
    private var loginStatus = ""
    private var hotKeyTestArmed = false
    private var appliedHotKey: CompanionHotKey?
    private var appliedLaunchAtLogin: Bool?
    private var hotKeyTestTimeout: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        startDiagnostics(arguments)
        permissions.onLibraryAccessReady = { [weak self] in
            guard let self else { return }
            self.ensureAppModel().requestLibraryImport()
        }
        permissions.onRelaunchRequested = { [weak self] in
            guard self?.appModel?.capturePhase != .running else {
                throw NSError(domain: "Tsundoku", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Finish or stop the current capture first"])
            }
            guard self?.appModel?.isImporting != true else {
                throw NSError(domain: "Tsundoku", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Wait for the current library import to finish"])
            }
            if self?.permissions.accessResumeIntent == .capture { self?.ensureAppModel().persistCaptureAccessForRelaunch() }
            try ApplicationRelaunch.schedule(appURL: Bundle.main.bundleURL,
                processID: ProcessInfo.processInfo.processIdentifier,
                arguments: SettingsLaunchPolicy.relaunchArguments(Array(CommandLine.arguments.dropFirst())))
            NSApp.terminate(nil)
        }
        permissions.onRelaunchFailed = { [weak self] in self?.appModel?.discardCaptureAccessRelaunch() }
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
        if !arguments.contains("--no-system-integrations") { configureHotKey() }
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

        settings.onTestShortcut = { [weak self] in self?.armHotKeyTest() }
        settingsNavigation.onCancelSetup = { [weak self] intent in self?.ensureAppModel().cancelAccessTask(intent: intent) }
        settingsNavigation.onIntentReplaced = { [weak self] previous in
            if previous == .capture { self?.appModel?.cancelAccessTask(intent: .capture) }
        }
        settingsNavigation.onReturnToTask = { [weak self] intent, close in
            guard let self else { return }
            if close { self.settingsWindow?.close() }
            switch intent {
            case .library:
                self.artifacts.show(importLibrary: false)
            case .capture:
                self.ensureAppModel().returnToCapture()
                self.artifacts.show(importLibrary: false)
            case .companion:
                if self.watcher.focusReader() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.companion.showPanel() }
                } else {
                    self.ensureAppModel().post("Open a book in Kindle or Apple Books, then use the companion shortcut.")
                    self.artifacts.show(importLibrary: false)
                }
            }
        }
        let resumeFocus = permissions.accessResumeFocus ?? .library
        let resumeIntent = permissions.accessResumeIntent ?? .library
        let resumeAccess = permissions.consumeAccessResume()
        if (arguments.contains("--show-onboarding") || resumeAccess), !arguments.contains("--no-onboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings(SettingsRoute(pane: .access, focus: resumeFocus,
                    intent: resumeIntent))
            }
        } else if SettingsLaunchPolicy.shouldPresentLibrary(
            firstUse: !UserDefaults.standard.bool(forKey: "app.hasPresentedLibrary"), arguments: arguments,
            isLoginLaunch: NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil) {
            UserDefaults.standard.set(true, forKey: "app.hasPresentedLibrary")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openLibrary(importLibrary: false)
            }
        }

        runLaunchArguments(arguments)
        logLaunch(arguments)
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissions.prepareForTermination()
        settingsWindow?.prepareForTermination()
        companion?.writeState()
        // Stopping the watcher emits a nil snapshot, which would overwrite the
        // state this run is meant to leave behind as evidence.
        watcher.onSnapshot = nil
        watcher.onFullScreenChange = nil
        watcher.stop()
        companion?.stop()
        hotKeyTestTimeout?.cancel()
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
        permissions.applicationBecameActive()
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
        let model = AppModel(deferReaderRecovery: true)
        model.companionSettings = settings
        model.permissions = permissions
        model.openCompanion = { [weak self, weak model] in
            guard let self, let model else { return }
            if !self.permissions.accessibility {
                self.openSettings(SettingsRoute(pane: .access, focus: .accessibility, intent: .companion))
                return
            }
            guard self.companion.canShowPanel else {
                model.post(
                    "Open a book in Kindle or Apple Books first. The companion "
                        + "appears only while a reader window is focused.")
                return
            }
            self.companion.showPanel()
        }
        model.openSettingsWindow = { [weak self] route in self?.openSettings(route) }
        model.openSavedNotesWindow = { [weak self] in
            guard let self else { return }
            self.artifacts.show(section: .highlights, importLibrary: false)
            self.appModel?.showSavedAINotes = true
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
        statusItem.onToggleLaunchAtLogin = { [weak self] in
            guard let self else { return }
            self.settings.settings.launchAtLogin.toggle()
        }
        statusItem.onTestShortcut = { [weak self] in
            self?.settings.testShortcut()
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
            self.permissions.refresh()
            if self.permissions.accessibility {
                self.companion.togglePanel()
            } else {
                self.openSettings(SettingsRoute(pane: .access, focus: .accessibility, intent: .companion))
            }
            guard wasArmed else { return }
            self.hotKeyTestArmed = false
            self.hotKeyTestTimeout?.cancel()
            self.settings.hotKeyTestNote = "Shortcut received. If another app also reacts, choose a different shortcut."
            self.statusItem.showShortcutFeedback("Shortcut received", success: true)
            TsundokuDiagnostics.shared.event("hotkey_test_fired")
        }
    }

    private func applySettings(
        _ new: CompanionSettings, userInitiated: Bool
    ) {
        guard companion != nil, statusItem != nil else { return }
        guard !CommandLine.arguments.contains("--no-system-integrations") else { return }
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
        hotKeyTestTimeout?.cancel()
        guard hotKey.isRegistered else {
            settings.hotKeyTestNote = "The shortcut is not registered. Choose another shortcut and try again."
            statusItem.showShortcutFeedback("Shortcut unavailable", success: false)
            return
        }
        hotKeyTestArmed = true
        settings.hotKeyTestNote = "Switch to another app and press \(settings.settings.hotKey.displayName)."
        statusItem.showShortcutFeedback("Press \(settings.settings.hotKey.displayName) to test", success: nil)
        TsundokuDiagnostics.shared.event("hotkey_test_armed")
        hotKeyTestTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.hotKeyTestArmed else { return }
            self.hotKeyTestArmed = false
            self.settings.hotKeyTestNote = "No shortcut received. Check for a conflicting shortcut and try again."
            self.statusItem.showShortcutFeedback("No shortcut received", success: false)
        }
    }

    // MARK: - Windows

    private func openLibrary(useRequestedSection: Bool = false, importLibrary: Bool = true) {
        let section = useRequestedSection ? requestedSection : nil
        artifacts.show(section: section,
            importLibrary: importLibrary && !CommandLine.arguments.contains("--no-import"))
        if let model = artifacts.modelIfCreated(), !CommandLine.arguments.contains("--shell-only") { model.startLivePolling() }
    }

    private var requestsLegacySettings: Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--section"), args.indices.contains(index + 1) else { return false }
        return args[index + 1] == "settings"
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

    /// Explicit synthetic mode for native UI gates. Never reads or writes the
    /// real Keychain and never connects to a provider. Normal launches use the
    /// production state object.
    private func providerStateForTesting() -> ProviderSettingsState? {
        let arguments = CommandLine.arguments
        guard arguments.contains("--settings-fixture"), arguments.contains("--no-system-integrations") else { return nil }
        var saves = 0
        return ProviderSettingsState(loadKey: { "fixture-key" }, saveKey: { _ in
            saves += 1
            return saves == 1 ? -1 : 0
        }, connectionTest: { _ in "Connected · Fixture" })
    }

    private func openSettings(_ route: SettingsRoute? = nil) {
        settingsNavigation.open(route, wasVisible: settingsWindow?.isVisible == true)
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: ensureAppModel(), navigation: settingsNavigation, providerState: providerStateForTesting())
        }
        settingsWindow?.present()
        TsundokuDiagnostics.shared.event("settings_shown", ["pane": settingsNavigation.selectedPane.rawValue])
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
            if arguments.contains("--open-library"), !self.requestsLegacySettings {
                self.openLibrary(useRequestedSection: true)
            } else if arguments.contains("--open-settings") || self.requestsLegacySettings {
                let index = arguments.firstIndex(of: "--settings-pane")
                let pane = index.flatMap { arguments.indices.contains($0 + 1) ? SettingsPane(rawValue: arguments[$0 + 1]) : nil }
                self.openSettings(pane.map { SettingsRoute(pane: $0) })
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
            "settings_visible": settingsWindow?.isVisible ?? false,
            "settings_pane": settingsNavigation.selectedPane.rawValue,
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

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        addBrowserItem("Open Book Annotations", command: "open", key: "o", to: fileMenu)
        let importItem = NSMenuItem(title: "Import Library", action: #selector(importFromMenu), keyEquivalent: "r")
        importItem.target = self
        fileMenu.addItem(importItem)
        addBrowserItem("Export Annotation Results…", command: "export", key: "e", to: fileMenu)
        addBrowserItem("Saved AI Notes…", command: "aiNotes", key: "", to: fileMenu)

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        for (title, selector, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(copyFromMenu), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(selectAllFromMenu), "a"),
        ] {
            let item = editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            if title == "Copy" || title == "Select All" { item.target = self }
        }
        editMenu.addItem(.separator())
        addBrowserItem("Find…", command: "find", key: "f", to: editMenu)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        addBrowserItem("Cards", command: "cards", key: "1", to: viewMenu)
        addBrowserItem("List", command: "list", key: "2", to: viewMenu)
        viewMenu.addItem(.separator())
        addBrowserItem("Show / Hide Sidebar", command: "sidebar", key: "", to: viewMenu)
        addBrowserItem("Show / Hide Inspector", command: "inspector", key: "i", to: viewMenu)
        addBrowserItem("Back to Books", command: "back", key: "[", to: viewMenu)

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

    private func addBrowserItem(_ title: String, command: String, key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(browserFromMenu(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = command
        menu.addItem(item)
    }

    @objc private func browserFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        TsundokuDiagnostics.shared.event("browser_menu_command", [
            "command": command, "window": NSApp.keyWindow?.identifier?.rawValue ?? "none",
        ])
        if command == "aiNotes" { ensureAppModel().openSavedNotesWindow?(); return }
        if NSApp.keyWindow?.identifier?.rawValue == "TsundokuInspector" {
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .tsundokuBrowserCommand, object: NSApp.keyWindow,
                                        userInfo: ["command": command])
    }

    @objc private func importFromMenu() { ensureAppModel().importLibrary() }

    @objc private func selectAllFromMenu() { textOrBrowserAction(#selector(NSText.selectAll(_:)), command: "selectAll") }
    @objc private func copyFromMenu() { textOrBrowserAction(#selector(NSText.copy(_:)), command: "copy") }

    private func textOrBrowserAction(_ action: Selector, command: String) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(action, to: nil, from: nil)
        } else {
            NotificationCenter.default.post(name: .tsundokuBrowserCommand, object: NSApp.keyWindow,
                                            userInfo: ["command": command])
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(browserFromMenu(_:)), let command = item.representedObject as? String {
            if command == "aiNotes" { return true }
            let keyID = NSApp.keyWindow?.identifier?.rawValue
            let browserActive = keyID == "TsundokuLibrary" || (keyID == "TsundokuInspector" && NSApp.mainWindow?.identifier?.rawValue == "TsundokuLibrary")
            guard browserActive, let model = appModel else { return false }
            let annotations = model.section == .highlights || (model.section == .library && model.bookWorkspaceID != nil)
            switch command {
            case "cards", "list", "export": return annotations
            case "find", "inspector": return model.section == .library || model.section == .highlights
            case "open": return model.section == .library && model.bookWorkspaceID == nil && model.selectedBookID != nil
            case "back": return model.section == .library && model.bookWorkspaceID != nil
            default: return true
            }
        }
        if item.action == #selector(importFromMenu) { return appModel?.isImporting != true }
        return true
    }
}
