import Foundation

/// What the capture bundle writes beyond the PDF. Both toggles default on;
/// copying the original is an explicit opt-in.
public struct CaptureBundleOptions: Sendable, Equatable {
    public var includeCoverPage: Bool
    public var writeSidecars: Bool
    public var copyOriginal: Bool
    /// The cover page size in points. `nil` uses the captured page size.
    public var pageSize: CGSize?

    public init(
        includeCoverPage: Bool = true,
        writeSidecars: Bool = true,
        copyOriginal: Bool = false,
        pageSize: CGSize? = nil
    ) {
        self.includeCoverPage = includeCoverPage
        self.writeSidecars = writeSidecars
        self.copyOriginal = copyOriginal
        self.pageSize = pageSize
    }

    public static let defaults = CaptureBundleOptions()
}

public struct CaptureBundleServices: Sendable {
    public let metadataResolver: BookMetadataResolver
    public let coverService: BookCoverService

    public init(
        metadataResolver: BookMetadataResolver,
        coverService: BookCoverService
    ) {
        self.metadataResolver = metadataResolver
        self.coverService = coverService
    }

    public static func standard() -> CaptureBundleServices {
        CaptureBundleServices(
            metadataResolver: BookMetadataResolver(
                kindlePaths: .standard(),
                booksAssets: BooksAssetReader()),
            coverService: BookCoverService())
    }
}

public struct CaptureBundleRequest: Sendable {
    public let options: CaptureBundleOptions
    public let services: CaptureBundleServices
    public let now: @Sendable () -> Date

    public init(
        options: CaptureBundleOptions = .defaults,
        services: CaptureBundleServices = .standard(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.options = options
        self.services = services
        self.now = now
    }
}

/// The state resolved before publication. `finish` writes the post-publication
/// files and returns warnings; none of them fail the capture.
public struct ExportBundlePlan: Sendable {
    public let metadata: BookMetadata
    public let cover: ResolvedCover?
    public let original: OriginalAvailability?
    public let coverPage: PDFCoverPage?
    public let options: CaptureBundleOptions
    public var warnings: [String]

    public init(
        metadata: BookMetadata,
        cover: ResolvedCover?,
        original: OriginalAvailability?,
        coverPage: PDFCoverPage?,
        options: CaptureBundleOptions,
        warnings: [String]
    ) {
        self.metadata = metadata
        self.cover = cover
        self.original = original
        self.coverPage = coverPage
        self.options = options
        self.warnings = warnings
    }
}

public enum ExportBundle {
    /// Resolve metadata and the cover, and build the cover page. Runs after
    /// the pages are captured and before the PDF is published, because the
    /// cover page is part of the PDF.
    public static func prepare(
        directory: URL, book: Book?, capturedTitle: String,
        identifier: String?, source: BookSource, capturedPages: Int,
        options: CaptureBundleOptions, services: CaptureBundleServices,
        now: Date
    ) -> ExportBundlePlan {
        var warnings: [String] = []
        let metadata = services.metadataResolver.resolve(
            book: book, capturedTitle: capturedTitle,
            identifier: identifier, source: source)
        warnings.append(contentsOf: metadata.warnings)
        var cover: ResolvedCover?
        if options.includeCoverPage || options.writeSidecars {
            let resolution = services.coverService.resolve(
                for: metadata, into: directory)
            warnings.append(contentsOf: resolution.warnings)
            cover = resolution.cover
        }
        let original = metadata.original
        var coverPage: PDFCoverPage?
        if options.includeCoverPage, let cover {
            coverPage = PDFCoverPage(
                title: metadata.title ?? capturedTitle,
                author: metadata.author,
                identifier: metadata.identifier,
                source: source.captureSource,
                exportDate: now,
                capturedPages: capturedPages,
                coverImageURL: cover.fileURL,
                textDisclosure: nil,
                pageSize: options.pageSize)
        } else if options.includeCoverPage {
            warnings.append(
                "The cover page was skipped because no cover image was "
                    + "available.")
        }
        return ExportBundlePlan(
            metadata: metadata, cover: cover, original: original,
            coverPage: coverPage, options: options, warnings: warnings)
    }

