import AppKit
import SwiftUI
import TsundokuCore

public struct ExportsView: View {
    @ObservedObject var model: AppModel
    @State private var showCropEditor = false
    @State private var showAllCaptures = false
    @State private var showStartDialog = false
    @State private var activeAlert: ExportsAlert?

    private enum ExportsAlert: Identifiable {
        case delete(CaptureRecord)
        case cleanup(Int)
        case resume(AbandonedCapture)

        var id: String {
            switch self {
            case .delete(let capture): "delete-\(capture.id)"
            case .cleanup(let count): "cleanup-\(count)"
            case .resume(let capture): "resume-\(capture.id)"
            }
        }
    }
    private var pageLimit: Binding<PageLimit> {
        Binding(
            get: {
                guard let limit = model.capturePageLimit else { return .all }
                return PageLimit.allCases.first { $0.pages == limit }
                    ?? .ten
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
                prepareKindleSection
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
                    ForEach(PageLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .disabled(model.capturePhase == .running)
                .help(
                    model.captureTargetIsBooks
                        ? "All Pages first returns to the book's first page, "
                            + "then captures to the end. 10 and 25 pages "
                            + "start at the page the reader is showing."
                        : "All Pages captures from the previewed page to the "
                            + "end of the book. 10 and 25 capture that many "
                            + "pages from the previewed page.")

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
                    }
                } icon: {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Advanced Capture Options") {
                    if model.captureTargetIsBooks {
                        Picker(
                            "Page size",
                            selection: $model.settings.capturePageSize
                        ) {
                            ForEach(
                                CapturePageSize.allCases, id: \.self
                            ) { size in
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
                        .help(
                            "Trim points from the top of each captured page."
                        )
                        .disabled(model.capturePhase == .running)

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
                        Text(
                            "Set the Kindle window, layout, and font in "
                                + "Kindle before previewing. Tsundoku does not "
                                + "change them; the previewed crop and A4 "
                                + "output are what this flow uses.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                if model.captures.count > 10 {
                    Button(
                        showAllCaptures
                            ? "Show Recent Only"
                            : "See All \(model.captures.count) Captures") {
                        showAllCaptures.toggle()
                    }
                    .controlSize(.small)
                }
                if model.captures.isEmpty {
                    Text("No captures yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        showAllCaptures
                            ? model.captures : Array(model.captures.prefix(10))
                    ) { capture in
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
                                if let termination = capture.termination,
                                    !termination.isEmpty
                                {
                                    Text(termination)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                if !capture.warnings.isEmpty {
                                    Label(
                                        capture.warnings.count == 1
                                            ? "1 warning"
                                            : "\(capture.warnings.count) warnings",
                                        systemImage: "exclamationmark.triangle")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help(
                                            capture.warnings.joined(
                                                separator: "\n"))
                                }
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
                            IconButton(
                                "Delete", systemImage: "trash",
                                tooltip: "Delete this capture and its files"
                            ) {
                                activeAlert = .delete(capture)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if !model.abandonedCaptures.isEmpty {
                    ForEach(model.abandonedCaptures) { capture in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capture.directory.lastPathComponent)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(
                                    "\(capture.pageCount) pages · "
                                        + ByteCountFormatter.string(
                                            fromByteCount: capture.byteCount,
                                            countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if capture.resumable {
                                Button("Resume…") {
                                    activeAlert = .resume(capture)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(
                            "\(model.abandonedCaptures.count) failed "
                                + "capture folder"
                                + (model.abandonedCaptures.count == 1
                                    ? "" : "s")
                                + " · "
                                + ByteCountFormatter.string(
                                    fromByteCount: model.abandonedCaptureBytes,
                                    countStyle: .file)
                                + " · safe to remove")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clean Up…") {
                            activeAlert = .cleanup(
                                model.abandonedCaptures.count)
                        }
                    }
                } else if model.capturePhase != .running {
                    Text(
                        "A failed capture keeps the pages it already wrote, "
                            + "so it can be resumed or removed here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .confirmationDialog(
            "Capture Will Control the Reader",
            isPresented: $showStartDialog,
            titleVisibility: .visible
        ) {
            Button("Start Capture") { beginCaptureNow() }
            Button("Start and Don't Ask Again") {
                startNoticeAcknowledged = true
                beginCaptureNow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Tsundoku sends page-turn keys to the reader and photographs "
                    + "the screen. Do not move the mouse, type, switch apps, "
                    + "move the reader window, or minimize it until it "
                    + "finishes. The warning stays in Prepare Kindle either "
                    + "way.")
        }
        .onChange(of: startNoticeAcknowledged) { _, value in
            UserDefaults.standard.set(
                value, forKey: Self.startNoticeKey)
        }
        .onAppear {
            model.refreshActivity()
            model.refreshAbandonedCaptures()
            model.refreshOriginalAvailability()
            model.startManualPreviewFollow()
        }
        .onDisappear {
            model.stopManualPreviewFollow()
        }
        .onChange(of: model.selectedBookID) { _, _ in
            model.refreshOriginalAvailability()
        }
        .onChange(of: showCropEditor) { _, open in
            model.setManualPreviewFollowPaused(open)
        }
        .onChange(of: model.captureTargetIsBooks) { _, isBooks in
            if isBooks {
                model.stopManualPreviewFollow()
            } else if !showCropEditor {
                model.startManualPreviewFollow()
            }
        }
        .sheet(isPresented: $showCropEditor) {
            if let preview = model.manualPreview {
                CropEditorView(
                    preview: preview,
                    crop: Binding(
                        get: { model.manualCrop ?? preview.crop },
                        set: { model.manualCrop = $0 }),
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
        .alert(item: $activeAlert) { alert(for: $0) }
    }

    /// Whether the reader has said they know what a capture does. Kept in
    /// defaults, because the warning is a fact about the feature, not about
    /// this window.
    private static let startNoticeKey = "tsundoku.captureStartNoticeAcknowledged"
    @State private var startNoticeAcknowledged =
        UserDefaults.standard.bool(forKey: ExportsView.startNoticeKey)

    private func beginCaptureNow() {
        if model.captureTargetIsBooks {
            model.startCapture(pages: model.capturePageLimit)
        } else {
            model.startManualCapture(pages: model.capturePageLimit)
        }
    }

    /// The alerts are factored out of the view body: keeping the whole
    /// switch inline pushed the body past the type checker's limits.
    private func alert(for pending: ExportsAlert) -> Alert {
        switch pending {
            case .delete(let capture):
                return Alert(
                    title: Text("Delete Capture?"),
                    message: Text(
                        "\(capture.title) · \(capture.pageCount) pages\n"
                            + capture.directory),
                    primaryButton: .destructive(
                        Text("Delete Capture and Files")
                    ) {
                        activeAlert = nil
                        model.deleteCapture(capture)
                    },
                    secondaryButton: .cancel())
            case .cleanup(let count):
                return Alert(
                    title: Text("Clean Up Failed Captures?"),
                    message: Text(
                        "This removes \(count) folder"
                            + (count == 1 ? "" : "s")
                            + " whose capture never published a PDF. "
                            + "Published captures are not touched."),
                    primaryButton: .destructive(
                        Text("Delete \(count) Failed Folders")
                    ) {
                        activeAlert = nil
                        model.cleanUpAbandonedCaptures()
                    },
                    secondaryButton: .cancel())
            case .resume(let capture):
                return Alert(
                    title: Text("Resume This Capture?"),
                    message: Text(
                        "Turn Kindle to the last page this folder stored — "
                            + "page \(capture.pageCount) of its own count. "
                            + "The window size must be the same as when the "
                            + "capture stopped. Tsundoku verifies that page "
                            + "before it captures anything new."),
                    primaryButton: .default(Text("Resume")) {
                        activeAlert = nil
                        model.resumeCapture(capture)
                    },
                    secondaryButton: .cancel())
        }
    }

    @ViewBuilder
    private var prepareKindleSection: some View {
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
                        + "to an A4 page box. It moves the window "
                        + "within the usable display area and reduces "
                        + "the width only if the page cannot fit.")
                if model.canRestoreKindleWindow {
                    Button("Restore Window") {
                        model.restoreKindleWindow()
                    }
                    .help(
                        "Put the Kindle window back where Fit A4 "
                            + "found it.")
                }
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
                            preview.pageNumber.map {
                                "Page \($0)"
                                    + (preview.pageCount.map {
                                        " of \($0)"
                                    } ?? "")
                            } ?? "Page number unavailable")
                            .font(.callout.weight(.semibold))
                        Text(
                            "Crop \(Int(preview.pageBox.width))×"
                                + "\(Int(preview.pageBox.height)) pt · A4")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let note = preview.pageBoxNote {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button("Edit Crop…") {
                            showCropEditor = true
                        }
                        .disabled(model.manualCrop == nil)
                        if model.manualPreviewFollowing {
                            Text("Updates when you turn a page.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            } else {
                Text(
                    "Preview the current page to set the crop. "
                        + "Start Capture then begins at that page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    /// The flow's primary action lives outside the scrolling form, so it is
    /// visible without hunting and cannot fall below the window edge.
    @ViewBuilder
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 12) {
                switch model.capturePhase {
                case .running:
                    ProgressView().controlSize(.small)
                    Text(model.captureMessage).font(.callout)
                    Spacer()
                    Button("Cancel Capture") { model.cancelCapture() }
                        .buttonStyle(.bordered)
                case .finished:
                    Label(
                        model.captureMessage,
                        systemImage: "checkmark.circle")
                    Spacer()
                    Button("Open PDF") { model.openPDF() }
                    Button("Reveal") { model.revealCapture() }
                case .failed, .idle:
                    if let reason = startBlockedReason {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if model.captureTargetIsBooks,
                        model.captureBook() == nil
                    {
                        // Apple Books capture reads the open window; a book
                        // the archive does not know still captures, but the
                        // file cannot carry its title.
                        Text(
                            "No library book matched, so the PDF will be "
                                + "titled “Book”."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if startBlockedReason != nil {
                        Button("Preview Current Page") {
                            model.refreshManualPreview()
                        }
                        .buttonStyle(.bordered)
                    }
                    Button {
                        if startNoticeAcknowledged {
                            beginCaptureNow()
                        } else {
                            showStartDialog = true
                        }
                    } label: {
                        Label("Start Capture", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(startBlockedReason != nil)
                    .help(
                        model.captureTargetIsBooks
                            ? "Start capture"
                            : "Start capture from the previewed page")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    /// Why Start is unavailable, in the reader's words. A Kindle capture
    /// needs the reviewed crop the preview produces. An Apple Books capture
    /// reads its own page setup and can begin on a book the archive does not
    /// know, so it has no precondition here.
    private var startBlockedReason: String? {
        guard !model.captureTargetIsBooks else { return nil }
        return model.manualCrop == nil
            ? "Preview the current page to set the crop." : nil
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
