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
            // Wide enough for the sidebar plus the books table's minimum
            // columns; at 760 the table had to hide its own content.
            .frame(minWidth: Size.windowMinWidth, minHeight: Size.windowMinHeight)
            // Feedback belongs over the content the action changed, not only
            // in a sidebar column that can be collapsed.
            .overlay(alignment: .top) {
                BannerView(model: model)
                    .animation(.easeOut(duration: Motion.quick), value: model.banner?.id)
            }
        }
        .sheet(isPresented: $model.showImportReport) {
            LibraryImportReportView(model: model)
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
                .font(.callout).textSelection(.enabled).padding(Space.p10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
            } else if let failure = model.importError,
                !(model.books.isEmpty && model.annotations.isEmpty
                    && (model.section == .library || model.section == .highlights)) {
                HStack(alignment: .top) {
                    Label(
                        model.importFailures.first?.summary ?? "Library import failed.",
                        systemImage: "exclamationmark.triangle")
                    Spacer()
                    IconButton("Details…", systemImage: "info.circle") {
                        model.showImportReport = true
                    }
                    IconButton("Retry", systemImage: "arrow.clockwise") {
                        model.importLibrary()
                    }.disabled(model.isImporting)
                }
                .font(.callout).padding(Space.p10)
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
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.permissionsNeeded && model.section == .exports {
            ToolbarItem {
                Button {
                    model.requestCaptureAccess(pages: model.capturePageLimit)
                } label: {
                    Label(
                        "Permissions", systemImage: "exclamationmark.triangle")
                }
                .help("Accessibility or Screen Recording is not granted")
            }
        }
        ToolbarItem {
            // In sections other than Books a bare "Import" read as importing
            // something into what is on screen; the action always re-reads the
            // whole local library.
            Button {
                model.refreshAll()
            } label: {
                if model.isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        model.section == .library
                            ? "Import Library" : "Refresh Library",
                        systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(model.isImporting)
            .help(
                "Re-read the Kindle and Apple Books stores on this Mac. "
                    + "Nothing is downloaded.")
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
                HStack(spacing: Space.p4) {
                    Label("Exports", systemImage: "doc.richtext")
                    // A capture that stopped early is invisible in a count.
                    if model.captures.contains(where: {
                        $0.termination.map(CaptureTermination.isProblem) ?? false
                    })
                    {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.warning)
                            .accessibilityLabel("Some captures failed")
                    }
                }
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
            VStack(alignment: .leading, spacing: Space.p0) {
                HStack(alignment: .top, spacing: Space.p8) {
                    if model.isImporting {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.notice ?? "Importing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.p12)
                .padding(.vertical, Space.p8)
            }
        }
    }
}
