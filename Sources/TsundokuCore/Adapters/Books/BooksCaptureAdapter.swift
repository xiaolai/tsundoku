import Foundation

public struct BooksCaptureAdapter: ReaderCaptureAdapter {
    public let kind: ReaderKind = .appleBooks

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
        if let pageSetup, pageSetup.font != nil {
            throw ReaderCaptureError.unsupported(
                .appleBooks, reason: "font setup is Kindle-only")
        }
        var setupGuard: BooksPageSetup?
        if let pageSetup, pageSetup.isRequested {
            let setup = BooksPageSetup(request: pageSetup)
            do {
                _ = try setup.begin()
            } catch {
                _ = setup.restore()
                throw ReaderCaptureError.captureFailed(
                    .appleBooks, reason: "page setup: \(error)")
            }
            setupGuard = setup
        }
        do {
            return try BooksCaptureSession(
                subject: subject, cancellation: cancellation,
                pageSetupGuard: setupGuard)
        } catch {
            _ = setupGuard?.restore()
            throw error
        }
    }
}
