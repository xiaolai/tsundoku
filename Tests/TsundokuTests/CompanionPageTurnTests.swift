import Foundation
import Testing

@testable import TsundokuCore
@testable import TsundokuUI

@MainActor
@Suite("Companion page turns", .timeLimit(.minutes(1)))
struct CompanionPageTurnTests {
    private final class SteppingReader: ReaderContext, @unchecked Sendable {
        let kind: ReaderKind
        private let lock = NSLock()
        private var pages: [ReaderPage]
        private var index = 0
        private var failingReads = false

        init(kind: ReaderKind, pages: [ReaderPage]) {
            self.kind = kind
            self.pages = pages
        }

        func page() throws -> ReaderPage {
            lock.lock()
            defer { lock.unlock() }
            if failingReads {
                throw ReaderContextError.noReaderWindow(.kindle)
            }
            return pages[min(index, pages.count - 1)]
        }

        func failReads(_ value: Bool) {
            lock.lock()
            failingReads = value
            lock.unlock()
        }

        func selectedText() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return pages[min(index, pages.count - 1)].selection
        }

        func show(_ index: Int) {
            lock.lock()
            self.index = index
            lock.unlock()
        }

        func setSelection(_ selection: String?) {
            lock.lock()
            let current = pages[index]
            pages[index] = ReaderPage(
                text: current.text, title: current.title, kind: current.kind,
                source: current.source, pageNumber: current.pageNumber,
                pageCount: current.pageCount, identifier: current.identifier,
                selection: selection)
            lock.unlock()
        }
    }

    private func page(_ number: Int, asin: String = "B0ASIN0001") -> ReaderPage {
        ReaderPage(
            text: String(
                repeating: "page \(number) words ", count: 20),
            title: "Kindle", kind: .kindle, source: .accessibility,
            pageNumber: number, pageCount: 300, identifier: asin)
    }

    private func model(in directory: URL) throws -> AppModel {
        AppModel(
            archiveURL: directory.appendingPathComponent("archive.sqlite"),
            kindlePaths: KindlePaths(
                container: directory.appendingPathComponent("missing")),
            booksPaths: BooksPaths(
                container: directory.appendingPathComponent("missing")),
            recoverReaderSettings: false)
    }

    /// Bounded so a persistence regression fails the test instead of
    /// defeating the suite's cooperative time limit.
    /// Waits until the write and the conversation refresh it triggers have
    /// settled. The panel refuses a send while it re-reads a transcript, so
    /// a test that sends again must wait for that window to close.
    /// Sends only when the panel would let a reader press Send. The UI
    /// disables the button while the panel is busy; a test that calls send()
    /// inside that window gets its message dropped by the guard in run(),
    /// which is not a product defect but does make the test racy under load.
    private func sendWhenReady(
        _ panel: AIPanelModel, scope: CompanionScope, question: String
    ) async {
        // The question is set first: canSend is false until there is one.
        panel.scope = scope
        panel.question = question
        let deadline = ContinuousClock.now + .seconds(10)
        while !panel.canSend, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.canSend, "the panel never accepted a send")
        panel.send()
    }

    private func awaitPersistence(_ panel: AIPanelModel) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while (panel.persisting || !panel.canRun),
            ContinuousClock.now < deadline
        {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                Issue.record("persistence wait was cancelled")
                return
            }
        }
        #expect(!panel.persisting)
    }

    private func panel(
        reader: any ReaderContext, model: AppModel,
        answer: @escaping AIPanelModel.AnswerProvider = { _, _ in
            AIAnswer(text: "answer", provider: "test")
        }
    ) -> AIPanelModel {
        let panel = AIPanelModel(
            app: model, context: reader,
            contextResolver: { page, _, _ in
                ReadingContextResolver.Result(
                    chapter: "Ch. \(page.pageNumber ?? 0)",
                    pageNumber: page.pageNumber, fingerprint: nil,
                    capture: nil)
            },
            answerProvider: answer)
        // The test drives each turn explicitly; a long interval keeps the
        // background loop from racing it.
        panel.followInterval = .seconds(3_600)
        panel.followDebounce = .zero
        return panel
    }

    @Test("three page turns move the chips with the page")
    func threeTurns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-turns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(
            kind: .kindle,
            pages: [page(1), page(2), page(3), page(4)])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        #expect(panel.context.pageNumber == 1)
        #expect(panel.context.chapter == "Ch. 1")

        for number in 2...4 {
            reader.show(number - 1)
            await panel.followPageOnce()
            await panel.localContextTask?.value
            #expect(panel.context.pageNumber == number)
            #expect(panel.context.chapter == "Ch. \(number)")
        }
    }

    @Test("a page that did not move is not re-adopted on every follow")
    func stationaryPageIsNotATurn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-stationary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        // Kindle hides its own page number; the local index supplies one.
        let hidden = ReaderPage(
            text: String(repeating: "preface words ", count: 20),
            title: "Kindle", kind: .kindle, source: .accessibility,
            identifier: "B0ASIN0001")
        let reader = SteppingReader(
            kind: .kindle,
            pages: [
                hidden,
                ReaderPage(
                    text: String(repeating: "first chapter words ", count: 20),
                    title: "Kindle", kind: .kindle, source: .accessibility,
                    identifier: "B0ASIN0001"),
            ])
        let panel = AIPanelModel(
            app: model, context: reader,
            contextResolver: { _, _, _ in
                ReadingContextResolver.Result(
                    chapter: "Ch. 1", pageNumber: 7, fingerprint: nil,
                    capture: nil)
            },
            answerProvider: { _, _ in
                AIAnswer(text: "answer", provider: "test")
            })
        panel.followInterval = .seconds(3_600)
        panel.followDebounce = .zero
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        #expect(panel.context.pageNumber == 7)

        await panel.followPageOnce()
        await panel.followPageOnce()
        #expect(panel.followedTurns == 0, "a stationary page is not a turn")

        reader.show(1)
        await panel.followPageOnce()
        #expect(panel.followedTurns == 1)
    }

    @Test("a page turn away from a captured page keeps its chat")
    func fingerprintKeySurvivesPageTurn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-keep-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let archive = try #require(model.archive)
        let conversation = try archive.createConversation(
            bookKey: "text:f00d", bookTitle: "Captured", bookSource: .kindle)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .ask, question: "Old",
            answer: "Answer", provider: "p", prompt: "", context: .empty)

        let first = ReaderPage(
            text: String(repeating: "first page words ", count: 20),
            title: "Kindle", kind: .kindle, source: .accessibility)
        let second = ReaderPage(
            text: String(repeating: "second page words ", count: 20),
            title: "Kindle", kind: .kindle, source: .accessibility)
        let reader = SteppingReader(kind: .kindle, pages: [first, second])
        let panel = AIPanelModel(
            app: model, context: reader,
            contextResolver: { page, _, _ in
                guard page.text.contains("first") else { return nil }
                return ReadingContextResolver.Result(
                    chapter: nil, pageNumber: 1, fingerprint: "f00d",
                    capture: CaptureRecord(
                        id: 1, asin: "", title: "Captured",
                        directory: "/tmp/capture", pageCount: 100,
                        pdfPath: nil, createdAt: Date(), state: "complete",
                        source: "kindle", identityConfidence: "exact"))
            },
            answerProvider: { _, _ in
                AIAnswer(text: "answer", provider: "test")
            })
        panel.followInterval = .seconds(3_600)
        panel.followDebounce = .zero
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        #expect(panel.bookKey == "text:f00d")
        #expect(panel.turns.count == 1)

        reader.show(1)
        await panel.followPageOnce()
        await panel.awaitPageLoad()
        #expect(panel.bookKey == "text:f00d")
        #expect(panel.turns.count == 1)
    }

    @Test("stopping an answer leaves page following on")
    func stopAnswerKeepsFollowing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(kind: .kindle, pages: [page(1), page(2)])
        let panel = panel(reader: reader, model: model)
        panel.followInterval = .seconds(3_600)
        panel.followDebounce = .zero
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        panel.stopAnswer()
        reader.show(1)
        await panel.followPageOnce()
        #expect(panel.followedTurns == 1)
    }

    @Test("a sent turn keeps the page it was sent with")
    func sentTurnCaptionIsStable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-turn-caption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(kind: .kindle, pages: [page(1), page(2)])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        panel.turns = [
            AITurn(
                action: .ask, question: "Why?", answer: "Because.",
                provider: "p", prompt: "prompt",
                context: AIContext(
                    bookTitle: "Kindle", reader: .kindle, pageNumber: 1))
        ]
        reader.show(1)
        await panel.followPageOnce()
        await panel.localContextTask?.value
        #expect(panel.context.pageNumber == 2)
        #expect(panel.turns.first?.context.pageNumber == 1)
    }

    @Test("a page turn refreshes the selection and a same-page change is picked up")
    func selectionRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(kind: .kindle, pages: [page(1), page(2)])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        reader.setSelection("page 1 words")
        await panel.followPageOnce()
        #expect(panel.context.selection == "page 1 words")

        reader.show(1)
        await panel.followPageOnce()
        await panel.localContextTask?.value
        #expect(panel.context.selection == nil)
    }

    @Test("a turn that changes the book starts the new book's history")
    func bookChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-book-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(
            kind: .kindle,
            pages: [page(1), page(2, asin: "B0ASIN0002")])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }
        panel.turns = [
            AITurn(
                action: .ask, question: "Old", answer: "Answer",
                provider: "p", prompt: "", context: .empty)
        ]
        reader.show(1)
        await panel.followPageOnce()
        await panel.awaitPageLoad()
        #expect(panel.bookKey == "B0ASIN0002")
        #expect(panel.turns.isEmpty)
    }

    @Test("a page turn before sending sends the new page, never the old one")
    func sendUsesTheFreshPage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-fresh-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(kind: .kindle, pages: [page(1), page(2)])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        reader.show(1)
        panel.question = "What does this mean?"
        panel.send()
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()

        #expect(panel.lastFreshness == .refreshed(2))
        #expect(panel.sendNote?.contains("page 2") == true)
        let turn = try #require(panel.turns.last)
        #expect(turn.context.pageNumber == 2)
        #expect(turn.answer == "answer")
        #expect(turn.context.excerpt.hasPrefix("page 2"))
    }

    @Test("a send is refused when the reader moved to another book")
    func bookChangeAbortsSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-book-abort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(
            kind: .kindle, pages: [page(1), page(2, asin: "B0ASIN0002")])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        reader.show(1)
        panel.question = "What does this mean?"
        panel.send()
        await panel.sendPreparationTask?.value

        #expect(panel.lastFreshness == .bookChanged)
        #expect(panel.sendNote?.contains("another book") == true)
        #expect(panel.turns.isEmpty)
        #expect(panel.phase != .loadingAnswer)
    }

    @Test("a failed answer is retried against the page the reader is on")
    func retryUsesCurrentPage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(
            kind: .kindle, pages: [page(1), page(2)])
        let log = RequestLog()
        let failsOnce = FailOnce()
        let panel = panel(
            reader: reader, model: model,
            answer: { request, _ in
                log.append(request)
                if failsOnce.take() { throw TemporaryFailure() }
                return AIAnswer(text: "answer", provider: "test")
            })
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        panel.question = "What does this mean?"
        panel.send()
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()
        #expect(panel.phase == .failed)
        #expect(panel.pendingQuestion == nil)

        // The reader turns the page before retrying. The question stays the
        // same; the page it is asked about does not.
        reader.show(1)
        panel.retry()
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()

        #expect(panel.phase == .ready)
        let retried = try #require(log.requests.last)
        #expect(retried.question == "What does this mean?")
        #expect(retried.pageText.contains("page 2 words"))
        #expect(!retried.pageText.contains("page 1 words"))
    }

    @Test("a downgraded chapter retry asks for the chapter, not the page")
    func retryKeepsTheRequestedScope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-retry-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(kind: .kindle, pages: [page(1)])
        let log = RequestLog()
        let failsOnce = FailOnce()
        // No capture resolves, so a chapter request is downgraded to the page
        // and says so. Retry must ask for the chapter again; if it remembered
        // the downgraded scope, the note would disappear.
        let panel = panel(
            reader: reader, model: model,
            answer: { request, _ in
                log.append(request)
                if failsOnce.take() { throw TemporaryFailure() }
                return AIAnswer(text: "answer", provider: "test")
            })
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        await sendWhenReady(
            panel, scope: .currentChapter, question: "Summarize the chapter")
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()
        #expect(panel.phase == .failed)
        #expect(panel.sendNote?.contains("sent instead") == true)

        panel.retry()
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()

        #expect(panel.phase == .ready)
        // A retry that asked for the page would not say the chapter is
        // missing; only a chapter request is downgraded and reported.
        #expect(panel.sendNote?.contains("sent instead") == true)
    }

    private struct TemporaryFailure: Error {}

    private final class FailOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }

    @Test("an unreadable page is sent with a visible note")
    func unreadablePageSendsWithNote() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(kind: .kindle, pages: [page(1)])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        reader.failReads(true)
        panel.question = "What does this mean?"
        panel.send()
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()

        #expect(panel.lastFreshness == .unconfirmed)
        #expect(panel.sendNote?.contains("Could not confirm") == true)
        #expect(panel.turns.last?.context.pageNumber == 1)
    }

    @Test("a reader asset ID adopts a duplicate edition and moves its chat")
    func duplicateEditionAssetID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-duplicate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let editions = [
            Book(
                asin: "ASSET-A", title: "Alice", author: "A", bookType: 10,
                readState: 0, source: .appleBooks),
            Book(
                asin: "ASSET-B", title: "Alice", author: "A", bookType: 10,
                readState: 0, source: .appleBooks),
        ]
        model.books = editions
        let archive = try #require(model.archive)
        _ = try archive.importAll(books: editions, annotations: [])
        let conversation = try archive.createConversation(
            bookKey: "ASSET-A", bookTitle: "Alice",
            bookSource: .appleBooks)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .explain, question: "",
            answer: "Old answer", provider: "p", prompt: "", context: .empty)

        let first = ReaderPage(
            text: String(repeating: "first page words ", count: 20),
            title: "Alice", kind: .appleBooks, source: .accessibility,
            pageNumber: 1, pageCount: 100)
        let second = ReaderPage(
            text: String(repeating: "second page words ", count: 20),
            title: "Alice", kind: .appleBooks, source: .accessibility,
            pageNumber: 2, pageCount: 100, identifier: "ASSET-B")
        let reader = SteppingReader(kind: .appleBooks, pages: [first, second])
        let panel = AIPanelModel(
            app: model, context: reader,
            contextResolver: { page, _, _ in
                ReadingContextResolver.Result(
                    chapter: nil, pageNumber: page.pageNumber,
                    fingerprint: nil, capture: nil,
                    assetID: page.pageNumber == 1 ? "ASSET-A" : nil)
            })
        panel.followInterval = .seconds(3_600)
        panel.followDebounce = .zero

        panel.loadPage()
        await panel.awaitPageLoad()
        await panel.localContextTask?.value
        defer { panel.cancel() }
        #expect(panel.bookKey == "ASSET-A")
        #expect(panel.identity?.evidence == .archiveEPUB)
        #expect(panel.identity?.book?.asin == "ASSET-A")
        #expect(panel.turns.count == 1)

        reader.show(1)
        await panel.followPageOnce()
        await panel.localContextTask?.value

        #expect(panel.bookKey == "ASSET-B")
        #expect(panel.turns.count == 1, "the chat must move, not clear")
        #expect(try archive.latestConversation(bookKey: "ASSET-A") == nil)
        #expect(
            try archive.latestConversation(bookKey: "ASSET-B")?.id
                == conversation.id)
    }

    @Test("a same-title book by another author starts a new chat")
    func sameTitleDifferentAuthor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-same-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let editions = [
            Book(
                asin: "ASSET-A", title: "Alice", author: "Author A",
                bookType: 10, readState: 0, source: .appleBooks),
            Book(
                asin: "ASSET-B", title: "Alice", author: "Author B",
                bookType: 10, readState: 0, source: .appleBooks),
        ]
        model.books = editions
        let archive = try #require(model.archive)
        _ = try archive.importAll(books: editions, annotations: [])
        let conversation = try archive.createConversation(
            bookKey: "ASSET-A", bookTitle: "Alice",
            bookSource: .appleBooks)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .explain, question: "",
            answer: "Old answer", provider: "p", prompt: "", context: .empty)

        let first = ReaderPage(
            text: String(repeating: "first page words ", count: 20),
            title: "Alice", kind: .appleBooks, source: .accessibility,
            pageNumber: 1, pageCount: 100)
        let second = ReaderPage(
            text: String(repeating: "second page words ", count: 20),
            title: "Alice", kind: .appleBooks, source: .accessibility,
            pageNumber: 2, pageCount: 100, identifier: "ASSET-B")
        let reader = SteppingReader(kind: .appleBooks, pages: [first, second])
        let panel = AIPanelModel(
            app: model, context: reader,
            contextResolver: { page, _, _ in
                ReadingContextResolver.Result(
                    chapter: nil, pageNumber: page.pageNumber,
                    fingerprint: nil, capture: nil,
                    assetID: page.pageNumber == 1 ? "ASSET-A" : nil)
            })
        panel.followInterval = .seconds(3_600)
        panel.followDebounce = .zero

        panel.loadPage()
        await panel.awaitPageLoad()
        await panel.localContextTask?.value
        defer { panel.cancel() }

        reader.show(1)
        await panel.followPageOnce()
        await panel.localContextTask?.value

        #expect(panel.bookKey == "ASSET-B")
        #expect(panel.turns.isEmpty, "another author's book must not inherit")
        #expect(
            try archive.latestConversation(bookKey: "ASSET-A")?.id
                == conversation.id)
    }

    @Test("an unarchived identifier after an EPUB match starts a new chat")
    func unarchivedIdentifierAfterEPUB() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-unarchived-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let editions = [
            Book(
                asin: "ASSET-A", title: "Alice", author: "Author A",
                bookType: 10, readState: 0, source: .appleBooks)
        ]
        model.books = editions
        let archive = try #require(model.archive)
        _ = try archive.importAll(books: editions, annotations: [])
        let conversation = try archive.createConversation(
            bookKey: "ASSET-A", bookTitle: "Alice",
            bookSource: .appleBooks)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .explain, question: "",
            answer: "Old answer", provider: "p", prompt: "", context: .empty)

        let first = ReaderPage(
            text: String(repeating: "first page words ", count: 20),
            title: "Alice", kind: .appleBooks, source: .accessibility,
            pageNumber: 1, pageCount: 100)
        let second = ReaderPage(
            text: String(repeating: "second page words ", count: 20),
            title: "Unknown", kind: .appleBooks, source: .accessibility,
            pageNumber: 2, pageCount: 100, identifier: "ASSET-B")
        let reader = SteppingReader(kind: .appleBooks, pages: [first, second])
        let panel = AIPanelModel(
            app: model, context: reader,
            contextResolver: { page, _, _ in
                ReadingContextResolver.Result(
                    chapter: nil, pageNumber: page.pageNumber,
                    fingerprint: nil, capture: nil,
                    assetID: page.pageNumber == 1 ? "ASSET-A" : nil)
            })
        panel.followInterval = .seconds(3_600)
        panel.followDebounce = .zero

        panel.loadPage()
        await panel.awaitPageLoad()
        await panel.localContextTask?.value
        defer { panel.cancel() }

        reader.show(1)
        await panel.followPageOnce()
        await panel.localContextTask?.value

        #expect(panel.bookKey == "ASSET-B")
        #expect(panel.turns.isEmpty, "an unproven identifier is not the old book")
        #expect(
            try archive.latestConversation(bookKey: "ASSET-A")?.id
                == conversation.id)
    }

    @Test("the context scope decides whether the selection is sent")
    func scopeControlsSelection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let selection = "Alice was beginning to get very tired"
        let first = ReaderPage(
            text: String(repeating: selection + " ", count: 5),
            title: "Alice", kind: .appleBooks, source: .accessibility,
            pageNumber: 1, pageCount: 100, selection: selection)
        let reader = SteppingReader(kind: .appleBooks, pages: [first])
        let log = RequestLog()
        let panel = panel(reader: reader, model: model) { request, _ in
            log.append(request)
            return AIAnswer(text: "answer", provider: "test")
        }
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        #expect(panel.scope == .currentPage)
        #expect(panel.selectionAvailable)

        panel.question = "Explain this"
        panel.send()
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()
        await awaitPersistence(panel)
        #expect(panel.turns.last?.context.selection == nil)

        panel.scope = .selection
        panel.question = "Explain the selection"
        panel.send()
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()
        #expect(panel.turns.last?.context.selection == selection)
        let requests = log.requests
        try #require(requests.count == 2)
        #expect(requests[0].selection == nil)
        #expect(requests[1].selection == selection)
    }

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AIRequest] = []

        func append(_ request: AIRequest) {
            lock.lock()
            stored.append(request)
            lock.unlock()
        }

        var requests: [AIRequest] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    @Test("choosing Selection reads the reader's selection")
    func choosingSelectionReadsIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-choose-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let selection = "page words page words"
        let first = ReaderPage(
            text: String(repeating: "page words ", count: 20),
            title: "Alice", kind: .appleBooks, source: .accessibility,
            pageNumber: 1, pageCount: 100)
        let reader = SteppingReader(kind: .appleBooks, pages: [first])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        #expect(panel.scope == .currentPage)
        #expect(!panel.selectionAvailable)
        // The selection is made after the page loaded; only a real refresh
        // can see it.
        reader.setSelection(selection)
        panel.chooseScope(.selection)
        await panel.awaitSelectionRefresh()
        #expect(panel.scope == .selection)
        #expect(panel.context.selection == selection)
        #expect(panel.selectionAvailable)
    }

    @Test("choosing Selection without one explains how to make it")
    func choosingMissingSelection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-no-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(
            kind: .kindle, pages: [page(1)])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        panel.chooseScope(.selection)
        await panel.awaitSelectionRefresh()
        #expect(panel.scope == .selection)
        #expect(!panel.selectionAvailable)
        #expect(panel.sendNote?.contains("Copy action") == true)
    }

    @Test("a copied selection from another app is rejected")
    func rejectsForeignSelection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-foreign-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let first = ReaderPage(
            text: String(repeating: "page words ", count: 20),
            title: "Alice", kind: .kindle, source: .accessibility,
            pageNumber: 1, pageCount: 100)
        let reader = SteppingReader(kind: .kindle, pages: [first])
        let log = RequestLog()
        let panel = panel(reader: reader, model: model) { request, _ in
            log.append(request)
            return AIAnswer(text: "answer", provider: "test")
        }
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        reader.setSelection("unrelated clipboard text")
        panel.chooseScope(.selection)
        await panel.awaitSelectionRefresh()
        #expect(!panel.selectionAvailable)
        #expect(panel.context.selection == nil)
        #expect(panel.sendNote?.contains("did not match this page") == true)

        // A later send must not resurrect the rejected text via page
        // confirmation.
        panel.question = "Explain"
        panel.send()
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()
        #expect(log.requests.isEmpty)
    }

    @Test("selection provenance accepts only page-matching words")
    func foreignSelectionWords() {
        #expect(
            SelectionText.belongs(
                "Momentum is a value",
                toPage: "Momentum is a value that pushes."))
        #expect(
            !SelectionText.belongs(
                "unrelated clipboard", toPage: "page words page words"))
        #expect(
            SelectionText.belongs(
                "中文片段", toPage: "这一页包含中文片段和更多文字"))
        #expect(
            !SelectionText.belongs(
                "中文 test", toPage: "这一页包含中文 testing 和更多文字"))
        #expect(
            SelectionText.belongs(
                "中文片段", toPage: "这一页包含中文\n片段和更多文字"))
        // Short technical terms are real selections; symbols are evidence.
        #expect(SelectionText.belongs("AI", toPage: "AI is a field."))
        #expect(SelectionText.belongs("cat", toPage: "The cat sat."))
        #expect(!SelectionText.belongs("$100", toPage: "The rate is 100%."))
        #expect(SelectionText.belongs("100%", toPage: "The rate is 100%."))
        #expect(!SelectionText.belongs("!!!a", toPage: "a"))
        #expect(SelectionText.belongs("C++", toPage: "C++ is a language."))
        #expect(SelectionText.belongs("C#", toPage: "C# and F# differ."))
        #expect(!SelectionText.belongs("10 - 5", toPage: "10 + 5 is 15."))
        #expect(!SelectionText.belongs("   ", toPage: "page words"))
        // Boundary-aware: a phrase that only occurs inside longer words is
        // not provenance, and a single character identifies nothing.
        #expect(!SelectionText.belongs("is a", toPage: "This argument holds."))
        #expect(!SelectionText.belongs("a", toPage: "a"))
        #expect(
            SelectionText.belongs("momentum", toPage: "Momentum matters."))
        #expect(!SelectionText.belongs("moment", toPage: "Momentum matters."))
    }

    @Test("a persisted answer becomes a card and stays one")
    func answerBecomesCard() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let archive = try #require(model.archive)
        let book = Book(
            asin: "B0ASIN0001", title: "The Book", author: "A",
            bookType: 10, readState: 0, source: .kindle)
        _ = try archive.importAll(books: [book], annotations: [])
        model.books = [book]
        let reader = SteppingReader(
            kind: .kindle, pages: [page(1)])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        panel.question = "What is momentum?"
        panel.send()
        await panel.sendPreparationTask?.value
        await panel.awaitAnswer()
        await awaitPersistence(panel)
        let turn = try #require(panel.turns.last)
        #expect(turn.persistedID != nil)

        panel.addToCards(turn)
        await panel.awaitCardSave()
        #expect(panel.isCarded(turn))
        let cards = try archive.aiCards()
        #expect(cards.count == 1)
        #expect(cards.first?.turnID == turn.persistedID)

        // A fresh panel reading the same book keeps the DB turn identity and
        // the card state; neither is rebuilt from the in-memory turn.
        let reopened = self.panel(reader: reader, model: model)
        reopened.loadPage()
        await reopened.awaitPageLoad()
        defer { reopened.cancel() }
        let reloaded = try #require(
            reopened.turns.first { $0.answer == "answer" })
        #expect(reloaded.persistedID == turn.persistedID)
        #expect(reopened.isCarded(reloaded))

        // Removing the card in the library updates the open panel, and the
        // same turn can be carded again.
        let stored = try #require(cards.first)
        model.removeAICard(stored)
        await model.awaitCardRemoval()
        #expect(!panel.isCarded(turn))
        panel.addToCards(turn)
        await panel.awaitCardSave()
        #expect(panel.isCarded(turn))
    }

    @Test("a card needs an archived book")
    func cardNeedsArchivedBook() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-card-no-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let archive = try #require(model.archive)
        let reader = SteppingReader(kind: .kindle, pages: [page(1)])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        #expect(!panel.canCard)
        let turn = AITurn(
            action: .ask, question: "Q", answer: "A", provider: "test",
            prompt: "prompt", persistedID: 1)
        panel.addToCards(turn)
        #expect(panel.saveError?.contains("single archived book") == true)
        #expect(try archive.aiCards().isEmpty)
    }

    @Test("a card waits for the turn to be persisted")
    func cardWaitsForTurn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-card-unpersisted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let archive = try #require(model.archive)
        let book = Book(
            asin: "B0ASIN0001", title: "The Book", author: "A",
            bookType: 10, readState: 0, source: .kindle)
        _ = try archive.importAll(books: [book], annotations: [])
        model.books = [book]
        let reader = SteppingReader(kind: .kindle, pages: [page(1)])
        let panel = panel(reader: reader, model: model)
        panel.loadPage()
        await panel.awaitPageLoad()
        defer { panel.cancel() }

        #expect(panel.canCard)
        let turn = AITurn(
            action: .ask, question: "Q", answer: "A", provider: "test",
            prompt: "prompt")
        panel.addToCards(turn)
        #expect(panel.saveError?.contains("still being saved") == true)
        #expect(try archive.aiCards().isEmpty)
    }

    @Test("a card routes to an explicit older conversation")
    func cardChatRoute() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-card-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let book = Book(
            asin: "B1", title: "A Book", author: "A", bookType: 10,
            readState: 0, source: .kindle)
        model.section = .highlights
        model.openChats(for: book, conversationID: 42, turnID: 7)
        #expect(model.section == .library)
        #expect(model.bookWorkspaceID == "B1")
        #expect(model.bookWorkspaceSection == .chats)
        let pending = try #require(model.takePendingChat(for: "B1"))
        #expect(pending.conversationID == 42)
        #expect(pending.turnID == 7)
        #expect(model.takePendingChat(for: "B1") == nil)
    }

    @Test("capture navigation never keeps an unrelated selected book")
    func captureNavigationClearsStaleBook() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-capture-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        model.selectedBookID = "STALE-BOOK"
        model.openCaptureExports(bookID: nil)
        #expect(model.selectedBookID == nil)
        #expect(model.section == .exports)

        model.selectedBookID = "STALE-BOOK"
        model.openCaptureExports(bookID: "NOT-IN-ARCHIVE")
        #expect(model.selectedBookID == nil)
        #expect(model.section == .exports)
    }

    private final class CopyOnlyReader: ReaderContext, @unchecked Sendable {
        let kind: ReaderKind = .kindle
        var pageValue: ReaderPage
        var selection: String

        init(page: ReaderPage, selection: String) {
            self.pageValue = page
            self.selection = selection
        }

        func page() throws -> ReaderPage { pageValue }
        func selectedText() -> String? { selection }
    }

    @Test("Kindle's Copy-only selection survives page confirmation and sends")
    func copyOnlySelectionSends() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-copy-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let selection = "page words page words"
        let page = ReaderPage(
            text: String(repeating: "page words ", count: 20),
            title: "Kindle", kind: .kindle, source: .accessibility,
            pageNumber: 1, pageCount: 100, selection: nil)
        let reader = CopyOnlyReader(page: page, selection: selection)
        let log = RequestLog()
        let panelModel = self.panel(reader: reader, model: model) { request, _ in
            log.append(request)
            return AIAnswer(text: "answer", provider: "test")
        }
        panelModel.loadPage()
        await panelModel.awaitPageLoad()
        defer { panelModel.cancel() }

        panelModel.chooseScope(.selection)
        await panelModel.awaitSelectionRefresh()
        #expect(panelModel.selectionAvailable)

        panelModel.question = "Explain the selection"
        panelModel.send()
        await panelModel.sendPreparationTask?.value
        await panelModel.awaitAnswer()
        #expect(log.requests.last?.selection == selection)
        // The page around a selection is sent too; the disclosure must say so.
        #expect(panelModel.transmissionLabel.contains("selection and page"))
        #expect(panelModel.transmissionDetail.contains("surrounding page"))
    }

    @Test("a retry that cannot start keeps the failure on screen")
    func retryRefusalKeepsTheFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-retry-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let selection = "page words page words"
        let page = ReaderPage(
            text: String(repeating: "page words ", count: 20),
            title: "Kindle", kind: .kindle, source: .accessibility,
            pageNumber: 1, pageCount: 100)
        let reader = CopyOnlyReader(page: page, selection: selection)
        let failsOnce = FailOnce()
        let panelModel = self.panel(reader: reader, model: model) {
            request, _ in
            if failsOnce.take() { throw TemporaryFailure() }
            return AIAnswer(text: "answer", provider: "test")
        }
        panelModel.loadPage()
        await panelModel.awaitPageLoad()
        defer { panelModel.cancel() }

        panelModel.chooseScope(.selection)
        await panelModel.awaitSelectionRefresh()
        panelModel.question = "Explain the selection"
        panelModel.send()
        await panelModel.sendPreparationTask?.value
        await panelModel.awaitAnswer()
        #expect(panelModel.phase == .failed)

        // The reader turns the page; Kindle's carried-over selection does
        // not survive a different page, and the saved request can no longer
        // be honoured.
        reader.selection = ""
        reader.pageValue = ReaderPage(
            text: String(repeating: "other page words ", count: 20),
            title: "Kindle", kind: .kindle, source: .accessibility,
            pageNumber: 2, pageCount: 100)

        // Retry re-reads the selection, finds none and refuses; the failure
        // must stay on screen with the reason.
        panelModel.retry()
        await panelModel.sendPreparationTask?.value

        // Not idle with an unsendable request: the failure and its Retry stay
        // on screen, with the reason.
        #expect(panelModel.phase == .failed)
        #expect(panelModel.sendNote?.contains("Nothing is selected") == true)
    }

    @Test("a chapter retry sends the chapter the reader is now in")
    func chapterRetryResolvesTheNewChapter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-chapter-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureDirectory = directory.appendingPathComponent("capture")
        try FileManager.default.createDirectory(
            at: captureDirectory, withIntermediateDirectories: true)
        let capturePages = [
            (1, "Ch. 1\nChapter one body text."),
            (2, "Ch. 2\nOther chapter body text."),
        ]
        let lines = capturePages.map { page, text in
            "{\"page\":\(page),\"text\":\"\(text.replacingOccurrences(of: "\n", with: "\\n"))\"}"
        }
        try lines.joined(separator: "\n").write(
            to: captureDirectory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        try "{\"complete\":{\"wholeBook\":true}}".write(
            to: captureDirectory.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        let record = CaptureRecord(
            id: 1, asin: "B0ASIN0001", title: "The Book",
            directory: captureDirectory.path, pageCount: 2, pdfPath: nil,
            createdAt: Date(), state: "finished", source: "kindle")
        let model = try model(in: directory)
        let reader = SteppingReader(kind: .kindle, pages: [page(1), page(2)])
        let log = RequestLog()
        let failsOnce = FailOnce()
        // The resolver follows the page, as the real one does; a fixed result
        // would pin the chapter and hide the very move under test.
        let panelModel = AIPanelModel(
            app: model, context: reader,
            contextResolver: { page, _, _ in
                ReadingContextResolver.Result(
                    chapter: "Ch. \(page.pageNumber ?? 0)",
                    pageNumber: page.pageNumber, fingerprint: "fp",
                    capture: record)
            },
            answerProvider: { request, _ in
                log.append(request)
                if failsOnce.take() { throw TemporaryFailure() }
                return AIAnswer(text: "answer", provider: "test")
            })
        panelModel.followInterval = .seconds(3_600)
        panelModel.followDebounce = .zero
        panelModel.loadPage()
        await panelModel.awaitPageLoad()
        defer { panelModel.cancel() }

        await sendWhenReady(
            panelModel, scope: .currentChapter,
            question: "Summarize the chapter")
        await panelModel.sendPreparationTask?.value
        await panelModel.awaitAnswer()
        #expect(panelModel.phase == .failed)
        let first = try #require(log.requests.last)
        #expect(first.pageText.contains("Chapter one body text."))

        // The reader moves into the second chapter before retrying: the
        // question is the same, the chapter it is asked about is not.
        reader.show(1)
        panelModel.retry()
        await panelModel.sendPreparationTask?.value
        await panelModel.awaitAnswer()

        #expect(panelModel.phase == .ready)
        let retried = try #require(log.requests.last)
        #expect(retried.scope == .currentChapter)
        #expect(retried.question == "Summarize the chapter")
        #expect(retried.pageText.contains("Other chapter body text."))
        #expect(!retried.pageText.contains("Chapter one body text."))
    }

    @Test("chapter and whole-book scopes send the matched capture text")
    func chapterAndBookScopes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-scope-success-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureDirectory = directory.appendingPathComponent("capture")
        try FileManager.default.createDirectory(
            at: captureDirectory, withIntermediateDirectories: true)
        let pages = [
            (1, "Ch. 1\nChapter one body text."),
            (2, "Ch. 2\nOther chapter body text."),
        ]
        let lines = pages.map { page, text in
            "{\"page\":\(page),\"text\":\"\(text.replacingOccurrences(of: "\n", with: "\\n"))\"}"
        }
        try lines.joined(separator: "\n").write(
            to: captureDirectory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        try "{\"complete\":{\"wholeBook\":true}}".write(
            to: captureDirectory.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        let record = CaptureRecord(
            id: 1, asin: "B0ASIN0001", title: "The Book",
            directory: captureDirectory.path, pageCount: 2, pdfPath: nil,
            createdAt: Date(), state: "finished", source: "kindle")
        let result = ReadingContextResolver.Result(
            chapter: "Ch. 1", pageNumber: 1, fingerprint: "fp",
            capture: record)
        let model = try model(in: directory)
        let page = ReaderPage(
            text: String(repeating: "page words ", count: 20),
            title: "Kindle", kind: .kindle, source: .accessibility,
            pageNumber: 1, pageCount: 100, identifier: "B0ASIN0001")
        let reader = SteppingReader(kind: .kindle, pages: [page])
        let log = RequestLog()
        let panelModel = AIPanelModel(
            app: model, context: reader,
            contextResolver: { _, _, _ in result },
            answerProvider: { request, _ in
                log.append(request)
                return AIAnswer(text: "answer", provider: "test")
            })
        panelModel.followInterval = .seconds(3_600)
        panelModel.followDebounce = .zero
        panelModel.loadPage()
        await panelModel.awaitPageLoad()
        defer { panelModel.cancel() }

        await sendWhenReady(
            panelModel, scope: .currentChapter,
            question: "Summarize the chapter")
        await panelModel.sendPreparationTask?.value
        await panelModel.awaitAnswer()
        let chapter = try #require(log.requests.last)
        #expect(chapter.scope == .currentChapter)
        #expect(chapter.pageText.contains("Chapter one body text."))
        #expect(!chapter.pageText.contains("Other chapter body text."))
        #expect(panelModel.sendNote?.contains("sent instead") != true)
        await awaitPersistence(panelModel)

        await sendWhenReady(
            panelModel, scope: .wholeBook, question: "Summarize the book")
        await panelModel.sendPreparationTask?.value
        await panelModel.awaitAnswer()
        let book = try #require(log.requests.last)
        #expect(book.scope == .wholeBook)
        #expect(book.pageText.contains("Chapter one body text."))
        #expect(book.pageText.contains("Other chapter body text."))
    }

    @Test("a missing chapter passage sends the page under the page scope")
    func missingChapterFallsBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-scope-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let reader = SteppingReader(kind: .kindle, pages: [page(1)])
        let log = RequestLog()
        let panelModel = self.panel(reader: reader, model: model) { request, _ in
            log.append(request)
            return AIAnswer(text: "answer", provider: "test")
        }
        panelModel.loadPage()
        await panelModel.awaitPageLoad()
        defer { panelModel.cancel() }

        await sendWhenReady(
            panelModel, scope: .currentChapter,
            question: "Summarize the chapter")
        await panelModel.sendPreparationTask?.value
        await panelModel.awaitAnswer()
        let request = try #require(log.requests.last)
        #expect(request.scope == .currentPage)
        #expect(request.pageText.contains("page 1 words"))
        #expect(panelModel.sendNote?.contains("sent instead") == true)
    }

    @Test("a Kindle capture follows the open book, not the library row")
    func captureFollowsLiveKindle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tsundoku-capture-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let selected = Book(
            asin: "OLD", title: "Surely You're Joking", author: "A",
            bookType: 10, readState: 0, source: .kindle)
        let open = Book(
            asin: "NEW", title: "Built to Grow", author: "B",
            bookType: 10, readState: 0, source: .kindle)
        model.books = [selected, open]
        model.selectedBookID = "OLD"
        model.livePage = LivePage(
            state: "readingChromeHidden",
            text: String(repeating: "words ", count: 20),
            title: "Built to Grow", characters: 120,
            windowFrame: nil, pageTextFrame: nil, endOfBook: false,
            pageNumber: 1, pageCount: 10, bookID: "NEW")
        #expect(model.captureBook()?.asin == "NEW")

        // An open book the archive does not know must not borrow the row.
        model.livePage = LivePage(
            state: "readingChromeHidden",
            text: String(repeating: "words ", count: 20),
            title: "A Book Not In The Archive", characters: 120,
            windowFrame: nil, pageTextFrame: nil, endOfBook: false,
            pageNumber: 1, pageCount: 10, bookID: "UNKNOWN")
        #expect(model.captureBook() == nil)
    }

    @Test("a selection spanning several nodes is joined in order")
    func multiNodeSelection() {
        #expect(
            SelectionText.joined(["Alice was", " beginning to get", "tired"])
                == "Alice was\nbeginning to get\ntired")
        #expect(SelectionText.joined(["  ", "\n", ""]) == nil)
        #expect(SelectionText.joined(["  one  "]) == "one")
    }
}
