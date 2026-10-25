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
