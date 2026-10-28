import CoreGraphics
import Foundation
import Testing

@testable import TsundokuCore

@Suite("Capture page index")
struct PageIndexTests {
    @Test("a page is named by its opening words, cut on a word boundary")
    func opening() {
        #expect(
            PageIndex.opening(of: "  The\nnegotiation   begins here.  ")
                == "The negotiation begins here.")
        let long = String(repeating: "word ", count: 40)
        let opening = PageIndex.opening(of: long)
        #expect(opening.count <= PageIndex.openingLength + 1)
        #expect(opening.hasSuffix("…"))
        #expect(!opening.contains("wor…"))
    }

    @Test("rows count from the first page the PDF numbers")
    func rows() {
        let rows = PageIndex.rows(
            texts: ["one", "two"], firstPDFPage: 2)
        #expect(rows.map(\.pdfPage) == [2, 3])
        #expect(rows.map(\.opening) == ["one", "two"])
    }

    @Test("the CSV quotes what needs quoting")
    func csv() {
        let rows = [
            PageIndexRow(pdfPage: 2, opening: "Plain words"),
            PageIndexRow(pdfPage: 3, opening: "Has, a comma"),
            PageIndexRow(pdfPage: 4, opening: "Has \"quotes\""),
        ]
        let text = PageIndex.csv(rows)
        #expect(text.hasPrefix("pdf_page,opening_words\n"))
        #expect(text.contains("\n2,Plain words\n"))
        #expect(text.contains("\n3,\"Has, a comma\"\n"))
        #expect(text.contains("\"Has \"\"quotes\"\"\""))
    }

    @Test("an index of many pages spans several PDF pages")
    func pagination() throws {
        let rows = PageIndex.rows(
            texts: (1...600).map { "page \($0) opening words" },
            firstPDFPage: 2)
        let document = try #require(
            PageIndex.document(
                rows: rows, title: "A Book",
                pageSize: CGSize(width: 595.28, height: 841.89)))
        #expect(document.pageCount > 1)
        // Every captured page is named somewhere in the index.
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined()
        // Text extraction collapses the column gap, so the two facts are
        // checked separately.
        #expect(text.contains("page 600 opening words"))
        #expect(text.contains("601"))
    }
}