    /// Write `metadata.json`, `text.md`, the per-page text files and, when
    /// requested, the original. Every failure becomes a warning in the
    /// manifest; the PDF and the capture stay valid.
    @discardableResult
    public static func finish(
        _ plan: ExportBundlePlan, manifest: inout [String: Any],
        directory: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> [String] {
        try checkCancelled(isCancelled)
        var warnings: [String] = []
        manifest["book"] = plan.metadata.manifest
        var coverObject: [String: Any]?
        if let cover = plan.cover {
            let object: [String: Any] = [
                "source": cover.source.rawValue,
                "file": cover.fileURL.lastPathComponent,
                "mediaType": cover.mediaType,
                "bytes": cover.byteCount,
            ]
            manifest["cover"] = object
            coverObject = object
        }
        let coverPage = plan.coverPage != nil
        manifest["coverPage"] = coverPage
        manifest["pageOffset"] = coverPage ? 1 : 0

        var originalObject = plan.original?.manifest
        if plan.options.copyOriginal {
            if let original = plan.original, original.isAvailable,
                let kind = original.kind
            {
                do {
                    let reserved = [
                        manifest["pdf"] as? String,
                        "cover.jpg", "metadata.json", "original.json",
                        "manifest.json", "text.jsonl", "text.md",
                    ].compactMap { $0 }
                    let copied = try OriginalService.copy(
                        original, into: directory,
                        destinationName: OriginalService.destinationName(
                            for: kind, in: directory,
                            reserving: reserved),
                        isCancelled: isCancelled)
                    originalObject?["copiedTo"] =
                        copied.url.lastPathComponent
                    originalObject?["copiedBytes"] = copied.bytes
                } catch is CancellationError {
                    // A stop requested during finalization must abort the
                    // capture, not become a warning over a reported success.
                    throw CancellationError()
                } catch {
                    if let copyError = error as? OriginalCopyError,
                        case .protected(let reason) = copyError
                    {
                        originalObject =
                            OriginalAvailability.protected(
                                reason: reason).manifest
                    }
                    warnings.append(
                        "The original was not copied: \(error)")
                }
            } else {
                warnings.append(
                    "No DRM-free original was available to copy.")
            }
        }
        if let originalObject {
            manifest["original"] = originalObject
        }

        try checkCancelled(isCancelled)
        var textObject: [String: Any]?
        if plan.options.writeSidecars {
            do {
                let pages = try TextSidecars.load(from: directory)
                let summary = try TextSidecars.write(
                    pages: pages, to: directory)
                textObject = summary.manifest
                manifest["text"] = textObject
            } catch {
                warnings.append(
                    "The text sidecars were not written: \(error)")
            }
            do {
                try writeOriginalJSON(
                    originalObject
                        ?? ["available": false, "missing": true],
                    directory: directory)
            } catch {
                warnings.append(
                    "original.json was not written: \(error)")
            }
            do {
                try writeMetadataJSON(
                    plan, manifest: manifest, cover: coverObject,
                    original: originalObject, text: textObject,
                    directory: directory)
            } catch {
                warnings.append(
                    "metadata.json was not written: \(error)")
            }
        }
        return warnings
    }

    private static func checkCancelled(
        _ isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
    }

    private static func writeOriginalJSON(
        _ object: [String: Any], directory: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: directory.appendingPathComponent("original.json"),
            options: .atomic)
    }

    private static func writeMetadataJSON(
        _ plan: ExportBundlePlan, manifest: [String: Any],
        cover: [String: Any]?, original: [String: Any]?,
        text: [String: Any]?, directory: URL
    ) throws {
        var record: [String: Any] = [
            "version": 1,
            "book": plan.metadata.manifest,
            "capture": [
                "title": manifest["title"] ?? NSNull(),
                "source": manifest["source"] ?? NSNull(),
                "termination": manifest["termination"] ?? NSNull(),
                "state": manifest["state"] ?? NSNull(),
                "pageCount": manifest["pageCount"] ?? NSNull(),
                "pdfPages": manifest["pdfPages"] ?? NSNull(),
                "coverPage": manifest["coverPage"] ?? false,
                "pageOffset": manifest["pageOffset"] ?? 0,
            ],
        ]
        if let cover { record["cover"] = cover }
        if let original { record["original"] = original }
        if let text { record["text"] = text }
        if let identifier = plan.metadata.identifier,
            !identifier.isEmpty
        {
            record["identifier"] = identifier
        }
        let data = try JSONSerialization.data(
            withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: directory.appendingPathComponent("metadata.json"),
            options: .atomic)
    }
}
