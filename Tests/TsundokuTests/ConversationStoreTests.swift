import Foundation
import Testing

@testable import TsundokuCore

@Suite("Conversation store")
struct ConversationStoreTests {
    private func temporaryArchive() throws -> (Archive, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        return (archive, directory)
    }

    @Test("a conversation keeps its turns, their order and their context")
    func turnsRoundTrip() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try archive.createConversation(
            bookKey: "B1", bookTitle: "A Book", bookSource: .kindle)
        let context = AIContext(
            bookTitle: "A Book", bookSource: .kindle, reader: .kindle,
            pageNumber: 5, pageCount: 320, excerpt: "page text")
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .explain, question: "",
            answer: "First answer", provider: "p", prompt: "prompt",
            context: context)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .ask, question: "Why?",
            answer: "Second answer", provider: "p", prompt: "prompt",
            context: context)

        #expect(try archive.latestConversation(bookKey: "B1")?.id == conversation.id)
        let turns = try archive.conversationTurns(
            conversationID: conversation.id)
        #expect(turns.count == 2)
        #expect(turns[0].promptLabel == "Explain")
        #expect(turns[0].context == context)
        #expect(turns[1].question == "Why?")
        #expect(turns[1].answer == "Second answer")
        let summary = try #require(
            try archive.conversations(bookKey: "B1").first)
        #expect(summary.turnCount == 2)
        #expect(summary.firstQuestion == "Explain")
        #expect(summary.lastAnswer == "Second answer")
    }

    @Test("the newest conversation is the one resumed")
    func newestConversationWins() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = try archive.createConversation(
            bookKey: "B2", bookTitle: "A Book", bookSource: .appleBooks)
        try archive.appendConversationTurn(
            conversationID: older.id, action: .explain, question: "",
            answer: "old", provider: "p", prompt: "", context: .empty)
        let newer = try archive.createConversation(
            bookKey: "B2", bookTitle: "A Book", bookSource: .appleBooks)
        try archive.appendConversationTurn(
            conversationID: newer.id, action: .ask, question: "new",
            answer: "new", provider: "p", prompt: "", context: .empty)
        #expect(try archive.latestConversation(bookKey: "B2")?.id == newer.id)
        let summaries = try archive.conversations(bookKey: "B2")
        #expect(summaries.count == 2)
        #expect(summaries.first?.id == newer.id)
    }

    @Test("chat counts are grouped by book key")
    func countsByBook() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try archive.createConversation(
            bookKey: "B3", bookTitle: "One", bookSource: .kindle)
        let second = try archive.createConversation(
            bookKey: "B4", bookTitle: "Two", bookSource: .appleBooks)
        for _ in 1...2 {
            try archive.appendConversationTurn(
                conversationID: first.id, action: .explain, question: "",
                answer: "a", provider: "p", prompt: "", context: .empty)
        }
        try archive.appendConversationTurn(
            conversationID: second.id, action: .summarize, question: "",
            answer: "b", provider: "p", prompt: "", context: .empty)
        let counts = try archive.conversationCounts()
        #expect(counts["B3"] == 2)
        #expect(counts["B4"] == 1)
        #expect(counts["missing"] == nil)
    }

    @Test("a selection and page survive a reopen")
    func contextSurvivesReopen() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try archive.createConversation(
            bookKey: "B5", bookTitle: "Book", bookSource: .appleBooks)
        let context = AIContext(
            bookTitle: "Book", bookSource: .appleBooks, reader: .appleBooks,
            pageNumber: nil, pageCount: nil,
            selection: "the selected words", excerpt: "page text")
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .translate,
            question: "", answer: "译文", provider: "p", prompt: "",
            context: context)
        let reopened = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        let turns = try reopened.conversationTurns(
            conversationID: conversation.id)
        #expect(turns.count == 1)
        #expect(turns[0].context.selection == "the selected words")
        #expect(
            turns[0].context.attachments.contains(
                "Selection · 18 characters"))
    }

    @Test("a stable identifier keys a book before the library knows it")
    func keyUsesAStableIdentifier() {
        #expect(
            ConversationKey.make(
                book: nil, reader: .kindle, title: "Kindle",
                identifier: "B075H364NC") == "B075H364NC")
        #expect(
            ConversationKey.make(
                book: nil, reader: .kindle, title: "The Math  of Networks")
                == "kindle:the math of networks")
        let known = Book(
            asin: "B9", title: "Known", author: "", bookType: 10,
            readState: 0)
        #expect(
            ConversationKey.make(
                book: known, reader: .kindle, title: "Known",
                identifier: "OTHER") == "B9")
    }
}
