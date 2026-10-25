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

    @Test("a selection spanning several nodes is joined in order")
    func multiNodeSelection() {
        #expect(
            SelectionText.joined(["Alice was", " beginning to get", "tired"])
                == "Alice was\nbeginning to get\ntired")
        #expect(SelectionText.joined(["  ", "\n", ""]) == nil)
        #expect(SelectionText.joined(["  one  "]) == "one")
    }
}
