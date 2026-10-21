import AppKit
import ApplicationServices
import Foundation
import KindlingCore
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
    @Published public var permissionAccessibility = AXIsProcessTrusted()
    @Published public var permissionScreen = CGPreflightScreenCaptureAccess()
    @Published public var livePage: LivePage?
    @Published public var liveError: String?
    @Published public var trackedBookID: String?
    @Published public var capturePhase: CapturePhase = .idle
    @Published public var captureProgress: Double = 0
    @Published public var captureMessage = ""
    @Published public var capturePDF: URL?
    @Published public var captureDirectory: URL?
    @Published public var exportFolder: URL = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Kindling")
    @Published public var lastImport: Date?

    public let archive: Archive?
    private let sessionLogger: SessionLogger?
    private let captureFlag = CancellationFlag()
    private var liveTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var pendingBookID: String?

    public init() {
        do {
            let archive = try Archive.standard()
            self.archive = archive
            self.sessionLogger = SessionLogger(archive: archive)
            reloadFromArchive()
            importLibrary(announce: false)
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
        if let index = CommandLine.arguments.firstIndex(of: "--language"),
            CommandLine.arguments.indices.contains(index + 1)
        {
            settings.language = CommandLine.arguments[index + 1]
        }
        startLivePolling()
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
            guard !query.isEmpty else { return true }
            return annotation.bookTitle.lowercased().contains(query)
                || annotation.displayText.lowercased().contains(query)
                || (annotation.note ?? "").lowercased().contains(query)
        }
    }

    public var selectedBookAnnotations: [Annotation] {
        guard let selectedBookID else { return [] }
        return annotations.filter { $0.asin == selectedBookID }
    }

    public var ebookCount: Int {
        books.filter(\.isEbook).count
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
        if let title = selectedBook?.title, !title.isEmpty {
            return title
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
                self.books = books
                self.bookTitles = Dictionary(
                    books.map { ($0.asin, $0.title) },
                    uniquingKeysWith: { first, _ in first })
                self.annotations = annotations
                self.sessions = sessions
                self.captures = captures
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
                self.status = "Archive read failed: \(error)"
                self.post("Archive read failed: \(error)", seconds: 10)
            }
        }
    }

    public func importLibrary(announce: Bool = true) {
        guard !isImporting, let archive else { return }
        isImporting = true
        status = "Reading Kindle's local stores…"
        Task {
            do {
                let paths = KindlePaths.standard()
                let data = try await Task.detached {
                    try KindleReader.readAll(paths)
                }.value
                let imported = try await Task.detached {
                    try archive.importAll(
                        books: data.books, annotations: data.annotations)
                }.value
                self.lastImport = imported.importedAt
                self.status =
                    "\(imported.books) books · \(imported.annotations) "
                    + "annotations · \(imported.userAnnotations) yours"
                self.post(
                    "Imported \(imported.books.formatted()) books and "
                        + "\(imported.annotations.formatted()) annotations.",
                    enabled: announce)
                self.isImporting = false
                self.reloadFromArchive()
            } catch {
                self.isImporting = false
                self.status =
                    "Showing the last archive. Live import was blocked by "
                    + "macOS; grant Files & Folders or Full Disk Access."
                self.liveError = "\(error)"
                self.post(
                    "Live import failed. The last archive is still shown.")
            }
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
        permissionAccessibility = AXIsProcessTrusted()
        permissionScreen = CGPreflightScreenCaptureAccess()
    }

    public func refreshActivity() {
        guard let archive else { return }
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

    public func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    public func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openScreenSettings()
    }

    public func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    public func openScreenSettings() {
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
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollLive()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollLive() async {
        guard KindleLive.isRunning(), KindleLive.isTrusted() else {
            livePage = nil
            return
        }
        do {
            let page = try await Task.detached {
                try KindleLive.currentPage()
            }.value
            livePage = page
            liveError = nil
        } catch {
            liveError = "\(error)"
        }
    }

    public func showAIPanel() {
        if capturePhase == .running {
            status =
                "Kindle is busy capturing. The reading panel waits until the "
                + "capture finishes."
            return
        }
        AIPanelController.shared.show(app: self)
    }

    // MARK: - Tracking

    public func toggleTracking() {
        if trackedBookID != nil {
            trackedBookID = nil
            sessionLogger?.stop()
            return
        }
        let asin: String?
        if let book =
            selectedBook
            ?? books.first(where: { $0.isEbook && $0.lastView != nil })
        {
            asin = book.asin
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
        }
    }

    // MARK: - Capture

    public func startCapture(pages: Int?) {
        guard let archive else { return }
        let book = selectedBook
            ?? books.first(where: { $0.isEbook && $0.lastView != nil })
        let title = book?.title ?? livePage?.title ?? "Kindle book"
        let folder = exportFolder.appendingPathComponent(
            "\(slug(title))-\(timestamp())")
        captureFlag.reset()
        capturePhase = .running
        captureProgress = 0
        captureMessage = "Starting…"
        capturePDF = nil
        captureDirectory = folder
        let flag = captureFlag
        Task {
            do {
                let result = try await Task.detached {
                    let engine = CaptureEngine(archive: archive)
                    return try engine.capture(
                        book: book,
                        pageLimit: pages,
                        output: folder,
                        progress: { progress in
                            Task { @MainActor [self] in
                                self.captureProgress = progress.fraction
                                self.captureMessage = progress.message
                            }
                        },
                        isCancelled: { flag.isSet })
                }.value
                self.capturePhase = .finished
                self.captureProgress = 1
                self.captureMessage =
                    "\(result.pages) pages · \(result.title)"
                self.capturePDF = result.pdf
                self.captureDirectory = result.directory
                self.reloadFromArchive()
            } catch {
                self.capturePhase = .failed
                self.captureMessage = "\(error)"
            }
        }
    }

    public func cancelCapture() {
        captureFlag.set()
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
