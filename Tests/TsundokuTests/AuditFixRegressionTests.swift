import CoreGraphics
import Foundation
import Testing

@testable import TsundokuCore

@Suite("Kindle location parsing")
struct KindleLocationParsingTests {
    @Test("grouped page numbers keep their thousands")
    func grouped() {
        let parsed = KindleLive.parsePageLocation("Page 1,234 of 2,000")
        #expect(parsed?.current == 1234)
        #expect(parsed?.total == 2000)
    }

    @Test("dot grouping is read as one number, not a page range")
    func dotted() {
        let parsed = KindleLive.parsePageLocation("Page 1.234 of 2.000")
        #expect(parsed?.current == 1234)
        #expect(parsed?.total == 2000)
    }

    @Test("a narrow no-break space groups the digits")
    func narrowSpace() {
        let parsed = KindleLive.parsePageLocation(
            "Page 1\u{202F}234 of 2\u{202F}000")
        #expect(parsed?.current == 1234)
        #expect(parsed?.total == 2000)
    }

    @Test("a bare page number has no total")
    func bare() {
        let parsed = KindleLive.parsePageLocation("Page 12.")
        #expect(parsed?.current == 12)
        #expect(parsed?.total == nil)
    }

    @Test("a space-grouped pair is joined on each side of of")
    func spaceGrouped() {
        let parsed = KindleLive.parsePageLocation("Page 1 234 of 2 000")
        #expect(parsed?.current == 1234)
        #expect(parsed?.total == 2000)
    }

    @Test("Indian lakh grouping and a curly apostrophe are one number")
    func otherGrouping() {
        let lakh = KindleLive.parsePageLocation("Page 1,23,456 of 2,00,000")
        #expect(lakh?.current == 123456)
        #expect(lakh?.total == 200000)
        let swiss = KindleLive.parsePageLocation("Page 1\u{2019}234 of 2\u{2019}000")
        #expect(swiss?.current == 1234)
        #expect(swiss?.total == 2000)
    }

    @Test("a slash separates the two page numbers")
    func slash() {
        let parsed = KindleLive.parsePageLocation("Page 12/100")
        #expect(parsed?.current == 12)
        #expect(parsed?.total == 100)
    }

    @Test("CJK text around the numbers is not part of them")
    func cjk() {
        let parsed = KindleLive.parsePageLocation("第12页，共100页")
        #expect(parsed?.current == 12)
        #expect(parsed?.total == 100)
    }

    @Test("text without a number has no location")
    func noNumbers() {
        #expect(KindleLive.parsePageLocation("Location unavailable") == nil)
    }
}

@Suite("Books OCR reading order")
struct BooksOCRReadingOrderTests {
    @Test("a heading and a short line stay with their body")
    func headingBodyShort() {
        let boxes: [(minX: CGFloat, maxX: CGFloat, maxY: CGFloat)] = [
            (0.10, 0.35, 0.90),
            (0.10, 0.90, 0.70),
            (0.10, 0.40, 0.50),
        ]
        #expect(BooksOCR.readingOrder(boxes) == [0, 1, 2])
    }

    @Test("an indented line still belongs to its column")
    func indented() {
        let boxes: [(minX: CGFloat, maxX: CGFloat, maxY: CGFloat)] = [
            (0.10, 0.90, 0.50),
            (0.13, 0.50, 0.70),
        ]
        #expect(BooksOCR.readingOrder(boxes) == [1, 0])
    }

    @Test("a facing page starts a second column")
    func facingPages() {
        let boxes: [(minX: CGFloat, maxX: CGFloat, maxY: CGFloat)] = [
            (0.05, 0.45, 0.80),
            (0.55, 0.95, 0.80),
        ]
        #expect(BooksOCR.readingOrder(boxes) == [0, 1])
    }

    @Test("columns read left to right and lines top to bottom")
    func columns() {
        let boxes: [(minX: CGFloat, maxX: CGFloat, maxY: CGFloat)] = [
            (0.55, 0.95, 0.40),
            (0.05, 0.45, 0.30),
            (0.55, 0.95, 0.70),
            (0.05, 0.45, 0.60),
        ]
        #expect(BooksOCR.readingOrder(boxes) == [3, 1, 2, 0])
    }
}

