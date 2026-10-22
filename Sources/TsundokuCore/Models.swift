import Foundation

// MARK: - Library

public enum BookSource: String, Codable, CaseIterable, Sendable {
    case kindle = "Kindle"
    case appleBooks = "Apple Books"

    public var displayName: String { rawValue }
}

public struct Book: Identifiable, Hashable, Sendable {
    public let asin: String
    public var title: String
    public var author: String
    public var bookType: Int
    public var readState: Int
    public var lastView: Date?
    public var currentPosition: String?
    public var maxPosition: String?
    public var downloaded: Bool
    public var annotationCount: Int
    public var userAnnotationCount: Int
    public var source: BookSource
    public var progress: Double?

    public var id: String { asin }
    public var isRead: Bool { readState == 1 }
    public var isFixedLayout: Bool { bookType == 19 }
    public var isEbook: Bool { bookType == 10 || bookType == 19 }
    public var spineIndex: Int {
        asin.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    }

    public init(
        asin: String,
        title: String,
        author: String,
        bookType: Int,
        readState: Int,
        lastView: Date? = nil,
        currentPosition: String? = nil,
        maxPosition: String? = nil,
        downloaded: Bool = false,
        annotationCount: Int = 0,
        userAnnotationCount: Int = 0,
        source: BookSource = .kindle,
        progress: Double? = nil
    ) {
        self.asin = asin
        self.title = title
        self.author = author
        self.bookType = bookType
        self.readState = readState
        self.lastView = lastView
        self.currentPosition = currentPosition
        self.maxPosition = maxPosition
        self.downloaded = downloaded
        self.annotationCount = annotationCount
        self.userAnnotationCount = userAnnotationCount
        self.source = source
        self.progress = progress
    }
}

// MARK: - Annotations

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case highlight
    case note
    case bookmark
    case position
    case popularHighlight

    public var displayName: String {
        switch self {
        case .highlight: "Highlight"
        case .note: "Note"
        case .bookmark: "Bookmark"
        case .position: "Reading position"
        case .popularHighlight: "Popular highlight"
        }
    }

    public var symbolName: String {
        switch self {
        case .highlight: "highlighter"
        case .note: "note.text"
        case .bookmark: "bookmark.fill"
        case .position: "book.pages"
        case .popularHighlight: "person.2.fill"
        }
    }
}

public enum AnnotationProvenance: String, Codable, CaseIterable, Sendable {
    case user
    case amazon
    case system

    public var displayName: String {
        switch self {
        case .user: "Mine"
        case .amazon: "Popular"
        case .system: "System"
        }
    }
}

public struct Annotation: Identifiable, Hashable, Sendable {
    public let id: String
    public let asin: String
    public var bookTitle: String
    public var kind: AnnotationKind
    public var provenance: AnnotationProvenance
    public var start: String?
    public var end: String?
    public var text: String?
    public var note: String?
    public var color: String?
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var sources: [String]
    public var bookSource: BookSource

    public var isResolved: Bool { !(text ?? "").isEmpty }
    public var displayText: String {
        if let text, !text.isEmpty { return text }
        if let note, !note.isEmpty { return note }
        return "Text unavailable in the local store"
    }

    public init(
        id: String,
        asin: String,
        bookTitle: String = "",
        kind: AnnotationKind,
        provenance: AnnotationProvenance,
        start: String? = nil,
        end: String? = nil,
        text: String? = nil,
        note: String? = nil,
        color: String? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        sources: [String] = [],
        bookSource: BookSource = .kindle
    ) {
        self.id = id
        self.asin = asin
        self.bookTitle = bookTitle
        self.kind = kind
        self.provenance = provenance
        self.start = start
        self.end = end
        self.text = text
        self.note = note
        self.color = color
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sources = sources
        self.bookSource = bookSource
    }
}

// MARK: - History

public struct ReadingSession: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let asin: String
    public let bookTitle: String
    public let startedAt: Date
    public let endedAt: Date
    public let pageCount: Int

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    public init(
        id: Int64,
        asin: String,
        bookTitle: String,
        startedAt: Date,
        endedAt: Date,
        pageCount: Int
    ) {
        self.id = id
        self.asin = asin
        self.bookTitle = bookTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pageCount = pageCount
    }
}

