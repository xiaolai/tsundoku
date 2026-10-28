import Foundation
import Testing

@testable import TsundokuCore

@Suite("AI cards")
struct AICardTests {
    private func temporaryArchive() throws -> (Archive, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        return (archive, directory)
    }

    private func conversation(
        _ archive: Archive, key: String = "B1"
    ) throws -> Conversation {
        try archive.createConversation(
            bookKey: key, bookTitle: "A Book", bookSource: .kindle)
    }

    @discardableResult
    private func addTurn(
        _ archive: Archive, conversationID: Int64, question: String,
        answer: String, page: Int = 12
    ) throws -> ConversationTurn {
        try archive.appendConversationTurn(
            conversationID: conversationID, action: .ask,
            question: question, answer: answer, provider: "p",
            prompt: "prompt", context: AIContext(
                bookTitle: "A Book", bookSource: .kindle, reader: .kindle,
                pageNumber: page, pageCount: 300, chapter: "Ch. 3",
                excerpt: "page words"))
    }

    @discardableResult
    private func save(
        _ archive: Archive, turn: ConversationTurn, card: Bool?,
        asin: String = "B1"
    ) throws -> Int64 {
        try archive.saveAISNote(
            asin: asin, position: nil, kind: turn.action.rawValue,
            prompt: turn.prompt, answer: turn.answer,
            provider: turn.provider, source: .kindle,
            turnID: turn.id, markCard: card)
    }

    @Test("Save and Add share one row in either order")
    func idempotent() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try conversation(archive)
        let turn = try addTurn(
            archive, conversationID: conversation.id,
            question: "What is momentum?", answer: "A moving average.")

        let noteID = try save(archive, turn: turn, card: nil)
        // A plain saved note is not a card, and marking it later reuses it.
        #expect(try archive.aiNotes().count == 1)
        #expect(try archive.aiNotes().first?.isCard == false)
        #expect(try archive.aiCards().isEmpty)
        let cardID = try save(archive, turn: turn, card: true)
        #expect(noteID == cardID)
        let cards = try archive.aiCards()
        #expect(cards.count == 1)
        #expect(cards.first?.question == "What is momentum?")
        #expect(cards.first?.answer == "A moving average.")
        #expect(cards.first?.conversationID == conversation.id)
        #expect(cards.first?.turnID == turn.id)
        #expect(cards.first?.context.pageNumber == 12)
        #expect(cards.first?.context.chapter == "Ch. 3")

        // Save Note after Add must not clear the card.
        _ = try save(archive, turn: turn, card: nil)
        #expect(try archive.aiCards().count == 1)

        // An explicit un-card clears it, distinct from Save's nil (preserve).
        _ = try save(archive, turn: turn, card: false)
        #expect(try archive.aiCards().isEmpty)
        #expect(try archive.aiNotes().first?.isCard == false)
        _ = try save(archive, turn: turn, card: true)
        #expect(try archive.aiCards().count == 1)

        try archive.removeCard(turnID: turn.id)
        #expect(try archive.aiCards().isEmpty)
        #expect(try archive.aiNotes().count == 1)
        #expect(try archive.aiNotes().first?.isCard == false)

