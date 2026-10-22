import Foundation

public struct CaptureProgress: Sendable {
    public let page: Int
    public let pageLimit: Int?
    public let message: String

    public var fraction: Double {
        guard let pageLimit, pageLimit > 0 else { return 0 }
        return min(1, Double(page) / Double(pageLimit))
    }

    public init(page: Int, pageLimit: Int?, message: String) {
        self.page = page
        self.pageLimit = pageLimit
        self.message = message
    }
}

public struct CaptureResult: Sendable {
    public let directory: URL
    public let pdf: URL
    public let pages: Int
    public let title: String
    public let cleanPage: CleanPageSummary?
    public let pageSetup: PageSetupOutcome?

    public init(
        directory: URL, pdf: URL, pages: Int, title: String,
        cleanPage: CleanPageSummary? = nil,
        pageSetup: PageSetupOutcome? = nil
    ) {
        self.directory = directory
        self.pdf = pdf
        self.pages = pages
        self.title = title
        self.cleanPage = cleanPage
        self.pageSetup = pageSetup
    }
}

/// Compatibility facade for the app and CLI. The reader-specific work lives in
/// `KindleCaptureAdapter`; the job loop lives in `CaptureJobEngine`.
public final class CaptureEngine: Sendable {
    private let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    public func capture(
        book: Book?,
        kind: ReaderKind = .kindle,
        pageLimit: Int?,
        output: URL,
        progress: @Sendable (CaptureProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool,
        cleanPage: CleanPagePolicy = .asDisplayed,
        pageSetup: PageSetupRequest = PageSetupRequest(),
        bundle: CaptureBundleRequest? = nil
    ) throws -> CaptureResult {
        let subject = CaptureSubject(book: book, kind: kind)
        let session: any ReaderCaptureSession
        switch kind {
        case .kindle:
            if pageSetup.booksFontSteps != 0 {
                throw ReaderCaptureError.unsupported(
                    .kindle,
                    reason: "Books text-size steps are Apple Books-only")
            }
            session = try KindleCaptureAdapter().makeSession(
                for: subject,
                cancellation: ClosureCancellation(isCancelled),
                pageSetup: pageSetup)
        case .appleBooks:
            session = try BooksCaptureAdapter().makeSession(
                for: subject,
                cancellation: ClosureCancellation(isCancelled),
                pageSetup: pageSetup)
        }
        let outputPageSize: CGSize? =
            kind == .appleBooks ? pageSetup.pageSize.points : nil
        let cleanRequest: CleanPageRequest?
        switch kind {
        case .kindle:
            cleanRequest = CleanPageRequest(
                policy: cleanPage, panel: KindlePopularHighlights())
        case .appleBooks:
            if cleanPage.hidesPopularHighlights {
                throw ReaderCaptureError.unsupported(
                    .appleBooks,
                    reason: "Popular Highlights cleanup is Kindle-only")
            }
            cleanRequest = nil
        }
        return try CaptureJobEngine(archive: archive).run(
            session: session, subject: subject, pageLimit: pageLimit,
            output: output, progress: progress, isCancelled: isCancelled,
            cleanPage: cleanRequest,
            bundle: bundle,
            outputPageSize: outputPageSize)
    }
}
