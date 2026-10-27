import CoreGraphics
import Foundation

public struct LivePageGeometry: Sendable {
    public let window: CGRect
    public let calibration: PageFrameCalibration
    public let pageBox: CGRect
    /// Set when the box is a text-bounds fallback rather than a clean
    /// chrome measurement. The reader can adjust the crop.
    public let pageBoxNote: String?

    public init(
        window: CGRect, calibration: PageFrameCalibration,
        pageBox: CGRect, pageBoxNote: String? = nil
    ) {
        self.window = window
        self.calibration = calibration
        self.pageBox = pageBox
        self.pageBoxNote = pageBoxNote
    }
}

public enum PageGeometryError: Error, CustomStringConvertible, Sendable {
    case notReading(String)
    case noWindow
    case tooSmall
    case refused(String)

    public var description: String {
        switch self {
        case .notReading(let state):
            "Kindle is not showing a reading page (\(state))."
        case .noWindow:
            "Kindle's reading window is not available."
        case .tooSmall:
            "The measured page box is too small."
        case .refused(let reason):
            "The page box could not be measured: \(reason)"
        }
    }
}

/// The one measurement path used by preview and optional A4 fit.
public enum PageGeometry {
    /// Below this many AX characters the frame is an image, not a text
    /// column; using it as text headroom rejects the page box.
    public static let minimumTextCharacters = 20

    /// `allowTextBoundsFallback` is for the manual preview/A4 flow, where the
    /// reader reviews and edits the crop. Automatic quick capture leaves it
    /// false so a refused chrome measurement cannot become a screenshot that
    /// includes the chrome.
    public static func measure(
        _ live: LivePage, allowTextBoundsFallback: Bool = false
    ) throws -> LivePageGeometry {
        guard live.isReading else {
            throw PageGeometryError.notReading(live.state)
        }
        guard let window = PageFrame.rect(live.windowFrame) else {
            throw PageGeometryError.noWindow
        }
        let textFrame = PageFrame.rect(live.pageTextFrame)
        let measuredText =
            live.text.count < minimumTextCharacters ? nil : textFrame
        var calibration = PageFrame.resolve(
            window: window, text: measuredText, chrome: live.chromeInsets)
        var pageBoxNote: String?
        // This path feeds a suggestion the reader can adjust, not an
        // automatic crop. If chrome needs a margin the text does not leave,
        // fall back to the text bounds; refusing here would block preview
        // and A4 fit even though the reader can resolve the conflict by
        // editing the crop.
        if allowTextBoundsFallback, calibration.status == .refused,
            let measuredText
        {
            let headroom = PageFrame.textHeadroom(
                window: window, text: measuredText)
            let insets = CaptureInsets(
                top: max(0, headroom.top),
                bottom: max(0, headroom.bottom),
                left: max(0, headroom.left), right: max(0, headroom.right))
            calibration = PageFrameCalibration(
                insets: insets, status: .derived,
                reason: "chrome and text disagree; using the text bounds",
                chrome: calibration.chrome, headroom: headroom)
            pageBoxNote =
                "Kindle's chrome and text margins disagree; the page box "
                + "uses the text bounds. Adjust the crop if needed."
        }
        guard calibration.status != .refused else {
            throw PageGeometryError.refused(
                calibration.reason ?? "the page box was refused")
        }
        let pageBox = PageFrame.pageRect(
            window: window, insets: calibration.insets)
        guard pageBox.width > 100, pageBox.height > 100 else {
            throw PageGeometryError.tooSmall
        }
        return LivePageGeometry(
            window: window, calibration: calibration, pageBox: pageBox,
            pageBoxNote: pageBoxNote)
    }
}
