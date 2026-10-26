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
    /// What was actually sent. Nil in older records means the current page.
    public var scope: CompanionScope?

    public init(
        bookTitle: String = "",
        bookSource: BookSource? = nil,
        reader: ReaderKind? = nil,
        pageNumber: Int? = nil,
        pageCount: Int? = nil,
        chapter: String? = nil,
        selection: String? = nil,
        excerpt: String = "",
        scope: CompanionScope? = nil
    ) {
        self.bookTitle = bookTitle
        self.bookSource = bookSource
        self.reader = reader
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.chapter = chapter
        self.selection = selection
        self.excerpt = excerpt
        self.scope = scope
    }

    public static let empty = AIContext()

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
        let scopeLabel: String? =
            switch scope {
            case .currentChapter: "Chapter"
            case .wholeBook: "Whole book"
            default: nil
            }
        return [reader?.displayName, scopeLabel ?? pageLabel, chapter,
                selectionLabel].compactMap { $0 }
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

/// A turn to write with a new conversation, in one transaction.
public struct NewConversationTurn: Sendable {
    public let action: AIAction
    public let question: String
    public let answer: String
    public let provider: String
    public let prompt: String
    public let context: AIContext

    public init(
        action: AIAction, question: String, answer: String,
        provider: String, prompt: String, context: AIContext
    ) {
        self.action = action
        self.question = question
        self.answer = answer
        self.provider = provider
        self.prompt = prompt
        self.context = context
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
        TurnLabel.prompt(question: question, action: action)
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

}

/// Which conversations belong to a library book, and which are only
/// tentatively filed.
///
/// A chat keyed by the book's ASIN is filed. One keyed by the book's title,
/// by an older `kindle:` title key, or by a capture fingerprint of a capture
/// made from this book is the same book under weaker evidence: it is shown
/// under the book and marked unfiled until the reader files it.
public enum ConversationFiling {
    /// One spelling for comparison. Identifier keys are uppercase in the
    /// archive; title and fingerprint keys are lowercase. Without this, a
    /// conversation stored as `asset-2` is "filed" but not found by the key
    /// set, so it disappears from the Chats tab.
    public static func canonical(_ key: String) -> String {
        key.contains(":") ? key.lowercased() : key.uppercased()
    }

    public static func keys(
        for book: Book, captureFingerprints: [String]
    ) -> Set<String> {
        var keys: Set<String> = [canonical(book.asin)]
        let normalized = ConversationKey.normalize(book.title)
        if !normalized.isEmpty,
            !ReadingIdentityResolver.isPlaceholder(book.title)
        {
            keys.insert(canonical("books:\(normalized)"))
            keys.insert(canonical("kindle:\(normalized)"))
        }
        for fingerprint in captureFingerprints where !fingerprint.isEmpty {
            keys.insert(canonical("text:\(fingerprint)"))
        }
        return keys
    }

    public static func isFiled(
        _ conversation: Conversation, under book: Book
    ) -> Bool {
        canonical(conversation.bookKey) == canonical(book.asin)
    }

    public static func matches(
        _ conversation: Conversation, keys: Set<String>
    ) -> Bool {
        keys.contains(canonical(conversation.bookKey))
    }
}

/// Selects the AI cards that belong to a book and match a search.
///
/// A card follows its conversation's filing key; a title fallback keeps a card
/// visible while its conversation still sits under a weak title or fingerprint
/// key. An explicit book identifier is never overridden by a matching title:
/// two editions can share one title and must not exchange cards.
public enum AICardFilter {
    /// A key that names a title or a capture rather than a stable book ID.
    public static func isWeakKey(_ key: String) -> Bool {
        let lower = key.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        return lower.isEmpty || lower.hasPrefix("books:")
            || lower.hasPrefix("kindle:") || lower.hasPrefix("text:")
    }

    public static func cards(
        _ cards: [AICard], for book: Book?, search: String
    ) -> [AICard] {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return cards.filter { card in
            if let book {
                let asinKey = ConversationFiling.canonical(book.asin)
                let normalizedTitle = ConversationKey.normalize(
                    book.title)
                let hasTitle =
                    !normalizedTitle.isEmpty
                    && !ReadingIdentityResolver.isPlaceholder(book.title)
                let titleKey = ConversationFiling.canonical(
                    "books:\(normalizedTitle)")
                let kindleKey = ConversationFiling.canonical(
                    "kindle:\(normalizedTitle)")
                let key = ConversationFiling.canonical(card.bookKey)
                let weakKey = isWeakKey(card.bookKey)
                // A title is weak evidence; a known source that disagrees
                // with the book is stronger evidence against the match.
                let sourceMismatch =
                    card.bookSource != nil && card.bookSource != book.source
                let titleMatchesCard =
                    hasTitle && !sourceMismatch
                    && !ReadingIdentityResolver.isPlaceholder(card.bookTitle)
                    && ConversationKey.normalize(card.bookTitle)
                        == normalizedTitle
                let sameBook =
                    key == asinKey
                    || (hasTitle && !sourceMismatch
                        && (key == titleKey || key == kindleKey))
                    || (weakKey && titleMatchesCard)
                guard sameBook else { return false }
            }
            guard !search.isEmpty else { return true }
            return card.question.localizedStandardContains(search)
                || card.answer.localizedStandardContains(search)
                || card.bookTitle.localizedStandardContains(search)
        }
    }
}

/// Title normalization shared by identity and filing.
public enum ConversationKey {
    public static func normalize(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
