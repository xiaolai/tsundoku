import AppKit
import Combine
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

    public enum CompactionState: Equatable {
        case idle
        case running
        case failed(String)
    }

    @Published public var pageText = ""
    @Published public var bookTitle = ""
    /// What the next message is sent with. A page turn refreshes the page and
    /// page number; the book stays the same until the reader changes it.
    @Published public var context = AIContext.empty
    /// How the current page's book was identified, for the info menu and
    /// diagnostics. A nil key means the page stays unfiled.
    @Published public var identity: ReadingIdentity?
    /// The conversation for this book, oldest first.
    @Published public var turns: [AITurn] = []
    /// Every conversation filed under the current book, newest first.
    @Published public var conversations: [ConversationSummary] = []
    @Published public var conversationID: Int64?
    /// The latest summary for the current conversation. The transcript still
    /// contains every original turn.
    @Published public private(set) var compaction: ConversationCompaction?
    @Published public private(set) var compactionState: CompactionState = .idle
    @Published public var compactionError: String?
    @Published public private(set) var compactionRefreshing = false
    @Published public private(set) var compactionRefreshFailed = false
    @Published public private(set) var compactionRemoving = false
    @Published public private(set) var transcriptRefreshing = false
    @Published public private(set) var deletionImpact: ConversationDeletionImpact?
    private var pendingDeletionID: Int64?
    private var pendingDeletionUpdatedAt: Date?
    private var pendingDeletionCompactionRevision: Int64?
    private var pendingDeletionCardNoteIDs: Set<Int64>?
    private var pendingDeletionBookKey: String?
    private var pendingDeletionBookSource: BookSource?
    /// True while the book's earlier turns are being read; sending waits, so a
    /// message cannot start a second conversation beside the stored one.
    @Published public private(set) var historyLoading = false
    /// A failed history read keeps sending disabled until a reload succeeds:
    /// an empty transcript is not the same fact as a book with no chats.
    @Published public private(set) var historyLoadFailed = false
    /// True while an answer is being written to the archive. Sending waits:
    /// a second send before the first write finishes would not yet know the
    /// conversation ID and would start a duplicate thread.
    @Published public private(set) var persisting = false
    /// Two writes can overlap: an answer being stored while session-only
    /// turns are promoted. A single Bool let the first completion clear the
    /// flag for both; the count keeps it true until the last write ends.
    private var persistenceCount = 0
    /// Serializes archive writes: an answer and a session promotion must not
    /// race to create the same book's conversation.
    private var persistenceChain: Task<Void, Never>?
    /// The reader's typography, when it could be sampled; nil keeps the
    /// panel's own body style.
    @Published public var textStyle: CompanionTextStyle?
    /// The reading page's colours, when a capture established them; nil keeps
    /// the system window styling.
    @Published public var theme: CompanionTheme?
    @Published public var action: AIAction = .ask
    /// What the next request answers about. The page is always available;
    /// selection is only offered while the reader exposes one.
    @Published public var scope: CompanionScope = .currentPage
    /// A one-shot page image captured from the side pane. It never turns a
    /// page or participates in an Exports capture.
    @Published public var quickCapture: QuickPageCapture?
    @Published public var quickCaptureBusy = false
    @Published public var quickCaptureError: String?
    @Published public var showQuickCapture = false

    public var selectionAvailable: Bool {
        !(context.selection ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The live companion preferences, so the Send menu reflects a change
    /// made in Settings without reopening the panel.
    public var companionSettings: CompanionSettingsStore? {
        app?.companionSettings
    }

    /// Whether a local capture or EPUB covers this page. Whole-book scope is
    /// offered only when there is text to read; the check is structural, so
    /// opening the menu never loads a whole book.
    public var hasLocalBookText: Bool {
        guard let result = localResult else { return false }
        return result.capture != nil || result.epubPath != nil
    }

    /// Choosing Selection reads the reader now. Kindle's words come from its
    /// Copy button; Books exposes the selection directly. Keeping the choice
    /// when nothing is selected lets Send explain instead of silently
    /// switching the scope back.
    public func chooseScope(_ scope: CompanionScope) {
        self.scope = scope
        guard scope == .selection, !selectionAvailable else { return }
        sendNote =
            "Select text in the reader; the companion reads the selection "
            + "through the reader's Copy action."
        refreshSelection()
    }

    /// Opens the library's Exports section with this book selected, where
    /// Capture as PDF writes the text sidecars chapter/book scopes need.
    public func openCaptureExports() {
        app?.openCaptureExports(
            bookID: identity?.book?.asin ?? pageIdentifier,
            readerKind: readerKind)
    }

    /// Capture the page currently visible in the reader, once, for the side
    /// pane. This is deliberately independent of the Exports crop and page
    /// range; it never turns a page.
    public func captureCurrentPage() {
        if app?.capturePhase == .running {
            quickCaptureError = "Available when book capture stops."
            return
        }
        quickCaptureBusy = true
        quickCaptureError = nil
        Task {
            let result = await Task.detached {
                Result { try QuickPageCaptureService().capture() }
            }.value
            self.quickCaptureBusy = false
            switch result {
            case .success(let capture):
                self.quickCapture = capture
                self.showQuickCapture = true
            case .failure(let error):
                self.quickCapture = nil
                self.quickCaptureError = "\(error)"
            }
        }
    }
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
    @Published public private(set) var cardedTurnIDs: Set<Int64> = []
    @Published public var readerKind: ReaderKind?
    @Published public var source: ReaderTextSource?
    @Published public var pageIdentifier: String?
    @Published public var saveError: String?

    public enum FailureKind: Equatable {
        case page
        case answer
    }

    /// What the pre-send page check found.
    public enum PageFreshness: Equatable, Sendable {
        case current
        case refreshed(Int?)
        case bookChanged
        case unconfirmed
    }

    /// The answer transport, injectable so tests exercise the send path
    /// without a provider or a network.
    public typealias AnswerProvider = @Sendable (
        AIRequest, AISettings
    ) async throws -> AIAnswer

    /// A provider call for a prompt the caller composed (compaction). It uses
    /// the same transport and answer budget as an ordinary request.
    public typealias PromptProvider = @Sendable (
        String, AISettings
    ) async throws -> AIAnswer

    private struct PendingSave {
        let turn: AITurn
        let conversationAtSend: Int64?
        let generationAtSend: Int
        let key: String
        let title: String
        let source: BookSource?
    }

    private struct PendingPromotion {
        let turns: [AITurn]
        let key: String
        let title: String
        let source: BookSource?
    }

    /// The local-index lookup, injectable so a test can supply an EPUB match
    /// without a Books library or a real capture on disk.
    public typealias ContextResolver = @Sendable (
        ReaderPage, [CaptureRecord], Archive?
    ) -> ReadingContextResolver.Result?

    private weak var app: AppModel?
    private let readerContext: any ReaderContext
    private let contextResolver: ContextResolver
    private let answerProvider: AnswerProvider
    private let promptProvider: PromptProvider
    private var compactionGeneration = 0
    private var compactionRemovalGeneration = 0
    private var transcriptRefreshGeneration = 0
    private var transcriptMutationGeneration = 0
    private var needsTranscriptRefresh = false
    private var manualCompactionToken = 0
    private var compactionTask: Task<Void, Never>?
    private var pendingSave: PendingSave?
    private var pendingPromotion: PendingPromotion?
    private var failedConversationID: Int64?
    #if DEBUG
    /// A test seam for the retry path. It is never set in a release build.
    var failNextPersistenceForTesting = false
    #endif
    private var pageTask: Task<Void, Never>?
    /// The local-context lookup started by the current page load. Callers can
    /// await the work itself instead of polling for its side effects.
    public private(set) var localContextTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var legacyMigrationTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    /// The page number the *reader* exposed, as opposed to the captured page
    /// number the local index resolved. Kindle hides its page number, so
    /// comparing against `context.pageNumber` would see every follow as a
    /// turn.
    private var livePageNumber: Int?
    /// How many settled page turns the follow loop has adopted, for tests and
    /// diagnostics.
    @Published public private(set) var followedTurns = 0
    /// How often the open panel checks the reader for a page turn, and how
    /// long it lets a page settle before moving the chips.
    public var followInterval: Duration = .milliseconds(600)
    public var followDebounce: Duration = .milliseconds(300)
    /// The result of the latest pre-send page check, for tests and the status
    /// line.
    public private(set) var lastFreshness: PageFreshness?
    /// A visible note when the page was refreshed, could not be confirmed, or
    /// changed books between typing and sending.
    @Published public var sendNote: String?
    /// The pre-send check started by `run()`, so a caller can await it.
    public private(set) var sendPreparationTask: Task<Void, Never>?
    private var sendGeneration = 0
    /// The last nonempty reader identifier, held across pages that expose
    /// none, so A → (none) → B is still seen as a switch when B names itself.
    private var lastReaderIdentifier: String?
    private var pageWork: Task<ReaderPage, Error>?
    private var answerTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var pageGeneration = 0
    private var answerGeneration = 0
    private var conversationGeneration = 0
    private var selectionGeneration = 0
    private var localContextGeneration = 0
    /// The resolver result for the current page, kept so chapter and book
    /// scopes can read the same local index without re-matching the page.
    private var localResult: ReadingContextResolver.Result?
    /// Changes whenever a page's local lookup starts, so a send can prove the
    /// passage it awaited still belongs to the page it confirmed.
    private var localResultGeneration = 0
    private var cardTask: Task<Void, Never>?
    private var cardObservation: AnyCancellable?
    private var deletionObservation: AnyCancellable?
    private var conversationChangeObservation: AnyCancellable?
    /// The last selection read through the reader (Kindle's Copy action),
    /// kept so a page refresh that reports no selection cannot erase it.
    private var acquiredSelection: String?
    /// The page identity a cached selection belongs to; a book switch or
    /// page move invalidates it even when the text repeats.
    private var acquiredSelectionKey: String?
    /// A clipboard-restoration warning survives the confirmation that clears
    /// ordinary notes.
    private var selectionWarning: String?
    private var failureKind: FailureKind?
    private var submittedRequest: AIRequest?
    private var submittedOnDevice = false
    /// The key this page's conversation is filed under; nil while the page
    /// is unidentified. Read-only outside the model.
    public private(set) var bookKey: String?

    public init(
        app: AppModel?, context: any ReaderContext,
        contextResolver: @escaping ContextResolver = { page, captures, archive in
            ReadingContextResolver.resolve(
                pageText: page.text, kind: page.kind, title: page.title,
                identifier: page.identifier, captures: captures,
                archive: archive)
        },
        answerProvider: @escaping AnswerProvider = { request, settings in
            try await AIService.answer(for: request, settings: settings)
        },
        promptProvider: PromptProvider? = nil
    ) {
        self.app = app
        self.readerContext = context
        self.contextResolver = contextResolver
        self.answerProvider = answerProvider
        self.promptProvider = promptProvider ?? { prompt, settings in
            try await AIService.answer(to: prompt, settings: settings)
        }
        // Removing a card in the library changes shared state, not this
        // model's own properties; forward that change so the per-turn
        // "In Cards" buttons re-render.
        cardObservation = app?.$cardTurnIDs.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        deletionObservation = app?.$deletedConversationIDs.sink {
            [weak self] deleted in
            Task { @MainActor in
                guard let self, let id = self.conversationID,
                    deleted.contains(id)
                else { return }
                self.resetKeepingUnsavedWrites()
                self.sendNote =
                    "This chat was deleted in the library; a new chat is "
                    + "ready."
            }
        }
        conversationChangeObservation = app?.$conversationChangeRevision.sink {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let id = self.conversationID,
                    self.app?.changedConversationIDs.contains(id) == true
                else { return }
                self.refreshCompactionFromArchive()
            }
        }
    }

    public convenience init(app: AppModel?) {
        let kind = ReaderContextLocator.preferredKind() ?? .kindle
        self.init(
            app: app, context: ReaderContextLocator.context(for: kind))
    }

    /// Waits for the current page load and the local-context lookup it
    /// started. The work signals its own completion; there is no deadline.
    public func awaitPageLoad() async {
        await pageTask?.value
        await localContextTask?.value
        // A stronger identity re-loads the book's history; await that too, so
        // the caller sees the settled conversation, not an empty one.
        await legacyMigrationTask?.value
        while let task = historyTask, historyLoading {
            await task.value
        }
    }

    /// Waits for the answer started by the last send, if any.
    public func awaitAnswer() async {
        await answerTask?.value
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

    /// A book label that never says "No book" while the reader supplied a
    /// usable identifier. The title arrives when the archive reload finishes;
    /// until then the ASIN is honest and specific.
    public var bookLabel: String {
        if !context.bookTitle.isEmpty { return context.bookTitle }
        if let title = identity?.book?.title, !title.isEmpty { return title }
        if let title = identity?.title, !title.isEmpty { return title }
        if let key = identity?.key, !key.isEmpty { return key }
        return "No book"
    }

    public var headerTitle: String {
        bookLabel == "No book" ? "Current Page" : bookLabel
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
        !pageText.isEmpty && !historyLoading && !historyLoadFailed
            && !persisting
            && pendingSave == nil && pendingPromotion == nil
            && compactionState != .running
            && !compactionRefreshing && !compactionRefreshFailed
            && !compactionRemoving && !transcriptRefreshing
            && (phase == .idle || phase == .ready)
    }

    public var canSave: Bool {
        turns.last?.persistedID != nil && !saved
    }

    public var canSend: Bool {
        canRun
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Compaction needs a persisted conversation; a session-only chat has no
    /// row to attach a summary to yet.
    public var canCompact: Bool {
        conversationID != nil && turns.count > ConversationCompactor.keepRecentTurns
            && turns.allSatisfy { $0.persistedID != nil }
            && !historyLoading && !historyLoadFailed && !persisting
            && !compactionRefreshing && !compactionRefreshFailed
            && !compactionRemoving && !transcriptRefreshing && phase != .loadingAnswer
            && compactionState != .running
    }

    public var canRetrySave: Bool {
        pendingSave != nil || pendingPromotion != nil
    }

    public var compactionCoveredTurnCount: Int {
        guard let compaction else { return 0 }
        return turns.filter {
            $0.persistedID.map { $0 <= compaction.throughTurnID } ?? false
        }.count
    }

    public var canOpenChats: Bool {
        identity?.book != nil
            || app?.books.contains(where: {
                guard let bookKey else { return false }
                return ConversationFiling.canonical($0.asin)
                    == ConversationFiling.canonical(bookKey)
            }) == true
    }

    /// A visible size warning when automatic compaction is off. It is a
    /// character estimate, not a token count.
    public var contextWarning: String? {
        guard let app, !app.settings.autoCompact else { return nil }
        let estimate = estimatedContextCharacters()
        guard estimate > app.settings.compactThresholdCharacters else {
            return nil
        }
        return "This request is about \(estimate.formatted()) characters. "
            + "Compact older turns to keep the conversation within the "
            + "provider's context."
    }

    /// What the info menu says about identity and coverage.
    ///
    /// A missing chapter is explained by the absence of local text that
    /// covers the page, and an unidentified page says where its chat stays,
    /// instead of guessing a title or quietly dropping the context.
    public var identityNote: String {
        var notes: [String] = []
        if let identity {
            switch identity.rank {
            case .sessionOnly:
                notes.append(
                    "This page could not be identified. The chat stays in "
                        + "this window and is not saved to the library.")
            case .captureText:
                notes.append(
                    "The book is identified by the captured page text.")
            case .titleMatch:
                notes.append("The book is identified by its Books title.")
                if context.chapter != nil {
                    notes.append(
                        "The EPUB text matched this page, but no archived "
                            + "edition was selected.")
                }
            case .lastOpened, .archiveMatch:
                if let title = identity.book?.title, !title.isEmpty {
                    notes.append("Book: \(title).")
                }
            }
        }
        if context.chapter == nil, !pageText.isEmpty {
            notes.append(
                "No chapter: the local book text does not cover this page.")
        }
        if context.pageLabel == nil, readerKind == .appleBooks {
            notes.append(
                "Apple Books exposes no page number through Accessibility.")
        }
        return notes.joined(separator: " ")
    }

    public var transmissionLabel: String {
        guard let request = submittedRequest else { return "Not sent" }
        if submittedOnDevice { return "Processed on this Mac" }
        let count = sentCharacters(for: request)
        switch request.scope {
        case .selection:
            return "Sent: selection and page · "
                + "\(count.formatted()) characters"
        case .currentChapter:
            return "Sent: current chapter · \(count.formatted()) characters"
        case .wholeBook:
            return "Sent: whole book · \(count.formatted()) characters"
        case .currentPage:
            return source?.disclosure == nil
                ? "Sent: current page"
                : "Sent: OCR text from the current page"
        }
    }

    /// The privacy line beside the info button must match the scope actually
    /// sent; saying "only this page" after a chapter send is false.
    public var transmissionDetail: String {
        guard let request = submittedRequest else {
            return "Nothing has been sent."
        }
        let what: String
        switch request.scope {
        case .selection:
            what = "The selection, its surrounding page, and the earlier "
                + "conversation are sent."
        case .currentPage:
            what = "Only this page and the earlier conversation are sent; "
                + "the rest of the book stays on this Mac."
        case .currentChapter:
            what = "Only this chapter and the earlier conversation are sent; "
                + "the rest of the book stays on this Mac."
        case .wholeBook:
            what = "The whole book and the earlier conversation are sent."
        }
        return what
    }

    /// Characters the prompt actually sends: the selection when present,
    /// otherwise the passage. The full passage goes out; there is no
    /// character cap.
    private func sentCharacters(for request: AIRequest) -> Int {
        let selection = request.selection?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if selection.isEmpty { return request.pageText.count }
        // A selection send carries the selection as the passage and the page
        // around it as appendix; both leave the Mac.
        return selection.count + request.pageText.count
    }

    public func openSavedNotes() { app?.openSavedNotesWindow?() }

    /// Opening must not send anything. The caller chooses when to read the
    /// page; `run()` is only reached from an explicit action.
    public func loadPage() {
        pageTask?.cancel()
        pageWork?.cancel()
        localContextTask?.cancel()
        followTask?.cancel()
        pageTask = nil
        pageWork = nil
        localContextTask = nil
        followTask = nil
        cancelAnswerWork()
        sendNote = nil
        acquiredSelection = nil
        acquiredSelectionKey = nil
        pageGeneration += 1
        conversationGeneration += 1
        selectionGeneration += 1
        let historyWasLoading = historyLoading
        historyLoading = false
        let generation = pageGeneration
        let previousKey = bookKey
        pageText = ""
        localResult = nil
        bookTitle = ""
        readerKind = nil
        source = nil
        pageIdentifier = nil
        livePageNumber = nil
        followedTurns = 0
        context = .empty
        phase = .loadingPage
        error = nil
        saveError = nil
        failureKind = nil
        submittedRequest = nil
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
                self.applyLivePage(page)
                self.lastReaderIdentifier = Self.identifierValue(
                    page.identifier)
                // Kindle hides the title with its chrome; its last-opened
                // ASIN identifies the book when the app can read Kindle's
                // container, and the archive supplies the title. Without
                // either, the page is genuinely unidentified: the chat stays
                // in memory instead of being filed under a placeholder and
                // mixed with every other Kindle book.
                // The identity order is the plan's: archive match, Kindle's
                // last-opened ASIN, capture text, Books title, session-only.
                // The capture and EPUB facts arrive after the page is shown;
                // `adopt` moves the key when they strengthen it.
                let facts = ReadingLiveFacts(
                    kind: page.kind, title: page.title,
                    identifier: page.identifier)
                let identity = ReadingIdentityResolver.resolve(
                    facts: facts, books: self.app?.books ?? [])
                self.identity = identity
                let title = identity.title
                self.bookTitle = title
                self.context = self.makeContext(for: page, identity: identity)
                let key = identity.key
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
                    if key != previousKey {
                        // The key already moved to the new book; its old
                        // turns must not survive to be sent by a retry.
                        self.turns = []
                        self.transcriptMutationGeneration += 1
                        self.conversationID = nil
                        self.conversations = []
                        self.resetCompaction()
                    }
                    if historyWasLoading, self.bookKey == previousKey {
                        self.loadConversationHistory()
                    }
                    return
                }
                self.phase = .idle
                if key != previousKey {
                    // The old book's turns must not be sent, or shown, while
                    // the new book's history loads.
                    self.turns = []
                    self.transcriptMutationGeneration += 1
                    self.conversationID = nil
                    self.conversations = []
                    self.resetCompaction()
                    self.loadConversationHistory()
                } else if historyWasLoading {
                    // The reload invalidated the in-flight history load; the
                    // same book still needs its stored turns.
                    self.loadConversationHistory()
                }
                self.resolveLocalContext(page: page)
                self.startFollowingPageTurns()
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
                if historyWasLoading, self.bookKey == previousKey {
                    // The reload invalidated the in-flight history load even
                    // though this page failed; a same-book Retry still needs
                    // the stored turns.
                    self.loadConversationHistory()
                }
            }
        }
    }

    /// Resolves the page's chapter and page number from local text: a
    /// non-DRM EPUB's navigation for Books, a captured book's `text.jsonl`
    /// for either reader. Live Accessibility alone cannot supply either.
    private func resolveLocalContext(page: ReaderPage) {
        guard let app else { return }
        // A result belongs to the page it was resolved from. Clear it before
        // the lookup so a failed resolution cannot leave the previous page's
        // chapter or book text in place.
        localResult = nil
        localResultGeneration += 1
        localContextGeneration += 1
        let generation = localContextGeneration
        // Read the captures from the archive, not the view model's copy:
        // the panel can open before the library reload has assigned it.
        let archive = app.archive
        let resolver = contextResolver
        let task = Task { [weak self] in
            // The panel is often created by the hotkey, which also creates
            // AppModel; its archive reload is still in flight here. Reading
            // `app.books` before it finishes makes a known ASIN look like an
            // unimported book, so the chip says "No book".
            await app.awaitArchiveLoaded()
            let books = app.books
            let result = await Task.detached {
                let captures = (try? archive?.captures()) ?? []
                return resolver(page, captures, archive)
            }.value
            guard let self, !Task.isCancelled,
                generation == self.localContextGeneration
            else { return }
            if let result {
                self.localResult = result
                if let chapter = result.chapter {
                    self.context.chapter = chapter
                }
                if let pageNumber = result.pageNumber,
                    self.context.pageNumber == nil
                {
                    self.context.pageNumber = pageNumber
                }
                let capture = result.capture.flatMap { record
                    -> CaptureEvidence? in
                    guard let fingerprint = result.fingerprint,
                        !fingerprint.isEmpty
                    else { return nil }
                    return CaptureEvidence(
                        fingerprint: fingerprint, title: record.title,
                        confidence: record.identityConfidence)
                }
                let improved = ReadingIdentityResolver.resolve(
                    facts: ReadingLiveFacts(
                        kind: page.kind, title: page.title,
                        identifier: page.identifier, capture: capture,
                        epubAssetID: result.assetID),
                    books: books)
                // Equal-ranked live evidence does not outrank an identity the
                // EPUB text proved: without an asset ID in this result, the
                // live identifier is a conflict, not an improvement.
                let currentIsEPUB =
                    self.identity?.evidence == .archiveEPUB
                let conflictingWithEPUB =
                    result.assetID == nil && currentIsEPUB
                    && improved.rank == self.identity?.rank
                    && improved.key != self.identity?.key
                let chosen: ReadingIdentity
                if conflictingWithEPUB, let current = self.identity {
                    chosen = current
                    self.migrateLegacyKeys(
                        current, fingerprint: result.fingerprint,
                        liveTitle: page.title, kind: page.kind)
                } else {
                    self.adopt(improved, archive: archive)
                    chosen = improved
                    self.migrateLegacyKeys(
                        improved, fingerprint: result.fingerprint,
                        liveTitle: page.title, kind: page.kind)
                }
                TsundokuDiagnostics.shared.event(
                    "local_context_resolved",
                    [
                        "chapter": result.chapter ?? "",
                        "page": result.pageNumber ?? -1,
                        "fingerprint": result.fingerprint ?? "",
                        "capture": result.capture?.directory ?? "",
                        "asset_id": result.assetID ?? "",
                        "identity_rank": chosen.rank.rawValue,
                        "identity_key": chosen.key ?? "unidentified",
                    ])
            } else if let identity = self.identity {
                // No local text covers this page. The archive may still have
                // arrived after the first identity pass; resolve again so a
                // known ASIN gets its book title instead of staying a bare
                // "last opened" key.
                let improved = ReadingIdentityResolver.resolve(
                    facts: ReadingLiveFacts(
                        kind: page.kind, title: page.title,
                        identifier: page.identifier),
                    books: books)
                if improved.rank <= identity.rank {
                    self.adopt(improved, archive: archive)
                }
                // A reader-supplied ASIN may also let an older title-keyed
                // chat move under it.
                self.migrateLegacyKeys(
                    identity, fingerprint: nil, liveTitle: page.title,
                    kind: page.kind)
            }
        }
        localContextTask = task
    }

    /// Moves chats filed under weaker keys that this page's text proves.
    ///
    /// The current page load only knows the key it started with. A thread
    /// begun before the ASIN was readable lives under `text:<fingerprint>`; a
    /// thread begun before an import lives under a Books title key. When the
    /// stronger identity is established, those rows move to it — idempotently,
    /// and only when the old key actually holds a conversation.
    private func migrateLegacyKeys(
        _ identity: ReadingIdentity, fingerprint: String?, liveTitle: String,
        kind: ReaderKind
    ) {
        guard let key = identity.key, identity.rank <= .lastOpened,
            let archive = app?.archive
        else { return }
        var legacy: [String] = []
        if let fingerprint, !fingerprint.isEmpty {
            legacy.append("text:\(fingerprint)")
        }
        if !ReadingIdentityResolver.isPlaceholder(liveTitle) {
            let normalized = ConversationKey.normalize(liveTitle)
            legacy.append("books:\(normalized)")
            // Pre-v2 Kindle chats used a `kindle:` title key. They are the
            // same book under weaker evidence and move with the rest.
            if kind == .kindle {
                legacy.append("kindle:\(normalized)")
            }
        }
        let candidates = legacy.filter { $0 != key }
        guard !candidates.isEmpty else { return }
        let title = identity.title
        let source = identity.book?.source
        let generation = conversationGeneration
        let task = Task { [weak self] in
            let migrated = await Task.detached {
                () -> (moved: Bool, error: String?) in
                var moved = false
                var firstError: String?
                for old in candidates {
                    do {
                        guard try archive.latestConversation(bookKey: old)
                            != nil
                        else { continue }
                        try archive.migrateConversations(
                            from: old, to: key, title: title, source: source)
                        moved = true
                    } catch {
                        firstError = firstError ?? "\(error)"
                    }
                }
                return (moved, firstError)
            }.value
            guard let self else { return }
            if let error = migrated.error {
                self.saveError =
                    "Could not file this book's earlier chats: \(error)"
            }
            guard migrated.moved, self.bookKey == key,
                generation == self.conversationGeneration,
                !self.persisting
            else { return }
            self.app?.refreshAICards()
            self.loadConversationHistory()
        }
        legacyMigrationTask = task
    }

    /// Adopts a stronger identity without starting a new conversation.
    ///
    /// A chat begun under a Books title or a capture fingerprint moves to the
    /// ASIN/asset ID that the local text later proves, in place; no thread is
    /// duplicated and no turn is lost. A weaker identity never replaces a
    /// stronger one, so a page with less local evidence cannot steal another
    /// book's history.
    private func adopt(_ improved: ReadingIdentity, archive: Archive?) {
        guard improved.rank <= (identity?.rank ?? .sessionOnly) else {
            return
        }
        let previous = identity
        // Equal evidence pointing at a different key is a conflict, not an
        // improvement — except that EPUB text outranks a reader identifier
        // at the same rank, which is how a duplicate edition is selected.
        if let previous, previous.rank == improved.rank,
            previous.key != improved.key,
            improved.evidence != .archiveEPUB
        {
            return
        }
        identity = improved
        guard let key = improved.key else {
            if bookTitle.isEmpty, !improved.title.isEmpty {
                bookTitle = improved.title
                context.bookTitle = improved.title
            }
            return
        }
        if bookKey != key, let previousKey = previous?.key,
            improved.rank < (previous?.rank ?? .sessionOnly)
                || (improved.rank == previous?.rank
                    && improved.evidence == .archiveEPUB)
        {
            do {
                try archive?.migrateConversations(
                    from: previousKey, to: key, title: improved.title,
                    source: improved.book?.source)
            } catch {
                saveError =
                    "Could not file this book's earlier chats: \(error)"
                identity = previous
                return
            }
            app?.refreshAICards()
            bookKey = key
            bookTitle = improved.title
            context.bookTitle = improved.title
            turns = []
            transcriptMutationGeneration += 1
            conversationID = nil
            conversations = []
            resetCompaction()
            loadConversationHistory()
            TsundokuDiagnostics.shared.event(
                "book_identity_migrated",
                ["from": previousKey, "to": key])
        } else if bookKey == nil, previous?.key == nil {
            // A session-only page gained a key. Turns answered while it had
            // no key exist only in memory; file them before anything reloads
            // a stored history over the top of them.
            let pending = turns
            bookKey = key
            bookTitle = improved.title
            context.bookTitle = improved.title
            if pending.isEmpty {
                loadConversationHistory()
            } else {
                persistTurns(pending, key: key, archive: archive)
            }
        } else if bookKey == key, bookTitle.isEmpty, !improved.title.isEmpty {
            bookTitle = improved.title
            context.bookTitle = improved.title
        }
    }

    /// Files turns that were answered while the page had no key. They stay in
    /// memory; the next page load reads the same turns back from the archive.
    private func persistTurns(
        _ pending: [AITurn], key: String, archive: Archive?,
        title explicitTitle: String? = nil,
        source explicitSource: BookSource? = nil
    ) {
        guard let archive else {
            // The turns exist only in this panel; keep them retryable.
            pendingPromotion = PendingPromotion(
                turns: pending, key: key,
                title: explicitTitle ?? context.bookTitle,
                source: explicitSource ?? context.bookSource)
            saveError =
                "Could not file this book's earlier chats: the archive is "
                + "not open. Retry Save once it is."
            return
        }
        let title = explicitTitle ?? context.bookTitle
        let source = explicitSource ?? context.bookSource
        let generation = conversationGeneration
        let turns = pending.map {
            NewConversationTurn(
                action: $0.action, question: $0.question, answer: $0.answer,
                provider: $0.provider, prompt: $0.prompt, context: $0.context)
        }
        beginPersistence()
        let previous = persistenceChain
        let task = Task { [weak self] in
            await previous?.value
            let stored = await Task.detached {
                () -> (Conversation, [Int64])? in
                // The conversation and every turn are one transaction; a
                // failure leaves no partially saved thread behind. The
                // inserted IDs come back from that transaction.
                try? archive.createConversationWithTurnIDs(
                    bookKey: key, bookTitle: title, bookSource: source,
                    turns: turns)
            }.value
            guard let self else { return }
            self.endPersistence()
            if let stored {
                self.pendingPromotion = nil
                if self.bookKey == key,
                    generation == self.conversationGeneration
                {
                    self.conversationID = stored.0.id
                }
                for (index, pendingTurn) in pending.enumerated()
                where index < stored.1.count
                {
                    if let position = self.turns.firstIndex(where: {
                        $0.id == pendingTurn.id
                    }) {
                        self.turns[position].persistedID = stored.1[index]
                    }
                }
                self.saveError = nil
                self.transcriptMutationGeneration += 1
                if self.needsTranscriptRefresh {
                    self.needsTranscriptRefresh = false
                    self.refreshCompactionFromArchive()
                }
                self.app?.refreshConversationCounts()
                self.app?.markConversationChanged(stored.0.id)
            } else {
                self.pendingPromotion = PendingPromotion(
                    turns: pending, key: key, title: title, source: source)
                self.saveError =
                    "Could not file this book's earlier chats. Retry Save."
            }
        }
        persistenceChain = task
    }

    // MARK: - Page turns

    /// Follows the reader's page while the panel is open.
    ///
    /// A page turn is detected by reading the live page, waiting one debounce
    /// interval for the page to settle, and adopting the settled page. The
    /// read runs off the main actor, so polling cannot stall typing.
    private func startFollowingPageTurns() {
        followTask?.cancel()
        let reader = readerContext
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval =
                    self?.followInterval ?? .milliseconds(600)
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.followPageOnce(reader: reader)
            }
        }
    }

    /// One follow step. Exposed so a test can drive page turns directly,
    /// without a timer or a wall-clock wait.
    public func followPageOnce() async {
        await followPageOnce(reader: readerContext)
    }

    private func followPageOnce(reader: any ReaderContext) async {
        guard phase != .loadingPage else { return }
        let first = await Task.detached { try? reader.page() }.value
        guard let first, !first.text.isEmpty, !Task.isCancelled else {
            return
        }
        if samePage(first) {
            // The page did not move, but a selection can change without one.
            applyReportedSelection(first.selection)
            TsundokuDiagnostics.shared.event(
                "selection_refreshed",
                [
                    "characters": context.selection?.count ?? 0,
                    "page": first.pageNumber ?? -1,
                ])
            return
        }
        if followDebounce > .zero {
            do {
                try await Task.sleep(for: followDebounce)
            } catch {
                return
            }
        }
        let settled = await Task.detached { try? reader.page() }.value
        guard let settled, !settled.text.isEmpty, !Task.isCancelled,
            !samePage(settled)
        else { return }
        applyPageTurn(settled)
    }

    private func samePage(_ page: ReaderPage) -> Bool {
        page.text == pageText && page.identifier == pageIdentifier
            && page.pageNumber == livePageNumber
    }

    private func beginPersistence() {
        persistenceCount += 1
        persisting = true
    }

    private func endPersistence() {
        persistenceCount = max(0, persistenceCount - 1)
        persisting = persistenceCount > 0
    }

    private func applyLivePage(_ page: ReaderPage) {
        pageText = page.text
        readerKind = page.kind
        source = page.source
        pageIdentifier = page.identifier
        livePageNumber = page.pageNumber
    }

    private static func identifierValue(_ value: String?) -> String? {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeContext(
        for page: ReaderPage, identity: ReadingIdentity
    ) -> AIContext {
        AIContext(
            bookTitle: identity.title,
            bookSource: identity.book?.source
                ?? (page.kind == .appleBooks ? .appleBooks : .kindle),
            reader: page.kind,
            pageNumber: page.pageNumber,
            pageCount: page.pageCount,
            selection: page.selection,
            excerpt: String(page.text.prefix(600))
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Adopts the settled page. A turn within a book keeps its conversation;
    /// a turn that changes the book starts the new book's history and stops an
    /// answer that belonged to the old one. A turn never rewrites an already
    /// stored turn: its caption was snapshotted when it was sent.
    private func applyPageTurn(_ page: ReaderPage) {
        let samePageText = page.text == pageText
        // The reader identifier before this turn, not the identity key: an
        // EPUB match can file the book under an archive ASIN while the reader
        // keeps reporting its own unchanged asset ID. Comparing against the
        // key would call that same-book conflict a switch on every turn.
        let previousIdentifier =
            lastReaderIdentifier
            ?? Self.identifierValue(pageIdentifier) ?? ""
        applyLivePage(page)
        // A selection read started for the previous page must not land on
        // this one.
        selectionGeneration += 1
        followedTurns += 1
        if phase == .failed, failureKind == .page {
            phase = .idle
            error = nil
            failureKind = nil
        }
        let liveIdentity = ReadingIdentityResolver.resolve(
            facts: ReadingLiveFacts(
                kind: page.kind, title: page.title,
                identifier: page.identifier),
            books: app?.books ?? [])
        // Live-only evidence is weaker than what the local text already
        // proved. A fingerprint-keyed page loses its capture match on the
        // next page; that is not a new book, and must not clear the chat.
        let liveIdentifier = Self.identifierValue(page.identifier) ?? ""
        let liveTitle =
            ReadingIdentityResolver.isPlaceholder(page.title)
            ? "" : page.title
        let currentIdentity = self.identity
        // A different archived edition of the same work: same title and
        // author, different identifier. That is a key move, not a new book.
        let duplicateEdition: Bool
        if let oldBook = currentIdentity?.book,
            currentIdentity?.evidence == .archiveEPUB,
            liveIdentity.evidence == .archiveIdentifier,
            let newBook = liveIdentity.book,
            oldBook.asin.caseInsensitiveCompare(newBook.asin)
                != .orderedSame,
            !newBook.title.isEmpty, !newBook.author.isEmpty,
            !oldBook.author.isEmpty,
            ConversationKey.normalize(newBook.title)
                == ConversationKey.normalize(oldBook.title),
            ConversationKey.normalize(newBook.author)
                == ConversationKey.normalize(oldBook.author)
        {
            duplicateEdition = true
        } else {
            duplicateEdition = false
        }
        let explicitNewBook: Bool
        if liveIdentifier.isEmpty {
            explicitNewBook = false
        } else if !previousIdentifier.isEmpty {
            explicitNewBook = liveIdentifier != previousIdentifier
        } else if let current = currentIdentity,
            current.rank != .sessionOnly
        {
            let keyDiffers =
                ConversationFiling.canonical(current.key ?? "")
                != liveIdentifier
            if current.evidence == .archiveEPUB {
                // The reader's asset ID is authoritative over a text match.
                // A proven duplicate edition is the only case that keeps the
                // thread; an unarchived identifier cannot be proven the same
                // book, so it starts a new chat rather than inheriting the
                // old one.
                explicitNewBook = keyDiffers && !duplicateEdition
            } else {
                // A title identity improves to an archived asset ID; it is a
                // new book only when the archive or the live title names a
                // different one.
                let matched = liveIdentity.book
                let matchedTitle = matched?.title ?? liveTitle
                let sameTitle =
                    !matchedTitle.isEmpty
                    && ConversationKey.normalize(matchedTitle)
                        == ConversationKey.normalize(current.title)
                let sameAuthor =
                    !(matched?.author ?? "").isEmpty
                    && !(current.book?.author ?? "").isEmpty
                    && ConversationKey.normalize(matched?.author ?? "")
                        == ConversationKey.normalize(
                            current.book?.author ?? "")
                let knownDifferent: Bool
                if let matched {
                    let sameBook = current.book.map {
                        $0.asin.caseInsensitiveCompare(matched.asin)
                            == .orderedSame
                    } ?? false
                    knownDifferent =
                        !sameBook && !(sameTitle && sameAuthor)
                } else {
                    knownDifferent = false
                }
                let titleDiffers =
                    matched == nil && !liveTitle.isEmpty
                    && !current.title.isEmpty
                    && ConversationKey.normalize(liveTitle)
                        != ConversationKey.normalize(current.title)
                explicitNewBook =
                    keyDiffers && (knownDifferent || titleDiffers)
            }
        } else {
            explicitNewBook = false
        }
        if !liveIdentifier.isEmpty {
            lastReaderIdentifier = liveIdentifier
        }
        // Adopt the reader's key for a duplicate edition and move the thread
        // under it, rather than letting the EPUB match suppress it forever.
        var migratedDuplicateEdition = false
        if duplicateEdition, !explicitNewBook,
            let current = currentIdentity,
            let newBook = liveIdentity.book,
            let oldKey = current.key, let newKey = liveIdentity.key
        {
            do {
                try app?.archive?.migrateConversations(
                    from: oldKey, to: newKey, title: newBook.title,
                    source: newBook.source)
            } catch {
                saveError =
                    "Could not file this book's earlier chats: \(error)"
            }
            app?.refreshAICards()
            migratedDuplicateEdition = true
        }
        let identity: ReadingIdentity
        if !migratedDuplicateEdition, let current = self.identity,
            !explicitNewBook,
            (liveIdentity.rank == .sessionOnly
                && current.rank != .sessionOnly)
                || (liveIdentity.rank == .archiveMatch
                    && current.evidence == .archiveEPUB)
        {
            // A page with no identity at all is not evidence of a new book;
            // keep what the local text proved. An explicit new ASIN or title
            // is a book change and falls through.
            identity = current
        } else {
            identity = liveIdentity
        }
        let bookChanged =
            identity.key != bookKey && !migratedDuplicateEdition
        self.identity = identity
        bookKey = identity.key
        bookTitle = identity.title
        context = makeContext(for: page, identity: identity)
        if page.selection != nil {
            acquiredSelection = page.selection
            acquiredSelectionKey = pageMarker
        } else if readerKind == .kindle, samePageText,
            let acquiredSelection, acquiredSelectionKey == pageMarker
        {
            context.selection = acquiredSelection
        } else {
            acquiredSelection = nil
            acquiredSelectionKey = nil
        }
        if bookChanged {
            answerTask?.cancel()
            answerTask = nil
            answerGeneration += 1
            if phase == .loadingAnswer { phase = .idle }
            turns = []
            transcriptMutationGeneration += 1
            conversationID = nil
            conversations = []
            resetCompaction()
            loadConversationHistory()
        }
        resolveLocalContext(page: page)
        TsundokuDiagnostics.shared.event(
            "page_turn_followed",
            [
                "page": page.pageNumber ?? -1,
                "book_changed": bookChanged,
                "book_key": identity.key ?? "unidentified",
                "selection": page.selection?.count ?? 0,
            ])
    }

    /// Reads the live selection again, without reloading the page. Called when
    /// the composer gains focus, because the reader may have selected text
    /// after the panel opened.
    /// Awaits the selection refresh started by choosing the Selection scope.
    public func awaitSelectionRefresh() async {
        await selectionTask?.value
    }

    public func refreshSelection() {
        guard !pageText.isEmpty, phase == .idle || phase == .ready else {
            return
        }
        selectionGeneration += 1
        let generation = selectionGeneration
        let book = bookTitle
        let page = pageText
        let reader = readerContext
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            var read: String?
            var overrideNote: String?
            let typed = await Task.detached {
                reader.selectionReading()
            }.value
            if let outcome = typed {
                read = outcome.text
                switch outcome {
                case .copiedButClipboardNotRestored:
                    overrideNote =
                        "The selection was read, but the clipboard could not "
                        + "be restored."
                case .failed(let reason):
                    overrideNote = reason
                case .copied, .noSelection:
                    break
                }
            } else {
                read = await Task.detached { reader.selectedText() }.value
            }
            guard
                let self, !Task.isCancelled,
                generation == self.selectionGeneration,
                self.bookTitle == book, self.pageText == page
            else { return }
            // Another app can change the pasteboard without supplying
            // Kindle's text; never attach unrelated content to this page.
            var selected = read
            var rejected = false
            if let value = read, !value.isEmpty,
                !SelectionText.belongs(value, toPage: page)
            {
                selected = nil
                rejected = true
                self.sendNote =
                    "The copied text did not match this page; select again "
                    + "in the reader."
            }
            self.context.selection = selected
            self.acquiredSelection = selected
            self.acquiredSelectionKey = self.pageMarker
            self.selectionWarning = overrideNote
            if self.scope == .selection, !rejected {
                self.sendNote =
                    overrideNote
                    ?? (selected?.isEmpty == false
                        ? nil
                        : "Select text in the reader; the companion reads the "
                            + "selection through the reader's Copy action.")
            }
            TsundokuDiagnostics.shared.event(
                "selection_refreshed",
                [
                    "characters": selected?.count ?? 0,
                    "page": self.context.pageNumber ?? -1,
                ])
        }
    }

    private struct ScopePassage: Sendable {
        let text: String
    }

    /// The local text a chapter or book send needs. Page and selection sends
    /// return immediately; only the larger scopes wait for, and read, the
    /// index that already matched this page.
    private func passageForScope(_ scope: CompanionScope) async -> ScopePassage? {
        guard scope == .currentChapter || scope == .wholeBook else {
            return nil
        }
        await localContextTask?.value
        guard let result = localResult, captureMatchesBook(result.capture)
        else { return nil }
        let page = context.pageNumber
        return await Task.detached {
            guard
                let text = ReadingContextResolver.scopeText(
                    scope, result: result, pageNumber: page),
                !text.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return ScopePassage(text: text)
        }.value
    }

    /// One policy for a selection reported by the live page: validate it,
    /// preserve Kindle's Copy-only selection for the same page, and clear it
    /// authoritatively when Books reports none.
    private func applyReportedSelection(_ selection: String?) {
        if let selection {
            if SelectionText.belongs(selection, toPage: pageText) {
                context.selection = selection
                acquiredSelection = selection
                acquiredSelectionKey = pageMarker
            } else {
                context.selection = nil
                acquiredSelection = nil
                acquiredSelectionKey = nil
                sendNote =
                    "The reader's selection did not match this page; "
                    + "select again."
            }
        } else if readerKind == .kindle, acquiredSelection != nil,
            acquiredSelectionKey == pageMarker
        {
            context.selection = acquiredSelection
        } else {
            context.selection = nil
            acquiredSelection = nil
            acquiredSelectionKey = nil
        }
    }

    private var pageMarker: String {
        "\(bookKey ?? "")|\(livePageNumber ?? -1)|\(pageText)"
    }

    /// A page match does not prove the capture is this book: shared front
    /// matter can match another edition. Chapter/book text is only sent when
    /// the capture's identifier or title agrees with the panel's book.
    private func captureMatchesBook(_ record: CaptureRecord?) -> Bool {
        guard let record else { return true }
        // A title is supplied by the resolver itself; only an identifier is
        // independent evidence that this capture belongs to this book.
        guard !record.asin.isEmpty, let bookKey, !bookKey.isEmpty
        else { return false }
        if let confidence = record.identityConfidence {
            guard confidence.lowercased().hasPrefix("exact:")
            else { return false }
        }
        return record.asin.caseInsensitiveCompare(bookKey) == .orderedSame
    }

    public func run() {
        guard canRun else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == .ask, text.isEmpty { return }
        let requested = action
        let requestedScope = scope
        sendGeneration += 1
        let generation = sendGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            if requestedScope == .selection {
                self.refreshSelection()
                await self.awaitSelectionRefresh()
            }
            let freshness = await self.confirmPageIsCurrent()
            guard !Task.isCancelled, generation == self.sendGeneration else {
                return
            }
            // A move to another book is not a page turn: the question was
            // written about the book that is no longer on screen, so it must
            // not be sent to the new one.
            guard freshness != .bookChanged else { return }
            let bookAtSend = self.bookKey
            let pageAtSend = self.pageText
            let resultGeneration = self.localResultGeneration
            let passage = await self.passageForScope(requestedScope)
            guard !Task.isCancelled, generation == self.sendGeneration else {
                return
            }
            guard self.bookKey == bookAtSend,
                self.pageText == pageAtSend,
                self.localResultGeneration == resultGeneration
            else {
                self.sendNote =
                    "The reader moved while the passage was prepared; send "
                    + "again for the current page."
                return
            }
            // The page is the only passage actually available; sending it
            // under a chapter or whole-book label would misdescribe it.
            let fellBack =
                passage == nil
                && (requestedScope == .currentChapter
                    || requestedScope == .wholeBook)
            let effectiveScope: CompanionScope =
                fellBack ? .currentPage : requestedScope
            if fellBack {
                self.sendNote =
                    "No local capture covers this "
                    + "\(requestedScope.displayName.lowercased()). Capture "
                    + "the book as PDF in Exports, then retry; the page was "
                    + "sent instead."
            }
            let settings = self.app?.settings ?? .defaults
            let projectionAtCompose = self.promptProjection()
            let conversationAtCompose = self.conversationGeneration
            let transcriptAtCompose = self.transcriptMutationGeneration
            let preview = self.makeRequest(
                action: requested, question: text, scope: effectiveScope,
                passage: passage, projection: projectionAtCompose)
            let previewCharacters = AIComposer.prompt(
                for: preview, settings: settings).count
            var compactedForSend = false
            var attemptedAutoCompaction = false
            if settings.autoCompact,
                previewCharacters > settings.compactThresholdCharacters,
                self.canCompact
            {
                attemptedAutoCompaction = true
                switch await self.compactNow() {
                case .failed:
                    self.sendNote =
                        "Automatic compaction failed; the message was not "
                        + "sent. Retry Compact or send again."
                    return
                case .compacted:
                    compactedForSend = true
                case .unnecessary:
                    break
                }
            }
            guard !Task.isCancelled, generation == self.sendGeneration else {
                return
            }
            let finalProjection: ConversationProjection? =
                compactedForSend ? nil
                : (attemptedAutoCompaction ? self.promptProjection()
                    : projectionAtCompose)
            guard self.conversationGeneration == conversationAtCompose,
                self.transcriptMutationGeneration == transcriptAtCompose,
                !self.compactionRefreshing, !self.compactionRemoving,
                !self.transcriptRefreshing
            else {
                self.sendNote =
                    "The conversation changed while the message was being "
                    + "prepared; send again."
                return
            }
            self.startRequest(
                action: requested, question: text,
                scope: effectiveScope, passage: passage,
                projection: finalProjection)
        }
        sendPreparationTask = task
    }

    /// Confirms the live page before a send, and adopts it when it moved.
    ///
    /// This is what makes a page turn followed by a send use the new page
    /// even when the debounced follow has not caught up. An unreadable reader
    /// keeps the page last read, with a visible note rather than a silent
    /// stale send.
    public func confirmPageIsCurrent() async -> PageFreshness {
        guard !pageText.isEmpty, phase != .loadingPage else {
            lastFreshness = .unconfirmed
            return .unconfirmed
        }
        let reader = readerContext
        let read = await Task.detached { try? reader.page() }.value
        guard !Task.isCancelled else { return .unconfirmed }
        guard let read, !read.text.isEmpty else {
            lastFreshness = .unconfirmed
            sendNote =
                "Could not confirm the page is current; the page last read "
                + "will be sent."
            return .unconfirmed
        }
        if samePage(read) {
            // The page is current; a selection may still have changed since
            // the last follow. Kindle reports no selection from page(), so an
            // explicitly acquired selection survives this refresh.
            applyReportedSelection(read.selection)
            lastFreshness = .current
            sendNote = selectionWarning
            return .current
        }
        guard !Task.isCancelled else { return .unconfirmed }
        let previousKey = bookKey
        applyPageTurn(read)
        await localContextTask?.value
        guard !Task.isCancelled else { return .unconfirmed }
        if bookKey != previousKey {
            lastFreshness = .bookChanged
            sendNote =
                "The reader moved to another book; the page was reloaded. "
                + "Send again if you meant the new page."
            return .bookChanged
        }
        let label = read.pageNumber.map { "page \($0)" } ?? "the new page"
        lastFreshness = .refreshed(read.pageNumber)
        sendNote = "The page changed while you were typing; \(label) was sent."
        return .refreshed(read.pageNumber)
    }

    private enum CompactionOutcome {
        case compacted
        case unnecessary
        case failed
    }

    private func makeRequest(
        action: AIAction, question text: String, scope: CompanionScope,
        passage: ScopePassage?, projection: ConversationProjection? = nil
    ) -> AIRequest {
        let settings = app?.settings ?? .defaults
        let selectedPassage: String? =
            scope == .selection ? context.selection : nil
        let projection = projection ?? promptProjection()
        return AIRequest(
            action: action,
            pageText: passage?.text ?? pageText,
            bookTitle: bookTitle, question: text,
            language: settings.language, selection: selectedPassage,
            pageNumber: context.pageNumber, pageCount: context.pageCount,
            chapter: context.chapter,
            history: projection.history,
            conversationSummary: projection.summary,
            scope: scope)
    }

    private func promptProjection() -> ConversationProjection {
        guard let compaction else {
            return .full(turns.map(\.exchange))
        }
        let history = turns.filter { turn in
            guard let id = turn.persistedID else { return true }
            return id > compaction.throughTurnID
        }.map(\.exchange)
        return ConversationProjection(
            summary: compaction.summary, history: history,
            throughTurnID: compaction.throughTurnID)
    }

    private func estimatedContextCharacters() -> Int {
        let selection = context.selection?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var total = pageText.count + selection.count + bookTitle.count
        if let compaction {
            total += compaction.summary.count
        }
        let projectedTurns: [AITurn] =
            compaction.map { value in
                turns.filter { turn in
                    guard let id = turn.persistedID else { return true }
                    return id > value.throughTurnID
                }
            } ?? turns
        for turn in projectedTurns {
            total += turn.question.count + turn.answer.count
            total += turn.context.excerpt.count
        }
        return total
    }

    /// Runs a compaction and publishes only a successfully stored result.
    /// Cancellation and provider failure leave the previous summary intact.
    private func compactNow() async -> CompactionOutcome {
        guard let archive = app?.archive, let conversationID
        else { return .failed }
        guard compactionState != .running else { return .failed }
        compactionGeneration += 1
        let generation = compactionGeneration
        let settings = app?.settings ?? .defaults
        let promptProvider = promptProvider
        let compactor = ConversationCompactor(
            archive: archive,
            provider: { prompt in
                try await promptProvider(prompt, settings)
            },
            providerName: AIService.providerName(for: settings),
            model: settings.model.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
                ? nil : settings.model,
            language: settings.language)
        compactionState = .running
        compactionError = nil
        do {
            let result = try await compactor.compact(
                conversationID: conversationID)
            // The write committed; library views must refresh even if this
            // panel was cancelled or switched in the meantime.
            app?.markConversationChanged(conversationID)
            guard generation == compactionGeneration,
                !Task.isCancelled
            else {
                // A cancellation that landed while the provider was
                // finishing must not leave a summary the reader stopped.
                // Remove only the new row; the previous summary stays.
                do {
                    try archive.removeCompaction(
                        id: result.id, conversationID: conversationID)
                    app?.markConversationChanged(conversationID)
                } catch {
                    let message =
                        "The compaction completed after cancellation and "
                        + "could not be rolled back: \(error)"
                    if generation == compactionGeneration,
                        self.conversationID == conversationID
                    {
                        compactionState = .failed(message)
                        compactionError = message
                    } else {
                        // The panel now shows another chat, or a newer
                        // compaction owns its state; a banner reports this
                        // without overwriting that chat's panel.
                        app?.post(message, seconds: 10)
                    }
                }
                return .failed
            }
            compaction = result
            compactionState = .idle
            return .compacted
        } catch {
            guard generation == compactionGeneration else { return .failed }
            if AIProviderFailure.isCancelled(error) {
                compactionState = .idle
                return .failed
            }
            if let compactionFailure = error as? ConversationCompactionError {
                switch compactionFailure {
                case .noNewTurns, .notEnoughTurns:
                    compactionState = .idle
                    return .unnecessary
                case .emptySummary:
                    break
                }
            }
            let message: String
            if error is ConversationCompactionError {
                message = "\(error)"
            } else {
                message = AIProviderFailure.message(
                    for: error, provider: settings.provider)
            }
            compactionState = .failed(message)
            compactionError = message
            return .failed
        }
    }

    /// Manual Compact. A conversation with three or fewer turns has nothing
    /// to summarize; the UI disables the action in that case.
    public func compactConversation() {
        guard canCompact else { return }
        manualCompactionToken += 1
        let token = manualCompactionToken
        compactionTask?.cancel()
        compactionTask = Task { [weak self] in
            guard let self else { return }
            switch await self.compactNow() {
            case .unnecessary:
                self.sendNote =
                    "There are no newer turns to summarize; the latest "
                    + "summary already covers them."
            case .compacted:
                self.sendNote = "Older turns were summarized for the model."
            case .failed:
                break
            }
            if token == self.manualCompactionToken {
                self.compactionTask = nil
            }
        }
    }

    public func removeCompaction() {
        guard let archive = app?.archive, let conversationID,
            let expectedCompactionID = compaction?.id
        else { return }
        compactionGeneration += 1
        compactionRemovalGeneration += 1
        let removalGeneration = compactionRemovalGeneration
        compactionTask?.cancel()
        compactionTask = nil
        let generation = compactionGeneration
        compactionState = .idle
        compactionError = nil
        compactionRemoving = true
        let app = app
        Task { [weak self] in
            do {
                try await Task.detached {
                    try archive.clearCompaction(
                        conversationID: conversationID,
                        expectedCompactionID: expectedCompactionID)
                }.value
                app?.markConversationChanged(conversationID)
                guard let self else { return }
                if removalGeneration == self.compactionRemovalGeneration {
                    self.compactionRemoving = false
                }
                guard generation == self.compactionGeneration else {
                    return
                }
                self.compaction = nil
                self.consumeNeedsTranscriptRefresh()
            } catch {
                guard let self else { return }
                if removalGeneration == self.compactionRemovalGeneration {
                    self.compactionRemoving = false
                }
                guard generation == self.compactionGeneration else {
                    return
                }
                let message = "Could not remove the summary: \(error)"
                self.compactionError = message
                self.compactionState = .failed(message)
            }
        }
    }

    public func openChats() {
        guard let book = identity?.book
            ?? app?.books.first(where: {
                guard let bookKey else { return false }
                return ConversationFiling.canonical($0.asin)
                    == ConversationFiling.canonical(bookKey)
            })
        else {
            sendNote = "Open an imported book before managing its chats."
            return
        }
        app?.openChats(for: book)
    }

    public func reviewCurrentChatDeletion() {
        guard let archive = app?.archive, let conversationID else {
            return
        }
        pendingDeletionID = conversationID
        Task { [weak self] in
            do {
                let reviewed = try await Task.detached {
                    try archive.deletionReview(ids: [conversationID])
                }.value
                guard let self, self.pendingDeletionID == conversationID
                else { return }
                self.pendingDeletionUpdatedAt =
                    reviewed.updatedAt[conversationID]
                self.pendingDeletionCompactionRevision =
                    reviewed.revisions[conversationID] ?? 0
                self.pendingDeletionCardNoteIDs = reviewed.cardNoteIDs
                self.pendingDeletionBookKey = self.bookKey
                self.pendingDeletionBookSource = self.context.bookSource
                self.deletionImpact = reviewed.impact
            } catch {
                self?.sendNote = "Could not inspect this chat: \(error)"
            }
        }
    }

    public func dismissChatDeletion() {
        pendingDeletionID = nil
        pendingDeletionUpdatedAt = nil
        pendingDeletionCompactionRevision = nil
        pendingDeletionCardNoteIDs = nil
        pendingDeletionBookKey = nil
        pendingDeletionBookSource = nil
        deletionImpact = nil
    }

    public func deleteCurrentChat() {
        guard let archive = app?.archive,
            let id = pendingDeletionID ?? conversationID,
            let updatedAt = pendingDeletionUpdatedAt,
            let revision = pendingDeletionCompactionRevision
        else { return }
        let expectedBookKey = pendingDeletionBookKey
        let expectedBookSource = pendingDeletionBookSource
        let expectedCardNoteIDs = pendingDeletionCardNoteIDs
        pendingDeletionID = nil
        pendingDeletionUpdatedAt = nil
        pendingDeletionCompactionRevision = nil
        pendingDeletionCardNoteIDs = nil
        pendingDeletionBookKey = nil
        pendingDeletionBookSource = nil
        deletionImpact = nil
        Task { [weak self] in
            do {
                _ = try await Task.detached {
                    try archive.deleteConversations(
                        ids: [id], expectedUpdatedAt: [id: updatedAt],
                        expectedCompactionRevisions: [id: revision],
                        expectedBookKeys: expectedBookKey.map { [$0] },
                        expectedBookSource: expectedBookSource,
                        expectedCardNoteIDs: expectedCardNoteIDs)
                }.value
                guard let self else { return }
                self.app?.markConversationsDeleted([id])
                self.app?.refreshConversationCounts()
                if self.conversationID == id {
                    self.resetKeepingUnsavedWrites()
                    self.sendNote =
                        "The chat was deleted. Saved notes remain; its cards "
                        + "were removed from Cards."
                }
            } catch {
                self?.sendNote = "Could not delete this chat: \(error)"
            }
        }
    }

    private func startRequest(
        action: AIAction, question text: String, scope: CompanionScope,
        passage: ScopePassage?, projection: ConversationProjection? = nil
    ) {
        guard canRun else {
            if !Task.isCancelled {
                sendNote =
                    "The conversation changed while the message was being "
                    + "prepared; send again."
            }
            return
        }
        if action == .ask, text.isEmpty { return }
        let settings = app?.settings ?? .defaults
        if scope == .selection, !selectionAvailable {
            sendNote =
                "Nothing is selected; select text in the reader and retry."
            return
        }
        let selectedPassage: String? =
            scope == .selection ? context.selection : nil
        let request = makeRequest(
            action: action, question: text, scope: scope, passage: passage,
            projection: projection)
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
        TsundokuDiagnostics.shared.event(
            "ai_request_started",
            [
                "action": action.rawValue,
                "characters": pageText.count,
                "provider": settings.provider.rawValue,
                "turns": turns.count,
                "selection": request.selection?.count ?? 0,
            ])
        // The stored caption must describe what was sent, not a selection
        // the page scope deliberately left out.
        var turnContext = context
        turnContext.scope = scope
        turnContext.selection = selectedPassage
        if let passage {
            turnContext.excerpt = String(passage.text.prefix(600))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let conversationAtSend = conversationID
        let conversationGenerationAtSend = conversationGeneration
        let provider = answerProvider
        answerTask = Task { [weak self] in
            do {
                let result = try await provider(request, settings)
                guard
                    let self, !Task.isCancelled,
                    generation == self.answerGeneration
                else { return }
                let turn = AITurn(
                    action: request.action, question: text,
                    answer: result.text, provider: result.provider,
                    prompt: prompt, context: turnContext)
                self.turns.append(turn)
                self.transcriptMutationGeneration += 1
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
        selectionTask?.cancel()
        localContextTask?.cancel()
        followTask?.cancel()
        pageTask = nil
        pageWork = nil
        selectionTask = nil
        localContextTask = nil
        followTask = nil
        cancelAnswerWork()
        sendNote = nil
        acquiredSelection = nil
        acquiredSelectionKey = nil
        pageGeneration += 1
        selectionGeneration += 1
        compactionGeneration += 1
        compactionRemovalGeneration += 1
        manualCompactionToken += 1
        compactionTask?.cancel()
        compactionTask = nil
        compactionRefreshing = false
        compactionRemoving = false
        compactionRefreshFailed = false
        // A refresh this invalidation discarded must be replaced, or the
        // next send could read a summary or transcript older than the
        // archive.
        needsTranscriptRefresh = true
        consumeNeedsTranscriptRefresh()
        if case .running = compactionState { compactionState = .idle }
        phase = .idle
        error = nil
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        TsundokuDiagnostics.shared.event("ai_work_cancelled")
    }

    /// Cancel the answer and any prepared send, and invalidate both
    /// generations so a late result cannot publish. Every caller that starts
    /// new answer work goes through here; only the operation-specific reset
    /// stays local.
    private func cancelAnswerWork() {
        answerTask?.cancel()
        answerTask = nil
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        sendGeneration += 1
        answerGeneration += 1
    }

    /// Stops the answer, not the panel: page following continues, so the next
    /// send uses the current page.
    public func stopAnswer() {
        cancelAnswerWork()
        if phase == .loadingAnswer { phase = .idle }
        error = nil
        failureKind = nil
    }

    /// Starts a fresh conversation about the same book. Earlier conversations
    /// stay in the history menu and in the library.
    public func newChat() {
        cancelAnswerWork()
        sendNote = nil
        conversationGeneration += 1
        turns = []
        transcriptMutationGeneration += 1
        conversationID = nil
        savedTurnID = nil
        historyLoading = false
        historyLoadFailed = false
        failedConversationID = nil
        transcriptRefreshGeneration += 1
        transcriptRefreshing = false
        resetCompaction()
        resetPendingSave()
        pendingDeletionID = nil
        pendingDeletionUpdatedAt = nil
        pendingDeletionCompactionRevision = nil
        pendingDeletionCardNoteIDs = nil
        pendingDeletionBookKey = nil
        pendingDeletionBookSource = nil
        deletionImpact = nil
        error = nil
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        // Any in-flight conversation load was invalidated above; leaving
        // `.loadingPage` here would disable sending forever.
        phase = .idle
        TsundokuDiagnostics.shared.event("ai_conversation_cleared")
    }

    /// Switches to an earlier conversation of the same book.
    public func openConversation(
        _ id: Int64, expectedBookKey: String? = nil,
        expectedBookSource: BookSource? = nil, force: Bool = false
    ) {
        if let expectedBookKey, let bookKey,
            ConversationFiling.canonical(expectedBookKey)
                != ConversationFiling.canonical(bookKey)
        {
            sendNote =
                "This chat belongs to another book. Open that book in the "
                + "reader, then continue."
            return
        }
        guard let archive = app?.archive else { return }
        // Re-selecting the conversation already on screen is a no-op. Doing
        // this after cancellation would stop its in-flight answer and leave
        // the phase reading as loading forever.
        if !force, id == conversationID, !turns.isEmpty { return }
        // A session-only transcript exists nowhere else. Loading a stored
        // chat over it would destroy the only copy; New Chat is the
        // explicit discard action. A write already in flight keeps its own
        // copy, so it does not block the switch.
        if !persisting, pendingSave == nil, pendingPromotion == nil,
            turns.contains(where: { $0.persistedID == nil })
        {
            sendNote =
                "This page's answers are not saved yet. Start a new chat to "
                + "discard them, or open the chat once the page's book is "
                + "identified."
            return
        }
        cancelAnswerWork()
        resetCompaction()
        dismissChatDeletion()
        transcriptRefreshGeneration += 1
        transcriptRefreshing = false
        failedConversationID = nil
        sendNote = nil
        conversationGeneration += 1
        selectionGeneration += 1
        let generation = conversationGeneration
        phase = .loadingPage
        Task { [weak self] in
            do {
                // Identity and transcript come from one read transaction; a
                // concurrent re-filing cannot validate the old book and then
                // load turns for another.
                let loaded = try await Task.detached {
                    try archive.conversationExportSnapshot(
                        conversationID: id)
                }.value
                guard
                    let self, !Task.isCancelled,
                    generation == self.conversationGeneration
                else { return }
                guard let loaded else {
                    self.historyLoading = false
                    self.sendNote = "This chat no longer exists."
                    self.phase = .ready
                    // The switch reset the summary before validation; the
                    // chat still on screen must read its boundary again.
                    self.refreshCompactionFromArchive()
                    return
                }
                if let expectedBookKey {
                    let conversation = loaded.conversation
                    let book = self.app?.books.first {
                        ConversationFiling.canonical($0.asin)
                            == ConversationFiling.canonical(expectedBookKey)
                            && (expectedBookSource == nil
                                || $0.source == expectedBookSource)
                    }
                    let matches = book.map {
                        ConversationFiling.isFiled(conversation, under: $0)
                    } ?? (ConversationFiling.canonical(
                        conversation.bookKey)
                        == ConversationFiling.canonical(expectedBookKey))
                    // A stored source that disagrees with the route is
                    // stronger evidence than a matching identifier: two
                    // readers can share one.
                    let sourceMatches =
                        expectedBookSource == nil
                        || conversation.bookSource == nil
                        || conversation.bookSource == expectedBookSource
                    guard matches, sourceMatches else {
                        self.historyLoading = false
                        self.sendNote =
                            "This chat belongs to another book. Open that "
                            + "book in the reader, then continue."
                        self.phase = .ready
                        self.refreshCompactionFromArchive()
                        return
                    }
                }
                self.apply(
                    stored: loaded.snapshot.turns,
                    cardIDs: loaded.snapshot.cardIDs,
                    conversationID: id,
                    compaction: loaded.snapshot.compaction)
                // A compaction notification may have arrived while this
                // snapshot was in flight, when the old selection was still
                // current. Re-read the boundary for the chat now on screen.
                self.refreshCompactionFromArchive()
            } catch {
                guard let self, !Task.isCancelled,
                    generation == self.conversationGeneration
                else { return }
                self.historyLoading = false
                self.historyLoadFailed = true
                self.failedConversationID = id
                self.error = "Could not read this conversation: \(error)"
                self.phase = .ready
                // Restore the boundary and transcript of the chat that is
                // still on screen; the switch cleared them before the read.
                self.refreshCompactionFromArchive()
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
        guard
            let asin = identity?.book?.asin ?? pageIdentifier
                ?? matchedBook()?.asin
        else {
            saveError =
                "This page could not be matched to a single archived book. "
                + "Import the library and try again."
            return
        }
        guard let turnID = turn.persistedID else {
            saveError = "This answer is still being saved; try again."
            return
        }
        do {
            _ = try archive.saveAISNote(
                asin: asin, position: nil,
                kind: turn.action.rawValue, prompt: turn.prompt,
                answer: turn.answer, provider: turn.provider,
                source: readerKind.map { $0 == .kindle ? .kindle : .appleBooks },
                turnID: turnID)
            savedTurnID = turn.id
            app?.refreshAINotes()
            saveError = nil
        } catch {
            saveError = "Could not save: \(error)"
        }
    }

    /// Promote a persisted answer to a card in the book's Cards view.
    /// Add and Save share the same row; the unique turn index makes a second
    /// click harmless.
    public func addToCards(_ turn: AITurn) {
        guard let app, let archive = app.archive, let asin = cardBookASIN
        else {
            saveError =
                "This page could not be matched to a single archived book. "
                + "Import the library and try again."
            return
        }
        guard let turnID = turn.persistedID else {
            saveError = "This answer is still being saved; try again."
            return
        }
        let source = readerKind.map {
            $0 == .kindle ? BookSource.kindle : .appleBooks
        }
        let task = Task { [weak self] in
            // A Remove started earlier must land first; the archive's serial
            // queue does not preserve user-action order across detached tasks.
            await app.awaitCardRemoval()
            do {
                _ = try await Task.detached {
                    try archive.saveAISNote(
                        asin: asin, position: nil,
                        kind: turn.action.rawValue, prompt: turn.prompt,
                        answer: turn.answer, provider: turn.provider,
                        source: source,
                        turnID: turnID, markCard: true)
                }.value
                guard let self else { return }
                self.cardedTurnIDs.insert(turnID)
                app.registerCard(turnID: turnID)
                self.saveError = nil
                app.refreshAINotes()
                app.refreshAICards()
            } catch {
                self?.saveError = "Could not add this card: \(error)"
            }
        }
        cardTask = task
    }

    /// Waits for the last Add to Cards write. Tests use it so they assert on
    /// the stored row rather than race a fixed polling window.
    public func awaitCardSave() async {
        await cardTask?.value
    }

    /// The archived book a card is filed under. Unlike Save Note, a card is
    /// only for an archived book; a session-only page has no stable home.
    private var cardBookASIN: String? {
        if let asin = identity?.book?.asin, !asin.isEmpty { return asin }
        if let pageIdentifier, !pageIdentifier.isEmpty {
            return app?.books.first {
                $0.asin.caseInsensitiveCompare(pageIdentifier) == .orderedSame
            }?.asin
        }
        return matchedBook()?.asin
    }

    public func isCarded(_ turn: AITurn) -> Bool {
        guard let id = turn.persistedID else { return false }
        // The library may remove a card while this panel is open. Once the
        // shared set has loaded, it is the source of truth so the button can
        // return to "Add to Cards" without reopening the panel.
        if let app, app.aiCardsLoaded {
            return app.cardTurnIDs.contains(id)
        }
        return cardedTurnIDs.contains(id)
    }

    public var canCard: Bool { cardBookASIN != nil }

    // MARK: - Conversation history

    private func resetCompaction() {
        compactionGeneration += 1
        compactionRemovalGeneration += 1
        manualCompactionToken += 1
        compactionTask?.cancel()
        compactionTask = nil
        compaction = nil
        compactionState = .idle
        compactionError = nil
        compactionRefreshing = false
        compactionRefreshFailed = false
        compactionRemoving = false
    }

    /// A library window can append turns, compact, or remove a summary while
    /// this panel is open. Re-read the transcript and boundary together; the
    /// live page stays where it is.
    private func refreshCompactionFromArchive() {
        guard let archive = app?.archive, let id = conversationID else {
            return
        }
        if transcriptRefreshing {
            needsTranscriptRefresh = true
            return
        }
        if persisting || pendingSave != nil || pendingPromotion != nil
            || turns.contains(where: { $0.persistedID == nil })
        {
            // Never replace an unsaved answer with an older snapshot. The
            // save path retries this refresh once persistence settles.
            needsTranscriptRefresh = true
            return
        }
        compactionGeneration += 1
        compactionTask?.cancel()
        compactionTask = nil
        compactionState = .idle
        compactionError = nil
        compactionRefreshing = true
        compactionRefreshFailed = false
        let compactionGeneration = compactionGeneration
        transcriptRefreshGeneration += 1
        let transcriptGeneration = transcriptRefreshGeneration
        let mutation = transcriptMutationGeneration
        Task { [weak self] in
            do {
                let snapshot = try await Task.detached {
                    try archive.conversationSnapshot(conversationID: id)
                }.value
                guard let self,
                    transcriptGeneration == self.transcriptRefreshGeneration,
                    compactionGeneration == self.compactionGeneration,
                    mutation == self.transcriptMutationGeneration,
                    self.conversationID == id
                else {
                    if let self,
                        transcriptGeneration == self.transcriptRefreshGeneration,
                        compactionGeneration == self.compactionGeneration
                    {
                        self.needsTranscriptRefresh = true
                        self.compactionRefreshing = false
                        self.consumeNeedsTranscriptRefresh()
                    }
                    return
                }
                self.turns = snapshot.turns.map(Self.turn(from:))
                self.transcriptMutationGeneration += 1
                self.cardedTurnIDs = snapshot.cardIDs
                self.compaction = snapshot.compaction
                self.compactionRefreshing = false
                self.compactionRefreshFailed = false
                self.compactionError = nil
                self.needsTranscriptRefresh = false
            } catch {
                guard let self,
                    transcriptGeneration == self.transcriptRefreshGeneration,
                    compactionGeneration == self.compactionGeneration
                else { return }
                self.compactionRefreshing = false
                self.compactionRefreshFailed = true
                self.compactionError =
                    "Could not refresh the conversation summary: \(error)"
            }
        }
    }

    public func retryCompactionRefresh() {
        refreshCompactionFromArchive()
    }

    /// A refresh that lost to a mutation leaves `needsTranscriptRefresh`
    /// set. When that mutation was itself a settled save, no later
    /// completion would consume the flag; read again now, so a stale
    /// transcript or summary cannot reach the next request.
    private func consumeNeedsTranscriptRefresh() {
        guard needsTranscriptRefresh, !transcriptRefreshing,
            !compactionRefreshing, !compactionRemoving,
            !persisting, pendingSave == nil, pendingPromotion == nil,
            !turns.contains(where: { $0.persistedID == nil }),
            conversationID != nil
        else { return }
        needsTranscriptRefresh = false
        refreshCompactionFromArchive()
    }

    /// Retry a failed history read without reloading the page or sending.
    public func retryHistory() {
        guard historyLoadFailed else { return }
        if let id = failedConversationID {
            openConversation(id, force: true)
        } else {
            loadConversationHistory()
        }
    }

    private func resetPendingSave() {
        pendingSave = nil
        pendingPromotion = nil
    }

    /// Starts a fresh chat without discarding an answer that never reached
    /// the archive. A delete is not the explicit discard action New Chat is;
    /// the pending write is retargeted at a new conversation, so Retry Save
    /// stores it instead of appending to a deleted row.
    @discardableResult
    private func resetKeepingUnsavedWrites() -> Bool {
        let unsaved = pendingSave
        let unsavedPromotion = pendingPromotion
        newChat()
        if let unsaved {
            pendingSave = PendingSave(
                turn: unsaved.turn, conversationAtSend: nil,
                generationAtSend: conversationGeneration,
                key: unsaved.key, title: unsaved.title,
                source: unsaved.source)
        }
        if let unsavedPromotion {
            pendingPromotion = unsavedPromotion
        }
        guard pendingSave != nil || pendingPromotion != nil else {
            return false
        }
        saveError =
            "This chat was deleted. The unsaved answer is kept; Retry Save "
            + "stores it in a new chat."
        return true
    }

    /// A save can finish after the reader switched away and back, so the
    /// in-memory turn list may no longer contain the answer that is now in
    /// the archive. Refresh only that transcript, without changing the page.
    private func refreshTranscript(conversationID: Int64) {
        guard let archive = app?.archive else { return }
        if compactionRefreshing {
            needsTranscriptRefresh = true
            return
        }
        transcriptRefreshGeneration += 1
        let generation = transcriptRefreshGeneration
        let mutation = transcriptMutationGeneration
        transcriptRefreshing = true
        Task { [weak self] in
            do {
                let snapshot = try await Task.detached {
                    try archive.conversationSnapshot(
                        conversationID: conversationID)
                }.value
                guard let self, generation == self.transcriptRefreshGeneration,
                    mutation == self.transcriptMutationGeneration,
                    self.conversationID == conversationID
                else {
                    if let self,
                        generation == self.transcriptRefreshGeneration
                    {
                        self.needsTranscriptRefresh = true
                        self.transcriptRefreshing = false
                        self.consumeNeedsTranscriptRefresh()
                    }
                    return
                }
                self.turns = snapshot.turns.map(Self.turn(from:))
                self.transcriptMutationGeneration += 1
                self.cardedTurnIDs = snapshot.cardIDs
                // Compaction has its own refresh path. Do not let a
                // transcript read taken before a newer summary overwrite it.
                self.historyLoadFailed = false
                self.transcriptRefreshing = false
                if self.needsTranscriptRefresh {
                    self.needsTranscriptRefresh = false
                    self.refreshCompactionFromArchive()
                }
            } catch {
                guard let self,
                    generation == self.transcriptRefreshGeneration
                else { return }
                self.transcriptRefreshing = false
                self.historyLoadFailed = true
                // Retry must reopen the chat that failed, not whichever
                // chat is newest for the book.
                self.failedConversationID = conversationID
                self.saveError =
                    "Saved, but the transcript could not be refreshed."
            }
        }
    }

    private func loadConversationHistory() {
        guard let archive = app?.archive, let key = bookKey else {
            turns = []
            transcriptMutationGeneration += 1
            conversationID = nil
            conversations = []
            resetCompaction()
            historyLoading = false
            historyLoadFailed = false
            historyTask = nil
            return
        }
        conversationGeneration += 1
        compactionGeneration += 1
        compactionTask?.cancel()
        compactionTask = nil
        failedConversationID = nil
        let generation = conversationGeneration
        historyLoading = true
        historyLoadFailed = false
        let task = Task { [weak self] in
            let revisionAtStart = self?.app?.conversationChangeRevision
            do {
                let loaded = try await Task.detached {
                    try archive.conversationHistory(bookKey: key)
                }.value
                guard
                    let self, !Task.isCancelled,
                    generation == self.conversationGeneration,
                    self.bookKey == key
                else { return }
                if let app = self.app,
                    app.conversationChangeRevision != revisionAtStart
                {
                    // A chat was created or changed after this snapshot was
                    // taken. Applying it would hide that chat; read again.
                    self.loadConversationHistory()
                    return
                }
                self.conversationID = loaded.latest?.id
                self.turns = loaded.transcript.turns.map(Self.turn(from:))
                self.transcriptMutationGeneration += 1
                self.conversations = loaded.summaries
                self.cardedTurnIDs = loaded.transcript.cardIDs
                self.compaction = loaded.transcript.compaction
                self.compactionState = .idle
                self.compactionError = nil
                self.historyLoading = false
                self.historyLoadFailed = false
                if self.phase == .loadingPage { self.phase = .idle }
                self.refreshCompactionFromArchive()
                TsundokuDiagnostics.shared.event(
                    "ai_conversation_loaded",
                    [
                        "turns": loaded.transcript.turns.count,
                        "conversations": loaded.summaries.count,
                    ])
            } catch {
                guard let self, generation == self.conversationGeneration
                else { return }
                self.historyLoading = false
                self.historyLoadFailed = true
                self.saveError = "Could not read this book's chats: \(error)"
            }
        }
        historyTask = task
    }

    private func apply(
        stored: [ConversationTurn], cardIDs: Set<Int64>,
        conversationID: Int64, compaction: ConversationCompaction?
    ) {
        self.conversationID = conversationID
        turns = stored.map(Self.turn(from:))
        transcriptMutationGeneration += 1
        cardedTurnIDs = cardIDs
        self.compaction = compaction
        compactionState = .idle
        compactionError = nil
        historyLoading = false
        historyLoadFailed = false
        failedConversationID = nil
        transcriptRefreshGeneration += 1
        transcriptRefreshing = false
        savedTurnID = nil
        error = nil
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        phase = .ready
    }

    private static func turn(from stored: ConversationTurn) -> AITurn {
        AITurn(
            action: stored.action, question: stored.question,
            answer: stored.answer, provider: stored.provider,
            prompt: stored.prompt, context: stored.context,
            createdAt: stored.createdAt, persistedID: stored.id)
    }

    private func persist(
        _ turn: AITurn, conversationAtSend: Int64?,
        generationAtSend: Int, key explicitKey: String? = nil,
        title explicitTitle: String? = nil,
        source explicitSource: BookSource? = nil
    ) {
        guard let app else { return }
        guard let key = explicitKey ?? bookKey else {
            // No book to file under. Say so; a silent return would lose an
            // answer that exists nowhere else.
            saveError =
                "This answer could not be saved: no book is identified "
                + "for it."
            return
        }
        guard let archive = app.archive else {
            // The answer exists only in this panel. Keep it retryable
            // instead of dropping it because the archive is not open.
            pendingSave = PendingSave(
                turn: turn, conversationAtSend: conversationAtSend,
                generationAtSend: generationAtSend, key: key,
                title: explicitTitle ?? context.bookTitle,
                source: explicitSource ?? context.bookSource)
            saveError =
                "This answer could not be saved: the archive is not open. "
                + "Retry Save once it is."
            return
        }
        let title = explicitTitle ?? context.bookTitle
        let source = explicitSource ?? context.bookSource
        #if DEBUG
        let shouldFail = failNextPersistenceForTesting
        failNextPersistenceForTesting = false
        #else
        let shouldFail = false
        #endif
        beginPersistence()
        let previous = persistenceChain
        let task = Task { [weak self] in
            await previous?.value
            // A failed session promotion owns this book's unfiled turns.
            // Writing this answer separately would create a second chat;
            // fold it into the promotion so one Retry Save produces one
            // conversation.
            if let self, let promotion = self.pendingPromotion,
                promotion.key == key, self.conversationID == nil
            {
                self.endPersistence()
                self.pendingPromotion = PendingPromotion(
                    turns: promotion.turns + [turn], key: promotion.key,
                    title: promotion.title, source: promotion.source)
                self.saveError =
                    "This book's earlier chats could not be filed. Retry "
                    + "Save files them and this answer together."
                return
            }
            #if DEBUG
            if shouldFail {
                guard let self else { return }
                self.endPersistence()
                self.pendingSave = PendingSave(
                    turn: turn, conversationAtSend: conversationAtSend,
                    generationAtSend: generationAtSend, key: key,
                    title: title, source: source)
                self.saveError =
                    "This answer could not be saved: injected test failure."
                return
            }
            #endif
            // A session promotion ahead of this write may have created and
            // recorded the book's conversation. Reuse that only while the
            // conversation has not changed since the answer was sent: a
            // queued write must never append to a thread the reader opened
            // after it. New Chat also leaves `conversationID` nil, so it
            // still creates a fresh thread.
            let existingID =
                self?.conversationGeneration == generationAtSend
                ? self?.conversationID : nil
            do {
                let result = try await Task.detached {
                    () -> (turnID: Int64, conversationID: Int64,
                        summaries: [ConversationSummary]?) in
                    let turnID: Int64
                    let id: Int64
                    if let conversationAtSend {
                        id = conversationAtSend
                        turnID = try archive.appendConversationTurn(
                            conversationID: id, action: turn.action,
                            question: turn.question, answer: turn.answer,
                            provider: turn.provider, prompt: turn.prompt,
                            context: turn.context).id
                    } else if let existingID {
                        id = existingID
                        turnID = try archive.appendConversationTurn(
                            conversationID: id, action: turn.action,
                            question: turn.question, answer: turn.answer,
                            provider: turn.provider, prompt: turn.prompt,
                            context: turn.context).id
                    } else {
                        // A new thread and its first turn are one
                        // transaction, so a failed insert cannot leave an
                        // empty conversation behind. The inserted ID comes
                        // back from the transaction; no post-commit read can
                        // turn a successful write into a retry.
                        let created = try archive.createConversationWithTurnIDs(
                            bookKey: key, bookTitle: title,
                            bookSource: source,
                            turns: [
                                NewConversationTurn(
                                    action: turn.action,
                                    question: turn.question,
                                    answer: turn.answer,
                                    provider: turn.provider,
                                    prompt: turn.prompt,
                                    context: turn.context)
                            ])
                        id = created.0.id
                        guard let inserted = created.1.last else {
                            throw Archive.ConversationArchiveError
                                .missingConversation(created.0.id)
                        }
                        turnID = inserted
                    }
                    // A summary refresh is not part of the write. If it
                    // fails, the turn is already durable and must not be
                    // retried as if the append failed.
                    let summaries = try? archive.conversations(
                        bookKey: key)
                    return (turnID, id, summaries)
                }.value
                guard let self else { return }
                self.endPersistence()
                let turnStillLoaded = self.turns.contains {
                    $0.id == turn.id
                }
                if let index = self.turns.firstIndex(where: {
                    $0.id == turn.id
                }) {
                    self.turns[index].persistedID = result.turnID
                    self.transcriptMutationGeneration += 1
                }
                if conversationAtSend == nil,
                    generationAtSend == self.conversationGeneration,
                    self.bookKey == key
                {
                    self.conversationID = result.conversationID
                }
                if !turnStillLoaded,
                    self.conversationID == result.conversationID
                {
                    self.refreshTranscript(
                        conversationID: result.conversationID)
                }
                if self.bookKey == key {
                    if let summaries = result.summaries {
                        self.conversations = summaries
                        self.saveError = nil
                    } else {
                        self.saveError =
                            "Saved, but the chat list could not be refreshed."
                    }
                }
                if self.pendingSave?.turn.id == turn.id {
                    self.pendingSave = nil
                }
                if self.needsTranscriptRefresh {
                    self.needsTranscriptRefresh = false
                    self.refreshCompactionFromArchive()
                }
                app.refreshConversationCounts()
                app.markConversationChanged(result.conversationID)
            } catch {
                guard let self else { return }
                self.endPersistence()
                // A delete that landed while this write was in flight
                // removes the target; retrying into it would fail forever.
                let target = conversationAtSend
                    ?? (self.conversationGeneration == generationAtSend
                        ? self.conversationID : nil)
                // Only a successful lookup that returns nil proves deletion
                // a failed query is not evidence, and must not silently
                // retarget the answer.
                var lookupFailure: String?
                var targetGone = false
                if let target {
                    do {
                        targetGone = try archive.conversation(id: target) == nil
                    } catch {
                        lookupFailure = "\(error)"
                    }
                }
                let message =
                    "This answer could not be saved: \(error)"
                    + (targetGone
                        ? " The chat was deleted; Retry Save stores it in a "
                            + "new chat."
                        : "")
                    + (lookupFailure.map {
                        " The chat could not be checked: \($0)"
                    } ?? "")
                if targetGone, target == self.conversationID {
                    // Treat a chat that vanished mid-write exactly like a
                    // deletion notification: keep the answer, retargeted,
                    // and drop the dead conversation.
                    self.pendingSave = PendingSave(
                        turn: turn, conversationAtSend: nil,
                        generationAtSend: self.conversationGeneration,
                        key: key, title: title, source: source)
                    self.resetKeepingUnsavedWrites()
                    self.saveError = message
                    return
                }
                self.pendingSave = PendingSave(
                    turn: turn,
                    conversationAtSend: targetGone
                        ? nil : conversationAtSend,
                    generationAtSend: targetGone
                        ? self.conversationGeneration : generationAtSend,
                    key: key, title: title, source: source)
                self.saveError = message
            }
        }
        persistenceChain = task
    }

    /// Retry the exact turn and conversation that failed. New Chat is the
    /// explicit discard action; switching pages or chats does not lose the
    /// only copy of an unsaved answer.
    public func retrySave() {
        guard app?.archive != nil else {
            if pendingSave != nil || pendingPromotion != nil {
                saveError =
                    "The archive is not open; the unsaved answer is kept."
            }
            return
        }
        if let pending = pendingSave {
            pendingSave = nil
            saveError = nil
            persist(
                pending.turn, conversationAtSend: pending.conversationAtSend,
                generationAtSend: pending.generationAtSend, key: pending.key,
                title: pending.title, source: pending.source)
            return
        }
        guard let promotion = pendingPromotion else { return }
        pendingPromotion = nil
        saveError = nil
        persistTurns(
            promotion.turns, key: promotion.key, archive: app?.archive,
            title: promotion.title, source: promotion.source)
    }

    /// A Books page has no ASIN in the Accessibility tree. The title
    /// identifies the imported book only when exactly one source book matches;
    /// otherwise the note is refused rather than filed under a guess.
    private func matchedBook() -> Book? {
        guard let app else { return nil }
        if let identifier = pageIdentifier, !identifier.isEmpty,
            let book = app.books.first(where: { $0.asin == identifier })
        {
            return book
        }
        guard let readerKind else { return nil }
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
    @State private var composerHeight: CGFloat = 80
    @State private var showCompactionSummary = false
    @State private var confirmRemoveCompaction = false
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
        .sheet(
            isPresented: $model.showQuickCapture,
            onDismiss: { model.quickCapture = nil }
        ) {
            if let capture = model.quickCapture {
                QuickPageCaptureView(capture: capture)
            }
        }
        .alert(
            "Remove Summary?", isPresented: $confirmRemoveCompaction
        ) {
            Button("Remove Summary", role: .destructive) {
                model.removeCompaction()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The next message will send the full transcript; nothing is "
                    + "deleted.")
        }
        .confirmationDialog(
            "Delete This Chat?",
            isPresented: Binding(
                get: { model.deletionImpact != nil },
                set: { if !$0 { model.dismissChatDeletion() } }),
            presenting: model.deletionImpact
        ) { _ in
            Button("Delete Chat", role: .destructive) {
                model.deleteCurrentChat()
            }
            Button("Cancel", role: .cancel) {
                model.dismissChatDeletion()
            }
        } message: { impact in
            Text(
                "\(impact.turns) turns and \(impact.compactions) summaries "
                    + "will be deleted. \(impact.notes) saved notes are kept; "
                    + "\(impact.cards) cards will leave Cards.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headerTitle)
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
            Button {
                model.captureCurrentPage()
            } label: {
                Image(systemName: "camera")
            }
            .buttonStyle(.borderless)
            .disabled(model.quickCaptureBusy)
            .help("Capture this page as an image")
            .accessibilityLabel("Capture this page")
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
            Button("Compact Conversation…") {
                model.compactConversation()
            }
            .disabled(!model.canCompact)
            Button("Manage Chats…") { model.openChats() }
                .disabled(!model.canOpenChats)
            Button("Delete This Chat…") {
                model.reviewCurrentChatDeletion()
            }
            .disabled(model.conversationID == nil)
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
                            "\(summary.displayTitle) · "
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
                        if model.compaction != nil {
                            compactionDivider
                        }
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
            IconButton("Stop", systemImage: "stop.fill") { model.stopAnswer() }
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

    @ViewBuilder private var compactionDivider: some View {
        if let compaction = model.compaction {
            VStack(alignment: .leading, spacing: 7) {
                Label(
                    "Earlier messages summarized for the model",
                    systemImage: "text.append")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(
                    "\(model.compactionCoveredTurnCount) earlier "
                        + (model.compactionCoveredTurnCount == 1
                            ? "turn is" : "turns are")
                        + " summarized. Every original message remains "
                        + "below and is still saved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(
                    "Summary written "
                        + compaction.createdAt.formatted(
                            date: .abbreviated, time: .shortened)
                        + " by \(compaction.provider).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                DisclosureGroup(
                    "View Summary", isExpanded: $showCompactionSummary
                ) {
                    Text(compaction.summary)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxHeight: 220, alignment: .topLeading)
                }
                HStack(spacing: 8) {
                    Button("Recompact") { model.compactConversation() }
                        .controlSize(.small)
                        .disabled(!model.canCompact)
                    Button("Remove Summary") {
                        confirmRemoveCompaction = true
                    }
                    .controlSize(.small)
                    .disabled(model.compactionState == .running)
                    Spacer()
                }
            }
            .padding(10)
            .background(
                Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "Earlier messages summarized for the model")
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
                    let carded = model.isCarded(turn)
                    IconButton(
                        carded ? "In Cards" : "Add to Cards",
                        systemImage: carded
                            ? "rectangle.stack.badge.checkmark"
                            : "rectangle.stack.badge.plus",
                        tooltip: carded
                            ? "This answer is a card in the book's Cards view"
                            : turn.persistedID == nil
                                ? "The answer is still being saved"
                                : !model.canCard
                                    ? "Card this answer from an imported book"
                                    : "Add this answer to the book's Cards view"
                    ) { model.addToCards(turn) }
                    .controlSize(.mini)
                    .disabled(
                        carded || turn.persistedID == nil
                            || !model.canCard)
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
                    // The title is already the header; repeating it here
                    // pushed the chapter chip out of a 400 pt panel.
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
            Text(model.transmissionDetail)
            if !model.identityNote.isEmpty {
                Divider()
                Text(model.identityNote)
            }
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
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                ActivatingTextView(
                    text: $model.question,
                    height: $composerHeight,
                    onSubmit: { model.send() },
                    onActivate: {
                        onActivate()
                        model.refreshSelection()
                    },
                    onEscape: { onClose?() })
                if model.question.isEmpty {
                    Text(
                        model.scope == .selection
                            ? "Ask about the selection…"
                            : "Ask about this page…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: composerHeight)
            HStack(alignment: .center, spacing: 8) {
                scopeMenu
                Spacer(minLength: 0)
                if model.phase == .loadingAnswer {
                    Button {
                        model.stopAnswer()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(.secondary)
                    .help("Stop the answer")
                    .accessibilityLabel("Stop")
                } else {
                    sendControl
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(dividerColor, lineWidth: 0.5))
    }

    /// A "+" menu on the composer's bottom row: what the answer covers. The
    /// collapsed control is an icon; the scope names appear only when open.
    private var scopeMenu: some View {
        Menu {
            ForEach(CompanionScope.allCases) { scope in
                Button {
                    model.chooseScope(scope)
                } label: {
                    Text(
                        model.scope == scope
                            ? "✓ \(scope.displayName)" : scope.displayName)
                }
                .disabled(
                    (scope == .currentChapter
                        && model.context.chapter == nil)
                        || (scope == .wholeBook && !model.hasLocalBookText))
            }
            if model.scope == .selection && !model.selectionAvailable {
                Divider()
                Text(
                    "Select text in the reader; the companion reads it "
                        + "through the reader's Copy action.")
            }
            if !model.hasLocalBookText {
                Divider()
                Text(
                    "Chapter and whole-book text need a local capture of "
                        + "this book.")
                Button("Open Capture as PDF…") {
                    model.openCaptureExports()
                    onClose?()
                }
            } else if model.context.chapter == nil {
                Divider()
                Text("This chapter is not in the local capture yet.")
                Button("Open Capture as PDF…") {
                    model.openCaptureExports()
                    onClose?()
                }
            } else if model.scope == .wholeBook {
                Divider()
                Text(
                    "Uses the captured text, up to the model's limit. "
                        + "Capture more pages to include them.")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    model.scope == .currentPage
                        ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 28)
                .background(
                    Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Context: \(model.scope.displayName)")
        .accessibilityLabel("Context: \(model.scope.displayName)")
    }

    /// One capsule: Send on the left, the quick-action menu on the chevron.
    private var sendControl: some View {
        HStack(spacing: 0) {
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .opacity(model.canSend ? 1 : 0.45)
            .help("Send")
            .accessibilityLabel("Send")
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 0.5, height: 14)
            quickActionsMenu
        }
        .foregroundStyle(.white)
        .background(
            Color.accentColor.opacity(model.canRun ? 1 : 0.4),
            in: Capsule())
        .fixedSize()
    }

    @ViewBuilder private var quickActionsMenu: some View {
        if let store = model.companionSettings {
            ObservedQuickActionsMenu(
                store: store, canRun: model.canRun
            ) { model.perform($0) }
        } else {
            QuickActionsMenu(
                actions: AIAction.quickActionCases, canRun: model.canRun
            ) { model.perform($0) }
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let note = model.sendNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error, model.phase != .failed {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.canRetrySave {
                Text(
                    model.saveError
                        ?? "An answer is not saved yet; Retry Save.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Save") { model.retrySave() }
                    .controlSize(.small)
            } else if let saveError = model.saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.historyLoadFailed {
                Button("Retry Chat History") { model.retryHistory() }
                    .controlSize(.small)
            }
            if model.transcriptRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing the transcript…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if model.compactionRemoving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Removing the conversation summary…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if model.compactionRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing the conversation…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if model.compactionRefreshFailed {
                Text(
                    model.compactionError
                        ?? "Could not refresh the conversation.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Summary Refresh") {
                    model.retryCompactionRefresh()
                }
                .controlSize(.small)
            }
            if case .running = model.compactionState {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing earlier turns…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if case .failed(let message) = model.compactionState {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = model.contextWarning {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Compact") { model.compactConversation() }
                        .controlSize(.mini)
                        .disabled(!model.canCompact)
                }
            }
            if let captureError = model.quickCaptureError {
                Text(captureError)
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

/// The dropdown attached to the Send button. Reading the actions from the
/// settings store keeps the menu and Settings in one source of truth.
private struct QuickActionsMenu: View {
    let actions: [AIAction]
    let canRun: Bool
    let perform: (AIAction) -> Void

    var body: some View {
        Menu {
            if actions.isEmpty {
                Text("No quick actions — choose them in Settings")
            } else {
                ForEach(actions, id: \.self) { action in
                    Button {
                        perform(action)
                    } label: {
                        Label(
                            action.displayName,
                            systemImage: action.symbolName)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 22, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!canRun)
        .help("Quick actions")
        .accessibilityLabel("Quick actions")
    }
}

private struct ObservedQuickActionsMenu: View {
    @ObservedObject var store: CompanionSettingsStore
    let canRun: Bool
    let perform: (AIAction) -> Void

    var body: some View {
        QuickActionsMenu(
            actions: store.settings.quickActions, canRun: canRun,
            perform: perform)
    }
}

// MARK: - Multiline composer

/// A multiline composer for a nonactivating panel.
///
/// AppKit gap, not a preference: the responder system owns first-responder
/// ordering and key handling here. The companion is a borderless
/// `.nonactivatingPanel`, and the spike measured Apple Books taking the first
/// keystroke from such a panel while Kindle sometimes accepted it (the
/// 2026-10-21 companion spike, "Typing in a nonactivating panel"). Activating
/// the app in `mouseDown`, before becoming
/// first responder, is what makes the first character land. Return must send
/// and Shift+Return must insert a newline, which means intercepting the text
/// system's own newline command; a SwiftUI `TextField` is single-line and a
/// `TextEditor` gives no access to that command.
public struct ActivatingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let onSubmit: () -> Void
    let onActivate: () -> Void
    let onEscape: () -> Void

    public init(
        text: Binding<String>, height: Binding<CGFloat>,
        onSubmit: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onEscape: @escaping () -> Void
    ) {
        self._text = text
        self._height = height
        self.onSubmit = onSubmit
        self.onActivate = onActivate
        self.onEscape = onEscape
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        let textView = ComposerTextView()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.onActivate = onActivate
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.updateHeight()
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerTextView
        else { return }
        textView.onActivate = onActivate
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        if textView.string != text {
            // Keep the caret: this update usually comes from sending a
            // message, not from typing, and a reset caret would jump.
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(
                    location: min(selected.location, text.utf16.count),
                    length: 0))
            context.coordinator.updateHeight()
        }
    }

    @MainActor public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ActivatingTextView
        weak var textView: NSTextView?
        private var heightUpdatePending = false

        init(_ parent: ActivatingTextView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            updateHeight()
        }

        /// Reports the text's laid-out height to SwiftUI, clamped to 80–160
        /// points (about four to eight lines). Setting state during a view
        /// update is deferred one turn of the main queue.
        func updateHeight() {
            guard !heightUpdatePending else { return }
            heightUpdatePending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let textView = self.textView,
                    let container = textView.textContainer,
                    let layout = textView.layoutManager
                else {
                    self.heightUpdatePending = false
                    return
                }
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container).height
                let desired = min(
                    max(used + textView.textContainerInset.height * 2, 80),
                    160)
                self.heightUpdatePending = false
                if abs(self.parent.height - desired) > 0.5 {
                    self.parent.height = desired
                }
            }
        }
    }
}

/// Which composer action a key press means.
///
/// Split out from the view so the Return/Shift+Return contract is testable
/// without a window: Return sends, Shift+Return inserts a newline, Escape
/// closes, and an active input-method composition keeps the key.
enum ComposerKeyPolicy {
    enum Action: Equatable {
        case send
        case newline
        case escape
        case none
    }

    static func action(
        keyCode: UInt16, shift: Bool, hasMarkedText: Bool
    ) -> Action {
        guard !hasMarkedText else { return .none }
        switch keyCode {
        case 36, 76: return shift ? .newline : .send
        case 53: return .escape
        default: return .none
        }
    }
}

/// The text view intercepts Return and Shift+Return before the text system
/// turns them into commands, and activates the app on the click that focuses
/// it. An input-method composition keeps Return until it is committed.
final class ComposerTextView: NSTextView {
    var onActivate: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    /// The panel is a borderless `.nonactivatingPanel` with
    /// `becomesKeyOnlyIfNeeded`; without this, the first click that should
    /// focus the composer is swallowed by the window and never reaches
    /// `mouseDown`, so the app never activates and the first keystroke goes
    /// to the reader.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !NSApp.isActive {
            onActivate?()
        }
        window?.makeKey()
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        if !NSApp.isActive {
            onActivate?()
        }
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        switch ComposerKeyPolicy.action(
            keyCode: event.keyCode,
            shift: event.modifierFlags.contains(.shift),
            hasMarkedText: hasMarkedText())
        {
        case .send: onSubmit?()
        case .newline: insertNewline(nil)
        case .escape: onEscape?()
        case .none: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
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

/// The side pane's one-shot page image. It is not an Exports page and cannot
/// turn the reader.
struct QuickPageCaptureView: View {
    let capture: QuickPageCapture
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Captured Page")
                        .font(.headline)
                    Text(
                        "Page \(capture.pageNumber.map(String.init) ?? "?")"
                            + (capture.pageCount.map { " of \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Image(decorative: capture.image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if capture.textSource == .ocr {
                Text("Read with OCR — check the text before relying on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !capture.text.isEmpty {
                ScrollView {
                    Text(capture.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 480)
    }
}
