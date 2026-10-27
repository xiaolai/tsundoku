import Foundation

public struct CaptureMetadata: Sendable {
    public let title: String
    public let author: String?
    public let identifier: String?
    public let source: String
    public let displayScale: Double

    public init(
        title: String, author: String?, identifier: String?,
        source: String, displayScale: Double = 1
    ) {
        self.title = title
        self.author = author
        self.identifier = identifier
        self.source = source
        self.displayScale = displayScale
    }
}

public struct CaptureArtifact: Sendable {
    public let directory: URL
    public let pageURLs: [URL]
    public let texts: [String]
    public let metadata: CaptureMetadata
    public let termination: Termination
    public let cancellation: any CancellationChecking
    public let coverPage: PDFCoverPage?
    /// The PDF page size in points. `nil` uses each captured page's size.
    public let pageSize: CGSize?

    public init(
        directory: URL, pageURLs: [URL], texts: [String],
        metadata: CaptureMetadata, termination: Termination,
        cancellation: any CancellationChecking =
            ClosureCancellation({ false }),
        coverPage: PDFCoverPage? = nil,
        pageSize: CGSize? = nil
    ) {
        self.directory = directory
        self.pageURLs = pageURLs
        self.texts = texts
        self.metadata = metadata
        self.termination = termination
        self.cancellation = cancellation
        self.coverPage = coverPage
        self.pageSize = pageSize
    }
}

public struct PublishedCapture: Sendable {
    public let url: URL
    public let pageCount: Int
    /// Non-fatal issues the publisher worked around, such as a page whose
    /// text layer could not hold all of its text. They go into the capture's
    /// manifest so the reader can see them.
    public let warnings: [String]

    public init(url: URL, pageCount: Int, warnings: [String] = []) {
        self.url = url
        self.pageCount = pageCount
        self.warnings = warnings
    }
}

public protocol CapturePublisher: Sendable {
    func publish(_ artifact: CaptureArtifact) throws -> PublishedCapture
}

public enum CapturePublisherError: Error, CustomStringConvertible, Sendable {
    case noPages
    case failed(String)

    public var description: String {
        switch self {
        case .noPages: "The capture has no pages to publish."
        case .failed(let reason): "Publication failed: \(reason)"
        }
    }
}
