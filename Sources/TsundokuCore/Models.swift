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
    /// Kindle notes can store their body in `text`; Books uses `note`.
    public var personalNote: String? {
        Self.content(note) ?? (kind == .note ? Self.content(text) : nil)
    }
    public var passageText: String? {
        if kind == .note && Self.content(note) == nil { return nil }
        return Self.content(text)
    }
    public var hasContent: Bool { passageText != nil || personalNote != nil }

    private static func content(_ value: String?) -> String? {
        guard let value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }
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

public struct SavedAINote: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let asin: String?
    public let bookTitle: String
    public let bookSource: BookSource?
    public let position: String?
    public let kind: String
    public let prompt: String
    public let answer: String
    public let provider: String
    public let createdAt: Date
    /// The persisted turn this answer came from, when it is linked.
    public let turnID: Int64?
    /// Non-nil when this saved answer is also a card.
    public let cardedAt: Date?

    public var isCard: Bool { cardedAt != nil }
}

/// A saved AI answer shown as a card. Every field is read from the persisted
/// turn and its conversation, so a conversation re-key moves the card with it.
public struct AICard: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let turnID: Int64
    public let conversationID: Int64
    public let action: AIAction?
    public let question: String
    public let answer: String
    public let provider: String
    public let context: AIContext
    public let bookKey: String
    public let bookTitle: String
    public let bookSource: BookSource?
    public let createdAt: Date
    public let cardedAt: Date

    public init(
        id: Int64, turnID: Int64, conversationID: Int64,
        action: AIAction?, question: String, answer: String,
        provider: String, context: AIContext, bookKey: String,
        bookTitle: String, bookSource: BookSource?, createdAt: Date,
        cardedAt: Date
    ) {
        self.id = id
        self.turnID = turnID
        self.conversationID = conversationID
        self.action = action
        self.question = question
        self.answer = answer
        self.provider = provider
        self.context = context
        self.bookKey = bookKey
        self.bookTitle = bookTitle
        self.bookSource = bookSource
        self.createdAt = createdAt
        self.cardedAt = cardedAt
    }
}

