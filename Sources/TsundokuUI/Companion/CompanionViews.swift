import AppKit
import SwiftUI
import TsundokuCore

// MARK: - Settings store

@MainActor
public final class CompanionSettingsStore: ObservableObject {
    @Published public var settings: CompanionSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            onChange?(settings)
        }
    }

    @Published public var hotKeyStatus = ""
    @Published public var hotKeyConflict = false
    @Published public var hotKeyTestNote = ""
    @Published public var loginItemStatus = ""

    public var onChange: ((CompanionSettings) -> Void)?
    public var onTestShortcut: (() -> Void)?
    public func testShortcut() { onTestShortcut?() }

    public init(settings: CompanionSettings = .load()) {
        self.settings = settings
    }
}

// MARK: - Trigger

public struct CompanionTriggerView: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    private var isDark: Bool { colorScheme == .dark }
    private var fill: Color {
        isDark ? .black.opacity(0.32) : .white.opacity(0.32)
    }
    private var tint: Color {
        isDark ? .black.opacity(0.55) : .white.opacity(0.18)
    }
    private var icon: Color { isDark ? .white : .black }
    private var rim: Color {
        isDark ? .white.opacity(0.14) : .black.opacity(0.08)
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(icon)
                .frame(
                    width: CompanionMetrics.triggerSize,
                    height: CompanionMetrics.triggerSize
                )
                .contentShape(Circle())
                .background(fill, in: Circle())
                .modifier(GlassCircle(tint: tint))
                .overlay(
                    Circle().strokeBorder(rim, lineWidth: 0.8)
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the reading companion")
        .help("Open the reading companion")
    }
}

private struct GlassCircle: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(tint).interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

// MARK: - Panel

public struct CompanionPanelView: View {
    @ObservedObject var model: AIPanelModel
    let compact: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    /// The appearance this view inherited; a nil theme keeps it unchanged.
    @Environment(\.colorScheme) private var inheritedColorScheme

    public init(
        model: AIPanelModel, compact: Bool,
        onActivate: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.compact = compact
        self.onActivate = onActivate
        self.onClose = onClose
    }

    public var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: CompanionMetrics.cornerRadius,
            style: .continuous)
        // One unconditional structure: the page's direction drives the
        // panel's semantic colours (a dark page gives light text, a light or
        // sepia page keeps dark text), and no theme keeps the inherited
        // appearance. Branching on the theme would replace the whole subtree
        // and could recreate a text field while the reader is typing.
        AIPanelView(
            model: model, compact: compact, onActivate: onActivate,
            onClose: onClose
        )
        .environment(
            \.colorScheme,
            model.theme.map { $0.isDark ? .dark : .light }
                ?? inheritedColorScheme)
        // The companion is a window, not a translucent HUD. An opaque
        // system window background keeps long answers readable over a
        // page view, and the window itself supplies the native shadow.
        // When the page's colours are known, the panel takes them instead.
        .background(
            model.theme?.background
                ?? Color(nsColor: .windowBackgroundColor),
            in: shape)
        .overlay(
            shape.strokeBorder(
                model.theme.map {
                    $0.isDark
                        ? Color.white.opacity(0.12)
                        : Color.black.opacity(0.12)
                } ?? Color(nsColor: .separatorColor).opacity(0.6),
                lineWidth: 0.5)
        )
        .clipShape(shape)
    }
}

// MARK: - Companion preferences

public struct CompanionSettingsSection: View {
    @ObservedObject var store: CompanionSettingsStore

    public init(store: CompanionSettingsStore) {
        self.store = store
    }

    private var chineseFace: Binding<String> {
        Binding(
            get: { store.settings.chineseFontName },
            set: { store.settings.chineseFontName = $0 })
    }