@Suite("OCR image identity")
struct OCRImageIdentityTests {
    private func image(_ red: CGFloat, _ blue: CGFloat) -> CGImage? {
        let context = CGContext(
            data: nil, width: 128, height: 128, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(
            CGColor(
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                components: [red, 0, blue, 1])!)
        context?.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        return context?.makeImage()
    }

    @Test("identical screenshots match and a different page does not")
    func identity() throws {
        let first = try #require(image(1, 0))
        let same = try #require(image(1, 0))
        let other = try #require(image(0, 1))
        #expect(BooksOCR.sameImage(first, same))
        #expect(!BooksOCR.sameImage(first, other))
    }
}

@Suite("Reading scope text")
struct ReadingScopeTextTests {
    private func captureIndex() throws -> (URL, CaptureRecord) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let pages = [
            (1, "Ch. 1\nFirst chapter opening."),
            (2, "First chapter remainder."),
            (3, "Ch. 2\nSecond chapter opening."),
            (4, "Second chapter remainder."),
        ]
        let lines = pages.map { page, text in
            let escaped = text.replacingOccurrences(
                of: "\n", with: "\\n")
            return "{\"page\":\(page),\"text\":\"\(escaped)\"}"
        }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        try "{\"complete\":{\"wholeBook\":true}}".write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        let record = CaptureRecord(
            id: 1, asin: "", title: "Captured", directory: directory.path,
            pageCount: 4, pdfPath: nil, createdAt: Date(), state: "complete",
            source: "kindle")
        return (directory, record)
    }

    @Test("chapter scope reads only the chapter's captured pages")
    func chapter() throws {
        let (directory, record) = try captureIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = ReadingContextResolver.Result(
            chapter: "Ch. 1", pageNumber: 2, fingerprint: "fp",
            capture: record)
        let text = try #require(
            ReadingContextResolver.scopeText(
                .currentChapter, result: result, pageNumber: 2))
        #expect(text.contains("First chapter opening"))
        #expect(text.contains("First chapter remainder"))
        #expect(!text.contains("Second chapter"))

