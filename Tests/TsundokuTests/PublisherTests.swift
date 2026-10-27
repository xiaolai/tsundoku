import CoreGraphics
import Foundation
import Testing

@testable import TsundokuCore

private enum PublisherTestError: Error {
    case noImage
    case publicationFailed
}

private struct FailingPublisher: CapturePublisher {
    func publish(_ artifact: CaptureArtifact) throws -> PublishedCapture {
        throw PublisherTestError.publicationFailed
    }
}

private final class OnePageSession: ReaderCaptureSession {
    let identity = ObservedIdentity(
        title: "A Book", confidence: .titleOnly("A Book"))
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

private final class TwoPageSession: ReaderCaptureSession {
    let identity = ObservedIdentity(
        title: "A Book", confidence: .titleOnly("A Book"))
    let mode = CaptureMode(
        layout: .reflowable, navigation: .automatic,
        endDetection: .positive)
    private let pages: [PageSnapshot]
    private var index = 0

    init(pages: [PageSnapshot]) { self.pages = pages }

    func snapshot() throws -> PageSnapshot { pages[index] }

    func advance(after mark: PageMark) throws -> PageTransition {
        if index + 1 < pages.count {
            index += 1
            return .turned(
                pages[index],
                TurnRecord(
                    attempted: true, posted: true, observed: true,
                    terminal: false, unresolved: false))
        }
        return .endOfBook(
            TurnRecord(
                attempted: true, posted: true, observed: true,
                terminal: true, unresolved: false))
    }

