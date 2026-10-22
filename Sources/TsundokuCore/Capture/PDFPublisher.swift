import Foundation

public struct PDFPublisher: CapturePublisher {
    public init() {}

    public func publish(_ artifact: CaptureArtifact) throws -> PublishedCapture {
        guard !artifact.pageURLs.isEmpty else {
            throw CapturePublisherError.noPages
        }
        let output = artifact.directory.appendingPathComponent(
            "\(Self.safeFilename(artifact.metadata.title)).pdf")
        let pages = try PDFWriter.write(
            pageURLs: artifact.pageURLs, texts: artifact.texts,
            metadata: PDFMetadata(
                title: artifact.metadata.title,
                author: artifact.metadata.author,
                identifier: artifact.metadata.identifier,
                source: artifact.metadata.source),
            displayScale: artifact.metadata.displayScale,
            isCancelled: { artifact.cancellation.isSet },
            to: output)
        let count = PDFWriter.pageCount(output)
        guard count == pages else {
            throw CapturePublisherError.failed(
                "the PDF has \(count) pages; \(pages) were captured")
        }
        return PublishedCapture(url: output, pageCount: count)
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
