import Foundation

/// Where a metadata field came from. The manifest records one entry per field
/// so a caller can tell a store value from a parsed OPF value.
public enum MetadataSource: String, Codable, CaseIterable, Sendable {
    case archive
    case booksLibrary = "books-library"
    case epubOPF = "epub-opf"
    case kindleMetadataCache = "kindle-metadata-cache"
    case localFiles = "local-files"
    case observed
    case generated
}

/// A cover that is not yet a local image file. The cover service turns one of
/// these into `cover.jpg` (or a generated fallback).
public enum CoverReference: Sendable, Equatable {
    case kindlePhysicalId(String)
    case kindleASIN(String)
    case epubImage(URL)
    case pdfPage(URL)
    case generated
}

/// The book identity carried into a capture bundle. Every field is optional;
/// an absent field is simply omitted from the manifest, never invented.
public struct BookMetadata: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var identifier: String?
    public var source: BookSource?
    public var language: String?
    public var publisher: String?
    public var publishedDate: String?
    public var cover: CoverReference?
    public var original: OriginalAvailability?
    public private(set) var sources: [String: MetadataSource]
    public var warnings: [String]

    public init(
        title: String? = nil,
        author: String? = nil,
        identifier: String? = nil,
        source: BookSource? = nil,
        language: String? = nil,
        publisher: String? = nil,
        publishedDate: String? = nil,
        cover: CoverReference? = nil,
        original: OriginalAvailability? = nil,
        sources: [String: MetadataSource] = [:],
        warnings: [String] = []
    ) {
        self.title = title
        self.author = author
        self.identifier = identifier
        self.source = source
        self.language = language
        self.publisher = publisher
        self.publishedDate = publishedDate
        self.cover = cover
        self.original = original
        self.sources = sources
        self.warnings = warnings
    }

    public mutating func setTitle(_ value: String?, from source: MetadataSource) {
        guard let value, !value.isEmpty else { return }
        title = value
        sources["title"] = source
    }

    public mutating func setAuthor(_ value: String?, from source: MetadataSource) {
        guard let value, !value.isEmpty else { return }
        author = value
        sources["author"] = source
    }

    public mutating func setIdentifier(
        _ value: String?, from source: MetadataSource
    ) {
        guard let value, !value.isEmpty else { return }
        identifier = value
        sources["identifier"] = source
    }

    public mutating func setLanguage(
        _ value: String?, from source: MetadataSource
    ) {
        guard let value, !value.isEmpty else { return }
        language = value
        sources["language"] = source
    }

    public mutating func setPublisher(
        _ value: String?, from source: MetadataSource
    ) {
        guard let value, !value.isEmpty else { return }
        publisher = value
        sources["publisher"] = source
    }

    public mutating func setPublishedDate(
        _ value: String?, from source: MetadataSource
    ) {
        guard let value, !value.isEmpty else { return }
        publishedDate = value
        sources["publishedDate"] = source
    }

    public mutating func setCover(
        _ value: CoverReference?, from source: MetadataSource
    ) {
        guard let value else { return }
        cover = value
        sources["cover"] = source
    }

    public mutating func setOriginal(
        _ value: OriginalAvailability?, from source: MetadataSource
    ) {
        guard let value else { return }
        original = value
        sources["original"] = source
    }

    /// The `book` object in the capture manifest. Empty optional fields are
    /// omitted rather than serialised as nulls.
    public var manifest: [String: Any] {
        var object: [String: Any] = [:]
        if let title, !title.isEmpty { object["title"] = title }
        if let author, !author.isEmpty { object["author"] = author }
        if let identifier, !identifier.isEmpty {
            object["identifier"] = identifier
            // The plan's manifest shape names the Kindle identifier `asin`.
            // A Books asset id is not an ASIN, so it stays under `identifier`.
            if source == .kindle { object["asin"] = identifier }
        }
        if let source { object["source"] = source.captureSource }
        if let language, !language.isEmpty { object["language"] = language }
        if let publisher, !publisher.isEmpty {
            object["publisher"] = publisher
        }
        if let publishedDate, !publishedDate.isEmpty {
            object["publishedDate"] = publishedDate
        }
        if !sources.isEmpty {
            object["sources"] = sources.mapValues(\.rawValue)
        }
        return object
    }
}

public extension BookSource {
    /// The value used in capture manifests and the archive's `captures.source`
    /// column.
    var captureSource: String {
        switch self {
        case .kindle: "kindle"
        case .appleBooks: "applebooks"
        }
    }
}
