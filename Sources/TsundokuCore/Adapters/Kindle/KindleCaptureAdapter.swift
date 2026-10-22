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
        try makeSession(
            for: subject, cancellation: cancellation, pageSetup: nil)
    }

    public func makeSession(
        for subject: CaptureSubject,
        cancellation: any CancellationChecking,
        pageSetup: PageSetupRequest?
    ) throws -> any ReaderCaptureSession {
        var setupGuard: KindlePageSetup?
        if let pageSetup, pageSetup.isRequested {
            let setup = KindlePageSetup(request: pageSetup)
            do {
                try setup.begin()
            } catch {
                throw ReaderCaptureError.captureFailed(
                    .kindle, reason: "page setup: \(error)")
            }
            setupGuard = setup
        }
        do {
            return try KindleCaptureSession(
                subject: subject, cancellation: cancellation,
                isFrontmost: KindleLive.isFrontmost,
                pageSetupGuard: setupGuard,
                cropTop: pageSetup?.cropTop ?? 0,
                cropBottom: pageSetup?.cropBottom)
        } catch {
            // The session did not start; put the reader back before the
            // caller sees the failure.
            _ = setupGuard?.restore()
            throw error
        }
    }
}
