import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import KindleAX
import ScreenCaptureKit
import UniformTypeIdentifiers

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

    public init(directory: URL, pdf: URL, pages: Int, title: String) {
        self.directory = directory
        self.pdf = pdf
        self.pages = pages
        self.title = title
    }
}

public enum CaptureError: Error, CustomStringConvertible, Sendable {
    case kindleNotRunning
    case notTrusted
    case noWindow
    case notReading(String)
    case cancelled
    case captureFailed(String)
    case pageDidNotTurn
    case pdfFailed(String)

    public var description: String {
        switch self {
        case .kindleNotRunning: "Kindle is not running."
        case .notTrusted: "Accessibility permission is not granted."
        case .noWindow: "Kindle has no scene window."
        case .notReading(let state):
            "Kindle is showing \(state). Open a book and hide the toolbar first."
        case .cancelled: "Cancelled."
        case .captureFailed(let message): message
        case .pageDidNotTurn:
            "The page did not turn. Kindle may be busy, or the window moved."
        case .pdfFailed(let message): "The PDF could not be written: \(message)"
        }
    }
}

public final class CaptureEngine: @unchecked Sendable {
    private let archive: Archive

    public init(archive: Archive) {
        self.archive = archive
    }

    public func capture(
        book: Book?,
        pageLimit: Int?,
        output: URL,
        progress: @Sendable (CaptureProgress) -> Void,
        isCancelled: @Sendable () -> Bool
    ) throws -> CaptureResult {
        guard KindleLive.isTrusted() else { throw CaptureError.notTrusted }
        guard KindleLive.isRunning() else {
            throw CaptureError.kindleNotRunning
        }
        try KindleLive.activate()
        guard let first = try? KindleLive.currentPage() else {
            throw CaptureError.noWindow
        }
        guard first.isReading else {
            throw CaptureError.notReading(first.state)
        }
        guard let window = first.windowFrame else {
            throw CaptureError.noWindow
        }
        let rect = pageRect(for: window)
        guard rect.width > 100, rect.height > 100 else {
            throw CaptureError.captureFailed(
                "The page frame is too small: \(rect.width)×\(rect.height).")
        }
        let display = CGDisplayBounds(CGMainDisplayID())
        guard display.contains(rect) else {
            throw CaptureError.captureFailed(
                "The page frame is outside the main display. Move the Kindle "
                    + "window fully onto the screen.")
        }

        let manager = FileManager.default
        let pagesDirectory = output.appendingPathComponent("pages")
        try manager.createDirectory(
            at: pagesDirectory, withIntermediateDirectories: true)

        let title =
            book?.title
            ?? (first.title.isEmpty ? "Kindle book" : first.title)
        let asin = book?.asin ?? "unknown"
        var pageURLs: [URL] = []
        var pageTexts: [String] = []
        var textEntries: [[String: Any]] = []
        var current = first
        var index = 0
        var turns = 0
        var ended = false
        let safetyLimit = pageLimit ?? 5_000
        defer {
            if ended {
                try? KindleLive.escape()
                Thread.sleep(forTimeInterval: 0.5)
            }
            for _ in 0..<turns {
                try? KindleLive.turnBackward()
                Thread.sleep(forTimeInterval: 0.4)
            }
        }

        while index < safetyLimit {
            if isCancelled() { throw CaptureError.cancelled }
            try requireFrontmost()
            let pageURL = pagesDirectory.appendingPathComponent(
                String(format: "page-%04d.png", index + 1))
            let image = try Screenshot.image(rect: rect)
            try Screenshot.save(image, to: pageURL)
            let imageHash = Screenshot.hash(image)
            pageURLs.append(pageURL)
            pageTexts.append(current.text)
            textEntries.append([
                "page": index + 1,
                "characters": current.characters,
                "text": current.text,
            ])
            index += 1
            progress(
                CaptureProgress(
                    page: index, pageLimit: pageLimit,
                    message: "Captured page \(index)"
                        + (current.endOfBook ? " · end of book" : "")))
            if current.endOfBook { break }
            if let pageLimit, index >= pageLimit { break }

            let previous = current
            try KindleLive.turnForward()
            current = try settle(
                before: previous, previousHash: imageHash, rect: rect,
                isCancelled: isCancelled)
            turns += 1
            try checkLayout(current, rect: rect, window: window)
            if current.endOfBook {
                ended = true
                break
            }
        }

        try writeText(textEntries, to: output.appendingPathComponent("text.jsonl"))
        let pdfURL = output.appendingPathComponent(
            "\(safeFilename(title)).pdf")
        let pages = try PDFWriter.write(
            pageURLs: pageURLs, texts: pageTexts, title: title, asin: asin,
            to: pdfURL)
        let pdfPages = PDFWriter.pageCount(pdfURL)
        guard pdfPages == pageURLs.count else {
            throw CaptureError.pdfFailed(
                "The PDF has \(pdfPages) pages; \(pageURLs.count) were "
                    + "captured.")
        }
        for pageURL in pageURLs {
            guard
                let source = CGImageSourceCreateWithURL(
                    pageURL as CFURL, nil),
                CGImageSourceGetCount(source) > 0
            else {
                throw CaptureError.captureFailed(
                    "A page image is missing or unreadable: "
                        + pageURL.lastPathComponent)
            }
        }
        let manifest: [String: Any] = [
            "asin": asin,
            "title": title,
            "pageCount": pageURLs.count,
            "pdfPages": pdfPages,
            "pageWidth": Int(rect.width.rounded()),
            "pageHeight": Int(rect.height.rounded()),
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "app": "Kindling",
            "verified": true,
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(
            to: output.appendingPathComponent("manifest.json"))
        _ = try? archive.recordCapture(
            asin: book?.asin, title: title, directory: output.path,
            pageCount: pages, pdfPath: pdfURL.path, state: "finished")
        return CaptureResult(
            directory: output, pdf: pdfURL, pages: pages, title: title)
    }

    private func pageRect(for window: AXNode.Frame) -> CGRect {
        CGRect(
            x: window.x + 52, y: window.y + 54,
            width: window.width - 104, height: window.height - 108)
    }

    private func requireFrontmost() throws {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == KindleLive.bundleID
        {
            return
        }
        KindleLive.activate()
        Thread.sleep(forTimeInterval: 0.3)
        guard
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == KindleLive.bundleID
        else {
            throw CaptureError.captureFailed(
                "Kindle is not frontmost. Bring it to the front and start "
                    + "again; a capture photographs whatever is on top.")
        }
    }

    private func checkLayout(
        _ page: LivePage, rect: CGRect, window: AXNode.Frame
    ) throws {
        if let frame = page.windowFrame {
            let moved =
                abs(frame.x - window.x) > 1 || abs(frame.y - window.y) > 1
                || abs(frame.width - window.width) > 1
                || abs(frame.height - window.height) > 1
            if moved {
                throw CaptureError.captureFailed(
                    "The Kindle window moved during the capture. The crop no "
                        + "longer holds; the run stopped.")
            }
        }
        if let text = page.pageTextFrame {
            let textRect = CGRect(
                x: text.x, y: text.y, width: text.width, height: text.height)
            if !rect.insetBy(dx: -2, dy: -2).contains(textRect) {
                throw CaptureError.captureFailed(
                    "The page text no longer fits the crop. The layout moved; "
                        + "the run stopped.")
            }
        }
    }

    private func settle(
        before: LivePage, previousHash: UInt64, rect: CGRect,
        isCancelled: @Sendable () -> Bool
    ) throws -> LivePage {
        let started = Date()
        while Date().timeIntervalSince(started) < 3.0 {
            Thread.sleep(forTimeInterval: 0.05)
            if isCancelled() { throw CaptureError.cancelled }
            guard let page = try? KindleLive.currentPage() else {
                continue
            }
            if page.endOfBook { return page }
            if page.state == "readingChromeHidden" {
                if page.text != before.text { return page }
                if Date().timeIntervalSince(started) > 0.3 {
                    let image = try Screenshot.image(rect: rect)
                    if Screenshot.hash(image) != previousHash {
                        return page
                    }
                }
            }
        }
        throw CaptureError.pageDidNotTurn
    }

    private func writeText(_ entries: [[String: Any]], to url: URL) throws {
        var lines: [String] = []
        for entry in entries {
            let data = try JSONSerialization.data(
                withJSONObject: entry, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: url, atomically: true, encoding: .utf8)
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.unicodeScalars.map {
            invalid.contains($0) ? "-" : Character($0)
        }
        let text = String(cleaned).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return text.isEmpty ? "Kindle book" : String(text.prefix(80))
    }
}

enum Screenshot {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<CGImage, Error>?

        func set(_ result: Result<CGImage, Error>) {
            lock.lock()
            value = result
            lock.unlock()
        }

        func get() -> Result<CGImage, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func image(rect: CGRect) throws -> CGImage {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let display =
                    content.displays.first(where: { $0.frame.contains(rect) })
                    ?? content.displays.first
                guard let display else {
                    throw CaptureError.captureFailed("No display found.")
                }
                let filter = SCContentFilter(
                    display: display, excludingApplications: [],
                    exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = CGRect(
                    x: rect.minX - display.frame.minX,
                    y: rect.minY - display.frame.minY,
                    width: rect.width, height: rect.height)
                configuration.width = Int(rect.width)
                configuration.height = Int(rect.height)
                configuration.captureResolution = .best
                configuration.scalesToFit = false
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration)
                box.set(.success(image))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.get() else {
            throw CaptureError.captureFailed("The screenshot did not finish.")
        }
        return try result.get()
    }

    static func save(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw CaptureError.captureFailed("Could not create \(url.path).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.captureFailed("Could not write \(url.path).")
        }
    }

    static func hash(_ image: CGImage) -> UInt64 {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            context.interpolationQuality = .low
            context.draw(
                image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let total = pixels.reduce(0) { $0 + Int($1) }
        let mean = total / pixels.count
        var hash: UInt64 = 0
        for pixel in pixels {
            hash = (hash << 1) | (Int(pixel) > mean ? 1 : 0)
        }
        return hash
    }
}
