import AppKit
import ApplicationServices
import Combine
import Foundation
import TsundokuCore
import SwiftUI

@MainActor
public final class AppModel: ObservableObject {
    public enum Section: String, CaseIterable, Identifiable, Hashable {
        case library
        case highlights
        case history
        case exports

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .library: "Books"
            case .highlights: "Annotations"
            case .history: "History"
            case .exports: "Exports"
            }
        }

        public var symbol: String {
            switch self {
            case .library: "books.vertical"
            case .highlights: "highlighter"
            case .history: "clock.arrow.circlepath"
            case .exports: "doc.richtext"
            }
        }
    }

    public enum BookWorkspaceSection: String, CaseIterable, Identifiable, Hashable {
        case annotations
        case chats

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .annotations: "Annotations"
            case .chats: "Chats"
            }
        }
    }

    public enum AnnotationFilter: String, CaseIterable, Identifiable {
        case mine
        case popular
        case system
        case all

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .mine: "Mine"
            case .popular: "Popular"
            case .system: "System"
            case .all: "All"
            }
        }

        public var provenance: AnnotationProvenance? {
            switch self {
            case .mine: .user
            case .popular: .amazon
            case .system: .system
            case .all: nil
            }
        }
    }

    public enum CapturePhase: Equatable {
        case idle
        case running
        case finished
        case failed
    }

    public enum SourceFilter: String, CaseIterable, Identifiable {
        case all
        case kindle
        case appleBooks

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: "All Sources"
            case .kindle: "Kindle"
            case .appleBooks: "Apple Books"
            }
        }

        public var source: BookSource? {
            switch self {
            case .all: nil
            case .kindle: .kindle
            case .appleBooks: .appleBooks
            }
        }
    }

    @Published public var section: Section = .library
    @Published public var books: [Book] = []
    @Published public var bookTitles: [String: String] = [:]
    @Published public var annotations: [Annotation] = []
    @Published public var sessions: [ReadingSession] = []
    @Published public var captures: [CaptureRecord] = []
    @Published public var counts: ArchiveCounts?
    @Published public var selectedBookID: String? {
        didSet {
            // An explicit book choice ends any capture route's override.
            if selectedBookID != oldValue {
                captureRouteKind = nil
                captureRouteWithoutBook = false
            }
        }
    }
    @Published public var search = ""
    @Published public var annotationFilter: AnnotationFilter = .mine
    @Published public var annotationSearch = ""
    @Published public var sourceFilter: SourceFilter = .all
    @Published public var annotationSourceFilter: SourceFilter = .all
    @Published public var annotationBookID: String?
    @Published public var bookWorkspaceID: String?
    @Published public var bookWorkspaceSection: BookWorkspaceSection = .annotations
    @Published public var savedAINotes: [SavedAINote] = []
    @Published public private(set) var aiCards: [AICard] = []
    /// The persisted turn IDs that are cards, shared with the companion so a
    /// removal in the library updates an open panel.
    @Published public private(set) var cardTurnIDs: Set<Int64> = []
    /// True once a card load has completed, even if it found none; an empty
    /// set before the first load means "unknown", not "no cards".
    @Published public private(set) var aiCardsLoaded = false
    private var aiCardsGeneration = 0
    /// Turns stored per book key (an ASIN when the archive knows the book).
    @Published public var conversationCounts: [String: Int] = [:]
    @Published public var showSavedAINotes = false
    @Published public var sourceHealth: [BookSource: String] = [:]
    @Published public var sourceLastImport: [BookSource: Date] = [:]
    public var openSettingsWindow: ((SettingsRoute) -> Void)?
    /// Opens the library window on the Exports section. The companion uses it
    /// for the capture prompt chapter and whole-book scopes need.
    public var openLibraryWindow: (() -> Void)?
    public var openSavedNotesWindow: (() -> Void)?
    @Published public var settings = AISettings.load() {
        didSet {
            settings.save()
            applyTracking()
        }
    }
    @Published public var status = "Starting…"
    @Published public var notice: String?
    @Published public var isImporting = false
    /// The archive reload started by an import or a refresh. Completion is
    /// observable so a caller does not see stale books or counts.
    public private(set) var reloadTask: Task<Void, Never>?
    @Published public private(set) var permissionAccessibility = AXIsProcessTrusted()
    @Published public private(set) var permissionScreen = CGPreflightScreenCaptureAccess()
    @Published public private(set) var permissionCheckResult: String?
    @Published public private(set) var permissionScreenStatus = "Not verified"
    @Published public private(set) var permissionChecking = false
    @Published public private(set) var permissionCheckDetail: String?
    @Published public var livePage: LivePage?
    @Published public var liveError: String?
    @Published public var importError: String?
    @Published public var importFailures: [LibraryImportFailure] = []
    @Published public var showImportReport = false
    @Published public var trackedBookID: String?
    @Published public var capturePhase: CapturePhase = .idle
    @Published public var captureProgress: Double = 0
    @Published public var captureMessage = ""
    @Published public var capturePDF: URL?
    @Published public var captureDirectory: URL?
    @Published public var captureCleanPage: CleanPageSummary?
    @Published public var capturePageSetup: PageSetupOutcome?
    @Published public var selectedBookOriginal: OriginalAvailability?
    @Published public var originalNote: String?
    @Published public var popularHighlightsState: Bool?
    @Published public var popularHighlightsNote: String?
    @Published public var capturePageLimit: Int? = 10
    private var captureAccessDraft: CaptureAccessDraft?
    private let accessDefaults: UserDefaults
    @Published public var exportFolder: URL = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Tsundoku")
    @Published public var lastImport: Date?

    public let archive: Archive?
    private let sessionLogger: SessionLogger?
    private let captureSession = CaptureSession()
    private let libraryImportSession = LibraryImportCoordinator.Session()
    private var liveTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var pendingBookID: String?
    private var hasImported = false
    private var readerRecoveryDeferred = false
    @Published public private(set) var hasCompletedImport = false
    @Published public private(set) var lastImportResult: String?
    public var emptyLibraryMessage: String {
        lastImportResult ?? "Import your local Kindle or Apple Books library."
    }
    private var pollGeneration = 0
    private var reloadGeneration = 0
    private var aiNotesGeneration = 0
    private var conversationCountsGeneration = 0
    private var activityGeneration = 0
    private var permissionCancellables: Set<AnyCancellable> = []
    private var cleanRecoveryRunning = false
    private var popularHighlightsProbeRunning = false

    /// Set by the app shell. The companion owns the reading panel, so the
    /// library window asks it to open rather than creating a second panel.
    public var openCompanion: (() -> Void)?

    /// Set by the app shell so the settings pane can edit the shell's
    /// companion settings without the shell constructing this model at login.
    public var companionSettings: CompanionSettingsStore?

    /// The one permission snapshot shared with onboarding and the companion.
    public var permissions: PermissionsModel? {
        didSet { observePermissions() }
    }

    private let kindleImportPaths: KindlePaths
    private let booksImportPaths: BooksPaths

    public init(
        archiveURL: URL? = nil, kindlePaths: KindlePaths? = nil,
        booksPaths: BooksPaths? = nil, recoverReaderSettings: Bool = true,
        deferReaderRecovery: Bool = false, accessDefaults: UserDefaults = .standard
    ) {
        self.accessDefaults = accessDefaults
        let arguments = CommandLine.arguments
        func launchPath(_ option: String) -> URL? {
            guard let index = arguments.firstIndex(of: option),
                arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1])
        }
        kindleImportPaths = kindlePaths
            ?? launchPath("--kindle-library-path").map { KindlePaths(container: $0) }
            ?? .standard()
        booksImportPaths = booksPaths
            ?? launchPath("--books-data-path").map { BooksPaths(container: $0) }
            ?? .standard()
        do {
            let archive: Archive
            if let archiveURL {
                archive = try Archive(path: archiveURL)
            } else if let index = arguments.firstIndex(of: "--archive-path"), arguments.indices.contains(index + 1) {
                archive = try Archive(path: URL(fileURLWithPath: arguments[index + 1]))
            } else {
                archive = try Archive.standard()
            }
            self.archive = archive
            self.sessionLogger = SessionLogger(archive: archive)
            for source in BookSource.allCases {
                if let raw = archive.meta("last_import_source_\(source.rawValue)"),
                   let date = ISO8601DateFormatter().date(from: raw) { sourceLastImport[source] = date }
            }
            reloadFromArchive()
        } catch {
            self.archive = nil
            self.sessionLogger = nil
            self.status = "Could not open the archive: \(error)"
            self.notice = "Could not open the archive: \(error)"
        }
        if CommandLine.arguments.contains("--provider-codex") {
            settings.provider = .codexCLI
        }
        if let index = CommandLine.arguments.firstIndex(of: "--select-asin"),
            CommandLine.arguments.indices.contains(index + 1)
        {
            pendingBookID = CommandLine.arguments[index + 1]
        }
        if let index = CommandLine.arguments.firstIndex(of: "--section"),
            CommandLine.arguments.indices.contains(index + 1)
        {
            let requested = CommandLine.arguments[index + 1]
            if let section = Section(rawValue: requested) {
                self.section = section
            } else if requested == "annotations" {
                self.section = .highlights
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--source"),
            CommandLine.arguments.indices.contains(index + 1)
        {
            switch CommandLine.arguments[index + 1].lowercased() {
            case "kindle": sourceFilter = .kindle
            case "applebooks", "apple-books", "apple", "books":
                sourceFilter = .appleBooks
            case "all": sourceFilter = .all
            default: break
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--language"),
            CommandLine.arguments.indices.contains(index + 1)
        {
            settings.language = CommandLine.arguments[index + 1]
        }
        readerRecoveryDeferred = recoverReaderSettings && deferReaderRecovery
        if recoverReaderSettings && !deferReaderRecovery && !arguments.contains("--shell-only") { recoverSettingsIfNeeded() }
    }

    /// A crash between turning Popular Highlights off and restoring it leaves
    /// a journal behind. Restore it when Kindle is available; never block the
    /// launch on an Accessibility round trip.
    private func recoverSettingsIfNeeded() {
        guard capturePhase != .running,
            !cleanRecoveryRunning, !popularHighlightsProbeRunning,
            KindleLive.isRunning()
        else { return }
        let setupPending = PageSetupJournal().load() != nil
        let cleanPending = CleanPageJournal().load() != nil
        guard setupPending || cleanPending else { return }
        cleanRecoveryRunning = true
        Task.detached { [weak self] in
            var notices: [String] = []
            if setupPending, let outcome = KindlePageSetup.recoverIfNeeded() {
                notices.append(
                    outcome.restored
                        ? "Reader window and font restored after an "
                            + "interrupted capture."
                        : "Reader window or font could not be restored: "
                            + (outcome.reason ?? "unknown reason"))
            }
            if cleanPending,
                let outcome = CleanPageGuard.recoverIfNeeded(
                    panel: KindlePopularHighlights())
            {
                notices.append(
                    outcome.restored
                        ? "Popular Highlights was restored after an "
                            + "interrupted capture."
                        : "Popular Highlights could not be restored: "
                            + (outcome.reason ?? "unknown reason"))
            }
            await MainActor.run {
                self?.cleanRecoveryRunning = false
                guard let self, !notices.isEmpty else { return }
                self.notice = notices.joined(separator: " ")
            }
        }
    }

    /// Called when the artifacts window is opened on demand. Nothing here runs
    /// at login. A grant/import action can also create the archive model;
    /// reader recovery stays deferred until a library window is requested.
    public func activate(importLibrary shouldImport: Bool) {
        if readerRecoveryDeferred {
            readerRecoveryDeferred = false
            if !CommandLine.arguments.contains("--shell-only") { recoverSettingsIfNeeded() }
        }
        if shouldImport, !hasImported {
            hasImported = true
            importLibrary(announce: false)
        }
    }


    // MARK: - Derived

    public var selectedBook: Book? {
        guard let selectedBookID else { return nil }
        return books.first { $0.asin == selectedBookID }
    }

    public var filteredBooks: [Book] {
        let query = search.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return books.filter { book in
            guard book.isEbook else { return false }
            if let source = sourceFilter.source, book.source != source {
                return false
            }
            guard !query.isEmpty else { return true }
            return book.title.lowercased().contains(query)
                || book.author.lowercased().contains(query)
                || book.asin.lowercased().contains(query)
        }
    }

    public var selectedBookAnnotations: [Annotation] {
        guard let selectedBookID else { return [] }
        return annotations.filter { $0.asin == selectedBookID && $0.bookSource == selectedBook?.source }
    }

    public func showAnnotations(for book: Book) {
        annotationBookID = book.asin
        annotationSourceFilter = book.source == .kindle ? .kindle : .appleBooks
        annotationSearch = ""
        annotationFilter = .mine
        section = .highlights
    }

    /// Loads every AI card. The Cards view filters by book; loading all keeps
    /// the book query free of capture-index work on the main thread.
    public func refreshAICards() {
        guard let archive else { return }
        aiCardsGeneration += 1
        let generation = aiCardsGeneration
        Task {
            do {
                let cards = try await Task.detached {
                    try archive.aiCards()
                }.value
                guard generation == self.aiCardsGeneration else { return }
                aiCards = cards
                cardTurnIDs = Set(cards.map(\.turnID))
                aiCardsLoaded = true
                TsundokuDiagnostics.shared.event(
                    "ai_cards_loaded", ["cards": cards.count])
            } catch {
                TsundokuDiagnostics.shared.event(
                    "ai_cards_failed", ["error": "\(error)"])
                post("Could not read AI cards: \(error)", seconds: 12)
            }
        }
    }

    public func refreshAINotes() {
        guard let archive else { return }
        aiNotesGeneration += 1
        let generation = aiNotesGeneration
        Task {
            do {
                let notes = try await Task.detached {
                    try archive.aiNotes()
                }.value
                guard generation == self.aiNotesGeneration else { return }
                savedAINotes = notes
            } catch {
                post("Could not read saved AI notes: \(error)", seconds: 12)
            }
        }
    }

    /// The Messages column's count for a book.
    ///
    /// A book's threads can be filed under its ASIN, or under a weaker title
    /// key before the local text proves the edition. Both are its chats, so
    /// both count; the Chats tab lists them and marks the weaker ones unfiled.
    /// Capture-fingerprint keys are not counted here because they need the
    /// capture index, which the column must not read per row.
    public func conversationCount(for book: Book) -> Int {
        let keys = ConversationFiling.keys(
            for: book, captureFingerprints: [])
        return conversationCounts.reduce(0) { total, entry in
            keys.contains(ConversationFiling.canonical(entry.key))
                ? total + entry.value : total
        }
    }

    /// Refreshes the per-book chat counts the library column prints.
    public func refreshConversationCounts() {
        guard let archive else { return }
        conversationCountsGeneration += 1
        let generation = conversationCountsGeneration
        Task {
            do {
                let counts = try await Task.detached {
                    try archive.conversationCounts()
                }.value
                guard generation == self.conversationCountsGeneration else {
                    return
                }
                conversationCounts = counts
            } catch {
                post("Could not read chat history: \(error)", seconds: 12)
            }
        }
    }

    /// Exports → Capture as PDF, with the companion's book selected when the
    /// archive knows it. The capture itself remains an explicit action.
    /// The reader the companion showed when it asked for Capture. The saved
    /// capture preference must not override the book on screen.
    private var captureRouteKind: ReaderKind?
    /// True while a capture route has no archived book. It persists across
    /// reloads (the first import is not the only one) until the reader picks
    /// a book or a capture consumes the route.
    private var captureRouteWithoutBook = false

    public func openCaptureExports(
        bookID: String?, readerKind: ReaderKind? = nil
    ) {
        let match = bookID.flatMap { id in
            books.first {
                $0.asin.caseInsensitiveCompare(id) == .orderedSame
            }
        }
        // Set the book first: its didSet clears any previous route state.
        selectedBookID = match?.asin
        captureRouteKind = readerKind
        captureRouteWithoutBook = match == nil
        bookWorkspaceID = nil
        section = .exports
        openLibraryWindow?()
    }

    public struct PendingChat: Sendable, Equatable {
        public let bookID: String
        public let conversationID: Int64
        public let turnID: Int64?
    }

    @Published public private(set) var pendingChat: PendingChat?

    public func openChats(
        for book: Book, conversationID: Int64? = nil, turnID: Int64? = nil
    ) {
        // The card can be opened from the global Annotations view, which is
        // not the library workspace; without this switch the route changes
        // state that no visible view renders.
        section = .library
        bookWorkspaceID = book.asin
        bookWorkspaceSection = .chats
        pendingChat = conversationID.map {
            PendingChat(
                bookID: book.asin, conversationID: $0, turnID: turnID)
        }
    }

    /// Reads a card route without consuming it; a transient failure keeps it
    /// available for the next attempt.
    public func peekPendingChat(for bookID: String) -> PendingChat? {
        guard let pending = pendingChat, pending.bookID == bookID else {
            return nil
        }
        return pending
    }

    /// Consumes a card's chat route once the matching Chats view appears.
    public func takePendingChat(for bookID: String) -> PendingChat? {
        guard let pending = pendingChat, pending.bookID == bookID else {
            return nil
        }
        pendingChat = nil
        return pending
    }

    /// Consumes exactly the route the caller resolved; a newer route for the
    /// same book must survive an older lookup's completion.
    public func takePendingChat(_ expected: PendingChat) -> PendingChat? {
        guard pendingChat == expected else { return nil }
        pendingChat = nil
        return expected
    }

    /// Keeps the shared set in step with a companion write before the next
    /// full card load finishes.
    public func registerCard(turnID: Int64) {
        cardTurnIDs.insert(turnID)
    }

    private var cardRemovalTask: Task<Void, Never>?

    public func removeAICard(_ card: AICard) {
        // An in-flight card load may still contain this row; discard it so
        // its result cannot put "In Cards" back.
        aiCardsGeneration += 1
        cardTurnIDs.remove(card.turnID)
        guard let archive else { return }
        cardRemovalTask = Task {
            do {
                try await Task.detached {
                    try archive.removeCard(turnID: card.turnID)
                }.value
                self.refreshAICards()
                self.refreshAINotes()
            } catch {
                // The row is still there; put the ID back so the companion
                // does not claim "Add to Cards" over an existing card.
                self.cardTurnIDs.insert(card.turnID)
                self.post("Could not remove the AI card: \(error)", seconds: 12)
            }
        }
    }

    /// Waits for the last Remove from Cards write.
    public func awaitCardRemoval() async {
        await cardRemovalTask?.value
    }

    public var ebookCount: Int {
        books.filter(\.isEbook).count
    }

    public var kindleBookCount: Int {
        books.lazy.filter { $0.isEbook && $0.source == .kindle }.count
    }

    public var appleBooksBookCount: Int {
        books.lazy.filter { $0.isEbook && $0.source == .appleBooks }.count
    }

    public var selectedBookIsAppleBooks: Bool {
        selectedBook?.source == .appleBooks
    }

    public var userAnnotationCount: Int {
        annotations.lazy.filter { $0.provenance == .user }.count
    }

    public var userNoteCount: Int {
        annotations.lazy.filter {
            $0.provenance == .user && $0.kind == .note
        }.count
    }

    public var userHighlightCount: Int {
        annotations.lazy.filter {
            $0.provenance == .user && $0.kind == .highlight
        }.count
    }

    public var annotatedBookCount: Int {
        Set(
            annotations.lazy.filter { $0.provenance == .user }.map(\.asin)
        ).count
    }

    public var permissionsNeeded: Bool {
        !(permissionAccessibility && permissionScreen)
    }

    // MARK: - Loading

    private func reloadFromArchive() {
        guard let archive else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let task = Task {
            do {
                let books = try await Task.detached {
                    try archive.books()
                }.value
                let annotations = try await Task.detached {
                    try archive.annotations()
                }.value
                let sessions = try await Task.detached {
                    try archive.sessions()
                }.value
                let captures = try await Task.detached {
                    try archive.captures()
                }.value
                let counts = try await Task.detached {
                    try archive.counts()
                }.value
                guard generation == self.reloadGeneration else { return }
                self.books = books
                self.bookTitles = Dictionary(
                    books.map { ($0.asin, $0.title) },
                    uniquingKeysWith: { first, _ in first })
                self.annotations = annotations
                self.sessions = sessions
                self.captures = captures
                self.refreshAINotes()
                self.refreshAICards()
                self.refreshConversationCounts()
                self.counts = counts
                self.status =
                    "\(counts.books) books · \(counts.annotations) "
                    + "annotations · \(counts.userAnnotations) yours"
                let requested =
                    self.pendingBookID.flatMap { id in
                        books.contains { $0.asin == id } ? id : nil
                    }
                    ?? self.selectedBookID.flatMap { id in
                        books.contains { $0.asin == id } ? id : nil
                    }
                if self.captureRouteWithoutBook {
                    // Keep the route empty through this reload.
                } else if let target = requested
                    ?? books.first(where: { $0.isEbook })?.asin,
                    self.selectedBookID != target
                {
                    self.pendingBookID = nil
                    // Selecting the row after the list has its data avoids a
                    // re-entrant update during layout.
                    DispatchQueue.main.async {
                        self.selectedBookID = target
                    }
                }
                if let raw = archive.meta("last_import"),
                    let date = ISO8601DateFormatter().date(from: raw)
                {
                    self.lastImport = date
                }
            } catch {
                guard generation == self.reloadGeneration else { return }
                self.status = "Archive read failed: \(error)"
                self.post("Archive read failed: \(error)", seconds: 10)
            }
        }
        reloadTask = task
    }

    /// A grant may arrive while a different source is still importing. Coalesce
    /// those requests so newly readable sources are not silently skipped.
    public func requestLibraryImport() {
        importLibrary()
    }

    public func importLibrary(announce: Bool = true) {
        guard !CommandLine.arguments.contains("--no-import") else { return }
        guard archive != nil else { return }
        hasImported = true
        libraryImportSession.request(
            makeRun: { [weak self] in
                guard let self, let archive = self.archive else {
                    return nil
                }
                TsundokuDiagnostics.shared.event("library_import_started")
                self.isImporting = true
                self.importError = nil
                self.importFailures = []
                self.sourceHealth[.kindle] = "Importing…"
                self.sourceHealth[.appleBooks] = "Importing…"
                self.status = "Reading local stores…"
                let accessGeneration =
                    self.permissions?.librarySetupGeneration
                let kindlePaths = self.kindleImportPaths
                let booksPaths = self.booksImportPaths
                return LibraryImportCoordinator.Session.Run(
                    sources: [
                        LibraryImportCoordinator.Source(
                            source: .kindle,
                            missingMessage:
                                "No local store found; showing any archived "
                                + "records.",
                            read: {
                                guard try kindlePaths.validateAccess() else {
                                    return nil
                                }
                                return try KindleReader.readAll(kindlePaths)
                            }),
                        LibraryImportCoordinator.Source(
                            source: .appleBooks,
                            missingMessage: "No local store found.",
                            read: {
                                guard try booksPaths.validateAccess() else {
                                    return nil
                                }
                                return try BooksReader.readAll(booksPaths)
                            }),
                    ],
                    archive: archive, announce: announce,
                    accessGeneration: accessGeneration)
            },
            onOutcome: { [weak self] outcome, run in
                self?.applyImportOutcome(
                    outcome, announce: run.announce,
                    accessGeneration: run.accessGeneration)
            },
            onFinish: { [weak self] in
                guard let self else { return }
                self.isImporting = false
                self.hasCompletedImport = true
                self.lastImportResult = self.status
                self.reloadFromArchive()
            })
    }

    /// Publish one finished import. Task lifecycle and queuing belong to
    /// `LibraryImportCoordinator.Session`; this is wording and state only.
    private func applyImportOutcome(
        _ outcome: LibraryImportCoordinator.Outcome, announce: Bool,
        accessGeneration: Int?
    ) {
        sourceHealth.merge(
            outcome.health, uniquingKeysWith: { _, new in new })
        for (source, date) in outcome.lastImportBySource {
            sourceLastImport[source] = date
        }
        let failures = outcome.failures
        lastImport = outcome.lastImportDate ?? lastImport
        importFailures = failures
        importError =
            failures.isEmpty
            ? nil
            : failures.map { "\($0.source.displayName): \($0.detail)" }
                .joined(separator: "\n")
        TsundokuDiagnostics.shared.event("library_import_finished", [
            "books": outcome.books,
            "annotations": outcome.annotations,
            "failed_sources": failures.map { $0.source.rawValue },
            "access_denied_sources": failures.filter(\.accessDenied)
                .map { $0.source.rawValue },
        ])
        if outcome.books > 0 || outcome.annotations > 0 {
            status =
                "\(outcome.books) books · "
                + "\(outcome.annotations) annotations "
                + "· \(outcome.user) yours"
            let sourceLabel =
                outcome.importedSources.isEmpty
                ? "local stores"
                : outcome.importedSources.joined(separator: " and ")
            post(
                "Imported \(outcome.books.formatted()) books and "
                    + "\(outcome.annotations.formatted()) annotations "
                    + "from \(sourceLabel).",
                enabled: announce)
            if !failures.isEmpty {
                status = "Import partially completed. Some archived records may be out of date."
            }
        } else if !outcome.importedSources.isEmpty {
            status = "The local stores are empty."
            post(
                "The local Kindle or Apple Books stores are empty.",
                enabled: announce)
        } else if failures.isEmpty {
            status = "No local Kindle or Apple Books stores found."
            post(
                "No local Kindle or Apple Books stores were found.",
                enabled: announce)
        } else {
            status = failures.first?.summary ?? "Library import failed."
            post(status, seconds: 12)
        }
        if let accessGeneration {
            permissions?.completeLibrarySetup(
                importedSources: outcome.committedSources,
                failures: failures, generation: accessGeneration)
        }
    }

    /// Awaits the archive hydration started at launch. The companion opens
    /// eagerly (`AppModel` is created on first use) and its first page can be
    /// read before the imported book rows arrive; identity must not race them.
    public func awaitArchiveLoaded() async {
        while true {
            let generation = reloadGeneration
            guard let task = reloadTask else { return }
            await task.value
            if generation == reloadGeneration { return }
        }
    }

    /// Awaits the running import and any import queued behind it.
    ///
    /// There is no deadline: the work signals its own completion, so a loaded
    /// machine delays the answer instead of failing the wait. A test that
    /// calls this and then asserts a post-condition cannot race the import.
    public func awaitImportCompletion() async {
        await libraryImportSession.waitForCompletion()
        // The import task starts the archive reload; awaiting the import
        // alone would return with stale books and counts.
        await reloadTask?.value
    }

    /// A short-lived message for the sidebar footer.
    public func post(
        _ message: String, seconds: Double = 6, enabled: Bool = true
    ) {
        guard enabled else { return }
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    public func requestLibraryAccess() {
        if permissions == nil { permissions = PermissionsModel() }
        showImportReport = false
        openAccess(focus: .library, intent: .library)
        permissions?.requestLibraryAccess()
    }

    public func openAccess(focus: AccessFocus, intent: AccessIntent? = nil) {
        showImportReport = false
        openSettingsWindow?(SettingsRoute(pane: .access, focus: focus, intent: intent))
    }

    public func requestCaptureAccess(pages: Int?) {
        captureAccessDraft = CaptureAccessDraft(bookID: selectedBookID, pages: pages, settings: settings)
        openAccess(focus: permissionAccessibility ? .screenRecording : .accessibility, intent: .capture)
    }

    public func returnToCapture() {
        let stored = accessDefaults.data(forKey: "settings.captureAccessResume")
            .flatMap { try? JSONDecoder().decode(CaptureAccessDraft.self, from: $0) }
        let restored = stored.flatMap { (0..<(24 * 3600)).contains(Date().timeIntervalSince($0.createdAt)) ? $0 : nil }
        if let draft = captureAccessDraft ?? restored {
            selectedBookID = draft.bookID
            capturePageLimit = draft.pages
            draft.restore(into: &settings)
        }
        captureAccessDraft = nil
        discardCaptureAccessRelaunch()
        section = .exports
    }

    public func persistCaptureAccessForRelaunch() {
        guard let draft = captureAccessDraft, let data = try? JSONEncoder().encode(draft) else { return }
        accessDefaults.set(data, forKey: "settings.captureAccessResume")
    }
    public func discardCaptureAccessRelaunch() { accessDefaults.removeObject(forKey: "settings.captureAccessResume") }
    public func cancelAccessTask(intent: AccessIntent? = nil) {
        switch intent {
        case .capture: captureAccessDraft = nil; discardCaptureAccessRelaunch(); permissions?.cancelReaderRecovery(intent: .capture)
        case .library, nil: permissions?.cancelLibrarySetup()
        case .companion: permissions?.cancelReaderRecovery(intent: .companion)
        }
    }

    public func refreshPermissions() {
        if permissions == nil { permissions = PermissionsModel() }
        permissions?.refresh()
    }

    public func verifyPermissions(includeLibrary: Bool = false) async {
        if permissions == nil { permissions = PermissionsModel() }
        await permissions?.verifyAccess()
        if includeLibrary { await permissions?.verifyLibraryAccess() }
    }

    private func applyPermissions(_ snapshot: PermissionSnapshot) {
        permissionAccessibility = snapshot.accessibility
        permissionScreen = snapshot.screenRecording
        permissionScreenStatus = snapshot.screenStatus
        permissionCheckResult = snapshot.checkResult
        permissionChecking = snapshot.isChecking
        permissionCheckDetail = snapshot.detail
    }

    private func observePermissions() {
        permissionCancellables.removeAll()
        guard let permissions else { return }
        // The model emits on MainActor. Keep one atomic snapshot and avoid
        // deferred per-field deliveries overwriting a newer explicit check.
        permissions.$snapshot.sink { [weak self] snapshot in
            self?.applyPermissions(snapshot)
        }.store(in: &permissionCancellables)
    }

    /// Read Kindle's Popular Highlights state for the Exports pane. It opens
    /// and closes the Aa panel, so it is never run during a capture.
    public func refreshPopularHighlights() {
        guard capturePhase != .running, !cleanRecoveryRunning,
            !popularHighlightsProbeRunning, KindleLive.isRunning(),
            AXIsProcessTrusted()
        else {
            popularHighlightsState = nil
            return
        }
        popularHighlightsProbeRunning = true
        Task.detached { [weak self] in
            let result = Result { try KindlePopularHighlights().state() }
            await MainActor.run {
                self?.popularHighlightsProbeRunning = false
                switch result {
                case .success(let on):
                    self?.popularHighlightsState = on
                    self?.popularHighlightsNote = nil
                case .failure(let error):
                    self?.popularHighlightsState = nil
                    self?.popularHighlightsNote =
                        "Popular Highlights: could not be read (\(error))."
                }
            }
        }
    }

    public func refreshActivity() {
        guard let archive else { return }
        recoverSettingsIfNeeded()
        activityGeneration += 1
        let generation = activityGeneration
        Task {
            do {
                let sessions = try await Task.detached(operation: {
                    try archive.sessions()
                }).value
                guard generation == self.activityGeneration else { return }
                self.sessions = sessions
            } catch {
                self.post(
                    "Could not refresh reading sessions: \(error)",
                    seconds: 12)
            }
            do {
                let captures = try await Task.detached(operation: {
                    try archive.captures()
                }).value
                guard generation == self.activityGeneration else { return }
                self.captures = captures
            } catch {
                self.post(
                    "Could not refresh captures: \(error)", seconds: 12)
            }
        }
    }

    /// Check the selected book for a DRM-free original. Read-only: neither the
    /// Kindle download nor the Books asset is modified.
    public func refreshOriginalAvailability() {
        // Clear the previous book's availability before the next async check:
        // its buttons must never act on a book that is no longer selected.
        selectedBookOriginal = nil
        originalNote = nil
        guard let book = selectedBook else { return }
        // Check the same stores this model imports from, not the defaults:
        // launch arguments and injected paths must not be bypassed.
        let kindlePaths = kindleImportPaths
        let booksPaths = booksImportPaths
        Task.detached { [weak self] in
            let availability: OriginalAvailability
            var note: String?
            switch book.source {
            case .kindle:
                availability = OriginalDetector.kindle(
                    asin: book.asin, paths: kindlePaths)
            case .appleBooks:
                do {
                    if let asset = try BooksAssetReader(paths: booksPaths)
                        .asset(for: book.asin)
                    {
                        availability = OriginalDetector.books(asset: asset)
                        note = asset.warnings.first
                    } else {
                        availability = .missing
                    }
                } catch {
                    availability = .missing
                    note = "The Apple Books asset could not be read: \(error)"
                }
            }
            await MainActor.run {
                guard let self, self.selectedBookID == book.asin else {
                    return
                }
                self.selectedBookOriginal = availability
                self.originalNote = note
            }
        }
    }

    public func revealOriginal() {
        guard let url = selectedBookOriginal?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func copyOriginal() {
        guard let availability = selectedBookOriginal,
            availability.isAvailable,
            let kind = availability.kind
        else { return }
        let destination = exportFolder
        let destinationName = originalFilename(
            for: selectedBook?.asin ?? "book", kind: kind)
        Task.detached { [weak self] in
            let message: String
            var seconds: Double = 6
            do {
                let copied = try OriginalService.copy(
                    availability, into: destination,
                    destinationName: destinationName)
                message = "Copied the original to "
                    + "\(copied.url.lastPathComponent)."
            } catch {
                message = "Could not copy the original: \(error)"
                seconds = 10
            }
            await MainActor.run {
                self?.post(message, seconds: seconds)
            }
        }
    }

    public func requestAccessibility() {
        if let permissions {
            permissions.requestAccessibility()
            return
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    public func requestScreenRecording() {
        if let permissions {
            permissions.requestScreenRecording()
            return
        }
        _ = CGRequestScreenCaptureAccess()
        openScreenSettings()
    }

    public func openAccessibilitySettings() {
        if let permissions {
            permissions.openAccessibilitySettings()
            return
        }
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    public func openScreenSettings() {
        if let permissions {
            permissions.openScreenSettings()
            return
        }
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Live Kindle

    public func startLivePolling() {
        guard liveTask == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        TsundokuDiagnostics.shared.event("live_poll_started")
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollLive(generation: generation)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stopLivePolling() {
        pollGeneration += 1
        liveTask?.cancel()
        liveTask = nil
        livePage = nil
    }

    private func pollLive(generation: Int) async {
        guard generation == pollGeneration else { return }
        guard KindleLive.isRunning(), KindleLive.isTrusted() else {
            livePage = nil
            liveError = nil
            return
        }
        do {
            let page = try await Task.detached {
                try KindleLive.currentPage()
            }.value
            guard generation == pollGeneration, !Task.isCancelled else {
                return
            }
            livePage = page
            liveError = nil
        } catch {
            guard generation == pollGeneration, !Task.isCancelled else {
                return
            }
            // A failed read must not leave yesterday's page on screen.
            livePage = nil
            liveError = "\(error)"
        }
    }

    public func showAIPanel() {
        if capturePhase == .running {
            status =
                "The reader is busy capturing. The reading panel waits until the "
                + "capture finishes."
            return
        }
        openCompanion?()
    }

    // MARK: - Tracking

    public func toggleTracking() {
        if trackedBookID != nil {
            trackedBookID = nil
            sessionLogger?.stop()
            return
        }
        if let selectedBook, selectedBook.source == .appleBooks {
            post(
                "Reading sessions follow the live Kindle page. Select a "
                    + "Kindle book first.")
            return
        }
        if sourceFilter == .appleBooks {
            post(
                "Reading sessions follow the live Kindle page. Select a "
                    + "Kindle book first.")
            return
        }
        let asin: String?
        if let selectedBook {
            asin = selectedBook.asin
        } else if let recent = books.first(where: {
            $0.isEbook && $0.source == .kindle && $0.lastView != nil
        }) {
            asin = recent.asin
        } else if let kindle = books.first(where: {
            $0.isEbook && $0.source == .kindle
        }) {
            asin = kindle.asin
        } else {
            asin = selectedBookID
        }
        guard let asin else { return }
        trackedBookID = asin
        settings.sessionLogging = true
        sessionLogger?.setBook(asin)
        sessionLogger?.start()
    }

    /// Start tracking one chosen book, replacing any other tracked title.
    /// The library's per-book button must switch the target, not stop the
    /// book currently being tracked.
    public func startTracking(_ book: Book) {
        guard book.source == .kindle else {
            post(
                "Reading sessions follow the live Kindle page. Select a "
                    + "Kindle book first.")
            return
        }
        trackedBookID = book.asin
        settings.sessionLogging = true
        sessionLogger?.setBook(book.asin)
        sessionLogger?.start()
    }

    private func applyTracking() {
        if settings.sessionLogging, let trackedBookID {
            sessionLogger?.setBook(trackedBookID)
            sessionLogger?.start()
        } else {
            sessionLogger?.stop()
            if !settings.sessionLogging {
                // Keep the state machine in sync: a stopped logger must not
                // leave a tracked ID that turns the next toggle into "stop".
                trackedBookID = nil
            }
        }
    }

    // MARK: - Capture

    /// The reader a capture will use, from the reader setting and what is
    /// present: the selected book, a live Kindle page, the source filter, then
    /// the first ebook.
    public var captureKind: ReaderKind {
        if let captureRouteKind { return captureRouteKind }
        return CaptureReader.resolve(
            settings.captureReader,
            selected: selectedBook?.source,
            liveReader: livePage == nil ? nil : .kindle,
            filter: sourceFilter.source,
            firstBook: books.first(where: \.isEbook)?.source)
    }

    /// The book a capture will use: the selected book when it belongs to that
    /// reader, otherwise the first (recent) ebook from the same reader. Nil
    /// when the library has no book for it — the live page names the capture.
    public func captureBook(for kind: ReaderKind) -> Book? {
        // A companion route with no archived match runs from the live page;
        // it must not borrow the first ebook of the same reader.
        if captureRouteWithoutBook, selectedBookID == nil { return nil }
        let source: BookSource = kind == .appleBooks ? .appleBooks : .kindle
        if let selected = selectedBook, selected.source == source {
            return selected
        }
        let candidates = books.filter { $0.isEbook && $0.source == source }
        return candidates.first { $0.lastView != nil } ?? candidates.first
    }

    public func captureBook() -> Book? {
        captureBook(for: captureKind)
    }

    /// Whether the next capture will use Apple Books. The controls and the
    /// capture itself read this same resolution.
    public var captureTargetIsBooks: Bool {
        captureKind == .appleBooks
    }

    public func startCapture(pages: Int?) {
        guard let archive else { return }
        guard capturePhase != .running, !captureSession.isRunning else {
            return
        }
        refreshPermissions()
        guard !permissionsNeeded else {
            requestCaptureAccess(pages: pages)
            return
        }
        // The probe and the crash recovery both open Kindle's settings panel;
        // a capture must not start on top of either.
        guard !popularHighlightsProbeRunning, !cleanRecoveryRunning else {
            capturePhase = .failed
            captureMessage =
                "Tsundoku is reading Kindle's settings. Try again in a moment."
            return
        }
        let kind = captureKind
        let book = captureBook(for: kind)
        captureRouteKind = nil
        captureRouteWithoutBook = false
        let title = book?.title ?? livePage?.title ?? "Book"
        let folder = exportFolder.appendingPathComponent(
            "\(slug(title))-\(timestamp())")
        capturePhase = .running
        captureProgress = 0
        capturePageLimit = pages
        captureMessage = "Starting…"
        capturePDF = nil
        captureCleanPage = nil
        capturePageSetup = nil
        captureDirectory = folder
        let flag = CancellationFlag()
        let cleanPolicy: CleanPagePolicy =
            settings.cleanPageDuringCapture ? .hidePopularHighlights
                : .asDisplayed
        let setup = PageSetupRequest(
            pageSize: settings.capturePageSize,
            font: settings.captureFontSize,
            cropTop: settings.captureCropTop,
            cropBottom: settings.kindleCropBottom)
        let booksSetup = PageSetupRequest(
            pageSize: settings.capturePageSize,
            booksFontSteps: settings.booksFontSteps,
            cropTop: settings.captureCropTop,
            cropBottom: settings.booksCropBottom)
        let bundleOptions = settings.captureBundleOptions
        let request = CaptureCoordinator.Request(
            archive: archive, book: book, kind: kind, pageLimit: pages,
            output: folder, cleanPage: cleanPolicy, pageSetup: setup,
            booksPageSetup: booksSetup, bundleOptions: bundleOptions,
            cancellation: flag)
        captureSession.start(
            request,
            progress: { [weak self] progress in
                self?.captureProgress = progress.fraction
                self?.captureMessage = progress.message
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let result):
                    self.capturePhase = .finished
                    self.captureProgress = 1
                    self.captureMessage =
                        "\(result.pages) pages · \(result.title)"
                    self.capturePDF = result.pdf
                    self.captureCleanPage = result.cleanPage
                    self.capturePageSetup = result.pageSetup
                    self.captureDirectory = result.directory
                    self.reloadFromArchive()
                case .failure(let error):
                    self.capturePhase = .failed
                    self.captureMessage = "\(error)"
                }
            })
    }

    public func cancelCapture() {
        captureSession.cancel()
        captureMessage = "Cancelling after this page…"
    }

    public func openPDF() {
        guard let capturePDF else { return }
        NSWorkspace.shared.open(capturePDF)
    }

    public func revealCapture() {
        guard let captureDirectory else { return }
        NSWorkspace.shared.selectFile(
            capturePDF?.path, inFileViewerRootedAtPath: captureDirectory.path)
    }

    public func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = exportFolder
        if panel.runModal() == .OK, let url = panel.url {
            exportFolder = url
        }
    }

    /// A per-book original name. The hash of the full identifier keeps two
    /// identifiers that share a sanitized prefix from colliding.
    private func originalFilename(
        for identifier: String, kind: OriginalKind
    ) -> String {
        let raw = identifier.isEmpty ? "book" : identifier
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_"))
        let sanitized = raw.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        let prefix = String(sanitized.prefix(48))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return "original-\(prefix)-\(String(hash, radix: 16))."
            + kind.fileExtension
    }

    private func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_ "))
        let cleaned = value.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        let text = String(cleaned).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return text.isEmpty ? "kindle-book" : String(text.prefix(48))
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// A bounded resume bookmark, never a capture job. It contains only the book
/// identity, page limit and capture preferences; no provider credentials.
private struct CaptureAccessDraft: Codable {
    let bookID: String?
    let pages: Int?
    let createdAt: Date
    let options: CaptureAccessOptions
    init(bookID: String?, pages: Int?, settings: AISettings) {
        self.bookID = bookID; self.pages = pages; createdAt = Date()
        options = CaptureAccessOptions(settings)
    }
    func restore(into value: inout AISettings) { options.restore(into: &value) }
}
private struct CaptureAccessOptions: Codable {
    let pageSize: CapturePageSize
    let fontSize: Int?
    let booksFontSteps: Int
    let cropTop: Int
    let booksCropBottom: Int
    let kindleCropBottom: Int
    let cleanPage: Bool
    let includeCover: Bool
    let writeSidecars: Bool
    /// Optional so a bookmark written before the reader choice existed still
    /// decodes.
    let captureReader: CaptureReader?
    init(_ settings: AISettings) {
        pageSize = settings.capturePageSize; fontSize = settings.captureFontSize
        booksFontSteps = settings.booksFontSteps; cropTop = settings.captureCropTop
        booksCropBottom = settings.booksCropBottom; kindleCropBottom = settings.kindleCropBottom
        cleanPage = settings.cleanPageDuringCapture; includeCover = settings.includeCoverPage
        writeSidecars = settings.writeSidecars
        captureReader = settings.captureReader
    }
    func restore(into value: inout AISettings) {
        value.capturePageSize = pageSize; value.captureFontSize = fontSize
        value.booksFontSteps = booksFontSteps; value.captureCropTop = cropTop
        value.booksCropBottom = booksCropBottom; value.kindleCropBottom = kindleCropBottom
        value.cleanPageDuringCapture = cleanPage; value.includeCoverPage = includeCover
        value.writeSidecars = writeSidecars
        if let captureReader { value.captureReader = captureReader }
    }
}
