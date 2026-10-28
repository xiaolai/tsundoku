import AppKit
import SwiftUI
import TsundokuCore
import TsundokuUI

/// Owns the companion state machine, the one window, and the input policy.
@MainActor
final class CompanionController {
    private var state = CompanionStateMachine()
    private let window = CompanionWindow()
    private let settings: CompanionSettingsStore
    private let permissions: PermissionsModel
    private let appModelFactory: () -> AppModel

    private var panelModel: AIPanelModel?
    private var panelIdentity: ReaderIdentity?
    private var reader: ReaderSnapshot?
    private var pendingConversation:
        (bookID: String, source: BookSource?, conversationID: Int64)?
    private var conversationRouteGeneration = 0
    private let styleSampler = ReaderStyleSampler()
    private var styleTask: Task<Void, Never>?
    private var styleGeneration = 0
    private var output = CompanionOutput(presentation: .hidden, layout: nil)
    private var lastAppliedOutput: CompanionOutput?
    private var lastSurface: CompanionOutput.Presentation = .hidden
    private var lastMode: CompanionLayout.Mode?
    private var hostedModel: AIPanelModel?
    private var presentationGeneration = 0

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var reorderGeneration = 0
    private var reorderWork: DispatchWorkItem?

    var onPresentationChange:
        ((CompanionOutput, ReaderSnapshot?) -> Void)?
    var onAppModelCreated: (() -> Void)?
    /// A user-visible message for a route that could not open because no
    /// reader is active.
    var messageSink: ((String) -> Void)?
    var statusProvider: () -> [String: Any] = { [:] }

    init(
        settings: CompanionSettingsStore,
        permissions: PermissionsModel,
        appModelFactory: @escaping () -> AppModel
    ) {
        self.settings = settings
        self.permissions = permissions
        self.appModelFactory = appModelFactory
        state.settings = settings.settings
    }

    var isPanelOpen: Bool { output.presentation == .panel }

    /// The status menu must not offer a companion for a reader window that is
    /// not eligible (minimized, library focused, another app frontmost).
    var canShowPanel: Bool { output.presentation != .hidden }

    var currentReader: ReaderSnapshot? { reader }

    func start() {
        installInputMonitors()
        TsundokuDiagnostics.shared.event(
            "companion_started",
            ["settings": settingsDictionary()])
    }

    func stop() {
        removeInputMonitors()
        reorderWork?.cancel()
        cancelPanelModel()
        window.hide()
    }

    // MARK: - Reader

    func readerChanged(_ snapshot: ReaderSnapshot?) {
        let wasOpen = state.panelOpen
        let previousReader = reader
        reader = snapshot
        let visible = visibleFrame(for: snapshot)
        output = state.update(reader: snapshot, visible: visible)
        if wasOpen && !state.panelOpen {
            cancelPanelModel()
        }
        if output.presentation == .panel {
            let prepared = preparePanelModelIfNeeded()
            if !prepared, snapshot != previousReader, let reader {
                refreshReaderStyle(for: reader)
            }
        }
        guard snapshot != previousReader || output != lastAppliedOutput else {
            return
        }
        apply(output, animated: snapshot != nil)
    }

    func fullScreenChanged(_ fullScreen: Bool) {
        scheduleReorder(expectedFullScreen: fullScreen, delay: 0.9)
    }

    func spaceChanged() {
        guard output.isVisible else { return }
        scheduleReorder(expectedFullScreen: nil, delay: 0.3)
    }

    func settingsChanged(_ newSettings: CompanionSettings) {
        state.settings = newSettings
        guard let reader else {
            output = state.output(visible: NSScreen.main?.visibleFrame ?? .zero)
            apply(output, animated: false)
            return
        }
        output = state.output(visible: visibleFrame(for: reader))
        apply(output, animated: false)
        TsundokuDiagnostics.shared.event(
            "companion_settings_changed", settingsDictionary())
    }

    // MARK: - Panel actions

    func showPanel() {
        guard let reader else {
            TsundokuDiagnostics.shared.event("companion_no_reader")
            return
        }
        let wasPanel = output.presentation == .panel
        output = state.openPanel(visible: visibleFrame(for: reader))
        guard state.panelOpen else { return }
        preparePanelModelIfNeeded()
        apply(output, animated: !wasPanel)
        // The panel is nonactivating; without this the reader's keystrokes
        // still go to Kindle after ⌥⌘K, where letters can trigger search or
        // page navigation. Route the first keystroke into the composer.
        activateForTyping()
    }

