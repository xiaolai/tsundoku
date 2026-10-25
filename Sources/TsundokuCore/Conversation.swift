import Foundation

/// What a message was sent with: the book, the reader, the page, and the
/// selection when the reader exposes one.
///
/// Stored with every turn so a transcript read months later still says what
/// the answer was about, without pointing at a live page that has moved on.
public struct AIContext: Codable, Hashable, Sendable {
    public var bookTitle: String
    public var bookSource: BookSource?
    public var reader: ReaderKind?
    public var pageNumber: Int?
    public var pageCount: Int?
    /// The chapter the page belongs to, resolved from a captured book's text
    /// or a non-DRM EPUB's navigation.
    public var chapter: String?
    /// The reader's selected text, when the reader exposes it. Apple Books
    /// does; Kindle does not. The measured evidence is in the private
    /// companion-context record, dated 2026-10-26.
    public var selection: String?
    /// The page text the answer was based on, bounded so a long page does not
    /// duplicate the whole prompt in the archive.
    public var excerpt: String

    public init(
        bookTitle: String = "",
        bookSource: BookSource? = nil,
        reader: ReaderKind? = nil,
        pageNumber: Int? = nil,
        pageCount: Int? = nil,
        chapter: String? = nil,
        selection: String? = nil,
        excerpt: String = ""
    ) {
        self.bookTitle = bookTitle
        self.bookSource = bookSource
        self.reader = reader
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.chapter = chapter
        self.selection = selection
        self.excerpt = excerpt
    }

    public static let empty = AIContext()

    public var isEmpty: Bool {
        bookTitle.isEmpty && excerpt.isEmpty && selection == nil
    }

    public var bookLabel: String {
        bookTitle.isEmpty ? "No book" : bookTitle
    }

    public var pageLabel: String? {
        guard let pageNumber else { return nil }
        if let pageCount { return "Page \(pageNumber) of \(pageCount)" }
        return "Page \(pageNumber)"
    }

    public var selectionLabel: String? {
        guard let selection, !selection.isEmpty else { return nil }
        return "Selection · \(selection.count.formatted()) characters"
    }

    /// The chips a transcript shows under a message, in reading order.
    public var attachments: [String] {
        [reader?.displayName, pageLabel, chapter, selectionLabel]
            .compactMap { $0 }
    }
}

/// One conversation about one book. A book can have several; the newest is
/// resumed when the companion opens.
public struct Conversation: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let bookKey: String
    public let bookTitle: String
    public let bookSource: BookSource?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: Int64, bookKey: String, bookTitle: String,
        bookSource: BookSource?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.bookKey = bookKey
        self.bookTitle = bookTitle
        self.bookSource = bookSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One stored exchange.
public struct ConversationTurn: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let conversationID: Int64
    public let action: AIAction
    public let question: String
    public let answer: String
    public let provider: String
    public let prompt: String
    public let context: AIContext
    public let createdAt: Date

    public init(
        id: Int64, conversationID: Int64, action: AIAction, question: String,
        answer: String, provider: String, prompt: String, context: AIContext,
        createdAt: Date
    ) {
        self.id = id
        self.conversationID = conversationID
        self.action = action
        self.question = question
        self.answer = answer
        self.provider = provider
        self.prompt = prompt
        self.context = context
        self.createdAt = createdAt
    }

    /// What the reader asked, or the action's name when no question was typed.
    public var promptLabel: String {
        question.isEmpty ? action.displayName : question
    }
}

/// A conversation plus what a list row needs, without loading every answer
/// of a long thread.
public struct ConversationSummary: Identifiable, Hashable, Sendable {
    public let conversation: Conversation
    public let turnCount: Int
    public let firstQuestion: String
    public let lastAnswer: String?

    public var id: Int64 { conversation.id }

    public init(
        conversation: Conversation, turnCount: Int, firstQuestion: String,
        lastAnswer: String?
    ) {
        self.conversation = conversation
        self.turnCount = turnCount
        self.firstQuestion = firstQuestion
        self.lastAnswer = lastAnswer
    }

    public var preview: String {
        let text = lastAnswer ?? firstQuestion
        return String(text.prefix(160))
    }
}

/// Which conversations belong to a library book, and which are only
/// tentatively filed.
///
/// A chat keyed by the book's ASIN is filed. One keyed by the book's title,
/// by an older `kindle:` title key, or by a capture fingerprint of a capture
/// made from this book is the same book under weaker evidence: it is shown
/// under the book and marked unfiled until the reader files it.
public enum ConversationFiling {
    public static func keys(
        for book: Book, captureFingerprints: [String]
    ) -> Set<String> {
        var keys: Set<String> = [book.asin]
        let normalized = ConversationKey.normalize(book.title)
        if !normalized.isEmpty,
            !ReadingIdentityResolver.isPlaceholder(book.title)
        {
            keys.insert("books:\(normalized)")
            keys.insert("kindle:\(normalized)")
        }
        for fingerprint in captureFingerprints where !fingerprint.isEmpty {
            keys.insert("text:\(fingerprint)")
        }
        return keys
    }

    public static func isFiled(
        _ conversation: Conversation, under book: Book
    ) -> Bool {
        conversation.bookKey.caseInsensitiveCompare(book.asin)
            == .orderedSame
    }
}

/// The key a conversation is filed under.
///
/// A book matched in the archive uses its ASIN (the library can then find its
/// chats). A live page the archive does not know still gets a stable key from
/// its reader and title, so its history is kept and shown in the companion,
/// even though no library row can list it.
public enum ConversationKey {
    public static func make(
        book: Book?, reader: ReaderKind?, title: String,
        identifier: String? = nil
    ) -> String {
        if let book, !book.asin.isEmpty { return book.asin }
        // Kindle's last-opened ASIN identifies the book even before the
        // library has imported it; the key then starts matching the book the
        // moment it is imported.
        if let identifier, !identifier.isEmpty { return identifier }
        let source = reader == .appleBooks ? "books" : "kindle"
        let normalized = normalize(title)
        return "\(source):\(normalized.isEmpty ? "untitled" : normalized)"
    }

    public static func normalize(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
