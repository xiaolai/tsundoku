import Foundation

public struct KindleCaptureAdapter: ReaderCaptureAdapter {
    public let kind: ReaderKind = .kindle

    public init() {}

    public func capabilities(for subject: CaptureSubject)
        -> CaptureCapabilities
    {
        CaptureCapabilities(
            paginatedNavigation: true, endOfBookDetection: true,
            textLayer: true, ocrFallback: false)
    }

    public func makeSession(
        for subject: CaptureSubject,
        cancellation: any CancellationChecking
    ) throws -> any ReaderCaptureSession {
        try KindleCaptureSession(
            subject: subject, cancellation: cancellation,
            isFrontmost: KindleLive.isFrontmost)
    }
}
