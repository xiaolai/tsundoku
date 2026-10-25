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
/// Books exposes a selection as `AXSelectedText` on each selected static text
/// node; the words are joined in tree order. The web area's own attribute
/// stays empty, so reading only the page element would miss every selection.
public struct BooksContext: ReaderContext {
    public let kind: ReaderKind = .appleBooks
    public let bundleID: String

    public init(bundleID: String = ReaderKind.appleBooks.bundleID) {
        self.bundleID = bundleID
    }

    public func page() throws -> ReaderPage {
        do {
            return try readPage()
        } catch is PageUnstable {
            // One retry: a page that moved mid-read is usually settled by
            // the time its replacement is read.
            do {
                return try readPage()
            } catch is PageUnstable {
                throw ReaderContextError.unavailable(
                    .appleBooks,
                    reason: "The page changed while it was being read.")
            }
        }
    }

    /// A page identity changed between two reads. Internal only: `page()`
    /// retries it and turns a second failure into a reader error.
    private struct PageUnstable: Error {}

    private func readPage() throws -> ReaderPage {
        if Task.isCancelled { throw ReaderContextError.cancelled }
        let chosen = try chosenWindow()
        let window = chosen.node
        if Task.isCancelled { throw ReaderContextError.cancelled }

        let title = displayTitle(window)
        let text = BooksPageText.text(from: window)
        if !text.isEmpty {
            // The selection is read after the text snapshot and accepted
            // only while both it and the page stay unchanged.
            let selection = try pageSelection(
                in: chosen, expectedTitle: title, expectedText: text)
            return ReaderPage(
                text: text, title: title, kind: .appleBooks,
                source: .accessibility, selection: selection)
        }

        guard let frame = BooksPageText.rect(window.frame) else {
            throw ReaderContextError.noReaderWindow(.appleBooks)
        }
        let pid = chosen.app.processIdentifier
        let ocr = try BooksOCR.pageText(pid: pid, axFrame: frame)
        let recognized = ocr.text
        guard recognized.count >= BooksOCR.minimumCharacters else {
            throw ReaderContextError.noPageText(.appleBooks)
        }
        if Task.isCancelled { throw ReaderContextError.cancelled }
        // OCR runs after the Accessibility snapshot. An image-only page can
        // leave both snapshots empty with the same title, so screenshots on
        // both sides of the selection read are what prove the page held.
        guard let current = try? chosen.recorder.capture(chosen.element),
            BooksPageText.text(from: current) == text,
            displayTitle(current) == title,
            let after = try? BooksOCR.capture(pid: pid, axFrame: frame),
            BooksOCR.sameImage(ocr.image, after)
        else { throw PageUnstable() }
        // The selection belongs to the OCR page only if it is read after
        // both screenshots and the page is still the same one afterwards.
        let selection = try pageSelection(
            in: chosen, expectedTitle: title, expectedText: text)
        guard let final = try? BooksOCR.capture(pid: pid, axFrame: frame),
            BooksOCR.sameImage(ocr.image, final)
        else { throw PageUnstable() }
        return ReaderPage(
            text: recognized, title: title, kind: .appleBooks,
            source: .ocr, selection: selection)
    }

    private func pageSelection(
        in chosen: ChosenWindow, expectedTitle: String, expectedText: String
    ) throws -> String? {
        switch stableSelection(
            in: chosen.element, source: chosen.source,
            recorder: chosen.recorder, expectedTitle: expectedTitle,
            expectedText: expectedText)
        {
        case .none: return nil
        case .text(let value): return value
        case .unstable: throw PageUnstable()
        }
    }

    /// The reader window `page()` and `selectedText()` both use, chosen by
    /// the same focus and geometry ranking so a selection always comes from
    /// the page it is attached to.
    private struct ChosenWindow {
        let element: AXUIElement
        let node: AXNode
        let source: LiveAXSource
        let recorder: AXRecorder<LiveAXSource>
        let app: NSRunningApplication
    }

    private func chosenWindow() throws -> ChosenWindow {
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
        let recorded = windows.compactMap {
            window -> (element: AXUIElement, node: AXNode)? in
            guard let node = try? recorder.capture(window) else { return nil }
            return (window, node)
        }
        guard !recorded.isEmpty else {
            throw ReaderContextError.unavailable(
                .appleBooks, reason: "The Accessibility tree is unreadable.")
        }
        let focus = focusedWindow(application)
        guard
            let best = BooksPageText.bestWindow(
                recorded.map(\.node),
                preferredTitle: focus?.title,
                preferredFrame: focus?.frame),
            let index = recorded.firstIndex(where: { $0.node == best })
        else {
            throw ReaderContextError.noReaderWindow(.appleBooks)
        }
        return ChosenWindow(
            element: recorded[index].element, node: recorded[index].node,
            source: source, recorder: recorder, app: app)
    }

    /// Reads the current selection from the live window's text nodes.
    ///
    /// Books sets `AXSelectedText` on selected `AXStaticText` nodes, not on
    /// the web area, and a selection can span several nodes. They are joined
    /// in tree order. Empty or unreadable nodes contribute nothing.
    public func selectedText() -> String? {
        guard let chosen = try? chosenWindow() else { return nil }
        guard
            case .text(let selection) = stableSelection(
                in: chosen.element, source: chosen.source,
                recorder: chosen.recorder,
                expectedTitle: displayTitle(chosen.node),
                expectedText: BooksPageText.text(from: chosen.node))
        else { return nil }
        return selection
    }

