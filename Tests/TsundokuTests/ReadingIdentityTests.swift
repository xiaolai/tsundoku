import Foundation
import Testing

@testable import TsundokuCore

@Suite("Reading identity")
struct ReadingIdentityTests {
    private func book(
        _ asin: String, _ title: String, _ source: BookSource = .kindle
    ) -> Book {
        Book(
            asin: asin, title: title, author: "A", bookType: 10,
            readState: 0, source: source)
    }

    private func capture(
        _ fingerprint: String, _ title: String, _ confidence: String?
    ) -> CaptureEvidence {
        CaptureEvidence(
            fingerprint: fingerprint, title: title, confidence: confidence)
    }

    @Test("the identity matrix yields one deterministic key and no Kindle bucket")
    func identityMatrix() {
        let archiveMatch = [book("B0ARCH0001", "The Book")]
        let duplicate = [
            book("B0DUP00001", "The Book", .appleBooks),
            book("B0DUP00002", "The Book", .appleBooks),
        ]
        let noArchive: [Book] = []
        let exact = capture("f00d", "The Book", "exact")

        struct Case {
            let name: String
            let facts: ReadingLiveFacts
            let books: [Book]
            let rank: ReadingIdentity.Rank
            let key: String?
        }
        let cases: [Case] = [
            // ASIN known × {match, duplicate, none} × {capture, none}
            Case(
                name: "asin + archive match + capture",
                facts: ReadingLiveFacts(
                    kind: .kindle, title: "Kindle", identifier: "B0ARCH0001",
                    capture: exact),
                books: archiveMatch, rank: .archiveMatch, key: "B0ARCH0001"),
            Case(
                name: "asin + archive match + no capture",
                facts: ReadingLiveFacts(
                    kind: .kindle, title: "Kindle", identifier: "B0ARCH0001"),
                books: archiveMatch, rank: .archiveMatch, key: "B0ARCH0001"),
            Case(
                name: "asin + duplicate titles + capture",
                facts: ReadingLiveFacts(
                    kind: .kindle, title: "Kindle", identifier: "B0DUP00002",
                    capture: exact),
                books: duplicate, rank: .archiveMatch, key: "B0DUP00002"),
            Case(
                name: "asin + duplicate titles + no capture",
                facts: ReadingLiveFacts(
                    kind: .kindle, title: "Kindle", identifier: "B0DUP00002"),
                books: duplicate, rank: .archiveMatch, key: "B0DUP00002"),
            Case(
                name: "asin + no archive + capture",
                facts: ReadingLiveFacts(
                    kind: .kindle, title: "Kindle", identifier: "B0NEW00001",
                    capture: exact),
                books: noArchive, rank: .lastOpened, key: "B0NEW00001"),
            Case(
                name: "asin + no archive + no capture",
                facts: ReadingLiveFacts(
                    kind: .kindle, title: "Kindle", identifier: "B0NEW00001"),
                books: noArchive, rank: .lastOpened, key: "B0NEW00001"),
            // ASIN unknown × {archive title match, duplicate, none} × capture
            Case(
                name: "no asin + archive title match + capture",
                facts: ReadingLiveFacts(
                    kind: .appleBooks, title: "The Book", capture: exact),
                books: archiveMatch, rank: .captureText, key: "text:f00d"),
            Case(
                name: "no asin + archive title match + no capture",
                facts: ReadingLiveFacts(kind: .appleBooks, title: "The Book"),
                books: archiveMatch, rank: .titleMatch, key: "books:the book"),
            Case(
                name: "no asin + duplicate titles + capture",
                facts: ReadingLiveFacts(
                    kind: .appleBooks, title: "The Book", capture: exact),
                books: duplicate, rank: .captureText, key: "text:f00d"),
            Case(
                name: "no asin + duplicate titles + no capture",
                facts: ReadingLiveFacts(kind: .appleBooks, title: "The Book"),
                books: duplicate, rank: .titleMatch, key: "books:the book"),
            Case(
                name: "no asin + no archive + capture",
                facts: ReadingLiveFacts(
                    kind: .kindle, title: "Kindle", capture: exact),
                books: noArchive, rank: .captureText, key: "text:f00d"),
            Case(
                name: "no asin + no archive + no capture (Kindle)",
                facts: ReadingLiveFacts(kind: .kindle, title: "Kindle"),
                books: noArchive, rank: .sessionOnly, key: nil),
            Case(
                name: "no asin + no archive + no capture (Books title)",
                facts: ReadingLiveFacts(kind: .appleBooks, title: "The Book"),
                books: noArchive, rank: .titleMatch, key: "books:the book"),
        ]
        for item in cases {
            let first = ReadingIdentityResolver.resolve(
                facts: item.facts, books: item.books)
            let second = ReadingIdentityResolver.resolve(
                facts: item.facts, books: item.books)
            #expect(first == second, "\(item.name) must be deterministic")
            #expect(first.rank == item.rank, "\(item.name): \(first.provenance)")
            #expect(first.key == item.key, "\(item.name): \(first.provenance)")
            #expect(first.key != "kindle:kindle", "\(item.name)")
            #expect(first.key != "kindle", "\(item.name)")
        }
    }

