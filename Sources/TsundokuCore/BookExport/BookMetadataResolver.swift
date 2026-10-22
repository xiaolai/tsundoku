import Foundation

/// Merges the archive row, Kindle's metadata cache and an Apple Books asset
/// into one optional-field metadata value. A missing source degrades a field;
/// it never fails the bundle.
public struct BookMetadataResolver: Sendable {
    public let kindlePaths: KindlePaths
    public let booksAssets: (any BooksAssetProviding)?
    public let kindleCache: KindleMetadataCache

    public init(
        kindlePaths: KindlePaths = .standard(),
        booksAssets: (any BooksAssetProviding)? = nil,
        kindleCache: KindleMetadataCache? = nil
    ) {
        self.kindlePaths = kindlePaths
        self.booksAssets = booksAssets
        self.kindleCache =
            kindleCache ?? KindleMetadataCache.load(paths: kindlePaths)
    }

    public func resolve(_ book: Book) -> BookMetadata {
        resolve(
            book: book, capturedTitle: book.title,
            identifier: book.asin.isEmpty ? nil : book.asin,
            source: book.source)
    }

    public func resolve(
        book: Book?, capturedTitle: String, identifier: String?,
        source: BookSource
    ) -> BookMetadata {
        var metadata = BookMetadata(source: source)
        var warnings: [String] = []
        if let book {
            let base: MetadataSource =
                book.source == .appleBooks ? .booksLibrary : .archive
            if book.title != "Untitled" {
                metadata.setTitle(book.title, from: base)
            }
            metadata.setAuthor(book.author, from: base)
            metadata.setIdentifier(book.asin, from: base)
        }
        if metadata.title == nil, !Self.isPlaceholderTitle(capturedTitle) {
            metadata.setTitle(capturedTitle, from: .observed)
        }
        if metadata.identifier == nil {
            metadata.setIdentifier(identifier, from: .observed)
        }
        switch source {
        case .kindle:
            resolveKindle(&metadata)
        case .appleBooks:
            resolveBooks(&metadata, warnings: &warnings)
        }
        metadata.warnings = warnings
        return metadata
    }

    /// The archive uses "Untitled" when the store supplied no title. Treat it
    /// as absent so the kindle metadata cache or the OPF can fill the field.
    private static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Untitled"
            || trimmed == "Kindle book" || trimmed == "Apple Books book"
    }

    private func resolveKindle(_ metadata: inout BookMetadata) {
        let identifier = metadata.identifier ?? ""
        if let entry = kindleCache.entry(for: identifier) {
            if metadata.title == nil {
                metadata.setTitle(
                    entry.title ?? entry.coverAltText,
                    from: .kindleMetadataCache)
            }
            if let physicalID = entry.coverPhysicalID, !physicalID.isEmpty {
                metadata.setCover(
                    .kindlePhysicalId(physicalID),
                    from: .kindleMetadataCache)
            }
        }
        if metadata.cover == nil, !identifier.isEmpty {
            metadata.setCover(.kindleASIN(identifier), from: .archive)
        }
        if metadata.cover == nil {
            metadata.setCover(.generated, from: .generated)
        }
        if identifier.isEmpty {
            metadata.setOriginal(.missing, from: .archive)
        } else {
            metadata.setOriginal(
                OriginalDetector.kindle(asin: identifier, paths: kindlePaths),
                from: .localFiles)
        }
    }

    private func resolveBooks(
        _ metadata: inout BookMetadata, warnings: inout [String]
    ) {
        let identifier = metadata.identifier ?? ""
        guard !identifier.isEmpty else {
            warnings.append(
                "No exact Apple Books identifier; the bundle is unverified.")
            metadata.setOriginal(.missing, from: .booksLibrary)
            metadata.setCover(.generated, from: .generated)
            return
        }
        guard let booksAssets else {
            warnings.append(
                "The Apple Books asset reader was not supplied; the original "
                    + "and cover could not be checked.")
            return
        }
        let asset: BooksAsset?
        do {
            asset = try booksAssets.asset(for: identifier)
        } catch {
            warnings.append("The Apple Books asset could not be read: \(error)")
            metadata.setOriginal(.missing, from: .booksLibrary)
            return
        }
        guard let asset else {
            warnings.append(
                "No Apple Books library row matched \(identifier).")
            metadata.setOriginal(.missing, from: .booksLibrary)
            metadata.setCover(.generated, from: .generated)
            return
        }
        warnings.append(contentsOf: asset.warnings)
        if let package = asset.package {
            if metadata.title == nil {
                metadata.setTitle(package.title, from: .epubOPF)
            }
            if metadata.author == nil, !package.creators.isEmpty {
                metadata.setAuthor(
                    package.creators.joined(separator: ", "),
                    from: .epubOPF)
            }
            metadata.setLanguage(package.language, from: .epubOPF)
            metadata.setPublisher(package.publisher, from: .epubOPF)
            metadata.setPublishedDate(
                package.publishedDate, from: .epubOPF)
            if let cover = package.coverImageURL {
                metadata.setCover(.epubImage(cover), from: .epubOPF)
            }
        }
        if metadata.cover == nil {
            if asset.contentType == .pdf, let path = asset.path,
                asset.pathKind == .file
            {
                metadata.setCover(.pdfPage(path), from: .booksLibrary)
            } else {
                metadata.setCover(.generated, from: .generated)
            }
        }
        metadata.setOriginal(
            OriginalDetector.books(asset: asset), from: .localFiles)
    }
}