    /// Opens the companion and loads a stored conversation after the panel
    /// has read its live page. The live book must match; a route for another
    /// book never replaces the current transcript. Kindle and Apple Books can
    /// share an identifier, so the source must match too.
    func showConversation(
        bookID: String, source: BookSource?, conversationID: Int64
    ) {
        showPanel()
        guard output.presentation == .panel else {
            pendingConversation = nil
            messageSink?(
                "Open the chat's book in Kindle or Apple Books, then "
                    + "continue from Chats.")
            return
        }
        pendingConversation = (bookID, source, conversationID)
        conversationRouteGeneration += 1
        openPendingConversation()
    }

    private func openPendingConversation() {
        guard let pending = pendingConversation,
            let model = panelModel
        else { return }
        let generation = conversationRouteGeneration
        pendingConversation = nil
        Task { [weak self] in
            await model.awaitPageLoad()
            guard let self, generation == self.conversationRouteGeneration
            else { return }
            guard let key = model.bookKey else {
                model.sendNote =
                    "This page could not be identified, so the saved chat "
                    + "cannot be continued."
                return
            }
            guard
                ConversationFiling.canonical(key)
                    == ConversationFiling.canonical(pending.bookID)
            else {
                model.sendNote =
                    "Open the chat's book in the reader, then continue from "
                    + "Chats."
                return
            }
            if let source = pending.source,
                let live = model.readerKind.map({
                    $0 == .kindle ? BookSource.kindle : .appleBooks
                }),
                live != source
            {
                model.sendNote =
                    "This chat belongs to the copy in "
                    + (source == .kindle ? "Kindle" : "Apple Books")
                    + ". Open that reader and continue from Chats."
                return
            }
            model.openConversation(
                pending.conversationID, expectedBookKey: pending.bookID,
                expectedBookSource: pending.source)
        }
    }

    func closePanel() {
        guard output.presentation == .panel || state.panelOpen else {
            return
        }
        cancelPanelModel()
        output = state.closePanel(
            visible: reader.map(visibleFrame(for:)) ?? .zero)
        apply(output, animated: true)
    }

