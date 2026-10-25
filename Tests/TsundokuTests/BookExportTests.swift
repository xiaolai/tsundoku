import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import TsundokuCore

// MARK: - Fixtures

private enum FixtureError: Error {
    case couldNotMakeImage
    case couldNotEncode
    case couldNotMakePDF
    case couldNotWrite
}

private func temporaryDirectory(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "tsundoku-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true)
    return url
}

private func jpegData(
    width: Int = 60, height: Int = 90, gray: CGFloat = 0.7
) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw FixtureError.couldNotMakeImage }
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw FixtureError.couldNotMakeImage
    }
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw FixtureError.couldNotEncode }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw FixtureError.couldNotEncode
    }
    return data as Data
}

private func pngFile(
    width: Int = 60, height: Int = 90, in directory: URL
) throws -> URL {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw FixtureError.couldNotMakeImage }
    context.setFillColor(CGColor(gray: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw FixtureError.couldNotMakeImage
    }
    let url = directory.appendingPathComponent("\(UUID().uuidString).png")
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw FixtureError.couldNotEncode }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw FixtureError.couldNotEncode
    }
    return url
}

private func pdfData(
    pages: Int = 1, encrypted: Bool = false
) throws -> Data {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
    var metadata: [CFString: Any] = [kCGPDFContextCreator: "Tsundoku tests"]
    if encrypted {
        metadata[kCGPDFContextUserPassword] = "user"
        metadata[kCGPDFContextOwnerPassword] = "owner"
        metadata[kCGPDFContextEncryptionKeyLength] = 128
    }
    guard
        let consumer = CGDataConsumer(data: data as CFMutableData),
        let context = CGContext(
            consumer: consumer, mediaBox: &mediaBox,
            metadata as CFDictionary)
    else { throw FixtureError.couldNotMakePDF }
    for _ in 0..<pages {
        context.beginPage(mediaBox: &mediaBox)
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(mediaBox)
        context.endPage()
    }
    context.closePDF()
    return data as Data
}

private struct EPUBFixture {
    let root: URL
    let opfURL: URL
    let coverURL: URL

    static func make(
        in parent: URL, publisher: String? = "Test Press",
        date: String? = "2024-01-02", cover: Bool = true,
        encryption: Bool = false,
        encryptionAlgorithm: String = "urn:test:encryption"
    ) throws -> EPUBFixture {
        let root = parent.appendingPathComponent(
            "Synthetic Book.epub")
        let meta = root.appendingPathComponent("META-INF")
        let oebps = root.appendingPathComponent("OEBPS")
        let images = oebps.appendingPathComponent("images")
        for directory in [root, meta, oebps, images] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        try "application/epub+zip".write(
            to: root.appendingPathComponent("mimetype"),
            atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf"
              media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(
            to: meta.appendingPathComponent("container.xml"),
            atomically: true, encoding: .utf8)
        var metadata = """
            <dc:title>Synthetic Title</dc:title>
            <dc:creator>Ada Lovelace</dc:creator>
            <dc:language>en</dc:language>
            <dc:identifier opf:scheme="ASIN">B0SYNTHETIC</dc:identifier>
            <meta name="cover" content="cover-image"/>
        """
        if let publisher {
            metadata += "\n    <dc:publisher>\(publisher)</dc:publisher>"
        }
        if let date {
            metadata += "\n    <dc:date>\(date)</dc:date>"
        }
        var manifest = ""
        if cover {
            manifest =
                """
                <item id="cover-image" href="images/cover.jpg"
                  media-type="image/jpeg"/>
                """
        }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf"
                 xmlns:opf="http://www.idpf.org/2007/opf"
                 version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(metadata)
          </metadata>
          <manifest>
            \(manifest)
          </manifest>
        </package>
        """
        let opfURL = oebps.appendingPathComponent("content.opf")
        try opf.write(to: opfURL, atomically: true, encoding: .utf8)
        let coverURL = images.appendingPathComponent("cover.jpg")
        if cover {
            try jpegData().write(to: coverURL)
        }
        if encryption {
            try """
            <?xml version="1.0"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                        xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="\(encryptionAlgorithm)"/>
              </enc:EncryptedData>
            </encryption>
            """.write(
                to: meta.appendingPathComponent("encryption.xml"),
                atomically: true, encoding: .utf8)
        }
        return EPUBFixture(root: root, opfURL: opfURL, coverURL: coverURL)
    }
}

private struct FakeFetcher: CoverDataFetching {
    let data: Data?
    let error: CoverFetchError?

    init(data: Data? = nil, error: CoverFetchError? = nil) {
        self.data = data
        self.error = error
    }

    func fetch(
        _ url: URL, timeout: TimeInterval, byteLimit: Int
    ) throws -> Data {
        if let error { throw error }
        return data ?? Data()
    }
}

private final class URLRecordingFetcher: CoverDataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    private let data: Data

    init(data: Data) { self.data = data }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func fetch(
        _ url: URL, timeout: TimeInterval, byteLimit: Int
    ) throws -> Data {
        lock.lock()
        stored.append(url)
        let isFirst = stored.count == 1
        lock.unlock()
        if isFirst { throw CoverFetchError.status(404) }
        return data
    }
}

private struct StubBooksProvider: BooksAssetProviding {
    let asset: BooksAsset?

    func asset(for asin: String) throws -> BooksAsset? { asset }
}

// MARK: - EPUB and metadata

@Suite("Book export metadata")
struct BookExportMetadataTests {
    @Test("an OPF supplies title, creator, publisher, date and cover")
    func parsesOPF() throws {
        let directory = try temporaryDirectory("opf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let package = try EPUBPackage.load(
            fromEPUBDirectory: fixture.root)
        #expect(package.title == "Synthetic Title")
        #expect(package.creators == ["Ada Lovelace"])
        #expect(package.publisher == "Test Press")
        #expect(package.publishedDate == "2024-01-02")
        #expect(package.language == "en")
        #expect(package.identifier == "B0SYNTHETIC")
        #expect(package.identifierScheme == "ASIN")
        #expect(package.coverImageURL == fixture.coverURL)
    }

    @Test("the first rootfile is the package, not the last")
    func firstRootfile() throws {
        let directory = try temporaryDirectory("opf-rootfiles")
        defer { try? FileManager.default.removeItem(at: directory) }
        let meta = directory.appendingPathComponent("META-INF")
        let oebps = directory.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(
            at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: oebps, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/first.opf"
              media-type="application/oebps-package+xml"/>
            <rootfile full-path="OEBPS/second.opf"
              media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(
            to: meta.appendingPathComponent("container.xml"),
            atomically: true, encoding: .utf8)
        for (name, title) in [
            ("first.opf", "First Title"),
            ("second.opf", "Second Title"),
        ] {
            try """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title>
              </metadata>
              <manifest/>
            </package>
            """.write(
                to: oebps.appendingPathComponent(name),
                atomically: true, encoding: .utf8)
        }
        let package = try EPUBPackage.load(fromEPUBDirectory: directory)
        #expect(package.title == "First Title")
    }

    @Test("a book with no publisher or date leaves those fields nil")
    func missingFields() throws {
        let directory = try temporaryDirectory("opf-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(
            in: directory, publisher: nil, date: nil)
        let package = try EPUBPackage.load(
            fromEPUBDirectory: fixture.root)
        #expect(package.publisher == nil)
        #expect(package.publishedDate == nil)
        #expect(package.title == "Synthetic Title")
    }

    @Test("an OPF cover href outside the book is refused")
    func rejectsTraversal() throws {
        let directory = try temporaryDirectory("opf-traversal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Escapes</dc:title>
            <meta name="cover" content="cover-id"/>
          </metadata>
          <manifest>
            <item id="cover-id" href="../../outside.jpg"
              media-type="image/jpeg"/>
          </manifest>
        </package>
        """
        let opfURL = directory.appendingPathComponent("content.opf")
        try opf.write(to: opfURL, atomically: true, encoding: .utf8)
        #expect(throws: EPUBError.self) {
            _ = try EPUBPackage.parse(
                opfData: Data(opf.utf8), opfURL: opfURL,
                rootURL: directory)
        }
    }

    @Test("the Kindle metadata cache is keyed by normalized ASIN")
    func kindleCache() throws {
        let directory = try temporaryDirectory("kindle-cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("metadata.json")
        try """
        {"locale":"en_US","entries":[
          null,
          {"asin":"B0BROKEN"},
          {"asin":"B0CACHE","title":"Cache Title",
           "coverImage":{"physicalId":"abc+123","altText":"Cache Title",
                         "fileExtension":"jpg"}}]}
        """.write(to: cacheURL, atomically: true, encoding: .utf8)
        let cache = KindleMetadataCache.load(path: cacheURL)
        let entry = try #require(cache.entry(for: "b0cache"))
        #expect(entry.title == "Cache Title")
        #expect(entry.coverPhysicalID == "abc+123")
        #expect(entry.coverAltText == "Cache Title")
        #expect(entry.coverFileExtension == "jpg")
    }

    @Test("the cache cover alt text is a title fallback")
    func cacheAltTextFallback() throws {
        let directory = try temporaryDirectory("kindle-alt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let cache = container.appendingPathComponent(
            "Caches/BookMetadataCache")
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: true)
        try """
        {"entries":[{"asin":"B0ALT","coverImage":
          {"physicalId":"physical","altText":"Alt Title"}}]}
        """.write(
            to: cache.appendingPathComponent("metadata.json"),
            atomically: true, encoding: .utf8)
        let resolver = BookMetadataResolver(
            kindlePaths: KindlePaths(container: container))
        let book = Book(
            asin: "B0ALT", title: "Untitled", author: "",
            bookType: 10, readState: 0, source: .kindle)
        let metadata = resolver.resolve(book)
        #expect(metadata.title == "Alt Title")
        #expect(metadata.sources["title"] == .kindleMetadataCache)
    }

    @Test("a capture with no library book titles itself from the reader")
    func metadataWithoutABook() throws {
        // The Reader picker can capture a Kindle book the library never
        // imported; the observed title and ASIN carry the bundle.
        let directory = try temporaryDirectory("kindle-nil-book")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = BookMetadataResolver(
            kindlePaths: KindlePaths(container: directory))
        let metadata = resolver.resolve(
            book: nil, capturedTitle: "Winning At New Products",
            identifier: "B0KINDLENIL", source: .kindle)
        #expect(metadata.title == "Winning At New Products")
        #expect(metadata.sources["title"] == .observed)
        #expect(metadata.identifier == "B0KINDLENIL")
    }

