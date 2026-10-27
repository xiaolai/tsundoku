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

    private enum CodingKeys: String, CodingKey {
        case bookTitle, bookSource, reader, pageNumber, pageCount
        case chapter, selection, excerpt, scope
    }

    /// Old context blobs may omit fields added later. Missing fields become
    /// empty; a malformed value still throws so the archive layer can report
    /// it instead of silently dropping source information.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookTitle =
            try container.decodeIfPresent(String.self, forKey: .bookTitle)
            ?? ""
        bookSource =
            try container.decodeIfPresent(
                BookSource.self, forKey: .bookSource)
        reader =
            try container.decodeIfPresent(
                ReaderKind.self, forKey: .reader)
        pageNumber =
            try container.decodeIfPresent(Int.self, forKey: .pageNumber)
        pageCount =
            try container.decodeIfPresent(Int.self, forKey: .pageCount)
        chapter =
            try container.decodeIfPresent(String.self, forKey: .chapter)
        selection =
            try container.decodeIfPresent(String.self, forKey: .selection)
        excerpt =
            try container.decodeIfPresent(String.self, forKey: .excerpt)
            ?? ""
        scope =
            try container.decodeIfPresent(
                CompanionScope.self, forKey: .scope)
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
    /// A reader-chosen name. Empty or nil falls back to the first question.
    public let title: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: Int64, bookKey: String, bookTitle: String,
        bookSource: BookSource?, title: String? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.bookKey = bookKey
        self.bookTitle = bookTitle
        self.bookSource = bookSource
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        let trimmed = title?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? bookTitle : trimmed
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
    /// Digest and original length of the full prompt. New rows store the
    /// prompt compressed; legacy rows may have only the text column.
    public let promptSHA256: String?
    public let promptCharacters: Int?

    public init(
        id: Int64, conversationID: Int64, action: AIAction, question: String,
        answer: String, provider: String, prompt: String, context: AIContext,
        createdAt: Date, promptSHA256: String? = nil,
        promptCharacters: Int? = nil
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
        self.promptSHA256 = promptSHA256
        self.promptCharacters = promptCharacters
    }

    /// What the reader asked, or the action's name when no question was typed.
    public var promptLabel: String {
        TurnLabel.prompt(question: question, action: action)
    }

    /// The exchange shape a request carries, with the same topic and source
    /// rules as a live turn.
    public var exchange: AIExchange {
        let topic = context.attachments.joined(separator: " · ")
        let selection = context.selection?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceText = selection.isEmpty ? context.excerpt : selection
        return AIExchange(
            question: promptLabel, answer: answer,
            topic: topic.isEmpty ? nil : topic,
            action: action.displayName,
            excerpt: sourceText.isEmpty ? nil : sourceText)
    }
}

/// A conversation plus what a list row needs, without loading every answer
/// of a long thread.
public struct ConversationSummary: Identifiable, Hashable, Sendable {
    public let conversation: Conversation
    public let turnCount: Int
    public let firstQuestion: String
    public let lastAnswer: String?
    /// True when a compaction exists; the list can mark a long chat without
    /// loading the summary text.
    public let isCompacted: Bool

    public var id: Int64 { conversation.id }

    public var displayTitle: String {
        let title = conversation.title?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? firstQuestion : title
    }

    public init(
        conversation: Conversation, turnCount: Int, firstQuestion: String,
        lastAnswer: String?, isCompacted: Bool = false
    ) {
        self.conversation = conversation
        self.turnCount = turnCount
        self.firstQuestion = firstQuestion
        self.lastAnswer = lastAnswer
        self.isCompacted = isCompacted
    }

}

/// A stored summary of earlier turns. The original turns remain in the
/// transcript; this is only the projection sent to the model.
public struct ConversationCompaction: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let conversationID: Int64
    public let throughTurnID: Int64
    public let summary: String
    public let provider: String
    public let model: String?
    public let createdAt: Date

    public init(
        id: Int64, conversationID: Int64, throughTurnID: Int64,
        summary: String, provider: String, model: String?,
        createdAt: Date
    ) {
        self.id = id
        self.conversationID = conversationID
        self.throughTurnID = throughTurnID
        self.summary = summary
        self.provider = provider
        self.model = model
        self.createdAt = createdAt
    }
}

/// A guard for a compaction write. `matching` makes a removal or a second
/// summary that lands while a provider call is in flight fail instead of
/// resurrecting a summary the reader removed.
public enum CompactionPrecondition: Sendable, Equatable {
    case any
    case none
    case matching(Int64)
}

/// What a delete will remove, shown before the transaction.
public struct ConversationDeletionImpact: Sendable, Equatable {
    public var conversations: Int
    public var turns: Int
    public var compactions: Int
    public var notes: Int
    public var cards: Int