public struct ReadingSession: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let asin: String
    public let bookTitle: String
    public let startedAt: Date
    public let endedAt: Date
    public let pageCount: Int

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var durationLabel: String {
        let minutes = max(0, Int(duration / 60))
        if minutes == 0 { return "Less than 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

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
    /// Which entry of `AIProviderProfile.known` the HTTP provider speaks: it
    /// fixes the auth header and the token-limit field, and supplies the base
    /// address when it is not `custom`. Older settings decode as `custom`.
    public var httpProfileID: String
    public var language: String
    public var sessionLogging: Bool
    /// The largest answer an HTTP model may return. The default is the
    /// common 64K output ceiling; a service with a different maximum can be
    /// tuned in Advanced. The app never imposes a short budget of its own.
    public var answerTokens: Int
    /// Turn Kindle's Popular Highlights display off for a capture and restore
    /// the setting afterwards. Default on.
    public var cleanPageDuringCapture: Bool
    /// Append a Page Index to captured PDFs, naming each page by its opening
    /// words. Off by default: it adds pages to every capture. The CSV page map
    /// is written either way.
    public var capturePageIndex: Bool
    /// The PDF page size. `a4` resizes the reader's window for the capture.
    public var capturePageSize: CapturePageSize
    /// Which reader a capture runs against. Default automatic.
    public var captureReader: CaptureReader
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
    /// Summarize older turns before a request when the composed prompt passes
    /// `compactThresholdCharacters`; manual Compact is always available.
    public var autoCompact: Bool
    /// Approximate prompt characters that trigger automatic compaction. This is
    /// a character estimate, not a model token count.
    public var compactThresholdCharacters: Int
    /// Delete conversations older than this many days. Zero means never.
    public var chatRetentionDays: Int
    /// The reader has reviewed retention once; launch maintenance only runs
    /// after this is true.
    public var chatRetentionConfirmed: Bool
    /// The retention period that was reviewed. A later period change requires
    /// a fresh review and blocks launch cleanup.
    public var chatRetentionConfirmedDays: Int

    public init(
        provider: AIProviderKind = .claudeCLI,
        model: String = "",
        endpoint: String = "http://127.0.0.1:11434/v1",
        httpProfileID: String = "custom",
        language: String = "",
        sessionLogging: Bool = false,
        answerTokens: Int = 65_536,
        cleanPageDuringCapture: Bool = true,
        capturePageIndex: Bool = false,
        capturePageSize: CapturePageSize = .asDisplayed,
        captureReader: CaptureReader = .automatic,
        captureFontSize: Int? = nil,
        booksFontSteps: Int = 0,
        captureCropTop: Int = 0,
        booksCropBottom: Int = Int(PageFooter.booksPageNumberInset),
        kindleCropBottom: Int = 0,
        includeCoverPage: Bool = true,
        writeSidecars: Bool = true,
        autoCompact: Bool = false,
        compactThresholdCharacters: Int = 800_000,
        chatRetentionDays: Int = 0,
        chatRetentionConfirmed: Bool = false,
        chatRetentionConfirmedDays: Int = 0
    ) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        // An id this build does not know would resolve to `custom` at request
        // time while the window kept the unknown id; normalise it once.
        self.httpProfileID = AIService.normalizedProfileID(httpProfileID)
        self.language = language
        self.sessionLogging = sessionLogging
        self.answerTokens = max(1, answerTokens)
        self.cleanPageDuringCapture = cleanPageDuringCapture
        self.capturePageIndex = capturePageIndex
        self.capturePageSize = capturePageSize
        self.captureReader = captureReader
        self.captureFontSize = captureFontSize
        self.booksFontSteps = booksFontSteps
        self.captureCropTop = captureCropTop
        self.booksCropBottom = booksCropBottom
        self.kindleCropBottom = kindleCropBottom
        self.includeCoverPage = includeCoverPage
        self.writeSidecars = writeSidecars
        self.autoCompact = autoCompact
        self.compactThresholdCharacters = max(1_000, compactThresholdCharacters)
        self.chatRetentionDays = max(0, chatRetentionDays)
        self.chatRetentionConfirmed = chatRetentionConfirmed
        self.chatRetentionConfirmedDays = max(0, chatRetentionConfirmedDays)
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, endpoint, language, sessionLogging
        case httpProfileID, answerTokens
        case cleanPageDuringCapture, capturePageIndex
        case capturePageSize, captureReader, captureFontSize, booksFontSteps
        case captureCropTop, booksCropBottom, kindleCropBottom
        case includeCoverPage, writeSidecars
        case autoCompact, compactThresholdCharacters
        case chatRetentionDays, chatRetentionConfirmed
        case chatRetentionConfirmedDays
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
            (try container.decodeIfPresent(String.self, forKey: .endpoint)
                ?? defaults.endpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        httpProfileID = AIService.migratedProfileID(
            try container.decodeIfPresent(
                String.self, forKey: .httpProfileID)
            ?? defaults.httpProfileID,
            endpoint: endpoint)
        language =
            try container.decodeIfPresent(String.self, forKey: .language)
            ?? defaults.language
        sessionLogging =
            try container.decodeIfPresent(
                Bool.self, forKey: .sessionLogging)
            ?? defaults.sessionLogging
        answerTokens = max(
            1,
            try container.decodeIfPresent(
                Int.self, forKey: .answerTokens)
                ?? defaults.answerTokens)
        cleanPageDuringCapture =
            try container.decodeIfPresent(
                Bool.self, forKey: .cleanPageDuringCapture)
            ?? defaults.cleanPageDuringCapture
        capturePageIndex =
            try container.decodeIfPresent(
                Bool.self, forKey: .capturePageIndex)
            ?? defaults.capturePageIndex
        capturePageSize =
            try container.decodeIfPresent(
                CapturePageSize.self, forKey: .capturePageSize)
            ?? defaults.capturePageSize
        captureReader =
            try container.decodeIfPresent(
                CaptureReader.self, forKey: .captureReader)
            ?? defaults.captureReader
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
        autoCompact =
            try container.decodeIfPresent(
                Bool.self, forKey: .autoCompact)
            ?? defaults.autoCompact
        compactThresholdCharacters = max(
            1_000,
            try container.decodeIfPresent(
                Int.self, forKey: .compactThresholdCharacters)
                ?? defaults.compactThresholdCharacters)
        chatRetentionDays = max(
            0,
            try container.decodeIfPresent(
                Int.self, forKey: .chatRetentionDays)
                ?? defaults.chatRetentionDays)
        chatRetentionConfirmed =
            try container.decodeIfPresent(
                Bool.self, forKey: .chatRetentionConfirmed)
            ?? defaults.chatRetentionConfirmed
        chatRetentionConfirmedDays = max(
            0,
            try container.decodeIfPresent(
                Int.self, forKey: .chatRetentionConfirmedDays)
                ?? defaults.chatRetentionConfirmedDays)
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
            let settings = try? JSONDecoder().decode(
                AISettings.self, from: data)
        else { return .defaults }
        // Decoding may have recognised a custom endpoint as a known service;
        // the key moves with it once.
        AIService.migrateLegacyKeyIfNeeded(
            profileID: settings.httpProfileID, endpoint: settings.endpoint)
        return settings
    }

    /// Persist a normalised copy: a pasted endpoint often carries a leading or
    /// trailing space, which the field hides and `URL(string:)` refuses.
    public func save() {
        var normalised = self
        normalised.endpoint = endpoint.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let data = try? JSONEncoder().encode(normalised) else { return }
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