    @Test("a Kindle book resolves its cache cover and DRM-free AZW original")
    func kindleMetadata() throws {
        let directory = try temporaryDirectory("kindle-meta")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let cache = container.appendingPathComponent(
            "Caches/BookMetadataCache")
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: true)
        try """
        {"locale":"en_US","entries":[
          {"asin":"B0KINDLE","title":"Cache Title",
           "coverImage":{"physicalId":"physical-id",
                         "altText":"Cache Title"}}]}
        """.write(
            to: cache.appendingPathComponent("metadata.json"),
            atomically: true, encoding: .utf8)
        let bookDirectory = container.appendingPathComponent(
            "eBooks/B0KINDLE/asset-id")
        try FileManager.default.createDirectory(
            at: bookDirectory, withIntermediateDirectories: true)
        try clearAZWData().write(
            to: bookDirectory.appendingPathComponent("book.azw"))
        let paths = KindlePaths(container: container)
        let resolver = BookMetadataResolver(kindlePaths: paths)
        let book = Book(
            asin: "B0KINDLE", title: "Archive Title", author: "Author",
            bookType: 10, readState: 0, source: .kindle)
        let metadata = resolver.resolve(book)
        #expect(metadata.title == "Archive Title")
        #expect(metadata.sources["title"] == .archive)
        #expect(metadata.cover == .kindlePhysicalId("physical-id"))
        #expect(metadata.sources["cover"] == .kindleMetadataCache)
        guard case .available(let kind, let url) = metadata.original else {
            Issue.record("expected an available original")
            return
        }
        #expect(kind == .azw)
        #expect(url.lastPathComponent == "book.azw")
    }

    @Test("a Kindle DRM voucher marks the original protected")
    func kindleProtected() throws {
        let directory = try temporaryDirectory("kindle-drm")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let bookDirectory = container.appendingPathComponent(
            "eBooks/B0PROTECTED/id")
        try FileManager.default.createDirectory(
            at: bookDirectory, withIntermediateDirectories: true)
        try Data("book".utf8).write(
            to: bookDirectory.appendingPathComponent("book.azw"))
        try Data("voucher".utf8).write(
            to: bookDirectory.appendingPathComponent(
                "amzn1.drm-voucher.v1.test.voucher"))
        let availability = OriginalDetector.kindle(
            asin: "B0PROTECTED",
            paths: KindlePaths(container: container))
        guard case .protected = availability else {
            Issue.record("expected a protected original")
            return
        }
    }

    @Test("a Books book without an exact identifier is marked unverified")
    func booksWithoutIdentifier() throws {
        let directory = try temporaryDirectory("books-no-id")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = BookMetadataResolver(
            kindlePaths: KindlePaths(
                container: directory.appendingPathComponent("none")),
            booksAssets: nil, kindleCache: KindleMetadataCache())
        let book = Book(
            asin: "", title: "", author: "", bookType: 10, readState: 0,
            source: .appleBooks)
        let metadata = resolver.resolve(
            book: book, capturedTitle: "A Book", identifier: nil,
            source: .appleBooks)
        #expect(metadata.title == "A Book")
        #expect(metadata.original == .missing)
        #expect(metadata.cover == .generated)
        #expect(metadata.warnings.contains {
            $0.contains("unverified")
        })
    }

    @Test("a Books EPUB supplies OPF fields and a DRM-free original")
    func booksMetadata() throws {
        let directory = try temporaryDirectory("books-meta")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let asset = BooksAsset.load(
            assetID: "ASSET01", path: fixture.root, contentType: .epub)
        let resolver = BookMetadataResolver(
            kindlePaths: KindlePaths(
                container: directory.appendingPathComponent("none")),
            booksAssets: StubBooksProvider(asset: asset),
            kindleCache: KindleMetadataCache())
        let book = Book(
            asin: "ASSET01", title: "", author: "",
            bookType: 10, readState: 0, source: .appleBooks)
        let metadata = resolver.resolve(book)
        #expect(metadata.title == "Synthetic Title")
        #expect(metadata.author == "Ada Lovelace")
        #expect(metadata.publisher == "Test Press")
        #expect(metadata.language == "en")
        #expect(metadata.publishedDate == "2024-01-02")
        #expect(metadata.sources["publisher"] == .epubOPF)
        #expect(metadata.cover == .epubImage(fixture.coverURL))
        guard case .available(let kind, _) = metadata.original else {
            Issue.record("expected an available original")
            return
        }
        #expect(kind == .epub)
    }
}

// MARK: - Books asset and original

@Suite("Books asset and original detection")
struct BooksAssetTests {
    @Test("an unpacked EPUB is read with its package and clear DRM")
    func unpackedEPUB() throws {
        let directory = try temporaryDirectory("asset-epub")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let asset = BooksAsset.load(
            assetID: "asset01", path: fixture.root, contentType: .epub)
        #expect(asset.assetID == "ASSET01")
        #expect(asset.pathKind == .unpackedEPUB)
        #expect(asset.contentType == .epub)
        #expect(asset.package?.title == "Synthetic Title")
        #expect(asset.drm == .clear)
        #expect(asset.warnings.isEmpty)
    }

    @Test("encryption.xml makes an EPUB protected")
    func protectedEPUB() throws {
        let directory = try temporaryDirectory("asset-drm")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory, encryption: true)
        let asset = BooksAsset.load(
            assetID: "ASSETDRM", path: fixture.root, contentType: .epub)
        #expect(asset.drm.isProtected)
        #expect(OriginalDetector.books(asset: asset).isAvailable == false)
    }

    @Test("standard EPUB font obfuscation is not DRM")
    func fontObfuscation() throws {
        let directory = try temporaryDirectory("asset-font")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(
            in: directory, encryption: true,
            encryptionAlgorithm: "http://www.idpf.org/2008/embedding")
        let asset = BooksAsset.load(
            assetID: "FONT", path: fixture.root, contentType: .epub)
        #expect(asset.drm == .clear)
        guard case .available(.epub, _) = OriginalDetector.books(asset: asset)
        else {
            Issue.record("expected the font-obfuscated EPUB to be available")
            return
        }
        let copied = try OriginalService.copy(
            .available(kind: .epub, url: fixture.root),
            into: directory.appendingPathComponent("out"))
        #expect(copied.url.lastPathComponent == "original.epub")
        #expect(
            ZIPArchive.containsEntry(
                at: copied.url, name: "META-INF/encryption.xml") == true)
    }

    @Test("a missing path is missing, not protected")
    func missingPath() throws {
        let directory = try temporaryDirectory("asset-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = BooksAsset.load(
            assetID: "ASSETMISSING",
            path: directory.appendingPathComponent("gone.epub"),
            contentType: .epub)
        #expect(asset.pathKind == .missing)
        #expect(OriginalDetector.books(asset: asset) == .missing)
    }

    @Test("an iCloud placeholder is dataless until it materialises")
    func datalessAsset() {
        #expect(
            BooksAsset.dataless(
                isUbiquitous: true, downloadingStatus: .notDownloaded))
        #expect(
            !BooksAsset.dataless(
                isUbiquitous: true, downloadingStatus: .current))
        #expect(
            !BooksAsset.dataless(
                isUbiquitous: false, downloadingStatus: .notDownloaded))
        let missing = BooksAsset(
            assetID: "ICLOUD", path: nil, contentType: .epub,
            pathKind: .missing, package: nil, drm: .unknown(reason: "test"),
            isDataless: true)
        #expect(OriginalDetector.books(asset: missing) == .missing)
    }

    @Test("asset lookup does not need the annotation database")
    func libraryOnlySnapshot() throws {
        let directory = try temporaryDirectory("books-library-only")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Container")
        let libraryDirectory = container.appendingPathComponent(
            "Documents/BKLibrary")
        try FileManager.default.createDirectory(
            at: libraryDirectory, withIntermediateDirectories: true)
        let fixture = try EPUBFixture.make(in: directory)
        let databaseURL = libraryDirectory.appendingPathComponent(
            "BKLibrary-test.sqlite")
        let database = try SQLiteDatabase(path: databaseURL.path)
        try database.execute(
            """
            CREATE TABLE ZBKLIBRARYASSET (
              ZASSETID TEXT, ZCONTENTTYPE INTEGER, ZPATH TEXT
            )
            """)
        try database.execute(
            "INSERT INTO ZBKLIBRARYASSET VALUES (?, ?, ?)",
            [
                .text("ASSET01"), .integer(1),
                .text(fixture.root.path),
            ])
        #expect(
            !FileManager.default.fileExists(
                atPath: container.appendingPathComponent(
                    "Documents/AEAnnotation").path))
        let reader = BooksAssetReader(
            paths: BooksPaths(container: container))
        let asset = try #require(try reader.asset(for: "asset01"))
        #expect(asset.package?.title == "Synthetic Title")
    }

    @Test("a PDF's first page and encryption flag are detected")
    func pdfAsset() throws {
        let directory = try temporaryDirectory("asset-pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clearURL = directory.appendingPathComponent("clear.pdf")
        try pdfData().write(to: clearURL)
        let clear = BooksAsset.load(
            assetID: "CLEAR", path: clearURL, contentType: .pdf)
        #expect(clear.pathKind == .file)
        #expect(clear.drm == .clear)
        guard case .available(let kind, _) = OriginalDetector.books(
            asset: clear)
        else {
            Issue.record("expected the PDF to be available")
            return
        }
        #expect(kind == .pdf)

        let protectedURL = directory.appendingPathComponent("protected.pdf")
        try pdfData(encrypted: true).write(to: protectedURL)
        let protected = BooksAsset.load(
            assetID: "PROTECTED", path: protectedURL, contentType: .pdf)
        #expect(protected.drm.isProtected)
        #expect(
            OriginalDetector.books(asset: protected).isAvailable == false)
    }

    @Test("a zipped EPUB is inspected without extracting it")
    func zippedEPUB() throws {
        let directory = try temporaryDirectory("asset-zip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.epub")
        try FileManager.default.createDirectory(
            at: source, withIntermediateDirectories: true)
        try "application/epub+zip".write(
            to: source.appendingPathComponent("mimetype"),
            atomically: true, encoding: .utf8)
        let meta = source.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(
            at: meta, withIntermediateDirectories: true)
        try "<container/>".write(
            to: meta.appendingPathComponent("container.xml"),
            atomically: true, encoding: .utf8)
        let zipURL = directory.appendingPathComponent("book.epub")
        try ZIPArchive.write(directory: source, to: zipURL)
        #expect(
            ZIPArchive.containsEntry(at: zipURL, name: "mimetype") == true)
        #expect(
            ZIPArchive.containsEntry(
                at: zipURL, name: "META-INF/encryption.xml") == false)
        let asset = BooksAsset.load(
            assetID: "ZIP", path: zipURL, contentType: .epub)
        #expect(asset.pathKind == .file)
        #expect(asset.drm == .clear)
        guard case .available(let kind, _) = OriginalDetector.books(
            asset: asset)
        else {
            Issue.record("expected the zipped EPUB to be available")
            return
        }
        #expect(kind == .epub)
    }

    @Test("an unpacked EPUB re-zips with mimetype first")
    func rezipOriginal() throws {
        let directory = try temporaryDirectory("original")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let availability = OriginalAvailability.available(
            kind: .epub, url: fixture.root)
        let output = directory.appendingPathComponent("export")
        let copied = try OriginalService.copy(availability, into: output)
        #expect(copied.kind == .epub)
        #expect(copied.url.lastPathComponent == "original.epub")
        #expect(FileManager.default.fileExists(atPath: copied.url.path))
        #expect(copied.bytes > 0)
        #expect(
            ZIPArchive.containsEntry(
                at: copied.url, name: "META-INF/container.xml") == true)
        let handle = try FileHandle(forReadingFrom: copied.url)
        defer { try? handle.close() }
        let head = try #require(try handle.read(upToCount: 30))
        let nameLength = Int(head[26]) | (Int(head[27]) << 8)
        let method = Int(head[8]) | (Int(head[9]) << 8)
        #expect(method == 0)
        let nameData = try #require(
            try handle.read(upToCount: nameLength))
        #expect(String(decoding: nameData, as: UTF8.self) == "mimetype")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", copied.url.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
    }

    @Test("a Kindle file is copied with its format")
    func copiesKindleFile() throws {
        let directory = try temporaryDirectory("original-azw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("book.azw")
        let bytes = clearAZWData()
        try bytes.write(to: source)
        let copied = try OriginalService.copy(
            .available(kind: .azw, url: source),
            into: directory.appendingPathComponent("export"))
        #expect(copied.kind == .azw)
        #expect(copied.url.lastPathComponent == "original.azw")
        #expect(try Data(contentsOf: copied.url) == bytes)
    }

    @Test("a symlinked Kindle source is copied as a regular file")
    func copiesSymlinkedSource() throws {
        let directory = try temporaryDirectory("original-symlink-source")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real.azw")
        let bytes = clearAZWData()
        try bytes.write(to: target)
        let link = directory.appendingPathComponent("book.azw")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target)
        let copied = try OriginalService.copy(
            .available(kind: .azw, url: link),
            into: directory.appendingPathComponent("export"))
        let values = try copied.url.resourceValues(
            forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink != true)
        #expect(try Data(contentsOf: copied.url) == bytes)

        let relativeLink = directory.appendingPathComponent(
            "relative.azw")
        try FileManager.default.createSymbolicLink(
            atPath: relativeLink.path,
            withDestinationPath: "real.azw")
        let relativeCopy = try OriginalService.copy(
            .available(kind: .azw, url: relativeLink),
            into: directory.appendingPathComponent("export-relative"),
            destinationName: "relative.azw")
        #expect(try Data(contentsOf: relativeCopy.url) == bytes)
        let relativeValues = try relativeCopy.url.resourceValues(
            forKeys: [.isSymbolicLinkKey])
        #expect(relativeValues.isSymbolicLink != true)
    }

    @Test("a book is matched only in the requested source")
    func bookLookupUsesSource() {
        let kindle = Book(
            asin: "B0SAME", title: "Kindle Title", author: "",
            bookType: 10, readState: 0, source: .kindle)
        let books = Book(
            asin: "B0SAME", title: "Books Title", author: "",
            bookType: 10, readState: 0, source: .appleBooks)
        #expect(
            BookLookup.book(
                asin: "B0SAME", source: .kindle,
                in: [books, kindle])?.title == "Kindle Title")
        #expect(
            BookLookup.book(
                asin: "B0SAME", source: .appleBooks,
                in: [books, kindle])?.title == "Books Title")
        #expect(
            BookLookup.book(
                asin: "amzn://B0SAME/reader", source: .kindle,
                in: [kindle])?.title == "Kindle Title")
        #expect(
            BookLookup.book(
                asin: "B0OTHER", source: .kindle,
                in: [books, kindle]) == nil)
    }

    @Test("a dataless asset is not available and is never offered")
    func datalessAssetIsUnavailable() throws {
        let directory = try temporaryDirectory("dataless-available")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        #expect(!BooksAsset.containsDatalessResource(in: fixture.root))
        #expect(!BooksAsset.isDataless(fixture.root))
        let dataless = BooksAsset(
            assetID: "CLOUD", path: fixture.root, contentType: .epub,
            pathKind: .unpackedEPUB, package: nil,
            drm: .clear, isDataless: true)
        #expect(!dataless.isAvailable)
        #expect(OriginalDetector.books(asset: dataless) == .missing)
        // A partially downloaded directory is rejected before its package
        // or encryption metadata is read.
        // A nested chapter is the placeholder while root metadata is
        // downloaded: discovery must descend into OEBPS to find it.
        let chapter = fixture.root.appendingPathComponent(
            "OEBPS/chapter.xhtml")
        let placeholder: (URL, URLResourceValues) -> Bool = { url, _ in
            url.lastPathComponent == "chapter.xhtml"
        }
        #expect(
            !BooksAsset.containsDatalessResource(
                in: fixture.root, placeholder: placeholder))
        try "<html/>".write(
            to: chapter, atomically: true, encoding: .utf8)
        #expect(
            BooksAsset.containsDatalessResource(
                in: fixture.root, placeholder: placeholder))
        #expect(
            !BooksAsset.containsDatalessResource(
                in: fixture.root, placeholder: { _, _ in false }))
        let partial = BooksAsset.load(
            assetID: "PARTIAL", path: fixture.root, contentType: .epub,
            resourceIsDataless: { url in
                BooksAsset.containsDatalessResource(
                    in: url, placeholder: placeholder)
            })
        #expect(partial.isDataless)
        #expect(!partial.isAvailable)
        #expect(partial.package == nil)
        #expect(OriginalDetector.books(asset: partial) == .missing)
    }

    @Test("a cancelled original copy publishes nothing")
    func cancelledOriginalCopy() throws {
        let directory = try temporaryDirectory("original-cancelled")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("book.azw")
        try clearAZWData().write(to: source)
        let output = directory.appendingPathComponent("export")
        #expect(throws: CancellationError.self) {
            _ = try OriginalService.copy(
                .available(kind: .azw, url: source), into: output,
                isCancelled: { true })
        }
        let names =
            (try? FileManager.default.contentsOfDirectory(
                atPath: output.path)) ?? []
        #expect(!names.contains { $0.hasPrefix("original") })
    }

    @Test("cancellation stops a copy in its first chunk")
    func cancelledMidStream() throws {
        let directory = try temporaryDirectory("original-mid-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("book.azw")
        var bytes = clearAZWData()
        bytes.append(Data(repeating: 0x41, count: 300_000))
        try bytes.write(to: source)
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let counter = Counter()
        let output = directory.appendingPathComponent("export")
        #expect(throws: CancellationError.self) {
            _ = try OriginalService.copy(
                .available(kind: .azw, url: source), into: output,
                isCancelled: { counter.next() > 2 })
        }
        let names =
            (try? FileManager.default.contentsOfDirectory(
                atPath: output.path)) ?? []
        #expect(!names.contains { $0.hasPrefix("original") })
    }

    @Test("a protected original cannot be copied")
    func protectedIsRefused() throws {
        let directory = try temporaryDirectory("original-refused")
        defer { try? FileManager.default.removeItem(at: directory) }
        let availability = OriginalAvailability.protected(reason: "test")
        #expect(throws: OriginalCopyError.self) {
            _ = try OriginalService.copy(
                availability, into: directory)
        }
    }
}

