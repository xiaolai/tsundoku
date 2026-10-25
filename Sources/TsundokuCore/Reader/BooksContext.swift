import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import KindleAX
import ScreenCaptureKit
import Vision

// MARK: - Books context

/// Apple Books page text through Accessibility, with a labelled OCR fallback.
///
/// Selection is deliberately out of scope: the spike measured
/// `AXSelectedText` as empty and a drag selecting nothing, so this type never
/// claims a selection it did not read.
public struct BooksContext: ReaderContext {
    public let kind: ReaderKind = .appleBooks
    public let bundleID: String

    public init(bundleID: String = ReaderKind.appleBooks.bundleID) {
        self.bundleID = bundleID
    }

    public func page() throws -> ReaderPage {
        if Task.isCancelled { throw ReaderContextError.cancelled }
        guard AXIsProcessTrusted() else {
            throw ReaderContextError.notTrusted
        }
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else {
            throw ReaderContextError.readerNotRunning(.appleBooks)
        }

        let application = AXUIElementCreateApplication(
            app.processIdentifier)
        let source = LiveAXSource()
        let recorder = AXRecorder(source: source)
        let windows: [AXUIElement]
        do {
            windows = try source.windows(application)
        } catch {
            throw ReaderContextError.noReaderWindow(.appleBooks)
        }
        // One unreadable window must not sink the reader: capture each
        // independently and keep whatever is readable.
        let recorded = windows.compactMap { try? recorder.capture($0) }
        guard !recorded.isEmpty else {
            throw ReaderContextError.unavailable(
                .appleBooks, reason: "The Accessibility tree is unreadable.")
        }
        let focus = focusedWindow(application)
        guard
            let window = BooksPageText.bestWindow(
                recorded,
                preferredTitle: focus?.title,
                preferredFrame: focus?.frame)
        else {
            throw ReaderContextError.noReaderWindow(.appleBooks)
        }
        if Task.isCancelled { throw ReaderContextError.cancelled }

        let title = displayTitle(window)
        let text = BooksPageText.text(from: window)
        if !text.isEmpty {
            return ReaderPage(
                text: text, title: title, kind: .appleBooks,
                source: .accessibility, selection: selectedText())
        }

        guard let frame = BooksPageText.rect(window.frame) else {
            throw ReaderContextError.noReaderWindow(.appleBooks)
        }
        let recognized = try BooksOCR.text(
            pid: app.processIdentifier, axFrame: frame)
        guard recognized.count >= BooksOCR.minimumCharacters else {
            throw ReaderContextError.noPageText(.appleBooks)
        }
        if Task.isCancelled { throw ReaderContextError.cancelled }
        return ReaderPage(
            text: recognized, title: title, kind: .appleBooks,
            source: .ocr, selection: selectedText())
    }

    /// Reads the current selection from the live window's text nodes.
    ///
    /// Books sets `AXSelectedText` on selected `AXStaticText` nodes, not on
    /// the web area, and a selection can span several nodes. They are joined
    /// in tree order. Empty or unreadable nodes contribute nothing.
    public func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID).first
        else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let source = LiveAXSource()
        guard let windows = try? source.windows(application) else {
            return nil
        }
        var parts: [String] = []
        for window in windows {
            collectSelection(window, source: source, depth: 0, into: &parts)
            if parts.count >= 50 { break }
        }
        let text = parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func collectSelection(
        _ element: AXUIElement, source: LiveAXSource, depth: Int,
        into parts: inout [String]
    ) {
        guard depth < 24, parts.count < 50 else { return }
        let role = (try? source.string(element, "AXRole")) ?? ""
        if role == "AXStaticText" || role == "AXHeading",
            let selected = try? source.string(element, "AXSelectedText"),
            !selected.isEmpty
        {
            parts.append(selected)
        }
        for child in (try? source.children(element)) ?? [] {
            collectSelection(child, source: source, depth: depth + 1, into: &parts)
        }
    }

    private func displayTitle(_ window: AXNode) -> String {
        let candidates = [
            window.title,
            window.label,
            window.value?.asText,
        ]
        for case let title? in candidates
        where !title.isEmpty && title != "未知" && title != "Unknown" {
            return title
        }
        return "Apple Books"
    }

    /// The focused window's title and AX frame, used to prefer the book the
    /// user is actually reading when several reader windows are open.
    private func focusedWindow(_ application: AXUIElement) -> (
        title: String?, frame: CGRect?
    )? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedWindowAttribute as CFString,
                &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &title)
        var position: CFTypeRef?
        var size: CFTypeRef?
        var frame: CGRect?
        if AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &position) == .success,
            AXUIElementCopyAttributeValue(
                window, kAXSizeAttribute as CFString, &size) == .success,
            let position, let size,
            CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        {
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &point),
                AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
            {
                frame = CGRect(origin: point, size: dimensions)
            }
        }
        return (title as? String, frame)
    }
}