    public init(
        conversations: Int = 0, turns: Int = 0, compactions: Int = 0,
        notes: Int = 0, cards: Int = 0
    ) {
        self.conversations = conversations
        self.turns = turns
        self.compactions = compactions
        self.notes = notes
        self.cards = cards
    }

    public static func + (
        left: ConversationDeletionImpact, right: ConversationDeletionImpact
    ) -> ConversationDeletionImpact {
        ConversationDeletionImpact(
            conversations: left.conversations + right.conversations,
            turns: left.turns + right.turns,
            compactions: left.compactions + right.compactions,
            notes: left.notes + right.notes,
            cards: left.cards + right.cards)
    }
}

/// The two supported delete policies. Saved notes survive by default; cards
/// always disappear because their turn no longer exists.
public enum ConversationDeletionPolicy: String, Sendable, CaseIterable {
    case keepSavedNotes
    case deleteSavedNotes
}

/// Small storage summary for Settings. No note or prompt text is returned.
public struct ConversationStorage: Sendable, Equatable {
    public let conversations: Int
    public let turns: Int
    public let compactions: Int

    public init(conversations: Int, turns: Int, compactions: Int) {
        self.conversations = conversations
        self.turns = turns
        self.compactions = compactions
    }
}

/// One stored transcript plus its card links and latest summary, read under
/// the archive's serial queue so a concurrent append or compaction cannot
/// produce a mixed snapshot.
public struct ConversationSnapshot: Sendable {
    public let turns: [ConversationTurn]
    public let cardIDs: Set<Int64>
    public let compaction: ConversationCompaction?

    public init(
        turns: [ConversationTurn], cardIDs: Set<Int64>,
        compaction: ConversationCompaction?
    ) {
        self.turns = turns
        self.cardIDs = cardIDs
        self.compaction = compaction
    }
}

/// The newest conversation for a book, its list, and one atomic transcript
/// snapshot.
public struct ConversationHistorySnapshot: Sendable {
    public let latest: Conversation?
    public let summaries: [ConversationSummary]
    public let transcript: ConversationSnapshot

    public init(
        latest: Conversation?, summaries: [ConversationSummary],
        transcript: ConversationSnapshot
    ) {
        self.latest = latest
        self.summaries = summaries
        self.transcript = transcript
    }
}

/// The transcript projection used for one request.
public struct ConversationProjection: Sendable, Equatable {
    public let summary: String?
    public let history: [AIExchange]
    public let throughTurnID: Int64?

    public init(
        summary: String? = nil, history: [AIExchange] = [],
        throughTurnID: Int64? = nil
    ) {
        self.summary = summary
        self.history = history
        self.throughTurnID = throughTurnID
    }

    public static func full(_ history: [AIExchange]) -> ConversationProjection {
        ConversationProjection(history: history)
    }

    /// The prompt view of a stored transcript. Covered turns stay in the
    /// archive and in the reader's transcript; only this projection drops
    /// them.
    public static func stored(
        turns: [ConversationTurn], compaction: ConversationCompaction?
    ) -> ConversationProjection {
        guard let compaction else {
            return ConversationProjection(history: turns.map(\.exchange))
        }
        return ConversationProjection(
            summary: compaction.summary,
            history: turns.filter {
                $0.id > compaction.throughTurnID
            }.map(\.exchange),
            throughTurnID: compaction.throughTurnID)
    }
}

/// The identity a chat had when it was reviewed for filing. A migration
/// refuses when another window changed it first, rather than moving a chat
/// that no longer belongs where the review said it did.
public struct ConversationFilingPrecondition: Sendable, Equatable {
    public let bookKey: String
    public let bookSource: BookSource?

    public init(bookKey: String, bookSource: BookSource?) {
        self.bookKey = bookKey
        self.bookSource = bookSource
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
        guard canonical(conversation.bookKey) == canonical(book.asin)
        else { return false }
        return conversation.bookSource == nil
            || conversation.bookSource == book.source
    }

    /// A title key is weak evidence; a known source that disagrees with the
    /// book is stronger evidence against the match.
    public static func matches(
        _ conversation: Conversation, keys: Set<String>,
        source: BookSource? = nil
    ) -> Bool {
        guard keys.contains(canonical(conversation.bookKey)) else {
            return false
        }
        if let source, let stored = conversation.bookSource, stored != source {
            return false
        }
        return true
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
                    !sourceMismatch
                    && (key == asinKey
                        || (hasTitle
                            && (key == titleKey || key == kindleKey))
                        || (weakKey && titleMatchesCard))
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
