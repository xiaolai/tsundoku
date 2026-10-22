import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ResolvedCover: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case cache
        case download
        case epub
        case pdf
        case generated
    }

    public let fileURL: URL
    public let source: Source
    public let mediaType: String
    public let byteCount: Int

    public init(
        fileURL: URL, source: Source, mediaType: String, byteCount: Int
    ) {
        self.fileURL = fileURL
        self.source = source
        self.mediaType = mediaType
        self.byteCount = byteCount
    }
}

public struct CoverResolution: Sendable {
    public let cover: ResolvedCover?
    public let warnings: [String]

    public init(cover: ResolvedCover?, warnings: [String]) {
        self.cover = cover
        self.warnings = warnings
    }
}

/// Resolves a cover into `<export>/cover.jpg`: cache first, then the Kindle
/// CDN, the unpacked EPUB image, the PDF's first page, and finally a generated
/// typographic cover. No failure here fails the capture.
public struct BookCoverService: Sendable {
    public let cacheDirectory: URL
    public let timeout: TimeInterval
    public let byteLimit: Int
    /// The largest decoded image accepted as a cover. A small compressed file
    /// can still describe an enormous bitmap; a thumbnail is decoded instead.
    public let maximumPixels: Int
    private let fetcher: any CoverDataFetching
    /// Monotonic seconds. A wall-clock adjustment must not enlarge the shared
    /// download deadline.
    private let clock: @Sendable () -> TimeInterval

    public init(
        fetcher: any CoverDataFetching = URLSessionCoverFetcher(),
        cacheDirectory: URL = BookCoverService.standardCacheDirectory,
        timeout: TimeInterval = 10,
        byteLimit: Int = 8 * 1024 * 1024,
        maximumPixels: Int = 40_000_000,
        clock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.fetcher = fetcher
        self.cacheDirectory = cacheDirectory
        self.timeout = timeout
        self.byteLimit = byteLimit
        self.maximumPixels = maximumPixels
        self.clock = clock
    }

