import Foundation
import SaySoAI
import Testing

@testable import TsundokuCore
@testable import TsundokuUI

private actor AnswerCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@MainActor
@Suite("Chat history and compaction panel", .serialized, .timeLimit(.minutes(1)))
struct AIPanelHistoryTests {
    private struct FixedReader: ReaderContext {
        let kind: ReaderKind
        let pageValue: ReaderPage

        func page() throws -> ReaderPage { pageValue }
        func selectedText() -> String? { pageValue.selection }
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func archive(in directory: URL) throws -> Archive {
        try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
    }

    private func model(in directory: URL) -> AppModel {
        AppModel(
            archiveURL: directory.appendingPathComponent("archive.sqlite"),
            kindlePaths: KindlePaths(
                container: directory.appendingPathComponent("missing")),
            booksPaths: BooksPaths(
                container: directory.appendingPathComponent("missing")),
            recoverReaderSettings: false)
    }

    private func page(_ number: Int = 1, text: String? = nil) -> ReaderPage {
        ReaderPage(
            text: text ?? String(repeating: "page words ", count: 40),
            title: "Kindle", kind: .kindle, source: .accessibility,
            pageNumber: number, pageCount: 300, identifier: "B0ASIN0001")
    }

    private func seededConversation(
        _ archive: Archive, turns: Int = 5
    ) throws -> (Conversation, [ConversationTurn]) {
        _ = try archive.importAll(
            books: [
                Book(
                    asin: "B0ASIN0001", title: "The Book", author: "A",
                    bookType: 10, readState: 0, source: .kindle)
            ], annotations: [])
        let conversation = try archive.createConversation(
            bookKey: "B0ASIN0001", bookTitle: "The Book",
            bookSource: .kindle)
        var stored: [ConversationTurn] = []
        for index in 1...turns {
            stored.append(
                try archive.appendConversationTurn(
                    conversationID: conversation.id, action: .ask,
                    question: "question \(index)",
                    answer: "answer \(index)", provider: "test",
                    prompt: String(repeating: "prompt ", count: 100),
                    context: .empty))
        }
        return (conversation, stored)
    }

    private func panel(
        model: AppModel,
        promptProvider: AIPanelModel.PromptProvider? = nil,
        answerProvider: @escaping AIPanelModel.AnswerProvider = { _, _ in
            AIAnswer(text: "new answer", provider: "test")
        }
    ) -> AIPanelModel {
        let panel = AIPanelModel(
            app: model, context: FixedReader(kind: .kindle, pageValue: page()),
            contextResolver: { _, _, _ in nil },
            answerProvider: answerProvider,
            promptProvider: promptProvider)
        panel.followInterval = .seconds(3_600)
        panel.followDebounce = .zero
        return panel
    }

    private func waitForCompaction(
        _ panel: AIPanelModel
    ) async -> ConversationCompaction? {
        let deadline = ContinuousClock.now + .seconds(3)
        while panel.compaction == nil, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch { return nil }
        }
        return panel.compaction
    }

    private func isFailed(_ state: AIPanelModel.CompactionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @Test("the latest compaction survives a panel restart")
    func loadsCompaction() async throws {
        let directory = try temporaryDirectory("panel-compaction")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        let (conversation, stored) = try seededConversation(archive)
        _ = try archive.saveCompaction(
            conversationID: conversation.id,
            throughTurnID: stored[1].id, summary: "stored summary",
            provider: "test", model: nil)

        let model = model(in: directory)
        let panel = panel(model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        #expect(panel.turns.count == 5)
        #expect(panel.compaction?.summary == "stored summary")
        #expect(panel.compactionCoveredTurnCount == 2)
    }

    @Test("manual compaction succeeds without deleting a turn")
    func manualCompaction() async throws {
        let directory = try temporaryDirectory("panel-manual")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        let (conversation, _) = try seededConversation(archive)
        let model = model(in: directory)
        let panel = panel(
            model: model, promptProvider: { _, _ in
                AIAnswer(text: "manual summary", provider: "test")
            })
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        #expect(panel.canCompact)

        panel.compactConversation()
        let result = await waitForCompaction(panel)
        #expect(result?.summary == "manual summary")
        #expect(panel.turns.count == 5)
        #expect(try archive.conversationTurns(
            conversationID: conversation.id).count == 5)
    }