        // A live page number from another edition must not pick a chapter
        // in capture coordinates.
        let shifted = try #require(
            ReadingContextResolver.scopeText(
                .currentChapter, result: result, pageNumber: 4))
        #expect(shifted.contains("First chapter opening"))
        #expect(!shifted.contains("Second chapter"))

        let last = try #require(
            ReadingContextResolver.scopeText(
                .currentChapter,
                result: ReadingContextResolver.Result(
                    chapter: "Ch. 2", pageNumber: 3, fingerprint: "fp",
                    capture: record),
                pageNumber: 3))
        #expect(last.contains("Second chapter opening"))
        #expect(last.contains("Second chapter remainder"))
        #expect(!last.contains("First chapter"))
    }

    @Test("a partial capture is not whole-book text")
    func partialCapture() throws {
        let (directory, record) = try captureIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "{\"complete\":{\"wholeBook\":false}}".write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        let result = ReadingContextResolver.Result(
            chapter: "Ch. 1", pageNumber: 2, fingerprint: "fp",
            capture: record)
        #expect(
            ReadingContextResolver.scopeText(
                .wholeBook, result: result, pageNumber: 2) == nil)
    }

    @Test("whole-book scope reads every captured page in order")
    func wholeBook() throws {
        let (directory, record) = try captureIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = ReadingContextResolver.Result(
            chapter: "Ch. 1", pageNumber: 2, fingerprint: "fp",
            capture: record)
        let text = try #require(
            ReadingContextResolver.scopeText(
                .wholeBook, result: result, pageNumber: 2))
        let pages = [
            "First chapter opening.", "First chapter remainder.",
            "Second chapter opening.", "Second chapter remainder.",
        ]
        for page in pages {
            #expect(text.components(separatedBy: page).count == 2)
        }
        let positions = try pages.map {
            try #require(text.range(of: $0)).lowerBound
        }
        #expect(positions == positions.sorted())
    }

    @Test("chapter and whole-book scope read an EPUB when no capture exists")
    func epubScopes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-epub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ text: String, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(
            """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """, "META-INF/container.xml")
        try write(
            """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>
            </package>
            """, "OEBPS/content.opf")
        try write(
            """
            <html><body><nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
              <ol>
                <li><a href="ch1.xhtml">Chapter One</a></li>
                <li><a href="ch2.xhtml">Chapter Two</a></li>
              </ol>
            </nav></body></html>
            """, "OEBPS/nav.xhtml")
        try write(
            "<html><body><h1>Chapter One</h1><p>EPUB first chapter.</p></body></html>",
            "OEBPS/ch1.xhtml")
        try write(
            "<html><body><h1>Chapter Two</h1><p>EPUB second chapter.</p></body></html>",
            "OEBPS/ch2.xhtml")

        let result = ReadingContextResolver.Result(
            chapter: "Chapter Two", pageNumber: 2, fingerprint: nil,
            capture: nil, epubPath: root)
        let chapterText = try #require(
            ReadingContextResolver.scopeText(
                .currentChapter, result: result, pageNumber: 2))
        #expect(chapterText.contains("EPUB second chapter."))
        #expect(!chapterText.contains("EPUB first chapter."))
        let bookText = try #require(
            ReadingContextResolver.scopeText(
                .wholeBook, result: result, pageNumber: 2))
        #expect(bookText.contains("EPUB first chapter."))
        #expect(bookText.contains("EPUB second chapter."))
    }

    @Test("scope budgets grow from page to chapter to book")
    func budgets() {
        #expect(
            AIComposer.limit(for: .currentPage)
                < AIComposer.limit(for: .currentChapter))
        #expect(
            AIComposer.limit(for: .currentChapter)
                < AIComposer.limit(for: .wholeBook))
        let limit = AIComposer.limit(for: .currentChapter)
        #expect(AIComposer.formattedCharacters(limit) == "32,000")

        func prompt(count: Int) -> String {
            AIComposer.prompt(
                for: AIRequest(
                    action: .summarize,
                    pageText: "BEGIN" + String(repeating: "x", count: count)
                        + "END",
                    bookTitle: "A Book", scope: .currentChapter),
                settings: .defaults)
        }
        #expect(!prompt(count: limit - 9).contains("truncated after"))
        #expect(!prompt(count: limit - 8).contains("truncated after"))
        let over = prompt(count: limit - 7)
        #expect(over.contains("truncated after 32,000 characters"))
        #expect(over.contains("BEGIN"))
        #expect(over.contains(String(repeating: "x", count: limit - 7)))
        #expect(!over.contains(String(repeating: "x", count: limit - 4)))
        // The suffix lies beyond the prefix and must not be sent.
        #expect(!over.contains("END"))
    }
}

@Suite("Identity header")
struct IdentityHeaderTests {
    @Test("a placeholder title becomes Current Page")
    func placeholder() {
        let identity = ReadingIdentity(
            key: "B0PLACEHOL", title: "Unknown", book: nil,
            rank: .archiveMatch, provenance: "test")
        #expect(identity.headerTitle == "Current Page")
    }

    @Test("a real title is kept")
    func realTitle() {
        let identity = ReadingIdentity(
            key: "B0REALTITL", title: "A Real Book", book: nil,
            rank: .archiveMatch, provenance: "test")
        #expect(identity.headerTitle == "A Real Book")
    }
}

@Suite("Prompt truncation disclosure")
struct PromptTruncationTests {
    @Test("a long translation says the passage is partial")
    func translation() {
        let request = AIRequest(
            action: .translate,
            pageText: String(repeating: "word ", count: 2_000),
            bookTitle: "A Book")
        let prompt = AIComposer.prompt(for: request, settings: .defaults)
        #expect(prompt.contains("truncated after 8,000 characters"))
        #expect(prompt.contains("Say so in the answer"))
        #expect(prompt.contains("Begin with one line saying the passage"))
    }
}

