import AppKit
import SwiftUI
import TsundokuCore

enum LibraryAppLocation {
    static func requiresInstallation(_ url: URL) -> Bool {
        url.pathExtension.lowercased() != "app" || url.path.hasPrefix("/Volumes/") || url.pathComponents.contains("AppTranslocation")
    }
}

/// All setup help lives inside the one Settings window. This view has no
/// window presenter and never cancels pending work when it disappears.
struct AccessSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var navigation: SettingsNavigation
    @Environment(\.scenePhase) private var scenePhase
    private var appURL: URL { Bundle.main.bundleURL }
    private var needsInstallation: Bool { LibraryAppLocation.requiresInstallation(appURL) }
    private var blocked: Bool { permissions.libraryFailures.contains(where: \.accessDenied) }
    private var libraryTitle: String {
        permissions.libraryReady && !permissions.libraryFailures.isEmpty ? "Partially readable" : permissions.libraryStatus.title
    }

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                if navigation.intent != nil || permissions.librarySetupPending {
                    Section {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(taskTitle).font(.headline)
                                if model.isImporting { ProgressView("Importing library…").controlSize(.small) }
                            }
                            Spacer()
                            IconButton("Cancel Setup", systemImage: "xmark", action: navigation.cancelIntent)
                                .disabled(permissions.relaunchPending || (model.isImporting && navigation.intent == .library))
                        }
                        if navigation.intent != nil {
                            Button(returnTitle, action: navigation.returnToTask)
                                .disabled(!canReturn)
                        }
                    }
                }

                Section("Library Imports") {
                    HStack {
                        Text(permissions.libraryChecking ? "Checking…" : libraryTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("library-access-status")
                        Spacer()
                        Button("Re-check Library Access") {
                            Task { await permissions.verifyLibraryAccess() }
                        }.disabled(permissions.libraryChecking || permissions.libraryRegistrationInProgress)
                        if permissions.libraryReady && !blocked {
                            Button("Manage Full Disk Access…", action: permissions.openLibrarySettings)
                        }
                        if permissions.libraryReady {
                            Button("Import Library", action: model.requestLibraryImport)
                                .disabled(model.isImporting || permissions.libraryRegistrationInProgress)
                        }
                    }
                    ForEach(BookSource.allCases, id: \.self) { source in
                        LabeledContent(source.displayName) {
                            Text(sourceStatus(source)).foregroundStyle(.secondary)
                        }
                    }
                    if permissions.libraryRegistrationInProgress {
                        ProgressView("Opening Full Disk Access…")
                    } else if blocked || (!permissions.libraryReady && (permissions.librarySetupPending || permissions.libraryStatus == .notChecked)) {
                        Button("Request Full Disk Access…", action: model.requestLibraryAccess)
                            .disabled(permissions.libraryChecking || needsInstallation)
                    }
                    if let instruction = permissions.libraryInstruction {
                        Text(instruction).font(.caption).foregroundStyle(.secondary)
                    }
                    if needsInstallation {
                        Label("Install Tsundoku in Applications before requesting access.", systemImage: "externaldrive")
                            .font(.caption)
                        Button("Show Applications") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
                    } else if blocked || (!permissions.libraryReady && permissions.librarySetupPending) {
                        DisclosureGroup("App Not Listed?") {
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path)).resizable().frame(width: 36, height: 36)
                                Text("Drag Tsundoku into the Full Disk Access list.").font(.caption)
                            }
                            .draggable(appURL)
                            Button("Show Tsundoku in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([appURL])
                            }
                        }
                    }
                    if permissions.libraryStatus == .notFound {
                        Text("Download a book in Kindle or Apple Books, then import again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = permissions.librarySettingsError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.hasCompletedImport {
                        Text(model.lastImportResult ?? model.status).font(.caption).foregroundStyle(.secondary)
                        if model.importError != nil {
                            Button("Retry Import") { model.requestLibraryImport() }.disabled(permissions.relaunchPending || (model.isImporting && navigation.intent == .library))
                        }
                    }
                    if !permissions.libraryFailures.isEmpty {
                        DisclosureGroup("Access Details") {
                            ForEach(permissions.libraryFailures) { failure in
                                Text("\(failure.source.displayName): \(failure.detail)").font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    if permissions.libraryStatus == .blocked && !needsInstallation {
                        VStack(alignment: .leading, spacing: 2) {
                            Button("Quit and Reopen Tsundoku") { permissions.requestRelaunch() }
                                .disabled(permissions.relaunchPending || model.isImporting || model.capturePhase == .running)
                            Text(
                                "macOS applies a new Full Disk Access grant only after a relaunch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }.id(AccessFocus.library)

                Section {
                    permissionRow("Accessibility", detail: "Read the current page, turn pages for capture, and record reading sessions.",
                        granted: permissions.companionReady, status: permissions.accessibility ? "Available" : "Not enabled",
                        request: permissions.requestAccessibility, manage: permissions.openAccessibilitySettings)
                        .id(AccessFocus.accessibility)
                    permissionRow("Screen Recording", detail: "Capture pages for searchable PDFs and OCR.",
                        granted: permissions.screenRecording, status: permissions.snapshot.screenStatus,
                        request: permissions.requestScreenRecording, manage: permissions.openScreenSettings)
                        .id(AccessFocus.screenRecording)
                    if permissions.screenRecording {
                        HStack {
                            Text(permissions.isChecking ? "Verifying…" : "Verify screen access").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Verify Screen Recording") {
                                Task { await permissions.verifyAccess() }
                            }.disabled(permissions.isChecking)
                        }
                    }
                    if permissions.readerAccessRequested, let focus = permissions.relaunchFocus(for: navigation.intent) {
                        VStack(alignment: .leading, spacing: 2) {
                            Button("Quit and Reopen Tsundoku") {
                                permissions.requestRelaunch(focus: focus, intent: navigation.intent)
                            }.disabled(permissions.relaunchPending || model.isImporting || model.capturePhase == .running)
                            Text(
                                "macOS applies Accessibility and Screen Recording changes on the next launch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = permissions.relaunchError, permissions.relaunchErrorFocus != .library {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    if let detail = permissions.snapshot.detail {
                        DisclosureGroup("Check Details") { Text(detail).font(.caption).textSelection(.enabled) }
                    }
                } header: {
                    HStack {
                        Text("Live Reader and Capture")
                        Spacer()
                        Button("Re-check Reader Access") { permissions.refresh() }
                    }
                } footer: {
                    Text("Only library imports need Full Disk Access.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .task {
                permissions.refresh()
                if navigation.intent != .companion && navigation.intent != .capture {
                    await permissions.verifyLibraryAccess()
                }
                if permissions.librarySetupPending && navigation.intent == nil {
                    navigation.open(SettingsRoute(pane: .access, focus: .library, intent: .library), wasVisible: true)
                }
                if let focus = navigation.focus { scroll.scrollTo(focus, anchor: .center) }
            }
            .onChange(of: navigation.focus) { _, focus in
                if let focus { scroll.scrollTo(focus, anchor: .center) }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                if permissions.librarySetupPending || navigation.intent == .library {
                    Task { await permissions.verifyLibraryAccess() }
                }
            }
        }
    }

    private func sourceStatus(_ source: BookSource) -> String {
        if permissions.readableLibrarySources.contains(source) { return "Readable" }
        if let failure = permissions.libraryFailures.first(where: { $0.source == source }) {
            return failure.accessDenied ? "Access blocked" : "Read failed"
        }
        return permissions.libraryStatus == .notChecked ? "Not checked" : "No local library"
    }
    private var taskTitle: String {
        switch navigation.intent {
        case .library, nil: permissions.libraryReady ? (permissions.libraryFailures.isEmpty ? "Library access is ready" : "Some library data is available") : "Set up library imports"
        case .companion: permissions.companionReady ? "Reader access is ready" : "Set up the reading companion"
        case .capture: permissions.captureReady ? "Capture access is ready" : "Set up capture access"
        }
    }
    private var returnTitle: String {
        switch navigation.intent {
        case .library, nil: "Return to Library"
        case .companion: "Return to Reader"
        case .capture: "Return to Capture"
        }
    }
    private var canReturn: Bool {
        switch navigation.intent {
        case .library, nil: !model.isImporting && (permissions.libraryReady || permissions.libraryStatus == .notFound)
        case .companion: permissions.companionReady
        case .capture: permissions.captureReady
        }
    }
    private func permissionRow(_ title: String, detail: String, granted: Bool, status: String,
        request: @escaping () -> Void, manage: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
                if granted { Button("Manage \(title)…", action: manage) }
                else { Button("Request \(title)…", action: request).controlSize(.small) }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