    @Test("a capture's title is used only at exact confidence")
    func captureTitleTrust() {
        let live = ReadingLiveFacts(
            kind: .kindle, title: "Kindle",
            capture: capture("abc123", "Weapons of Math Destruction", "unknown"))
        let identity = ReadingIdentityResolver.resolve(facts: live, books: [])
        #expect(identity.key == "text:abc123")
        #expect(identity.title.isEmpty)
        #expect(identity.headerTitle == "Current Page")

        let exact = ReadingIdentityResolver.resolve(
            facts: ReadingLiveFacts(
                kind: .kindle, title: "Kindle",
                capture: capture("abc123", "The Math of Neural Networks", "exact")),
            books: [])
        #expect(exact.title == "The Math of Neural Networks")
    }

    @Test("EPUB text picks the edition and its asset ID")
    func editionSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-editions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeEPUB(
            at: root.appendingPathComponent("first"),
            chapter: "Alice was beginning to get very tired of sitting by her sister on the bank and of having nothing to do.")
        let second = try makeEPUB(
            at: root.appendingPathComponent("second"),
            chapter: "There was nothing so very remarkable in that, nor did Alice think it so very much out of the way as she peeped into the book her sister was reading.")
        let indexes = ["EDITION-A": first, "EDITION-B": second]
        let match = try #require(
            ReadingContextResolver.edition(
                matching: "There was nothing so very remarkable in that, nor did Alice think it so very much out of the way",
                identifiers: ["EDITION-A", "EDITION-B"],
                index: { indexes[$0] }))
        #expect(match.identifier == "EDITION-B")
        #expect(match.chapter == "Chapter One")

        // The same page in both editions: the sorted identifier decides, so
        // the answer does not depend on archive row order.
        let tied = try #require(
            ReadingContextResolver.edition(
                matching: "Alice was beginning to get very tired of sitting by her sister on the bank",
                identifiers: ["EDITION-B", "EDITION-A"],
                index: { indexes[$0] }))
        #expect(tied.identifier == "EDITION-A")
    }

    @Test("an unarchived EPUB asset outranks an archived reader identifier")
    func epubOutranksIdentifier() {
        let identity = ReadingIdentityResolver.resolve(
            facts: ReadingLiveFacts(
                kind: .appleBooks, title: "Alice", identifier: "ASSET-1",
                epubAssetID: "ASSET-2"),
            books: [book("ASSET-1", "Alice", .appleBooks)])
        #expect(identity.key == "ASSET-2")
        #expect(identity.rank == .archiveMatch)
        #expect(identity.provenance.contains("EPUB"))
    }

    @Test("an unimported Books asset ID is keyed in canonical case")
    func assetIDCasing() {
        let identity = ReadingIdentityResolver.resolve(
            facts: ReadingLiveFacts(
                kind: .appleBooks, title: "Alice", identifier: "asset-2"),
            books: [])
        #expect(identity.key == "ASSET-2")
        #expect(identity.rank == .archiveMatch)
    }

    @Test("an EPUB asset ID outranks a title key")
    func assetIDOutranksTitle() {
        let identity = ReadingIdentityResolver.resolve(
            facts: ReadingLiveFacts(
                kind: .appleBooks, title: "Alice", epubAssetID: "ASSET-2"),
            books: [
                book("ASSET-1", "Alice", .appleBooks),
                book("ASSET-2", "Alice", .appleBooks),
            ])
        #expect(identity.rank == .archiveMatch)
        #expect(identity.key == "ASSET-2")
        #expect(identity.book?.asin == "ASSET-2")
        #expect(identity.rank < .titleMatch)
    }

    @Test("a placeholder title is never a key")
    func placeholderTitles() {
        for title in ["Kindle", "kindle", "Apple Books", "Unknown", "  "] {
            let identity = ReadingIdentityResolver.resolve(
                facts: ReadingLiveFacts(kind: .appleBooks, title: title),
                books: [])
            #expect(identity.key == nil, "\(title)")
            #expect(identity.title.isEmpty, "\(title)")
            #expect(identity.headerTitle == "Current Page", "\(title)")
        }
    }

    @Test("a migration moves threads without duplication or loss")
    func migration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        let titleKey = "books:alice"
        let assetKey = "ASSET-2"
        let conversation = try archive.createConversation(
            bookKey: titleKey, bookTitle: "", bookSource: nil)
        try archive.appendConversationTurn(
            conversationID: conversation.id, action: .explain, question: "",
            answer: "an answer", provider: "p", prompt: "", context: .empty)
        try archive.migrateConversations(
            from: titleKey, to: assetKey, title: "Alice", source: .appleBooks)
        #expect(try archive.latestConversation(bookKey: titleKey) == nil)
        let moved = try #require(try archive.latestConversation(bookKey: assetKey))
        #expect(moved.id == conversation.id)
        #expect(moved.bookTitle == "Alice")
        #expect(moved.bookSource == .appleBooks)
        #expect(
            try archive.conversationTurns(conversationID: moved.id).count == 1)

        // A second thread under the old key joins the same book; the first
        // is untouched, and rerunning the migration changes nothing.
        let second = try archive.createConversation(
            bookKey: titleKey, bookTitle: "", bookSource: nil)
        try archive.migrateConversations(
            from: titleKey, to: assetKey, title: "Alice", source: .appleBooks)
        try archive.migrateConversations(
            from: titleKey, to: assetKey, title: "Alice", source: .appleBooks)
        let summaries = try archive.conversations(bookKey: assetKey)
        #expect(summaries.count == 2)
        #expect(Set(summaries.map(\.id)) == [conversation.id, second.id])
    }

    // MARK: Fixtures

    private func makeEPUB(at root: URL, chapter: String) throws -> EPUBBookIndex {
        try write(
            """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """, to: root.appendingPathComponent("META-INF/container.xml"))
        try write(
            """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="ch1"/></spine>
            </package>
            """, to: root.appendingPathComponent("OEBPS/content.opf"))
        try write(
            """
            <html><body><nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
              <ol><li><a href="ch1.xhtml">Chapter One</a></li></ol>
            </nav></body></html>
            """, to: root.appendingPathComponent("OEBPS/nav.xhtml"))
        try write(
            "<html><body><p>\(chapter)</p></body></html>",
            to: root.appendingPathComponent("OEBPS/ch1.xhtml"))
        return try EPUBBookIndex(epubDirectory: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
