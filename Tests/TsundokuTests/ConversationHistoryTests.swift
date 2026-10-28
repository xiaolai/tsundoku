import Foundation
import Testing

@testable import TsundokuCore

@Suite("Conversation history storage")
struct ConversationHistoryTests {
    private func temporaryArchive() throws -> (Archive, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("archive.sqlite")
        return (try Archive(path: path), path)
    }

    private func turn(
        _ conversationID: Int64, _ question: String, _ answer: String,
        archive: Archive
    ) throws -> ConversationTurn {
        try archive.appendConversationTurn(
            conversationID: conversationID, action: .ask,
            question: question, answer: answer, provider: "test",
            prompt: "prompt \(question)", context: .empty)
    }

    @Test("new context and retention settings default safely")
    func settingsDefaults() throws {
        let defaults = AISettings()
        #expect(!defaults.autoCompact)
        #expect(defaults.compactThresholdCharacters == 800_000)
        #expect(defaults.chatRetentionDays == 0)
        #expect(!defaults.chatRetentionConfirmed)
        #expect(defaults.chatRetentionConfirmedDays == 0)
        let decoded = try JSONDecoder().decode(
            AISettings.self, from: Data("{}".utf8))
        #expect(!decoded.autoCompact)
        #expect(decoded.compactThresholdCharacters == 800_000)
        #expect(decoded.chatRetentionDays == 0)
        #expect(decoded.chatRetentionConfirmedDays == 0)
    }