    public static var standardCacheDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Tsundoku/Covers")
    }

    public func resolve(
        for metadata: BookMetadata, into directory: URL
    ) -> CoverResolution {
        var warnings: [String] = []
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            return CoverResolution(
                cover: nil,
                warnings: [
                    "The export folder could not be prepared: \(error)"
                ])
        }
        let identifier = metadata.identifier?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let key: String? = {
            guard let identifier, !identifier.isEmpty else { return nil }
            return Self.cacheKey(for: identifier, source: metadata.source)
        }()
        if let key, let cached = cachedCover(key: key, warnings: &warnings)
        {
            do {
                let data = try Data(contentsOf: cached)
                let file = try writeCover(data: data, to: directory)
                return CoverResolution(
                    cover: cover(
                        file: file, source: .cache, data: data,
                        warnings: &warnings),
                    warnings: warnings)
            } catch {
                warnings.append("The cached cover was not usable: \(error)")
                try? FileManager.default.removeItem(at: cached)
            }
        }

        switch metadata.cover ?? .generated {
        case .kindlePhysicalId(let physicalID):
            if let result = download(
                kindleURLs(physicalID: physicalID, asin: identifier),
                cacheKey: key, into: directory,
                warnings: &warnings)
            {
                return CoverResolution(cover: result, warnings: warnings)
            }
        case .kindleASIN(let asin):
            if let result = download(
                kindleURLs(physicalID: nil, asin: asin),
                cacheKey: key, into: directory,
                warnings: &warnings)
            {
                return CoverResolution(cover: result, warnings: warnings)
            }
        case .epubImage(let url):
            if let result = imageFile(
                url, cacheKey: key, into: directory,
                source: .epub, warnings: &warnings)
            {
                return CoverResolution(cover: result, warnings: warnings)
            }
        case .pdfPage(let url):
            if let result = pdfPage(
                url, cacheKey: key, into: directory,
                warnings: &warnings)
            {
                return CoverResolution(cover: result, warnings: warnings)
            }
        case .generated:
            break
        }

        let title = metadata.title ?? "Untitled"
        if let data = GeneratedCover.jpegData(
            title: title, author: metadata.author,
            identifier: metadata.identifier)
        {
            do {
                let file = try writeRawJPEG(data, to: directory)
                // A generated cover is a fallback, not the book's cover. Do
                // not cache it: a later online run must be allowed to fetch
                // the real image instead of trusting the placeholder.
                return CoverResolution(
                    cover: ResolvedCover(
                        fileURL: file, source: .generated,
                        mediaType: UTType.jpeg.identifier,
                        byteCount: byteCount(of: file, fallback: data.count)),
                    warnings: warnings)
            } catch {
                warnings.append("The generated cover could not be written: \(error)")
            }
        } else {
            warnings.append("The generated cover could not be rendered.")
        }
        warnings.append("No cover image was written for this capture.")
        return CoverResolution(cover: nil, warnings: warnings)
    }

    // MARK: - Sources

    private func download(
        _ urls: [URL], cacheKey: String?, into directory: URL,
        warnings: inout [String]
    ) -> ResolvedCover? {
        // The two Kindle URLs share one deadline: a primary that consumes
        // most of the budget must not give the fallback a second full one.
        let start = clock()
        var elapsed: TimeInterval = 0
        for url in urls {
            // Never let a non-monotonic clock hand the fallback more time.
            elapsed = max(elapsed, clock() - start)
            let remaining = timeout - elapsed
            guard remaining > 0 else {
                warnings.append("The cover download deadline expired.")
                break
            }
            do {
                let data = try fetcher.fetch(
                    url, timeout: remaining, byteLimit: byteLimit)
                guard isReadableImage(data) else {
                    warnings.append(
                        "The cover response was not a readable image.")
                    continue
                }
                let file = try writeCover(data: data, to: directory)
                cacheFile(at: file, key: cacheKey, warnings: &warnings)
                return cover(
                    file: file, source: .download, data: data,
                    warnings: &warnings)
            } catch {
                warnings.append("Cover download failed: \(error)")
            }
        }
        return nil
    }

    private func imageFile(
        _ url: URL, cacheKey: String?, into directory: URL,
        source: ResolvedCover.Source, warnings: inout [String]
    ) -> ResolvedCover? {
        // Inspect the target, not a symlink's own tiny inode, so an allowed
        // link inside the EPUB cannot bypass the byte limit.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let size =
            (try? FileManager.default.attributesOfItem(
                atPath: resolved.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= byteLimit else {
            warnings.append(
                "The EPUB cover is \(size) bytes, over the size limit.")
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: resolved)
        } catch {
            warnings.append("The EPUB cover could not be read: \(error)")
            return nil
        }
        guard isReadableImage(data) else {
            warnings.append("The EPUB cover is not a readable image.")
            return nil
        }
        do {
            let file = try writeCover(data: data, to: directory)
            cacheFile(at: file, key: cacheKey, warnings: &warnings)
            return cover(
                file: file, source: source, data: data, warnings: &warnings)
        } catch {
            warnings.append("The EPUB cover could not be written: \(error)")
            return nil
        }
    }

    private func pdfPage(
        _ url: URL, cacheKey: String?, into directory: URL,
        warnings: inout [String]
    ) -> ResolvedCover? {
        guard let document = CGPDFDocument(url as CFURL),
            let page = document.page(at: 1)
        else {
            warnings.append("The PDF's first page could not be read.")
            return nil
        }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 1, box.height > 1 else {
            warnings.append("The PDF's first page has no usable size.")
            return nil
        }
        // A /Rotate 90 or 270 page displays landscape; the bitmap must use
        // the rotated bounds or the cover gets blank margins and a wrong
        // aspect ratio.
        let rotated = page.rotationAngle % 180 != 0
        let displayWidth = rotated ? box.height : box.width
        let displayHeight = rotated ? box.width : box.height
        let scale = min(
            1600 / displayWidth, 1600 / displayHeight, 2)
        let width = max(1, Int(ceil(displayWidth * scale)))
        let height = max(1, Int(ceil(displayHeight * scale)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            warnings.append("The PDF cover could not be rendered.")
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let target = CGRect(
            x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        // getDrawingTransform normalises the page box and rotation, but it
        // never scales a page UP. Enlarge the fitted page about the target
        // centre; this keeps the page upright and fills the cover.
        let base = page.getDrawingTransform(
            .mediaBox, rect: target, rotate: 0,
            preserveAspectRatio: true)
        let mapped = box.applying(base)
        guard mapped.width > 0, mapped.height > 0 else {
            warnings.append("The PDF page has no usable drawing box.")
            return nil
        }
        let factor = min(
            target.width / mapped.width,
            target.height / mapped.height,
            2)
        context.translateBy(x: target.midX, y: target.midY)
        context.scaleBy(x: factor, y: factor)
        context.translateBy(x: -target.midX, y: -target.midY)
        context.concatenate(base)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else {
            warnings.append("The PDF cover could not be rendered.")
            return nil
        }
        do {
            let file = try writeImage(image, to: directory)
            cacheFile(at: file, key: cacheKey, warnings: &warnings)
            let size = byteCount(of: file, fallback: 0)
            return ResolvedCover(
                fileURL: file, source: .pdf,
                mediaType: UTType.jpeg.identifier, byteCount: size)
        } catch {
            warnings.append("The PDF cover could not be written: \(error)")
            return nil
        }
    }

    // MARK: - URLs and cache

    private func kindleURLs(physicalID: String?, asin: String?) -> [URL] {
        var urls: [URL] = []
        if let physicalID, !physicalID.isEmpty,
            let encoded = physicalID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed),
            let url = URL(
                string: "https://m.media-amazon.com/images/I/\(encoded).jpg")
        {
            urls.append(url)
        }
        if let asin, !asin.isEmpty,
            let encoded = asin.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed),
            let url = URL(
                string:
                    "https://m.media-amazon.com/images/P/\(encoded)"
                    + ".01.LZZZZZZZ.jpg")
        {
            urls.append(url)
        }
        return urls
    }

    private func cachedCover(
        key: String, warnings: inout [String]
    ) -> URL? {
        let url = cacheDirectory.appendingPathComponent(key + ".jpg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url), isReadableImage(data)
        else {
            warnings.append("A cached cover was corrupt and was discarded.")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func cacheFile(
        at file: URL, key: String?, warnings: inout [String]
    ) {
        guard let key, !key.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true)
            let data = try Data(contentsOf: file)
            guard isReadableImage(data) else { return }
            let destination = cacheDirectory.appendingPathComponent(
                key + ".jpg")
            try data.write(to: destination, options: .atomic)
        } catch {
            warnings.append("The cover cache could not be written: \(error)")
        }
    }

    /// A stable key for the full identifier and source. Sanitising alone
    /// collides (`A:B` and `A-B`), so a 64-bit FNV-1a digest is appended.
    public static func cacheKey(
        for identifier: String, source: BookSource?
    ) -> String {
        let raw = (source?.captureSource ?? "") + "|" + identifier
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_"))
        let prefix = identifier.unicodeScalars.prefix(32).map {
            allowed.contains($0) ? Character($0) : "-"
        }
        return "\(String(prefix))-\(String(hash, radix: 16))"
    }

    // MARK: - Image writing

    private func writeCover(data: Data, to directory: URL) throws -> URL {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?
        else {
            throw CoverWriteError.unreadableImage
        }
        if type == UTType.jpeg.identifier {
            return try writeRawJPEG(data, to: directory)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4000,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary)
        else {
            throw CoverWriteError.unreadableImage
        }
        return try writeImage(image, to: directory)
    }

    private func writeImage(_ image: CGImage, to directory: URL) throws -> URL {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw CoverWriteError.couldNotEncode
        }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CoverWriteError.couldNotEncode
        }
        return try writeRawJPEG(data as Data, to: directory)
    }

    private func writeRawJPEG(_ data: Data, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("cover.jpg")
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw CoverWriteError.io("\(error)")
        }
        return destination
    }

    private func cover(
        file: URL, source: ResolvedCover.Source, data: Data,
        warnings: inout [String]
    ) -> ResolvedCover {
        ResolvedCover(
            fileURL: file, source: source,
            mediaType: UTType.jpeg.identifier,
            byteCount: byteCount(of: file, fallback: data.count))
    }

    private func isReadableImage(_ data: Data) -> Bool {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth]
                as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight]
                as? NSNumber)?.intValue,
            width > 0, height > 0
        else { return false }
        // Divide rather than multiply so an enormous pair cannot overflow.
        return width <= maximumPixels / height
    }

    private func byteCount(of url: URL, fallback: Int) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.intValue ?? fallback
    }
}

public enum CoverWriteError: Error, CustomStringConvertible, Sendable {
    case unreadableImage
    case couldNotEncode
    case io(String)

    public var description: String {
        switch self {
        case .unreadableImage:
            "The cover bytes are not a readable image."
        case .couldNotEncode:
            "The cover image could not be encoded as JPEG."
        case .io(let message):
            "The cover could not be written: \(message)"
        }
    }
}