    private enum SelectionSnapshot {
        case none
        case text(String)
        /// The page or selection moved between reads; the caller must not
        /// pair this selection with the text it read.
        case unstable
    }

    /// A selection read twice with the same result, while the page itself is
    /// proven unchanged, so a turn between the text snapshot and the
    /// selection cannot pair them across pages.
    private func stableSelection(
        in window: AXUIElement, source: LiveAXSource,
        recorder: AXRecorder<LiveAXSource>, expectedTitle: String,
        expectedText: String
    ) -> SelectionSnapshot {
        guard let selection = selectionText(in: window, source: source)
        else { return .none }
        let liveTitle = (try? source.string(window, "AXTitle")) ?? ""
        if !liveTitle.isEmpty, liveTitle != expectedTitle,
            expectedTitle != "Apple Books"
        {
            return .unstable
        }
        guard let current = try? recorder.capture(window),
            BooksPageText.text(from: current) == expectedText,
            displayTitle(current) == expectedTitle
        else { return .unstable }
        guard selectionText(in: window, source: source) == selection
        else { return .unstable }
        return .text(selection)
    }

    private func selectionText(
        in window: AXUIElement, source: LiveAXSource
    ) -> String? {
        var parts: [String] = []
        var budget = 4_000
        var visited = Set<AXUIElement>()
        var complete = true
        collectSelection(
            window, source: source, depth: 0,
            budget: &budget, visited: &visited, into: &parts,
            complete: &complete)
        // A traversal that hit a depth, part or node limit returns a prefix.
        // Callers cannot tell it apart from a complete selection, so refuse
        // it rather than attach a silently incomplete passage.
        guard complete else { return nil }
        return SelectionText.joined(parts)
    }

    private func collectSelection(
        _ element: AXUIElement, source: LiveAXSource, depth: Int,
        budget: inout Int, visited: inout Set<AXUIElement>,
        into parts: inout [String], complete: inout Bool
    ) {
        guard depth < 24, parts.count < 50, budget > 0 else {
            if !Task.isCancelled { complete = false }
            return
        }
        guard !Task.isCancelled else {
            complete = false
            return
        }
        // AXUIElement equality resolves hash collisions; a hash-only set
        // would drop a distinct element that shares one.
        guard !visited.contains(element) else { return }
        visited.insert(element)
        budget -= 1
        let role = (try? source.string(element, "AXRole")) ?? ""
        if role == "AXHeading",
            let selected = try? source.string(element, "AXSelectedText"),
            !selected.isEmpty
        {
            // Its child static text would repeat the same words.
            parts.append(selected)
            return
        }
        if role == "AXStaticText",
            let selected = try? source.string(element, "AXSelectedText"),
            !selected.isEmpty
        {
            parts.append(selected)
        }
        for child in (try? source.children(element)) ?? [] {
            collectSelection(
                child, source: source, depth: depth + 1,
                budget: &budget, visited: &visited, into: &parts,
                complete: &complete)
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
        try pageText(pid: pid, axFrame: axFrame).text
    }

    /// The recognised text and the image it came from. The image lets the
    /// caller prove the page did not turn while Vision was running.
    static func pageText(pid: pid_t, axFrame: CGRect) throws
        -> (text: String, image: CGImage)
    {
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
        return (try recognize(image), image)
    }

    /// Two screenshots of the same page agree after the same downscale. A
    /// page turn changes enough content to differ even at this size, while a
    /// static reader window is pixel-stable between captures.
    static func sameImage(_ left: CGImage, _ right: CGImage) -> Bool {
        guard let leftBytes = thumbnail(left), let rightBytes = thumbnail(right)
        else { return false }
        return leftBytes == rightBytes
    }

    private static func thumbnail(_ image: CGImage) -> [UInt8]? {
        let side = 64
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(
                image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? bytes : nil
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
        let order = readingOrder(
            observations.map {
                (
                    minX: $0.boundingBox.minX, maxX: $0.boundingBox.maxX,
                    maxY: $0.boundingBox.maxY
                )
            })
        let lines = order.compactMap {
            observations[$0].topCandidates(1).first?.string
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reading order from recognised line boxes: columns left to right, then
    /// lines top to bottom. A line joins a column when it shares the column's
    /// left edge or overlaps most of the column's width, so a heading and a
    /// short last line stay with their body instead of forming columns of
    /// their own; a facing page overlaps neither and starts a new column.
    static func readingOrder(
        _ boxes: [(minX: CGFloat, maxX: CGFloat, maxY: CGFloat)]
    ) -> [Int] {
        var columns: [[Int]] = []
        for index in boxes.indices.sorted(by: {
            boxes[$0].minX < boxes[$1].minX
        }) {
            let box = boxes[index]
            if let column = columns.firstIndex(where: { members in
                let left = members.map { boxes[$0].minX }.min() ?? box.minX
                let right = members.map { boxes[$0].maxX }.max() ?? box.maxX
                let sameEdge = abs(box.minX - left) <= 0.015
                let overlap =
                    min(box.maxX, right) - max(box.minX, left)
                let narrower = min(box.maxX - box.minX, right - left)
                return sameEdge
                    || (narrower > 0 && overlap / narrower >= 0.5)
            }) {
                columns[column].append(index)
            } else {
                columns.append([index])
            }
        }
        return columns
            .sorted { left, right in
                let leftX = left.map { boxes[$0].minX }.min() ?? 0
                let rightX = right.map { boxes[$0].minX }.min() ?? 0
                return leftX < rightX
            }
            .flatMap { column in
                column.sorted { boxes[$0].maxY > boxes[$1].maxY }
            }
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
