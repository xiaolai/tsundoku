import AppKit
import SwiftUI
import TsundokuCore

public struct ExportsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmCapture = false
    @State private var showCropEditor = false
    private var pageLimit: Binding<PageLimit> {
        Binding(
            get: {
                if !model.captureTargetIsBooks,
                    model.capturePageLimit == nil
                {
                    return .ten
                }
                return PageLimit.allCases.first {
                    $0.pages == model.capturePageLimit
                } ?? .ten
            },
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
            if !model.captureTargetIsBooks {
                Section("Prepare Kindle") {
                    Text(
                        "Set the Kindle window, font, and first page first. "
                            + "Hide Kindle's chrome, then preview the page and "
                            + "approve the crop before starting.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Fit A4") {
                            model.fitKindleWindowToA4()
                        }
                        .disabled(model.manualPreviewBusy)
                        .help(
                            "Resize the Kindle window from its current width "
                                + "to an A4 page box. The width is reduced if "
                                + "the display cannot fit the height.")
                        Button("Preview Current Page") {
                            model.refreshManualPreview()
                        }
                        .disabled(model.manualPreviewBusy)
                        .help(
                            "Capture the current page once. This does not "
                                + "turn a page or activate Kindle.")
                        if model.manualPreviewBusy {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let message = model.manualFitMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = model.manualPreviewError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let readiness = model.manualReadiness {
                        if let blocking = readiness.blockingMessage {
                            Label(
                                blocking,
                                systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let warning = readiness.warnings.first {
                            Text(warning.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(
                                "Ready to capture from this page.",
                                systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let preview = model.manualPreview {
                        HStack(alignment: .top, spacing: 12) {
                            Image(decorative: preview.image, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 180)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    "Page \(preview.pageNumber.map(String.init) ?? "?")"
                                        + (preview.pageCount.map {
                                            " of \($0)"
                                        } ?? ""))
                                    .font(.callout.weight(.semibold))
                                Text(
                                    "Page box \(Int(preview.pageBox.width))×"
                                        + "\(Int(preview.pageBox.height)) pt · "
                                        + "crop "
                                        + String(
                                            format: "%.3f",
                                            preview.pageRatio))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Edit Crop…") {
                                    showCropEditor = true
                                }
                                .disabled(model.manualCrop == nil)
                            }
                            Spacer()
                        }
                    } else {
                        Text(
                            "No preview yet. The first page is the page "
                                + "Kindle is showing when capture starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
                    ForEach(
                        PageLimit.allCases.filter {
                            model.captureTargetIsBooks || $0 != .all
                        }
                    ) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .disabled(model.capturePhase == .running)
                .help(
                    model.captureTargetIsBooks
                        ? "All Pages first returns to the book's first page, "
                            + "then captures to the end. 10 and 25 pages "
                            + "start at the page the reader is showing."
                        : "Kindle capture starts at the previewed page. "
                            + "10 and 25 capture that many pages.")

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hands off while capturing")
                            .font(.callout.weight(.semibold))
                        Text(
                            "Tsundoku sends page-turn keys to the reader and "
                                + "photographs the screen. Do not use the "
                                + "mouse or keyboard, switch apps, or move the "
                                + "reader window until it finishes; input can "
                                + "turn a page or change focus and fail the "
                                + "capture."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Label(
                            model.captureTargetIsBooks
                                ? "Do not minimize the Apple Books window. "
                                    + "Capture needs it open and unminimized "
                                    + "to turn pages."
                                : "Do not minimize the Kindle window. "
                                    + "Capture needs it open and unminimized "
                                    + "to turn pages.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        if model.settings.cleanPageDuringCapture,
                            !model.captureTargetIsBooks
                        {
                            Text(
                                "Hide Popular Highlights also moves the "
                                    + "pointer briefly to click Kindle's "
                                    + "settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Advanced Capture Options") {
                    if !model.captureTargetIsBooks {
                        Text(
                            "Manual Kindle capture uses the previewed crop "
                                + "and A4 output. Page size, crop, font size, "
                                + "and Hide Popular Highlights below are not "
                                + "used by this flow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker(
                        "Page size",
                        selection: $model.settings.capturePageSize
                    ) {
                        ForEach(CapturePageSize.allCases, id: \.self) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .disabled(
                        model.capturePhase == .running
                            || !model.captureTargetIsBooks)
                    .help(
                        "A4 temporarily resizes the reader. Layout and text size are restored afterward."
                    )

                    Stepper(
                        "Crop top: \(model.settings.captureCropTop) pt",
                        value: $model.settings.captureCropTop, in: 0...200
                    )
                    .help("Trim points from the top of each captured page.")
                    .disabled(
                        model.capturePhase == .running
                            || !model.captureTargetIsBooks)

                    if model.captureTargetIsBooks {
                        Stepper(
                            "Crop bottom: \(model.settings.booksCropBottom) pt",
                            value: $model.settings.booksCropBottom, in: 0...200
                        )
                        .help(
                            "Bottom crop in points; zero keeps printed page numbers."
                        )
                        .disabled(
                            model.capturePhase == .running
                                || !model.captureTargetIsBooks)
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
                        .disabled(
                            model.capturePhase == .running
                                || !model.captureTargetIsBooks)
                        Picker(
                            "Font size",
                            selection: $model.settings.captureFontSize
                        ) {
                            Text("Keep current").tag(Int?.none)
                            ForEach([5, 6, 7, 8, 9], id: \.self) { size in
                                Text("\(size)").tag(Int?.some(size))
                            }
                        }
                        .disabled(
                            model.capturePhase == .running
                                || !model.captureTargetIsBooks)
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
                            || !model.captureTargetIsBooks
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
                            confirmCapture = true
                        } label: {
                            Label("Start Capture", systemImage: "play.fill")
                        }
                        .labelStyle(.iconOnly)
                        .help(
                            model.captureTargetIsBooks
                                ? "Start capture"
                                : "Start capture from the previewed page")
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !model.captureTargetIsBooks
                                && model.manualCrop == nil)
                    }
                }

                statusArea
            }

            Section("Reader") {
                Text(
                    "Open the book and keep its reader visible and "
                        + "unminimized. Capture needs the window open to turn "
                        + "pages."
                )
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
        .sheet(isPresented: $showCropEditor) {
            if let preview = model.manualPreview {
                CropEditorView(
                    preview: preview,
                    crop: Binding(
                        get: { model.manualCrop ?? preview.crop },
                        set: { model.manualCrop = $0 }),
                    lockA4: $model.manualCropLocksA4,
                    onRefresh: {
                        model.refreshManualPreview()
                    })
            } else {
                VStack(spacing: 12) {
                    Text("The preview is no longer available.")
                        .font(.headline)
                    if let error = model.manualPreviewError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button("Done") { showCropEditor = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(24)
                .frame(minWidth: 360, minHeight: 180)
            }
        }
        .alert(
            "Capture Will Control the Reader", isPresented: $confirmCapture
        ) {
            Button("Start Capture") {
                if model.captureTargetIsBooks {
                    model.startCapture(pages: model.capturePageLimit)
                } else {
                    model.startManualCapture(pages: model.capturePageLimit)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Tsundoku sends page-turn keys to the reader and photographs "
                    + "the screen. Do not move the mouse, type, switch apps, "
                    + "move the reader window, or minimize it until it "
                    + "finishes. Input can turn a page, change focus, or make "
                    + "the capture fail; a minimized reader cannot receive "
                    + "page turns reliably. Start only after the preview and "
                    + "crop are approved.")
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
                if model.captureProgress > 0 {
                    ProgressView(value: model.captureProgress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(model.captureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(
                    "Capturing — do not use the mouse or keyboard or "
                        + "minimize the reader.",
                    systemImage: "hand.raised"
                )
                .font(.caption.weight(.semibold))
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
