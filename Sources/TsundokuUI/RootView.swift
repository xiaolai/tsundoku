import SwiftUI
import TsundokuCore

public struct RootView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            NavigationSplitView {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(
                        min: 180, ideal: 200, max: 260)
            } detail: {
                detail
                    .navigationTitle(model.section.title)
                    .navigationSubtitle(subtitle)
                    .toolbar { toolbarContent }
            }
            .frame(minWidth: 980, minHeight: 640)
        }
        .sheet(isPresented: $model.showPermissions) {
            PermissionsView(model: model)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .library:
            LibraryView(model: model)
        case .highlights:
            HighlightsView(model: model)
        case .history:
            HistoryView(model: model)
        case .exports:
            ExportsView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }

    private var subtitle: String {
        switch model.section {
        case .library:
            return "\(model.ebookCount.formatted()) ebooks"
        case .highlights:
            return "\(model.userAnnotationCount.formatted()) annotations"
        case .history:
            let count = model.sessions.count
            return "\(count) " + (count == 1 ? "session" : "sessions")
        case .exports:
            return "\(model.captures.count.formatted()) captures"
        case .settings:
            return "Version \(appVersion)"
        }
    }

    private var appVersion: String {
        let short =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String
        let build =
            Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        // Unbundled runs have no Info.plist; VERSION owns the release number.
        default: return "dev"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.permissionsNeeded {
            ToolbarItem {
                Button {
                    model.showPermissions = true
                } label: {
                    Label(
                        "Permissions", systemImage: "exclamationmark.triangle")
                }
                .help("Accessibility or Screen Recording is not granted")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showAIPanel()
            } label: {
                Label("Ask page", systemImage: "sparkles")
            }
            .help("Ask about the current Kindle page (⌥⌘K)")
        }
        ToolbarItem {
            Button {
                model.importLibrary()
            } label: {
                if model.isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        "Import",
                        systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(model.isImporting)
            .help("Re-read Kindle's local stores")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.section) {
            Section("Library") {
                Label("Books", systemImage: "books.vertical")
                    .badge(model.ebookCount)
                    .tag(AppModel.Section.library)
                Label("Annotations", systemImage: "highlighter")
                    .badge(model.userAnnotationCount)
                    .tag(AppModel.Section.highlights)
                Label("History", systemImage: "clock")
                    .badge(model.sessions.count)
                    .tag(AppModel.Section.history)
            }
            Section("Reading") {
                Label("Exports", systemImage: "doc.richtext")
                    .badge(model.captures.count)
                    .tag(AppModel.Section.exports)
                Label("Settings", systemImage: "gearshape")
                    .tag(AppModel.Section.settings)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isImporting || model.notice != nil {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    if model.isImporting {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.notice ?? "Importing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Live page access") {
                    Text(
                        "Accessibility reads the current page and turns "
                            + "pages. Screen Recording captures the page for "
                            + "PDF export. The library and archive work "
                            + "without either."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section("Accessibility") {
                    LabeledContent("Status") {
                        Text(
                            model.permissionAccessibility
                                ? "Granted" : "Needed")
                    }
                    Text(
                        "Read the current page, turn pages, and detect the "
                            + "end of the book."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button(
                        model.permissionAccessibility
                            ? "Open Settings" : "Grant…"
                    ) {
                        if model.permissionAccessibility {
                            model.openAccessibilitySettings()
                        } else {
                            model.requestAccessibility()
                        }
                    }
                }

                Section("Screen Recording") {
                    LabeledContent("Status") {
                        Text(
                            model.permissionScreen ? "Granted" : "Needed")
                    }
                    Text("Capture the page rectangle for PDF export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(
                        model.permissionScreen ? "Open Settings" : "Grant…"
                    ) {
                        if model.permissionScreen {
                            model.openScreenSettings()
                        } else {
                            model.requestScreenRecording()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    model.refreshPermissions()
                    model.showPermissions = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 460)
    }
}
