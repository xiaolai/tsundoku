import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import KindleAX

/// One Apple Books reader page as Accessibility exposes it.
public struct BooksLivePage: Sendable, Equatable {
    public let state: String
    public let title: String
    public let text: String
    public let windowFrame: AXNode.Frame?
    public let textFrames: [AXNode.Frame]
    public let webAreaFrames: [AXNode.Frame]
    public let pageNumber: Int?
    public let pageCount: Int?
    public let endOfBook: Bool
    public let windowMain: Bool
    public let windowFocused: Bool
    /// The whole visible spread below the reader toolbar, in global AX
    /// coordinates: this includes the page margins and printed page numbers.
    public let cropRect: CGRect?

    /// A visible reader spread. Books can expose no static text on a page
    /// (image-only pages, or when it virtualises the text layer) while the
    /// page itself is still readable; the image is the page of record.
    public var isReading: Bool {
        state == "reading" || state == "readingNoText"
    }
}

public enum BooksLiveError: Error, CustomStringConvertible, Sendable {
    case notTrusted
    case notRunning
    case noWindow
    case notReading(String)
    case readFailed(String)

    public var description: String {
        switch self {
        case .notTrusted:
            "Accessibility permission is not granted to Tsundoku."
        case .notRunning:
            "Apple Books is not running."
        case .noWindow:
            "Apple Books has no reader window."
        case .notReading(let state):
            "Apple Books is showing \(state), not a reading page."
        case .readFailed(let message):
            "Could not read Apple Books: \(message)"
        }
    }
}

/// A reader window paired with the Accessibility element used to focus it.
public struct BooksReaderWindow {
    public let element: AXUIElement
    public let node: AXNode
    public let frame: CGRect?
}

public struct BooksFocusReport: Sendable, Equatable {
    public let activated: Bool
    public let frontmost: Bool
    public let windowMain: Bool
    public let windowFocused: Bool
    public let raised: Bool
    public let focusedWindowTitle: String?
    public let focusedRole: String?
    public let focusedFrame: CGRect?
}

/// Apple Books behind the capture contract. Reads the reader window, focuses
/// it, and posts page turns; it never selects or modifies book text.
public enum BooksLive {
    public static let bundleID = "com.apple.iBooksX"