// MARK: - Cover service

@Suite("Cover service")
struct CoverServiceTests {
    @Test("a cache hit is copied without fetching")
    func cacheHit() throws {
        let directory = try temporaryDirectory("cover-cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache")
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: true)
        try jpegData(gray: 0.4).write(
            to: cache.appendingPathComponent(
                BookCoverService.cacheKey(
                    for: "B0CACHE", source: .kindle) + ".jpg"))
        let service = BookCoverService(
            fetcher: FakeFetcher(error: .timedOut),
            cacheDirectory: cache)
        let export = directory.appendingPathComponent("export")
        let metadata = BookMetadata(
            title: "Cached", identifier: "B0CACHE",
            source: .kindle, cover: .kindleASIN("B0CACHE"))
        let result = service.resolve(for: metadata, into: export)
        let cover = try #require(result.cover)
        #expect(cover.source == .cache)
        #expect(FileManager.default.fileExists(
            atPath: cover.fileURL.path))
    }

    @Test("a downloaded cover is written and cached")
    func downloadHit() throws {
        let directory = try temporaryDirectory("cover-download")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache")
        let service = BookCoverService(
            fetcher: FakeFetcher(data: try jpegData(gray: 0.3)),
            cacheDirectory: cache)
        let export = directory.appendingPathComponent("export")
        let metadata = BookMetadata(
            title: "Downloaded", identifier: "B0DOWNLOAD",
            source: .kindle, cover: .kindlePhysicalId("physical"))
        let result = service.resolve(for: metadata, into: export)
        let cover = try #require(result.cover)
        #expect(cover.source == .download)
        #expect(cover.byteCount > 0)
        #expect(FileManager.default.fileExists(
            atPath: export.appendingPathComponent("cover.jpg").path))
        #expect(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent(
                BookCoverService.cacheKey(
                    for: "B0DOWNLOAD", source: .kindle) + ".jpg").path))
    }

    @Test("bytes that are not an image fall back to a generated cover")
    func nonImageFallsBack() throws {
        let directory = try temporaryDirectory("cover-fallback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BookCoverService(
            fetcher: FakeFetcher(data: Data("not an image".utf8)),
            cacheDirectory: directory.appendingPathComponent("cache"))
        let metadata = BookMetadata(
            title: "Fallback", author: "Author", identifier: "B0FALLBACK",
            source: .kindle, cover: .kindlePhysicalId("physical"))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        let cover = try #require(result.cover)
        #expect(cover.source == .generated)
        #expect(result.warnings.contains {
            $0.contains("not a readable image")
        })
    }

    @Test("a timeout falls back to a generated cover")
    func timeoutFallsBack() throws {
        let directory = try temporaryDirectory("cover-timeout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BookCoverService(
            fetcher: FakeFetcher(error: .timedOut),
            cacheDirectory: directory.appendingPathComponent("cache"))
        let metadata = BookMetadata(
            title: "Timeout", identifier: "B0TIMEOUT",
            source: .kindle, cover: .kindleASIN("B0TIMEOUT"))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        let cover = try #require(result.cover)
        #expect(cover.source == .generated)
        #expect(result.warnings.contains { $0.contains("timed out") })
    }

    @Test("cache keys do not collide for A:B and A-B")
    func cacheKeyCollision() throws {
        let directory = try temporaryDirectory("cover-key-collision")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache")
        let exportA = directory.appendingPathComponent("export-a")
        let exportB = directory.appendingPathComponent("export-b")
        let first = BookCoverService(
            fetcher: FakeFetcher(data: try jpegData(gray: 0.2)),
            cacheDirectory: cache)
        let second = BookCoverService(
            fetcher: FakeFetcher(data: try jpegData(gray: 0.8)),
            cacheDirectory: cache)
        let a = try #require(
            first.resolve(
                for: BookMetadata(
                    title: "A", identifier: "A:B", source: .kindle,
                    cover: .kindleASIN("A:B")),
                into: exportA).cover)
        let b = try #require(
            second.resolve(
                for: BookMetadata(
                    title: "B", identifier: "A-B", source: .kindle,
                    cover: .kindleASIN("A-B")),
                into: exportB).cover)
        #expect(a.source == .download)
        #expect(b.source == .download)
        #expect(try Data(contentsOf: a.fileURL)
            != (try Data(contentsOf: b.fileURL)))
    }

    @Test("a failed physicalId URL falls back to the ASIN URL")
    func physicalIDFallback() throws {
        let directory = try temporaryDirectory("cover-fallback-url")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetcher = URLRecordingFetcher(data: try jpegData(gray: 0.4))
        let service = BookCoverService(
            fetcher: fetcher,
            cacheDirectory: directory.appendingPathComponent("cache"))
        let metadata = BookMetadata(
            title: "Fallback URL", identifier: "B0FALLBACK",
            source: .kindle, cover: .kindlePhysicalId("physical"))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        let cover = try #require(result.cover)
        #expect(cover.source == .download)
        #expect(fetcher.urls.count == 2)
        #expect(
            fetcher.urls[0].absoluteString
                == "https://m.media-amazon.com/images/I/physical.jpg")
        #expect(
            fetcher.urls[1].absoluteString
                == "https://m.media-amazon.com/images/P/B0FALLBACK"
                    + ".01.LZZZZZZZ.jpg")
    }

    @Test("a generated cover is not cached, so a later download can win")
    func generatedIsNotCached() throws {
        let directory = try temporaryDirectory("cover-no-poison")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache")
        let export = directory.appendingPathComponent("export")
        let metadata = BookMetadata(
            title: "No Poison", identifier: "B0NOPOISON",
            source: .kindle, cover: .kindleASIN("B0NOPOISON"))
        let offline = BookCoverService(
            fetcher: FakeFetcher(error: .timedOut),
            cacheDirectory: cache)
        let first = offline.resolve(for: metadata, into: export)
        #expect(first.cover?.source == .generated)
        #expect(!FileManager.default.fileExists(
            atPath: cache.appendingPathComponent(
                BookCoverService.cacheKey(
                    for: "B0NOPOISON", source: .kindle) + ".jpg").path))
        let online = BookCoverService(
            fetcher: FakeFetcher(data: try jpegData(gray: 0.2)),
            cacheDirectory: cache)
        let second = online.resolve(for: metadata, into: export)
        #expect(second.cover?.source == .download)
    }

    @Test("an EPUB cover is copied from the package")
    func epubCover() throws {
        let directory = try temporaryDirectory("cover-epub")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let service = BookCoverService(
            fetcher: FakeFetcher(error: .timedOut),
            cacheDirectory: directory.appendingPathComponent("cache"))
        let metadata = BookMetadata(
            title: "EPUB Cover", identifier: "EPUBCOVER",
            source: .appleBooks, cover: .epubImage(fixture.coverURL))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        let cover = try #require(result.cover)
        #expect(cover.source == .epub)
        #expect(cover.byteCount > 0)
    }

    @Test("a PDF cover is rendered from page one")
    func pdfCover() throws {
        let directory = try temporaryDirectory("cover-pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("book.pdf")
        try pdfData(pages: 2).write(to: pdf)
        let service = BookCoverService(
            fetcher: FakeFetcher(error: .timedOut),
            cacheDirectory: directory.appendingPathComponent("cache"))
        let metadata = BookMetadata(
            title: "PDF Cover", identifier: "PDFCOVER",
            source: .appleBooks, cover: .pdfPage(pdf))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        let cover = try #require(result.cover)
        #expect(cover.source == .pdf)
        #expect(cover.byteCount > 0)
    }
}

// MARK: - Text sidecars