public struct PageObservation: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let sessionID: Int64
    public let asin: String
    public let text: String
    public let observedAt: Date

    public init(
        id: Int64, sessionID: Int64, asin: String, text: String,
        observedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.asin = asin
        self.text = text
        self.observedAt = observedAt
    }
}

public struct CaptureRecord: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let asin: String
    public let title: String
    public let directory: String
    public let pageCount: Int
    public let pdfPath: String?
    public let createdAt: Date
    public let state: String
    public let source: String
    public let identityConfidence: String?
    public let termination: String?
    public let warnings: [String]

    public init(
        id: Int64, asin: String, title: String, directory: String,
        pageCount: Int, pdfPath: String?, createdAt: Date, state: String,
        source: String = "kindle", identityConfidence: String? = nil,
        termination: String? = nil, warnings: [String] = []
    ) {
        self.id = id
        self.asin = asin
        self.title = title
        self.directory = directory
        self.pageCount = pageCount
        self.pdfPath = pdfPath
        self.createdAt = createdAt
        self.state = state
        self.source = source
        self.identityConfidence = identityConfidence
        self.termination = termination
        self.warnings = warnings
    }
}

// MARK: - Import

public struct ImportResult: Sendable {
    public let books: Int
    public let annotations: Int
    public let userAnnotations: Int
    public let importedAt: Date

    public init(
        books: Int, annotations: Int, userAnnotations: Int, importedAt: Date
    ) {
        self.books = books
        self.annotations = annotations
        self.userAnnotations = userAnnotations
        self.importedAt = importedAt
    }
}

// MARK: - AI settings

public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case claudeCLI
    case codexCLI
    case http
    case appleOnDevice

    public var displayName: String {
        switch self {
        case .claudeCLI: "Claude CLI"
        case .codexCLI: "Codex CLI"
        case .http: "OpenAI-compatible HTTP"
        case .appleOnDevice: "Apple on-device"
        }
    }
}

public struct AISettings: Codable, Sendable, Equatable {
    public var provider: AIProviderKind
    public var model: String
    public var endpoint: String
    public var language: String
    public var sessionLogging: Bool
    /// Turn Kindle's Popular Highlights display off for a capture and restore
    /// the setting afterwards. Default on.
    public var cleanPageDuringCapture: Bool
    /// The PDF page size. `a4` resizes the reader's window for the capture.
    public var capturePageSize: CapturePageSize
    /// The Aa font size for the capture; nil keeps the reader's setting.
    public var captureFontSize: Int?
    /// Apple Books' relative text-size steps for the capture; 0 keeps it.
    public var booksFontSteps: Int
    /// Extra crop from the top of every captured page, in points.
    public var captureCropTop: Int
    /// Bottom crop for Apple Books, in points; 0 keeps printed page numbers.
    public var booksCropBottom: Int
    /// Bottom crop for Kindle; 0 detects a page number automatically.
    public var kindleCropBottom: Int
    /// Draw a vector cover page before the captured pages. Default on.
    public var includeCoverPage: Bool
    /// Write `metadata.json`, `text.md` and the per-page text files. Default on.
    public var writeSidecars: Bool

