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

        func selectedText() -> String? { nil }

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

    private func panel(
        reader: SteppingReader, model: AppModel,
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

        reader.setSelection("a selected phrase")
        await panel.followPageOnce()
        #expect(panel.context.selection == "a selected phrase")

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

    @Test("a selection spanning several nodes is joined in order")
    func multiNodeSelection() {
        #expect(
            SelectionText.joined(["Alice was", " beginning to get", "tired"])
                == "Alice was\nbeginning to get\ntired")
        #expect(SelectionText.joined(["  ", "\n", ""]) == nil)
        #expect(SelectionText.joined(["  one  "]) == "one")
    }
}
