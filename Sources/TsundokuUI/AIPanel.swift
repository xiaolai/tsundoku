import AppKit
import SwiftUI
import TsundokuCore

// MARK: - Model

@MainActor
public final class AIPanelModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case loadingPage
        case loadingAnswer
        case ready
        case failed
    }

    @Published public var pageText = ""
    @Published public var bookTitle = ""
    @Published public var answer = ""
    @Published public var action: AIAction = .explain
    @Published public var question = "" {
        didSet {
            guard question.count != oldValue.count else { return }
            TsundokuDiagnostics.shared.event(
                "question_edited", ["characters": question.count])
        }
    }
    @Published public var phase: Phase = .idle
    @Published public var provider = ""
    @Published public var error: String?
    @Published public var saved = false
    @Published public var readerKind: ReaderKind?
    @Published public var source: ReaderTextSource?
    @Published public var pageIdentifier: String?
    @Published public var saveError: String?

    public enum FailureKind: Equatable {
        case page
        case answer
    }

    private weak var app: AppModel?
    private let context: any ReaderContext
    private var pageTask: Task<Void, Never>?
    private var pageWork: Task<ReaderPage, Error>?
    private var answerTask: Task<Void, Never>?
    private var pageGeneration = 0
    private var answerGeneration = 0
    private var failureKind: FailureKind?
    private var submittedRequest: AIRequest?
    private var submittedPrompt: String?
    private var submittedOnDevice = false

    public init(app: AppModel?, context: any ReaderContext) {
        self.app = app
        self.context = context
    }

    public convenience init(app: AppModel?) {
        let kind = ReaderContextLocator.preferredKind() ?? .kindle
        self.init(
            app: app, context: ReaderContextLocator.context(for: kind))
    }

    public var excerpt: String {
        let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(420))
    }

    public var characterCount: Int { pageText.count }

    public var readerLabel: String {
        let name = readerKind?.displayName ?? "Reader"
        return "\(name) · Page · \(characterCount.formatted()) characters"
    }

    /// Actions are allowed only on a page that finished loading. A reload
    /// clears the text first, so a stale page can never be sent.
    public var canRun: Bool {
        !pageText.isEmpty && (phase == .idle || phase == .ready)
    }

    public var canSave: Bool {
        submittedRequest != nil && !answer.isEmpty && !saved
    }

    public var transmissionLabel: String {
        guard submittedRequest != nil else { return "Not sent" }
        if submittedOnDevice { return "Processed on this Mac" }
        return source?.disclosure == nil
            ? "Sent: current page" : "Sent: OCR text from the current page"
    }

    public func openSavedNotes() { app?.openSavedNotesWindow?() }

    /// Opening must not send anything. The caller chooses when to read the
    /// page; `run()` is only reached from an explicit action.
    public func loadPage() {
        pageTask?.cancel()
        pageWork?.cancel()
        answerTask?.cancel()
        pageTask = nil
        pageWork = nil
        answerTask = nil
        pageGeneration += 1
        answerGeneration += 1
        let generation = pageGeneration
        pageText = ""
        bookTitle = ""
        readerKind = nil
        source = nil
        pageIdentifier = nil
        phase = .loadingPage
        answer = ""
        error = nil
        saved = false
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        submittedPrompt = nil
        let context = context
        let work = Task.detached { try context.page() }
        pageWork = work
        pageTask = Task { [weak self] in
            do {
                let page = try await work.value
                guard
                    let self, !Task.isCancelled,
                    generation == self.pageGeneration
                else { return }
                self.pageText = page.text
                self.bookTitle = page.title
                self.readerKind = page.kind
                self.source = page.source
                self.pageIdentifier = page.identifier
                TsundokuDiagnostics.shared.event(
                    "page_loaded",
                    [
                        "reader": page.kind.rawValue,
                        "source": page.source.rawValue,
                        "characters": page.text.count,
                        "page": page.pageNumber ?? -1,
                        "of": page.pageCount ?? -1,
                    ])
                if page.text.isEmpty {
                    self.failureKind = .page
                    self.phase = .failed
                    self.error =
                        "This page exposes no text. Image pages need a "
                        + "screenshot or a vision model."
                    return
                }
                self.phase = .idle
            } catch {
                guard
                    let self, generation == self.pageGeneration
                else { return }
                if case ReaderContextError.cancelled = error {
                    self.phase = .idle
                    return
                }
                TsundokuDiagnostics.shared.event(
                    "page_load_failed", ["error": "\(error)"])
                self.failureKind = .page
                self.phase = .failed
                self.error = "\(error)"
            }
        }
    }

    public func run() {
        guard canRun else { return }
        let settings = app?.settings ?? .defaults
        let request = AIRequest(
            action: action, pageText: pageText, bookTitle: bookTitle,
            question: question, language: settings.language)
        answerTask?.cancel()
        answerGeneration += 1
        let generation = answerGeneration
        phase = .loadingAnswer
        answer = ""
        error = nil
        saved = false
        saveError = nil
        failureKind = nil
        provider = settings.provider.displayName
        submittedRequest = request
        submittedOnDevice = settings.provider == .appleOnDevice
        submittedPrompt = AIComposer.prompt(
            for: request, settings: settings)
        TsundokuDiagnostics.shared.event(
            "ai_request_started",
            [
                "action": action.rawValue,
                "characters": pageText.count,
                "provider": settings.provider.rawValue,
            ])
        answerTask = Task { [weak self] in
            do {
                let result = try await AIService.answer(
                    for: request, settings: settings)
                guard
                    let self, !Task.isCancelled,
                    generation == self.answerGeneration
                else { return }
                self.answer = result.text
                self.provider = result.provider
                self.phase = .ready
            } catch {
                guard
                    let self, generation == self.answerGeneration
                else { return }
                if AIProviderFailure.isCancelled(error) {
                    self.phase = .idle
                    return
                }
                self.failureKind = .answer
                self.error = AIProviderFailure.message(
                    for: error, provider: settings.provider)
                self.phase = .failed
            }
        }
    }

    public func retry() {
        switch failureKind {
        case .page:
            loadPage()
        case .answer:
            // `canRun` rejects a failed phase; clear it before re-asking.
            phase = .idle
            run()
        case nil:
            if pageText.isEmpty {
                loadPage()
            } else {
                run()
            }
        }
    }

    /// Escape and closing both land here: stop the work, discard the late
    /// answer, and write nothing.
    public func cancel() {
        pageTask?.cancel()
        pageWork?.cancel()
        answerTask?.cancel()
        pageTask = nil
        pageWork = nil
        answerTask = nil
        pageGeneration += 1
        answerGeneration += 1
        phase = .idle
        answer = ""
        error = nil
        saved = false
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        submittedPrompt = nil
        TsundokuDiagnostics.shared.event("ai_work_cancelled")
    }

    public func copy() {
        guard !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    public func save() {
        guard
            !answer.isEmpty, let archive = app?.archive,
            let request = submittedRequest,
            let prompt = submittedPrompt
        else { return }
        guard let asin = pageIdentifier ?? matchedBook()?.asin else {
            saveError =
                "This page could not be matched to a single archived book. "
                + "Import the library and try again."
            return
        }
        do {
            try archive.saveAISNote(
                asin: asin, position: nil,
                kind: request.action.rawValue, prompt: prompt,
                answer: answer, provider: provider,
                source: readerKind.map { $0 == .kindle ? .kindle : .appleBooks }
            )
            saved = true
            app?.refreshAINotes()
            saveError = nil
        } catch {
            saveError = "Could not save: \(error)"
        }
    }

    /// A Books page has no ASIN in the Accessibility tree. The title
    /// identifies the imported book only when exactly one source book matches;
    /// otherwise the note is refused rather than filed under a guess.
    private func matchedBook() -> Book? {
        guard let app, let readerKind else { return nil }
        let source: BookSource =
            readerKind == .kindle ? .kindle : .appleBooks
        let matches = app.books.filter {
            $0.source == source && $0.title == bookTitle
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

// MARK: - View

public struct AIPanelView: View {
    @ObservedObject var model: AIPanelModel
    private let compact: Bool
    private let onActivate: () -> Void
    private let onClose: (() -> Void)?

    public init(
        model: AIPanelModel,
        compact: Bool = false,
        onActivate: @escaping () -> Void = {},
        onClose: (() -> Void)? = nil
    ) {
        self.model = model
        self.compact = compact
        self.onActivate = onActivate
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            header
            pageSection
            actionPicker
            if model.action == .ask {
                questionField
            }
            answerSection
            footer
        }
        .padding(compact ? 12 : 16)
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.bookTitle.isEmpty
                        ? "Current Page" : model.bookTitle
                )
                .font(compact ? .subheadline : .headline)
                .lineLimit(1)
                Text(model.readerKind?.displayName ?? "Reader")
                    .help(model.readerLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !model.provider.isEmpty {
                Text(model.provider).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                model.loadPage()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.phase == .loadingPage)
            .help("Read the current page again")
            .accessibilityLabel("Reload page")
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(
                            width: CompanionMetrics.closeSize,
                            height: CompanionMetrics.closeSize
                        )
                        .background(.thinMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close the companion")
                .accessibilityLabel("Close companion")
            }
        }
    }

    private var pageSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.excerpt.isEmpty {
                Text(model.excerpt)
                    .lineLimit(compact ? 2 : 5)
                    .textSelection(.enabled)
                    .foregroundStyle(
                        model.excerpt.isEmpty ? .secondary : .primary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let disclosure = model.source?.disclosure {
                Label(disclosure, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(disclosure)
            }
        }
    }

    private var actionPicker: some View {
        HStack(spacing: 4) {
            ForEach(AIAction.allCases, id: \.self) { action in
                Button {
                    model.action = action
                    if action != .ask {
                        model.run()
                    }
                } label: {
                    Image(systemName: action.symbolName)
                        .font(.body)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .background(
                            model.action == action
                                ? Color.accentColor.opacity(0.22)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(action.displayName)
                .accessibilityLabel(action.displayName)
                .disabled(!model.canRun)
                .accessibilityAddTraits(
                    model.action == action ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8))
    }

    private var questionField: some View {
        HStack(spacing: 8) {
            ActivatingTextField(
                text: $model.question,
                placeholder: "Ask about this page…",
                onSubmit: { model.run() },
                onActivate: onActivate,
                onEscape: { onClose?() })
            Button {
                model.run()
            } label: {
                Label("Ask", systemImage: "paperplane.fill").labelStyle(
                    .iconOnly)
            }
            .help("Ask about this page")
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .small : .regular)
            .disabled(!model.canRun)
        }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                if model.phase == .loadingAnswer
                    || model.phase == .loadingPage
                {
                    ProgressView().controlSize(.small)
                    IconButton("Stop", systemImage: "stop.fill") {
                        model.cancel()
                    }.controlSize(.small)
                }
            }
            Group {
                switch model.phase {
                case .loadingPage:
                    Text("Reading the current page…")
                        .foregroundStyle(.secondary)
                case .loadingAnswer:
                    Text("Asking \(model.provider)…")
                        .foregroundStyle(.secondary)
                case .failed:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.error ?? "Something went wrong.")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        IconButton("Try Again", systemImage: "arrow.clockwise")
                        { model.retry() }
                        .controlSize(compact ? .small : .regular)
                    }
                case .ready:
                    ScrollView {
                        MarkdownText(text: model.answer)
                            .textSelection(.enabled)
                            .frame(
                                maxWidth: .infinity, alignment: .leading)
                    }
                case .idle:
                    Text(
                        model.pageText.isEmpty
                            ? "Reload the page to begin." : "Choose an action."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .frame(
                maxWidth: .infinity, maxHeight: .infinity,
                alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let saveError = model.saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .help(
                        model.transmissionLabel
                            + ". Only this page is used; the rest of the book stays on this Mac."
                    )
                    .accessibilityLabel(model.transmissionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.saved {
                    IconButton(
                        "View Saved Notes",
                        systemImage: "sparkles.rectangle.stack"
                    ) { model.openSavedNotes() }.controlSize(.small)
                }
                IconButton("Copy", systemImage: "doc.on.doc") { model.copy() }
                    .controlSize(.small)
                    .disabled(model.answer.isEmpty)
                IconButton(
                    model.saved ? "Saved" : "Save Note",
                    systemImage: model.saved
                        ? "checkmark.circle" : "square.and.arrow.down"
                ) { model.save() }
                .controlSize(.small)
                .disabled(!model.canSave)
            }
        }
    }
}

// MARK: - Text field

/// A field that activates the companion on the click that focuses it.
///
/// The spike measured Apple Books taking the first keystroke from a
/// nonactivating panel. Activating in `mouseDown`, before becoming first
/// responder, is what makes the first character land in the field.
public struct ActivatingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onActivate: () -> Void
    let onEscape: () -> Void

    public init(
        text: Binding<String>, placeholder: String,
        onSubmit: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onEscape: @escaping () -> Void
    ) {
        self._text = text
        self.placeholder = placeholder
        self.onSubmit = onSubmit
        self.onActivate = onActivate
        self.onEscape = onEscape
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> ActivatingField {
        let field = ActivatingField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.onActivate = onActivate
        field.onEscape = onEscape
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    public func updateNSView(_ field: ActivatingField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.onActivate = onActivate
        field.onEscape = onEscape
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ActivatingTextField

        init(_ parent: ActivatingTextField) {
            self.parent = parent
        }

        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            parent.text = field.stringValue
        }

        public func control(
            _ control: NSControl, textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }

        @MainActor @objc func submit() {
            parent.onSubmit()
        }
    }
}

public final class ActivatingField: NSTextField {
    var onActivate: (() -> Void)?
    var onEscape: (() -> Void)?

    public override func mouseDown(with event: NSEvent) {
        if !NSApp.isActive {
            onActivate?()
        }
        window?.makeKey()
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    public override func becomeFirstResponder() -> Bool {
        if !NSApp.isActive {
            onActivate?()
        }
        return super.becomeFirstResponder()
    }

    public override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

// MARK: - Markdown

struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            Text(attributed)
                .font(.body)
                .lineSpacing(3)
        } else {
            Text(text)
                .font(.body)
                .lineSpacing(3)
        }
    }
}
