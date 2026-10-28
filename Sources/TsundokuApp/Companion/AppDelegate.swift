import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI
import TsundokuCore
import TsundokuUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let settings = CompanionSettingsStore()
    private let permissions = PermissionsModel()
    private var companion: CompanionController!
    private let watcher = ReaderWatcher()
    private let hotKey = GlobalHotKey()
    let settingsNavigation = SettingsNavigation()
    let providerState: ProviderSettingsState
    let updateChecker = UpdateController()
    let windowBridge = SceneWindowBridge()

    @Published private(set) var appModel: AppModel?
    @Published private(set) var menuRevision = 0
    @Published private(set) var feedbackSymbol = "eyeglasses"
    @Published private(set) var feedbackNote = ""
    @Published private(set) var panelOpen = false
    @Published private(set) var readerPresent = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var libraryVisible = false
    @Published private(set) var settingsVisible = false

    private var cancellables: Set<AnyCancellable> = []
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var loginStatus = ""
    private var hotKeyTestArmed = false
    private var appliedHotKey: CompanionHotKey?
    private var appliedLaunchAtLogin: Bool?
    private var appliedMatchTypography: Bool?
    private var appliedMatchTheme: Bool?
    private var hotKeyTestTimeout: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    /// Set when this delegate opened Settings with a route; the Settings scene
    /// then keeps that pane instead of resetting to the ordinary pane.
    private var settingsPresentationRouted = false

    override init() {
        let arguments = CommandLine.arguments
        if arguments.contains("--settings-fixture"),
            arguments.contains("--no-system-integrations")
        {
            var saves = 0
            providerState = ProviderSettingsState(
                loadKey: { _ in "fixture-key" },
                saveKey: { _, _ in
                    saves += 1
                    return saves == 1 ? -1 : 0
                },
                // The fixture writes nothing, so it must delete nothing: the
                // default would remove the reader's real legacy Keychain key.
                forgetLegacyKey: {},
                connectionTest: { _ in "Connected · Fixture" })
        } else {
            providerState = ProviderSettingsState()
        }
        super.init()
    }

    /// Set before the first window exists so Launch Services never shows a
    /// Dock icon for this menu-bar app.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        startDiagnostics(arguments)
        // The gate measures a window of its own and exits; none of the
        // menu-bar app's reader tracking or companion setup applies.
        if arguments.contains("--typography-gate") {
            TypographyGate.run()
            return
        }
        if !arguments.contains("--no-update-check"),
            !arguments.contains("--settings-fixture"),
            !arguments.contains("--shell-only")
        {
            updateChecker.start()
        }
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

        companion = CompanionController(
            settings: settings, permissions: permissions,
            appModelFactory: { [weak self] in
                self?.ensureAppModel() ?? AppModel()
            })
        companion.statusProvider = { [weak self] in
            self?.shellStatus() ?? [:]
        }
        companion.onPresentationChange = { [weak self] _, _ in
            self?.refreshStatusMenu()
        }
        companion.start()

        // Update state is owned by its controller, not by AppDelegate's own
        // published fields; forward it so the status menu refreshes.
        updateChecker.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.menuRevision += 1 }
            }
            .store(in: &cancellables)

        watcher.onSnapshot = { [weak self] snapshot in
            self?.companion.readerChanged(snapshot)
        }
        watcher.onFullScreenChange = { [weak self] fullScreen in
            self?.companion.fullScreenChanged(fullScreen)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowStateChanged(_:)),
                name: name, object: nil)
        }

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
            if close { self.closeSettingsWindow() }
            switch intent {
            case .library:
                self.openLibrary(importLibrary: false)
            case .capture:
                self.ensureAppModel().returnToCapture()
                self.openLibrary(importLibrary: false)
            case .companion:
                if self.watcher.focusReader() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.companion.showPanel() }
                } else {
                    self.ensureAppModel().post("Open a book in Kindle or Apple Books, then use the companion shortcut.")
                    self.openLibrary(importLibrary: false)
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

        refreshStatusMenu()
        runLaunchArguments(arguments)
        logLaunch(arguments)
    }

    func applicationWillTerminate(_ notification: Notification) {
        providerState.invalidateTest()
        permissions.prepareForTermination()
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
        if !libraryVisible {
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
        refreshStatusMenu()
        TsundokuDiagnostics.shared.event(
            "login_item_refreshed", ["status": status])
    }

    // MARK: - Model

    @discardableResult
    func ensureAppModel() -> AppModel {
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
        model.openCompanionChat = { [weak self, weak model] pending in
            guard let self, let model else { return }
            if !self.permissions.accessibility {
                self.openSettings(SettingsRoute(pane: .access, focus: .accessibility, intent: .companion))
                return
            }
            guard self.companion.canShowPanel else {
                model.post(
                    "Open the book in the reader first, then ask from Chats.")
                return
            }
            if let conversationID = pending.conversationID {
                self.companion.showConversation(
                    bookID: pending.bookID, source: pending.bookSource,
                    conversationID: conversationID)
            } else {
                self.companion.showNewChat(
                    bookID: pending.bookID, source: pending.bookSource)
            }
        }
        companion.messageSink = { [weak model] message in
            model?.post(message)
        }
        model.openSettingsWindow = { [weak self] route in self?.openSettings(route) }
        model.openLibraryWindow = { [weak self] in self?.openLibrary() }
        model.openSavedNotesWindow = { [weak self] in
            self?.showSavedNotes()
        }
        appModel = model
        model.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.menuRevision += 1 }
            }
            .store(in: &cancellables)
        TsundokuDiagnostics.shared.event("app_model_created")
        return model
    }

    // MARK: - Status menu

    func showCompanion() { companion?.showPanel() }
    func hideCompanion() { companion?.closePanel() }
    func setLaunchAtLogin(_ enabled: Bool) {
        settings.settings.launchAtLogin = enabled
    }
    func testShortcut() { settings.testShortcut() }

    private func refreshStatusMenu() {
        let nextPanel = companion?.isPanelOpen ?? false
        let nextReader = companion?.canShowPanel ?? false
        let nextLaunch = settings.settings.launchAtLogin
        guard nextPanel != panelOpen || nextReader != readerPresent
            || nextLaunch != launchAtLogin
        else { return }
        panelOpen = nextPanel
        readerPresent = nextReader
        launchAtLogin = nextLaunch
        menuRevision += 1
    }

    // MARK: - Services

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
            self.showShortcutFeedback("Shortcut received", success: true)
            TsundokuDiagnostics.shared.event("hotkey_test_fired")
        }
    }

    private func applySettings(
        _ new: CompanionSettings, userInitiated: Bool
    ) {
        guard companion != nil else { return }
        // Only the two match settings affect the sample; refreshing on every
        // settings write would cancel a pending sample for nothing.
        let styleChanged =
            (appliedMatchTypography != new.matchReaderTypography)
            || (appliedMatchTheme != new.matchReaderTheme)
        if appliedMatchTypography != nil, styleChanged {
            companion?.refreshStyleForCurrentReader()
        }
        appliedMatchTypography = new.matchReaderTypography
        appliedMatchTheme = new.matchReaderTheme
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
        refreshStatusMenu()
    }

    /// Mirrors the old status item's feedback: a symbol change for a definite
    /// result, and a menu row that keeps the note until the next test.
    private func showShortcutFeedback(_ text: String, success: Bool?) {
        feedbackTask?.cancel()
        feedbackNote = text
        if let success {
            feedbackSymbol = success ? "checkmark.circle" : "exclamationmark.circle"
            feedbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.feedbackSymbol = "eyeglasses"
            }
        }
    }

    private func armHotKeyTest() {
        hotKeyTestTimeout?.cancel()
        guard hotKey.isRegistered else {
            settings.hotKeyTestNote = "The shortcut is not registered. Choose another shortcut and try again."
            showShortcutFeedback("Shortcut unavailable", success: false)
            return
        }
        hotKeyTestArmed = true
        settings.hotKeyTestNote = "Switch to another app and press \(settings.settings.hotKey.displayName)."
        showShortcutFeedback("Press \(settings.settings.hotKey.displayName) to test", success: nil)
        TsundokuDiagnostics.shared.event("hotkey_test_armed")
        hotKeyTestTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.hotKeyTestArmed else { return }
            self.hotKeyTestArmed = false
            self.settings.hotKeyTestNote = "No shortcut received. Check for a conflicting shortcut and try again."
            self.showShortcutFeedback("No shortcut received", success: false)
        }
    }

    // MARK: - Windows

    /// The status item's "Library…" opens the library itself, not whatever
    /// section or book workspace happened to be open last.
    func showLibrarySection() {
        let model = ensureAppModel()
        model.section = .library
        model.bookWorkspaceID = nil
        openLibrary()
    }

    func openLibrary(useRequestedSection: Bool = false, importLibrary: Bool = true) {
        let section = useRequestedSection ? requestedSection : nil
        let model = ensureAppModel()
        if let section { model.section = section }
        model.activate(
            importLibrary: importLibrary
                && !CommandLine.arguments.contains("--no-import"))
        windowBridge.openLibrary()
        NSApp.activate(ignoringOtherApps: true)
        if !CommandLine.arguments.contains("--shell-only") {
            model.startLivePolling()
        }
    }

    /// The SwiftUI `Window` scene owns creation and ordering; this records the
    /// hosting window so menu enablement and the macOS 27 content rounding can
    /// use the same stable identity the old controller assigned.
    private static let libraryWindowNotifications = [
        NSWindow.willCloseNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didBecomeMainNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
    ]

    private func removeLibraryWindowObservers(_ window: NSWindow) {
        for name in Self.libraryWindowNotifications {
            NotificationCenter.default.removeObserver(
                self, name: name, object: window)
        }
    }

    func configureLibraryWindow(_ window: NSWindow?) {
        guard let window else { return }
        if libraryWindow !== window {
            if let previous = libraryWindow {
                removeLibraryWindowObservers(previous)
            }
            libraryWindow = window
            window.identifier = NSUserInterfaceItemIdentifier(
                TsundokuWindowIdentifier.library)
            window.setFrameAutosaveName("TsundokuArtifacts")
            // The SwiftUI Window scene keeps full-size content but gives the
            // titlebar an opaque backing. The library's edge-to-edge layout
            // needs the old transparent titlebar and clear window behind it.
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            TsundokuDiagnostics.shared.event(
                "library_window_configured",
                [
                    "style_mask": window.styleMask.rawValue,
                    "full_size_content": window.styleMask
                        .contains(.fullSizeContentView),
                    "titlebar_transparent": window.titlebarAppearsTransparent,
                    "title_visibility": window.titleVisibility.rawValue,
                    "titlebar_height": window.frame.height
                        - window.contentLayoutRect.height,
                ])
            let observers: [(NSNotification.Name, Selector)] = [
                (NSWindow.willCloseNotification, #selector(libraryWindowWillClose(_:))),
                (NSWindow.didBecomeKeyNotification, #selector(libraryWindowBecameVisible(_:))),
                (NSWindow.didBecomeMainNotification, #selector(libraryWindowBecameVisible(_:))),
                (NSWindow.didEnterFullScreenNotification, #selector(libraryWindowDidEnterFullScreen(_:))),
                (NSWindow.didExitFullScreenNotification, #selector(libraryWindowDidExitFullScreen(_:))),
            ]
            for (name, selector) in observers {
                NotificationCenter.default.addObserver(
                    self, selector: selector, name: name, object: window)
            }
        }
        roundLibraryContent(of: window)
        // The scene's content is configured before SwiftUI orders the window
        // front. Defer the observable publication out of the update
        // transaction and verify the sampled window is still current.
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.libraryWindow === window else { return }
            self.setLibraryVisible(window.isVisible)
        }
    }

    @objc private func libraryWindowBecameVisible(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        setLibraryVisible(window.isVisible)
    }

    func setLibraryVisible(_ visible: Bool) {
        // `WindowConfigurator` reports on every SwiftUI update. Publishing an
        // unchanged value here would re-render, report again, and spin.
        guard visible != libraryVisible else { return }
        libraryVisible = visible
        updateActivationPolicy()
        menuRevision += 1
        guard visible, let model = appModel else { return }
        TsundokuDiagnostics.shared.event(
            "artifacts_window_shown",
            [
                "section": model.section.rawValue,
                "window_visible": true,
                "activation_policy": NSApp.activationPolicy().rawValue,
            ])
    }

    @objc private func libraryWindowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            removeLibraryWindowObservers(window)
        }
        libraryVisible = false
        libraryWindow = nil
        appModel?.stopLivePolling()
        updateActivationPolicy()
        menuRevision += 1
        TsundokuDiagnostics.shared.event("artifacts_window_closed")
    }

    @objc private func libraryWindowDidEnterFullScreen(
        _ notification: Notification
    ) {
        guard let window = notification.object as? NSWindow else { return }
        window.contentView?.layer?.cornerRadius = 0
        window.contentView?.layer?.masksToBounds = false
    }

    @objc private func libraryWindowDidExitFullScreen(
        _ notification: Notification
    ) {
        roundLibraryContent(of: notification.object as? NSWindow)
    }

    /// macOS 27 draws a SwiftUI full-size window square, to the screen edge.
    /// The old `WindowGroup` needed the same correction; earlier systems draw
    /// their own shape and are left alone.
    private func roundLibraryContent(of window: NSWindow?) {
        guard #available(macOS 27.0, *), let window else { return }
        guard
            !window.styleMask.contains(.fullScreen),
            window.styleMask.contains(.fullSizeContentView),
            let content = window.contentView
        else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
    }

    func configureSettingsWindow(_ window: NSWindow?) {
        guard let window, settingsWindow !== window else { return }
        settingsWindow = window
        window.identifier = NSUserInterfaceItemIdentifier(
            TsundokuWindowIdentifier.settings)
        // The Settings scene titles the window from the selected pane; the
        // gates identify it by the five pane tabs instead of a fixed title.
        TsundokuDiagnostics.shared.event(
            "settings_window_configured",
            [
                "title": window.title,
                "style_mask": window.styleMask.rawValue,
                "frame": [
                    "width": window.frame.width,
                    "height": window.frame.height,
                ],
            ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window)
    }

    func setSettingsVisible(_ visible: Bool, dismiss: (() -> Void)? = nil) {
        windowBridge.setDismissSettings(visible ? dismiss : nil)
        guard visible != settingsVisible else { return }
        settingsVisible = visible
        if !visible { forgetSettingsWindow() }
        updateActivationPolicy()
        menuRevision += 1
    }

    /// A windowed app must be regular to have a menu bar; the status item and
    /// companion panel keep working either way. Without this switch every
    /// command in `TsundokuCommands` stays unreachable and the app never
    /// appears in the Dock or ⌘-Tab.
    private func updateActivationPolicy() {
        let windowed = libraryVisible || settingsVisible
        let policy: NSApplication.ActivationPolicy =
            windowed ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if windowed { NSApp.activate(ignoringOtherApps: true) }
        menuRevision += 1
    }

    private func forgetSettingsWindow() {
        if let window = settingsWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.willCloseNotification, object: window)
        }
        settingsWindow = nil
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) {
        settingsVisible = false
        if let window = notification.object as? NSWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.willCloseNotification, object: window)
        }
        settingsWindow = nil
        windowBridge.setDismissSettings(nil)
        updateActivationPolicy()
        menuRevision += 1
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        menuRevision += 1
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

    func openSettings(_ route: SettingsRoute? = nil) {
        let wasVisible = settingsVisible
        if !wasVisible { settingsPresentationRouted = true }
        settingsNavigation.open(route, wasVisible: wasVisible)
        ensureAppModel()
        windowBridge.openSettings()
        NSApp.activate(ignoringOtherApps: true)
        TsundokuDiagnostics.shared.event(
            "settings_shown",
            ["pane": settingsNavigation.selectedPane.rawValue])
    }

    /// The automatic Settings command (and the status menu) both present the
    /// scene; this is the one place that initializes its model and restores
    /// ordinary pane navigation when the open did not carry a route.
    func settingsSceneAppeared() {
        ensureAppModel()
        if settingsPresentationRouted {
            settingsPresentationRouted = false
        } else {
            settingsNavigation.open(nil, wasVisible: false)
        }
        TsundokuDiagnostics.shared.event(
            "settings_scene_appeared",
            ["pane": settingsNavigation.selectedPane.rawValue])
    }

    /// `dismiss` is the SwiftUI path; if the Settings scene ignores it, close
    /// the window it is actually showing.
    func closeSettingsWindow() {
        windowBridge.dismissSettings()
        Task { @MainActor [weak self] in
            guard let self, let window = self.settingsWindow,
                window.isVisible
            else { return }
            window.performClose(nil)
        }
    }

    func installSceneActions(
        openWindow: OpenWindowAction, openSettings: OpenSettingsAction
    ) {
        windowBridge.install(
            openWindow: openWindow, openSettings: openSettings)
    }

    @objc private func spaceChanged() {
        companion?.spaceChanged()
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
            "artifacts_window_visible": libraryVisible,
            "app_model_created": appModel != nil,
            "settings_visible": settingsVisible,
            "settings_pane": settingsNavigation.selectedPane.rawValue,
            "diagnostics_dropped_events":
                TsundokuDiagnostics.shared.droppedEventCount,
            "diagnostics_last_error":
                TsundokuDiagnostics.shared.lastError ?? "",
        ]
    }

    // MARK: - Menu commands

    /// Native edit commands were validated by the responder chain; the custom
    /// menu buttons ask the same validator, so a read-only field or an empty
    /// selection disables them exactly as the standard menu would.
    private func canPerformTextAction(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSTextView,
            let target = NSApp.target(forAction: action, to: nil, from: nil)
        else { return false }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        // AppKit consults NSMenuItemValidation before NSUserInterfaceValidations.
        if let validating = target as? NSMenuItemValidation {
            return validating.validateMenuItem(item)
        }
        if let validating = target as? NSUserInterfaceValidations {
            return validating.validateUserInterfaceItem(item)
        }
        return true
    }

    var canCut: Bool { canPerformTextAction(#selector(NSText.cut(_:))) }
    var canPaste: Bool { canPerformTextAction(#selector(NSText.paste(_:))) }

    var browserMenuState: BrowserMenuState {
        BrowserMenuState.make(
            keyWindowIdentifier: NSApp.keyWindow?.identifier?.rawValue,
            mainWindowIdentifier: NSApp.mainWindow?.identifier?.rawValue,
            section: appModel?.section,
            bookWorkspaceID: appModel?.bookWorkspaceID,
            selectedBookID: appModel?.selectedBookID,
            isImporting: appModel?.isImporting == true)
    }

    func performBrowserCommand(_ command: String) {
        TsundokuDiagnostics.shared.event("browser_menu_command", [
            "command": command,
            "window": NSApp.keyWindow?.identifier?.rawValue ?? "none",
        ])
        if NSApp.keyWindow?.identifier?.rawValue
            == TsundokuWindowIdentifier.inspector
        {
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(
            name: .tsundokuBrowserCommand, object: NSApp.keyWindow,
            userInfo: ["command": command])
    }

    func importFromMenu() { ensureAppModel().importLibrary() }

    func showSavedNotes() {
        let model = ensureAppModel()
        model.section = .highlights
        openLibrary(importLibrary: false)
        model.showSavedAINotes = true
    }

    func selectAllFromMenu() {
        textOrBrowserAction(
            #selector(NSText.selectAll(_:)), command: "selectAll")
    }

    func copyFromMenu() {
        textOrBrowserAction(#selector(NSText.copy(_:)), command: "copy")
    }

    func performResponderAction(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    private func textOrBrowserAction(_ action: Selector, command: String) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(action, to: nil, from: nil)
        } else {
            NotificationCenter.default.post(
                name: .tsundokuBrowserCommand, object: NSApp.keyWindow,
                userInfo: ["command": command])
        }
    }

}