@Suite("Text sidecars")
struct TextSidecarTests {
    @Test("three pages produce the golden Markdown and page files")
    func goldenMarkdown() throws {
        let directory = try temporaryDirectory("sidecar")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = [
            CapturedPageText(page: 1, text: "  alpha  \n", source: "accessibility"),
            CapturedPageText(page: 2, text: "beta\n\n", source: "accessibility"),
            CapturedPageText(page: 3, text: "", source: "none"),
        ]
        let summary = try TextSidecars.write(pages: pages, to: directory)
        #expect(summary.pages == 3)
        let markdown = try String(
            contentsOf: directory.appendingPathComponent("text.md"),
            encoding: .utf8)
        #expect(
            markdown
                == "## Page 1\n\nalpha\n\n---\n\n## Page 2\n\nbeta\n\n---\n\n"
                + "## Page 3\n\n")
        let first = try String(
            contentsOf: directory.appendingPathComponent(
                "pages/page-0001.txt"), encoding: .utf8)
        let second = try String(
            contentsOf: directory.appendingPathComponent(
                "pages/page-0002.txt"), encoding: .utf8)
        let third = try String(
            contentsOf: directory.appendingPathComponent(
                "pages/page-0003.txt"), encoding: .utf8)
        #expect(first == "alpha\n")
        #expect(second == "beta\n")
        #expect(third.isEmpty)
    }

    @Test("text.jsonl round-trips through the sidecar reader")
    func readsJSONL() throws {
        let directory = try temporaryDirectory("jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = [
            #"{"page":2,"text":"beta","source":"ocr"}"#,
            #"{"page":1,"text":"alpha","source":"accessibility"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        let pages = try TextSidecars.load(from: directory)
        #expect(pages.map(\.page) == [1, 2])
        #expect(pages.map(\.source) == ["accessibility", "ocr"])
    }

    @Test("a malformed text.jsonl line is reported")
    func malformedJSONL() throws {
        let directory = try temporaryDirectory("jsonl-bad")
        defer { try? FileManager.default.removeItem(at: directory) }
        try "{\"page\":1}\n".write(
            to: directory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        #expect(throws: TextSidecarError.self) {
            _ = try TextSidecars.load(from: directory)
        }
    }
}

// MARK: - PDF cover page

@Suite("PDF cover page")
struct PDFCoverPageTests {
    @Test("a cover page adds one vector page with title and author")
    func coverPage() throws {
        let directory = try temporaryDirectory("pdf-cover")
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try (0..<2).map {
            _ in try pngFile(width: 240, height: 320, in: directory)
        }
        let output = directory.appendingPathComponent("book.pdf")
        let coverImage = directory.appendingPathComponent("cover.jpg")
        try jpegData().write(to: coverImage)
        let cover = PDFCoverPage(
            title: "Synthetic Title", author: "Ada Lovelace",
            identifier: "B0SYNTHETIC", source: "kindle",
            exportDate: Date(timeIntervalSince1970: 1_700_000_000),
            capturedPages: 2, coverImageURL: coverImage,
            textDisclosure: "Page-level text layer; not word-aligned.",
            pageSize: CGSize(width: 595.28, height: 841.89))
        let count = try PDFWriter.write(
            pageURLs: images, texts: ["one", "two"],
            metadata: PDFMetadata(title: "Synthetic Title"),
            cover: cover, displayScale: 1, to: output)
        #expect(count == 3)
        #expect(PDFWriter.pageCount(output) == 3)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 3)
        let first = try #require(document.page(at: 0))
        let text = first.string ?? ""
        #expect(text.contains("Synthetic Title"))
        #expect(text.contains("Ada Lovelace"))
        #expect(text.contains("Captured pages: 2"))
        #expect(text.contains("Identifier: B0SYNTHETIC"))
        #expect(text.contains("Source: kindle"))
        #expect(text.contains("Exported: 2023-11-14"))
        #expect(text.contains("Page-level text layer; not word-aligned."))
        let size = first.bounds(for: .mediaBox).size
        #expect(abs(size.width - 595.28) < 1)
        #expect(abs(size.height - 841.89) < 1)

        // The image is drawn, not just the text: a cover without the image
        // must render materially lighter than the same page with it.
        let noImageOutput = directory.appendingPathComponent("no-image.pdf")
        let noImageCover = PDFCoverPage(
            title: "Synthetic Title", author: "Ada Lovelace",
            identifier: "B0SYNTHETIC", source: "kindle",
            exportDate: Date(timeIntervalSince1970: 1_700_000_000),
            capturedPages: 2, coverImageURL: nil,
            textDisclosure: "Page-level text layer; not word-aligned.",
            pageSize: CGSize(width: 595.28, height: 841.89))
        _ = try PDFWriter.write(
            pageURLs: images, texts: ["one", "two"],
            metadata: PDFMetadata(title: "Synthetic Title"),
            cover: noImageCover, displayScale: 1, to: noImageOutput)
        let noImageDocument = try #require(PDFDocument(url: noImageOutput))
        let noImagePage = try #require(noImageDocument.page(at: 0))
        let withPixels = try #require(renderPixels(first))
        let withoutPixels = try #require(renderPixels(noImagePage))
        let withAverage = averageBrightness(withPixels)
        let withoutAverage = averageBrightness(withoutPixels)
        #expect(
            withoutAverage - withAverage > 0.02,
            "the cover image did not darken the page: \(withoutAverage) vs \(withAverage)")
    }

    private func renderPixels(_ page: PDFPage) -> [UInt8]? {
        let width = 300
        let height = 424
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        context.scaleBy(
            x: CGFloat(width) / bounds.width,
            y: CGFloat(height) / bounds.height)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage(),
            let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return nil }
        return Array(
            UnsafeBufferPointer(
                start: bytes, count: CFDataGetLength(data)))
    }

    private func averageBrightness(_ pixels: [UInt8]) -> Double {
        guard !pixels.isEmpty else { return 0 }
        var total = 0.0
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            total += (red + green + blue) / 3
            count += 1
        }
        return count == 0 ? 0 : total / Double(count)
    }

    @Test("a small cover page with long metadata stays on the page")
    func smallCoverPage() throws {
        let directory = try temporaryDirectory("pdf-small-cover")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try pngFile(width: 240, height: 320, in: directory)
        let output = directory.appendingPathComponent("small.pdf")
        let cover = PDFCoverPage(
            title: String(repeating: "A long title ", count: 12),
            author: String(repeating: "An author ", count: 12),
            identifier: "B0SMALL", source: "kindle",
            exportDate: Date(timeIntervalSince1970: 1_700_000_000),
            capturedPages: 2, coverImageURL: image,
            textDisclosure: "Page-level text layer; not word-aligned.",
            pageSize: CGSize(width: 200, height: 300))
        let count = try PDFWriter.write(
            pageURLs: [image], texts: ["alpha"],
            metadata: PDFMetadata(title: "Small"),
            cover: cover, displayScale: 1, to: output)
        #expect(count == 2)
        let document = try #require(PDFDocument(url: output))
        let text = try #require(document.page(at: 0)?.string)
        #expect(text.contains("A long title"))
        #expect(text.contains("Captured pages: 2"))
        #expect(text.contains("Exported: 2023-11-14"))
    }

    @Test("a capture without a cover is unchanged")
    func noCover() throws {
        let directory = try temporaryDirectory("pdf-no-cover")
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try (0..<2).map {
            _ in try pngFile(width: 240, height: 320, in: directory)
        }
        let output = directory.appendingPathComponent("book.pdf")
        let count = try PDFWriter.write(
            pageURLs: images, texts: ["one", "two"],
            metadata: PDFMetadata(title: "No Cover"),
            displayScale: 1, to: output)
        #expect(count == 2)
        #expect(PDFWriter.pageCount(output) == 2)
    }
}

// MARK: - Bundle orchestration

