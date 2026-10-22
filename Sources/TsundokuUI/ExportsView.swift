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
                        "Apple Books uses its own font family — set it in "
                            + "Books. Text size can be set here in relative "
                            + "steps and is restored after the capture."
                            + (model.settings.capturePageSize == .a4
                                ? " A4 captures one page per PDF page; the "
                                    + "reader is resized to A4 and restored."
                                : " Without A4, one two-page spread fills "
                                    + "each PDF page."),
                        systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }

                Picker("Pages", selection: $pageLimit) {
                    ForEach(PageLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .disabled(model.capturePhase == .running)

                Picker(
                    "Page size",
                    selection: $model.settings.capturePageSize
                ) {
                    ForEach(CapturePageSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .disabled(model.capturePhase == .running)

                Stepper(
                    "Crop top: \(model.settings.captureCropTop) pt",
                    value: $model.settings.captureCropTop, in: 0...200)
                    .disabled(model.capturePhase == .running)

                if model.selectedBookIsAppleBooks
                    || model.sourceFilter == .appleBooks
                {
                    Stepper(
                        "Crop bottom: \(model.settings.booksCropBottom) pt",
                        value: $model.settings.booksCropBottom, in: 0...200)
                        .disabled(model.capturePhase == .running)
                    Text(
                        "Points trimmed from each captured page. Bottom 0 "
                            + "keeps the printed page numbers; the default "
                            + "54 removes them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(
                        "Text size",
                        selection: $model.settings.booksFontSteps
                    ) {
                        Text("Much smaller").tag(-2)
                        Text("Smaller").tag(-1)
                        Text("Keep current").tag(0)
                        Text("Larger").tag(1)
                        Text("Much larger").tag(2)
                    }
                    .disabled(model.capturePhase == .running)
                } else {
                    Stepper(
                        "Crop bottom: \(model.settings.kindleCropBottom) pt",
                        value: $model.settings.kindleCropBottom, in: 0...200)
                        .disabled(model.capturePhase == .running)
                    Text(
                        "Points trimmed from each captured page. Bottom 0 "
                            + "detects a page number automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(
                        "Font size",
                        selection: $model.settings.captureFontSize
                    ) {
                        Text("Keep current").tag(Int?.none)
                        ForEach([5, 6, 7, 8, 9], id: \.self) { size in
                            Text("\(size)").tag(Int?.some(size))
                        }
                    }
                    .disabled(model.capturePhase == .running)
                }

                Text(
                    "A4 resizes the reader to a 595×842 pt page and restores "
                        + "it; a font change reflows the book and is restored "
                        + "afterwards. Kindle font size and Apple Books "
                        + "text size are applied for the capture and "
                        + "restored. Apple Books uses its own font family, "
                        + "set in Books. Apple Books at A4 captures one page "
                        + "per PDF page. Crop values trim the delivered page "
                        + "image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Include cover page",
                    isOn: $model.settings.includeCoverPage
                )
                .disabled(model.capturePhase == .running)
                Text(
                    "A vector cover page with the title, author, identifier, "
                        + "source, export date and captured page count is "
                        + "written before the captured pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Write text and metadata sidecars",
                    isOn: $model.settings.writeSidecars
                )
                .disabled(model.capturePhase == .running)
                Text(
                    "Adds cover.jpg, metadata.json, original.json, text.md and a "
                        + ".txt file beside each page. A sidecar failure is "
                        + "a warning, never a failed capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                originalWarning

                Toggle(
                    "Hide Popular Highlights during capture",
                    isOn: $model.settings.cleanPageDuringCapture
                )
                .disabled(
                    model.capturePhase == .running
                        || model.selectedBookIsAppleBooks)
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
                    }
                }

                statusArea
            }

            Section("Before You Start") {
                Text(
                    "Open the book in Kindle or Apple Books and keep the "
                        + "reader window fully on screen. For Kindle, hide "
                        + "the reading toolbar. For Apple Books, set the "
                        + "font family in Books; the text size picker is "
                        + "relative.")
                Text(
                    "The page text becomes an invisible, searchable layer in "
                        + "the PDF. Apple Books pages are captured as "
                        + (model.settings.capturePageSize == .a4
                            ? "single A4 pages." : "two-page spreads."))
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
            model.refreshOriginalAvailability()
        }
        .onChange(of: model.selectedBookID) { _, _ in
            model.refreshOriginalAvailability()
        }
    }

    @ViewBuilder
    private var originalWarning: some View {
        if let availability = model.selectedBookOriginal {
            switch availability {
            case .available:
                Label(
                    availability.warning ?? "",
                    systemImage: "book.closed")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Reveal Original") {
                        model.revealOriginal()
                    }
                    .controlSize(.small)
                    Button("Copy Original") {
                        model.copyOriginal()
                    }
                    .controlSize(.small)
                }
            case .protected(let reason):
                Label(
                    "The original is protected: \(reason)",
                    systemImage: "lock")
                    .foregroundStyle(.secondary)
            case .missing:
                if let note = model.originalNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

    private func setupLine(_ setup: PageSetupOutcome) -> String {
        var parts = ["Page: \(setup.pageSize.title)"]
        if let font = setup.requestedFont {
            parts.append("font \(font)")
        }
        parts.append(setup.restored ? "restored" : "NOT restored")
        return parts.joined(separator: " · ")
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
                if let setup = model.capturePageSetup,
                    setup.pageSize != .asDisplayed
                        || setup.requestedFont != nil
                {
                    Text(setupLine(setup))
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
