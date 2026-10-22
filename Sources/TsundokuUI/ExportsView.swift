import AppKit
import SwiftUI
import TsundokuCore

public struct ExportsView: View {
    @ObservedObject var model: AppModel
    @State private var pageLimit: PageLimit = .ten

    public init(model: AppModel) {
        self.model = model
    }

    enum PageLimit: String, CaseIterable, Identifiable {
        case ten
        case twentyFive
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ten: "10 Pages"
            case .twentyFive: "25 Pages"
            case .all: "All Pages"
            }
        }

        var pages: Int? {
            switch self {
            case .ten: 10
            case .twentyFive: 25
            case .all: nil
            }
        }
    }

    public var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Book") {
                    Text(bookLine)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if model.selectedBookIsAppleBooks {
                    Label(
                        "Apple Books capture is not implemented yet. "
                            + "Select a Kindle book to capture.",
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }

                Picker("Pages", selection: $pageLimit) {
                    ForEach(PageLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .disabled(model.capturePhase == .running)

                LabeledContent("Output") {
                    HStack(spacing: 8) {
                        Text(model.exportFolder.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            model.chooseExportFolder()
                        }
                    }
                }

                HStack(spacing: 8) {
                    if model.capturePhase == .running {
                        Button("Cancel") {
                            model.cancelCapture()
                        }
                    } else {
                        Button {
                            model.startCapture(pages: pageLimit.pages)
                        } label: {
                            Label("Start Capture", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedBookIsAppleBooks)
                    }
                }

                statusArea
            }

            Section("Before You Start") {
                Text("Open the book in Kindle, hide the reading toolbar, and keep the window fully on screen.")
                Text("The AX text of each page becomes an invisible, searchable layer in the PDF.")
                if model.permissionsNeeded {
                    Label(
                        "Accessibility or Screen Recording is not granted.",
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("Review Permissions…") {
                        model.showPermissions = true
                    }
                }
            }

            Section("Recent Captures") {
                if model.captures.isEmpty {
                    Text("No exports yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.captures.prefix(10)) { capture in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capture.title)
                                Text(
                                    "\(capture.pageCount) pages · "
                                        + capture.createdAt.formatted(
                                            date: .abbreviated,
                                            time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let path = capture.pdfPath {
                                Button("Open") {
                                    NSWorkspace.shared.open(
                                        URL(fileURLWithPath: path))
                                }
                                .controlSize(.small)
                                Button("Reveal") {
                                    NSWorkspace.shared.selectFile(
                                        path,
                                        inFileViewerRootedAtPath:
                                            capture.directory)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { model.refreshActivity() }
    }

    private var bookLine: String {
        if let title = model.selectedBook?.title, !title.isEmpty {
            return title
        }
        if let title = model.livePage?.title, !title.isEmpty {
            return title
        }
        return "No book is open in Kindle."
    }

    @ViewBuilder
    private var statusArea: some View {
        switch model.capturePhase {
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                if pageLimit == .all {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: model.captureProgress)
                        .progressViewStyle(.linear)
                }
                Text(model.captureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    model.captureMessage, systemImage: "checkmark.circle")
                Spacer()
                Button("Open PDF") { model.openPDF() }
                    .controlSize(.small)
                Button("Reveal") { model.revealCapture() }
                    .controlSize(.small)
            }
        case .failed:
            Label(
                model.captureMessage,
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .idle:
            EmptyView()
        }
    }
}
