import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import TsundokuCore

private enum TestFailure: Error {
    case couldNotMakeImage
    case couldNotWriteImage
}

@Suite("PDF writer")
struct PDFWriterTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsundoku-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePNG(
        width: Int, height: Int, gray: CGFloat = 0.8, in directory: URL
    ) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TestFailure.couldNotMakeImage }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestFailure.couldNotMakeImage
        }
        let url = directory.appendingPathComponent(
            "\(UUID().uuidString).png")
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw TestFailure.couldNotWriteImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestFailure.couldNotWriteImage
        }
        return url
    }

    private func partialFiles(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path))?.filter { $0.contains(".partial-") } ?? []
    }

    @Test("three pages become a searchable PDF with metadata")
    func writesSearchablePDF() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = try (0..<3).map { _ in
            try makePNG(width: 240, height: 320, in: directory)
        }
        let output = directory.appendingPathComponent("book.pdf")
        let metadata = PDFMetadata(
            title: "A Book", author: "Ada Lovelace",
            identifier: "B0123", source: "Apple Books",
            textDisclosure: "OCR text; not word-aligned.")
        let count = try PDFWriter.write(
            pageURLs: pages, texts: ["alpha", "beta", "gamma"],
            metadata: metadata, displayScale: 1, to: output)

        #expect(count == 3)
        #expect(PDFWriter.pageCount(output) == 3)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(partialFiles(in: directory).isEmpty)

        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 3)
        #expect(document.page(at: 1)?.string?.contains("beta") == true)
        let attributes = document.documentAttributes
        #expect(
            attributes?[PDFDocumentAttribute.titleAttribute] as? String
                == "A Book")
        #expect(
            attributes?[PDFDocumentAttribute.authorAttribute] as? String
                == "Ada Lovelace")
        #expect(attributes?[PDFDocumentAttribute.creationDateAttribute] != nil)
        let subject =
            attributes?[PDFDocumentAttribute.subjectAttribute] as? String
        #expect(subject?.contains("Apple Books") == true)
        #expect(subject?.contains("OCR text") == true)
        let keywords = String(
            describing: attributes?[PDFDocumentAttribute.keywordsAttribute])
        #expect(keywords.contains("B0123"))
    }

    @Test("a corrupt middle page throws and leaves no final PDF")
    func corruptPageThrows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makePNG(width: 200, height: 300, in: directory)
        let second = directory.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: second)
        let third = try makePNG(width: 200, height: 300, in: directory)
        let output = directory.appendingPathComponent("book.pdf")

        #expect(throws: PDFWriterError.self) {
            try PDFWriter.write(
                pageURLs: [first, second, third],
                texts: ["a", "b", "c"],
                metadata: PDFMetadata(title: "Broken"),
                to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(partialFiles(in: directory).isEmpty)
    }

    @Test("a text count mismatch throws")
    func textCountMismatchThrows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = try (0..<2).map { _ in
            try makePNG(width: 200, height: 300, in: directory)
        }
        let output = directory.appendingPathComponent("book.pdf")
        #expect(throws: PDFWriterError.self) {
            try PDFWriter.write(
                pageURLs: pages, texts: ["only one"],
                metadata: PDFMetadata(title: "Mismatch"), to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("an empty text page is still a page")
    func emptyTextPage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = try (0..<2).map { _ in
            try makePNG(width: 200, height: 300, in: directory)
        }
        let output = directory.appendingPathComponent("book.pdf")
        _ = try PDFWriter.write(
            pageURLs: pages, texts: ["", "beta"],
            metadata: PDFMetadata(title: "Blank"), to: output)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 1)?.string?.contains("beta") == true)
    }

    @Test("oversized text throws instead of silently clipping")
    func oversizedTextThrows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try makePNG(width: 120, height: 120, in: directory)
        let output = directory.appendingPathComponent("book.pdf")
        let text = String(repeating: "A", count: 50_000)
        #expect(throws: PDFWriterError.self) {
            try PDFWriter.write(
                pageURLs: [page], texts: [text],
                metadata: PDFMetadata(title: "Too long"), to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("page points are pixels divided by display scale")
    func pagePointsUseDisplayScale() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try makePNG(width: 200, height: 300, in: directory)
        let oneX = directory.appendingPathComponent("one.pdf")
        let twoX = directory.appendingPathComponent("two.pdf")
        _ = try PDFWriter.write(
            pageURLs: [page], texts: ["x"],
            metadata: PDFMetadata(title: "One"), displayScale: 1, to: oneX)
        _ = try PDFWriter.write(
            pageURLs: [page], texts: ["x"],
            metadata: PDFMetadata(title: "Two"), displayScale: 2, to: twoX)

        let onePage = try #require(
            CGPDFDocument(oneX as CFURL)?.page(at: 1))
        let twoPage = try #require(
            CGPDFDocument(twoX as CFURL)?.page(at: 1))
        #expect(onePage.getBoxRect(.mediaBox).size == CGSize(
            width: 200, height: 300))
        #expect(twoPage.getBoxRect(.mediaBox).size == CGSize(
            width: 100, height: 150))
    }

    @Test("cancellation during the write leaves no final PDF")
    func cancellationDuringWrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pages = try (0..<2).map { _ in
            try makePNG(width: 200, height: 300, in: directory)
        }
        let output = directory.appendingPathComponent("cancelled.pdf")
        final class Counter: @unchecked Sendable {
            var calls = 0
        }
        let counter = Counter()
        #expect(throws: PDFWriterError.self) {
            try PDFWriter.write(
                pageURLs: pages, texts: ["a", "b"],
                metadata: PDFMetadata(title: "Cancelled"),
                displayScale: 1,
                isCancelled: {
                    counter.calls += 1
                    return counter.calls > 1
                },
                to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(partialFiles(in: directory).isEmpty)
    }

    @Test("a free crop is padded onto an A4 page")
    func freeCropA4Page() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageURL = try makePNG(width: 200, height: 400, in: directory)
        let output = directory.appendingPathComponent("a4.pdf")
        _ = try PDFWriter.write(
            pageURLs: [pageURL], texts: ["included sentence"],
            metadata: PDFMetadata(title: "A4"),
            displayScale: 1, pageSize: CapturePageSize.a4.points,
            to: output)
        let pdf = try #require(CGPDFDocument(output as CFURL))
        let pdfPage = try #require(pdf.page(at: 1))
        let box = pdfPage.getBoxRect(.mediaBox)
        #expect(abs(box.width - 595.28) < 0.1)
        #expect(abs(box.height - 841.89) < 0.1)
        let document = try #require(PDFDocument(url: output))
        #expect(document.string?.contains("included sentence") == true)
    }

    @Test("the legacy entry point still writes a PDF")
    func legacyEntryPoint() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try makePNG(width: 200, height: 300, in: directory)
        let output = directory.appendingPathComponent("legacy.pdf")
        let count = try PDFWriter.write(
            pageURLs: [page], texts: ["legacy"], title: "Legacy",
            asin: "B0999", to: output)
        #expect(count == 1)
        #expect(PDFWriter.pageCount(output) == 1)
        let document = try #require(PDFDocument(url: output))
        let keywords = String(
            describing: document.documentAttributes?[
                PDFDocumentAttribute.keywordsAttribute])
        #expect(keywords.contains("B0999"))
    }
}