@Suite("Export bundle")
struct ExportBundleTests {
    private func buildPlan(
        directory: URL, includeCoverPage: Bool = true
    ) throws -> (ExportBundlePlan, URL) {
        let cache = directory.appendingPathComponent("cache")
        let services = CaptureBundleServices(
            metadataResolver: BookMetadataResolver(
                kindlePaths: KindlePaths(
                    container: directory.appendingPathComponent("none")),
                booksAssets: nil,
                kindleCache: KindleMetadataCache()),
            coverService: BookCoverService(
                fetcher: FakeFetcher(data: try jpegData()),
                cacheDirectory: cache))
        let book = Book(
            asin: "B0BUNDLE", title: "Bundle Title", author: "Author",
            bookType: 10, readState: 0, source: .kindle)
        let plan = ExportBundle.prepare(
            directory: directory, book: book,
            capturedTitle: "Bundle Title", identifier: "B0BUNDLE",
            source: .kindle, capturedPages: 2,
            options: CaptureBundleOptions(
                includeCoverPage: includeCoverPage,
                writeSidecars: true, copyOriginal: true,
                pageSize: CGSize(width: 595.28, height: 841.89)),
            services: services,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        return (plan, directory)
    }

    @Test("the manifest and metadata.json carry every bundle object")
    func manifestSchema() throws {
        let directory = try temporaryDirectory("bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        {"page":1,"text":"alpha","source":"accessibility"}
        {"page":2,"text":"beta","source":"accessibility"}
        """.write(
            to: directory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        let fixture = try EPUBFixture.make(in: directory)
        let originalURL = directory.appendingPathComponent("book.epub")
        try ZIPArchive.write(directory: fixture.root, to: originalURL)
        let (plan, _) = try buildPlan(directory: directory)
        var planWithOriginal = plan
        planWithOriginal = ExportBundlePlan(
            metadata: plan.metadata, cover: plan.cover,
            original: .available(kind: .epub, url: originalURL),
            coverPage: plan.coverPage, options: plan.options,
            warnings: plan.warnings)
        var manifest: [String: Any] = [
            "title": "Bundle Title",
            "source": "kindle",
            "state": "finished",
            "termination": "endOfBook",
            "pageCount": 2,
            "pdfPages": 3,
        ]
        let warnings = try ExportBundle.finish(
            planWithOriginal, manifest: &manifest, directory: directory)
        #expect(warnings.isEmpty)
        let book = try #require(manifest["book"] as? [String: Any])
        #expect(book["title"] as? String == "Bundle Title")
        #expect(book["author"] as? String == "Author")
        #expect(book["asin"] as? String == "B0BUNDLE")
        #expect(book["source"] as? String == "kindle")
        let sources = try #require(book["sources"] as? [String: String])
        #expect(sources["title"] == "archive")
        #expect(sources["cover"] == "archive")
        #expect(sources["identifier"] == "archive")
        #expect(sources["original"] == "local-files")
        let cover = try #require(manifest["cover"] as? [String: Any])
        #expect(cover["source"] as? String == "download")
        #expect(cover["file"] as? String == "cover.jpg")
        let original = try #require(
            manifest["original"] as? [String: Any])
        #expect(original["available"] as? Bool == true)
        #expect(original["kind"] as? String == "epub")
        #expect(original["path"] as? String == originalURL.path)
        #expect(original["copiedTo"] as? String == "original.epub")
        let text = try #require(manifest["text"] as? [String: Any])
        #expect(text["pages"] as? Int == 2)
        #expect(text["markdown"] as? String == "text.md")
        #expect(text["perPage"] as? String == "pages/*.txt")
        #expect(manifest["coverPage"] as? Bool == true)
        #expect(manifest["pageOffset"] as? Int == 1)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("metadata.json").path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("text.md").path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                "pages/page-0001.txt").path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("original.epub").path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("original.json").path))
        let originalData = try Data(
            contentsOf: directory.appendingPathComponent("original.json"))
        let originalRecord = try #require(
            try JSONSerialization.jsonObject(with: originalData)
                as? [String: Any])
        #expect(originalRecord["available"] as? Bool == true)
        #expect(originalRecord["kind"] as? String == "epub")
        let metadataData = try Data(
            contentsOf: directory.appendingPathComponent("metadata.json"))
        let record = try #require(
            try JSONSerialization.jsonObject(with: metadataData)
                as? [String: Any])
        let metadataBook = try #require(
            record["book"] as? [String: Any])
        #expect(metadataBook["sources"] != nil)
        #expect(record["capture"] != nil)
        #expect(record["cover"] != nil)
        #expect(record["original"] != nil)
        #expect(record["text"] != nil)
    }

    @Test("a missing text.jsonl is a warning, not a failure")
    func sidecarFailureIsWarning() throws {
        let directory = try temporaryDirectory("bundle-warning")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, _) = try buildPlan(directory: directory)
        var manifest: [String: Any] = [:]
        let warnings = try ExportBundle.finish(
            plan, manifest: &manifest, directory: directory)
        #expect(warnings.contains {
            $0.contains("text sidecars were not written")
        })
        #expect(manifest["book"] != nil)
        #expect(manifest["cover"] != nil)
    }

    @Test("a capture with the network blocked still gets a generated cover")
    func offlineStillBundles() throws {
        let directory = try temporaryDirectory("bundle-offline")
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = CaptureBundleServices(
            metadataResolver: BookMetadataResolver(
                kindlePaths: KindlePaths(
                    container: directory.appendingPathComponent("none")),
                booksAssets: nil, kindleCache: KindleMetadataCache()),
            coverService: BookCoverService(
                fetcher: FakeFetcher(error: .timedOut),
                cacheDirectory: directory.appendingPathComponent("cache")))
        let plan = ExportBundle.prepare(
            directory: directory,
            book: Book(
                asin: "B0OFFLINE", title: "Offline", author: "Author",
                bookType: 10, readState: 0, source: .kindle),
            capturedTitle: "Offline", identifier: "B0OFFLINE",
            source: .kindle, capturedPages: 1, options: .defaults,
            services: services, now: Date())
        let cover = try #require(plan.cover)
        #expect(cover.source == .generated)
        #expect(plan.coverPage != nil)
    }
}

// MARK: - Verifier

@Suite("Verifier cover accounting")
struct VerifierCoverTests {
    @Test("the verifier expects the cover page when the manifest says so")
    func coverAccounting() throws {
        let directory = try temporaryDirectory("verify-cover")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pagesDirectory = directory.appendingPathComponent("pages")
        try FileManager.default.createDirectory(
            at: pagesDirectory, withIntermediateDirectories: true)
        let page = try pngFile(width: 60, height: 90, in: pagesDirectory)
        try FileManager.default.moveItem(
            at: page,
            to: pagesDirectory.appendingPathComponent("page-0001.png"))
        let pdfURL = directory.appendingPathComponent("book.pdf")
        let cover = PDFCoverPage(
            title: "Title", author: nil, identifier: nil, source: "kindle",
            exportDate: Date(), capturedPages: 1, coverImageURL: nil,
            textDisclosure: nil, pageSize: nil)
        let images = [pagesDirectory.appendingPathComponent("page-0001.png")]
        _ = try PDFWriter.write(
            pageURLs: images, texts: ["alpha"],
            metadata: PDFMetadata(title: "Title"), cover: cover,
            displayScale: 1, to: pdfURL)
        let manifest: [String: Any] = [
            "pdf": "book.pdf",
            "pageCount": 1,
            "coverPage": true,
            "pages": [["page": 1, "source": "accessibility"]],
            "termination": "endOfBook",
            "startPage": 1,
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: directory.appendingPathComponent("manifest.json"))
        let verification = try CaptureVerifier.verify(directory: directory)
        #expect(verification.structural)
    }
}

// MARK: - Engine integration

private final class OnePageExportSession: ReaderCaptureSession {
    let identity = ObservedIdentity(
        title: "Bundle Title", confidence: .titleOnly("Bundle Title"))
    let mode = CaptureMode(
        layout: .reflowable, navigation: .automatic,
        endDetection: .positive)
    private let page: PageSnapshot

    init(page: PageSnapshot) { self.page = page }

    func snapshot() throws -> PageSnapshot { page }

    func advance(after mark: PageMark) throws -> PageTransition {
        .endOfBook(
            TurnRecord(
                attempted: true, posted: true, observed: false,
                terminal: true, unresolved: false))
    }

    func restore() -> RestoreReport {
        RestoreReport(
            opening: PageLocation(pageNumber: 1, pageCount: 1),
            final: PageLocation(pageNumber: 1, pageCount: 1),
            attempted: 0, posted: 0, observed: 0, terminal: 0,
            unresolved: 0, exact: true, reason: nil)
    }
}

private func exportSnapshot(text: String) throws -> PageSnapshot {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: 240, height: 320, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw FixtureError.couldNotMakeImage }
    context.setFillColor(CGColor(gray: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
    guard let image = context.makeImage() else {
        throw FixtureError.couldNotMakeImage
    }
    return PageSnapshot(
        identity: ObservedIdentity(
            title: "Bundle Title", confidence: .titleOnly("Bundle Title")),
        image: image, text: text, textSource: .accessibility,
        pageNumber: 1, pageCount: 1,
        location: PageLocation(pageNumber: 1, pageCount: 1),
        isEndOfBook: false,
        cropRect: CGRect(x: 0, y: 0, width: 240, height: 320),
        pixelSize: CGSize(width: 240, height: 320),
        mark: PageMark(imageHash: 1, text: text))
}

@Suite("Engine bundle integration")
struct EngineBundleTests {
    @Test("a capture publishes a covered PDF and every sidecar")
    func engineWritesBundle() throws {
        let directory = try temporaryDirectory("engine-bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        let output = directory.appendingPathComponent("capture")
        let services = CaptureBundleServices(
            metadataResolver: BookMetadataResolver(
                kindlePaths: KindlePaths(
                    container: directory.appendingPathComponent("none")),
                booksAssets: nil, kindleCache: KindleMetadataCache()),
            coverService: BookCoverService(
                fetcher: FakeFetcher(data: try jpegData()),
                cacheDirectory: directory.appendingPathComponent("cache")))
        let book = Book(
            asin: "B0ENGINE", title: "Bundle Title", author: "Author",
            bookType: 10, readState: 0, source: .kindle)
        let session = OnePageExportSession(
            page: try exportSnapshot(text: "alpha"))
        let result = try CaptureJobEngine(archive: archive).run(
            session: session,
            subject: CaptureSubject(book: book, kind: .kindle),
            pageLimit: 1, output: output,
            progress: { _ in }, isCancelled: { false },
            lifecycle: CaptureLifecycle(locked: { false }),
            bundle: CaptureBundleRequest(
                options: .defaults, services: services,
                now: { Date(timeIntervalSince1970: 1_700_000_000) }))
        #expect(result.pages == 2)
        #expect(PDFWriter.pageCount(result.pdf) == 2)
        let manifestData = try Data(
            contentsOf: output.appendingPathComponent("manifest.json"))
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any])
        #expect(manifest["coverPage"] as? Bool == true)
        #expect(manifest["pageOffset"] as? Int == 1)
        #expect(manifest["pageCount"] as? Int == 1)
        #expect(manifest["pdfPages"] as? Int == 2)
        let metadataURL = output.appendingPathComponent("metadata.json")
        let metadataData = try Data(contentsOf: metadataURL)
        let metadataRecord = try #require(
            try JSONSerialization.jsonObject(with: metadataData)
                as? [String: Any])
        let captureRecord = try #require(
            metadataRecord["capture"] as? [String: Any])
        #expect(captureRecord["pageCount"] as? Int == 1)
        #expect(captureRecord["pdfPages"] as? Int == 2)
        let bookObject = try #require(
            manifest["book"] as? [String: Any])
        #expect(bookObject["title"] as? String == "Bundle Title")
        #expect(bookObject["asin"] as? String == "B0ENGINE")
        #expect(manifest["text"] != nil)
        for name in [
            "cover.jpg", "metadata.json", "original.json", "text.md",
            "pages/page-0001.txt",
        ] {
            #expect(
                FileManager.default.fileExists(
                    atPath: output.appendingPathComponent(name).path),
                "missing \(name)")
        }
        let document = try #require(PDFDocument(url: result.pdf))
        #expect(document.pageCount == 2)
        #expect(
            document.page(at: 0)?.string?.contains("Bundle Title") == true)
        #expect(
            document.page(at: 0)?.string?.contains("Captured pages: 1")
                == true)
    }

    @Test("cancellation during finalization is not reported as success")
    func cancellationDuringFinalization() throws {
        let directory = try temporaryDirectory("engine-cancel-finish")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        let output = directory.appendingPathComponent("capture")
        let services = CaptureBundleServices(
            metadataResolver: BookMetadataResolver(
                kindlePaths: KindlePaths(
                    container: directory.appendingPathComponent("none")),
                booksAssets: nil, kindleCache: KindleMetadataCache()),
            coverService: BookCoverService(
                fetcher: FakeFetcher(data: try jpegData()),
                cacheDirectory: directory.appendingPathComponent("cache")))
        let book = Book(
            asin: "B0CANCELFIN", title: "Bundle Title", author: "Author",
            bookType: 10, readState: 0, source: .kindle)
        let session = OnePageExportSession(
            page: try exportSnapshot(text: "alpha"))
        // metadata.json is written late in finalization, so this observes a
        // stop arriving after the original copy but before success.
        let isCancelled: @Sendable () -> Bool = {
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent("metadata.json").path)
        }
        do {
            _ = try CaptureJobEngine(archive: archive).run(
                session: session,
                subject: CaptureSubject(book: book, kind: .kindle),
                pageLimit: 1, output: output,
                progress: { _ in }, isCancelled: isCancelled,
                lifecycle: CaptureLifecycle(locked: { false }),
                bundle: CaptureBundleRequest(
                    options: .defaults, services: services,
                    now: { Date(timeIntervalSince1970: 1_700_000_000) }))
            Issue.record("expected the capture to be cancelled")
        } catch is ReaderCaptureError {
            // The stop is reported, not converted into success.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        let manifestData = try Data(
            contentsOf: output.appendingPathComponent("manifest.json"))
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any])
        #expect(manifest["state"] as? String == "cancelled")
        #expect(manifest["termination"] as? String == "cancelled")
    }

    @Test("older settings blobs keep the bundle toggles on")
    func settingsDefaults() throws {
        let json = """
        {"provider":"claudeCLI","model":"","endpoint":"http://127.0.0.1:11434/v1",
         "language":"Simplified Chinese","sessionLogging":false,
         "cleanPageDuringCapture":true,"capturePageSize":"asDisplayed"}
        """
        let settings = try JSONDecoder().decode(
            AISettings.self, from: Data(json.utf8))
        #expect(settings.includeCoverPage)
        #expect(settings.writeSidecars)
        #expect(settings.booksFontSteps == 0)
        #expect(settings.captureCropTop == 0)
        #expect(settings.booksCropBottom == 54)
        #expect(settings.kindleCropBottom == 0)
        #expect(settings.captureBundleOptions.includeCoverPage)
        let a4 = AISettings(capturePageSize: .a4)
        #expect(
            a4.captureBundleOptions.pageSize
                == CapturePageSize.a4.points)
    }
}

// MARK: - Hardening tests

private func clearAZWData(
    encryption: UInt16 = 0, recordCount: Int = 1
) -> Data {
    // PalmDB header (78 bytes) + record info entries, then the record 0
    // PalmDOC header: compression 1, encryption at offset 12.
    let recordInfoEnd = 78 + recordCount * 8
    var data = Data(repeating: 0, count: recordInfoEnd)
    data[60] = 0x42  // B
    data[61] = 0x4F  // O
    data[62] = 0x4F  // O
    data[63] = 0x4B  // K
    data[64] = 0x4D  // M
    data[65] = 0x4F  // O
    data[66] = 0x42  // B
    data[67] = 0x49  // I
    data[76] = UInt8((recordCount >> 8) & 0xff)
    data[77] = UInt8(recordCount & 0xff)
    data[78] = UInt8((recordInfoEnd >> 24) & 0xff)
    data[79] = UInt8((recordInfoEnd >> 16) & 0xff)
    data[80] = UInt8((recordInfoEnd >> 8) & 0xff)
    data[81] = UInt8(recordInfoEnd & 0xff)
    if recordCount > 1 {
        // Record 1 starts after record 0's 16-byte PalmDOC header and its
        // 232-byte MOBI header.
        let record1 = recordInfoEnd + 248
        data[86] = UInt8((record1 >> 24) & 0xff)
        data[87] = UInt8((record1 >> 16) & 0xff)
        data[88] = UInt8((record1 >> 8) & 0xff)
        data[89] = UInt8(record1 & 0xff)
    }
    data.append(contentsOf: [0, 1])  // compression 1
    data.append(contentsOf: [0, 0])
    data.append(contentsOf: [0, 0, 0, 10])
    data.append(contentsOf: [0, 1])
    data.append(contentsOf: [0, 0])
    data.append(contentsOf: [
        UInt8(encryption >> 8), UInt8(encryption & 0xff),
    ])
    data.append(contentsOf: [0, 0])
    data.append(Data(repeating: 0, count: 4000))
    // MOBI magic at record0 + 16, then a plausible 232-byte header length.
    let mobi = recordInfoEnd + 16
    data[mobi] = 0x4D
    data[mobi + 1] = 0x4F
    data[mobi + 2] = 0x42
    data[mobi + 3] = 0x49
    data[mobi + 4] = 0
    data[mobi + 5] = 0
    data[mobi + 6] = 0
    data[mobi + 7] = 232
    return data
}

private func asymmetricPDFData() throws -> Data {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
    guard
        let consumer = CGDataConsumer(data: data as CFMutableData),
        let context = CGContext(
            consumer: consumer, mediaBox: &mediaBox, nil)
    else { throw FixtureError.couldNotMakePDF }
    context.beginPage(mediaBox: &mediaBox)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(mediaBox)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    // PDF coordinates: y = 150...300 is the top half.
    context.fill(CGRect(x: 0, y: 150, width: 200, height: 150))
    context.endPage()
    context.closePDF()
    return data as Data
}

/// Brightness of the decoded image's top and bottom rows. From a calibration
/// of CGBitmapContext, data row 0 is the top row.
private func brightnessRows(of url: URL) throws -> (top: Double, bottom: Double) {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let data = context.data
    else { throw FixtureError.couldNotMakeImage }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
    let pointer = data.assumingMemoryBound(to: UInt8.self)
    func brightness(_ offset: Int) -> Double {
        (Double(pointer[offset]) + Double(pointer[offset + 1])
            + Double(pointer[offset + 2])) / 3
    }
    let top = (brightness(0) + brightness(4)) / 2
    let bottom = (brightness(8) + brightness(12)) / 2
    return (top, bottom)
}

private final class StubStore: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var status = 200
    private var delay: TimeInterval = 0
    private var chunkDelay: TimeInterval = 0

    func set(
        data: Data = Data(), status: Int = 200, delay: TimeInterval = 0,
        chunkDelay: TimeInterval = 0
    ) {
        lock.lock()
        self.data = data
        self.status = status
        self.delay = delay
        self.chunkDelay = chunkDelay
        lock.unlock()
    }

    func snapshot() -> (Data, Int, TimeInterval, TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (data, status, delay, chunkDelay)
    }
}

private final class StubURLProtocol: URLProtocol {
    static let store = StubStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (data, status, delay, chunkDelay) = Self.store.snapshot()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(
            self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if chunkDelay > 0 {
            let chunkSize = max(1, data.count / 4)
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                client?.urlProtocol(
                    self, didLoad: data.subdata(in: offset..<end))
                offset = end
                Thread.sleep(forTimeInterval: chunkDelay)
            }
        } else {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Cover fetcher network", .serialized)
struct CoverFetcherNetworkTests {
    private func fetcher() -> URLSessionCoverFetcher {
        URLSessionCoverFetcher(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            return configuration
        })
    }

    @Test("an oversized response is rejected at the byte limit")
    func oversized() throws {
        StubURLProtocol.store.set(
            data: Data(repeating: 0x41, count: 4096))
        let fetcher = fetcher()
        let url = try #require(URL(string: "https://example.test/big.jpg"))
        do {
            _ = try fetcher.fetch(url, timeout: 5, byteLimit: 1024)
            Issue.record("expected tooLarge")
        } catch CoverFetchError.tooLarge(let bytes) {
            #expect(bytes == 4096)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a trickling response still hits the deadline")
    func trickle() throws {
        StubURLProtocol.store.set(
            data: Data(repeating: 0x41, count: 8),
            chunkDelay: 0.2)
        let fetcher = fetcher()
        let url = try #require(
            URL(string: "https://example.test/trickle.jpg"))
        let start = Date()
        do {
            _ = try fetcher.fetch(url, timeout: 0.3, byteLimit: 1024)
            Issue.record("expected timedOut")
        } catch CoverFetchError.timedOut {
            #expect(Date().timeIntervalSince(start) < 1.5)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a response beyond the absolute deadline times out")
    func deadline() throws {
        StubURLProtocol.store.set(
            data: Data(repeating: 0x41, count: 10), delay: 2)
        let fetcher = fetcher()
        let url = try #require(URL(string: "https://example.test/slow.jpg"))
        let start = Date()
        do {
            _ = try fetcher.fetch(url, timeout: 0.2, byteLimit: 1024)
            Issue.record("expected timedOut")
        } catch CoverFetchError.timedOut {
            #expect(Date().timeIntervalSince(start) < 1.5)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Suite("Cover and original hardening")
struct CoverHardeningTests {
    @Test("a PDF cover keeps the page upright")
    func pdfOrientation() throws {
        let directory = try temporaryDirectory("cover-orientation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("asymmetric.pdf")
        try asymmetricPDFData().write(to: pdf)
        let service = BookCoverService(
            fetcher: FakeFetcher(error: .timedOut),
            cacheDirectory: directory.appendingPathComponent("cache"))
        let metadata = BookMetadata(
            title: "Orientation", identifier: "ORIENT",
            source: .appleBooks, cover: .pdfPage(pdf))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        let cover = try #require(result.cover)
        let rows = try brightnessRows(of: cover.fileURL)
        #expect(rows.top < 100, "top \(rows.top) bottom \(rows.bottom)")
        #expect(rows.bottom > 200, "top \(rows.top) bottom \(rows.bottom)")
    }

    @Test("a rotated PDF cover uses the rotated aspect ratio")
    func pdfRotation() throws {
        let directory = try temporaryDirectory("cover-rotation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("plain.pdf")
        try pdfData().write(to: source)
        let document = try #require(PDFDocument(url: source))
        let page = try #require(document.page(at: 0))
        page.rotation = 90
        let rotated = directory.appendingPathComponent("rotated.pdf")
        #expect(document.write(to: rotated))
        let service = BookCoverService(
            fetcher: FakeFetcher(error: .timedOut),
            cacheDirectory: directory.appendingPathComponent("cache"))
        let metadata = BookMetadata(
            title: "Rotated", identifier: "ROTATED",
            source: .appleBooks, cover: .pdfPage(rotated))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        let cover = try #require(result.cover)
        let imageSource = try #require(
            CGImageSourceCreateWithURL(cover.fileURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(
                imageSource, 0, nil) as? [CFString: Any])
        let width = try #require(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
                .intValue)
        let height = try #require(
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
                .intValue)
        #expect(width > height, "\(width)x\(height)")
    }

    @Test("an EPUB cover symlink is measured at its target")
    func coverSymlinkSize() throws {
        let directory = try temporaryDirectory("cover-symlink-size")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let target = fixture.root.appendingPathComponent(
            "OEBPS/images/real.jpg")
        try jpegData(width: 400, height: 400).write(to: target)
        try FileManager.default.removeItem(at: fixture.coverURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.coverURL, withDestinationURL: target)
        let service = BookCoverService(
            fetcher: FakeFetcher(error: .timedOut),
            cacheDirectory: directory.appendingPathComponent("cache"),
            byteLimit: 1024)
        let metadata = BookMetadata(
            title: "Linked", identifier: "LINKED",
            source: .appleBooks, cover: .epubImage(fixture.coverURL))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        #expect(result.cover?.source == .generated)
    }

    @Test("an oversized decoded image falls back to a generated cover")
    func oversizedCoverImage() throws {
        let directory = try temporaryDirectory("cover-oversized")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try pngFile(
            width: 2000, height: 2000, in: directory)
        let service = BookCoverService(
            fetcher: FakeFetcher(error: .timedOut),
            cacheDirectory: directory.appendingPathComponent("cache"),
            maximumPixels: 1_000_000)
        let metadata = BookMetadata(
            title: "Oversized", identifier: "BIG",
            source: .appleBooks, cover: .epubImage(image))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        #expect(result.cover?.source == .generated)
    }

    @Test("a cover symlink outside the EPUB is refused")
    func coverSymlinkEscape() throws {
        let directory = try temporaryDirectory("cover-symlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let outside = directory.appendingPathComponent("outside.jpg")
        try jpegData().write(to: outside)
        try FileManager.default.removeItem(at: fixture.coverURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.coverURL, withDestinationURL: outside)
        #expect(throws: EPUBError.self) {
            _ = try EPUBPackage.load(fromEPUBDirectory: fixture.root)
        }
    }

    @Test("an unreadable META-INF is unknown, not DRM-free")
    func unreadableMeta() throws {
        let directory = try temporaryDirectory("cover-permission")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let meta = fixture.root.appendingPathComponent("META-INF")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: meta.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: meta.path)
        }
        let asset = BooksAsset.load(
            assetID: "PERMISSION", path: fixture.root,
            contentType: .epub)
        if case .unknown = asset.drm {
        } else {
            Issue.record("expected unknown, got \(asset.drm)")
        }
        #expect(OriginalDetector.books(asset: asset).isAvailable == false)
    }

    @Test("a Kindle PDF is inspected; a traversal identifier is refused")
    func kindleProtection() throws {
        let directory = try temporaryDirectory("kindle-protection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let paths = KindlePaths(container: container)
        let protected = container.appendingPathComponent(
            "eBooks/B0PROTECTED/id")
        try FileManager.default.createDirectory(
            at: protected, withIntermediateDirectories: true)
        try pdfData(encrypted: true).write(
            to: protected.appendingPathComponent("book.pdf"))
        if case .protected = OriginalDetector.kindle(
            asin: "B0PROTECTED", paths: paths)
        {
        } else {
            Issue.record("expected the encrypted PDF to be protected")
        }
        let clear = container.appendingPathComponent("eBooks/B0CLEAR/id")
        try FileManager.default.createDirectory(
            at: clear, withIntermediateDirectories: true)
        try pdfData().write(to: clear.appendingPathComponent("book.pdf"))
        guard
            case .available(.pdf, _) = OriginalDetector.kindle(
                asin: "B0CLEAR", paths: paths)
        else {
            Issue.record("expected the clear PDF to be available")
            return
        }
        #expect(
            OriginalDetector.kindle(
                asin: "../escape", paths: paths) == .missing)
    }

    @Test("an AZW encryption flag is protected; KFX is unverified")
    func kindleContainerProtection() throws {
        let directory = try temporaryDirectory("kindle-azw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let paths = KindlePaths(container: container)
        let protected = container.appendingPathComponent(
            "eBooks/B0AZW/id")
        try FileManager.default.createDirectory(
            at: protected, withIntermediateDirectories: true)
        try clearAZWData(encryption: 2).write(
            to: protected.appendingPathComponent("book.azw"))
        if case .protected = OriginalDetector.kindle(
            asin: "B0AZW", paths: paths)
        {
        } else {
            Issue.record("expected the encrypted AZW to be protected")
        }
        let clear = container.appendingPathComponent(
            "eBooks/B0CLEARAZW/id")
        try FileManager.default.createDirectory(
            at: clear, withIntermediateDirectories: true)
        try clearAZWData().write(
            to: clear.appendingPathComponent("book.azw"))
        guard
            case .available(.azw, _) = OriginalDetector.kindle(
                asin: "B0CLEARAZW", paths: paths)
        else {
            Issue.record("expected the clear AZW to be available")
            return
        }
        let kfx = container.appendingPathComponent("eBooks/B0KFX/id")
        try FileManager.default.createDirectory(
            at: kfx, withIntermediateDirectories: true)
        try Data("kfx".utf8).write(
            to: kfx.appendingPathComponent("book.kfx"))
        if case .protected = OriginalDetector.kindle(
            asin: "B0KFX", paths: paths)
        {
        } else {
            Issue.record("expected KFX to fail closed")
        }
    }

    @Test("an unreadable Kindle subtree fails closed")
    func unreadableKindleSubtree() throws {
        let directory = try temporaryDirectory("kindle-unreadable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let bookDirectory = container.appendingPathComponent(
            "eBooks/B0UNREAD/id")
        try FileManager.default.createDirectory(
            at: bookDirectory, withIntermediateDirectories: true)
        try clearAZWData().write(
            to: bookDirectory.appendingPathComponent("book.azw"))
        let secret = container.appendingPathComponent(
            "eBooks/B0UNREAD/secret")
        try FileManager.default.createDirectory(
            at: secret, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: secret.path)
        }
        if case .protected = OriginalDetector.kindle(
            asin: "B0UNREAD", paths: KindlePaths(container: container))
        {
        } else {
            Issue.record("expected an unreadable subtree to fail closed")
        }
    }

    @Test("an original copy does not overwrite a captured original.pdf")
    func originalCollision() throws {
        let directory = try temporaryDirectory("original-collision")
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = directory.appendingPathComponent("Original.pdf")
        try "captured".write(
            to: captured, atomically: true, encoding: .utf8)
        let source = directory.appendingPathComponent("source.pdf")
        try pdfData().write(to: source)
        let plan = ExportBundlePlan(
            metadata: BookMetadata(
                title: "Original", identifier: "B0ORIGINAL",
                source: .kindle),
            cover: nil, original: .available(kind: .pdf, url: source),
            coverPage: nil,
            options: CaptureBundleOptions(
                includeCoverPage: false, writeSidecars: false,
                copyOriginal: true),
            warnings: [])
        var manifest: [String: Any] = [
            "pdf": "Original.pdf", "pageCount": 1, "pdfPages": 1,
        ]
        let warnings = try ExportBundle.finish(
            plan, manifest: &manifest, directory: directory)
        #expect(warnings.isEmpty)
        let original = try #require(
            manifest["original"] as? [String: Any])
        #expect(original["copiedTo"] as? String == "original-book.pdf")
        #expect(
            try String(contentsOf: captured, encoding: .utf8)
                == "captured")
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                "original-book.pdf").path))
    }

    @Test("a copy refused as protected updates the original records")
    func protectedAtCopyTimeUpdatesRecords() throws {
        let directory = try temporaryDirectory("original-stale")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("protected.pdf")
        try pdfData(encrypted: true).write(to: pdf)
        try #"{"page":1,"text":"alpha","source":"accessibility"}"#.write(
            to: directory.appendingPathComponent("text.jsonl"),
            atomically: true, encoding: .utf8)
        let plan = ExportBundlePlan(
            metadata: BookMetadata(
                title: "Protected", identifier: "B0PROTECTED",
                source: .kindle),
            cover: nil, original: .available(kind: .pdf, url: pdf),
            coverPage: nil,
            options: CaptureBundleOptions(
                includeCoverPage: false, writeSidecars: true,
                copyOriginal: true),
            warnings: [])
        var manifest: [String: Any] = [
            "pdf": "capture.pdf", "pageCount": 1, "pdfPages": 1,
        ]
        let warnings = try ExportBundle.finish(
            plan, manifest: &manifest, directory: directory)
        #expect(warnings.contains { $0.contains("not copied") })
        let original = try #require(
            manifest["original"] as? [String: Any])
        #expect(original["available"] as? Bool == false)
        #expect(original["protected"] as? Bool == true)
        let data = try Data(
            contentsOf: directory.appendingPathComponent("original.json"))
        let record = try #require(
            try JSONSerialization.jsonObject(with: data)
                as? [String: Any])
        #expect(record["available"] as? Bool == false)
        #expect(record["protected"] as? Bool == true)
    }

    @Test("a symlinked output directory cannot land inside the source EPUB")
    func symlinkOutputContainment() throws {
        let directory = try temporaryDirectory("original-symlink-out")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let link = directory.appendingPathComponent("out-link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: fixture.root)
        #expect(throws: OriginalCopyError.self) {
            _ = try OriginalService.copy(
                .available(kind: .epub, url: fixture.root), into: link)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    "original.epub").path))
    }

    @Test("a source that became protected is refused at copy time")
    func revalidatesBeforeCopy() throws {
        let directory = try temporaryDirectory("original-revalidate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("protected.pdf")
        try pdfData(encrypted: true).write(to: pdf)
        let availability = OriginalAvailability.available(
            kind: .pdf, url: pdf)
        #expect(throws: OriginalCopyError.self) {
            _ = try OriginalService.copy(
                availability, into: directory.appendingPathComponent("out"))
        }
        let fixture = try EPUBFixture.make(in: directory, encryption: true)
        #expect(throws: OriginalCopyError.self) {
            _ = try OriginalService.copy(
                .available(kind: .epub, url: fixture.root),
                into: directory.appendingPathComponent("out2"))
        }
        let root = directory.appendingPathComponent(
            "Library/eBooks/B0TOCTOU")
        let fileDirectory = root.appendingPathComponent("a")
        let voucherDirectory = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(
            at: fileDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: voucherDirectory, withIntermediateDirectories: true)
        let book = fileDirectory.appendingPathComponent("book.azw")
        try Data("azw".utf8).write(to: book)
        try Data("voucher".utf8).write(
            to: voucherDirectory.appendingPathComponent(
                "amzn1.drm-voucher.v1.test.voucher"))
        #expect(throws: OriginalCopyError.self) {
            _ = try OriginalService.copy(
                .available(kind: .azw, url: book),
                into: directory.appendingPathComponent("out3"))
        }
    }
}

@Suite("ZIP hardening")
struct ZIPHardeningTests {
    private func makeSource(
        _ directory: URL, mimetype: String? = "application/epub+zip"
    ) throws -> URL {
        let source = directory.appendingPathComponent("source")
        let meta = source.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(
            at: meta, withIntermediateDirectories: true)
        if let mimetype {
            try mimetype.write(
                to: source.appendingPathComponent("mimetype"),
                atomically: true, encoding: .utf8)
        }
        try "<container/>".write(
            to: meta.appendingPathComponent("container.xml"),
            atomically: true, encoding: .utf8)
        return source
    }

    @Test("a missing mimetype is refused")
    func missingMimetype() throws {
        let directory = try temporaryDirectory("zip-no-mimetype")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory, mimetype: nil)
        #expect(throws: ZIPError.self) {
            try ZIPArchive.write(
                directory: source,
                to: directory.appendingPathComponent("bad.epub"))
        }
    }

    @Test("a mimetype with a trailing newline is refused")
    func paddedMimetype() throws {
        let directory = try temporaryDirectory("zip-padded-mimetype")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(
            directory, mimetype: "application/epub+zip\n")
        #expect(throws: ZIPError.self) {
            try ZIPArchive.write(
                directory: source,
                to: directory.appendingPathComponent("bad.epub"))
        }
    }

    @Test("hidden publication resources survive the re-zip")
    func hiddenResources() throws {
        let directory = try temporaryDirectory("zip-hidden")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let assets = source.appendingPathComponent(".assets")
        try FileManager.default.createDirectory(
            at: assets, withIntermediateDirectories: true)
        try Data("image".utf8).write(
            to: assets.appendingPathComponent("image.png"))
        try Data("noise".utf8).write(
            to: source.appendingPathComponent(".DS_Store"))
        try Data("noise".utf8).write(
            to: source.appendingPathComponent("._resource"))
        let zip = directory.appendingPathComponent("book.epub")
        try ZIPArchive.write(directory: source, to: zip)
        #expect(
            ZIPArchive.containsEntry(
                at: zip, name: ".assets/image.png") == true)
        #expect(
            ZIPArchive.containsEntry(at: zip, name: ".DS_Store") == false)
        #expect(
            ZIPArchive.containsEntry(at: zip, name: "._resource") == false)
    }

    @Test("an internal symlink resource survives the re-zip")
    func symlinkResource() throws {
        let directory = try temporaryDirectory("zip-symlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let images = source.appendingPathComponent("images")
        try FileManager.default.createDirectory(
            at: images, withIntermediateDirectories: true)
        let target = images.appendingPathComponent("cover.jpg")
        let bytes = Data("jpeg-bytes".utf8)
        try bytes.write(to: target)
        let alias = images.appendingPathComponent("alias.jpg")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: target)
        let zip = directory.appendingPathComponent("book.epub")
        try ZIPArchive.write(directory: source, to: zip)
        #expect(
            ZIPArchive.containsEntry(
                at: zip, name: "images/alias.jpg") == true)
        #expect(
            ZIPArchive.readEntry(
                at: zip, name: "images/alias.jpg", maxBytes: 1_000_000)
                == bytes)
    }

    @Test("a symlink escaping the book is refused")
    func escapingSymlink() throws {
        let directory = try temporaryDirectory("zip-symlink-out")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let outside = directory.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("leak.txt"),
            withDestinationURL: outside)
        #expect(throws: ZIPError.self) {
            try ZIPArchive.write(
                directory: source,
                to: directory.appendingPathComponent("bad.epub"))
        }
    }

    @Test("duplicate protection entries are uninspectable")
    func duplicateProtection() throws {
        let directory = try temporaryDirectory("zip-duplicate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clear = Data(
            """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                        xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
              </enc:EncryptedData>
            </encryption>
            """.utf8)
        let protected = Data(
            """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                        xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="urn:test:protected"/>
              </enc:EncryptedData>
            </encryption>
            """.utf8)
        let duplicate = directory.appendingPathComponent("duplicate.epub")
        try rawStoredZIP(entries: [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/encryption.xml", clear),
            ("META-INF/encryption.xml", protected),
        ]).write(to: duplicate)
        #expect(
            ZIPArchive.containsEntry(
                at: duplicate, name: "META-INF/encryption.xml") == nil)
        let duplicateAsset = BooksAsset.load(
            assetID: "DUPLICATE", path: duplicate, contentType: .epub)
        #expect(
            !OriginalDetector.books(asset: duplicateAsset).isAvailable)
        let variant = directory.appendingPathComponent("variant.epub")
        try rawStoredZIP(entries: [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/encryption.xml", clear),
            ("META-INF/ENCRYPTION.XML", protected),
        ]).write(to: variant)
        #expect(
            ZIPArchive.containsEntry(
                at: variant, name: "META-INF/encryption.xml") == nil)
    }

    @Test("an oversized central directory is rejected before reading")
    func oversizedCentralDirectory() throws {
        let directory = try temporaryDirectory("zip-huge-directory")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("huge.epub")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let centralSize: UInt32 = 64 * 1024 * 1024 + 1
        let total = UInt64(centralSize) + 22
        try handle.truncate(atOffset: total)
        var eocd = Data([
            0x50, 0x4B, 0x05, 0x06,  // EOCD signature
            0, 0, 0, 0,              // disk numbers
            1, 0, 1, 0,              // entry counts
        ])
        func append32(_ value: UInt32) {
            eocd.append(UInt8(value & 0xFF))
            eocd.append(UInt8((value >> 8) & 0xFF))
            eocd.append(UInt8((value >> 16) & 0xFF))
            eocd.append(UInt8((value >> 24) & 0xFF))
        }
        append32(centralSize)
        append32(0)
        eocd.append(contentsOf: [0, 0])
        try handle.seek(toOffset: total - 22)
        try handle.write(contentsOf: eocd)
        try handle.close()
        #expect(
            ZIPArchive.containsEntry(
                at: url, name: "META-INF/encryption.xml") == nil)
    }

    @Test("a cancelled re-zip leaves no archive")
    func cancelledZip() throws {
        let directory = try temporaryDirectory("zip-cancelled")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let target = directory.appendingPathComponent("cancelled.epub")
        #expect(throws: CancellationError.self) {
            try ZIPArchive.write(
                directory: source, to: target, isCancelled: { true })
        }
        #expect(
            !FileManager.default.fileExists(atPath: target.path))
    }

    @Test("cancellation during ZIP streaming stays a cancellation")
    func cancelledZipMidStream() throws {
        let directory = try temporaryDirectory("zip-cancel-stream")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        try Data(repeating: 0x41, count: 300_000).write(
            to: source.appendingPathComponent("big.bin"))
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let counter = Counter()
        let target = directory.appendingPathComponent("mid.epub")
        #expect(throws: CancellationError.self) {
            try ZIPArchive.write(
                directory: source, to: target,
                isCancelled: { counter.next() > 6 })
        }
        #expect(
            !FileManager.default.fileExists(atPath: target.path))
    }

    @Test("a truncated central directory is unknown, not clear")
    func truncatedCentralDirectory() throws {
        let directory = try temporaryDirectory("zip-truncated")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let zip = directory.appendingPathComponent("book.epub")
        try ZIPArchive.write(directory: source, to: zip)
        #expect(
            ZIPArchive.containsEntry(
                at: zip, name: "META-INF/encryption.xml") == false)
        var data = try Data(contentsOf: zip)
        // Remove bytes from the central directory, leaving the EOCD's
        // offset and size pointing past the shortened file.
        let cut = data.count - 22 - 10
        data.removeSubrange(cut..<(cut + 10))
        let truncated = directory.appendingPathComponent("truncated.epub")
        try data.write(to: truncated)
        #expect(
            ZIPArchive.containsEntry(
                at: truncated, name: "META-INF/encryption.xml") == nil)
    }

    @Test("an unreadable subtree aborts the archive")
    func unreadableSubtree() throws {
        let directory = try temporaryDirectory("zip-unreadable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let secret = source.appendingPathComponent("secret")
        try FileManager.default.createDirectory(
            at: secret, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: secret.path)
        }
        #expect(throws: ZIPError.self) {
            try ZIPArchive.write(
                directory: source,
                to: directory.appendingPathComponent("bad.epub"))
        }
    }
}

private final class TimeoutRecordingFetcher: CoverDataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private let data: Data

    init(data: Data) { self.data = data }

    var timeouts: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func fetch(
        _ url: URL, timeout: TimeInterval, byteLimit: Int
    ) throws -> Data {
        lock.lock()
        recorded.append(timeout)
        let first = recorded.count == 1
        lock.unlock()
        if first {
            Thread.sleep(forTimeInterval: 0.2)
            throw CoverFetchError.status(404)
        }
        return data
    }
}

private final class ScriptedClock: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [TimeInterval]
    private var index = 0

    init(_ values: [TimeInterval]) { self.values = values }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

private final class TimeoutOnlyFetcher: CoverDataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var timeouts: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func fetch(
        _ url: URL, timeout: TimeInterval, byteLimit: Int
    ) throws -> Data {
        lock.lock()
        recorded.append(timeout)
        lock.unlock()
        throw CoverFetchError.status(404)
    }
}

@Suite("Cover deadline")
struct CoverDeadlineTests {
    @Test("a backward clock cannot enlarge the fallback deadline")
    func monotonicDeadline() throws {
        let directory = try temporaryDirectory("cover-monotonic")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetcher = TimeoutOnlyFetcher()
        // Start at 0, then let the clock jump backward from 5 to 3. The
        // second attempt must keep the first attempt's remaining budget,
        // not gain time.
        let clock = ScriptedClock([0, 5, 3])
        let service = BookCoverService(
            fetcher: fetcher,
            cacheDirectory: directory.appendingPathComponent("cache"),
            timeout: 10,
            clock: { clock.now() })
        let metadata = BookMetadata(
            title: "Monotonic", identifier: "B0CLOCK", source: .kindle,
            cover: .kindlePhysicalId("B0CLOCK"))
        _ = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        #expect(fetcher.timeouts == [5, 5])
    }

    @Test("the two Kindle URLs share one download deadline")
    func sharedDeadline() throws {
        let directory = try temporaryDirectory("cover-deadline")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetcher = TimeoutRecordingFetcher(
            data: try jpegData(gray: 0.4))
        let service = BookCoverService(
            fetcher: fetcher,
            cacheDirectory: directory.appendingPathComponent("cache"),
            timeout: 0.5)
        let metadata = BookMetadata(
            title: "Deadline", identifier: "DEADLINE",
            source: .kindle, cover: .kindlePhysicalId("physical"))
        let result = service.resolve(
            for: metadata, into: directory.appendingPathComponent("export"))
        #expect(result.cover?.source == .download)
        let timeouts = fetcher.timeouts
        #expect(timeouts.count == 2)
        if timeouts.count == 2 {
            #expect(timeouts[1] < timeouts[0])
        }
    }
}

@Suite("Protection edge cases")
struct ProtectionEdgeCaseTests {
    @Test("an encryption method without an algorithm fails closed")
    func missingEncryptionAlgorithm() {
        let xml = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod/>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
          </enc:EncryptedData>
        </encryption>
        """
        let status = EPUBEncryption.status(
            encryptionXML: Data(xml.utf8))
        if case .protected = status {
        } else {
            Issue.record("expected protected, got \(status)")
        }
    }

    @Test("a prefixed decoy Algorithm cannot mask protection")
    func decoyAlgorithm() {
        let xml = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#"
                    xmlns:decoy="urn:test:decoy">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="urn:test:protected"
                                  decoy:Algorithm="http://www.idpf.org/2008/embedding"/>
          </enc:EncryptedData>
        </encryption>
        """
        let status = EPUBEncryption.status(encryptionXML: Data(xml.utf8))
        if case .protected = status {
        } else {
            Issue.record("expected protected, got \(status)")
        }
    }

    @Test("a case-variant encryption declaration fails closed")
    func ambiguousUnpackedDeclaration() throws {
        let directory = try temporaryDirectory("ambiguity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory)
        let meta = fixture.root.appendingPathComponent("META-INF")
        // APFS is case-insensitive and cannot hold both spellings at once.
        // A single non-standard spelling is still ambiguous and must not be
        // silently treated as "no encryption declaration".
        try """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
          </enc:EncryptedData>
        </encryption>
        """.write(
            to: meta.appendingPathComponent("ENCRYPTION.XML"),
            atomically: true, encoding: .utf8)
        let status = EPUBEncryption.status(unpackedEPUB: fixture.root)
        if case .unknown = status {
        } else {
            Issue.record("expected unknown, got \(status)")
        }
        let asset = BooksAsset.load(
            assetID: "AMBIGUOUS", path: fixture.root,
            contentType: .epub)
        #expect(!OriginalDetector.books(asset: asset).isAvailable)
    }

    @Test("an oversized encryption declaration is not parsed")
    func oversizedDeclaration() throws {
        let directory = try temporaryDirectory("oversized-xml")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EPUBFixture.make(in: directory, encryption: true)
        let encryption = fixture.root.appendingPathComponent(
            "META-INF/encryption.xml")
        try Data(repeating: 0x20, count: 1_000_001).write(to: encryption)
        let status = EPUBEncryption.status(unpackedEPUB: fixture.root)
        if case .unknown = status {
        } else {
            Issue.record("expected unknown, got \(status)")
        }
    }

    @Test("an EncryptedData without a method is unknown")
    func encryptedDataWithoutMethod() {
        let xml = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
          </enc:EncryptedData>
          <enc:EncryptedData/>
        </encryption>
        """
        let status = EPUBEncryption.status(
            encryptionXML: Data(xml.utf8))
        if case .unknown = status {
        } else {
            Issue.record("expected unknown, got \(status)")
        }
    }

    @Test("an AZW with a large record table is still parsed")
    func largeAZWRecordTable() throws {
        let directory = try temporaryDirectory("kindle-large-table")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let book = container.appendingPathComponent("eBooks/B0LARGE/id")
        try FileManager.default.createDirectory(
            at: book, withIntermediateDirectories: true)
        try clearAZWData(recordCount: 600).write(
            to: book.appendingPathComponent("book.azw"))
        guard
            case .available(.azw, _) = OriginalDetector.kindle(
                asin: "B0LARGE", paths: KindlePaths(container: container))
        else {
            Issue.record("expected a large record table to parse")
            return
        }
    }

    @Test("a truncated MOBI header fails closed")
    func truncatedMOBIHeader() throws {
        let directory = try temporaryDirectory("kindle-truncated-mobi")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let book = container.appendingPathComponent("eBooks/B0TRUNC/id")
        try FileManager.default.createDirectory(
            at: book, withIntermediateDirectories: true)
        let full = clearAZWData()
        let truncated = Data(full.prefix(86 + 24))
        try truncated.write(to: book.appendingPathComponent("book.azw"))
        if case .protected = OriginalDetector.kindle(
            asin: "B0TRUNC", paths: KindlePaths(container: container))
        {
        } else {
            Issue.record("expected a truncated MOBI header to fail closed")
        }
    }

    @Test("a malformed AZW fails closed")
    func malformedAZW() throws {
        let directory = try temporaryDirectory("kindle-malformed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let book = container.appendingPathComponent("eBooks/B0BAD/id")
        try FileManager.default.createDirectory(
            at: book, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 200).write(
            to: book.appendingPathComponent("book.azw"))
        if case .protected = OriginalDetector.kindle(
            asin: "B0BAD", paths: KindlePaths(container: container))
        {
        } else {
            Issue.record("expected a malformed AZW to fail closed")
        }
    }

    @Test("a zipped EPUB classifies font obfuscation as clear")
    func zippedFontObfuscation() throws {
        let directory = try temporaryDirectory("zip-font")
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("font")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
        let fixture = try EPUBFixture.make(
            in: parent, encryption: true,
            encryptionAlgorithm: "http://www.idpf.org/2008/embedding")
        let zip = directory.appendingPathComponent("font.epub")
        try ZIPArchive.write(directory: fixture.root, to: zip)
        let asset = BooksAsset.load(
            assetID: "FONTZIP", path: zip, contentType: .epub)
        #expect(asset.drm == .clear)
        guard case .available(.epub, _) = OriginalDetector.books(asset: asset)
        else {
            Issue.record("expected the zipped font EPUB to be available")
            return
        }
    }

    @Test("a deflated encryption.xml is read by the real zip tool")
    func deflatedEncryption() throws {
        let directory = try temporaryDirectory("zip-deflate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let meta = source.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(
            at: meta, withIntermediateDirectories: true)
        try "application/epub+zip".write(
            to: source.appendingPathComponent("mimetype"),
            atomically: true, encoding: .utf8)
        try "<container/>".write(
            to: meta.appendingPathComponent("container.xml"),
            atomically: true, encoding: .utf8)
        try """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
          </enc:EncryptedData>
        </encryption>
        """.write(
            to: meta.appendingPathComponent("encryption.xml"),
            atomically: true, encoding: .utf8)
        let zip = directory.appendingPathComponent("deflated.epub")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = [
            "-q", "-9", "-Z", "deflate", "-r", "-X", zip.path,
            "mimetype", "META-INF",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let asset = BooksAsset.load(
            assetID: "DEFLATE", path: zip, contentType: .epub)
        #expect(asset.drm == .clear)
    }

    @Test("a voucher in a hidden Kindle subtree is found")
    func hiddenVoucher() throws {
        let directory = try temporaryDirectory("kindle-hidden")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Library")
        let book = container.appendingPathComponent("eBooks/B0HIDDEN/id")
        try FileManager.default.createDirectory(
            at: book, withIntermediateDirectories: true)
        try clearAZWData().write(
            to: book.appendingPathComponent("book.azw"))
        let hidden = container.appendingPathComponent(
            "eBooks/B0HIDDEN/.vouchers")
        try FileManager.default.createDirectory(
            at: hidden, withIntermediateDirectories: true)
        try Data("voucher".utf8).write(
            to: hidden.appendingPathComponent(
                "amzn1.drm-voucher.v1.test.voucher"))
        if case .protected = OriginalDetector.kindle(
            asin: "B0HIDDEN", paths: KindlePaths(container: container))
        {
        } else {
            Issue.record("expected the hidden voucher to be found")
        }
    }

    @Test("an unlistable output directory gets a unique original name")
    func unlistableOutputName() throws {
        let directory = try temporaryDirectory("original-unlistable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(
            at: output, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o300], ofItemAtPath: output.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: output.path)
        }
        let name = OriginalService.destinationName(
            for: .pdf, in: output)
        #expect(name.hasPrefix("original-"))
        #expect(name.hasSuffix(".pdf"))
        #expect(name != "original.pdf")
    }
}


/// A minimal stored-method ZIP, used to construct archives the writer would
/// never produce (duplicate and case-variant entries).
private func rawStoredZIP(
    entries: [(name: String, data: Data)]
) -> Data {
    var local = Data()
    var central = Data()
    func append16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
    func append32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
    for entry in entries {
        let name = Data(entry.name.utf8)
        let offset = UInt32(local.count)
        local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        append16(&local, 20)
        append16(&local, 0x0800)
        append16(&local, 0)
        append16(&local, 0)
        append16(&local, 0x0021)
        append32(&local, 0)
        append32(&local, UInt32(entry.data.count))
        append32(&local, UInt32(entry.data.count))
        append16(&local, UInt16(name.count))
        append16(&local, 0)
        local.append(name)
        local.append(entry.data)
        central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        append16(&central, 20)
        append16(&central, 20)
        append16(&central, 0x0800)
        append16(&central, 0)
        append16(&central, 0)
        append16(&central, 0x0021)
        append32(&central, 0)
        append32(&central, UInt32(entry.data.count))
        append32(&central, UInt32(entry.data.count))
        append16(&central, UInt16(name.count))
        append16(&central, 0)
        append16(&central, 0)
        append16(&central, 0)
        append16(&central, 0)
        append32(&central, 0)
        append32(&central, offset)
        central.append(name)
    }
    let centralOffset = UInt32(local.count)
    var result = local + central
    result.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
    append16(&result, 0)
    append16(&result, 0)
    append16(&result, UInt16(entries.count))
    append16(&result, UInt16(entries.count))
    append32(&result, UInt32(central.count))
    append32(&result, centralOffset)
    append16(&result, 0)
    return result
}
