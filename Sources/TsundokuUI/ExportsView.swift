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

                Toggle(
                    "Hide Popular Highlights during capture",
                    isOn: $model.settings.cleanPageDuringCapture
                )
                .disabled(model.capturePhase == .running)
                Text(
                    "Kindle's display setting is turned off for the capture "
                        + "and restored afterwards. Your own highlights stay "
                        + "in the page images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let count = personalMarkCount {
                    Text(
                        "Your annotations in this book: \(count) — "
                            + "they stay in the page images.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.settings.cleanPageDuringCapture {
                    if let on = model.popularHighlightsState {
                        Text(
                            on
                                ? "Popular Highlights: on — they will be "
                                    + "turned off for the capture and "
                                    + "restored afterwards."
                                : "Popular Highlights: already off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let note = model.popularHighlightsNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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
        .onAppear {
            model.refreshActivity()
            model.refreshPopularHighlights()
        }
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

    private var personalMarkCount: Int? {
        guard model.selectedBook?.source == .kindle else { return nil }
        return model.selectedBookAnnotations.filter {
            $0.provenance == .user
        }.count
    }

    @ViewBuilder
    private var statusArea: some View {
        switch model.capturePhase {
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                if model.capturePageLimit == nil {
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(
                        model.captureMessage,
                        systemImage: "checkmark.circle")
                    Spacer()
                    Button("Open PDF") { model.openPDF() }
                        .controlSize(.small)
                    Button("Reveal") { model.revealCapture() }
                        .controlSize(.small)
                }
                if let note = model.captureCleanPage?.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
