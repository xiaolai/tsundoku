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
    @Published public private(set) var abandonedCaptures: [AbandonedCapture] = []
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
    @Published public private(set) var conversationCountsBySource:
        [String: [String: Int]] = [:]
    @Published public private(set) var conversationStorage: ConversationStorage?
    @Published public private(set) var retentionImpact: ConversationDeletionImpact?
    @Published public private(set) var retentionBusy = false
    private var retentionReviewIDs: Set<Int64> = []
    private var retentionReviewCutoff: Date?
    private var retentionReviewDays: Int?
    private var retentionReviewUpdatedAt: [Int64: Date] = [:]
    private var retentionReviewRevisions: [Int64: Int64] = [:]
    private var retentionReviewCardNoteIDs: Set<Int64> = []
    private var retentionPolicyRevision = 0
    /// IDs removed by a Chats action, so an open companion can clear a thread
    /// that no longer exists.
    @Published public private(set) var deletedConversationIDs: Set<Int64> = []
    /// Bumped when a library view changes a transcript's compaction. An open
    /// companion refreshes its prompt projection instead of sending the old
    /// summary or the full history after a Remove Summary.
    @Published public private(set) var conversationChangeRevision = 0
    @Published public private(set) var changedConversationIDs: Set<Int64> = []
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
            if oldValue.chatRetentionDays != settings.chatRetentionDays {
                // A confirmation belongs to the period the reader reviewed.
                // Changing the policy, even away and back, requires a new
                // review before launch cleanup can run.
                retentionPolicyRevision += 1
                settings.chatRetentionConfirmed = false
                settings.chatRetentionConfirmedDays = 0
            }
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
    @Published public var capturePageLimit: Int? = 10
    @Published public var manualPreview: PagePreview?
    @Published public var manualCrop: CaptureCrop?
    @Published public var manualPreviewBusy = false
    @Published public var manualPreviewError: String?
    @Published public var manualFitMessage: String?
    @Published public var manualReadiness: CaptureReadiness?
    @Published public private(set) var manualPreviewFollowing = false
    private var manualPreviewFollowTask: Task<Void, Never>?
    private var manualPreviewFollowingPaused = false
    private var manualPreviewRefreshing = false
    private var manualPreviewRefreshPending = false
    private var manualPreviewGeneration = 0
    private var manualPreviewRetryAt = Date.distantPast
    private var manualPreviewImageProbeAt = Date.distantPast
    private var captureAccessDraft: CaptureAccessDraft?
    private let accessDefaults: UserDefaults
    @Published public var exportFolder: URL = AppModel.storedExportFolder()
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
    private var cleanupGeneration = 0
    private var permissionCancellables: Set<AnyCancellable> = []
    private var cleanRecoveryRunning = false

    /// Set by the app shell. The companion owns the reading panel, so the
    /// library window asks it to open rather than creating a second panel.
    public var openCompanion: (() -> Void)?
    /// Opens the companion and continues a specific stored conversation.
    public var openCompanionChat: ((PendingCompanionChat) -> Void)?

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
        runChatRetentionIfEnabled()
    }

    /// A crash between turning Popular Highlights off and restoring it leaves
    /// a journal behind. Restore it when Kindle is available; never block the
    /// launch on an Accessibility round trip.
    private func recoverSettingsIfNeeded() {
        guard capturePhase != .running, !cleanRecoveryRunning,
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

    /// Delete one saved answer. The same row is the card, when the note was
    /// carded, so the card disappears with it.
    public func deleteSavedAINote(_ note: SavedAINote) {
        guard let archive else { return }
        aiNotesGeneration += 1
        Task {
            do {
                let deleted = try await Task.detached {
                    try archive.deleteAINote(id: note.id)
                }.value
                post(
                    deleted ? "Deleted the saved note." : "The note was already gone.",
                    seconds: 5)
                refreshAINotes()
            } catch {
                post("Could not delete the saved note: \(error)", seconds: 12)
            }
        }
    }

    /// Delete every saved answer, reported by count.
    public func deleteAllSavedAINotes() {
        guard let archive else { return }
        aiNotesGeneration += 1
        Task {
            do {
                let count = try await Task.detached {
                    try archive.deleteAllAINotes()
                }.value
                post(
                    count == 1
                        ? "Deleted 1 saved note."
                        : "Deleted \(count) saved notes.", seconds: 6)
                refreshAINotes()
            } catch {
                post("Could not delete the saved notes: \(error)", seconds: 12)
            }
        }
    }

    /// A review gate before the bulk delete: the count is shown, and nothing
    /// is removed until the reader confirms.
    @Published public var reviewingNoteDeletion = false

    public func confirmDeleteAllSavedAINotes() {
        refreshAINotes()
        reviewingNoteDeletion = true
    }

    public func dismissNoteDeletionReview() { reviewingNoteDeletion = false }

    public func performDeleteAllSavedAINotes() {
        reviewingNoteDeletion = false
        deleteAllSavedAINotes()
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
        let source = book.source.rawValue
        return conversationCounts.reduce(0) { total, entry in
            guard keys.contains(ConversationFiling.canonical(entry.key))
            else { return total }
            if let bySource = conversationCountsBySource[entry.key] {
                let matching = bySource[source] ?? 0
                let unknown = bySource[""] ?? 0
                return total + matching + unknown
            }
            return total + entry.value
        }
    }

    /// Refreshes the per-book chat counts the library column prints.
    public func refreshConversationCounts() {
        guard let archive else { return }
        conversationCountsGeneration += 1
        let generation = conversationCountsGeneration
        Task {
            do {
                let loaded = try await Task.detached {
                    () -> (
                        [String: Int], [String: [String: Int]],
                        ConversationStorage?, String?
                    ) in
                    do {
                        return (
                            try archive.conversationCounts(),
                            try archive.conversationCountsBySource(),
                            try archive.conversationStorage(), nil)
                    } catch {
                        return (
                            try archive.conversationCounts(), [:], nil,
                            "\(error)")
                    }
                }.value
                guard generation == self.conversationCountsGeneration else {
                    return
                }
                conversationCounts = loaded.0
                conversationCountsBySource = loaded.1
                conversationStorage = loaded.2
                if let error = loaded.3 {
                    post(
                        "Could not read chat storage: \(error)",
                        seconds: 12)
                }
            } catch {
                post("Could not read chat history: \(error)", seconds: 12)
            }
        }
    }

    private var chatRetentionCutoff: Date? {
        guard settings.chatRetentionDays > 0 else { return nil }
        return Calendar.current.date(
            byAdding: .day, value: -settings.chatRetentionDays, to: Date())
    }

    /// Ask before the first destructive retention pass. The UI shows the
    /// returned counts; nothing is deleted here.
    public func reviewChatRetention() {
        guard let archive, let cutoff = chatRetentionCutoff else {
            retentionImpact = nil
            return
        }
        let reviewedDays = settings.chatRetentionDays
        let policyRevision = retentionPolicyRevision
        retentionBusy = true
        Task {
            defer { retentionBusy = false }
            do {
                let reviewed = try await Task.detached {
                    try archive.retentionReview(olderThan: cutoff)
                }.value
                guard self.settings.chatRetentionDays == reviewedDays,
                    self.retentionPolicyRevision == policyRevision
                else {
                    self.retentionReviewIDs = []
                    self.retentionReviewCutoff = nil
                    self.retentionReviewDays = nil
                    self.retentionReviewUpdatedAt = [:]
                    self.retentionReviewRevisions = [:]
                    self.retentionReviewCardNoteIDs = []
                    self.retentionImpact = nil
                    self.post(
                        "The retention period changed while the review was "
                            + "loading; review it again.", seconds: 8)
                    return
                }
                retentionReviewIDs = reviewed.ids
                retentionReviewCutoff = cutoff
                retentionReviewDays = reviewedDays
                retentionReviewUpdatedAt = reviewed.updatedAt
                retentionReviewRevisions = reviewed.revisions
                retentionReviewCardNoteIDs = reviewed.cardNoteIDs
                retentionImpact = reviewed.impact
            } catch {
                post("Could not inspect old chats: \(error)", seconds: 12)
            }
        }
    }

    public func dismissRetentionImpact() {
        retentionReviewIDs = []
        retentionReviewCutoff = nil
        retentionReviewDays = nil
        retentionReviewUpdatedAt = [:]
        retentionReviewRevisions = [:]
        retentionReviewCardNoteIDs = []
        retentionImpact = nil
    }

    /// Delete chats older than the configured window. This runs only after
    /// the reader has confirmed retention, or when they confirm the review
    /// alert. Every reviewed chat must still have its reviewed timestamp,
    /// summary and cards; a chat that gained any of them after the review
    /// survives, and the whole pass asks to be reviewed again.
    public func performChatRetention() {
        guard let archive else { return }
        let ids = retentionReviewIDs
        let cutoff = retentionReviewCutoff
        let reviewedDays = retentionReviewDays
        let expectedUpdatedAt = retentionReviewUpdatedAt
        let expectedRevisions = retentionReviewRevisions
        let expectedCardNoteIDs = retentionReviewCardNoteIDs
        retentionReviewIDs = []
        retentionReviewCutoff = nil
        retentionReviewDays = nil
        retentionReviewUpdatedAt = [:]
        retentionReviewRevisions = [:]
        retentionReviewCardNoteIDs = []
        retentionImpact = nil
        guard let reviewedDays,
            reviewedDays == settings.chatRetentionDays
        else {
            post(
                "The retention period changed; review the cleanup again.",
                seconds: 8)
            return
        }
        guard cutoff != nil, !ids.isEmpty else {
            settings.chatRetentionConfirmed = true
            settings.chatRetentionConfirmedDays = reviewedDays
            return
        }
        let policyRevision = retentionPolicyRevision
        retentionBusy = true
        Task {
            defer { retentionBusy = false }
            do {
                let result = try await Task.detached {
                    let impact = try archive.deleteConversations(
                        ids: ids, expectedUpdatedAt: expectedUpdatedAt,
                        expectedCompactionRevisions: expectedRevisions,
                        expectedCardNoteIDs: expectedCardNoteIDs,
                        olderThan: cutoff)
                    // The transaction verifies every reviewed row still
                    // exists with its reviewed timestamp before deleting,
                    // so a committed pass removed exactly those rows. No
                    // post-commit read is needed to know what to notify.
                    return (impact, Set(expectedUpdatedAt.keys))
                }.value
                let impact = result.0
                if !result.1.isEmpty {
                    markConversationsDeleted(result.1)
                }
                if policyRevision == self.retentionPolicyRevision {
                    settings.chatRetentionConfirmed = true
                    settings.chatRetentionConfirmedDays = reviewedDays
                } else {
                    post(
                        "The retention period changed during cleanup; "
                            + "review it again before launch cleanup.",
                        seconds: 8)
                }
                refreshConversationCounts()
                post(
                    "Removed \(impact.conversations) old "
                        + (impact.conversations == 1 ? "chat" : "chats")
                        + "; \(impact.notes) saved notes were kept.",
                    seconds: 8)
            } catch {
                post("Could not remove old chats: \(error)", seconds: 12)
            }
        }
    }

    /// At launch, retention runs only after the reader confirmed it once.
    public func runChatRetentionIfEnabled() {
        guard settings.chatRetentionDays > 0,
            settings.chatRetentionConfirmed,
            settings.chatRetentionConfirmedDays
                == settings.chatRetentionDays
        else { return }
        guard let archive, let cutoff = chatRetentionCutoff else { return }
        // Run synchronously on the main actor at launch: there is no window
        // in which the reader can abandon the policy while a queued task
        // still deletes under it.
        do {
            let ids = try archive.conversationIDs(olderThan: cutoff)
            _ = try archive.deleteConversations(
                ids: ids, olderThan: cutoff)
            let surviving = try archive.existingConversationIDs(ids)
            let deleted = ids.subtracting(surviving)
            if !deleted.isEmpty {
                markConversationsDeleted(deleted)
                refreshConversationCounts()
            }
        } catch {
            post("Could not remove old chats: \(error)", seconds: 12)
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

    public struct PendingCompanionChat: Sendable, Equatable {
        public let bookID: String
        /// The library source of the book the chat belongs to. Kindle and
        /// Apple Books can share an identifier, so the ID alone cannot tell
        /// which reader window should continue the chat.
        public let bookSource: BookSource?
        /// The chat to resume. Nil asks the companion for a new chat about
        /// the same book, which is what the empty Chats tab offers.
        public let conversationID: Int64?
    }

    @Published public private(set) var pendingChat: PendingChat?

    /// Continue an older chat from the library. The companion checks the
    /// live book before loading it; an unfiled chat must be filed first.
    public func continueChat(
        book: Book, conversationID: Int64
    ) {
        let pending = PendingCompanionChat(
            bookID: book.asin, bookSource: book.source,
            conversationID: conversationID)
        openCompanionChat?(pending)
    }

    /// Start a new chat about a library book. The companion still needs that
    /// book open in a reader; it says so when it is not.
    public func startChat(book: Book) {
        let pending = PendingCompanionChat(
            bookID: book.asin, bookSource: book.source,
            conversationID: nil)
        openCompanionChat?(pending)
    }

    public func markConversationsDeleted(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        deletedConversationIDs.formUnion(ids)
        // Cards are joined to turns; deleting the chat removes those cards
        // without touching the saved-note rows.
        refreshAICards()
        refreshAINotes()
    }

    public func markConversationChanged(_ conversationID: Int64? = nil) {
        if let conversationID {
            changedConversationIDs.insert(conversationID)
        }
        conversationChangeRevision += 1
    }

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

    /// Re-reads the reader now instead of waiting for the next two-second
    /// poll. The library refresh button calls this beside its import.
    public func refreshLivePage() async {
        await pollLive(generation: pollGeneration)
    }

    public func refreshAll() {
        importLibrary()
        Task { await refreshLivePage() }
    }

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

    /// The Kindle book the reader actually has open. Kindle's own last-opened
    /// ASIN is authoritative; the title is a fallback only when exactly one
    /// archived book carries it.
    public var liveKindleBook: Book? {
        guard let page = livePage else { return nil }
        if let id = page.bookID, !id.isEmpty,
            let byID = books.first(where: {
                $0.source == .kindle
                    && $0.asin.caseInsensitiveCompare(id) == .orderedSame
            })
        {
            return byID
        }
        let title = ConversationKey.normalize(page.title)
        guard !title.isEmpty,
            !ReadingIdentityResolver.isPlaceholder(page.title)
        else { return nil }
        let matches = books.filter {
            $0.isEbook && $0.source == .kindle
                && ConversationKey.normalize($0.title) == title
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The book a capture will use. The open reader is the target: a Kindle
    /// capture follows Kindle's last-opened book even when the library has a
    /// different row selected. The library selection is the fallback only
    /// when that reader is not open. Nil lets the live page name the capture.
    public func captureBook(for kind: ReaderKind) -> Book? {
        // A companion route with no archived match runs from the live page;
        // it must not borrow the first ebook of the same reader.
        if captureRouteWithoutBook, selectedBookID == nil { return nil }
        let source: BookSource = kind == .appleBooks ? .appleBooks : .kindle
        if kind == .kindle {
            if let live = liveKindleBook { return live }
            // Kindle is open on a book the archive does not know; naming the
            // library selection here would capture a different book.
            if livePage != nil { return nil }
        }
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

    public func refreshManualPreview() {
        requestManualPreview(showBusy: true)
    }

    /// Keep the preview on the page Kindle is showing while Exports is open.
    /// The loop reads AX at a low cadence and captures only when the page
    /// identity changes; image-only pages fall back to a one-second visual
    /// probe because they expose no text or page number.
    public func startManualPreviewFollow() {
        guard manualPreviewFollowTask == nil, captureKind == .kindle else {
            return
        }
        manualPreviewFollowingPaused = false
        manualPreviewFollowing = true
        manualPreviewFollowTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.manualPreviewFollowTick()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    public func stopManualPreviewFollow() {
        manualPreviewFollowTask?.cancel()
        manualPreviewFollowTask = nil
        manualPreviewFollowing = false
    }

    public func setManualPreviewFollowPaused(_ paused: Bool) {
        manualPreviewFollowingPaused = paused
        if paused {
            // A refresh already in flight must not replace the crop the
            // editor is holding.
            manualPreviewGeneration += 1
            manualPreviewRefreshPending = false
            manualPreviewBusy = false
        } else {
            manualPreviewRetryAt = .distantPast
            startManualPreviewFollow()
        }
    }

    private func clearManualPreview() {
        manualPreviewGeneration += 1
        manualPreviewRefreshPending = false
        manualPreviewBusy = false
        manualPreview = nil
        manualCrop = nil
        manualReadiness = nil
    }

    private func requestManualPreview(showBusy: Bool) {
        guard capturePhase != .running else { return }
        if manualPreviewRefreshing {
            manualPreviewRefreshPending = true
            if showBusy { manualPreviewBusy = true }
            return
        }
        manualPreviewRefreshing = true
        manualPreviewRetryAt = .distantPast
        if showBusy { manualPreviewBusy = true }
        let generation = manualPreviewGeneration
        let previousWindowSize = manualPreview?.windowFrame.size
        let hadPrevious = manualPreview != nil
        Task {
            let result = await Task.detached {
                Result {
                    try PagePreviewService(
                        allowTextBoundsFallback: true
                    ).preview()
                }
            }.value
            self.manualPreviewRefreshing = false
            let pending = self.manualPreviewRefreshPending
            self.manualPreviewRefreshPending = false
            if !pending { self.manualPreviewBusy = false }
            defer {
                if pending {
                    self.requestManualPreview(showBusy: self.manualPreviewBusy)
                }
            }
            guard self.manualPreviewGeneration == generation else {
                return
            }
            switch result {
            case .success(let preview):
                self.manualPreviewError = nil
                self.manualPreview = preview
                let window = CGRect(
                    origin: .zero, size: preview.windowFrame.size)
                let sameSize = previousWindowSize.map {
                    PageFrame.sameSize(
                        $0, preview.windowFrame.size, tolerance: 4)
                } ?? false
                let currentCrop = self.manualCrop
                // The Kindle flow always writes A4 pages, so the crop keeps
                // the A4 ratio by construction rather than by a toggle that
                // can leave the image letterboxed.
                if let currentCrop, sameSize, currentCrop.isUsable {
                    self.manualCrop = currentCrop.a4Locked(in: window)
                } else {
                    self.manualCrop = preview.crop.a4Locked(in: window)
                }
                if showBusy { self.manualFitMessage = nil }
                self.refreshManualReadiness(live: preview.live)
            case .failure(let error):
                if case PagePreviewError.pageChanged = error, hadPrevious {
                    self.manualPreviewRetryAt =
                        Date().addingTimeInterval(0.3)
                    self.refreshManualReadiness()
                    return
                }
                self.manualPreviewError = "\(error)"
                self.manualPreviewRetryAt = Date().addingTimeInterval(1.5)
                if self.manualPreview == nil {
                    self.manualReadiness = nil
                }
            }
        }
    }

    private func manualPreviewFollowTick() async {
        guard manualPreviewFollowing, !manualPreviewFollowingPaused,
            capturePhase != .running, captureKind == .kindle,
            permissionAccessibility, permissionScreen
        else { return }
        let live = await Task.detached {
            try? KindleLive.currentPage()
        }.value
        guard !Task.isCancelled, manualPreviewFollowing,
            !manualPreviewFollowingPaused, capturePhase != .running,
            captureKind == .kindle
        else { return }
        guard let live else {
            refreshManualReadiness(live: nil)
            return
        }
        refreshManualReadiness(live: live)
        guard live.isReading else { return }
        let now = Date()
        guard now >= manualPreviewRetryAt else { return }
        guard !manualPreviewRefreshing else { return }
        guard let preview = manualPreview else {
            requestManualPreview(showBusy: false)
            return
        }
        if PagePreviewFollower.needsRefresh(preview: preview, live: live) {
            requestManualPreview(showBusy: false)
            return
        }
        if PagePreviewFollower.needsImageProbe(live: live),
            now.timeIntervalSince(manualPreviewImageProbeAt) >= 1
        {
            manualPreviewImageProbeAt = now
            requestManualPreview(showBusy: false)
        }
    }

    public func refreshManualReadiness() {
        refreshManualReadiness(live: try? KindleLive.currentPage())
    }

    private func refreshManualReadiness(live: LivePage?) {
        guard let preview = manualPreview else {
            if manualReadiness != nil { manualReadiness = nil }
            return
        }
        let window = PageFrame.rect(live?.windowFrame)
        let windowMatches: Bool = {
            guard let window else { return false }
            return PageFrame.sameSize(
                window.size, preview.windowFrame.size, tolerance: 4)
        }()
        let bookMatches = live.map { preview.identity.matches($0) } ?? false
        let pageMatches: Bool = {
            guard let live else { return false }
            if !preview.text.isEmpty || !live.text.isEmpty {
                return preview.text == live.text
            }
            if let before = preview.pageNumber, let after = live.pageNumber {
                return before == after
            }
            return true
        }()
        let folder = exportFolder
        let outputWritable =
            FileManager.default.isWritableFile(atPath: folder.path)
            || FileManager.default.isWritableFile(
                atPath: folder.deletingLastPathComponent().path)
        let input = CaptureReadinessInput(
            hasAccessibility: permissionAccessibility,
            hasScreenRecording: permissionScreen,
            isRunning: KindleLive.isRunning(),
            isReading: live?.isReading == true,
            isMinimized: live?.isMinimized ?? true,
            isMainWindow: live?.isMainWindow ?? false,
            bookMatches: bookMatches,
            windowMatches: windowMatches,
            pageMatches: pageMatches,
            outputWritable: outputWritable,
            captureBusy: capturePhase == .running,
            pageCountKnown: live?.pageCount != nil)
        let next = CaptureReadinessChecker.check(input)
        if manualReadiness != next { manualReadiness = next }
    }

    public func fitKindleWindowToA4() {
        guard captureKind == .kindle, capturePhase != .running else {
            return
        }
        manualPreviewBusy = true
        manualPreviewError = nil
        manualFitMessage = nil
        // Remember where Kindle was before the first fit. Fit A4 changes a
        // window this app does not own, so the reader must be able to undo it.
        if restoreKindleFrame == nil,
            let frame = try? KindleLive.currentPage().windowFrame
        {
            restoreKindleFrame = CGRect(
                x: frame.x, y: frame.y,
                width: frame.width, height: frame.height)
        }
        let areas = PageFrame.displayAreas()
        Task {
            let result = await Task.detached {
                Result { () -> A4FitResult in
                    guard let first = areas.first else {
                        throw A4FitError.refused(
                            "no active display was found")
                    }
                    let initial = try Self.measureKindleForA4()
                    let area =
                        areas.first {
                            $0.display.contains(
                                CGPoint(
                                    x: initial.window.midX,
                                    y: initial.window.midY))
                        } ?? first
                    let service = A4FitService()
                    return try service.fit(
                        area: area,
                        measure: { try Self.measureKindleForA4() },
                        apply: { try KindleLive.setWindowFrame($0) },
                        settle: {
                            Thread.sleep(forTimeInterval: 0.7)
                        })
                }
            }.value
            self.manualPreviewBusy = false
            switch result {
            case .success(let fit):
                self.manualFitMessage =
                    "Fit \(fit.mode.rawValue): window "
                    + "\(Int(fit.frame.width))×\(Int(fit.frame.height)) pt, "
                    + "page \(Int(fit.pageBox.width))×"
                    + "\(Int(fit.pageBox.height)) pt"
                    + (fit.mode == .scaledToDisplay
                        ? " · the usable display area limited the page size"
                        : "")
                self.clearManualPreview()
                self.refreshManualPreview()
            case .failure(let error):
                self.manualPreviewError = "\(error)"
            }
        }
    }

    @Published public private(set) var restoreKindleFrame: CGRect?

    public var canRestoreKindleWindow: Bool { restoreKindleFrame != nil }

    /// Put the Kindle window back where Fit A4 found it. The frame is kept
    /// only for this session; a relaunch must not move a window the reader
    /// has since arranged.
    public func restoreKindleWindow() {
        guard let frame = restoreKindleFrame else { return }
        do {
            _ = try KindleLive.setWindowFrame(frame)
            restoreKindleFrame = nil
            manualFitMessage = "Kindle window restored."
            clearManualPreview()
            refreshManualPreview()
        } catch {
            manualPreviewError = "\(error)"
        }
    }

    public func startCapture(pages: Int?) {
        beginCapture(pages: pages, manual: nil)
    }

    /// Start the Kindle flow from the reviewed preview. It refuses to fall
    /// back to the automatic rewind path when no preview exists.
    public func startManualCapture(pages: Int?) {
        guard captureKind == .kindle else {
            startCapture(pages: pages)
            return
        }
        // A nil limit keeps its "all pages" meaning: the manual session is
        // forward-only, so it captures from the previewed page to the end
        // without the rewind the automatic Kindle path would perform.
        guard let preview = manualPreview,
            let approved = manualCrop,
            approved.isUsable
        else {
            capturePhase = .failed
            captureMessage =
                "Preview the current page and approve the crop before "
                + "capturing."
            return
        }
        // The capture writes A4 pages: the crop must keep that ratio, and
        // the same crop is used for the preview mark and for every frame.
        let crop = approved.a4Locked(
            in: CGRect(origin: .zero, size: preview.windowFrame.size))
        manualCrop = crop
        refreshManualReadiness()
        if manualReadiness?.blockingIssue == .minimized {
            capturePhase = .failed
            captureMessage =
                manualReadiness?.blockingMessage
                ?? "The Kindle window is minimized."
            return
        }
        // Priming AXMain is the one state change Start owns. Revalidate after
        // it so the readiness snapshot describes the window that will be used.
        do {
            try KindleLive.ensureMainWindow()
        } catch {
            capturePhase = .failed
            captureMessage = "\(error)"
            return
        }
        refreshManualReadiness()
        if let readiness = manualReadiness, !readiness.isReady {
            capturePhase = .failed
            captureMessage =
                readiness.blockingMessage
                ?? "The Kindle window is not ready for capture."
            return
        }
        let expected = preview.windowFrame
        let mark: PageMark
        do {
            mark = try preview.mark(for: crop)
        } catch {
            capturePhase = .failed
            captureMessage = "\(error)"
            return
        }
        beginCapture(
            pages: pages,
            manual: ManualCaptureConfiguration(
                crop: crop, expectedWindow: expected,
                expectedMark: mark,
                expectedPageNumber: preview.pageNumber))
    }

    /// Continue a failed Kindle capture from the last page it stored. The
    /// reader must show that page; the first snapshot verifies its pixels
    /// against the stored page before anything new is written.
    public func resumeCapture(_ capture: AbandonedCapture) {
        guard capturePhase != .running else { return }
        guard captureKind == .kindle else {
            capturePhase = .failed
            captureMessage = "Only Kindle captures can be resumed."
            return
        }
        guard let plan = CaptureCleanup.resumePlan(for: capture.directory)
        else {
            capturePhase = .failed
            captureMessage =
                "This folder has no reviewed crop or no captured pages; it "
                + "can be removed instead."
            return
        }
        refreshManualReadiness()
        if manualReadiness?.blockingIssue == .minimized {
            capturePhase = .failed
            captureMessage =
                manualReadiness?.blockingMessage
                ?? "The Kindle window is minimized."
            return
        }
        do {
            try KindleLive.ensureMainWindow()
        } catch {
            capturePhase = .failed
            captureMessage = "\(error)"
            return
        }
        refreshManualReadiness()
        if let readiness = manualReadiness, !readiness.isReady {
            capturePhase = .failed
            captureMessage =
                readiness.blockingMessage
                ?? "The Kindle window is not ready for capture."
            return
        }
        guard let live = try? KindleLive.currentPage(),
            let frame = live.windowFrame
        else {
            capturePhase = .failed
            captureMessage = "Could not read the Kindle window."
            return
        }
        let window = CGRect(
            x: frame.x, y: frame.y,
            width: frame.width, height: frame.height)
        beginCapture(
            pages: nil,
            manual: ManualCaptureConfiguration(
                crop: plan.crop, expectedWindow: window,
                expectedMark: plan.lastMark, isResume: true),
            output: plan.directory, resume: true)
    }

    private func beginCapture(
        pages: Int?, manual: ManualCaptureConfiguration?,
        output: URL? = nil, resume: Bool = false
    ) {
        guard let archive else { return }
        guard capturePhase != .running, !captureSession.isRunning else {
            return
        }
        refreshPermissions()
        guard !permissionsNeeded else {
            requestCaptureAccess(pages: pages)
            return
        }
        // Crash recovery opens Kindle's settings panel; a capture must not
        // start on top of it.
        guard !cleanRecoveryRunning else {
            capturePhase = .failed
            captureMessage =
                "Tsundoku is restoring Kindle's settings. Try again in a moment."
            return
        }
        let kind = captureKind
        let book = captureBook(for: kind)
        captureRouteKind = nil
        captureRouteWithoutBook = false
        let title = book?.title ?? livePage?.title ?? "Book"
        let folder = output ?? newCaptureFolder(for: title)
        if manual != nil {
            // The capture owns the reviewed crop and mark now; the full
            // window image is no longer needed.
            clearManualPreview()
        }
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
            cancellation: flag, manual: manual, resume: resume)
        captureSession.start(
            request,
            progress: { [weak self] progress in
                self?.captureProgress = progress.fraction
                self?.captureMessage = Self.captureMessage(progress)
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
                    var message = "\(error)"
                    // Captured pages are the expensive part of a run. Keep
                    // them and list the folder under failed captures; Clean
                    // Up is the explicit way to remove them. Only a shell
                    // with no pages is removed here.
                    let pages = CaptureCleanup.capturedPageCount(in: folder)
                    if pages == 0 {
                        try? FileManager.default.removeItem(at: folder)
                        self.captureDirectory = nil
                    } else {
                        self.captureDirectory = folder
                        message +=
                            " · \(pages) captured "
                            + (pages == 1 ? "page was" : "pages were")
                            + " kept in \(folder.path)."
                    }
                    self.captureMessage = message
                    self.refreshAbandonedCaptures()
                }
            })
    }

    nonisolated private static func measureKindleForA4() throws
        -> A4Measurement
    {
        let live = try KindleLive.currentPage()
        do {
            let geometry = try PageGeometry.measure(
                live, allowTextBoundsFallback: true)
            return A4Measurement(
                window: geometry.window, pageBox: geometry.pageBox,
                insets: geometry.calibration.insets)
        } catch {
            throw A4FitError.refused("\(error)")
        }
    }

    private static func captureMessage(_ progress: CaptureProgress) -> String {
        guard let remaining = progress.estimatedRemaining else {
            return progress.message
        }
        let seconds = max(0, Int(remaining.rounded()))
        let estimate: String
        if seconds < 60 {
            estimate = "\(seconds) s"
        } else {
            estimate = "\(seconds / 60) m \(seconds % 60) s"
        }
        return progress.message + " · about \(estimate) left"
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

    public var abandonedCaptureBytes: Int64 {
        abandonedCaptures.reduce(0) { $0 + $1.byteCount }
    }

    /// Find folders left by interrupted or failed captures. Published
    /// captures are excluded by `CaptureCleanup`.
    public func refreshAbandonedCaptures() {
        guard capturePhase != .running else { return }
        cleanupGeneration += 1
        let generation = cleanupGeneration
        let root = exportFolder
        Task {
            let found = await Task.detached {
                CaptureCleanup.abandoned(in: root)
            }.value
            guard generation == self.cleanupGeneration else { return }
            self.abandonedCaptures = found
        }
    }

    public func deleteCapture(_ capture: CaptureRecord) {
        guard capturePhase != .running, let archive else { return }
        let directory = URL(fileURLWithPath: capture.directory)
        guard directory.standardizedFileURL
            != captureDirectory?.standardizedFileURL
        else { return }
        Task {
            let result = await Task.detached {
                Result {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: directory.path) {
                        try manager.removeItem(at: directory)
                    }
                    try archive.deleteCapture(id: capture.id)
                }
            }.value
            switch result {
            case .success:
                ReadingContextResolver.invalidateCaptureIndex(
                    directory: capture.directory)
                self.reloadFromArchive()
                self.refreshAbandonedCaptures()
                self.post("Deleted capture “\(capture.title)”.")
            case .failure(let error):
                self.post("Could not delete the capture: \(error)", seconds: 12)
            }
        }
    }

    public func cleanUpAbandonedCaptures() {
        guard capturePhase != .running else { return }
        let candidates = abandonedCaptures
        guard !candidates.isEmpty else { return }
        Task {
            let result = await Task.detached {
                Result { try CaptureCleanup.remove(candidates) }
            }.value
            switch result {
            case .success:
                for capture in candidates {
                    ReadingContextResolver.invalidateCaptureIndex(
                        directory: capture.directory.path)
                }
                self.abandonedCaptures = []
                self.post(
                    "Removed \(candidates.count) failed capture"
                        + (candidates.count == 1 ? " folder." : " folders."))
            case .failure(let error):
                self.post(
                    "Could not remove all failed captures: \(error)",
                    seconds: 12)
                self.refreshAbandonedCaptures()
            }
        }
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
            UserDefaults.standard.set(
                url.path, forKey: Self.exportFolderDefaultsKey)
            refreshAbandonedCaptures()
        }
    }

    static let exportFolderDefaultsKey = "tsundoku.exportFolder"

    /// The folder the reader last chose, if it still exists; otherwise the
    /// default. A stored path that vanished must not become an unwritable
    /// output folder.
    static func storedExportFolder() -> URL {
        let fallback = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Tsundoku")
        guard
            let path = UserDefaults.standard.string(
                forKey: exportFolderDefaultsKey),
            !path.isEmpty
        else { return fallback }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return fallback }
        return URL(fileURLWithPath: path, isDirectory: true)
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

    /// Never reuse an existing folder: a leftover incomplete run must not
    /// receive the next run's pages.
    private func newCaptureFolder(for title: String) -> URL {
        let base = "\(slug(title))-\(timestamp())"
        var candidate = exportFolder.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = exportFolder.appendingPathComponent(
                "\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
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
