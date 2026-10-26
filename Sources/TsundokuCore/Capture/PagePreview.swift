import CoreGraphics
import Foundation

public struct PagePreview: Sendable {
    public let image: CGImage
    public let windowFrame: CGRect
    public let contentRect: CGRect
    public let pageBox: CGRect
    public let crop: CaptureCrop
    public let mark: PageMark
    public let identity: ObservedIdentity
    public let text: String
    public let textFrame: CGRect?
    public let pageNumber: Int?
    public let pageCount: Int?
    public let location: PageLocation?
    public let isOnScreen: Bool
    public let capturedAt: Date

    public init(
        image: CGImage, windowFrame: CGRect, contentRect: CGRect,
        pageBox: CGRect, crop: CaptureCrop, mark: PageMark,
        identity: ObservedIdentity, text: String, textFrame: CGRect?,
        pageNumber: Int?, pageCount: Int?, location: PageLocation?,
        isOnScreen: Bool, capturedAt: Date
    ) {
        self.image = image
        self.windowFrame = windowFrame
        self.contentRect = contentRect
        self.pageBox = pageBox
        self.crop = crop
        self.mark = mark
        self.identity = identity
        self.text = text
        self.textFrame = textFrame
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.location = location
        self.isOnScreen = isOnScreen
        self.capturedAt = capturedAt
    }

    public var pageRatio: CGFloat {
        crop.rect.height > 0 ? crop.rect.width / crop.rect.height : 0
    }

    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    /// The mark for an approved crop, which can differ from the measured page
    /// box when the reader uses a free or A4-locked crop.
    public func mark(for crop: CaptureCrop) -> PageMark? {
        guard
            let pixels = try? CropTransform.pixelRect(
                crop: crop, windowFrame: windowFrame,
                contentRect: contentRect, imageSize: pixelSize),
            let cropped = try? CropTransform.croppedImage(image, crop: pixels)
        else { return nil }
        return PageMark(
            imageHash: ImageFingerprint.detailHash(cropped), text: text)
    }
}

public enum PagePreviewError: Error, CustomStringConvertible, Sendable {
    case notReading(String)
    case noWindow
    case pageChanged
    case geometryUnavailable(String)
    case capture(String)

    public var description: String {
        switch self {
        case .notReading(let state):
            "Kindle is not showing a reading page (\(state))."
        case .noWindow:
            "Kindle's reading window is not available."
        case .pageChanged:
            "The page changed while the preview was being captured. Refresh."
        case .geometryUnavailable(let reason):
            "The page box could not be measured: \(reason)"
        case .capture(let reason):
            "The preview could not be captured: \(reason)"
        }
    }
}

/// One snapshot for the preview. It never turns a page, activates Kindle, or
/// changes any reader setting.
public struct PagePreviewService: Sendable {
    public typealias Read = @Sendable () throws -> LivePage
    public typealias Capture = @Sendable (CGRect, @escaping @Sendable () -> Bool)
        throws -> CapturedWindow
    public typealias Now = @Sendable () -> Date

    private let captureService: any WindowCapturing
    private let read: Read
    private let now: Now

    public init(
        capture: any WindowCapturing = WindowCaptureService(),
        read: @escaping Read = { try KindleLive.currentPage() },
        now: @escaping Now = Date.init
    ) {
        self.captureService = capture
        self.read = read
        self.now = now
    }

    public func preview() throws -> PagePreview {
        let before = try read()
        guard before.isReading else {
            throw PagePreviewError.notReading(before.state)
        }
        guard let frame = before.windowFrame else {
            throw PagePreviewError.noWindow
        }
        let window = CGRect(
            x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let textFrame = before.pageTextFrame.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        let calibration = PageFrame.resolve(
            window: window,
            // An image-only page exposes a text frame that covers the image;
            // treating it as text headroom rejects the page box.
            text: before.text.count < 20 ? nil : textFrame,
            chrome: before.chromeInsets)
        guard calibration.status != .refused else {
            throw PagePreviewError.geometryUnavailable(
                calibration.reason ?? "the page box was refused")
        }
        let pageBox = PageFrame.pageRect(
            window: window, insets: calibration.insets)
        guard pageBox.width > 100, pageBox.height > 100 else {
            throw PagePreviewError.geometryUnavailable(
                "the measured page box is too small")
        }
        let captured: CapturedWindow
        do {
            captured = try captureService.capture(
                expectedFrame: window, isCancelled: { false })
        } catch {
            throw PagePreviewError.capture("\(error)")
        }
        let after = try read()
        guard after.isReading, after.windowFrame == before.windowFrame,
            after.text == before.text,
            after.bookID == before.bookID,
            after.endOfBook == before.endOfBook,
            after.pageNumber == before.pageNumber
                || after.pageNumber == nil || before.pageNumber == nil,
            after.pageCount == before.pageCount
                || after.pageCount == nil || before.pageCount == nil
        else {
            throw PagePreviewError.pageChanged
        }
        guard
            abs(captured.windowFrame.minX - window.minX) <= 4,
            abs(captured.windowFrame.minY - window.minY) <= 4,
            abs(captured.windowFrame.width - window.width) <= 4,
            abs(captured.windowFrame.height - window.height) <= 4
        else {
            throw PagePreviewError.pageChanged
        }
        let crop = CaptureCrop(
            rect: pageBox.offsetBy(
                dx: -captured.windowFrame.minX,
                dy: -captured.windowFrame.minY))
        let pixelRect: CGRect
        do {
            pixelRect = try CropTransform.pixelRect(
                crop: crop, windowFrame: captured.windowFrame,
                contentRect: captured.contentRect,
                imageSize: CGSize(
                    width: captured.image.width,
                    height: captured.image.height))
        } catch {
            throw PagePreviewError.geometryUnavailable("\(error)")
        }
        guard let cropped = try? CropTransform.croppedImage(
            captured.image, crop: pixelRect)
        else {
            throw PagePreviewError.geometryUnavailable(
                "the page box is outside the captured window")
        }
        let title = before.title.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let identity: ObservedIdentity
        if let bookID = before.bookID, !bookID.isEmpty {
            identity = ObservedIdentity(
                title: title, confidence: .exact(bookID))
        } else {
            identity = ObservedIdentity(
                title: title,
                confidence: title.isEmpty ? .unknown : .titleOnly(title))
        }
        return PagePreview(
            image: captured.image,
            windowFrame: captured.windowFrame,
            contentRect: captured.contentRect,
            pageBox: pageBox,
            crop: crop,
            mark: PageMark(
                imageHash: ImageFingerprint.detailHash(cropped),
                text: before.text),
            identity: identity,
            text: before.text,
            textFrame: textFrame,
            pageNumber: before.pageNumber,
            pageCount: before.pageCount,
            location: PageLocation(
                pageNumber: before.pageNumber, pageCount: before.pageCount),
            isOnScreen: captured.isOnScreen,
            capturedAt: now())
    }
}
