import AppKit
import SwiftUI
import TsundokuCore

public struct ExportsView: View {
    @ObservedObject var model: AppModel
    private var pageLimit: Binding<PageLimit> {
        Binding(get: { PageLimit.allCases.first { $0.pages == model.capturePageLimit } ?? .ten },
            set: { model.capturePageLimit = $0.pages })
    }

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

                Picker("Reader", selection: $model.settings.captureReader) {
                    ForEach(CaptureReader.allCases, id: \.self) { reader in
                        Text(reader.displayName).tag(reader)
                    }
                }
                .disabled(model.capturePhase == .running)
                .help(
                    "Automatic follows the selected book, then the reader that is open. Choose Kindle or Apple Books to capture that reader even when the library has no book from it."
                )

                Picker("Pages", selection: pageLimit) {
                    ForEach(PageLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .disabled(model.capturePhase == .running)

                DisclosureGroup("Advanced Capture Options") {
                    Picker(
                        "Page size",
                        selection: $model.settings.capturePageSize
                    ) {
                        ForEach(CapturePageSize.allCases, id: \.self) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .disabled(model.capturePhase == .running)
                    .help(
                        "A4 temporarily resizes the reader. Layout and text size are restored afterward."
                    )

                    Stepper(
                        "Crop top: \(model.settings.captureCropTop) pt",
                        value: $model.settings.captureCropTop, in: 0...200
                    )
                    .help("Trim points from the top of each captured page.")
                    .disabled(model.capturePhase == .running)

                    if model.captureTargetIsBooks {
                        Stepper(
                            "Crop bottom: \(model.settings.booksCropBottom) pt",
                            value: $model.settings.booksCropBottom, in: 0...200
                        )
                        .help(
                            "Bottom crop in points; zero keeps printed page numbers."
                        )
                        .disabled(model.capturePhase == .running)
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
                            value: $model.settings.kindleCropBottom, in: 0...200
                        )
                        .help(
                            "Bottom crop in points; zero detects page numbers automatically."
                        )
                        .disabled(model.capturePhase == .running)
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

                    Toggle(
                        "Include cover page",
                        isOn: $model.settings.includeCoverPage
                    )
                    .disabled(model.capturePhase == .running)
                    .help("Add a cover with book details and the capture date.")
                    Toggle(
                        "Write text and metadata sidecars",
                        isOn: $model.settings.writeSidecars
                    )
                    .disabled(model.capturePhase == .running)
                    .help("Save extracted text and metadata alongside the PDF.")
                    originalWarning

                    Toggle(
                        "Hide Popular Highlights during capture",
                        isOn: $model.settings.cleanPageDuringCapture
                    )
                    .disabled(
                        model.capturePhase == .running
                            || model.selectedBookIsAppleBooks
                    )
                    .help(
                        "Temporarily hide Amazon popular highlights and restore the setting afterward. Personal annotations remain visible."
                    )
                    if let count = personalMarkCount, count > 0 {
                        Text(
                            "\(count) personal annotations remain visible."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if model.settings.cleanPageDuringCapture {
                        if let on = model.popularHighlightsState {
                            Text(
                                on
                                    ? "Popular highlights will be hidden temporarily."
                                    : "Popular highlights are already hidden."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if let note = model.popularHighlightsNote {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                }
                LabeledContent("Output") {
                    HStack(spacing: 8) {
                        Text(model.exportFolder.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        IconButton(
                            "Choose…", systemImage: "folder.badge.plus",
                            tooltip: "Choose export folder"
                        ) {
                            model.chooseExportFolder()
                        }
                    }
                }

                HStack(spacing: 8) {
                    if model.capturePhase == .running {
                        IconButton(
                            "Cancel", systemImage: "xmark",
                            tooltip: "Cancel capture"
                        ) {
                            model.cancelCapture()
                        }
                    } else {
                        Button {
                            model.startCapture(pages: model.capturePageLimit)
                        } label: {
                            Label("Start Capture", systemImage: "play.fill")
                        }
                        .labelStyle(.iconOnly)
                        .help("Start capture")
                        .buttonStyle(.borderedProminent)
                    }
                }

                statusArea
            }

            Section("Reader") {
                Text("Open the book and keep its reader visible.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.permissionsNeeded {
                    Label(
                        "Capture permissions required.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                    IconButton(
                        "Review Permissions…", systemImage: "lock.shield",
                        tooltip: "Review capture permissions"
                    ) {
                        model.requestCaptureAccess(pages: model.capturePageLimit)
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
                                            time: .shortened)
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let path = capture.pdfPath {
                                IconButton(
                                    "Open",
                                    systemImage: "arrow.up.right.square",
                                    tooltip: "Open PDF"
                                ) {
                                    NSWorkspace.shared.open(
                                        URL(fileURLWithPath: path))
                                }
                                .controlSize(.small)
                                IconButton(
                                    "Reveal", systemImage: "folder",
                                    tooltip: "Show in Finder"
                                ) {
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
                    systemImage: "book.closed"
                )
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    IconButton("Reveal Original", systemImage: "folder") {
                        model.revealOriginal()
                    }
                    .controlSize(.small)
                    IconButton("Copy Original", systemImage: "doc.on.doc") {
                        model.copyOriginal()
                    }
                    .controlSize(.small)
                }
            case .protected(let reason):
                Label(
                    "The original is protected: \(reason)",
                    systemImage: "lock"
                )
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
        if let title = model.captureBook()?.title, !title.isEmpty {
            return title
        }
        if model.captureKind == .kindle,
            let title = model.livePage?.title, !title.isEmpty
        {
            return title
        }
        return model.captureKind == .appleBooks
            ? "No Apple Books book is selected."
            : "No book is open in Kindle."
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
                    IconButton("Open PDF", systemImage: "arrow.up.right.square")
                    { model.openPDF() }
                    .controlSize(.small)
                    IconButton(
                        "Reveal", systemImage: "folder",
                        tooltip: "Show in Finder"
                    ) { model.revealCapture() }
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
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        case .idle:
            EmptyView()
        }
    }
}
