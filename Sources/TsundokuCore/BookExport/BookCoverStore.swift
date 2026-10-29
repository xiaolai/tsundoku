import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Book covers for the library, resolved lazily and kept.
///
/// "Whenever possible" has to mean something in a list of four hundred books:
///
/// - A cover already resolved by an export is on disk, under the same key
///   `BookCoverService` writes, and is read without touching the network.
/// - An Apple Books cover is in the reader's own EPUB on disk. That is local
///   and free, so it is read.
/// - A Kindle cover is on Amazon's image CDN. It is fetched once per book,
///   for the rows the reader actually scrolls past, at most `parallelism` at
///   a time; a failure is remembered for the session and the row keeps its
///   spine.
///
/// Nothing here blocks a row: the spine is drawn first and the artwork
/// replaces it when it arrives.
public actor BookCoverStore {
    public static let shared = BookCoverStore()

    /// How many books may be resolved at once. The list asks for every
    /// visible row as it scrolls; without a cap, a fast scroll would open a
    /// connection per book.
    private let parallelism = 2
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private let cacheDirectory: URL
    private let booksPaths: BooksPaths
    private let timeout: TimeInterval
    private let maximumPixels: Int
    /// Injected so a test can answer without a network and so the app can
    /// change the source later without touching the store's logic.
    private let fetch: @Sendable (URL) async -> Data?

    /// A cover that could not be resolved is remembered and is not asked for
    /// again in this session: a missing cover is not a transient error, and
    /// retrying it on every scroll would hammer the CDN.
    private var memory = NSCache<NSString, CoverImage>()
    private var missing: Set<String> = []

    private final class CoverImage {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    public init(
        cacheDirectory: URL = BookCoverService.standardCacheDirectory,
        booksPaths: BooksPaths = .standard(),
        timeout: TimeInterval = 6,
        maximumPixels: Int = 1_600,
        fetch: (@Sendable (URL) async -> Data?)? = nil
    ) {
        self.cacheDirectory = cacheDirectory
        self.booksPaths = booksPaths
        self.timeout = timeout
        self.maximumPixels = maximumPixels
        if let fetch {
            self.fetch = fetch
        } else {
            self.fetch = { url in
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                guard
                    let (data, response) = try? await URLSession.shared.data(
                        for: request),
                    let http = response as? HTTPURLResponse,
                    http.statusCode == 200,
                    data.count <= 8 * 1024 * 1024
                else { return nil }
                return data
            }
        }
        // Four hundred decoded covers would be tens of megabytes; a bounded
        // cache keeps the rows the reader is near and lets the rest go.
        memory.countLimit = 150
    }

    /// The cover for a book at thumbnail size, or nil when it has none that
    /// can be reached.
    public func thumbnail(for book: Book) async -> CGImage? {
        let identifier = book.asin
        guard !identifier.isEmpty else { return nil }
        if let image = memory.object(forKey: identifier as NSString)?.image {
            return image
        }
        if missing.contains(identifier) { return nil }
        await acquire()
        defer { release() }
        // The same book can be asked for by two rows while the first is in
        // flight; the second finds the answer here.
        if let image = memory.object(forKey: identifier as NSString)?.image {
            return image
        }
        if missing.contains(identifier) { return nil }
        if let image = await resolve(book) {
            memory.setObject(CoverImage(image), forKey: identifier as NSString)
            return image
        }
        missing.insert(identifier)
        return nil
    }

    /// Answers already in memory. Reading the disk is `thumbnail(for:)`'s job;
    /// this exists so a row that appears again paints immediately.
    public func cachedImage(for identifier: String) -> CGImage? {
        memory.object(forKey: identifier as NSString)?.image
    }

    // MARK: Resolution

    private func resolve(_ book: Book) async -> CGImage? {
        let key = BookCoverService.cacheKey(
            for: book.asin, source: book.source)
        let onDisk = cacheDirectory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: onDisk),
            let image = Self.thumbnail(from: data, maximumPixels: maximumPixels)
        {
            return image
        }
        switch book.source {
        case .appleBooks:
            return BooksCover.image(for: book.asin, paths: booksPaths)
                .flatMap { Self.thumbnail($0, maximumPixels: maximumPixels) }
        case .kindle:
            guard let data = await download(book.asin) else { return nil }
            // Keep it under the export pipeline's key, so an export of this
            // book reuses the download instead of repeating it.
            try? FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: onDisk, options: .atomic)
            return Self.thumbnail(from: data, maximumPixels: maximumPixels)
        }
    }

    private func download(_ asin: String) async -> Data? {
        guard
            let encoded = asin.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed),
            let url = URL(
                string:
                    "https://m.media-amazon.com/images/P/\(encoded)"
                    + ".01.LZZZZZZZ.jpg")
        else { return nil }
        return await fetch(url)
    }

    // MARK: Limiting

    private func acquire() async {
        if inFlight < parallelism {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
        inFlight += 1
    }

    private func release() {
        inFlight -= 1
        if let next = waiting.first {
            waiting.removeFirst()
            next.resume()
        }
    }

    // MARK: Images

    static func thumbnail(from data: Data, maximumPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
    }

    static func thumbnail(_ image: NSImage, maximumPixels: Int) -> CGImage? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let jpeg = rep.representation(using: .jpeg, properties: [:])
        else { return nil }
        return thumbnail(from: jpeg, maximumPixels: maximumPixels)
    }
}

/// The cover inside an Apple Books EPUB.
private enum BooksCover {
    static func image(for asin: String, paths: BooksPaths) -> NSImage? {
        guard
            let asset = try? BooksAssetReader(paths: paths).asset(for: asin),
            let package = asset.package,
            let url = package.coverImageURL
        else { return nil }
        return NSImage(contentsOf: url)
    }
}