        _ = try save(archive, turn: turn, card: true)
        #expect(try archive.aiCards().count == 1)
    }

    @Test("deleting a note removes the card made from it")
    func deleteNote() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try conversation(archive)
        let turn = try addTurn(
            archive, conversationID: conversation.id,
            question: "Why?", answer: "Because.")
        let noteID = try save(archive, turn: turn, card: true)
        #expect(try archive.aiCards().count == 1)

        #expect(try archive.deleteAINote(id: noteID))
        #expect(try archive.aiNotes().isEmpty)
        #expect(try archive.aiCards().isEmpty)
        // The chat the answer came from is untouched.
        #expect(
            try archive.conversationTurns(conversationID: conversation.id)
                .count == 1)
        // A second delete reports that there was nothing left.
        #expect(try archive.deleteAINote(id: noteID) == false)
    }

    @Test("deleting every note reports the count and empties both lists")
    func deleteAllNotes() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try conversation(archive)
        let first = try addTurn(
            archive, conversationID: conversation.id, question: "One",
            answer: "1")
        let second = try addTurn(
            archive, conversationID: conversation.id, question: "Two",
            answer: "2")
        _ = try save(archive, turn: first, card: true)
        _ = try save(archive, turn: second, card: nil)
        #expect(try archive.aiNotes().count == 2)

        #expect(try archive.deleteAllAINotes() == 2)
        #expect(try archive.aiNotes().isEmpty)
        #expect(try archive.aiCards().isEmpty)
        #expect(try archive.deleteAllAINotes() == 0)
    }

    @Test("two turns with the same answer and timestamp do not collapse")
    func distinctTurns() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try archive.createConversation(
            bookKey: "B1", bookTitle: "A Book", bookSource: .kindle,
            turns: [
                NewConversationTurn(
                    action: .ask, question: "Q1", answer: "same answer",
                    provider: "p", prompt: "p", context: .empty),
                NewConversationTurn(
                    action: .ask, question: "Q2", answer: "same answer",
                    provider: "p", prompt: "p", context: .empty),
            ])
        let turns = try archive.conversationTurns(
            conversationID: conversation.id)
        try #require(turns.count == 2)
        #expect(turns[0].createdAt == turns[1].createdAt)
        for turn in turns { _ = try save(archive, turn: turn, card: true) }
        let cards = try archive.aiCards()
        #expect(cards.count == 2)
        #expect(Set(cards.map(\.turnID)).count == 2)
        #expect(try archive.cardTurnIDs(conversationID: conversation.id)
            == [turns[0].id, turns[1].id])
    }

    @Test("Add before Save keeps the same row and the card")
    func addThenSave() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try conversation(archive)
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: "A")
        let cardID = try save(archive, turn: turn, card: true)
        let noteID = try save(archive, turn: turn, card: nil)
        #expect(cardID == noteID)
        #expect(try archive.aiNotes().count == 1)
        #expect(try archive.aiCards().count == 1)
    }

    @Test("a card follows its conversation key migration")
    func followsMigration() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try conversation(archive, key: "books:alice")
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: "A")
        _ = try save(archive, turn: turn, card: true)

        try archive.migrateConversations(
            from: "books:alice", to: "ASSET-1", title: "Alice",
            source: .appleBooks)
        #expect(try archive.aiCards(bookKeys: ["ASSET-1"]).count == 1)
        #expect(try archive.aiCards(bookKeys: ["BOOKS:ALICE"]).isEmpty)
        #expect(try archive.aiNotes(asin: "ASSET-1").count == 1)
        // A writer that captured the old key before the migration must not
        // put the note back under the old book.
        _ = try save(archive, turn: turn, card: true, asin: "books:alice")
        #expect(try archive.aiNotes(asin: "ASSET-1").count == 1)
        #expect(try archive.aiNotes(asin: "books:alice").isEmpty)
        try archive.removeCard(turnID: turn.id)
        #expect(try archive.aiNotes(asin: "ASSET-1").count == 1)
        #expect(try archive.aiNotes(asin: "books:alice").isEmpty)
    }

    @Test("a card survives a fingerprint to ASIN migration")
    func fingerprintMigration() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try conversation(archive, key: "text:abc123")
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: "A")
        _ = try save(archive, turn: turn, card: true)

        try archive.migrateConversations(
            from: "text:abc123", to: "ASSET-2", title: "Alice",
            source: .appleBooks)
        #expect(try archive.aiCards(bookKeys: ["ASSET-2"]).count == 1)
        #expect(try archive.aiCards(bookKeys: ["TEXT:ABC123"]).isEmpty)
    }

    @Test("a card survives closing and reopening the archive")
    func restart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-cards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("archive.sqlite")
        var turnID: Int64 = 0
        do {
            let archive = try Archive(path: path)
            let conversation = try conversation(archive)
            let turn = try addTurn(
                archive, conversationID: conversation.id, question: "Q",
                answer: "A")
            _ = try save(archive, turn: turn, card: true)
            turnID = turn.id
        }

        let reopened = try Archive(path: path)
        let cards = try reopened.aiCards()
        #expect(cards.count == 1)
        #expect(cards.first?.turnID == turnID)
        #expect(try reopened.aiNotes().count == 1)
        #expect(try reopened.aiNotes().first?.isCard == true)
    }

    @Test("an AI-only archive exposes cards and no annotations")
    func aiOnlyArchive() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try conversation(archive, key: "B1")
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: "A")
        _ = try save(archive, turn: turn, card: true)

        #expect(try archive.annotations().isEmpty)
        #expect(try archive.counts().annotations == 0)
        let cards = try archive.aiCards()
        #expect(cards.count == 1)
        let book = Book(
            asin: "B1", title: "A Book", author: "A", bookType: 10,
            readState: 0, source: .kindle)
        #expect(AICardFilter.cards(cards, for: book, search: "").count == 1)
    }

    @Test("mixed-case keys find the card and its book")
    func mixedCaseKey() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Book(
            asin: "ASSET-2", title: "A Book", author: "A", bookType: 10,
            readState: 0, source: .kindle)
        _ = try archive.importAll(books: [book], annotations: [])
        let conversation = try archive.createConversation(
            bookKey: "asset-2", bookTitle: "", bookSource: nil)
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: "A")
        _ = try save(archive, turn: turn, card: true)
        let cards = try archive.aiCards(bookKeys: ["ASSET-2"])
        #expect(cards.count == 1)
        #expect(cards.first?.bookTitle == "A Book")
        #expect(cards.first?.bookSource == .kindle)
    }

    @Test("duplicate case-variant book rows yield one card")
    func duplicateBookRows() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try archive.importAll(
            books: [
                Book(
                    asin: "B1", title: "First", author: "A", bookType: 10,
                    readState: 0, source: .kindle),
                Book(
                    asin: "b1", title: "Second", author: "A", bookType: 10,
                    readState: 0, source: .kindle),
            ], annotations: [])
        let conversation = try conversation(archive)
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: "A")
        _ = try save(archive, turn: turn, card: true)
        #expect(try archive.aiCards(bookKeys: ["B1"]).count == 1)
        #expect(try archive.aiCardCount() == 1)
    }

    @Test("the card index serves the ordered query")
    func cardIndexPlan() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDatabase(
            path: directory.appendingPathComponent("archive.sqlite").path)
        _ = try archive.importAll(
            books: [
                Book(
                    asin: "B1", title: "A Book", author: "A", bookType: 10,
                    readState: 0, source: .kindle)
            ], annotations: [])
        let conversation = try conversation(archive)
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: "A")
        _ = try save(archive, turn: turn, card: true)
        let plan = try database.query(
            """
            EXPLAIN QUERY PLAN
            SELECT n.id, t.id, c.book_key, b.title
            FROM ai_notes n
            JOIN conversation_turns t ON t.id = n.turn_id
            JOIN conversations c ON c.id = t.conversation_id
            LEFT JOIN books b ON b.rowid = (
                SELECT rowid FROM books
                WHERE asin = c.book_key COLLATE NOCASE
                ORDER BY rowid LIMIT 1)
            WHERE n.carded_at IS NOT NULL
            ORDER BY n.carded_at DESC, n.id DESC
            """)
        let text = plan.compactMap { $0.string("detail") }.joined(separator: " ")
        #expect(text.contains("ai_notes_carded"))
        #expect(text.contains("books_asin_nocase"))
        #expect(!text.contains("SCAN b"))
        #expect(!text.contains("TEMP B-TREE"))
    }

    @Test("a card requires a persisted turn")
    func missingTurn() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: Archive.AICardError.self) {
            try archive.saveAISNote(
                asin: "B1", position: nil, kind: "ask", prompt: "p",
                answer: "a", provider: "p", turnID: 999, markCard: true)
        }
        #expect(throws: Archive.AICardError.self) {
            try archive.saveAISNote(
                asin: "B1", position: nil, kind: "ask", prompt: "p",
                answer: "a", provider: "p", turnID: nil, markCard: true)
        }
        #expect(try archive.aiNotes().isEmpty)
        #expect(try archive.aiCards().isEmpty)
    }

    @Test("a long answer keeps its full text on the card and the turn")
    func longAnswerRetained() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try conversation(archive)
        let answer = String(repeating: "Long answer sentence. ", count: 500)
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: answer)
        _ = try save(archive, turn: turn, card: true)

        #expect(try archive.aiCards().first?.answer == answer)
        #expect(
            try archive.conversationTurns(conversationID: conversation.id)
                .last?.answer == answer)
    }

    @Test("a card whose turn disappeared is hidden, not invented")
    func orphanHidden() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try conversation(archive)
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: "A")
        _ = try save(archive, turn: turn, card: true)

        let database = try SQLiteDatabase(
            path: directory.appendingPathComponent("archive.sqlite").path)
        try database.execute(
            "DELETE FROM conversation_turns WHERE id = \(turn.id)")

        #expect(try archive.aiCards().isEmpty)
        #expect(try archive.aiNotes().count == 1)
        #expect(try archive.aiNotes().first?.isCard == true)
    }

    private func card(
        key: String, title: String = "A Book", question: String = "Q",
        answer: String = "A"
    ) -> AICard {
        AICard(
            id: 1, turnID: 2, conversationID: 3, action: .ask,
            question: question, answer: answer, provider: "p",
            context: .empty, bookKey: key, bookTitle: title,
            bookSource: .kindle, createdAt: Date(timeIntervalSince1970: 1),
            cardedAt: Date(timeIntervalSince1970: 2))
    }

    @Test("AI cards filter by book key, title fallback and search")
    func filtering() {
        let book = Book(
            asin: "B1", title: "A Book", author: "A", bookType: 10,
            readState: 0, source: .kindle)
        let matching = [
            card(key: "B1"),
            card(key: "BOOKS:A BOOK", title: ""),
            card(key: "AsSeT-2", title: "A Book"),
            card(key: "OTHER", title: "Another Book"),
            card(
                key: "B1", question: "Unrelated",
                answer: "Momentum is a moving average."),
        ]
        let visible = AICardFilter.cards(
            matching, for: book, search: "")
        #expect(visible.count == 3)
        #expect(!visible.contains { $0.bookKey == "AsSeT-2" })
        #expect(
            AICardFilter.cards(
                matching, for: book, search: "q").count == 2)
        #expect(
            AICardFilter.cards(
                matching, for: book, search: "another").isEmpty)
        let answerOnly = AICardFilter.cards(
            matching, for: book, search: "momentum")
        #expect(answerOnly.count == 1)
        #expect(answerOnly.first?.question == "Unrelated")
        #expect(
            AICardFilter.cards(matching, for: nil, search: "").count == 5)

        // The other edition keeps its own card; a weak title key still
        // travels to a book that carries the same title.
        let otherEdition = Book(
            asin: "ASSET-2", title: "A Book", author: "A", bookType: 10,
            readState: 0, source: .kindle)
        let otherVisible = AICardFilter.cards(
            matching, for: otherEdition, search: "")
        #expect(otherVisible.count == 2)
        #expect(otherVisible.contains { $0.bookKey == "AsSeT-2" })
        #expect(!otherVisible.contains { $0.bookKey == "B1" })
    }

    @Test("a weak key does not cross readers or match a placeholder")
    func weakKeyGuards() {
        let appleBook = Book(
            asin: "B3", title: "Alice's Adventures", author: "A",
            bookType: 10, readState: 0, source: .appleBooks)
        let kindleCard = card(
            key: "kindle:alice's adventures", title: "Alice",
            question: "Q", answer: "A")
        #expect(
            AICardFilter.cards([kindleCard], for: appleBook, search: "")
                .isEmpty)

        let placeholderBook = Book(
            asin: "B4", title: "Kindle", author: "", bookType: 10,
            readState: 0, source: .kindle)
        let placeholderCard = card(
            key: "books:kindle", title: "Kindle", question: "Q",
            answer: "A")
        #expect(
            AICardFilter.cards(
                [placeholderCard], for: placeholderBook, search: "")
                .isEmpty)
    }

    @Test("a fingerprint card shows by title only when the title matches")
    func fingerprintTitleFallback() {
        let book = Book(
            asin: "B5", title: "A Book", author: "A", bookType: 10,
            readState: 0, source: .kindle)
        let matching = card(key: "text:abc123", title: "A Book")
        #expect(
            AICardFilter.cards([matching], for: book, search: "").count == 1)
        let otherTitle = card(key: "text:abc123", title: "Another Book")
        #expect(
            AICardFilter.cards([otherTitle], for: book, search: "").isEmpty)
    }

    @Test("a legacy kindle title key still finds its card")
    func kindleTitleKey() {
        let book = Book(
            asin: "B2", title: "Alice's Adventures", author: "A",
            bookType: 10, readState: 0, source: .kindle)
        let legacy = card(
            key: "kindle:alice's adventures", title: "Alice",
            question: "Who?", answer: "Alice.")
        #expect(
            AICardFilter.cards([legacy], for: book, search: "").count == 1)
    }

    @Test("AI cards do not change annotation counts or export")
    func exportUnchanged() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Book(
            asin: "B1", title: "A Book", author: "A", bookType: 10,
            readState: 0, source: .kindle)
        _ = try archive.importAll(
            books: [book], annotations: [
                Annotation(
                    id: "ann-1", asin: "B1", kind: .highlight,
                    provenance: .user, text: "A highlight")
            ])
        let before = try archive.counts()
        let conversation = try conversation(archive)
        let turn = try addTurn(
            archive, conversationID: conversation.id, question: "Q",
            answer: "CARD-ANSWER-SENTINEL")
        _ = try save(archive, turn: turn, card: true)

        let after = try archive.counts()
        #expect(after.annotations == before.annotations)
        #expect(try archive.aiCards().count == 1)
        let url = directory.appendingPathComponent("export.json")
        try archive.exportAnnotations(to: url, format: .json)
        let exported = try String(contentsOf: url, encoding: .utf8)
        #expect(!exported.contains("CARD-ANSWER-SENTINEL"))
        #expect(exported.contains("A highlight"))
    }
}
