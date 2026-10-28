import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// A captured page named by its own opening words.
///
/// Kindle publishes no page number while its chrome is hidden, so the only
/// thing a reader can match between the PDF and the reader is the text on the
/// page. Every capture writes this map beside its PDF, and the PDF carries the
/// same table as an index at the end, where it cannot shift the book's own
/// page numbers.
public struct PageIndexRow: Sendable, Equatable {
    /// The page as the PDF numbers it (1-based, countng the cover).
    public let pdfPage: Int
    /// The opening words, with whitespace collapsed.
    public let opening: String

    public init(pdfPage: Int, opening: String) {
        self.pdfPage = pdfPage
        self.opening = opening
    }
}

public enum PageIndex {
    /// How much of a page's opening to keep. Enough to recognise the page in
    /// Kindle's search, short enough to fit one line in a narrow column.
    public static let openingLength = 70

    public static func rows(
        texts: [String], firstPDFPage: Int
    ) -> [PageIndexRow] {
        texts.enumerated().map { index, text in
            PageIndexRow(
                pdfPage: firstPDFPage + index,
                opening: opening(of: text))
        }
    }

    /// The first words of a page, whitespace collapsed.
    public static func opening(of text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > openingLength else { return collapsed }
        let cut = collapsed.prefix(openingLength)
        // Cut on a word boundary so the line does not end mid-word.
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    public static func csv(_ rows: [PageIndexRow]) -> String {
        var lines = ["pdf_page,opening_words"]
        for row in rows {
            lines.append("\(row.pdfPage),\(quoted(row.opening))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"")
            + "\""
    }

    /// The index as one attributed body, for drawing into a PDF context.
    public static func attributedBody(
        rows: [PageIndexRow], title: String
    ) -> NSAttributedString {
        let body = NSMutableAttributedString()
        body.append(
            NSAttributedString(
                string: "\(title)\nPage Index\n\n",
                attributes: [
                    .font: CTFontCreateWithName(
                        "Helvetica-Bold" as CFString, 14, nil),
                    .foregroundColor: CGColor(gray: 0, alpha: 1),
                ]))
        body.append(
            NSAttributedString(
                string: "PDF page → the page's opening words\n\n",
                attributes: [
                    .font: CTFontCreateWithName(
                        "Helvetica" as CFString, 9, nil),
                    .foregroundColor: CGColor(gray: 0.35, alpha: 1),
                ]))
        for row in rows {
            body.append(
                NSAttributedString(
                    string: "p.\(row.pdfPage) — \(row.opening)\n",
                    attributes: [
                        .font: CTFontCreateWithName(
                            "Helvetica" as CFString, 9, nil),
                        .foregroundColor: CGColor(gray: 0.15, alpha: 1),
                    ]))
        }
        return body
    }

    /// Draws the body into an open PDF context, one page per screenful of
    /// text, and returns how many pages it used.
    @discardableResult
    public static func draw(
        _ body: NSAttributedString, in context: CGContext,
        pageSize: CGSize, margin: CGFloat = 40
    ) -> Int {
        let frame = CGRect(
            x: margin, y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2)
        let framesetter = CTFramesetterCreateWithAttributedString(body)
        var start = 0
        var pages = 0
        while start < body.length {
            var box = CGRect(origin: .zero, size: pageSize)
            context.beginPage(mediaBox: &box)
            let path = CGPath(rect: frame, transform: nil)
            let textFrame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(textFrame, context)
            let visible = CTFrameGetVisibleStringRange(textFrame)
            context.endPage()
            guard visible.length > 0 else { break }
            start += visible.length
            pages += 1
        }
        return pages
    }

    /// The index as a PDF document, for existing captures whose PDF is
    /// already written.
    public static func document(
        rows: [PageIndexRow], title: String, pageSize: CGSize
    ) -> PDFDocument? {
        guard !rows.isEmpty else { return nil }
        let body = attributedBody(rows: rows, title: title)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData)
        else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(
            consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }
        draw(body, in: context, pageSize: pageSize)
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    /// Appends the index to an existing PDF and writes the CSV beside it.
    /// Returns the number of pages the document has afterwards.
    @discardableResult
    public static func append(
        to pdf: URL, rows: [PageIndexRow], title: String,
        pageSize: CGSize, csvURL: URL?
    ) throws -> Int {
        guard let target = PDFDocument(url: pdf),
            let index = document(
                rows: rows, title: title, pageSize: pageSize)
        else { return 0 }
        let added = index.pageCount
        for indexPage in 0..<added {
            guard let page = index.page(at: indexPage) else { continue }
            target.insert(page, at: target.pageCount)
        }
        guard target.write(to: pdf) else { return 0 }
        if let csvURL {
            try csv(rows).write(to: csvURL, atomically: true, encoding: .utf8)
        }
        return target.pageCount
    }
}