    public var body: some View {
        Section("Companion") {
            Picker("Panel placement", selection: $store.settings.panelPlacement)
            {
                ForEach(CompanionSettings.PanelPlacement.allCases, id: \.self) {
                    placement in
                    Text(placement.displayName).tag(placement)
                }
            }
            Picker("Trigger", selection: $store.settings.triggerPlacement) {
                ForEach(CompanionSettings.TriggerPlacement.allCases, id: \.self)
                {
                    placement in
                    Text(placement.displayName).tag(placement)
                }
            }
            Picker("Panel animation", selection: $store.settings.panelAnimation)
            {
                ForEach(CompanionSettings.PanelAnimation.allCases, id: \.self) {
                    style in
                    Text(style.displayName).tag(style)
                }
            }
            .help(
                "A drawer opens from the edge of the reader beside the panel; "
                    + "the direction follows the panel's placement.")
            // The two sizes a reader actually adjusts: how wide a side panel
            // is, and how tall a bottom one is. The other placement keeps its
            // own dimension from the reader's window.
            LabeledContent("Side panel width") {
                HStack(spacing: 8) {
                    Slider(
                        value: $store.settings.panelSideWidth,
                        in: 300...720, step: 20)
                        .frame(width: 180)
                    Text("\(Int(store.settings.panelSideWidth)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Bottom panel height") {
                HStack(spacing: 8) {
                    Slider(
                        value: $store.settings.panelBottomHeight,
                        in: 240...720, step: 20)
                        .frame(width: 180)
                    Text("\(Int(store.settings.panelBottomHeight)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Chinese face", selection: chineseFace) {
                Text("Follow the reader").tag("")
                ForEach(ChineseFace.allCases) { face in
                    Text(face.displayName).tag(face.fontName)
                }
            }
            .help(
                "Chinese characters use this face; Latin keeps the reader's. "
                    + "PingFang and Hiragino each ship in Simplified and "
                    + "Traditional cuts.")
            LabeledContent("Chinese tracking") {
                HStack(spacing: 8) {
                    Slider(
                        value: $store.settings.chineseTracking,
                        in: 0...0.6, step: 0.05)
                        .frame(width: 180)
                    Text(
                        String(format: "%.2f pt", store.settings.chineseTracking)
                    )
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .help(
                "Extra space between Chinese characters, in points. Chinese "
                    + "glyphs are full-width and set solid look crowded beside "
                    + "Latin word spacing.")
            Toggle("Start at login", isOn: $store.settings.launchAtLogin)
            if !store.loginItemStatus.isEmpty
                && !["Not registered", "Enabled"].contains(
                    store.loginItemStatus)
            {
                LabeledContent("Login item") {
                    Text(store.loginItemStatus)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(
                "Match the reader's typography",
                isOn: $store.settings.matchReaderTypography
            )
            Toggle(
                "Match the reader's theme",
                isOn: $store.settings.matchReaderTheme
            )
        }
        Section("Quick actions") {
            Text(
                "These actions appear in the Send button's menu in the "
                    + "companion.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(AIAction.quickActionCases, id: \.self) { action in
                Toggle(
                    action.displayName,
                    isOn: Binding(
                        get: {
                            store.settings.quickActions.contains(action)
                        },
                        set: { include in
                            var actions = store.settings.quickActions
                            if include {
                                if !actions.contains(action) {
                                    actions.append(action)
                                }
                            } else {
                                actions.removeAll { $0 == action }
                            }
                            store.settings.quickActions = actions
                        }))
            }
        }
        Section("Companion shortcut") {
            LabeledContent("Shortcut") {
                HotKeyRecorderButton(store: store)
            }
            if store.hotKeyConflict && !store.hotKeyStatus.isEmpty {
                Text(store.hotKeyStatus)
                    .font(.caption)
                    .foregroundStyle(
                        store.hotKeyConflict ? .orange : .secondary)
            }
            LabeledContent("Test") {
                IconButton(
                    "Test Shortcut", systemImage: "play",
                    tooltip: "Test the shortcut from another app"
                ) {
                    store.testShortcut()
                }
                .controlSize(.small)
            }
            if !store.hotKeyTestNote.isEmpty {
                Text(store.hotKeyTestNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Captures the next key combination in this window. A local monitor is
/// enough because the settings window is active while recording.
public struct HotKeyRecorderButton: View {
    @ObservedObject var store: CompanionSettingsStore
    @State private var recording = false
    @State private var monitor: Any?

    public init(store: CompanionSettingsStore) {
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(store.settings.hotKey.displayName)
                .font(.system(.body, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            IconButton(
                recording ? "Press a shortcut…" : "Record",
                systemImage: recording ? "keyboard" : "pencil"
            ) {
                beginRecording()
            }
            .controlSize(.small)
            if recording {
                Text("Press a shortcut…").font(.caption).foregroundStyle(
                    .secondary)
            }
            if store.hotKeyConflict {
                Label("Unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: endRecording)
    }

    private func beginRecording() {
        endRecording()
        guard let window = NSApp.keyWindow else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            guard event.window === window else {
                // The user moved to another Tsundoku window; do not swallow
                // that window's keystrokes.
                endRecording()
                return event
            }
            defer { endRecording() }
            if event.keyCode == 53 { return nil }
            var modifiers: CompanionHotKeyModifiers = []
            if event.modifierFlags.contains(.command) {
                modifiers.insert(.command)
            }
            if event.modifierFlags.contains(.option) {
                modifiers.insert(.option)
            }
            if event.modifierFlags.contains(.control) {
                modifiers.insert(.control)
            }
            if event.modifierFlags.contains(.shift) {
                modifiers.insert(.shift)
            }
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return nil
            }
            store.settings.hotKey = CompanionHotKey(
                keyCode: UInt32(event.keyCode), modifiers: modifiers)
            return nil
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
    }
}