    func togglePanel() {
        if output.presentation == .panel {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// The click that focuses the ask field activates the app. The spike
    /// measured Books taking the first keystroke from a nonactivating panel;
    /// activating before the field becomes first responder fixes it.
    func activateForTyping() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        TsundokuDiagnostics.shared.event(
            "companion_activated_for_typing",
            [
                "app_active": NSApp.isActive,
                "panel_key": window.window.isKeyWindow,
                "frontmost": NSWorkspace.shared.frontmostApplication?
                    .bundleIdentifier ?? "",
            ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            [weak self] in
            guard let self else { return }
            TsundokuDiagnostics.shared.event(
                "field_focus",
                [
                    "app_active": NSApp.isActive,
                    "panel_key": self.window.window.isKeyWindow,
                    "first_responder":
                        self.window.window.firstResponder.map {
                            String(describing: type(of: $0))
                        } ?? "nil",
                    "frontmost": NSWorkspace.shared.frontmostApplication?
                        .bundleIdentifier ?? "",
                ])
        }
        writeState()
    }

    // MARK: - Presentation

    private func apply(_ output: CompanionOutput, animated: Bool) {
        lastAppliedOutput = output
        presentationGeneration += 1
        let generation = presentationGeneration
        let previous = lastSurface
        lastSurface = output.presentation
        let animation = settings.settings.panelAnimation
        switch output.presentation {
        case .hidden:
            window.hide()
        case .trigger:
            guard let layout = output.layout else {
                window.hide()
                break
            }
            if previous == .panel, animation == .outward, !reduceMotion {
                // Collapse the drawer with the panel still in place, then swap
                // in the trigger at its own frame.
                let anchor = CompanionDrawer.anchor(
                    panel: layout.panelFrame, reader: layout.readerFrame)
                window.setLevel(layout.mode.isOverlay ? .floating : .normal)
                window.collapseDrawer(
                    anchor: anchor, reduceMotion: reduceMotion
                ) { [weak self] in
                    guard let self, generation == self.presentationGeneration,
                        self.output.presentation == .trigger
                    else { return }
                    self.window.clearDrawerAnchor()
                    self.window.setContent(
                        AnyView(
                            CompanionTriggerView { [weak self] in
                                self?.showPanel()
                            }),
                        shape: .circle)
                    self.hostedModel = nil
                    self.window.setFrame(
                        layout.triggerFrame, animated: false,
                        reduceMotion: true)
                    self.window.fadeIn()
                }
            } else {
                if previous != .trigger {
                    window.setContent(
                        AnyView(
                            CompanionTriggerView { [weak self] in
                                self?.showPanel()
                            }),
                        shape: .circle)
                    hostedModel = nil
                }
                window.clearDrawerAnchor()
                window.setFrame(
                    layout.triggerFrame,
                    animated: animation != .none && animated
                        && previous != .hidden,
                    reduceMotion: reduceMotion)
                window.setLevel(layout.mode.isOverlay ? .floating : .normal)
                window.show()
            }
        case .panel:
            guard let layout = output.layout, let model = panelModel else {
                window.hide()
                break
            }
            let compact = layout.mode == .bottom
            if previous != .panel || lastMode != layout.mode
                || hostedModel !== model
            {
                window.setContent(
                    AnyView(
                        CompanionPanelView(
                            model: model, compact: compact,
                            onActivate: { [weak self] in
                                self?.activateForTyping()
                            },
                            onClose: { [weak self] in
                                self?.closePanel()
                            })),
                    shape: .roundedRect(
                        radius: CompanionMetrics.cornerRadius))
                hostedModel = model
            }
            lastMode = layout.mode
            window.setLevel(layout.mode.isOverlay ? .floating : .normal)
            if previous == .trigger, animation == .outward, !reduceMotion {
                // The panel opens from the edge nearest the reader, full
                // height (or width) from the first frame.
                let anchor = CompanionDrawer.anchor(
                    panel: layout.panelFrame, reader: layout.readerFrame)
                window.openDrawer(
                    to: layout.panelFrame, anchor: anchor, animated: animated,
                    reduceMotion: reduceMotion)
            } else {
                window.clearDrawerAnchor()
                window.setFrame(
                    layout.panelFrame,
                    animated: animation != .none && animated
                        && previous != .hidden,
                    reduceMotion: reduceMotion)
            }
            window.show()
        }
        if output.presentation != .panel && previous == .panel {
            cancelPanelModel()
        }
        TsundokuDiagnostics.shared.event(
            "presentation",
            [
                "presentation": output.presentation.rawValue,
                "mode": output.layout?.mode.rawValue ?? "none",
                "panel_animation": animation.rawValue,
                "drawer_anchor": output.layout.map {
                    CompanionDrawer.anchor(
                        panel: $0.panelFrame, reader: $0.readerFrame).rawValue
                } ?? "",
                "panel_frame": dictionary(output.layout?.panelFrame),
                "trigger_frame": dictionary(output.layout?.triggerFrame),
                "reader_frame": dictionary(output.layout?.readerFrame),
                "window_frame": dictionary(window.frame),
                "window_on_screen": window.isOnScreen,
                "app_active": NSApp.isActive,
                "panel_key": window.window.isKeyWindow,
                "frontmost": NSWorkspace.shared.frontmostApplication?
                    .bundleIdentifier ?? "",
            ])
        onPresentationChange?(output, reader)
        writeState()
        verifyWindowAppearance(
            presentation: output.presentation,
            frames: output.layout.map {
                ($0.triggerFrame, $0.panelFrame)
            },
            generation: generation)
    }

    /// A just-ordered window is not necessarily on screen when the presentation
    /// event is written. This second sample makes a failed show visible to the
    /// gate instead of leaving it as a plausible timing gap.
    private func verifyWindowAppearance(
        presentation: CompanionOutput.Presentation,
        frames: (CGRect, CGRect)?,
        generation: Int
    ) {
        guard presentation != .hidden else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            [weak self] in
            guard
                let self,
                generation == self.presentationGeneration,
                self.output.presentation == presentation,
                let frames
            else { return }
            TsundokuDiagnostics.shared.event(
                "window_verification",
                [
                    "presentation": presentation.rawValue,
                    "on_screen": self.window.isOnScreen,
                    "window_visible": self.window.window.isVisible,
                    "window_frame": self.dictionary(self.window.frame),
                    "expected_frame": self.dictionary(
                        presentation == .panel
                            ? frames.1 : frames.0),
                    "window_number": self.window.window.windowNumber,
                ])
            self.writeState()
        }
    }

    /// Creates the panel model for the current reader. Returns whether a new
    /// model was created: its fresh sample is started here, so the caller must
    /// not start a second one.
    @discardableResult
    private func preparePanelModelIfNeeded() -> Bool {
        guard let reader else { return false }
        let identity = ReaderIdentity(
            kind: reader.kind, pid: reader.pid,
            windowNumber: reader.windowNumber, title: reader.title)
        if panelModel != nil, panelIdentity == identity { return false }
        cancelPanelModel()
        let app = appModelFactory()
        onAppModelCreated?()
        let model = AIPanelModel(
            app: app,
            context: ReaderContextLocator.context(for: reader.kind))
        panelModel = model
        panelIdentity = identity
        model.loadPage()
        // Reopening the panel is the moment a reader's font or theme change
        // becomes visible; the cache must not answer for the old appearance.
        refreshReaderStyle(for: reader, force: true)
        TsundokuDiagnostics.shared.event(
            "ai_panel_model_created", ["reader": reader.kind.rawValue])
        return true
    }

    private func cancelPanelModel() {
        styleGeneration += 1
        styleTask?.cancel()
        styleTask = nil
        panelModel?.cancel()
        panelModel = nil
        panelIdentity = nil
        pendingConversation = nil
        conversationRouteGeneration += 1
    }

    /// Sample the reader's type for the answer text. The sampler reuses a
    /// fresh sample for the same surface; `force` is used when the panel
    /// opens or the match settings change.
    private func refreshReaderStyle(
        for reader: ReaderSnapshot, force: Bool = false
    ) {
        let settings = settings.settings
        guard settings.matchReaderTypography || settings.matchReaderTheme else {
            styleGeneration += 1
            styleTask?.cancel()
            styleTask = nil
            panelModel?.textStyle = nil
            panelModel?.theme = nil
            return
        }
        styleGeneration += 1
        let generation = styleGeneration
        styleTask?.cancel()
        styleTask = Task { [weak self] in
            guard let self else { return }
            let sampled = await self.styleSampler.sample(
                for: reader, force: force)
            guard !Task.isCancelled, generation == self.styleGeneration
            else { return }
            let style = settings.matchReaderTypography
                ? sampled?.style.map { CompanionTypography.style(from: $0) }
                : nil
            let theme = settings.matchReaderTheme
                ? sampled?.theme.map(CompanionTheme.init)
                : nil
            self.panelModel?.textStyle = style
            self.panelModel?.theme = theme
            guard let sampled else { return }
            var fields: [String: Any] = ["reader": reader.kind.rawValue]
            if let readerStyle = sampled.style {
                fields["origin"] = readerStyle.origin.rawValue
                fields["family"] = readerStyle.family ?? ""
                fields["point_size"] = Double(readerStyle.pointSize)
                fields["line_pitch"] = Double(readerStyle.linePitch)
                fields["panel_size"] = style.map { Double($0.size) } ?? 0
                fields["panel_spacing"] =
                    style.map { Double($0.lineSpacing) } ?? 0
            }
            if let sampledTheme = sampled.theme {
                fields["theme_red"] = (sampledTheme.red * 255).rounded()
                fields["theme_green"] = (sampledTheme.green * 255).rounded()
                fields["theme_blue"] = (sampledTheme.blue * 255).rounded()
                fields["theme_share"] = sampledTheme.share
                fields["theme_dark"] = sampledTheme.isDark
            }
            TsundokuDiagnostics.shared.event("reader_style_sampled", fields)
        }
    }

    /// The setting changed while the panel is open: resample or drop the
    /// style without waiting for the next reader event.
    func refreshStyleForCurrentReader() {
        guard output.presentation == .panel, let reader else { return }
        refreshReaderStyle(for: reader)
    }
    // MARK: - Full screen

    /// Re-order for the Space transition, then verify. The generation token
    /// makes a stale callback harmless: switching readers, minimizing or
    /// closing before the delay expires cannot re-show an old panel.
    private func scheduleReorder(
        expectedFullScreen: Bool?, delay: TimeInterval, attempt: Int = 0
    ) {
        reorderGeneration += 1
        let generation = reorderGeneration
        reorderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.reorderGeneration else {
                return
            }
            guard self.output.isVisible, let reader = self.reader else {
                return
            }
            if let expected = expectedFullScreen,
                reader.fullScreen != expected
            {
                TsundokuDiagnostics.shared.event(
                    "fullscreen_reorder_skipped",
                    [
                        "expected": expected,
                        "current": reader.fullScreen,
                    ])
                return
            }
            self.window.orderFront()
            let onScreen = self.window.isOnScreen
            TsundokuDiagnostics.shared.event(
                "fullscreen_reorder",
                [
                    "attempt": attempt,
                    "fullscreen": reader.fullScreen,
                    "presentation": self.output.presentation.rawValue,
                    "on_screen": onScreen,
                    "window_number": self.window.window.windowNumber,
                ])
            if !onScreen && attempt < 1 {
                self.scheduleReorder(
                    expectedFullScreen: expectedFullScreen,
                    delay: 0.6, attempt: attempt + 1)
            }
        }
        reorderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Input monitors

    private func installInputMonitors() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            guard let self, self.output.presentation == .panel else {
                return event
            }
            if event.window !== self.window.window {
                self.closePanel()
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] _ in
            guard let self, self.output.presentation == .panel else {
                return
            }
            let point = NSEvent.mouseLocation
            if !self.window.frame.contains(point) {
                TsundokuDiagnostics.shared.event(
                    "click_outside",
                    [
                        "point": pointDictionary(point),
                        "window_frame": dictionary(self.window.frame),
                    ])
                self.closePanel()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard
                let self, event.keyCode == 53,
                self.output.presentation == .panel
            else { return event }
            self.closePanel()
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard
                let self, event.keyCode == 53,
                self.output.presentation == .panel
            else { return }
            self.closePanel()
        }
    }

