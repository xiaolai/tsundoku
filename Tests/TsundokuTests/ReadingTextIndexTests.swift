import Foundation
import Testing

@testable import TsundokuCore

@Suite("Reading text index")
struct ReadingTextIndexTests {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-index-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func capture(
        pages: [(Int, String)], in directory: URL
    ) throws -> URL {
        let lines = pages.map { page, text in
            let object: [String: Any] = [
                "page": page, "text": text, "source": "accessibility",
            ]
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        return directory
    }

    @Test("a captured Kindle page matches its page and chapter")
    func kindleCaptureMatch() throws {
        let directory = try temporaryDirectory("kindle")
        defer { try? FileManager.default.removeItem(at: directory) }
        try capture(
            pages: [
                (1, "Ch. 1  The Math of Neural Networks: Introduction There are many reasons why neural networks fascinate us and have captured the imagination of researchers for decades."),
                (2, "Once we dig a bit deeper though, we discover that a handful of mathematical functions play a major role in the trials and errors of a neural network, and that is the subject of this chapter."),
                (3, "Ch. 2  Terminology and Notation If you are new to the field of neural networks or machine learning in general, one of the first things you will notice is the abundance of terminology."),
                (4, "The second list contains common notation, along with a brief explanation of what each symbol means and where it is used in the following chapters of the book."),
            ], in: directory)
        let index = try BookTextIndex.load(directory: directory)
        #expect(index.chapters.map(\.page) == [1, 3])
        #expect(index.chapters.first?.title == "Ch. 1")
        let second = try #require(index.match(
            pageText: "Once we dig a bit deeper though, we discover that a handful of mathematical functions play a major role in the trials and errors of a neural network"))
        #expect(second.page == 2)
        #expect(second.chapter == "Ch. 1")
        let fourth = try #require(index.match(
            pageText: "The second list contains common notation, along with a brief explanation of what each symbol means"))
        #expect(fourth.page == 4)
        #expect(fourth.chapter == "Ch. 2")
        #expect(index.match(pageText: "Nothing from this book at all.") == nil)
    }

    @Test("a Books capture keeps the full chapter heading")
    func booksCaptureHeading() throws {
        let directory = try temporaryDirectory("books")
        defer { try? FileManager.default.removeItem(at: directory) }
        try capture(
            pages: [
                (1, "Chapter One. Down the Rabbit-\nHole.\nAlice was beginning to get very tired of sitting by her sister on the bank."),
                (2, "There was nothing so very remarkable in that; nor did Alice think it so very much out of the way to hear the Rabbit say to itself."),
            ], in: directory)
        let index = try BookTextIndex.load(directory: directory)
        #expect(
            index.chapter(for: 2) == "Chapter One. Down the Rabbit-Hole.")
        let match = try #require(index.match(
            pageText: "There was nothing so very remarkable in that; nor did Alice think it so very much out of the way to hear the Rabbit"))
        #expect(match.chapter == "Chapter One. Down the Rabbit-Hole.")
    }

    @Test("the resolver returns a captured page and chapter")
    func resolverUsesCapture() throws {
        let directory = try temporaryDirectory("resolve")
        defer { try? FileManager.default.removeItem(at: directory) }
        try capture(
            pages: [
                (1, "Ch. 1  A Chapter Heading The body of the first page follows here with enough words to make a shingle match possible."),
                (2, "The second page continues with a distinctive sentence that will be matched by the resolver in this test case."),
            ], in: directory)
        let record = CaptureRecord(
            id: 1, asin: "", title: "A Book", directory: directory.path,
            pageCount: 2, pdfPath: nil, createdAt: Date(), state: "finished",
            source: "kindle")
        let result = try #require(
            ReadingContextResolver.resolve(
                pageText: "The second page continues with a distinctive sentence that will be matched by the resolver",
                kind: .kindle, identifier: nil, captures: [record]))
        #expect(result.pageNumber == 2)
        #expect(result.chapter == "Ch. 1")
        #expect(result.fingerprint != nil)

        // A page no local text covers is honestly unresolved: no guessed
        // page, no guessed chapter.
        #expect(
            ReadingContextResolver.resolve(
                pageText:
                    "A page this capture never saw, with enough words to be a real page.",
                kind: .kindle, identifier: nil, captures: [record]) == nil)
    }

    @Test("shared front matter does not make two books one identity")
    func fingerprintNeedsMoreThanFrontMatter() {
        let first = BookTextIndex(pages: [
            IndexedPage(page: 1, text: "A Shared Title Page"),
            IndexedPage(page: 2, text: "A Shared Copyright Page"),
            IndexedPage(page: 3, text: "Only the first book has this chapter."),
        ])
        let second = BookTextIndex(pages: [
            IndexedPage(page: 1, text: "A Shared Title Page"),
            IndexedPage(page: 2, text: "A Shared Copyright Page"),
            IndexedPage(page: 3, text: "Only the second book has this chapter."),
        ])
        #expect(first.fingerprint != second.fingerprint)
    }

    @Test("inline markup does not split a word")
    func inlineMarkup() {
        #expect(
            EPUBBookIndex.plainText(
                "<p>inter<em>national</em>ization and <strong>more</strong>.")
                == "internationalization and more.")
    }

    @Test("a toc nav ignores landmarks and a fragment selects its range")
    func tocAndFragment() {
        let html = """
            <nav epub:type="landmarks"><a href="ch1.xhtml">Start reading</a></nav>
            <nav epub:type="toc"><a href="ch2.xhtml#x">Chapter Two</a></nav>
            """
        let anchors = EPUBBookIndex.anchors(in: html)
        #expect(anchors.map(\.title) == ["Chapter Two"])

        let body = """
            <body><h2 id="one">One</h2><p>First chapter text here.</p>\
            <h2 id="two">Two</h2><p>Second chapter text here.</p>\
            <h2 id="three">Three</h2><p>Third chapter text here.</p></body>
            """
        let first = EPUBBookIndex.fragmentText(
            in: body, fragment: "one", next: ["two"])
        #expect(first?.contains("First chapter text") == true)
        #expect(first?.contains("Second chapter text") == false)

        // A marker that appears before the current fragment cannot end it;
        // the earliest marker after it must, even when another candidate is
        // out of document order (one→two→one→three).
        let second = EPUBBookIndex.fragmentText(
            in: body, fragment: "two", next: ["one", "three"])
        #expect(second?.contains("Second chapter text") == true)
        #expect(second?.contains("Third chapter text") == false)
    }

    @Test("an EPUB's navigation supplies the chapter, and DRM is refused")
    func epubNavigationAndDRM() throws {
        let root = try temporaryDirectory("epub")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """, to: root.appendingPathComponent("META-INF/container.xml"))
        try write(
            """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>A Test Book</dc:title>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>
            </package>
            """, to: root.appendingPathComponent("OEBPS/content.opf"))
        try write(
            """
            <?xml version="1.0"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <body><nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
                <ol>
                  <li><a href="ch1.xhtml">Chapter One. The First</a></li>
                  <li><a href="ch2.xhtml">Chapter Two. The Second</a></li>
                </ol>
              </nav></body>
            </html>
            """, to: root.appendingPathComponent("OEBPS/nav.xhtml"))
        try write(
            """
            <html><body><h1>Chapter One. The First</h1>
            <p>Alice was beginning to get very tired of sitting by her sister on the bank and of having nothing to do.</p>
            </body></html>
            """, to: root.appendingPathComponent("OEBPS/ch1.xhtml"))
        try write(
            """
            <html><body><h1>Chapter Two. The Second</h1>
            <p>There was nothing so very remarkable in that, nor did Alice think it so very much out of the way.</p>
            </body></html>
            """, to: root.appendingPathComponent("OEBPS/ch2.xhtml"))
        let index = try EPUBBookIndex(epubDirectory: root)
        #expect(
            index.chapter(containing:
                "There was nothing so very remarkable in that, nor did Alice think it so very much out of the way.")
                == "Chapter Two. The Second")
        #expect(
            index.chapter(containing:
                "Alice was beginning to get very tired of sitting by her sister on the bank")
                == "Chapter One. The First")

        try write(
            """
            <?xml version="1.0"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
              xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="http://example.com/unknown-drm"/>
                <enc:CipherData><enc:CipherReference URI="OEBPS/ch1.xhtml"/></enc:CipherData>
              </enc:EncryptedData>
            </encryption>
            """, to: root.appendingPathComponent("META-INF/encryption.xml"))
        #expect(throws: ReadingIndexError.self) {
            _ = try EPUBBookIndex(epubDirectory: root)
        }
    }

    @Test("the Books folder fallback finds an unpacked EPUB by title")
    func booksFolderFallback() throws {
        let documents = try temporaryDirectory("documents")
        defer { try? FileManager.default.removeItem(at: documents) }
        let book = documents.appendingPathComponent("A Test Book.epub")
        try write(
            """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """, to: book.appendingPathComponent("META-INF/container.xml"))
        try write(
            """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="ch1"/></spine>
            </package>
            """, to: book.appendingPathComponent("OEBPS/content.opf"))
        try write(
            """
            <html><body><nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
              <ol><li><a href="ch1.xhtml">Chapter One</a></li></ol>
            </nav></body></html>
            """, to: book.appendingPathComponent("OEBPS/nav.xhtml"))
        try write(
            "<html><body><p>Only the first chapter says this sentence, and it keeps going long enough for the shingle index to compare several windows against the live page text.</p></body></html>",
            to: book.appendingPathComponent("OEBPS/ch1.xhtml"))

        let indexes = ReadingContextResolver.epubIndexes(
            named: "A Test Book", in: documents)
        #expect(indexes.count == 1)
        #expect(
            indexes.first?.chapter(containing:
                "Only the first chapter says this sentence, and it keeps going long enough for the shingle index to compare")
                == "Chapter One")
        #expect(
            ReadingContextResolver.folded("Alice's Adventures in Wonderland")
                == "alicesadventuresinwonderland")
        #expect(
            ReadingContextResolver.epubIndexes(
                named: "Another Book", in: documents).isEmpty)
    }

    @Test("a chapter reaches the context and the prompt")
    func chapterInContextAndPrompt() {
        let context = AIContext(
            bookTitle: "A Book", reader: .kindle, pageNumber: 5,
            chapter: "Ch. 3", excerpt: "text")
        #expect(context.attachments.contains("Ch. 3"))
        let request = AIRequest(
            action: .explain, pageText: "Passage", bookTitle: "A Book",
            chapter: "Ch. 3")
        let prompt = AIComposer.prompt(
            for: request, settings: AISettings.defaults)
        #expect(prompt.contains("The passage is from Ch. 3."))
    }
}

@Suite("Passage lookup")
struct PassageLookupTests {
    private func capture(_ pages: [(Int, String)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-passage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let lines = try pages.map { page, text -> String in
            let object: [String: Any] = [
                "page": page, "text": text, "source": "accessibility",
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        return directory
    }

    @Test("a short highlight inside a page is found")
    func shortPassage() throws {
        let directory = try capture([
            (1, "Momentum is a direction, not a speed: it is where a trend is going."),
            (2, "Reversal is the moment a trend turns, and it is the hardest thing to see while it happens."),
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try BookTextIndex.load(directory: directory)
        // Five words, well under the page matcher's 20-character floor for a
        // whole-page match, and under its three-shingle rule.
        let match = try #require(
            index.containing(passage: "the hardest thing to see"))
        #expect(match.page == 2)
    }

    @Test("a passage too short to locate is not searched")
    func tooShort() throws {
        let directory = try capture([
            (1, "Momentum is a direction, not a speed.")
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try BookTextIndex.load(directory: directory)
        // "the" occurs on every page; a match would be a coincidence, not a
        // location.
        #expect(index.containing(passage: "the") == nil)
    }

    @Test("a passage from no page is not found")
    func absentPassage() throws {
        let directory = try capture([
            (1, "Momentum is a direction, not a speed: it is where a trend is going.")
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try BookTextIndex.load(directory: directory)
        #expect(index.containing(passage: "not in this book at all") == nil)
    }
}
