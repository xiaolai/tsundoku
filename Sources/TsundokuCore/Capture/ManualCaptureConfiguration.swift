import CoreGraphics
import Foundation

/// The binding between a reviewed preview and the capture that follows it.
/// The crop is window-local; the expected frame is only a size check because
/// a same-display move is harmless with a window-local crop.
public struct ManualCaptureConfiguration: Sendable, Equatable {
    public let crop: CaptureCrop
    public let expectedWindow: CGRect
    /// The mark of the page the reader approved. The first capture refuses a
    /// different page instead of silently starting somewhere else.
    public let expectedMark: PageMark?
    public let expectedPageNumber: Int?
    /// A resumed run starts on the last page already stored, so a mark
    /// mismatch means the reader is not showing that page, not that the page
    /// moved since a preview.
    public let isResume: Bool

    public init(
        crop: CaptureCrop, expectedWindow: CGRect,
        expectedMark: PageMark? = nil, expectedPageNumber: Int? = nil,
        isResume: Bool = false
    ) {
        self.crop = crop
        self.expectedWindow = expectedWindow
        self.expectedMark = expectedMark
        self.expectedPageNumber = expectedPageNumber
        self.isResume = isResume
    }
}
