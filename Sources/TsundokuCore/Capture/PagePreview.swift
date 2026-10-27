import CoreGraphics
import Foundation

public struct PagePreview: Sendable {
    public let image: CGImage
    public let windowFrame: CGRect
    public let contentRect: CGRect
    public let pageBox: CGRect
    public let crop: CaptureCrop
    public let identity: ObservedIdentity
    public let text: String
    public let pageNumber: Int?
    public let pageCount: Int?
    public let pageBoxNote: String?
    /// The live read taken after the screenshot. Readiness can reuse it
    /// instead of walking Kindle's AX tree a second time.
    public let live: LivePage

    public init(
        image: CGImage, windowFrame: CGRect, contentRect: CGRect,
        pageBox: CGRect, crop: CaptureCrop,
        identity: ObservedIdentity, text: String, pageNumber: Int?,
        pageCount: Int?, live: LivePage, pageBoxNote: String? = nil
    ) {
        self.image = image
        self.windowFrame = windowFrame
        self.contentRect = contentRect
        self.pageBox = pageBox
        self.crop = crop
        self.identity = identity
        self.text = text
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.pageBoxNote = pageBoxNote
        self.live = live
    }

    public var pageRatio: CGFloat {
        crop.rect.height > 0 ? crop.rect.width / crop.rect.height : 0
    }

    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    /// The cropped image for an approved crop. Preview, quick capture and the
    /// mark all share this one transform.
    public func croppedImage(for crop: CaptureCrop) throws -> CGImage {
        let pixels = try CropTransform.pixelRect(
            crop: crop, windowFrame: windowFrame,
            contentRect: contentRect, imageSize: pixelSize)
        return try CropTransform.croppedImage(image, crop: pixels)
    }

    /// The mark for an approved crop, which can differ from the measured page
    /// box when the reader uses a free or A4-locked crop. It is computed on
    /// demand because the preview itself does not need the bitmap.
    public func mark(for crop: CaptureCrop) throws -> PageMark {
        let cropped = try croppedImage(for: crop)
        return PageMark(
            imageHash: ImageFingerprint.detailHash(cropped), text: text)
    }
}

/// Decides when the open preview is stale. It deliberately ignores a window
/// that only moved: the crop is window-local, so the captured page is still
/// valid. A resize, a different book, or different page content needs a new
/// capture.
public enum PagePreviewFollower {
    public static func needsRefresh(
        preview: PagePreview, live: LivePage
    ) -> Bool {
        guard live.isReading, let window = PageFrame.rect(live.windowFrame)
        else { return false }
        if !PageFrame.sameSize(
            window.size, preview.windowFrame.size, tolerance: 4)
        {
            return true
        }
        if preview.text != live.text { return true }
        // A baseline captured before Kindle exposed a page number would
        // otherwise accept every later number through sameWhenKnown.
        if preview.pageNumber == nil, live.pageNumber != nil { return true }
        if preview.pageCount == nil, live.pageCount != nil { return true }
        if !LivePage.sameWhenKnown(preview.pageNumber, live.pageNumber) {
            return true
        }
        if !LivePage.sameWhenKnown(preview.pageCount, live.pageCount) {
            return true
        }
        return !preview.identity.matches(live)
    }

    /// Image-only pages have no AX text or page number to compare. The
    /// caller should capture at a slower cadence as a visual probe.
    public static func needsImageProbe(live: LivePage) -> Bool {
        live.isReading && live.pageNumber == nil
            && live.text.count < PageGeometry.minimumTextCharacters
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

    private let captureService: any WindowCapturing
    private let read: Read
    private let allowTextBoundsFallback: Bool

    public init(
        capture: any WindowCapturing = WindowCaptureService(),
        read: @escaping Read = { try KindleLive.currentPage() },
        allowTextBoundsFallback: Bool = false
    ) {
        self.captureService = capture
        self.read = read
        self.allowTextBoundsFallback = allowTextBoundsFallback
    }

    public func preview() throws -> PagePreview {
        let before = try read()
        let geometry: LivePageGeometry
        do {
            geometry = try PageGeometry.measure(
                before,
                allowTextBoundsFallback: allowTextBoundsFallback)
        } catch let error as PageGeometryError {
            switch error {
            case .notReading(let state):
                throw PagePreviewError.notReading(state)
            case .noWindow:
                throw PagePreviewError.noWindow
            case .tooSmall, .refused:
                throw PagePreviewError.geometryUnavailable("\(error)")
            }
        }
        let window = geometry.window
        let pageBox = geometry.pageBox
        let captured: CapturedWindow
        do {
            captured = try captureService.capture(
                expectedFrame: window, isCancelled: { false })
        } catch {
            throw PagePreviewError.capture("\(error)")
        }
        let after = try read()
        guard after.sameContent(as: before) else {
            throw PagePreviewError.pageChanged
        }
        guard PageFrame.sameRect(
            captured.windowFrame, window, tolerance: 4)
        else {
            throw PagePreviewError.pageChanged
        }
        let crop = CaptureCrop(
            rect: pageBox.offsetBy(
                dx: -captured.windowFrame.minX,
                dy: -captured.windowFrame.minY))
        do {
            _ = try CropTransform.pixelRect(
                crop: crop, windowFrame: captured.windowFrame,
                contentRect: captured.contentRect,
                imageSize: CGSize(
                    width: captured.image.width,
                    height: captured.image.height))
        } catch {
            throw PagePreviewError.geometryUnavailable("\(error)")
        }
        let identity = ObservedIdentity(page: before)
        return PagePreview(
            image: captured.image,
            windowFrame: captured.windowFrame,
            contentRect: captured.contentRect,
            pageBox: pageBox,
            crop: crop,
            identity: identity,
            text: before.text,
            pageNumber: before.pageNumber,
            pageCount: before.pageCount,
            live: after,
            pageBoxNote: geometry.pageBoxNote)
    }
}