    @Test("a failed manual compaction keeps the old projection")
    func failedCompactionPreservesProjection() async throws {
        let directory = try temporaryDirectory("panel-compaction-fail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        _ = try seededConversation(archive)
        let model = model(in: directory)
        let panel = panel(
            model: model, promptProvider: { _, _ in
                throw AIProviderError.unreachable
            })
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        panel.compactConversation()
        let deadline = ContinuousClock.now + .seconds(3)
        while !isFailed(panel.compactionState),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(isFailed(panel.compactionState))
        #expect(panel.compactionError != nil)
        #expect(panel.compaction == nil)
        #expect(panel.turns.count == 5)
    }

    @Test("a failed recompaction keeps the previous summary")
    func failedRecompactionPreservesSummary() async throws {
        let directory = try temporaryDirectory("panel-recompact-fail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        let (conversation, stored) = try seededConversation(
            archive, turns: 8)
        _ = try archive.saveCompaction(
            conversationID: conversation.id,
            throughTurnID: stored[1].id, summary: "old summary",
            provider: "test", model: nil)
        let model = model(in: directory)
        let panel = panel(
            model: model, promptProvider: { _, _ in
                throw AIProviderError.unreachable
            })
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        #expect(panel.compaction?.summary == "old summary")
        #expect(panel.canCompact)

        panel.compactConversation()
        let deadline = ContinuousClock.now + .seconds(3)
        while !isFailed(panel.compactionState),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(isFailed(panel.compactionState))
        #expect(panel.compactionError != nil)
        #expect(panel.compaction?.summary == "old summary")
        #expect(panel.turns.count == 8)
    }

    @Test("automatic compaction runs before a large send")
    func automaticCompaction() async throws {
        let directory = try temporaryDirectory("panel-auto")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        _ = try seededConversation(archive, turns: 4)
        let model = model(in: directory)
        model.settings.autoCompact = true
        model.settings.compactThresholdCharacters = 1_000
        let counter = AnswerCounter()
        let panel = panel(
            model: model,
            promptProvider: { _, _ in
                AIAnswer(text: "automatic summary", provider: "test")
            },
            answerProvider: { _, _ in
                await counter.increment()
                return AIAnswer(text: "new answer", provider: "test")
            })
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        panel.question = "next question"
        panel.run()
        let result = await waitForCompaction(panel)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await counter.value >= 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let count = await counter.value
        #expect(result?.summary == "automatic summary")
        #expect(count == 1)
        #expect(panel.turns.count == 5)
    }

    @Test("automatic compaction failure blocks the send")
    func automaticCompactionFailureBlocksSend() async throws {
        let directory = try temporaryDirectory("panel-auto-fail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        _ = try seededConversation(archive, turns: 4)
        let model = model(in: directory)
        model.settings.autoCompact = true
        model.settings.compactThresholdCharacters = 1_000
        let counter = AnswerCounter()
        let panel = panel(
            model: model,
            promptProvider: { _, _ in
                throw AIProviderError.unreachable
            },
            answerProvider: { _, _ in
                await counter.increment()
                return AIAnswer(text: "new answer", provider: "test")
            })
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        panel.question = "next question"
        panel.run()
        let deadline = ContinuousClock.now + .seconds(3)
        while !isFailed(panel.compactionState),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(isFailed(panel.compactionState))
        #expect(panel.compactionError != nil)
        let count = await counter.value
        #expect(count == 0)
        #expect(panel.turns.count == 4)
    }

    @Test("a failed save can be retried, and New Chat drops it")
    func failedSaveRetry() async throws {
        let directory = try temporaryDirectory("panel-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        let (conversation, _) = try seededConversation(archive)
        let model = model(in: directory)
        model.settings.autoCompact = false
        let panel = panel(model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        panel.failNextPersistenceForTesting = true
        panel.question = "save me"
        panel.run()
        let deadline = ContinuousClock.now + .seconds(3)
        while !panel.canRetrySave, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.canRetrySave)
        #expect(panel.saveError != nil)

        panel.retrySave()
        let retryDeadline = ContinuousClock.now + .seconds(3)
        while (panel.canRetrySave || panel.persisting),
            ContinuousClock.now < retryDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!panel.canRetrySave)
        #expect(panel.saveError == nil)
        #expect(try archive.conversationTurns(
            conversationID: conversation.id).count == 6)

        panel.failNextPersistenceForTesting = true
        panel.question = "new chat drops this"
        panel.run()
        let secondDeadline = ContinuousClock.now + .seconds(3)
        while !panel.canRetrySave, ContinuousClock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.canRetrySave)
        panel.newChat()
        #expect(!panel.canRetrySave)
    }

    @Test("cancelling a compaction keeps the transcript")
    func cancelCompaction() async throws {
        let directory = try temporaryDirectory("panel-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        _ = try seededConversation(archive)
        let model = model(in: directory)
        model.settings.autoCompact = false
        let panel = panel(
            model: model, promptProvider: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return AIAnswer(text: "late", provider: "test")
            })
        panel.loadPage()
        await panel.awaitPageLoad()
        panel.compactConversation()
        let deadline = ContinuousClock.now + .seconds(2)
        while panel.compactionState != .running,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.compactionState == .running)
        panel.cancel()
        #expect(panel.compaction == nil)
        #expect(panel.turns.count == 5)
    }

    @Test("continuing a chat carries its book and conversation")
    func continueRoute() throws {
        let directory = try temporaryDirectory("panel-continue")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(in: directory)
        let book = Book(
            asin: "B0ASIN0001", title: "The Book", author: "A",
            bookType: 10, readState: 0, source: .kindle)
        var received: AppModel.PendingCompanionChat?
        model.openCompanionChat = { received = $0 }
        model.continueChat(book: book, conversationID: 42)
        #expect(received?.bookID == "B0ASIN0001")
        #expect(received?.bookSource == .kindle)
        #expect(received?.conversationID == 42)
    }

    @Test("a route from another book is refused")
    func refusesAnotherBooksChat() async throws {
        let directory = try temporaryDirectory("panel-route")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        let conversation = try archive.createConversation(
            bookKey: "OTHER", bookTitle: "Other", bookSource: .kindle)
        let model = model(in: directory)
        let panel = panel(model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        panel.openConversation(
            conversation.id, expectedBookKey: "OTHER")
        #expect(panel.conversationID == nil)
        #expect(panel.sendNote?.contains("another book") == true)
    }

    @Test("deleting the open chat resets the panel")
    func deletionResetsPanel() async throws {
        let directory = try temporaryDirectory("panel-delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        let (conversation, _) = try seededConversation(archive)
        let model = model(in: directory)
        let panel = panel(model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        #expect(panel.conversationID == conversation.id)
        model.markConversationsDeleted([conversation.id])
        let deadline = ContinuousClock.now + .seconds(2)
        while panel.conversationID != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.conversationID == nil)
        #expect(panel.turns.isEmpty)
    }

    @Test("deleting the open chat keeps an unsaved answer for retry")
    func deletionKeepsUnsavedAnswer() async throws {
        let directory = try temporaryDirectory("panel-delete-unsaved")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        let (conversation, _) = try seededConversation(archive)
        let model = model(in: directory)
        let panel = panel(model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        panel.failNextPersistenceForTesting = true
        panel.question = "keep me"
        panel.run()
        let deadline = ContinuousClock.now + .seconds(3)
        while !panel.canRetrySave, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.canRetrySave)

        try archive.deleteConversations(ids: [conversation.id])
        model.markConversationsDeleted([conversation.id])
        let resetDeadline = ContinuousClock.now + .seconds(2)
        while panel.conversationID != nil,
            ContinuousClock.now < resetDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.conversationID == nil)
        #expect(panel.canRetrySave)
        #expect(panel.saveError?.contains("deleted") == true)

        panel.retrySave()
        let retryDeadline = ContinuousClock.now + .seconds(3)
        while (panel.canRetrySave || panel.persisting),
            ContinuousClock.now < retryDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!panel.canRetrySave)
        #expect(panel.saveError == nil)
        let remaining = try archive.conversations(bookKey: "B0ASIN0001")
        #expect(remaining.count == 1)
        #expect(
            try archive.conversationTurns(
                conversationID: remaining[0].id).count == 1)
    }

    @Test("deleting the current chat from the panel keeps an unsaved answer")
    func panelDeleteKeepsUnsavedAnswer() async throws {
        let directory = try temporaryDirectory("panel-delete-unsaved-current")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        _ = try seededConversation(archive)
        let model = model(in: directory)
        let panel = panel(model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        panel.failNextPersistenceForTesting = true
        panel.question = "keep me too"
        panel.run()
        let deadline = ContinuousClock.now + .seconds(3)
        while !panel.canRetrySave, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.canRetrySave)

        panel.reviewCurrentChatDeletion()
        let reviewDeadline = ContinuousClock.now + .seconds(3)
        while panel.deletionImpact == nil,
            ContinuousClock.now < reviewDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.deletionImpact != nil)
        panel.deleteCurrentChat()
        let deleteDeadline = ContinuousClock.now + .seconds(3)
        while panel.conversationID != nil,
            ContinuousClock.now < deleteDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.conversationID == nil)
        #expect(panel.canRetrySave)

        panel.retrySave()
        let retryDeadline = ContinuousClock.now + .seconds(3)
        while (panel.canRetrySave || panel.persisting),
            ContinuousClock.now < retryDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!panel.canRetrySave)
        let remaining = try archive.conversations(bookKey: "B0ASIN0001")
        #expect(remaining.count == 1)
        #expect(
            try archive.conversationTurns(
                conversationID: remaining[0].id).count == 1)
    }

    @Test("a save that loses its chat retargets instead of failing forever")
    func failedSaveRetargetsAfterDeletion() async throws {
        let directory = try temporaryDirectory("panel-race-delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        let (conversation, _) = try seededConversation(archive)
        let model = model(in: directory)
        let panel = panel(model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        panel.failNextPersistenceForTesting = true
        panel.question = "raced answer"
        panel.run()
        let deadline = ContinuousClock.now + .seconds(3)
        while !panel.canRetrySave, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.canRetrySave)

        // The chat is gone but the panel has not been told yet; retrying
        // into the deleted row must not fail forever.
        try archive.deleteConversations(ids: [conversation.id])
        panel.retrySave()
        let retargetDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < retargetDeadline {
            if panel.canRetrySave,
                panel.saveError?.contains("deleted") == true
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.canRetrySave)
        #expect(panel.saveError?.contains("deleted") == true)
        #expect(panel.conversationID == nil)

        panel.retrySave()
        let retryDeadline = ContinuousClock.now + .seconds(3)
        while (panel.canRetrySave || panel.persisting),
            ContinuousClock.now < retryDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!panel.canRetrySave)
        let remaining = try archive.conversations(bookKey: "B0ASIN0001")
        #expect(remaining.count == 1)
        #expect(
            try archive.conversationTurns(
                conversationID: remaining[0].id).count == 1)
    }

    @Test("opening a stored chat does not discard session-only answers")
    func openChatKeepsSessionOnlyTurns() async throws {
        let directory = try temporaryDirectory("panel-session-turns")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        let (conversation, _) = try seededConversation(archive)
        let model = model(in: directory)
        let anonymous = ReaderPage(
            text: String(repeating: "page words ", count: 40),
            title: "Kindle", kind: .kindle, source: .accessibility,
            pageNumber: 1, pageCount: 300, identifier: nil)
        let panel = AIPanelModel(
            app: model,
            context: FixedReader(kind: .kindle, pageValue: anonymous),
            contextResolver: { _, _, _ in nil },
            answerProvider: { _, _ in
                AIAnswer(text: "session answer", provider: "test")
            })
        panel.followInterval = .seconds(3_600)
        panel.followDebounce = .zero
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        #expect(panel.bookKey == nil)

        panel.question = "unsaved question"
        panel.run()
        let deadline = ContinuousClock.now + .seconds(3)
        while panel.turns.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.turns.count == 1)
        #expect(panel.turns.first?.persistedID == nil)

        panel.openConversation(conversation.id)
        #expect(panel.sendNote?.contains("not saved") == true)
        #expect(panel.turns.count == 1)
    }

    @Test("retention notifies open views of the chats it deleted")
    func retentionNotifiesDeletedChats() async throws {
        let directory = try temporaryDirectory("panel-retention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try self.archive(in: directory)
        // Open the model before any old chat exists: a launch cleanup from a
        // persisted retention policy must not consume this test's data.
        let model = model(in: directory)
        defer {
            model.settings.chatRetentionDays = 0
            model.settings.chatRetentionConfirmed = false
            model.settings.chatRetentionConfirmedDays = 0
        }
        let (conversation, _) = try seededConversation(archive)
        let database = try SQLiteDatabase(
            path: directory.appendingPathComponent("archive.sqlite").path)
        try database.execute(
            "UPDATE conversations SET updated_at = 1000 WHERE id = ?",
            [.integer(conversation.id)])
        model.settings.chatRetentionDays = 30
        model.reviewChatRetention()
        let reviewDeadline = ContinuousClock.now + .seconds(3)
        while model.retentionImpact == nil,
            ContinuousClock.now < reviewDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.retentionImpact?.conversations == 1)

        model.performChatRetention()
        let deleteDeadline = ContinuousClock.now + .seconds(3)
        while !model.deletedConversationIDs.contains(conversation.id),
            ContinuousClock.now < deleteDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.deletedConversationIDs.contains(conversation.id))
        #expect(try archive.conversation(id: conversation.id) == nil)
        #expect(model.settings.chatRetentionConfirmed)
    }
}
