import Foundation
import Testing

@testable import TsundokuCore
@testable import TsundokuUI

@MainActor
@Suite("Companion identity", .timeLimit(.minutes(1)))
struct CompanionIdentityTests {
    private struct FixedReader: ReaderContext {
        let kind: ReaderKind
        let pageValue: ReaderPage

        func page() throws -> ReaderPage { pageValue }
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
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

    private func book(_ asin: String, _ title: String) -> Book {
        Book(
            asin: asin, title: title, author: "A", bookType: 10,
            readState: 0, source: .appleBooks)
    }

    @Test("a title-keyed chat moves under the edition's asset ID")
    func titleKeyMigratesToAssetID() async throws {
        let directory = try temporaryDirectory("identity-migrate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        model.books = [book("ASSET-1", "Alice"), book("ASSET-2", "Alice")]
        let archive = try #require(model.archive)
        let conversation = try archive.createConversation(
            bookKey: "books:alice", bookTitle: "Alice",
            bookSource: .appleBooks)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .explain, question: "",
            answer: "Old answer", provider: "p", prompt: "", context: .empty)

        let page = ReaderPage(
            text: "There was nothing so very remarkable in that, nor did Alice think it so very much out of the way.",
            title: "Alice", kind: .appleBooks, source: .accessibility)
        let panel = AIPanelModel(
            app: model, context: FixedReader(kind: .appleBooks, pageValue: page),
            contextResolver: { _, _, _ in
                ReadingContextResolver.Result(
                    chapter: "Chapter One", pageNumber: nil,
                    fingerprint: nil, capture: nil, assetID: "ASSET-2")
            })
        panel.loadPage()
        await panel.awaitPageLoad()

        #expect(panel.bookKey == "ASSET-2")
        #expect(panel.bookTitle == "Alice")
        #expect(panel.context.chapter == "Chapter One")
        #expect(panel.turns.count == 1, "the migrated chat must load")
        #expect(try archive.latestConversation(bookKey: "books:alice") == nil)
        #expect(
            try archive.latestConversation(bookKey: "ASSET-2")?.id
                == conversation.id)
    }

    @Test("an unidentified Kindle page adopts a capture fingerprint and title")
    func unidentifiedKindleAdoptsCapture() async throws {
        let directory = try temporaryDirectory("identity-capture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let page = ReaderPage(
            text: String(repeating: "the page's words ", count: 30),
            title: "Kindle", kind: .kindle, source: .accessibility)
        let panel = AIPanelModel(
            app: model, context: FixedReader(kind: .kindle, pageValue: page),
            contextResolver: { _, _, _ in
                ReadingContextResolver.Result(
                    chapter: "Ch. 1", pageNumber: 2, fingerprint: "f00d",
                    capture: CaptureRecord(
                        id: 1, asin: "", title: "Captured Book",
                        directory: "/tmp/capture", pageCount: 100,
                        pdfPath: nil, createdAt: Date(), state: "complete",
                        source: "kindle", identityConfidence: "exact"))
            })
        panel.loadPage()
        await panel.awaitPageLoad()

        #expect(panel.bookKey == "text:f00d")
        #expect(panel.bookTitle == "Captured Book")
        #expect(panel.identity?.rank == .captureText)
        #expect(!panel.identityNote.isEmpty)
    }

    @Test("a fingerprint-keyed chat moves under the ASIN once it is readable")
    func fingerprintKeyMigratesToASIN() async throws {
        let directory = try temporaryDirectory("identity-fingerprint")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let archive = try #require(model.archive)
        let conversation = try archive.createConversation(
            bookKey: "text:f00d", bookTitle: "Captured Book",
            bookSource: .kindle)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .ask, question: "Before",
            answer: "Answer", provider: "p", prompt: "", context: .empty)

        let page = ReaderPage(
            text: String(repeating: "the page's words ", count: 30),
            title: "Kindle", kind: .kindle, source: .accessibility,
            identifier: "B0ASIN0001")
        let panel = AIPanelModel(
            app: model, context: FixedReader(kind: .kindle, pageValue: page),
            contextResolver: { _, _, _ in
                ReadingContextResolver.Result(
                    chapter: nil, pageNumber: 2, fingerprint: "f00d",
                    capture: CaptureRecord(
                        id: 1, asin: "", title: "Captured Book",
                        directory: "/tmp/capture", pageCount: 100,
                        pdfPath: nil, createdAt: Date(), state: "complete",
                        source: "kindle", identityConfidence: "exact"))
            })
        panel.loadPage()
        await panel.awaitPageLoad()

        #expect(panel.bookKey == "B0ASIN0001")
        #expect(panel.turns.count == 1)
        #expect(try archive.latestConversation(bookKey: "text:f00d") == nil)
        #expect(
            try archive.latestConversation(bookKey: "B0ASIN0001")?.id
                == conversation.id)
    }

    @Test("an unidentified Kindle page stays session-only")
    func unidentifiedKindleStaysSessionOnly() async throws {
        let directory = try temporaryDirectory("identity-session")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(in: directory)
        let page = ReaderPage(
            text: String(repeating: "the page's words ", count: 30),
            title: "Kindle", kind: .kindle, source: .accessibility)
        let panel = AIPanelModel(
            app: model, context: FixedReader(kind: .kindle, pageValue: page),
            contextResolver: { _, _, _ in nil })
        panel.loadPage()
        await panel.awaitPageLoad()

        #expect(panel.bookKey == nil)
        #expect(panel.bookTitle.isEmpty)
        #expect(panel.identity?.rank == .sessionOnly)
        #expect(panel.identityNote.contains("not saved"))
    }
}