    private func removeInputMonitors() {
        for monitor in [
            localMouseMonitor, globalMouseMonitor,
            localKeyMonitor, globalKeyMonitor,
        ] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }

    // MARK: - Helpers

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func visibleFrame(for snapshot: ReaderSnapshot?) -> CGRect {
        guard let snapshot else {
            return NSScreen.main?.visibleFrame ?? .zero
        }
        let screen = NSScreen.screens.max { left, right in
            intersectionArea(left.frame, snapshot.frame)
                < intersectionArea(right.frame, snapshot.frame)
        }
        guard
            let screen,
            intersectionArea(screen.frame, snapshot.frame) > 0
        else {
            return NSScreen.main?.visibleFrame ?? snapshot.frame
        }
        return screen.visibleFrame
    }

    private func intersectionArea(_ left: CGRect, _ right: CGRect)
        -> CGFloat
    {
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func settingsDictionary() -> [String: Any] {
        [
            "panel_placement": settings.settings.panelPlacement.rawValue,
            "trigger_placement": settings.settings.triggerPlacement.rawValue,
            "launch_at_login": settings.settings.launchAtLogin,
            "hotkey": settings.settings.hotKey.displayName,
            "hotkey_key_code": Int(settings.settings.hotKey.keyCode),
        ]
    }

    private func dictionary(_ rect: CGRect?) -> [String: Double] {
        guard let rect else { return [:] }
        return [
            "x": rect.origin.x, "y": rect.origin.y,
            "width": rect.width, "height": rect.height,
        ]
    }

    private func pointDictionary(_ point: CGPoint) -> [String: Double] {
        ["x": point.x, "y": point.y]
    }

    // MARK: - Diagnostics

    func writeState() {
        guard TsundokuDiagnostics.shared.isEnabled else { return }
        var state: [String: Any] = [
            "activation_policy": NSApp.activationPolicy().rawValue,
            "app_active": NSApp.isActive,
            "frontmost": NSWorkspace.shared.frontmostApplication?
                .bundleIdentifier ?? "",
            "accessibility": permissions.accessibility,
            "screen_recording": permissions.screenRecording,
            "presentation": output.presentation.rawValue,
            "mode": output.layout?.mode.rawValue ?? "none",
            "panel_frame": dictionary(output.layout?.panelFrame),
            "trigger_frame": dictionary(output.layout?.triggerFrame),
            "reader_frame": dictionary(output.layout?.readerFrame),
            "window_frame": dictionary(window.frame),
            "window_on_screen": window.isOnScreen,
            "panel_key": window.window.isKeyWindow,
            "panel_open": state.panelOpen,
            "app_windows": appWindows(),
        ]
        if let reader {
            state["reader"] = [
                "kind": reader.kind.rawValue,
                "pid": Int(reader.pid),
                "title": reader.title,
                "frame": dictionary(reader.frame),
                "focused": reader.focused,
                "minimized": reader.minimized,
                "fullscreen": reader.fullScreen,
                "window_number": reader.windowNumber.map { Int($0) } ?? -1,
            ]
        }
        for (key, value) in statusProvider() {
            state[key] = value
        }
        TsundokuDiagnostics.shared.writeState(state)
    }

    private func appWindows() -> [[String: Any]] {
        NSApp.windows.map { window in
            [
                "class": String(describing: type(of: window)),
                "title": window.title,
                "visible": window.isVisible,
                "key": window.isKeyWindow,
                "number": window.windowNumber,
                "frame": dictionary(window.frame),
            ]
        }
    }
}

private struct ReaderIdentity: Equatable {
    let kind: ReaderKind
    let pid: pid_t
    let windowNumber: UInt32?
    let title: String
}