    func restore() -> RestoreReport {
        RestoreReport(
            opening: PageLocation(pageNumber: 1, pageCount: pages.count),
            final: PageLocation(pageNumber: pages.count, pageCount: pages.count),
            attempted: 0, posted: 0, observed: 0, terminal: 0,
            unresolved: 0, exact: true, reason: nil)
    }
}

private func publisherImage() throws -> CGImage {
    guard
        let context = CGContext(
            data: nil, width: 40, height: 60, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw PublisherTestError.noImage }
    context.setFillColor(CGColor(gray: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
    guard let image = context.makeImage() else {
        throw PublisherTestError.noImage
    }
    return image
}

private func publisherSnapshot() throws -> PageSnapshot {
    let image = try publisherImage()
    return PageSnapshot(
        identity: ObservedIdentity(
            title: "A Book", confidence: .titleOnly("A Book")),
        image: image, text: "alpha", textSource: .accessibility,
        pageNumber: 1, pageCount: 1,
        location: PageLocation(pageNumber: 1, pageCount: 1),
        isEndOfBook: false,
        cropRect: CGRect(x: 0, y: 0, width: 40, height: 60),
        pixelSize: CGSize(width: 40, height: 60),
        mark: PageMark(imageHash: 1, text: "alpha"))
}

private func publisherDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tsundoku-publisher-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Capture publisher")
struct PublisherTests {
    @Test("PDFPublisher publishes the artifact")
    func pdfPublisher() throws {
        let directory = try publisherDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureArtifactStore(output: directory)
        _ = try store.commitPage(
            image: try publisherImage(), text: "alpha",
            source: "accessibility")
        let artifact = CaptureArtifact(
            directory: directory, pageURLs: store.pageURLs,
            texts: ["alpha"],
            metadata: CaptureMetadata(
                title: "A Book", author: "Author", identifier: "B01",
                source: "Kindle"),
            termination: .endOfBook)
        let published = try PDFPublisher().publish(artifact)
        #expect(published.pageCount == 1)
        #expect(FileManager.default.fileExists(atPath: published.url.path))
        #expect(PDFWriter.pageCount(published.url) == 1)
    }

    @Test("display scale reaches the published page size")
    func displayScaleReachesPDF() throws {
        let directory = try publisherDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        let output = directory.appendingPathComponent("capture")
        let image = try scaledImage(width: 1200, height: 1600)
        let page = PageSnapshot(
            identity: ObservedIdentity(
                title: "A Book", confidence: .titleOnly("A Book")),
            image: image, text: "alpha", textSource: .accessibility,
            pageNumber: 1, pageCount: 1,
            location: PageLocation(pageNumber: 1, pageCount: 1),
            isEndOfBook: false,
            cropRect: CGRect(x: 0, y: 0, width: 600, height: 800),
            pixelSize: CGSize(width: 1200, height: 1600),
            mark: PageMark(imageHash: 1, text: "alpha"))
        let result = try CaptureJobEngine(archive: archive).run(
            session: OnePageSession(page: page),
            subject: CaptureSubject(book: nil, kind: .kindle),
            pageLimit: nil, output: output,
            progress: { _ in }, isCancelled: { false },
            lifecycle: CaptureLifecycle(locked: { false }))
        let pdf = try #require(CGPDFDocument(result.pdf as CFURL))
        let box = try #require(pdf.page(at: 1)).getBoxRect(.mediaBox)
        #expect(box.size == CGSize(width: 600, height: 800))
    }

    @Test("a resumed run continues after the pages already stored")
    func resumeAppendsPages() throws {
        let directory = try publisherDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        let output = directory.appendingPathComponent("capture")
        let first = try publisherSnapshot()
        let second = PageSnapshot(
            identity: first.identity, image: first.image, text: "beta",
            textSource: .accessibility, pageNumber: 2, pageCount: 2,
            location: PageLocation(pageNumber: 2, pageCount: 2),
            isEndOfBook: false,
            cropRect: first.cropRect, pixelSize: first.pixelSize,
            mark: PageMark(imageHash: 2, text: "beta"))
        // Stage the folder as a failed first run would leave it.
        let staged = try CaptureArtifactStore(output: output)
        _ = try staged.commitPage(
            image: first.image, text: "alpha", source: "accessibility")
        try staged.writeManifest([
            "state": "running", "title": "A Book",
        ])
        #expect(throws: CaptureStoreError.self) {
            _ = try CaptureArtifactStore(output: output)
        }

        let result = try CaptureJobEngine(archive: archive).run(
            session: TwoPageSession(pages: [first, second]),
            subject: CaptureSubject(book: nil, kind: .kindle),
            pageLimit: nil, output: output,
            progress: { _ in }, isCancelled: { false },
            lifecycle: CaptureLifecycle(locked: { false }),
            resume: true)
        #expect(result.pages == 2)
        #expect(PDFWriter.pageCount(result.pdf) == 2)
        let text = try String(
            contentsOf: output.appendingPathComponent("text.jsonl"),
            encoding: .utf8)
        #expect(text.contains("\"alpha\""))
        #expect(text.contains("\"beta\""))
    }

    private func scaledImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PublisherTestError.noImage }
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw PublisherTestError.noImage
        }
        return image
    }

    @Test("a long emoji title fits the filename byte budget")
    func filenameBytes() {
        let name = PDFPublisher.safeFilename(
            String(repeating: "🎉", count: 100))
        #expect(!name.isEmpty)
        #expect(name.utf8.count <= 200)
    }

    @Test("a text layer that cannot hold a page is a capture warning")
    func textLayerWarningReachesManifest() throws {
        let directory = try publisherDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        let output = directory.appendingPathComponent("capture")
        let dense = String(repeating: "word ", count: 20_000)
        let page = PageSnapshot(
            identity: ObservedIdentity(
                title: "A Book", confidence: .titleOnly("A Book")),
            image: try publisherImage(), text: dense,
            textSource: .accessibility, pageNumber: 1, pageCount: 1,
            location: PageLocation(pageNumber: 1, pageCount: 1),
            isEndOfBook: false,
            cropRect: CGRect(x: 0, y: 0, width: 40, height: 60),
            pixelSize: CGSize(width: 40, height: 60),
            mark: PageMark(imageHash: 1, text: dense))
        _ = try CaptureJobEngine(archive: archive).run(
            session: OnePageSession(page: page),
            subject: CaptureSubject(book: nil, kind: .kindle),
            pageLimit: nil, output: output,
            progress: { _ in }, isCancelled: { false },
            lifecycle: CaptureLifecycle(locked: { false }))
        let manifestData = try Data(
            contentsOf: output.appendingPathComponent("manifest.json"))
        let manifest = try #require(
            JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any])
        let warnings = manifest["warnings"] as? [String] ?? []
        #expect(warnings.contains { $0.contains("text layer") })
    }

    @Test("a publication failure leaves the capture retryable")
    func publicationFailureRetry() throws {
        let directory = try publisherDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Archive(
            path: directory.appendingPathComponent("archive.sqlite"))
        let output = directory.appendingPathComponent("capture")
        let page = try publisherSnapshot()
        #expect(throws: Error.self) {
            _ = try CaptureJobEngine(archive: archive).run(
                session: OnePageSession(page: page),
                subject: CaptureSubject(book: nil, kind: .kindle),
                pageLimit: nil, output: output,
                progress: { _ in }, isCancelled: { false },
                lifecycle: CaptureLifecycle(locked: { false }),
                publisher: FailingPublisher())
        }
        let pages = output.appendingPathComponent("pages")
        #expect(FileManager.default.fileExists(atPath: pages.path))
        let manifestData = try Data(
            contentsOf: output.appendingPathComponent("manifest.json"))
        let manifest = try #require(
            JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any])
        #expect(manifest["state"] as? String == "incomplete")
        #expect(
            !FileManager.default.fileExists(
                atPath: output.appendingPathComponent("A Book.pdf").path))
    }
}
