import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

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
    public static func write(
        pageURLs: [URL], texts: [String], title: String, asin: String,
        to url: URL
    ) throws -> Int {
        guard !pageURLs.isEmpty else {
            throw CaptureError.pdfFailed("There are no pages to write.")
        }
        guard
            let firstSource = CGImageSourceCreateWithURL(
                pageURLs[0] as CFURL, nil),
            let firstImage = CGImageSourceCreateImageAtIndex(
                firstSource, 0, nil)
        else {
            throw CaptureError.pdfFailed("The first page is not an image.")
        }
        var mediaBox = CGRect(
            x: 0, y: 0, width: CGFloat(firstImage.width),
            height: CGFloat(firstImage.height))
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextAuthor: "Kindle",
            kCGPDFContextCreator: "Kindling",
            kCGPDFContextSubject:
                "Captured from Kindle. Page-level text layer; "
                + "not word-aligned.",
        ]
        guard let consumer = CGDataConsumer(url: url as CFURL),
            let context = CGContext(
                consumer: consumer, mediaBox: &mediaBox,
                info as CFDictionary)
        else {
            throw CaptureError.pdfFailed("Could not create the PDF context.")
        }
        for (index, pageURL) in pageURLs.enumerated() {
            guard
                let source = CGImageSourceCreateWithURL(pageURL as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            var box = CGRect(
                x: 0, y: 0, width: CGFloat(image.width),
                height: CGFloat(image.height))
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            if index < texts.count, !texts[index].isEmpty {
                drawInvisible(texts[index], in: context, page: box)
            }
            context.endPage()
        }
        context.closePDF()
        return pageURLs.count
    }

    private static func drawInvisible(
        _ text: String, in context: CGContext, page: CGRect
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 6, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                NSColor.clear.cgColor,
        ]
        let attributed = NSAttributedString(
            string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: page.insetBy(dx: 12, dy: 12), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRangeMake(0, 0), path, nil)
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
