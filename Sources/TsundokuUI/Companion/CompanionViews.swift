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
        AIPanelView(
            model: model, compact: compact, onActivate: onActivate,
            onClose: onClose
        )
        // The companion is a window, not a translucent HUD. An opaque system
        // window background keeps long answers readable over a page view, and
        // the window itself supplies the native shadow.
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .overlay(
            shape.strokeBorder(
                Color(nsColor: .separatorColor).opacity(0.6),
                lineWidth: 0.5)
        )
        .clipShape(shape)
    }
}

// MARK: - Onboarding

public struct CompanionOnboardingView: View {
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var settings: CompanionSettingsStore
    let onOpenLoginItemSettings: () -> Void
    let onClose: () -> Void

    public init(
        permissions: PermissionsModel,
        settings: CompanionSettingsStore,
        onOpenLoginItemSettings: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.settings = settings
        self.onOpenLoginItemSettings = onOpenLoginItemSettings
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 26, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up Tsundoku")
                        .font(.headline)
                    Text(
                        "Allow library imports and live reader actions."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            LibraryAccessRow(permissions: permissions, resumeSetup: true)

            Divider()

            permissionRow(
                title: "Accessibility",
                detail:
                    "Read the current page and control the reader.",
                granted: permissions.accessibility,
                grant: permissions.requestAccessibility,
                openSettings: permissions.openAccessibilitySettings)

            permissionRow(
                title: "Screen Recording",
                detail:
                    "Capture PDFs and read pages with OCR.",
                granted: permissions.screenRecording,
                status: permissions.snapshot.screenStatus,
                grant: permissions.requestScreenRecording,
                openSettings: permissions.openScreenSettings)

            Divider()

            LabeledContent("Start at login") {
                HStack(spacing: 8) {
                    Toggle("", isOn: $settings.settings.launchAtLogin)
                        .labelsHidden()
                    Text(settings.loginItemStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.loginItemStatus == "Requires approval" {
                        IconButton(
                            "Approve…", systemImage: "gearshape",
                            action: onOpenLoginItemSettings
                        )
                        .controlSize(.small)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                IconButton("Re-check", systemImage: "arrow.clockwise", tooltip: "Check reader access. macOS may ask for authorization.") {
                    Task {
                        await permissions.verifyAccess()
                        await permissions.verifyLibraryAccess()
                    }
                }
                .disabled(permissions.isChecking || permissions.libraryChecking)
                Spacer()
                Button(permissions.setupIncomplete ? "Continue Anyway" : "Done") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 620)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            permissions.refresh()
        }
    }

    private func permissionRow(
        title: String, detail: String, granted: Bool, status: String? = nil,
        grant: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(status ?? (granted ? "Available" : "Unavailable"))
                    .font(.caption)
                    .foregroundStyle(granted && status != "Check failed" && status != "Checking…" ? .green : .orange)
                if granted {
                    IconButton(
                        "Settings…", systemImage: "gearshape",
                        action: openSettings)
                } else {
                    Button("Grant…", action: grant).controlSize(.small)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Hot key recorder

public struct CompanionSettingsSection: View {
    @ObservedObject var store: CompanionSettingsStore

    public init(store: CompanionSettingsStore) {
        self.store = store
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
                    store.hotKeyTestNote =
                        "Press the shortcut in another app to check delivery and conflicts."
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
