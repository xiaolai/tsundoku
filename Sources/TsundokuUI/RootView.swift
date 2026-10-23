import SwiftUI
import TsundokuCore

public struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(
                        min: 180, ideal: 200, max: 260)
            } detail: {
                detail
                    .navigationTitle(model.section.title)
                    .toolbar { toolbarContent }
            }
            .frame(minWidth: 760, minHeight: 540)
        }
        .sheet(isPresented: $model.showPermissions) {
            PermissionsView(model: model)
        }
        .sheet(isPresented: $model.showSavedAINotes) {
            SavedAINotesView(model: model, bookID: nil)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .tsundokuBrowserCommand)
        ) { notification in
            guard browserWindowIsKey else { return }
            if notification.userInfo?["command"] as? String == "sidebar" {
                columnVisibility =
                    columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.archive == nil {
                Label(
                    model.status,
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                .font(.callout).textSelection(.enabled).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
            } else if let failure = model.importError {
                HStack(alignment: .top) {
                    Label(
                        "Import incomplete. Showing archived records.",
                        systemImage: "exclamationmark.triangle")
                    Spacer()
                    IconButton("Details…", systemImage: "info.circle") {
                        model.openSettingsWindow?()
                    }
                    IconButton("Retry", systemImage: "arrow.clockwise") {
                        model.importLibrary()
                    }.disabled(model.isImporting)
                }
                .font(.callout).padding(10)
                .background(.regularMaterial)
                .help(failure)
            }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.permissionsNeeded && model.section == .exports {
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
            .help("Re-read the local Kindle and Apple Books stores")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.section) {
            Group {
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
            Group {
                Label("Exports", systemImage: "doc.richtext")
                    .badge(model.captures.count)
                    .tag(AppModel.Section.exports)
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
                        "Library browsing needs no permissions. Live reader actions use the access below."
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
                IconButton(
                    "Done", systemImage: "xmark", tooltip: "Close permissions"
                ) {
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
