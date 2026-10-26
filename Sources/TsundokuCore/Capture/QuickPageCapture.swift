import CoreGraphics
import Foundation

public struct QuickPageCapture: Sendable {
    public let image: CGImage
    public let text: String
    public let textSource: ReaderTextSource
    public let pageNumber: Int?
    public let pageCount: Int?
    public let identity: ObservedIdentity
    public let capturedAt: Date

    public init(
        image: CGImage, text: String, textSource: ReaderTextSource,
        pageNumber: Int?, pageCount: Int?, identity: ObservedIdentity,
        capturedAt: Date
    ) {
        self.image = image
        self.text = text
        self.textSource = textSource
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.identity = identity
        self.capturedAt = capturedAt
    }
}

/// One image plus matching text from the current page. It never turns a page,
/// fits A4, applies the Exports crop, or writes a PDF.
public struct QuickPageCaptureService: Sendable {
    private let preview: PagePreviewService

    public init(preview: PagePreviewService = PagePreviewService()) {
        self.preview = preview
    }

    public func capture() throws -> QuickPageCapture {
        let snapshot = try preview.preview()
        let crop = snapshot.crop
        let pixelRect = try CropTransform.pixelRect(
            crop: crop, windowFrame: snapshot.windowFrame,
            contentRect: snapshot.contentRect,
            imageSize: snapshot.pixelSize)
        let image = try CropTransform.croppedImage(
            snapshot.image, crop: pixelRect)
        var text = snapshot.text
        var source: ReaderTextSource =
            text.isEmpty ? .none : .accessibility
        if text.isEmpty,
            let recognised = try? BooksOCR.recognize(image),
            !recognised.isEmpty
        {
            text = recognised
            source = .ocr
        }
        return QuickPageCapture(
            image: image, text: text, textSource: source,
            pageNumber: snapshot.pageNumber, pageCount: snapshot.pageCount,
            identity: snapshot.identity, capturedAt: snapshot.capturedAt)
    }
}
