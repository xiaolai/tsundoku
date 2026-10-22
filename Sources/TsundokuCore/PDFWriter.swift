import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO

public struct PDFMetadata: Sendable {
    public var title: String
    public var author: String?
    public var identifier: String?
    public var source: String
    public var textDisclosure: String?

    public init(
        title: String, author: String? = nil, identifier: String? = nil,
        source: String = "Kindle",
        textDisclosure: String? =
            "Page-level text layer; not word-aligned.",
    ) {
        self.title = title
        self.author = author
        self.identifier = identifier
        self.source = source
        self.textDisclosure = textDisclosure
    }
}

public enum PDFWriterError: Error, CustomStringConvertible, Sendable {
    case noPages
    case invalidScale(CGFloat)
    case unreadablePage(index: Int, url: URL)
    case textCountMismatch(expected: Int, actual: Int)
    case textDidNotFit(page: Int, characters: Int)
    case couldNotCreateContext
    case verificationFailed(expected: Int, actual: Int)
    case cancelled
    case io(String)

    public var description: String {
        switch self {
        case .noPages:
            "There are no pages to write."
        case .invalidScale(let scale):
            "The display scale must be finite and positive, not \(scale)."
        case .unreadablePage(let index, let url):
            "Page \(index + 1) is missing or unreadable: \(url.lastPathComponent)"
        case .textCountMismatch(let expected, let actual):
            "The PDF has \(expected) pages but \(actual) text entries."
        case .textDidNotFit(let page, let characters):
            "Page \(page + 1): \(characters) characters do not fit the "
                + "invisible text layer."
        case .couldNotCreateContext:
            "Could not create the PDF context."
        case .verificationFailed(let expected, let actual):
            "The PDF has \(actual) pages; \(expected) were requested."
        case .cancelled:
            "The PDF write was cancelled."
        case .io(let message):
            "The PDF could not be written: \(message)"
        }
    }
}

public enum PDFWriter {
    public static func pageCount(_ url: URL) -> Int {
        guard let document = CGPDFDocument(url as CFURL) else { return 0 }
        return document.numberOfPages
    }

    /// One page per image, with an invisible page-level text layer.
    ///
    /// The text is searchable but not word-aligned: the AX transcription has
    /// no word boxes. The PDF metadata says so, rather than implying a
    /// precision the capture does not have.
    ///
    /// Pages are written to a temporary file, verified, then moved into place.
    /// A corrupt page or a text layer that cannot hold its text leaves no
    /// final PDF behind.
    public static func write(
        pageURLs: [URL], texts: [String], metadata: PDFMetadata,
        displayScale: CGFloat = 1,
        isCancelled: @Sendable () -> Bool = { false },
        to url: URL
    ) throws -> Int {
        guard !pageURLs.isEmpty else { throw PDFWriterError.noPages }
        guard displayScale.isFinite, displayScale > 0 else {
            throw PDFWriterError.invalidScale(displayScale)
        }
        guard texts.isEmpty || texts.count == pageURLs.count else {
            throw PDFWriterError.textCountMismatch(
                expected: pageURLs.count, actual: texts.count)
        }

        let pageSizes = try pageSizes(
            for: pageURLs, displayScale: displayScale)
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(
            ".\(url.lastPathComponent).partial-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: partial) }

        var mediaBox = CGRect(origin: .zero, size: pageSizes[0])
        guard
            let consumer = CGDataConsumer(url: partial as CFURL),
            let context = CGContext(
                consumer: consumer, mediaBox: &mediaBox,
                metadata.infoDictionary() as CFDictionary)
        else {
            throw PDFWriterError.couldNotCreateContext
        }

        for (index, pageURL) in pageURLs.enumerated() {
            if isCancelled() { throw PDFWriterError.cancelled }
            guard
                let source = CGImageSourceCreateWithURL(
                    pageURL as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw PDFWriterError.unreadablePage(
                    index: index, url: pageURL)
            }
            var box = CGRect(origin: .zero, size: pageSizes[index])
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            if index < texts.count, !texts[index].isEmpty {
                let fitted = drawInvisible(
                    texts[index], in: context, page: box)
                guard fitted else {
                    context.endPage()
                    throw PDFWriterError.textDidNotFit(
                        page: index, characters: texts[index].count)
                }
            }
            context.endPage()
        }
        context.closePDF()
        if isCancelled() { throw PDFWriterError.cancelled }
        try fsync(partial)

        guard
            let document = CGPDFDocument(partial as CFURL),
            document.numberOfPages == pageURLs.count
        else {
            throw PDFWriterError.verificationFailed(
                expected: pageURLs.count,
                actual: CGPDFDocument(partial as CFURL)?.numberOfPages ?? 0)
        }

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: url)
        }
        return pageURLs.count
    }

    /// Compatibility entry point for the current capture engine. The adapter
    /// port passes `PDFMetadata` and the recorded display scale instead.
    public static func write(
        pageURLs: [URL], texts: [String], title: String, asin: String,
        to url: URL
    ) throws -> Int {
        let identifier =
            asin.isEmpty || asin == "unknown" ? nil : asin
        return try write(
            pageURLs: pageURLs, texts: texts,
            metadata: PDFMetadata(
                title: title, identifier: identifier, source: "Kindle"),
            displayScale: 1, to: url)
    }

    private static func pageSizes(
        for pageURLs: [URL], displayScale: CGFloat
    ) throws -> [CGSize] {
        try pageURLs.enumerated().map { index, pageURL in
            guard
                let source = CGImageSourceCreateWithURL(
                    pageURL as CFURL, nil),
                CGImageSourceGetCount(source) > 0,
                let properties = CGImageSourceCopyPropertiesAtIndex(
                    source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth]
                    as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight]
                    as? NSNumber,
                width.intValue > 0, height.intValue > 0
            else {
                throw PDFWriterError.unreadablePage(
                    index: index, url: pageURL)
            }
            return CGSize(
                width: CGFloat(width.intValue) / displayScale,
                height: CGFloat(height.intValue) / displayScale)
        }
    }

    private static func drawInvisible(
        _ text: String, in context: CGContext, page: CGRect
    ) -> Bool {
        let font = CTFontCreateWithName("Helvetica" as CFString, 6, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 0),
        ]
        let attributed = NSAttributedString(
            string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let inset = min(12, page.width / 4, page.height / 4)
        let path = CGPath(
            rect: page.insetBy(dx: inset, dy: inset), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRangeMake(0, 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length >= attributed.length else { return false }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        CTFrameDraw(frame, context)
        context.restoreGState()
        return true
    }

    private static func fsync(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw PDFWriterError.io(
                "could not open \(url.lastPathComponent) for sync")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PDFWriterError.io(
                "could not sync \(url.lastPathComponent)")
        }
    }
}

private extension PDFMetadata {
    func infoDictionary() -> [CFString: Any] {
        var info: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextCreator: "Tsundoku",
        ]
        if let author, !author.isEmpty {
            info[kCGPDFContextAuthor] = author
        }
        var subject = "Captured from \(source)."
        if let textDisclosure, !textDisclosure.isEmpty {
            subject += " " + textDisclosure
        }
        info[kCGPDFContextSubject] = subject
        if let identifier, !identifier.isEmpty {
            info[kCGPDFContextKeywords] = "identifier=\(identifier)"
        }
        return info
    }
}
