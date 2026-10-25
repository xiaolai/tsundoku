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
    /// How the current page's book was identified, for the info menu and
    /// diagnostics. A nil key means the page stays unfiled.
    @Published public var identity: ReadingIdentity?
    /// The conversation for this book, oldest first.
    @Published public var turns: [AITurn] = []
    /// Every conversation filed under the current book, newest first.
    @Published public var conversations: [ConversationSummary] = []
    @Published public var conversationID: Int64?
    /// True while the book's earlier turns are being read; sending waits, so a
    /// message cannot start a second conversation beside the stored one.
    @Published public private(set) var historyLoading = false
    /// True while an answer is being written to the archive. Sending waits:
    /// a second send before the first write finishes would not yet know the
    /// conversation ID and would start a duplicate thread.
    @Published public private(set) var persisting = false
    /// Two writes can overlap: an answer being stored while session-only
    /// turns are promoted. A single Bool let the first completion clear the
    /// flag for both; the count keeps it true until the last write ends.
    private var persistenceCount = 0
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

    /// The local-index lookup, injectable so a test can supply an EPUB match
    /// without a Books library or a real capture on disk.
    public typealias ContextResolver = @Sendable (
        ReaderPage, [CaptureRecord], Archive?
    ) -> ReadingContextResolver.Result?

    private weak var app: AppModel?
    private let readerContext: any ReaderContext
    private let contextResolver: ContextResolver
    private let answerProvider: AnswerProvider
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
        }
    ) {
        self.app = app
        self.readerContext = context
        self.contextResolver = contextResolver
        self.answerProvider = answerProvider
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
        !pageText.isEmpty && !historyLoading && !persisting
            && (phase == .idle || phase == .ready)
    }

    public var canSave: Bool {
        turns.last != nil && !saved
    }

    public var canSend: Bool {
        canRun
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        localContextTask?.cancel()
        followTask?.cancel()
        sendPreparationTask?.cancel()
        pageTask = nil
        pageWork = nil
        answerTask = nil
        localContextTask = nil
        followTask = nil
        sendPreparationTask = nil
        sendGeneration += 1
        sendNote = nil
        pageGeneration += 1
        answerGeneration += 1
        conversationGeneration += 1
        selectionGeneration += 1
        let historyWasLoading = historyLoading
        historyLoading = false
        let generation = pageGeneration
        let previousKey = bookKey
        pageText = ""
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
                    self.conversationID = nil
                    self.conversations = []
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
        localContextGeneration += 1
        let generation = localContextGeneration
        // Read the captures from the archive, not the view model's copy:
        // the panel can open before the library reload has assigned it.
        let archive = app.archive
        let books = app.books
        let resolver = contextResolver
        let task = Task { [weak self] in
            let result = await Task.detached {
                let captures = (try? archive?.captures()) ?? []
                return resolver(page, captures, archive)
            }.value
            guard let self, !Task.isCancelled,
                generation == self.localContextGeneration
            else { return }
            if let result {
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
                // No local text covers this page, but a reader-supplied ASIN
                // may still let an older title-keyed chat move under it.
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
            let migrated = await Task.detached { () -> Bool in
                var moved = false
                for old in candidates {
                    guard
                        (try? archive.latestConversation(bookKey: old)) ?? nil
                            != nil
                    else { continue }
                    do {
                        try archive.migrateConversations(
                            from: old, to: key, title: title, source: source)
                        moved = true
                    } catch {
                        continue
                    }
                }
                return moved
            }.value
            guard let self, migrated, self.bookKey == key,
                generation == self.conversationGeneration,
                !self.persisting
            else { return }
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
            }
            bookKey = key
            bookTitle = improved.title
            context.bookTitle = improved.title
            turns = []
            conversationID = nil
            conversations = []
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
        _ pending: [AITurn], key: String, archive: Archive?
    ) {
        guard let archive else { return }
        let title = context.bookTitle
        let source = context.bookSource
        let generation = conversationGeneration
        let turns = pending.map {
            NewConversationTurn(
                action: $0.action, question: $0.question, answer: $0.answer,
                provider: $0.provider, prompt: $0.prompt, context: $0.context)
        }
        beginPersistence()
        Task { [weak self] in
            let stored = await Task.detached { () -> Conversation? in
                // The conversation and every turn are one transaction; a
                // failure leaves no partially saved thread behind.
                try? archive.createConversation(
                    bookKey: key, bookTitle: title, bookSource: source,
                    turns: turns)
            }.value
            guard let self else { return }
            self.endPersistence()
            if let stored {
                if self.bookKey == key,
                    generation == self.conversationGeneration
                {
                    self.conversationID = stored.id
                }
            } else {
                self.saveError =
                    "Could not file this book's earlier chats."
            }
        }
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
            if first.selection != context.selection {
                context.selection = first.selection
                TsundokuDiagnostics.shared.event(
                    "selection_refreshed",
                    [
                        "characters": first.selection?.count ?? 0,
                        "page": first.pageNumber ?? -1,
                    ])
            }
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
        applyLivePage(page)
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
        let identity: ReadingIdentity
        if let current = self.identity,
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
        let bookChanged = identity.key != bookKey
        self.identity = identity
        bookKey = identity.key
        bookTitle = identity.title
        context = makeContext(for: page, identity: identity)
        if bookChanged {
            answerTask?.cancel()
            answerTask = nil
            answerGeneration += 1
            if phase == .loadingAnswer { phase = .idle }
            turns = []
            conversationID = nil
            conversations = []
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
            TsundokuDiagnostics.shared.event(
                "selection_refreshed",
                [
                    "characters": selected?.count ?? 0,
                    "page": self.context.pageNumber ?? -1,
                ])
        }
    }

    public func run() {
        guard canRun else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == .ask, text.isEmpty { return }
        let requested = action
        sendGeneration += 1
        let generation = sendGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            let freshness = await self.confirmPageIsCurrent()
            guard !Task.isCancelled, generation == self.sendGeneration else {
                return
            }
            // A move to another book is not a page turn: the question was
            // written about the book that is no longer on screen, so it must
            // not be sent to the new one.
            guard freshness != .bookChanged else { return }
            self.startRequest(action: requested, question: text)
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
            // the last follow.
            if read.selection != context.selection {
                context.selection = read.selection
            }
            lastFreshness = .current
            sendNote = nil
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

    private func startRequest(action: AIAction, question text: String) {
        guard canRun else { return }
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
        localContextTask?.cancel()
        followTask?.cancel()
        sendPreparationTask?.cancel()
        pageTask = nil
        pageWork = nil
        answerTask = nil
        selectionTask = nil
        localContextTask = nil
        followTask = nil
        sendPreparationTask = nil
        sendGeneration += 1
        sendNote = nil
        pageGeneration += 1
        answerGeneration += 1
        selectionGeneration += 1
        phase = .idle
        error = nil
        saveError = nil
        failureKind = nil
        submittedRequest = nil
        TsundokuDiagnostics.shared.event("ai_work_cancelled")
    }

    /// Stops the answer, not the panel: page following continues, so the next
    /// send uses the current page.
    public func stopAnswer() {
        answerTask?.cancel()
        answerTask = nil
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        sendGeneration += 1
        answerGeneration += 1
        if phase == .loadingAnswer { phase = .idle }
        error = nil
        failureKind = nil
    }

    /// Starts a fresh conversation about the same book. Earlier conversations
    /// stay in the history menu and in the library.
    public func newChat() {
        answerTask?.cancel()
        answerTask = nil
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        sendGeneration += 1
        sendNote = nil
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
        if phase != .loadingPage { phase = .idle }
        TsundokuDiagnostics.shared.event("ai_conversation_cleared")
    }

    /// Switches to an earlier conversation of the same book.
    public func openConversation(_ id: Int64) {
        guard let archive = app?.archive else { return }
        // Re-selecting the conversation already on screen is a no-op. Doing
        // this after cancellation would stop its in-flight answer and leave
        // the phase reading as loading forever.
        if id == conversationID, !turns.isEmpty { return }
        answerTask?.cancel()
        answerTask = nil
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        sendGeneration += 1
        sendNote = nil
        answerGeneration += 1
        conversationGeneration += 1
        selectionGeneration += 1
        let generation = conversationGeneration
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
                guard let self, !Task.isCancelled,
                    generation == self.conversationGeneration
                else { return }
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
        guard
            let asin = identity?.book?.asin ?? pageIdentifier
                ?? matchedBook()?.asin
        else {
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
            historyTask = nil
            return
        }
        conversationGeneration += 1
        let generation = conversationGeneration
        historyLoading = true
        let task = Task { [weak self] in
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
        historyTask = task
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
        beginPersistence()
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
                self.endPersistence()
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
                self.endPersistence()
                self.saveError =
                    "This answer could not be saved: \(error)"
            }
        }
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
    @State private var composerHeight: CGFloat = 22
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
                    + " and up to three earlier exchanges are sent; the rest "
                    + "of the book stays on this Mac.")
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
                        Text("Ask about this page…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: composerHeight)
                if model.phase == .loadingAnswer {
                    Button {
                        model.stopAnswer()
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
            if let note = model.sendNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        textView.textContainerInset = NSSize(width: 4, height: 4)
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

        /// Reports the text's laid-out height to SwiftUI, clamped to one line
        /// through six. Setting state during a view update is deferred one
        /// turn of the main queue.
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
                    max(used + textView.textContainerInset.height * 2, 22),
                    96)
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
