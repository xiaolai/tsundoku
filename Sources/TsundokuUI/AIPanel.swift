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
    /// What the next message is sent with. A page turn refreshes the page and
    /// page number; the book stays the same until the reader changes it.
    @Published public var context = AIContext.empty
    /// The conversation for this book, oldest first.
    @Published public var turns: [AITurn] = []
    /// Every conversation filed under the current book, newest first.
    @Published public var conversations: [ConversationSummary] = []
    @Published public var conversationID: Int64?
    /// True while the book's earlier turns are being read; sending waits, so a
    /// message cannot start a second conversation beside the stored one.
    @Published public private(set) var historyLoading = false
    /// The reader's typography, when it could be sampled; nil keeps the
    /// panel's own body style.
    @Published public var textStyle: CompanionTextStyle?
    /// The reading page's colours, when a capture established them; nil keeps
    /// the system window styling.
    @Published public var theme: CompanionTheme?
    @Published public var action: AIAction = .ask
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
    /// The turn whose answer was written to the archive. `saved` is derived
    /// from the latest turn, so a new answer is unsaved even after an earlier
    /// one was saved.
    @Published public var savedTurnID: UUID?
    @Published public var readerKind: ReaderKind?
    @Published public var source: ReaderTextSource?
    @Published public var pageIdentifier: String?
    @Published public var saveError: String?

    public enum FailureKind: Equatable {
        case page
        case answer
    }

    private weak var app: AppModel?
    private let readerContext: any ReaderContext
    private var pageTask: Task<Void, Never>?
    private var pageWork: Task<ReaderPage, Error>?
    private var answerTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var pageGeneration = 0
    private var answerGeneration = 0
    private var conversationGeneration = 0
    private var selectionGeneration = 0
    private var localContextGeneration = 0
    private var failureKind: FailureKind?
    private var submittedRequest: AIRequest?
    private var submittedPrompt: String?
    private var submittedOnDevice = false
    private var bookKey: String?

    public init(app: AppModel?, context: any ReaderContext) {
        self.app = app
        self.readerContext = context
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

    /// The latest answer, for copy, save and the footer's state.
    public var answer: String { turns.last?.answer ?? "" }

    /// Whether the latest turn's answer has been saved.
    public var saved: Bool {
        guard let savedTurnID else { return false }
        return savedTurnID == turns.last?.id
    }

    public var readerLabel: String {
        let name = readerKind?.displayName ?? "Reader"
        var parts = [name]
        if let page = context.pageLabel { parts.append(page) }
        parts.append("\(characterCount.formatted()) characters")
        return parts.joined(separator: " · ")
    }

    /// Actions are allowed only on a page that finished loading. A reload
    /// clears the text first, so a stale page can never be sent.
    public var canRun: Bool {
        !pageText.isEmpty && !historyLoading
            && (phase == .idle || phase == .ready)
    }

    public var canSave: Bool {
        turns.last != nil && !saved
    }

    public var canSend: Bool {
        canRun
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var transmissionLabel: String {
        guard submittedRequest != nil else { return "Not sent" }
        if submittedOnDevice { return "Processed on this Mac" }
        if let selection = submittedRequest?.selection, !selection.isEmpty {
            return "Sent: selection · \(selection.count.formatted()) characters"
        }
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
        conversationGeneration += 1
        selectionGeneration += 1
        historyLoading = false
        let generation = pageGeneration
        let previousKey = bookKey
        pageText = ""
        bookTitle = ""
        readerKind = nil
        source = nil
        pageIdentifier = nil
        context = .empty
        phase = .loadingPage
        error = nil
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        submittedPrompt = nil
        let context = readerContext
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
                self.readerKind = page.kind
                self.source = page.source
                self.pageIdentifier = page.identifier
                // Kindle hides the title with its chrome; its last-opened
                // ASIN identifies the book when the app can read Kindle's
                // container, and the archive supplies the title. Without
                // either, the page is genuinely unidentified: the chat stays
                // in memory instead of being filed under a placeholder and
                // mixed with every other Kindle book.
                let matched = self.matchedBook(for: page)
                let identifier =
                    page.identifier?.trimmingCharacters(
                        in: .whitespacesAndNewlines) ?? ""
                let placeholder =
                    page.title.isEmpty || page.title == "Kindle"
                let unidentifiedKindle =
                    page.kind == .kindle && matched == nil
                    && identifier.isEmpty && placeholder
                let title =
                    matched?.title
                    ?? (unidentifiedKindle ? "" : page.title)
                self.bookTitle = title
                self.context = AIContext(
                    bookTitle: title,
                    bookSource: page.kind == .appleBooks
                        ? .appleBooks : .kindle,
                    reader: page.kind,
                    pageNumber: page.pageNumber,
                    pageCount: page.pageCount,
                    selection: page.selection,
                    excerpt: String(
                        page.text.prefix(600))
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                let key =
                    unidentifiedKindle
                    ? nil
                    : ConversationKey.make(
                        book: matched, reader: page.kind, title: title,
                        identifier: page.identifier)
                self.bookKey = key
                TsundokuDiagnostics.shared.event(
                    "page_loaded",
                    [
                        "reader": page.kind.rawValue,
                        "source": page.source.rawValue,
                        "characters": page.text.count,
                        "page": page.pageNumber ?? -1,
                        "of": page.pageCount ?? -1,
                        "selection": page.selection?.count ?? 0,
                        "book_key": key ?? "unidentified",
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
                if key != previousKey {
                    // The old book's turns must not be sent, or shown, while
                    // the new book's history loads.
                    self.turns = []
                    self.conversationID = nil
                    self.conversations = []
                    self.loadConversationHistory()
                }
                self.resolveLocalContext(page: page, matched: matched)
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

    /// Resolves the page's chapter and page number from local text: a
    /// non-DRM EPUB's navigation for Books, a captured book's `text.jsonl`
    /// for either reader. Live Accessibility alone cannot supply either.
    private func resolveLocalContext(page: ReaderPage, matched: Book?) {
        guard let app else { return }
        localContextGeneration += 1
        let generation = localContextGeneration
        // Read the captures from the archive, not the view model's copy:
        // the panel can open before the library reload has assigned it.
        let archive = app.archive
        let identifier = matched?.asin ?? page.identifier
        Task { [weak self] in
            let result = await Task.detached {
                let captures = (try? archive?.captures()) ?? []
                return ReadingContextResolver.resolve(
                    pageText: page.text, kind: page.kind, title: page.title,
                    identifier: identifier, captures: captures,
                    archive: archive)
            }.value
            guard let self, generation == self.localContextGeneration,
                let result
            else { return }
            if let chapter = result.chapter {
                self.context.chapter = chapter
            }
            if let pageNumber = result.pageNumber,
                self.context.pageNumber == nil
            {
                self.context.pageNumber = pageNumber
            }
            if self.bookKey == nil, let fingerprint = result.fingerprint {
                self.bookKey = "text:\(fingerprint)"
                if self.bookTitle.isEmpty,
                    let record = result.capture,
                    record.identityConfidence == "exact",
                    !record.title.isEmpty
                {
                    self.bookTitle = record.title
                    self.context.bookTitle = record.title
                }
                self.loadConversationHistory()
            }
            TsundokuDiagnostics.shared.event(
                "local_context_resolved",
                [
                    "chapter": result.chapter ?? "",
                    "page": result.pageNumber ?? -1,
                    "fingerprint": result.fingerprint ?? "",
                    "capture": result.capture?.directory ?? "",
                ])
        }
    }

    /// Reads the live selection again, without reloading the page. Called when
    /// the composer gains focus, because the reader may have selected text
    /// after the panel opened.
    public func refreshSelection() {
        guard !pageText.isEmpty, phase == .idle || phase == .ready else {
            return
        }
        selectionGeneration += 1
        let generation = selectionGeneration
        let book = bookTitle
        let reader = readerContext
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            let selected = await Task.detached { reader.selectedText() }.value
            guard
                let self, !Task.isCancelled,
                generation == self.selectionGeneration,
                self.bookTitle == book
            else { return }
            self.context.selection = selected
        }
    }

    public func run() {
        guard canRun else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == .ask, text.isEmpty { return }
        let settings = app?.settings ?? .defaults
        let request = AIRequest(
            action: action, pageText: pageText, bookTitle: bookTitle,
            question: text, language: settings.language,
            selection: context.selection,
            pageNumber: context.pageNumber, pageCount: context.pageCount,
            chapter: context.chapter,
            history: turns.suffix(3).map(\.exchange))
        answerTask?.cancel()
        answerGeneration += 1
        let generation = answerGeneration
        phase = .loadingAnswer
        error = nil
        saveError = nil
        failureKind = nil
        provider = settings.provider.displayName
        submittedRequest = request
        submittedOnDevice = settings.provider == .appleOnDevice
        let prompt = AIComposer.prompt(for: request, settings: settings)
        submittedPrompt = prompt
        TsundokuDiagnostics.shared.event(
            "ai_request_started",
            [
                "action": action.rawValue,
                "characters": pageText.count,
                "provider": settings.provider.rawValue,
                "turns": turns.count,
                "selection": request.selection?.count ?? 0,
            ])
        let turnContext = context
        let conversationAtSend = conversationID
        let conversationGenerationAtSend = conversationGeneration
        answerTask = Task { [weak self] in
            do {
                let result = try await AIService.answer(
                    for: request, settings: settings)
                guard
                    let self, !Task.isCancelled,
                    generation == self.answerGeneration
                else { return }
                let turn = AITurn(
                    action: request.action, question: text,
                    answer: result.text, provider: result.provider,
                    prompt: prompt, context: turnContext)
                self.turns.append(turn)
                if self.question.trimmingCharacters(in: .whitespacesAndNewlines)
                    == turn.question
                {
                    self.question = ""
                }
                self.provider = result.provider
                self.phase = .ready
                self.persist(
                    turn, conversationAtSend: conversationAtSend,
                    generationAtSend: conversationGenerationAtSend)
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

    /// A quick action sends at once, with the typed text as its question when
    /// there is one.
    public func perform(_ action: AIAction) {
        guard canRun else { return }
        self.action = action
        run()
    }

    /// The composer's send: always an Ask, and only when something was typed.
    public func send() {
        guard canSend else { return }
        action = .ask
        run()
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
        selectionTask?.cancel()
        pageTask = nil
        pageWork = nil
        answerTask = nil
        selectionTask = nil
        pageGeneration += 1
        answerGeneration += 1
        selectionGeneration += 1
        phase = .idle
        error = nil
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        submittedPrompt = nil
        TsundokuDiagnostics.shared.event("ai_work_cancelled")
    }

    /// Starts a fresh conversation about the same book. Earlier conversations
    /// stay in the history menu and in the library.
    public func newChat() {
        answerTask?.cancel()
        answerTask = nil
        answerGeneration += 1
        conversationGeneration += 1
        turns = []
        conversationID = nil
        savedTurnID = nil
        historyLoading = false
        error = nil
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        submittedPrompt = nil
        if phase != .loadingPage { phase = .idle }
        TsundokuDiagnostics.shared.event("ai_conversation_cleared")
    }

    /// Switches to an earlier conversation of the same book.
    public func openConversation(_ id: Int64) {
        guard let archive = app?.archive else { return }
        answerTask?.cancel()
        answerTask = nil
        answerGeneration += 1
        conversationGeneration += 1
        selectionGeneration += 1
        let generation = conversationGeneration
        let localTurns = turns
        if id == conversationID, !localTurns.isEmpty { return }
        phase = .loadingPage
        Task { [weak self] in
            do {
                let stored = try await Task.detached {
                    try archive.conversationTurns(conversationID: id)
                }.value
                guard
                    let self, !Task.isCancelled,
                    generation == self.conversationGeneration
                else { return }
                self.apply(stored: stored, conversationID: id)
            } catch {
                guard let self else { return }
                self.error = "Could not read this conversation: \(error)"
                self.phase = .ready
            }
        }
    }

    public func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func copy() {
        copy(answer)
    }

    public func save() {
        guard let turn = turns.last, let archive = app?.archive else {
            return
        }
        guard let asin = pageIdentifier ?? matchedBook()?.asin else {
            saveError =
                "This page could not be matched to a single archived book. "
                + "Import the library and try again."
            return
        }
        do {
            try archive.saveAISNote(
                asin: asin, position: nil,
                kind: turn.action.rawValue, prompt: turn.prompt,
                answer: turn.answer, provider: turn.provider,
                source: readerKind.map { $0 == .kindle ? .kindle : .appleBooks }
            )
            savedTurnID = turn.id
            app?.refreshAINotes()
            saveError = nil
        } catch {
            saveError = "Could not save: \(error)"
        }
    }

    // MARK: - Conversation history

    private func loadConversationHistory() {
        guard let archive = app?.archive, let key = bookKey else {
            turns = []
            conversationID = nil
            conversations = []
            historyLoading = false
            return
        }
        conversationGeneration += 1
        let generation = conversationGeneration
        historyLoading = true
        Task { [weak self] in
            do {
                let loaded = try await Task.detached {
                    let latest = try archive.latestConversation(bookKey: key)
                    let summaries = try archive.conversations(bookKey: key)
                    let stored = try latest.map {
                        try archive.conversationTurns(conversationID: $0.id)
                    } ?? []
                    return (latest, summaries, stored)
                }.value
                guard
                    let self, !Task.isCancelled,
                    generation == self.conversationGeneration,
                    self.bookKey == key
                else { return }
                self.conversationID = loaded.0?.id
                self.turns = loaded.2.map(Self.turn(from:))
                self.conversations = loaded.1
                self.historyLoading = false
                if self.phase == .loadingPage { self.phase = .idle }
                TsundokuDiagnostics.shared.event(
                    "ai_conversation_loaded",
                    [
                        "turns": loaded.2.count,
                        "conversations": loaded.1.count,
                    ])
            } catch {
                guard let self, generation == self.conversationGeneration
                else { return }
                self.historyLoading = false
                self.saveError = "Could not read this book's chats: \(error)"
            }
        }
    }

    private func apply(
        stored: [ConversationTurn], conversationID: Int64
    ) {
        self.conversationID = conversationID
        turns = stored.map(Self.turn(from:))
        historyLoading = false
        savedTurnID = nil
        error = nil
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        submittedPrompt = nil
        phase = .ready
    }

    private static func turn(from stored: ConversationTurn) -> AITurn {
        AITurn(
            action: stored.action, question: stored.question,
            answer: stored.answer, provider: stored.provider,
            prompt: stored.prompt, context: stored.context,
            createdAt: stored.createdAt)
    }

    private func persist(
        _ turn: AITurn, conversationAtSend: Int64?,
        generationAtSend: Int
    ) {
        guard let app, let archive = app.archive, let key = bookKey else {
            return
        }
        let title = context.bookTitle
        let source = context.bookSource
        Task { [weak self] in
            do {
                let result = try await Task.detached {
                    () -> (Int64, [ConversationSummary]) in
                    let id: Int64
                    if let conversationAtSend {
                        id = conversationAtSend
                    } else {
                        id = try archive.createConversation(
                            bookKey: key, bookTitle: title,
                            bookSource: source
                        ).id
                    }
                    try archive.appendConversationTurn(
                        conversationID: id, action: turn.action,
                        question: turn.question, answer: turn.answer,
                        provider: turn.provider, prompt: turn.prompt,
                        context: turn.context)
                    let summaries = try archive.conversations(bookKey: key)
                    return (id, summaries)
                }.value
                guard let self else { return }
                if conversationAtSend == nil,
                    generationAtSend == self.conversationGeneration,
                    self.bookKey == key
                {
                    self.conversationID = result.0
                }
                if self.bookKey == key {
                    self.conversations = result.1
                }
                app.refreshConversationCounts()
            } catch {
                guard let self else { return }
                self.saveError =
                    "This answer could not be saved: \(error)"
            }
        }
    }

    /// A Books page has no ASIN in the Accessibility tree. The title
    /// identifies the imported book only when exactly one source book matches;
    /// otherwise the note is refused rather than filed under a guess.
    private func matchedBook(for page: ReaderPage? = nil) -> Book? {
        guard let app else { return nil }
        let identifier = page?.identifier ?? pageIdentifier
        if let identifier, !identifier.isEmpty,
            let book = app.books.first(where: { $0.asin == identifier })
        {
            return book
        }
        guard let readerKind else { return nil }
        let source: BookSource =
            readerKind == .kindle ? .kindle : .appleBooks
        let title = page?.title ?? bookTitle
        let matches = app.books.filter {
            $0.source == source && $0.title == title
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

    private let quickActions: [AIAction] = [
        .explain, .translate, .summarize, .define,
    ]

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.top, compact ? 10 : 12)
                .padding(.bottom, 8)
            separator
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            contextBar
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.top, 6)
            composer
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.top, 6)
                .padding(.bottom, compact ? 8 : 10)
            statusLine
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.bottom, compact ? 8 : 10)
        }
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.context.bookTitle.isEmpty
                        ? "Current Page" : model.context.bookTitle
                )
                .font(compact ? .subheadline : .headline)
                .lineLimit(1)
                Text(model.readerLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !model.provider.isEmpty {
                Text(model.provider).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            historyMenu
            Button {
                model.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("Start a new chat about this book")
            .accessibilityLabel("New chat")
            .disabled(model.turns.isEmpty && model.conversationID == nil)
            Button {
                model.loadPage()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.phase == .loadingPage)
            .help("Read the current page and selection again")
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

    private var historyMenu: some View {
        Menu {
            Button("New Chat") { model.newChat() }
                .disabled(model.turns.isEmpty && model.conversationID == nil)
            if model.conversations.isEmpty {
                Divider()
                Text("No earlier chats about this book")
            } else {
                Divider()
                ForEach(model.conversations.prefix(12)) { summary in
                    Button {
                        model.openConversation(summary.id)
                    } label: {
                        Text(
                            "\(summary.firstQuestion) · "
                                + summary.conversation.updatedAt.formatted(
                                    date: .abbreviated, time: .shortened))
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Earlier chats about this book")
        .accessibilityLabel("Chat history")
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.turns.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.turns) { turn in
                            turnView(turn)
                        }
                    }
                    if model.phase == .loadingAnswer {
                        loadingRow
                    }
                    if model.phase == .failed, !model.turns.isEmpty {
                        failureView
                    }
                }
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.vertical, 12)
            }
            .onChange(of: model.turns.count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: model.phase) { _, phase in
                if phase == .loadingAnswer { scrollToLatest(proxy) }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let last = model.turns.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.phase {
        case .loadingPage:
            Text("Reading the current page…")
                .foregroundStyle(.secondary)
        case .loadingAnswer:
            Text("Asking \(model.provider)…")
                .foregroundStyle(.secondary)
        case .failed:
            failureView
        case .ready, .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    model.pageText.isEmpty
                        ? "Reload the page to begin." : "Ask about this page"
                )
                .font(.headline)
                if !model.pageText.isEmpty {
                    Text(
                        "Explain, translate or summarize the page from the "
                            + "buttons below, or type your own question."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Asking \(model.provider)…")
                .foregroundStyle(.secondary)
            Spacer()
            IconButton("Stop", systemImage: "stop.fill") { model.cancel() }
                .controlSize(.small)
        }
    }

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.error ?? "Something went wrong.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            IconButton("Try Again", systemImage: "arrow.clockwise") {
                model.retry()
            }
            .controlSize(compact ? .small : .regular)
        }
    }

    private func turnView(_ turn: AITurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: compact ? 24 : 48)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(turn.promptLabel)
                        .font(compact ? .callout : .body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(
                                cornerRadius: 14, style: .continuous))
                    if !turn.context.attachments.isEmpty {
                        Text(
                            turn.context.attachments.joined(separator: " · ")
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Companion")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !turn.provider.isEmpty {
                        Text("· \(turn.provider)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    IconButton(
                        "Copy Answer", systemImage: "doc.on.doc",
                        tooltip: "Copy this answer"
                    ) { model.copy(turn.answer) }
                    .controlSize(.mini)
                    if turn.id == model.turns.last?.id {
                        IconButton(
                            model.saved ? "Saved" : "Save Note",
                            systemImage: model.saved
                                ? "checkmark.circle" : "square.and.arrow.down",
                            tooltip: model.saved
                                ? "Saved as a note" : "Save as a note"
                        ) { model.save() }
                        .controlSize(.mini)
                        .disabled(!model.canSave)
                    }
                }
                MarkdownText(text: turn.answer, style: model.textStyle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(turn.id)
    }

    // MARK: Context

    private var contextBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(
                        model.context.bookLabel, systemImage: "book.closed",
                        help: model.context.bookTitle, maxWidth: 140
                    )
                    if let reader = model.readerKind {
                        chip(reader.displayName, systemImage: "text.book.closed")
                    }
                    if let page = model.context.pageLabel {
                        chip(page, systemImage: "bookmark")
                    }
                    if let chapter = model.context.chapter {
                        chip(
                            chapter, systemImage: "list.bullet",
                            help: "Chapter, resolved from the local book text",
                            maxWidth: 190)
                    }
                    if let selection = model.context.selectionLabel {
                        chip(
                            selection, systemImage: "text.cursor",
                            help: "The reader's selection is sent as the passage"
                        )
                    }
                    if !model.pageText.isEmpty {
                        Button {
                            model.refreshSelection()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Read the current selection again")
                        .accessibilityLabel("Refresh selection")
                    }
                }
            }
            Spacer(minLength: 0)
            contextInfoButton
        }
    }

    private func chip(
        _ text: String, systemImage: String, help: String? = nil,
        maxWidth: CGFloat? = nil
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: Capsule())
            .help(help ?? text)
    }

    private var contextInfoButton: some View {
        Menu {
            if !model.excerpt.isEmpty {
                Text(model.excerpt)
                Divider()
            }
            Text(model.transmissionLabel)
            Text(
                "Only this page"
                    + (model.context.selection == nil ? "" : " and your selection")
                    + " is sent; the rest of the book stays on this Mac.")
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.transmissionLabel)
        .accessibilityLabel(model.transmissionLabel)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickActions, id: \.self) { action in
                        Button {
                            model.perform(action)
                        } label: {
                            Label(
                                action.displayName,
                                systemImage: action.symbolName
                            )
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                .quaternary.opacity(0.5), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canRun)
                        .opacity(model.canRun ? 1 : 0.5)
                        .help(action.displayName)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ActivatingTextField(
                    text: $model.question,
                    placeholder: "Ask about this page…",
                    onSubmit: { model.send() },
                    onActivate: {
                        onActivate()
                        model.refreshSelection()
                    },
                    onEscape: { onClose?() })
                if model.phase == .loadingAnswer {
                    Button {
                        model.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(.secondary)
                    .help("Stop the answer")
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        model.send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(!model.canSend)
                    .help("Send")
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                .quaternary.opacity(0.35),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(dividerColor, lineWidth: 0.5))
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let saveError = model.saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.transmissionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.saved {
                    IconButton(
                        "View Saved Notes",
                        systemImage: "sparkles.rectangle.stack",
                        tooltip: "View saved AI notes"
                    ) { model.openSavedNotes() }
                    .controlSize(.mini)
                }
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 0.5)
    }

    /// The same hairline the panel's border uses, so a themed panel keeps one
    /// set of separators instead of system grey on black.
    private var dividerColor: Color {
        model.theme.map {
            $0.isDark
                ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
        } ?? Color(nsColor: .separatorColor).opacity(0.6)
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
    var style: CompanionTextStyle? = nil

    private var font: Font {
        guard let style else { return .body }
        if let family = style.family {
            return .custom(family, size: style.size)
        }
        return .system(size: style.size)
    }

    private var lineSpacing: CGFloat { style?.lineSpacing ?? 3 }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            Text(attributed)
                .font(font)
                .lineSpacing(lineSpacing)
        } else {
            Text(text)
                .font(font)
                .lineSpacing(lineSpacing)
        }
    }
}