// MARK: - OCR fallback

/// Screenshot the Books reader window, then recognise its text with Vision.
///
/// The screenshot is a window capture, never the whole display: the panel and
/// the trigger live outside the reader and must not appear in the picture.
enum BooksOCR {
    static let minimumCharacters = 20

    static func text(pid: pid_t, axFrame: CGRect) throws -> String {
        if Task.isCancelled { throw ReaderContextError.cancelled }
        guard CGPreflightScreenCaptureAccess() else {
            throw ReaderContextError.unavailable(
                .appleBooks,
                reason:
                    "Screen Recording is not granted; the page has no "
                    + "Accessibility text and OCR cannot run.")
        }
        let image = try capture(pid: pid, axFrame: axFrame)
        if Task.isCancelled { throw ReaderContextError.cancelled }
        return try recognize(image)
    }

    static func capture(pid: pid_t, axFrame: CGRect) throws
        -> CGImage
    {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ImageBox()
        let captureTask = Task.detached {
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let candidates = content.windows.filter {
                    $0.owningApplication?.processID == pid
                        && $0.frame.width > 40 && $0.frame.height > 40
                }
                guard
                    let window = candidates.min(by: {
                        distance($0.frame, axFrame)
                            < distance($1.frame, axFrame)
                    })
                else {
                    box.set(
                        .failure(
                            ReaderContextError.noReaderWindow(.appleBooks)))
                    semaphore.signal()
                    return
                }
                guard distance(window.frame, axFrame) <= 120 else {
                    box.set(
                        .failure(
                            ReaderContextError.noReaderWindow(.appleBooks)))
                    semaphore.signal()
                    return
                }
                let filter = SCContentFilter(
                    desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.width = Int(window.frame.width)
                configuration.height = Int(window.frame.height)
                configuration.showsCursor = false
                configuration.captureResolution = .best
                configuration.scalesToFit = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration)
                box.set(.success(image))
            } catch {
                box.set(
                    .failure(
                        ReaderContextError.unavailable(
                            .appleBooks,
                            reason: "The reader screenshot failed: \(error)")))
            }
            semaphore.signal()
        }
        let deadline = Date().addingTimeInterval(6)
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            if Task.isCancelled {
                captureTask.cancel()
                throw ReaderContextError.cancelled
            }
            if Date() >= deadline {
                captureTask.cancel()
                throw ReaderContextError.unavailable(
                    .appleBooks,
                    reason:
                        "The reader screenshot timed out after 6 seconds.")
            }
        }
        guard let result = box.value else {
            throw ReaderContextError.unavailable(
                .appleBooks, reason: "The reader screenshot did not finish.")
        }
        return try result.get()
    }

    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:])
                .perform([request])
        } catch {
            throw ReaderContextError.unavailable(
                .appleBooks, reason: "OCR failed: \(error)")
        }
        let observations = request.results ?? []
        // Columns are horizontal-overlap clusters: lines in one column share
        // x-extent, while a facing page does not. This keeps a single-column
        // line that happens to straddle the midpoint in its own column.
        var columns: [[VNRecognizedTextObservation]] = []
        for observation in observations.sorted(by: {
            $0.boundingBox.minX < $1.boundingBox.minX
        }) {
            let box = observation.boundingBox
            if let index = columns.firstIndex(where: { column in
                // A line belongs to a column when its midpoint lies within
                // that column's x-range. This keeps short and long lines with
                // the same left edge together and still separates a facing
                // page, whose midpoint is outside the range.
                let minX = column.map(\.boundingBox.minX).min() ?? 0
                let maxX = column.map(\.boundingBox.maxX).max() ?? 0
                let mid = box.midX
                return mid >= minX - box.width * 0.1
                    && mid <= maxX + box.width * 0.1
            }) {
                columns[index].append(observation)
            } else {
                columns.append([observation])
            }
        }
        let ordered = columns
            .sorted { left, right in
                let leftX = left.map(\.boundingBox.minX).min() ?? 0
                let rightX = right.map(\.boundingBox.minX).min() ?? 0
                return leftX < rightX
            }
            .flatMap { column in
                column.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            }
        let lines = ordered.compactMap {
            $0.topCandidates(1).first?.string
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func distance(_ left: CGRect, _ right: CGRect) -> CGFloat {
        abs(left.origin.x - right.origin.x)
            + abs(left.origin.y - right.origin.y)
            + abs(left.width - right.width)
            + abs(left.height - right.height)
    }
}

private final class ImageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<CGImage, Error>?

    func set(_ value: Result<CGImage, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Result<CGImage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
