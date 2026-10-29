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
///   for the rows the reader actually scrolls past, two at a time; the answer
///   is written back under the export key so an export reuses it.
///
/// Nothing here blocks a row: the spine is drawn first and the artwork
/// replaces it when it arrives.
public actor BookCoverStore {
    /// What a fetch amounts to. The three cases are not the same answer, and
    /// only one of them is final.
    public enum FetchOutcome: Sendable {
        case data(Data)
        /// The service says there is no cover. Final.
        case absent
        /// Offline, timed out, or a server error. Worth trying again later.
        case failed
    }

    public static let shared = BookCoverStore()

    /// How many books may be resolved at once. The list asks for every
    /// visible row as it scrolls; without a cap, a fast scroll would open a
    /// connection per book.
    /// Permits handed out and not yet returned.
    private var permits: Int
    /// Callers waiting for a permit, oldest first. A permit is *transferred*
    /// to the first waiter on release, never returned to the pool and taken
    /// again, so a new caller cannot overtake a queued one.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private let cacheDirectory: URL
    private let booksPaths: BooksPaths
    private let maximumPixels: Int
    private let fetch: @Sendable (URL) async -> FetchOutcome

    /// One resolution per book at a time: two rows asking for the same book
    /// while the first is in flight share its answer. The work runs in the
    /// *first caller's* task — an unstructured `Task` would keep downloading
    /// after that row scrolled away, holding a permit the queue is waiting on.
    private var waiters: [String: [CheckedContinuation<CGImage?, Never>]] = [:]

    /// Confirmed absences only. A timeout is not an absence, and remembering
    /// one would leave a book without its cover for the rest of the session
    /// because the network blinked.
    private var absent: Set<String> = []

    private var memory = NSCache<NSString, CoverImage>()

    private final class CoverImage {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    public init(
        cacheDirectory: URL = BookCoverService.standardCacheDirectory,
        booksPaths: BooksPaths = .standard(),
        timeout: TimeInterval = 6,
        maximumPixels: Int = 1_600,
        parallelism: Int = 2,
        // Injected so a test can answer without a network, and so the source
        // can change without touching the store's logic.
        fetch: (@Sendable (URL) async -> FetchOutcome)? = nil
    ) {
        self.cacheDirectory = cacheDirectory
        self.booksPaths = booksPaths
        self.maximumPixels = maximumPixels
        self.permits = max(1, parallelism)
        if let fetch {
            self.fetch = fetch
        } else {
            self.fetch = { url in
                await Self.download(url, timeout: timeout, byteLimit: 8 << 20)
            }
        }
        // Four hundred decoded covers would be tens of megabytes; a bounded
        // cache keeps the rows the reader is near and lets the rest go.
        memory.countLimit = 150
    }

    /// The cover for a book at thumbnail size, or nil when it has none that
    /// can be reached.
    public func thumbnail(for book: Book) async -> CGImage? {
        guard !book.asin.isEmpty else { return nil }
        let key = Self.cacheKey(for: book)
        if let image = memory.object(forKey: key as NSString)?.image {
            return image
        }
        if absent.contains(key) { return nil }
        if waiters[key] != nil {
            // Someone is already resolving this book; take their answer.
            return await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }
        waiters[key] = []
        let image = await load(book, key: key)
        let pending = waiters.removeValue(forKey: key) ?? []
        for waiter in pending { waiter.resume(returning: image) }
        return image
    }

    /// Source-qualified, because an ASIN and a Books asset id can coincide and
    /// must not share artwork.
    static func cacheKey(for book: Book) -> String {
        BookCoverService.cacheKey(for: book.asin, source: book.source)
    }

    // MARK: Resolution

    private func load(_ book: Book, key: String) async -> CGImage? {
        if let image = memory.object(forKey: key as NSString)?.image {
            return image
        }
        if absent.contains(key) { return nil }
        await acquire()
        defer { release() }
        // A row that scrolled away while queued does no work.
        guard !Task.isCancelled else { return nil }
        if let image = readDisk(key) { return image }
        switch book.source {
        case .appleBooks:
            guard
                let url = BooksCover.coverURL(
                    for: book.asin, paths: booksPaths)
            else {
                // A Books asset that is not downloaded yet may arrive; that
                // is not an absence.
                return nil
            }
            // The image is thumbnailed straight from its bytes: going through
            // NSImage would decode the full-size cover first.
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard
                let image = Self.thumbnail(
                    from: data, maximumPixels: maximumPixels)
            else {
                absent.insert(key)
                return nil
            }
            memory.setObject(CoverImage(image), forKey: key as NSString)
            return image
        case .kindle:
            for url in BookCoverService.kindleURLs(
                physicalID: nil, asin: book.asin)
            {
                if Task.isCancelled { return nil }
                switch await fetch(url) {
                case .failed:
                    // Temporary: forget it happened and try on a later scroll.
                    return nil
                case .absent:
                    continue
                case .data(let data):
                    guard
                        let image = Self.thumbnail(
                            from: data, maximumPixels: maximumPixels)
                    else {
                        // A 200 that is not an image is usually an error page
                        // or a captive portal, not a final answer: do not
                        // remember it.
                        return nil
                    }
                    writeDisk(data, key: key)
                    memory.setObject(
                        CoverImage(image), forKey: key as NSString)
                    return image
                }
            }
            absent.insert(key)
            return nil
        }
    }

    private func readDisk(_ key: String) -> CGImage? {
        let url = cacheDirectory.appendingPathComponent(key + ".jpg")
        guard let data = try? Data(contentsOf: url),
            let image = Self.thumbnail(
                from: data, maximumPixels: maximumPixels)
        else { return nil }
        memory.setObject(CoverImage(image), forKey: key as NSString)
        return image
    }

    private func writeDisk(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(
            to: cacheDirectory.appendingPathComponent(key + ".jpg"),
            options: .atomic)
    }

    // MARK: Limiting

    /// Takes a permit, or waits for one.
    ///
    /// A caller that is cancelled while queued still receives its permit, and
    /// returns it immediately in `load` — one turn of the queue, not a slot
    /// held for the length of a download. Removing a waiter's continuation on
    /// cancellation was the alternative, but a cancel that races a grant
    /// either leaks a permit or resets the count under a live caller; keeping
    /// the accounting trivial is worth one turn.
    private func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
        // A permit was transferred by `release`; nothing to increment.
    }

    private func release() {
        if !waiting.isEmpty {
            waiting.removeFirst().resume()
            return
        }
        permits += 1
    }

    // MARK: Network

    /// Streams the body and stops at the limit: checking the size after
    /// `data(for:)` has already buffered the whole response bounds nothing.
    static func download(
        _ url: URL, timeout: TimeInterval, byteLimit: Int
    ) async -> FetchOutcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (bytes, response) = try await URLSession.shared.bytes(
                for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed
            }
            if http.statusCode == 404 || http.statusCode == 403 {
                return .absent
            }
            guard http.statusCode == 200 else { return .failed }
            if http.expectedContentLength > Int64(byteLimit) {
                return .absent
            }
            var data = Data()
            data.reserveCapacity(
                min(byteLimit, max(0, Int(http.expectedContentLength))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteLimit { return .absent }
            }
            return .data(data)
        } catch {
            return .failed
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
}

/// Where an Apple Books cover lives on disk.
private enum BooksCover {
    static func coverURL(for asin: String, paths: BooksPaths) -> URL? {
        guard
            let asset = try? BooksAssetReader(paths: paths).asset(for: asin),
            let package = asset.package
        else { return nil }
        return package.coverImageURL
    }
}
