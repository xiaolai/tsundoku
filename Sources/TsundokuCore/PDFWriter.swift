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

/// The optional first page: a vector cover with the book's identity and the
/// capture record. Text is Core Text, so it is selectable and searchable.
public struct PDFCoverPage: Sendable, Equatable {
    public let title: String
    public let author: String?
    public let identifier: String?
    public let source: String
    public let exportDate: Date
    public let capturedPages: Int
    public let coverImageURL: URL?
    public let textDisclosure: String?
    /// Points. `nil` uses the first captured page's size.
    public let pageSize: CGSize?

    public init(
        title: String, author: String?, identifier: String?,
        source: String, exportDate: Date, capturedPages: Int,
        coverImageURL: URL?, textDisclosure: String?,
        pageSize: CGSize?
    ) {
        self.title = title
        self.author = author
        self.identifier = identifier
        self.source = source
        self.exportDate = exportDate
        self.capturedPages = capturedPages
        self.coverImageURL = coverImageURL
        self.textDisclosure = textDisclosure
        self.pageSize = pageSize
    }
}

public enum PDFWriterError: Error, CustomStringConvertible, Sendable {
    case noPages
    case invalidScale(CGFloat)
    case unreadablePage(index: Int, url: URL)
    case textCountMismatch(expected: Int, actual: Int)
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
    /// A page whose text cannot fit the layer is reported through `warnings`
    /// and written with the part that does fit: losing the whole book over
    /// one dense page would be worse than a page whose search text is
    /// incomplete.
    ///
    /// Pages are written to a temporary file, verified, then moved into place.
    /// A corrupt page leaves no final PDF behind.
    public static func write(
        pageURLs: [URL], texts: [String], metadata: PDFMetadata,
        cover: PDFCoverPage? = nil,
        displayScale: CGFloat = 1,
        pageSize: CGSize? = nil,
        index: [PageIndexRow] = [],
        indexTitle: String = "",
        isCancelled: @Sendable () -> Bool = { false },
        warnings: ((String) -> Void)? = nil,
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
        let expectedPages = pageURLs.count + (cover == nil ? 0 : 1)
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(
            ".\(url.lastPathComponent).partial-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: partial) }

        let outputSize = pageSize ?? cover?.pageSize ?? pageSizes[0]
        var mediaBox = CGRect(origin: .zero, size: outputSize)
        guard
            let consumer = CGDataConsumer(url: partial as CFURL),
            let context = CGContext(
                consumer: consumer, mediaBox: &mediaBox,
                metadata.infoDictionary() as CFDictionary)
        else {
            throw PDFWriterError.couldNotCreateContext
        }

        if let cover {
            if isCancelled() { throw PDFWriterError.cancelled }
            var box = CGRect(origin: .zero, size: outputSize)
            context.beginPage(mediaBox: &box)
            drawCover(cover, in: box, context: context)
            context.endPage()
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
            var box = CGRect(
                origin: .zero, size: pageSize ?? pageSizes[index])
            // An A4 output for a wide spread centers the image on the page
            // instead of stretching it; the text layer stays on the image.
            let imageRect =
                pageSize == nil
                ? box
                : aspectFit(
                    CGSize(
                        width: CGFloat(image.width),
                        height: CGFloat(image.height)),
                    in: box)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: imageRect)
            if index < texts.count, !texts[index].isEmpty {
                let complete = drawInvisible(
                    texts[index], in: context, page: imageRect)
                if !complete {
                    warnings?(
                        "Page \(index + 1): the PDF text layer could not "
                            + "hold all of this page's text; search may miss "
                            + "part of it.")
                }
            }
            context.endPage()
        }
        // The page index goes after the book's own pages: in the same context,
        // so the file is written once, and at the end, so the pages the reader
        // already knows keep their numbers.
        var indexPages = 0
        if !index.isEmpty {
            let body = PageIndex.attributedBody(rows: index, title: indexTitle)
            indexPages = PageIndex.draw(
                body, in: context, pageSize: PageIndex.pageSize)
        }
        context.closePDF()
        if isCancelled() { throw PDFWriterError.cancelled }
        try fsync(partial)

        let expectedTotal = expectedPages + indexPages
        guard
            let document = CGPDFDocument(partial as CFURL),
            document.numberOfPages == expectedTotal
        else {
            throw PDFWriterError.verificationFailed(
                expected: expectedTotal,
                actual: CGPDFDocument(partial as CFURL)?.numberOfPages ?? 0)
        }

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: url)
        }
        return expectedTotal
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

    private static func aspectFit(
        _ size: CGSize, in box: CGRect
    ) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(
            box.width / size.width, box.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(
            x: box.midX - width / 2, y: box.midY - height / 2,
            width: width, height: height)
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

    // MARK: - Cover page

    private static func drawCover(
        _ cover: PDFCoverPage, in page: CGRect, context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(page)
        let margin = min(
            56, max(12, min(page.width, page.height) * 0.08))
        let contentWidth = max(1, page.width - margin * 2)
        var top = page.maxY - margin

        let detailsFont = CTFontCreateWithName(
            "Helvetica" as CFString, 11, nil)
        let disclosureFont = CTFontCreateWithName(
            "Helvetica" as CFString, 9, nil)
        let detailColor = CGColor(gray: 0.28, alpha: 1)
        let disclosureColor = CGColor(gray: 0.46, alpha: 1)
        var detailLines: [String] = []
        if let identifier = cover.identifier, !identifier.isEmpty {
            detailLines.append("Identifier: \(identifier)")
        }
        detailLines.append("Source: \(cover.source)")
        detailLines.append("Captured pages: \(cover.capturedPages)")
        detailLines.append("Exported: \(exportDateString(cover.exportDate))")
        let details = detailLines.joined(separator: "\n")
        let disclosure = cover.textDisclosure
            ?? "Page-level text layer; not word-aligned."
        let detailsHeight = measureText(
            details, font: detailsFont, width: contentWidth)
        let disclosureHeight = measureText(
            disclosure, font: disclosureFont, width: contentWidth)
        let bottom = page.minY + margin
        let disclosureTop = bottom + disclosureHeight
        let detailsTop = disclosureTop + 10 + detailsHeight
        let bottomBlockTop = detailsTop + margin * 0.8

        // The image takes at most 55% of the free column; the title and
        // author keep the rest, so a small page or long metadata cannot
        // overlap the capture record.
        let available = max(0, top - bottomBlockTop)
        let maxImageHeight = min(page.height * 0.46, available * 0.55)
        if maxImageHeight >= 40,
            let imageURL = cover.coverImageURL,
            let source = CGImageSourceCreateWithURL(
                imageURL as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3000,
                ] as CFDictionary),
            image.width > 0, image.height > 0
        {
            let scale = min(
                contentWidth / CGFloat(image.width),
                maxImageHeight / CGFloat(image.height))
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            let rect = CGRect(
                x: page.midX - width / 2, y: top - height,
                width: width, height: height)
            context.draw(image, in: rect)
            top -= height + margin * 0.7
        }

        var titleSize = min(40, max(8, page.width * 0.06))
        var authorSize = min(15, max(8, page.height * 0.02))
        func blockHeight() -> CGFloat {
            let titleHeight = measureText(
                cover.title,
                font: CTFontCreateWithName(
                    "Helvetica-Bold" as CFString, titleSize, nil),
                width: contentWidth)
            let authorHeight =
                cover.author.map {
                    measureText(
                        $0,
                        font: CTFontCreateWithName(
                            "Helvetica" as CFString, authorSize, nil),
                        width: contentWidth) + 12
                } ?? 0
            return titleHeight + authorHeight
        }
        while top - blockHeight() - 8 < bottomBlockTop {
            if authorSize > 8 {
                authorSize -= 1
            } else if titleSize > 8 {
                titleSize -= 1
            } else {
                break
            }
        }
        let titleFont = CTFontCreateWithName(
            "Helvetica-Bold" as CFString, titleSize, nil)
        let titleMax = max(0, top - bottomBlockTop)
        let titleTop = drawText(
            cover.title, font: titleFont,
            color: CGColor(gray: 0.08, alpha: 1),
            x: margin, width: contentWidth, top: top,
            maxHeight: titleMax, context: context)
        top = titleTop - 12
        if let author = cover.author, !author.isEmpty,
            top - bottomBlockTop > 8
        {
            let authorFont = CTFontCreateWithName(
                "Helvetica" as CFString, authorSize, nil)
            top = drawText(
                author, font: authorFont,
                color: CGColor(gray: 0.25, alpha: 1),
                x: margin, width: contentWidth, top: top,
                maxHeight: max(0, top - bottomBlockTop),
                context: context) - 8
        }
        if top > bottomBlockTop + 8 {
            context.setStrokeColor(CGColor(gray: 0.62, alpha: 1))
            context.setLineWidth(1)
            context.move(to: CGPoint(x: margin, y: top - 4))
            context.addLine(
                to: CGPoint(x: page.maxX - margin, y: top - 4))
            context.strokePath()
        }
        _ = drawText(
            disclosure, font: disclosureFont, color: disclosureColor,
            x: margin, width: contentWidth, top: disclosureTop,
            context: context)
        _ = drawText(
            details, font: detailsFont, color: detailColor,
            x: margin, width: contentWidth, top: detailsTop,
            context: context)
        context.restoreGState()
    }

    @discardableResult
    private static func drawText(
        _ text: String, font: CTFont, color: CGColor, x: CGFloat,
        width: CGFloat, top: CGFloat, maxHeight: CGFloat? = nil,
        context: CGContext
    ) -> CGFloat {
        let attributed = attributedText(text, font: font, color: color)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let measuredHeight = ceil(measured.height) + 2
        let height = max(0, min(measuredHeight, maxHeight ?? measuredHeight))
        guard height > 0 else { return top }
        let rect = CGRect(
            x: x, y: top - height, width: width, height: height)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, context)
        return top - height
    }

    private static func measureText(
        _ text: String, font: CTFont, width: CGFloat
    ) -> CGFloat {
        let attributed = attributedText(
            text, font: font, color: CGColor(gray: 0, alpha: 1))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(measured.height) + 2
    }

    private static func attributedText(
        _ text: String, font: CTFont, color: CGColor
    ) -> NSAttributedString {
        return NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(
                    kCTForegroundColorAttributeName as String): color,
            ])
    }

    private static func exportDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Draws the page's text invisibly. Returns false when only part of it
    /// fitted.
    ///
    /// The layer is a searchable text stream, not a visual layout: hard line
    /// breaks from the transcription carry no meaning, and a page of many
    /// short lines would otherwise overflow the frame. Collapse every
    /// whitespace run to one space first, then shrink the (invisible) font
    /// until the text fits, and draw the visible prefix as a last resort.
    private static func drawInvisible(
        _ text: String, in context: CGContext, page: CGRect
    ) -> Bool {
        let plain = text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !plain.isEmpty else { return true }
        for size in [6.0, 4.0, 3.0, 2.0] {
            if draw(plain, in: context, page: page, size: size) {
                return true
            }
        }
        // Nothing fits at the smallest size; draw what does. The caller
        // records the incomplete layer in the capture warnings.
        _ = draw(plain, in: context, page: page, size: 2)
        return false
    }

    private static func draw(
        _ text: String, in context: CGContext, page: CGRect, size: CGFloat
    ) -> Bool {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
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
        guard visible.length > 0 else { return false }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        CTFrameDraw(frame, context)
        context.restoreGState()
        return visible.length >= attributed.length
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