    public init(
        provider: AIProviderKind = .claudeCLI,
        model: String = "",
        endpoint: String = "http://127.0.0.1:11434/v1",
        language: String = "Simplified Chinese",
        sessionLogging: Bool = false,
        cleanPageDuringCapture: Bool = true,
        capturePageSize: CapturePageSize = .asDisplayed,
        captureFontSize: Int? = nil,
        booksFontSteps: Int = 0,
        captureCropTop: Int = 0,
        booksCropBottom: Int = 54,
        kindleCropBottom: Int = 0,
        includeCoverPage: Bool = true,
        writeSidecars: Bool = true
    ) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.language = language
        self.sessionLogging = sessionLogging
        self.cleanPageDuringCapture = cleanPageDuringCapture
        self.capturePageSize = capturePageSize
        self.captureFontSize = captureFontSize
        self.booksFontSteps = booksFontSteps
        self.captureCropTop = captureCropTop
        self.booksCropBottom = booksCropBottom
        self.kindleCropBottom = kindleCropBottom
        self.includeCoverPage = includeCoverPage
        self.writeSidecars = writeSidecars
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, endpoint, language, sessionLogging
        case cleanPageDuringCapture
        case capturePageSize, captureFontSize, booksFontSteps
        case captureCropTop, booksCropBottom, kindleCropBottom
        case includeCoverPage, writeSidecars
    }

    /// Decodes every missing field to its default, so a settings blob written
    /// before a field existed does not reset the whole pane.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AISettings()
        provider =
            try container.decodeIfPresent(
                AIProviderKind.self, forKey: .provider)
            ?? defaults.provider
        model =
            try container.decodeIfPresent(String.self, forKey: .model)
            ?? defaults.model
        endpoint =
            try container.decodeIfPresent(String.self, forKey: .endpoint)
            ?? defaults.endpoint
        language =
            try container.decodeIfPresent(String.self, forKey: .language)
            ?? defaults.language
        sessionLogging =
            try container.decodeIfPresent(
                Bool.self, forKey: .sessionLogging)
            ?? defaults.sessionLogging
        cleanPageDuringCapture =
            try container.decodeIfPresent(
                Bool.self, forKey: .cleanPageDuringCapture)
            ?? defaults.cleanPageDuringCapture
        capturePageSize =
            try container.decodeIfPresent(
                CapturePageSize.self, forKey: .capturePageSize)
            ?? defaults.capturePageSize
        captureFontSize =
            try container.decodeIfPresent(
                Int.self, forKey: .captureFontSize)
        booksFontSteps =
            try container.decodeIfPresent(
                Int.self, forKey: .booksFontSteps)
            ?? defaults.booksFontSteps
        captureCropTop =
            try container.decodeIfPresent(
                Int.self, forKey: .captureCropTop)
            ?? defaults.captureCropTop
        booksCropBottom =
            try container.decodeIfPresent(
                Int.self, forKey: .booksCropBottom)
            ?? defaults.booksCropBottom
        kindleCropBottom =
            try container.decodeIfPresent(
                Int.self, forKey: .kindleCropBottom)
            ?? defaults.kindleCropBottom
        includeCoverPage =
            try container.decodeIfPresent(
                Bool.self, forKey: .includeCoverPage)
            ?? defaults.includeCoverPage
        writeSidecars =
            try container.decodeIfPresent(
                Bool.self, forKey: .writeSidecars)
            ?? defaults.writeSidecars
    }

    /// The bundle options for a capture started from these settings.
    public var captureBundleOptions: CaptureBundleOptions {
        CaptureBundleOptions(
            includeCoverPage: includeCoverPage,
            writeSidecars: writeSidecars,
            copyOriginal: false,
            pageSize: capturePageSize.points)
    }

    public static let defaults = AISettings()

    public static func load() -> AISettings {
        guard let data = UserDefaults.standard.data(forKey: "ai.settings"),
            let settings = try? JSONDecoder().decode(AISettings.self, from: data)
        else { return .defaults }
        return settings
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "ai.settings")
    }
}

// MARK: - Identity

public enum BookIdentity {
    /// Normalises the four forms Kindle uses into a bare identifier.
    public static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("amzn://") {
            value = String(value.dropFirst("amzn://".count))
            if let slash = value.firstIndex(of: "/") {
                value = String(value[..<slash])
            }
        }
        if value.hasPrefix("Cell(asin:"), value.hasSuffix(")") {
            value = String(
                value.dropFirst("Cell(asin:".count).dropLast())
        }
        if value.hasPrefix("A:"), value.hasSuffix("-0") {
            value = String(value.dropFirst(2).dropLast(2))
        }
        return value
    }
}

public enum DateParsing {
    public static func coreData(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    public static func epoch(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        let seconds = value > 1_000_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}