    public static func isRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first != nil
    }

    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public static func isFrontmost() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.isActive == true
    }

    /// Bring Books to the front. `NSRunningApplication.activate` alone is
    /// refused for a CLI child of SSH; asking LaunchServices raises the app.
    public static func activate() {
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else { return }
        if app.isActive { return }
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(
                at: url, configuration: configuration
            ) { _, _ in semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 3)
        }
        app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.30)
    }

    public static func currentPage() throws -> BooksLivePage {
        let reader = try readerWindow()
        let node = reader.node
        let title = readerTitle(node)
        let text = BooksPageText.text(from: node)
        let frames = BooksPageText.textFrames(in: node)
        let webFrames = BooksPageText.webAreaFrames(in: node).map {
            AXNode.Frame(
                x: Double($0.minX), y: Double($0.minY),
                width: Double($0.width), height: Double($0.height))
        }
        let window = reader.frame
        let flags = windowFlags(reader.element)
        // Books draws page numbers but no measured AX element carries them
        // yet; the probe records what the tree exposes before this is used.
        return BooksLivePage(
            state: text.isEmpty ? "readingNoText" : "reading",
            title: title,
            text: text,
            windowFrame: window.map {
                AXNode.Frame(
                    x: Double($0.minX), y: Double($0.minY),
                    width: Double($0.width), height: Double($0.height))
            },
            textFrames: frames,
            webAreaFrames: webFrames,
            pageNumber: nil,
            pageCount: nil,
            endOfBook: false,
            windowMain: flags.main,
            windowFocused: flags.focused,
            cropRect: cropRect(for: reader))
    }

    /// The reader window: a window with an `AXWebArea` and readable page text,
    /// preferring the focused window when several books are open.
    public static func readerWindow() throws -> BooksReaderWindow {
        guard isTrusted() else { throw BooksLiveError.notTrusted }
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else { throw BooksLiveError.notRunning }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let source = LiveAXSource()
        let recorder = AXRecorder(source: source)
        let windows: [AXUIElement]
        do {
            windows = try source.windows(application)
        } catch {
            throw BooksLiveError.noWindow
        }
        let recorded = windows.compactMap { window -> (AXUIElement, AXNode)? in
            guard let node = try? recorder.capture(window) else { return nil }
            return (window, node)
        }
        let focus = focusedWindow(application)
        let nodes = recorded.map(\.1)
        guard
            let bestIndex = BooksPageText.bestWindow(
                nodes,
                preferredTitle: focus?.title,
                preferredFrame: focus?.frame)
                .flatMap({ nodes.firstIndex(of: $0) })
        else {
            throw BooksLiveError.noWindow
        }
        let pair = recorded[bestIndex]
        let frame = (try? source.frame(pair.0)).flatMap {
            CGRect(
                x: $0.x, y: $0.y,
                width: $0.width, height: $0.height)
        }
        return BooksReaderWindow(
            element: pair.0, node: pair.1, frame: frame)
    }

    /// Make the reader window main, focused and raised. No synthetic click is
    /// sent: Books turns pages from taps, so clicking the page to focus it
    /// would navigate.
    @discardableResult
    public static func focusReader() throws -> BooksFocusReport {
        activate()
        let reader = try readerWindow()
        // The report below carries the window flags read back after the
        // request, which is the stronger check; these two results only say
        // Books accepted the set.
        _ = AXUIElementSetAttributeValue(
            reader.element, kAXMainAttribute as CFString,
            kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(
            reader.element, kAXFocusedAttribute as CFString,
            kCFBooleanTrue)
        let raised = AXUIElementPerformAction(
            reader.element, kAXRaiseAction as CFString)
        Thread.sleep(forTimeInterval: 0.20)
        let application = AXUIElementCreateApplication(pid())
        let focus = focusedWindow(application)
        let flags = windowFlags(reader.element)
        return BooksFocusReport(
            activated: isFrontmost(), frontmost: isFrontmost(),
            windowMain: flags.main, windowFocused: flags.focused,
            raised: raised == .success,
            focusedWindowTitle: focus?.title,
            focusedRole: focus?.role,
            focusedFrame: focus?.frame)
    }

    /// Move and resize the reader window, then report what Books accepted.
    /// Used by the A4 single-page setup; the caller must restore the original
    /// frame.
    public static func setWindowFrame(_ frame: CGRect) throws -> CGRect {
        guard isTrusted() else { throw BooksLiveError.notTrusted }
        // AX window discovery can briefly return nothing while Books
        // reflows; retry before reporting the reader missing.
        var found: BooksReaderWindow?
        for _ in 0..<5 {
            if let reader = try? readerWindow() {
                found = reader
                break
            }
            Thread.sleep(forTimeInterval: 0.20)
        }
        guard let reader = found else {
            throw BooksLiveError.noWindow
        }
        var origin = CGPoint(x: frame.minX, y: frame.minY)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let position = AXValueCreate(.cgPoint, &origin),
            let dimensions = AXValueCreate(.cgSize, &size)
        else {
            throw BooksLiveError.readFailed("could not build a frame value")
        }
        let moved = AXUIElementSetAttributeValue(
            reader.element, kAXPositionAttribute as CFString, position)
        let resized = AXUIElementSetAttributeValue(
            reader.element, kAXSizeAttribute as CFString, dimensions)
        guard moved == .success, resized == .success else {
            throw BooksLiveError.readFailed("Apple Books refused the frame")
        }
        Thread.sleep(forTimeInterval: 0.45)
        // Books can drop its AX window while it reflows after the resize.
        // The AX set succeeded; retry the read and, if it stays unavailable,
        // report the requested frame. The session verifies the real crop
        // before any page is captured.
        for attempt in 0..<12 {
            if let actual = try? readerWindow().frame {
                return actual
            }
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.5 : 0.3)
        }
        return frame
    }

    /// Press a Books menu item by its exact title. Books exposes font size as
    /// View > Increase/Decrease Font Size, not as an absolute value.
    @discardableResult
    public static func pressMenuItem(_ title: String) -> Bool {
        guard isTrusted(),
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID).first
        else { return false }
        let application = AXUIElementCreateApplication(
            app.processIdentifier)
        var menuBar: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXMenuBarAttribute as CFString,
                &menuBar) == .success,
            let menuBar,
            CFGetTypeID(menuBar) == AXUIElementGetTypeID()
        else { return false }
        let bar = unsafeDowncast(menuBar, to: AXUIElement.self)
        for item in children(bar) {
            let name = stringAttribute(item, kAXTitleAttribute) ?? ""
            guard !name.isEmpty,
                let menu = children(item).first
            else { continue }
            for entry in descendants(menu, depth: 0) {
                guard stringAttribute(entry, kAXTitleAttribute) == title
                else { continue }
                return AXUIElementPerformAction(
                    entry, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    private static func descendants(
        _ element: AXUIElement, depth: Int
    ) -> [AXUIElement] {
        guard depth < 6 else { return [] }
        var result = children(element)
        for child in result {
            result.append(contentsOf: descendants(child, depth: depth + 1))
        }
        return result
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString,
                &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    public static func postKey(_ key: CGKeyCode) throws {
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else { throw BooksLiveError.notRunning }
        guard
            let down = CGEvent(
                keyboardEventSource: nil, virtualKey: key, keyDown: true),
            let up = CGEvent(
                keyboardEventSource: nil, virtualKey: key, keyDown: false)
        else { throw BooksLiveError.readFailed("could not make a key event") }
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
    }

    public static func turnForward() throws { try postKey(124) }
    public static func turnBackward() throws { try postKey(123) }

    /// The page image is a display crop, like Kindle's: it photographs the
    /// pixels the user sees, after the caller has proved Books is frontmost.
    public static func pageImage(
        _ rect: CGRect, isCancelled: @Sendable () -> Bool = { false }
    ) throws -> CGImage {
        do {
            return try DisplayScreenCapture().image(
                rect: rect, isCancelled: isCancelled)
        } catch {
            throw BooksLiveError.readFailed("the page screenshot failed: \(error)")
        }
    }

    /// Books keeps the reader title and toolbar above the spread. The crop
    /// starts below that toolbar and covers the full window width, so the
    /// printed page numbers and page margins stay in the image.
    public static func cropRect(
        for reader: BooksReaderWindow
    ) -> CGRect? {
        guard let window = reader.frame else { return nil }
        let toolbars = reader.node.all { $0.role == "AXToolbar" }
            .compactMap(\.frame)
        return cropRect(window: window, toolbarFrames: toolbars)
    }

    /// The spread starts below the top toolbar, not below a bottom toolbar or
    /// a scrubber. Without a recognisable top toolbar the crop is refused:
    /// guessing would include the title bar in the page image.
    public static func cropRect(
        window: CGRect, toolbarFrames: [AXNode.Frame]
    ) -> CGRect? {
        let top = toolbarFrames.filter {
            abs($0.y - Double(window.minY)) <= 8
                && abs($0.width - Double(window.width)) <= 8
                && abs($0.x - Double(window.minX)) <= 8
        }
        guard let bottom = top.map({ $0.y + $0.height }).max() else {
            return nil
        }
        let start = max(Double(window.minY), bottom)
        let height = Double(window.maxY) - start
        guard height > 100 else { return nil }
        return CGRect(
            x: window.minX, y: start,
            width: window.width, height: height)
    }

    /// True when the frontmost normal window at the crop centre is exactly the
    /// reader. A Books sheet, another Books window, or another app's panel
    /// would otherwise be photographed by the display crop.
    public static func readerIsUnobstructed(
        _ reader: BooksReaderWindow, crop: CGRect
    ) -> Bool {
        guard let readerFrame = reader.frame,
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let point = CGPoint(x: crop.midX, y: crop.midY)
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                let boundsValue = info[kCGWindowBounds as String]
                    as? NSDictionary,
                let bounds = CGRect(
                    dictionaryRepresentation: boundsValue as CFDictionary)
            else { continue }
            guard bounds.contains(point) else { continue }
            guard (info[kCGWindowOwnerPID as String] as? Int)
                == Int(pid())
            else { return false }
            return abs(bounds.minX - readerFrame.minX) <= 2
                && abs(bounds.minY - readerFrame.minY) <= 2
                && abs(bounds.width - readerFrame.width) <= 2
                && abs(bounds.height - readerFrame.height) <= 2
        }
        return false
    }

    /// True when key events posted to the Books process will reach the reader
    /// window: Books is frontmost, the reader is its main window, and that
    /// window is the application's focused window. Books reports `AXFocused`
    /// as false on the window even while it accepts arrow keys, so the
    /// focused-window identity is the reliable signal.
    public static func hasReaderLease(_ reader: BooksReaderWindow) -> Bool {
        guard isFrontmost() else { return false }
        let flags = windowFlags(reader.element)
        guard flags.main else { return false }
        let application = AXUIElementCreateApplication(pid())
        guard let focused = focusedWindow(application),
            let focusedTitle = focused.title
        else {
            // A missing focused window or title cannot be proved to be the
            // reader; fail closed.
            return false
        }
        let title = readerTitle(reader.node)
        return focusedTitle.compare(
            title, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
    }

    /// Recognise text in a captured spread. Only used for measurement and the
    /// OCR fallback; the caller labels the result.
    public static func recognizeText(in image: CGImage) throws -> String {
        try BooksOCR.recognize(image)
    }

    /// OCR for the text layer, with printed page-number lines removed.
    public static func recognizePageText(in image: CGImage) throws -> String {
        let raw = try BooksOCR.recognize(image)
        return raw.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && !trimmed.allSatisfy { $0.isNumber || $0 == " " }
        }.joined(separator: "\n")
    }

    /// The lease without exposing the window element.
    public static func currentReaderLease() -> Bool {
        guard let reader = try? readerWindow() else { return false }
        return hasReaderLease(reader)
    }

    public static func pid() -> pid_t {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).first?.processIdentifier ?? 0
    }

    private static func focusedWindow(_ application: AXUIElement) -> (
        title: String?, frame: CGRect?, role: String?
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
        let title = stringAttribute(window, kAXTitleAttribute)
        let role = stringAttribute(window, kAXRoleAttribute)
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
        return (title, frame, role)
    }

    private static func windowFlags(_ window: AXUIElement) -> (
        main: Bool, focused: Bool
    ) {
        (boolAttribute(window, kAXMainAttribute),
         boolAttribute(window, kAXFocusedAttribute))
    }

    private static func stringAttribute(
        _ element: AXUIElement, _ name: String
    ) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, name as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func boolAttribute(
        _ element: AXUIElement, _ name: String
    ) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, name as CFString, &value) == .success,
            let number = value as? NSNumber
        else { return false }
        return number.boolValue
    }

    private static func readerTitle(_ node: AXNode) -> String {
        for candidate in [node.title, node.label, node.value?.asText] {
            if let candidate, !candidate.isEmpty,
                candidate != "Unknown", candidate != "未知"
            {
                return candidate
            }
        }
        return "Apple Books"
    }

}
