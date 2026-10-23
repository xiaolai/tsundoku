import Foundation
import Testing

@testable import TsundokuCore

@Suite("Annotation browser contracts")
struct AnnotationBrowserTests {
    private func item(
        _ id: String, kind: AnnotationKind = .highlight,
        text: String? = nil, note: String? = nil,
        source: BookSource = .kindle, asin: String = "B1"
    ) -> Annotation {
        Annotation(
            id: id, asin: asin, kind: kind, provenance: .user,
            text: text, note: note, bookSource: source)
    }

    @Test func contentEncodings() {
        let note = item("n", kind: .note, note: "My thought")
        #expect(note.hasContent)
        #expect(note.passageText == nil)
        #expect(note.personalNote == "My thought")
        let legacy = item("l", kind: .note, text: "Legacy thought")
        #expect(legacy.personalNote == "Legacy thought")
        #expect(legacy.passageText == nil)
        let attached = item("h", text: "Passage", note: "My thought")
        #expect(attached.passageText == "Passage")
        #expect(attached.personalNote == "My thought")
        #expect(!item("blank", text: " \n", note: " \t").hasContent)
    }

    @Test func queryCombinesEveryBoundary() {
        let books = [
            Book(
                asin: "B1", title: "A title", author: "Some Author",
                bookType: 10, readState: 0)
        ]
        let items = [
            item("n", kind: .note, note: "Thought"), item("missing"),
            item("apple", text: "Passage", source: .appleBooks, asin: "A1"),
        ]
        var query = AnnotationQuery()
        query.contentOnly = true
        #expect(
            query.apply(to: items, books: books).map(\.id) == ["apple", "n"])
        query.source = .kindle
        query.bookID = "B1"
        query.kind = .notes
        query.search = "AUTHOR"
        #expect(query.apply(to: items, books: books).map(\.id) == ["n"])
        query.search = "missing"
        #expect(query.apply(to: items, books: books).isEmpty)
        query = AnnotationQuery()
        #expect(query.apply(to: items, books: books).count == 3)
    }

    @Test func orderingAndMissingDates() {
        var recent = item("z", text: "New")
        recent.createdAt = Date(timeIntervalSince1970: 100)
        #expect(
            AnnotationQuery().apply(to: [item("b"), recent, item("a")]).map(
                \.id) == ["z", "a", "b"])
        #expect(
            AnnotationQuery().apply(to: [item("b"), item("a")]).first?.createdAt
                == nil)
    }

    @Test func oldestStillKeepsUnknownDatesLast() {
        var known = item("known", text: "Passage")
        known.createdAt = Date(timeIntervalSince1970: 100)
        var query = AnnotationQuery()
        query.sort = .oldest
        #expect(
            query.apply(to: [item("unknown"), known]).map(\.id) == [
                "known", "unknown",
            ])
    }

    @Test func selectionRangesAndFiltering() {
        var selection = AnnotationSelection()
        let ids = ["a", "b", "c", "d"]
        selection.select("b", in: ids)
        selection.select("d", in: ids, extending: true)
        #expect(selection.ids == ["b", "c", "d"])
        selection.select("c", in: ids, toggling: true)
        #expect(selection.ids == ["b", "d"])
        selection.reconcile(with: ["a", "b"])
        #expect(selection.ids == ["b"])
        selection.reconcile(with: [])
        #expect(selection.ids.isEmpty)
    }

    @Test func keyboardStartsAtFirstAndExtendsFromMovingFocus() {
        var selection = AnnotationSelection()
        let ids = ["a", "b", "c", "d", "e", "f"]
        selection.move(by: 2, in: ids)
        #expect(selection.ids == ["a"])
        selection.move(by: 2, in: ids, extending: true)
        #expect(selection.ids == ["a", "b", "c"])
        selection.move(by: 2, in: ids, extending: true)
        #expect(selection.ids == ["a", "b", "c", "d", "e"])
        #expect(selection.focusedID == "e")
        #expect(selection.anchor == "a")
    }

    @Test func exactExportsPreserveRowsAndOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try Archive(
            path: dir.appendingPathComponent("archive.sqlite"))
        let rows = [
            item("z", text: "A, quoted \"passage\"", note: "A\nthought"),
            item("a", kind: .note, note: "Standalone"),
        ]
        for format in AnnotationExportFormat.allCases {
            let url = dir.appendingPathComponent(
                "results.\(format.fileExtension)")
            try archive.exportAnnotations(rows, to: url, format: format)
            let output = try String(contentsOf: url, encoding: .utf8)
            #expect(output.contains("Standalone"))
            #expect(output.components(separatedBy: "Standalone").count == 2)
            #expect(!output.contains("Text unavailable"))
            if format == .json {
                let parsed = try #require(
                    JSONSerialization.jsonObject(with: Data(output.utf8))
                        as? [[String: Any]])
                #expect(
                    parsed.compactMap { $0["id"] as? String } == ["z", "a"])
            }
        }
    }

    @Test func largeFixture() {
        let rows = (0..<10_000).map { item("\($0)", text: "Passage \($0)") }
        var query = AnnotationQuery()
        query.search = "Passage 9999"
        #expect(query.apply(to: rows).map(\.id) == ["9999"])
    }
}
