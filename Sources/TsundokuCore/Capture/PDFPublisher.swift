import CoreGraphics
import Foundation

public struct PDFPublisher: CapturePublisher {
    public init() {}

    public func publish(_ artifact: CaptureArtifact) throws -> PublishedCapture {
        guard !artifact.pageURLs.isEmpty else {
            throw CapturePublisherError.noPages
        }
        let output = artifact.directory.appendingPathComponent(
            "\(Self.safeFilename(artifact.metadata.title)).pdf")
        let expected =
            artifact.pageURLs.count + (artifact.coverPage == nil ? 0 : 1)
        var warnings: [String] = []
        // The index is written with the pages, not appended afterwards: one
        // write, one verification, no read-modify-write of the PDF.
        let firstPDFPage = artifact.coverPage == nil ? 1 : 2
        let index = artifact.includePageIndex
            ? PageIndex.rows(texts: artifact.texts, firstPDFPage: firstPDFPage)
            : []
        let pages = try PDFWriter.write(
            pageURLs: artifact.pageURLs, texts: artifact.texts,
            metadata: PDFMetadata(
                title: artifact.metadata.title,
                author: artifact.metadata.author,
                identifier: artifact.metadata.identifier,
                source: artifact.metadata.source),
            cover: artifact.coverPage,
            displayScale: artifact.metadata.displayScale,
            pageSize: artifact.pageSize,
            index: index,
            indexTitle: artifact.metadata.title,
            isCancelled: { artifact.cancellation.isSet },
            warnings: { warnings.append($0) },
            to: output)
        // The writer verified the file while writing it, including the
        // index pages; this re-read catches a file damaged on disk.
        let count = PDFWriter.pageCount(output)
        guard count == pages else {
            throw CapturePublisherError.failed(
                "the PDF has \(count) pages; \(pages) were written")
        }
        let indexPages = max(0, pages - expected)
        guard indexPages > 0 else {
            return PublishedCapture(
                url: output, pageCount: pages, warnings: warnings)
        }
        let csv = output.deletingPathExtension()
            .appendingPathExtension("page-map.csv")
        try? PageIndex.csv(index).write(
            to: csv, atomically: true, encoding: .utf8)
        return PublishedCapture(
            url: output, pageCount: pages, warnings: warnings,
            indexPages: indexPages, pageMapURL: csv)
    }

    static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.unicodeScalars.map {
            invalid.contains($0) ? "-" : Character($0)
        }
        let text = String(cleaned).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Kindle book" }
        // APFS limits one path component to 255 UTF-8 bytes. Truncate on
        // character boundaries with room for ".pdf" and a de-duplication
        // suffix, not by a character count that emoji can exceed.
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > 200 { break }
            result.append(character)
            bytes += size
        }
        return result.isEmpty ? "Kindle book" : result
    }
}
