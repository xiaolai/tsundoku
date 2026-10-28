import Foundation
import Testing

@testable import TsundokuCore
@testable import TsundokuUI

/// Every route into the library must bring its window forward. The companion
/// panel is nonactivating, so a route that only sets state changes nothing a
/// reader can see — which is what "Manage Chats" did until it called the
/// window closure.
@MainActor
@Suite("Library routes")
struct RouteTests {
    private func model() throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let model = AppModel(
            archiveURL: directory.appendingPathComponent("archive.sqlite"),
            recoverReaderSettings: false)
        return (model, directory)
    }

    private func book() -> Book {
        Book(
            asin: "B0ROUTE", title: "A Book", author: "Author",
            bookType: 10, readState: 0)
    }

    @Test("opening a book's chats brings the library forward")
    func openChats() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var presented = 0
        model.openLibraryWindow = { presented += 1 }
        model.openChats(for: book())
        #expect(presented == 1)
        #expect(model.section == .library)
        #expect(model.bookWorkspaceSection == .chats)
    }

    @Test("showing a book's annotations brings the library forward")
    func showAnnotations() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var presented = 0
        model.openLibraryWindow = { presented += 1 }
        model.showAnnotations(for: book())
        #expect(presented == 1)
        #expect(model.section == .highlights)
        #expect(model.annotationBookID == "B0ROUTE")
    }

    @Test("the capture exports route brings the library forward")
    func openCaptureExports() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var presented = 0
        model.openLibraryWindow = { presented += 1 }
        model.openCaptureExports(bookID: nil, readerKind: .kindle)
        #expect(presented == 1)
        #expect(model.section == .exports)
    }

    @Test("returning to a capture after granting access brings the library forward")
    func returnToCapture() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var presented = 0
        model.openLibraryWindow = { presented += 1 }
        model.returnToCapture()
        #expect(presented == 1)
        #expect(model.section == .exports)
    }

    @Test("access routes open Settings, not the library")
    func accessRoutes() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = 0
        var library = 0
        model.openSettingsWindow = { _ in settings += 1 }
        model.openLibraryWindow = { library += 1 }
        model.openAccess(focus: .library)
        #expect(settings == 1)
        model.requestCaptureAccess(pages: nil)
        #expect(settings == 2)
        #expect(library == 0)
    }

    @Test("revealing a book clears the filters that could hide it")
    func revealBook() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        var presented = 0
        model.openLibraryWindow = { presented += 1 }
        model.search = "something else"
        model.sourceFilter = .kindle
        model.section = .highlights

        model.revealBook(asin: "B0ROUTE")

        #expect(presented == 1)
        #expect(model.search.isEmpty)
        #expect(model.sourceFilter == .all)
        #expect(model.selectedBookID == "B0ROUTE")
        #expect(model.section == .library)
        #expect(model.libraryReveal?.asin == "B0ROUTE")
    }

    @Test("a reveal is consumed once")
    func revealConsumed() throws {
        let (model, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.openLibraryWindow = {}
        model.revealBook(asin: "B0ROUTE")
        let generation = try #require(model.libraryReveal?.generation)
        model.consumeLibraryReveal(generation - 1)
        #expect(model.libraryReveal != nil, "a stale generation must not consume it")
        model.consumeLibraryReveal(generation)
        #expect(model.libraryReveal == nil)
        // A second reveal after consumption starts again.
        model.revealBook(asin: "B0ROUTE")
        #expect(model.libraryReveal?.generation == generation + 1)
    }
}

/// Which capture answers for an annotation. Two editions can share a title,
/// and a newer capture of the wrong one must not supply the page.
@MainActor
@Suite("Annotation capture lookup")
struct CaptureCandidateTests {
    private func record(
        id: Int64, asin: String, title: String, source: String = "kindle",
        day: Double = 0
    ) -> CaptureRecord {
        CaptureRecord(
            id: id, asin: asin, title: title, directory: "/tmp/c\(id)",
            pageCount: 100, pdfPath: nil,
            createdAt: Date(timeIntervalSince1970: day), state: "complete",
            source: source)
    }

    private func annotation(asin: String, title: String) -> Annotation {
        Annotation(
            id: "a1", asin: asin, bookTitle: title, kind: .highlight,
            provenance: .user, text: "x", bookSource: .kindle)
    }

    @Test("the same book and reader wins over a newer capture of another edition")
    func exactIdentifierFirst() {
        let captures = [
            record(id: 2, asin: "B0OTHER", title: "Same Title", day: 200),
            record(id: 1, asin: "B0MINE", title: "Same Title", day: 100),
        ]
        let candidates = AppModel.captureCandidates(
            for: annotation(asin: "B0MINE", title: "Same Title"),
            among: captures)
        #expect(candidates.map(\.id) == [1])
    }

    @Test("the newest capture of the same book comes first")
    func newestFirst() {
        let captures = [
            record(id: 1, asin: "B0MINE", title: "T", day: 100),
            record(id: 2, asin: "B0MINE", title: "T", day: 200),
        ]
        let candidates = AppModel.captureCandidates(
            for: annotation(asin: "B0MINE", title: "T"), among: captures)
        #expect(candidates.map(\.id) == [2, 1])
    }

    @Test("another reader's capture is not this book's")
    func sourceMatters() {
        let captures = [
            record(id: 1, asin: "B0MINE", title: "T", source: "books"),
        ]
        let candidates = AppModel.captureCandidates(
            for: annotation(asin: "B0MINE", title: "T"), among: captures)
        #expect(candidates.isEmpty)
    }

    @Test("a title shared by two captures is not used to guess")
    func ambiguousTitle() {
        let captures = [
            record(id: 1, asin: "B0A", title: "Same Title"),
            record(id: 2, asin: "B0B", title: "Same Title"),
        ]
        let candidates = AppModel.captureCandidates(
            for: annotation(asin: "B0MISSING", title: "Same Title"),
            among: captures)
        #expect(candidates.isEmpty)
    }

    @Test("a title that names exactly one capture is used")
    func unambiguousTitle() {
        let captures = [
            record(id: 1, asin: "B0A", title: "Only Edition"),
            record(id: 2, asin: "B0B", title: "Another Book"),
        ]
        let candidates = AppModel.captureCandidates(
            for: annotation(asin: "B0MISSING", title: "Only Edition"),
            among: captures)
        #expect(candidates.map(\.id) == [1])
    }
}
