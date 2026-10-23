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
        case settings

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .library: "Books"
            case .highlights: "Annotations"
            case .history: "History"
            case .exports: "Exports"
            case .settings: "Settings"
            }
        }

        public var symbol: String {
            switch self {
            case .library: "books.vertical"
            case .highlights: "highlighter"
            case .history: "clock.arrow.circlepath"
            case .exports: "doc.richtext"
            case .settings: "gearshape"
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
    @Published public var selectedBookID: String?
    @Published public var search = ""
    @Published public var annotationFilter: AnnotationFilter = .mine
    @Published public var annotationSearch = ""
    @Published public var sourceFilter: SourceFilter = .all
    @Published public var annotationSourceFilter: SourceFilter = .all
    @Published public var annotationBookID: String?
    @Published public var bookWorkspaceID: String?
    @Published public var savedAINotes: [SavedAINote] = []
    @Published public var showSavedAINotes = false
    @Published public var sourceHealth: [BookSource: String] = [:]
    @Published public var sourceLastImport: [BookSource: Date] = [:]
    public var openSettingsWindow: (() -> Void)?
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
    @Published public var showPermissions = false
    @Published public private(set) var permissionAccessibility = AXIsProcessTrusted()
    @Published public private(set) var permissionScreen = CGPreflightScreenCaptureAccess()
    @Published public var livePage: LivePage?
    @Published public var liveError: String?
    @Published public var importError: String?
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
    @Published public var capturePageLimit: Int?
    @Published public var exportFolder: URL = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Tsundoku")
    @Published public var lastImport: Date?

    public let archive: Archive?
    private let sessionLogger: SessionLogger?
    private var activeCaptureFlag: CancellationFlag?
    private var liveTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var pendingBookID: String?
    private var hasImported = false
    private var pollGeneration = 0
    private var reloadGeneration = 0
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

    public init() {
        do {
            let arguments = CommandLine.arguments
            let archive: Archive
            if let index = arguments.firstIndex(of: "--archive-path"), arguments.indices.contains(index + 1) {
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
        if !CommandLine.arguments.contains("--shell-only") { recoverSettingsIfNeeded() }
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
    /// at login: the shell constructs this model lazily and calls `activate`
    /// only for a window the user asked for.
    public func activate(importLibrary shouldImport: Bool) {
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

    public var filteredAnnotations: [Annotation] {
        let query = annotationSearch.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return annotations.filter { annotation in
            if let provenance = annotationFilter.provenance,
                annotation.provenance != provenance
            {
                return false
            }
            if let source = sourceFilter.source,
                annotation.bookSource != source
            {
                return false
            }
            guard !query.isEmpty else { return true }
            return annotation.bookTitle.lowercased().contains(query)
                || annotation.displayText.lowercased().contains(query)
                || (annotation.note ?? "").lowercased().contains(query)
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

    public func refreshAINotes() {
        guard let archive else { return }
        Task {
            do { savedAINotes = try await Task.detached { try archive.aiNotes() }.value }
            catch { post("Could not read saved AI notes: \(error)", seconds: 12) }
        }
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

    public var currentBookTitle: String {
        if let book = selectedBook, book.source == .kindle,
            !book.title.isEmpty
        {
            return book.title
        }
        if let title = livePage?.title, !title.isEmpty {
            return title
        }
        return "the open book"
    }

    public var capturePageLimitLabel: String {
        capturePhase == .running ? "Capturing…" : "Ready"
    }

    // MARK: - Loading

    private func reloadFromArchive() {
        guard let archive else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        Task {
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
                if let target = requested
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
    }

    public func importLibrary(announce: Bool = true) {
        guard !CommandLine.arguments.contains("--no-import") else { return }
        guard !isImporting, let archive else { return }
        TsundokuDiagnostics.shared.event("library_import_started")
        isImporting = true
        status = "Reading local stores…"
        Task {
            var totalBooks = 0
            var totalAnnotations = 0
            var totalUser = 0
            var lastImportDate: Date?
            var importedSources: [String] = []
            var failures: [String] = []

            do {
                let paths = KindlePaths.standard()
                if paths.exists {
                    self.sourceHealth[.kindle] = "Importing…"
                    let data = try await Task.detached {
                        try KindleReader.readAll(paths)
                    }.value
                    let imported = try await Task.detached {
                        try archive.importAll(
                            books: data.books, annotations: data.annotations)
                    }.value
                    totalBooks += imported.books
                    totalAnnotations += imported.annotations
                    totalUser += imported.userAnnotations
                    lastImportDate = imported.importedAt
                    importedSources.append("Kindle")
                    self.sourceLastImport[.kindle] = imported.importedAt
                    try archive.setMeta("last_import_source_Kindle", ISO8601DateFormatter().string(from: imported.importedAt))
                    self.sourceHealth[.kindle] = "Imported \(imported.books.formatted()) books · \(TsundokuFormat.relative(imported.importedAt))"
                } else {
                    self.sourceHealth[.kindle] = "No local store found; showing any archived records."
                }
            } catch {
                failures.append("Kindle: \(error)")
                self.sourceHealth[.kindle] = "Import failed: \(error)"
            }

            let booksPaths = BooksPaths.standard()
            if booksPaths.exists {
                self.sourceHealth[.appleBooks] = "Importing…"
                do {
                    let data = try await Task.detached {
                        try BooksReader.readAll(booksPaths)
                    }.value
                    let imported = try await Task.detached {
                        try archive.importAll(
                            books: data.books,
                            annotations: data.annotations)
                    }.value
                    totalBooks += imported.books
                    totalAnnotations += imported.annotations
                    totalUser += imported.userAnnotations
                    lastImportDate = max(
                        lastImportDate ?? imported.importedAt,
                        imported.importedAt)
                    importedSources.append("Apple Books")
                    self.sourceLastImport[.appleBooks] = imported.importedAt
                    try archive.setMeta("last_import_source_Apple Books", ISO8601DateFormatter().string(from: imported.importedAt))
                    self.sourceHealth[.appleBooks] = "Imported \(imported.books.formatted()) books · \(TsundokuFormat.relative(imported.importedAt))"
                } catch {
                    failures.append("Apple Books: \(error)")
                    self.sourceHealth[.appleBooks] = "Import failed: \(error)"
                }
            } else {
                self.sourceHealth[.appleBooks] = "No local store found; showing any archived records."
            }

            self.isImporting = false
            self.lastImport = lastImportDate ?? self.lastImport
            self.importError =
                failures.isEmpty ? nil : failures.joined(separator: "\n")
            if totalBooks > 0 || totalAnnotations > 0 {
                self.status =
                    "\(totalBooks) books · \(totalAnnotations) annotations "
                    + "· \(totalUser) yours"
                let sourceLabel =
                    importedSources.isEmpty
                    ? "local stores"
                    : importedSources.joined(separator: " and ")
                self.post(
                    "Imported \(totalBooks.formatted()) books and "
                        + "\(totalAnnotations.formatted()) annotations "
                        + "from \(sourceLabel).",
                    enabled: announce)
                if !failures.isEmpty {
                    self.status = "Import partially completed. Some archived records may be out of date."
                }
            } else if !importedSources.isEmpty {
                self.status = "The local stores are empty."
                self.post(
                    "The local Kindle or Apple Books stores are empty.",
                    enabled: announce)
            } else if failures.isEmpty {
                self.status = "No local Kindle or Apple Books stores found."
                self.post(
                    "No local Kindle or Apple Books stores were found.",
                    enabled: announce)
            } else {
                self.status =
                    "Showing the last archive. Some local stores could not "
                    + "be read."
                self.post(
                    "Could not read "
                        + failures.joined(separator: "; ")
                        + ". The last archive is still shown.",
                    seconds: 12)
            }
            self.reloadFromArchive()
        }
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

    public func refreshPermissions() {
        if let permissions {
            permissions.refresh()
            permissionAccessibility = permissions.accessibility
            permissionScreen = permissions.screenRecording
            return
        }
        permissionAccessibility = AXIsProcessTrusted()
        permissionScreen = CGPreflightScreenCaptureAccess()
    }

    private func observePermissions() {
        permissionCancellables.removeAll()
        guard let permissions else { return }
        permissionAccessibility = permissions.accessibility
        permissionScreen = permissions.screenRecording
        permissions.$accessibility
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.permissionAccessibility = value
            }
            .store(in: &permissionCancellables)
        permissions.$screenRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.permissionScreen = value
            }
            .store(in: &permissionCancellables)
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
        Task {
            let sessions = try? await Task.detached(operation: {
                try archive.sessions()
            }).value
            if let sessions {
                self.sessions = sessions
            }
            let captures = try? await Task.detached(operation: {
                try archive.captures()
            }).value
            if let captures {
                self.captures = captures
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
        Task.detached { [weak self] in
            let availability: OriginalAvailability
            var note: String?
            switch book.source {
            case .kindle:
                availability = OriginalDetector.kindle(
                    asin: book.asin, paths: KindlePaths.standard())
            case .appleBooks:
                do {
                    if let asset = try BooksAssetReader().asset(
                        for: book.asin)
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

    /// The book a capture will use. The selected book wins; otherwise the
    /// source filter chooses the first recent ebook, then the first ebook.
    public func captureBook() -> Book? {
        if let selectedBook { return selectedBook }
        let filterSource = sourceFilter.source
        return books.first {
            $0.isEbook
                && (filterSource == nil || $0.source == filterSource)
                && $0.lastView != nil
        } ?? books.first {
            $0.isEbook
                && (filterSource == nil || $0.source == filterSource)
        }
    }

    /// Whether the next capture will use Apple Books. The controls and the
    /// capture itself read this same resolution.
    public var captureTargetIsBooks: Bool {
        captureBook()?.source == .appleBooks
    }

    public func startCapture(pages: Int?) {
        guard let archive else { return }
        guard capturePhase != .running else { return }
        refreshPermissions()
        guard !permissionsNeeded else {
            showPermissions = true
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
        let book = captureBook()
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
        activeCaptureFlag = flag
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
        Task {
            do {
                let result = try await Task.detached {
                    let engine = CaptureEngine(archive: archive)
                    let kind: ReaderKind =
                        book?.source == .appleBooks ? .appleBooks : .kindle
                    return try engine.capture(
                        book: book,
                        kind: kind,
                        pageLimit: pages,
                        output: folder,
                        progress: { progress in
                            Task { @MainActor [self] in
                                self.captureProgress = progress.fraction
                                self.captureMessage = progress.message
                            }
                        },
                        isCancelled: { flag.isSet },
                        cleanPage: kind == .kindle ? cleanPolicy : .asDisplayed,
                        pageSetup: kind == .kindle ? setup : booksSetup,
                        bundle: CaptureBundleRequest(
                            options: bundleOptions))
                }.value
                self.capturePhase = .finished
                self.captureProgress = 1
                self.captureMessage =
                    "\(result.pages) pages · \(result.title)"
                self.capturePDF = result.pdf
                self.captureCleanPage = result.cleanPage
                self.capturePageSetup = result.pageSetup
                self.captureDirectory = result.directory
                self.activeCaptureFlag = nil
                self.reloadFromArchive()
            } catch {
                self.capturePhase = .failed
                self.captureMessage = "\(error)"
                self.activeCaptureFlag = nil
            }
        }
    }

    public func cancelCapture() {
        activeCaptureFlag?.set()
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

@MainActor
public final class AppEnvironment {
    public static let shared = AppEnvironment()
    public let model = AppModel()
    private init() {}
}