    @Test("an archive written by the current release migrates in place")
    func oldSchemaMigrates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("archive.sqlite")
        let old = try SQLiteDatabase(path: path.path)
        try old.execute(
            """
            CREATE TABLE conversations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              book_key TEXT NOT NULL,
              book_title TEXT NOT NULL,
              book_source TEXT,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            )
            """)
        try old.execute(
            """
            CREATE TABLE conversation_turns (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              conversation_id INTEGER NOT NULL,
              action TEXT NOT NULL,
              question TEXT NOT NULL,
              answer TEXT NOT NULL,
              provider TEXT NOT NULL,
              prompt TEXT NOT NULL,
              context_json TEXT NOT NULL,
              created_at REAL NOT NULL
            )
            """)
        try old.execute(
            """
            CREATE TABLE ai_notes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              asin TEXT, position TEXT, kind TEXT NOT NULL,
              prompt TEXT NOT NULL, answer TEXT NOT NULL,
              provider TEXT NOT NULL, created_at REAL NOT NULL
            )
            """)
        try old.execute(
            "INSERT INTO conversations VALUES (1, 'B-old', 'Old', 'Kindle', 1, 1)")
        try old.execute(
            """
            INSERT INTO conversation_turns
            VALUES (1, 1, 'ask', 'old question', 'old answer', 'test',
                    'old prompt', '{}', 1)
            """)
        let archive = try Archive(path: path)
        let conversation = try #require(try archive.conversation(id: 1))
        #expect(conversation.title == nil)
        let turn = try #require(
            try archive.conversationTurns(conversationID: 1).first)
        #expect(turn.prompt == "old prompt")
        #expect(
            try archive.conversations(
                bookKey: "B-old", search: "old question").count == 1)
    }

    @Test("prompt metadata counts characters, not UTF-8 bytes")
    func promptCharacterCount() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-unicode", bookTitle: "Book", bookSource: .kindle)
        let prompt = "é😀 word"
        let saved = try archive.appendConversationTurn(
            conversationID: conversation.id, action: .ask,
            question: "Q", answer: "A", provider: "test",
            prompt: prompt, context: .empty)
        #expect(saved.promptCharacters == prompt.count)
        let loaded = try #require(
            try archive.conversationTurns(conversationID: conversation.id)
                .first)
        #expect(loaded.promptCharacters == prompt.count)
    }

    @Test("unknown actions and corrupt context fail visibly")
    func corruptTurnMetadataFails() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-turn-corrupt", bookTitle: "Book",
            bookSource: .kindle)
        _ = try archive.appendConversationTurn(
            conversationID: conversation.id, action: .ask,
            question: "Q", answer: "A", provider: "test",
            prompt: "p", context: .empty)
        let database = try SQLiteDatabase(path: path.path)
        try database.execute(
            "UPDATE conversation_turns SET action = 'future-action'")
        #expect(throws: Archive.ConversationArchiveError.self) {
            try archive.conversationTurns(conversationID: conversation.id)
        }
        try database.execute(
            "UPDATE conversation_turns SET action = 'ask', context_json = '[]'")
        #expect(throws: Archive.ConversationArchiveError.self) {
            try archive.conversationTurns(conversationID: conversation.id)
        }
    }

    @Test("an empty blob stays a blob, not SQL NULL")
    func emptyBlobRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-blob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDatabase(
            path: directory.appendingPathComponent("test.sqlite").path)
        try database.execute("CREATE TABLE t (v BLOB)")
        try database.execute("INSERT INTO t VALUES (?)", [.blob(Data())])
        let row = try #require(
            try database.query("SELECT v FROM t").first)
        #expect(row.data("v") == Data())
    }

    @Test("text with an embedded NUL round-trips")
    func textWithNULRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDatabase(
            path: directory.appendingPathComponent("test.sqlite").path)
        try database.execute("CREATE TABLE t (v TEXT)")
        let text = "before\u{0}after"
        try database.execute("INSERT INTO t VALUES (?)", [.text(text)])
        let row = try #require(
            try database.query("SELECT v FROM t").first)
        #expect(row.string("v") == text)
    }

    @Test("a long prompt round-trips through compressed storage")
    func compressedPromptRoundTrip() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B1", bookTitle: "Book", bookSource: .kindle)
        let prompt = String(repeating: "a long prompt ", count: 8_000)
        let saved = try archive.appendConversationTurn(
            conversationID: conversation.id, action: .explain,
            question: "", answer: "answer", provider: "test",
            prompt: prompt, context: .empty)
        #expect(saved.prompt == prompt)
        #expect(saved.promptCharacters == prompt.count)
        #expect(saved.promptSHA256?.isEmpty == false)

        let loaded = try #require(
            try archive.conversationTurns(conversationID: conversation.id)
                .first)
        #expect(loaded.prompt == prompt)

        let database = try SQLiteDatabase(path: path.path)
        let row = try #require(
            try database.query(
                "SELECT prompt, prompt_zlib FROM conversation_turns LIMIT 1"
            ).first)
        #expect(row.string("prompt") == "")
        #expect((row.data("prompt_zlib")?.count ?? 0) > 0)
    }

    @Test("a new conversation returns its inserted turn IDs")
    func createConversationReturnsTurnIDs() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let created = try archive.createConversationWithTurnIDs(
            bookKey: "B-create", bookTitle: "Book", bookSource: .kindle,
            turns: [
                NewConversationTurn(
                    action: .ask, question: "Q", answer: "A",
                    provider: "test", prompt: "prompt", context: .empty)
            ])
        #expect(created.1.count == 1)
        let turns = try archive.conversationTurns(
            conversationID: created.0.id)
        #expect(turns.map(\.id) == created.1)
    }

    @Test("a corrupted compressed prompt fails visibly")
    func corruptPromptFails() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-corrupt", bookTitle: "Book", bookSource: .kindle)
        _ = try archive.appendConversationTurn(
            conversationID: conversation.id, action: .ask,
            question: "Q", answer: "A", provider: "test",
            prompt: "compressed prompt", context: .empty)
        let database = try SQLiteDatabase(path: path.path)
        try database.execute(
            "UPDATE conversation_turns SET prompt_zlib = ? WHERE id = 1",
            [.blob(Data([0, 1, 2, 3, 4]))])
        #expect(throws: Archive.ConversationArchiveError.self) {
            try archive.conversationTurns(conversationID: conversation.id)
        }
    }

    @Test("a legacy plain prompt remains readable")
    func legacyPromptReadable() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-legacy", bookTitle: "Book", bookSource: .kindle)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .ask,
            question: "Q", answer: "A", provider: "test",
            prompt: "legacy prompt", context: .empty)
        let database = try SQLiteDatabase(path: path.path)
        try database.execute(
            """
            UPDATE conversation_turns
            SET prompt = 'legacy prompt', prompt_zlib = NULL,
                prompt_sha256 = NULL, prompt_chars = NULL
            """)
        let loaded = try #require(
            try archive.conversationTurns(conversationID: conversation.id)
                .first)
        #expect(loaded.prompt == "legacy prompt")
    }

    @Test("search covers title, questions, answers and summaries")
    func searchCoversTranscript() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-search", bookTitle: "Book", bookSource: .kindle)
        let first = try turn(
            conversation.id, "Why does the needle move?",
            "The answer is hidden.", archive: archive)
        _ = first
        try archive.renameConversation(
            id: conversation.id, title: "A Unique Title")
        #expect(
            try archive.conversations(
                bookKey: "B-search", search: "needle").count == 1)
        #expect(
            try archive.conversations(
                bookKey: "B-search", search: "Unique Title").count == 1)
        #expect(
            try archive.conversations(
                bookKey: "B-search", search: "hidden").count == 1)
        #expect(
            try archive.conversations(
                bookKey: "B-search", search: "needle hidden").count == 1)
        #expect(
            try archive.conversations(
                bookKey: "B-search", search: "ask").count == 1)

        let second = try turn(
            conversation.id, "Another question", "Another answer",
            archive: archive)
        _ = second
        try archive.saveCompaction(
            conversationID: conversation.id, throughTurnID: first.id,
            summary: "The needle was discussed.", provider: "test",
            model: nil)
        #expect(
            try archive.conversations(
                bookKey: "B-search", search: "needle was discussed")
                .count == 1)
        // FTS matches whole tokens; a reader typing part of a word must
        // still find the turn.
        #expect(
            try archive.conversations(
                bookKey: "B-search", search: "need").count == 1)
        #expect(
            try archive.conversations(
                bookKey: "B-search", search: "needle mov").count == 1)
    }

    @Test("search is scoped by book keys and does not cross books")
    func searchDoesNotCrossBooks() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let one = try archive.createConversation(
            bookKey: "B-one", bookTitle: "One", bookSource: .kindle)
        let two = try archive.createConversation(
            bookKey: "B-two", bookTitle: "Two", bookSource: .kindle)
        _ = try turn(one.id, "alpha", "one", archive: archive)
        _ = try turn(two.id, "alpha", "two", archive: archive)
        let found = try archive.conversations(
            bookKeys: ["B-one"], search: "alpha")
        #expect(found.map(\.id) == [one.id])
        #expect(
            try archive.conversations(
                bookKeys: ["B-missing"], search: "alpha").isEmpty)
    }

    @Test("FTS backfills a store whose index was cleared")
    func searchBackfill() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-backfill", bookTitle: "Book", bookSource: .kindle)
        _ = try turn(
            conversation.id, "A backfill marker", "The answer",
            archive: archive)
        let database = try SQLiteDatabase(path: path.path)
        // Simulate a database written before the search index existed.
        try database.execute("DELETE FROM conversation_turns_fts")
        try database.execute(
            """
            INSERT INTO meta (key, value) VALUES ('conversation_fts', '0')
            ON CONFLICT(key) DO UPDATE SET value = '0'
            """)
        let reopened = try Archive(path: path)
        #expect(
            try reopened.conversations(
                bookKey: "B-backfill", search: "backfill marker").count == 1)
    }

    @Test("rename does not reorder a conversation")
    func renameDoesNotReorder() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-rename", bookTitle: "Book", bookSource: .kindle)
        _ = try turn(conversation.id, "Q", "A", archive: archive)
        let before = try #require(
            try archive.conversation(id: conversation.id))
        try archive.renameConversation(
            id: conversation.id, title: "A name")
        let after = try #require(
            try archive.conversation(id: conversation.id))
        #expect(after.title == "A name")
        #expect(after.updatedAt == before.updatedAt)
        try archive.renameConversation(id: conversation.id, title: " ")
        #expect(try archive.conversation(id: conversation.id)?.title == "")
    }

    @Test("a delete confirmation omits zero clauses and agrees in number")
    func deletionSentenceGrammar() {
        let simple = ConversationDeletionImpact(
            conversations: 2, turns: 1, compactions: 0, notes: 0, cards: 0)
        #expect(
            simple.deletionSentence(includeConversations: true)
                == "2 chats and 1 turn will be deleted.")
        let full = ConversationDeletionImpact(
            conversations: 1, turns: 2, compactions: 1, notes: 3, cards: 1)
        #expect(
            full.deletionSentence(includeConversations: true)
                == "1 chat, 2 turns and 1 summary will be deleted. "
                    + "3 saved notes are kept. 1 card will leave Cards.")
    }

    @Test("deleting a chat keeps notes but removes cards and summaries")
    func deleteKeepsNotes() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-delete", bookTitle: "Book", bookSource: .kindle)
        let saved = try turn(
            conversation.id, "Q", "A", archive: archive)
        _ = try archive.saveAISNote(
            asin: "B-delete", position: nil, kind: "ask",
            prompt: "prompt", answer: "A", provider: "test",
            source: .kindle, turnID: saved.id, markCard: true)
        _ = try archive.saveCompaction(
            conversationID: conversation.id, throughTurnID: saved.id,
            summary: "summary", provider: "test", model: nil)

        let impact = try archive.deletionImpact(
            conversationID: conversation.id)
        #expect(impact.conversations == 1)
        #expect(impact.turns == 1)
        #expect(impact.compactions == 1)
        #expect(impact.notes == 1)
        #expect(impact.cards == 1)

        let deleted = try archive.deleteConversation(id: conversation.id)
        #expect(deleted == impact)
        #expect(try archive.conversationTurns(
            conversationID: conversation.id).isEmpty)
        #expect(try archive.latestCompaction(
            conversationID: conversation.id) == nil)
        #expect(try archive.aiCards().isEmpty)
        let notes = try archive.aiNotes()
        #expect(notes.count == 1)
        #expect(notes[0].turnID == nil)
        #expect(notes[0].cardedAt == nil)
        #expect(notes[0].answer == "A")
        #expect(try archive.deleteConversation(id: conversation.id).turns == 0)
    }

    @Test("deleting a book's chats leaves another book alone")
    func deleteAllForBook() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let one = try archive.createConversation(
            bookKey: "B-all-one", bookTitle: "One", bookSource: .kindle)
        let two = try archive.createConversation(
            bookKey: "B-all-two", bookTitle: "Two", bookSource: .kindle)
        _ = try turn(one.id, "Q", "A", archive: archive)
        _ = try turn(two.id, "Q", "A", archive: archive)
        let impact = try archive.deleteConversations(
            bookKey: "B-all-one")
        #expect(impact.conversations == 1)
        #expect(try archive.conversations(bookKey: "B-all-one").isEmpty)
        #expect(
            try archive.conversations(bookKey: "B-all-two").count == 1)
    }

    @Test("retention deletes only conversations older than its cutoff")
    func retentionBoundary() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let old = try archive.createConversation(
            bookKey: "B-old", bookTitle: "Old", bookSource: .kindle)
        let current = try archive.createConversation(
            bookKey: "B-current", bookTitle: "Current", bookSource: .kindle)
        _ = try turn(old.id, "Q", "A", archive: archive)
        _ = try turn(current.id, "Q", "A", archive: archive)
        let database = try SQLiteDatabase(path: path.path)
        try database.execute(
            "UPDATE conversations SET updated_at = 1000 WHERE id = ?",
            [.integer(old.id)])
        let deleted = try archive.deleteConversations(
            olderThan: Date(timeIntervalSince1970: 2_000))
        #expect(deleted.conversations == 1)
        #expect(try archive.conversation(id: old.id) == nil)
        #expect(try archive.conversation(id: current.id) != nil)
    }

    @Test("a summary or card added after a review blocks deletion")
    func retentionReviewPreconditions() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-review", bookTitle: "Book", bookSource: .kindle)
        let first = try turn(conversation.id, "Q", "A", archive: archive)
        let database = try SQLiteDatabase(path: path.path)
        try database.execute(
            "UPDATE conversations SET updated_at = 1000 WHERE id = ?",
            [.integer(conversation.id)])
        let cutoff = Date(timeIntervalSince1970: 2_000)
        let ids = try archive.conversationIDs(olderThan: cutoff)
        let review = try archive.deletionReview(ids: ids)
        #expect(review.cardNoteIDs.isEmpty)
        // Selection and review come from one snapshot.
        #expect(try archive.retentionReview(olderThan: cutoff).ids == ids)

        // A summary changes no conversation timestamp; only the reviewed
        // compaction revision can catch it.
        _ = try archive.saveCompaction(
            conversationID: conversation.id, throughTurnID: first.id,
            summary: "late summary", provider: "test", model: nil)
        #expect(throws: Archive.ConversationArchiveError.self) {
            try archive.deleteConversations(
                ids: ids, expectedUpdatedAt: review.updatedAt,
                expectedCompactionRevisions: review.revisions,
                expectedCardNoteIDs: review.cardNoteIDs)
        }
        #expect(try archive.conversation(id: conversation.id) != nil)

        // A card does too; only the reviewed card set can catch it.
        let afterSummary = try archive.deletionReview(ids: ids)
        _ = try archive.saveAISNote(
            asin: "B-review", position: nil, kind: "ask",
            prompt: "prompt", answer: "A", provider: "test",
            source: .kindle, turnID: first.id, markCard: true)
        #expect(throws: Archive.ConversationArchiveError.self) {
            try archive.deleteConversations(
                ids: ids, expectedUpdatedAt: afterSummary.updatedAt,
                expectedCompactionRevisions: afterSummary.revisions,
                expectedCardNoteIDs: afterSummary.cardNoteIDs)
        }
        #expect(try archive.conversation(id: conversation.id) != nil)

        // A new turn moves the timestamp; the reviewed one no longer holds.
        _ = try turn(conversation.id, "late question", "late answer",
                     archive: archive)
        #expect(throws: Archive.ConversationArchiveError.self) {
            try archive.deleteConversations(
                ids: ids, expectedUpdatedAt: afterSummary.updatedAt,
                expectedCompactionRevisions: afterSummary.revisions,
                expectedCardNoteIDs: afterSummary.cardNoteIDs)
        }
        #expect(try archive.conversation(id: conversation.id) != nil)

        // An unchanged review deletes.
        try database.execute(
            "UPDATE conversations SET updated_at = 1000 WHERE id = ?",
            [.integer(conversation.id)])
        let final = try archive.deletionReview(ids: ids)
        #expect(final.cardNoteIDs.count == 1)
        let impact = try archive.deleteConversations(
            ids: ids, expectedUpdatedAt: final.updatedAt,
            expectedCompactionRevisions: final.revisions,
            expectedCardNoteIDs: final.cardNoteIDs)
        #expect(impact.conversations == 1)
        #expect(try archive.conversation(id: conversation.id) == nil)
    }

    @Test("a compaction started before removal cannot resurrect it")
    func compactionPrecondition() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-precondition", bookTitle: "Book",
            bookSource: .kindle)
        var turns: [ConversationTurn] = []
        for index in 1...5 {
            turns.append(
                try archive.appendConversationTurn(
                    conversationID: conversation.id, action: .ask,
                    question: "Q\(index)", answer: "A\(index)",
                    provider: "test", prompt: "p", context: .empty))
        }
        let revision = try archive.compactionRevision(
            conversationID: conversation.id)
        let first = try archive.saveCompaction(
            conversationID: conversation.id, throughTurnID: turns[1].id,
            summary: "first", provider: "test", model: nil,
            precondition: .none, expectedRevision: revision)
        try archive.clearCompaction(conversationID: conversation.id)
        #expect(throws: Archive.ConversationArchiveError.self) {
            try archive.saveCompaction(
                conversationID: conversation.id,
                throughTurnID: turns[2].id, summary: "late",
                provider: "test", model: nil,
                precondition: .matching(first.id),
                expectedRevision: revision)
        }
        #expect(try archive.latestCompaction(
            conversationID: conversation.id) == nil)
    }

    @Test("Markdown export keeps selection and excerpt context")
    func exportKeepsContext() {
        let conversation = Conversation(
            id: 1, bookKey: "B", bookTitle: "Book", bookSource: .kindle,
            title: "A chat", createdAt: Date(), updatedAt: Date())
        let context = AIContext(
            bookTitle: "Book", bookSource: .kindle, reader: .kindle,
            pageNumber: 7, chapter: "Chapter 2", selection: "chosen words",
            excerpt: "page opening", scope: .currentChapter)
        let turn = ConversationTurn(
            id: 1, conversationID: 1, action: .ask, question: "Q",
            answer: "A", provider: "test", prompt: "p", context: context,
            createdAt: Date())
        let text = ConversationExport.markdown(
            conversation: conversation, turns: [turn], compaction: nil)
        #expect(text.contains("- Page: Page 7"))
        #expect(text.contains("- Chapter: Chapter 2"))
        #expect(text.contains("- Book source: Kindle"))
        #expect(text.contains("- Reader: Kindle"))
        #expect(text.contains("chosen words"))
        #expect(text.contains("page opening"))
    }

    @Test("Markdown export keeps stored text from changing its structure")
    func exportEscapesTranscript() {
        let conversation = Conversation(
            id: 1, bookKey: "B", bookTitle: "Book", bookSource: .kindle,
            title: nil, createdAt: Date(), updatedAt: Date())
        let context = AIContext(
            bookTitle: "Book", excerpt: "line one\nline two")
        let answer =
            "<example>\n# heading\n```swift\nlet x = 1\n```\n"
            + "![image](https://example.com/a.png)"
        let turn = ConversationTurn(
            id: 1, conversationID: 1, action: .ask,
            question: "First line\n## second line",
            answer: answer,
            provider: "test", prompt: "p", context: context,
            createdAt: Date())
        let text = ConversationExport.markdown(
            conversation: conversation, turns: [turn], compaction: nil)
        #expect(text.contains("## 1. First line ## second line"))
        // Each stored block is fenced longer than any backtick run inside
        // it, so headings, links and images stay literal text.
        #expect(text.contains("```text\nFirst line\n## second line\n```"))
        #expect(text.contains("````text\n\(answer)\n````"))
        #expect(text.contains("```text\nline one\nline two\n```"))
    }

    @Test("an export snapshot reads the row and transcript together")
    func exportSnapshotIsConsistent() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-export", bookTitle: "Book", bookSource: .kindle)
        let saved = try turn(
            conversation.id, "Q", "A", archive: archive)
        try archive.renameConversation(
            id: conversation.id, title: "Fresh name")
        _ = try archive.saveCompaction(
            conversationID: conversation.id, throughTurnID: saved.id,
            summary: "summary", provider: "test", model: nil)
        let loaded = try #require(
            try archive.conversationExportSnapshot(
                conversationID: conversation.id))
        #expect(loaded.conversation.title == "Fresh name")
        #expect(loaded.snapshot.turns.count == 1)
        #expect(loaded.snapshot.compaction?.summary == "summary")
        #expect(
            try archive.conversationExportSnapshot(conversationID: 9_999)
                == nil)
    }

    @Test("filing refuses a chat another window already moved")
    func filingPrecondition() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "books:title", bookTitle: "Book", bookSource: nil)
        let reviewed = ConversationFilingPrecondition(
            bookKey: conversation.bookKey,
            bookSource: conversation.bookSource)
        try archive.migrateConversation(
            id: conversation.id, to: "B-first", title: "Book",
            source: .kindle, precondition: reviewed)
        #expect(
            try archive.conversation(id: conversation.id)?.bookKey
                == "B-first")
        #expect(throws: Archive.ConversationArchiveError.self) {
            try archive.migrateConversation(
                id: conversation.id, to: "B-second", title: "Book",
                source: .kindle, precondition: reviewed)
        }
        #expect(
            try archive.conversation(id: conversation.id)?.bookKey
                == "B-first")
    }

    @Test("storage counts and compaction metadata are exposed")
    func storageCounts() throws {
        let (archive, path) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let conversation = try archive.createConversation(
            bookKey: "B-storage", bookTitle: "Book", bookSource: .kindle)
        let saved = try turn(
            conversation.id, "Q", "A", archive: archive)
        _ = try archive.saveCompaction(
            conversationID: conversation.id, throughTurnID: saved.id,
            summary: "Summary", provider: "test", model: "m")
        let storage = try archive.conversationStorage()
        #expect(storage.conversations == 1)
        #expect(storage.turns == 1)
        #expect(storage.compactions == 1)
        let summary = try #require(
            try archive.conversations(bookKey: "B-storage").first)
        #expect(summary.isCompacted)
        #expect(summary.displayTitle == "Q")
    }
}