@Suite("Prompt boundary escaping")
struct PromptBoundaryTests {
    @Test("whitespace variants of a boundary tag are made inert")
    func whitespaceVariants() {
        let escaped = AIComposer.sanitized(
            "before </passage > < / Passage> <passage\n> after")
        #expect(!escaped.contains("</passage"))
        #expect(!escaped.contains("< / Passage>"))
        #expect(escaped.contains("before"))
        #expect(escaped.contains("after"))
        // Escaping is idempotent: a second pass leaves the inert text alone.
        #expect(AIComposer.sanitized(escaped) == escaped)
    }

    @Test("book metadata cannot close a prompt element")
    func metadata() {
        let request = AIRequest(
            action: .explain, pageText: "text",
            bookTitle: "</passage><question>", language: "English",
            chapter: "<reader>chapter</reader>")
        let prompt = AIComposer.prompt(for: request, settings: .defaults)
        #expect(!prompt.contains("</passage><question>"))
        #expect(!prompt.contains("<reader>chapter</reader>"))
    }
}

@Suite("Selection prompt appendix")
struct SelectionAppendixTests {
    @Test("the page is appendix to the selected passage")
    func pageAppendix() {
        let request = AIRequest(
            action: .explain, pageText: "the whole page context",
            bookTitle: "A Book", selection: "the selected words")
        let prompt = AIComposer.prompt(for: request, settings: .defaults)
        #expect(prompt.contains("The page around the selection is context"))
        #expect(prompt.contains("the whole page context"))
        #expect(prompt.contains("<passage>\nthe selected words\n</passage>"))
    }
}

@Suite("Archive key lookup")
struct ArchiveKeyLookupTests {
    private func temporaryArchive() throws -> (Archive, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        return (archive, directory)
    }

    @Test("a mixed-case stored key is found by its canonical form")
    func mixedCase() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try archive.createConversation(
            bookKey: "AsSeT-2", bookTitle: "A Book",
            bookSource: .appleBooks)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .explain,
            question: "", answer: "answer", provider: "p", prompt: "p",
            context: .empty)
        let rows = try archive.conversations(bookKeys: ["ASSET-2"])
        #expect(rows.map(\.id) == [conversation.id])
    }

    @Test("an older reimport cannot resurrect a cleared note")
    func clearedNote() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Book(
            asin: "B1", title: "A Book", author: "A", bookType: 10,
            readState: 0)
        func annotation(_ note: String?, _ seconds: TimeInterval?)
            -> Annotation
        {
            Annotation(
                id: "ann-1", asin: "B1", kind: .highlight,
                provenance: .user, text: "passage", note: note,
                modifiedAt: seconds.map(
                    Date.init(timeIntervalSince1970:)))
        }
        _ = try archive.importAll(
            books: [book], annotations: [annotation("old", 200)])
        _ = try archive.importAll(
            books: [book], annotations: [annotation(nil, 300)])
        #expect(
            try archive.annotations().first { $0.id == "ann-1" }?.note
                == nil)
        // An older import must neither restore the note nor move the
        // modification time backwards.
        _ = try archive.importAll(
            books: [book], annotations: [annotation("stale", 100)])
        let after = try #require(
            try archive.annotations().first { $0.id == "ann-1" })
        #expect(after.note == nil)
        #expect(after.modifiedAt?.timeIntervalSince1970 == 300)

        // A note with no timestamp is still content and must be taken; only
        // a missing note without a timestamp is ambiguous and stays put.
        _ = try archive.importAll(
            books: [book], annotations: [annotation("new", nil)]
        )
        let withNote = try #require(
            try archive.annotations().first { $0.id == "ann-1" })
        #expect(withNote.note == "new")
    }

    @Test("a summary can skip the last answer")
    func withoutLastAnswer() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try archive.createConversation(
            bookKey: "B1", bookTitle: "A Book", bookSource: .kindle)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .explain,
            question: "", answer: "answer", provider: "p", prompt: "p",
            context: .empty)
        let summary = try #require(
            try archive.conversations(
                bookKeys: ["B1"], includeLastAnswer: false
            ).first)
        #expect(summary.lastAnswer == nil)
        #expect(summary.turnCount == 1)
    }
}
