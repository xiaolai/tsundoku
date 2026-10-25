import Foundation
import AppKit
import ApplicationServices
import KindleAX

public struct LivePage: Sendable, Equatable {
    public let state: String
    public let text: String
    public let title: String
    public let characters: Int
    public let windowFrame: AXNode.Frame?
    public let pageTextFrame: AXNode.Frame?
    public let endOfBook: Bool
    public let pageNumber: Int?
    public let pageCount: Int?
    /// The open book's ASIN, read from Kindle's own last-opened state. The
    /// reading view exposes no title while its chrome is hidden, so this is
    /// what keeps a conversation filed under the right book.
    public let bookID: String?
    public let chromeInsets: CaptureInsets?
    public let observedAt: Date

    public var isReading: Bool { state == "readingChromeHidden" }

    public init(
        state: String,
        text: String,
        title: String,
        characters: Int,
        windowFrame: AXNode.Frame?,
        pageTextFrame: AXNode.Frame?,
        endOfBook: Bool,
        pageNumber: Int?,
        pageCount: Int?,
        bookID: String? = nil,
        chromeInsets: CaptureInsets? = nil,
        observedAt: Date = Date()
    ) {
        self.state = state
        self.text = text
        self.title = title
        self.characters = characters
        self.windowFrame = windowFrame
        self.pageTextFrame = pageTextFrame
        self.endOfBook = endOfBook
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.bookID = bookID
        self.chromeInsets = chromeInsets
        self.observedAt = observedAt
    }
}

public enum KindleLiveError: Error, CustomStringConvertible, Sendable {
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
            "Kindle is not running."
        case .noWindow:
            "Kindle has no scene window."
        case .notReading(let state):
            "Kindle is showing \(state), not a live page."
        case .readFailed(let message):
            "Could not read Kindle: \(message)"
        }
    }
}

public enum KindleLive {
    public static let bundleID = "com.amazon.Lassen"

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

    /// Bring Kindle to the front.
    ///
    /// `NSRunningApplication.activate` alone is refused when the caller is a
    /// CLI child of SSH — the calling process is not active, so it has no
    /// activation rights, and Kindle stays behind another app while a display
    /// capture photographs whatever is on top. `openApplication` asks
    /// LaunchServices, which does raise the app.
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

    public static func currentPage() throws -> LivePage {
        guard AXIsProcessTrusted() else { throw KindleLiveError.notTrusted }
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else { throw KindleLiveError.notRunning }
        let recorder = AXRecorder(source: LiveAXSource())
        let application = AXUIElementCreateApplication(app.processIdentifier)
        do {
            guard let window = try recorder.findWindow(from: application) else {
                throw KindleLiveError.noWindow
            }
            // Read the identity on both sides of the text snapshot. A book
            // switch during the read would otherwise pair book A's text with
            // book B's ASIN; an unstable id is reported as unknown.
            let bookIDBefore = lastOpenedBookID()
            let tree = try recorder.capture(window)
            let bookIDAfter = lastOpenedBookID()
            let bookID =
                bookIDBefore == bookIDAfter ? bookIDAfter : nil
            let frame = try? recorder.source.frame(window)
            let number = pageNumber(tree)
            var chrome: CaptureInsets?
            if let frame {
                let windowRect = CGRect(
                    x: frame.x, y: frame.y,
                    width: frame.width, height: frame.height)
                let content = tree.pageTextRect.map {
                    CGRect(
                        x: $0.x, y: $0.y,
                        width: $0.width, height: $0.height)
                }
                chrome = try? PageFrame.chromeIntrusion(
                    tree: tree, window: windowRect, content: content)
            }
            return LivePage(
                state: tree.readerState.rawValue,
                text: tree.pageText ?? "",
                title: liveTitle(tree),
                characters: tree.pageText?.count ?? 0,
                windowFrame: frame,
                pageTextFrame: tree.pageTextRect,
                endOfBook: tree.isEndOfBook,
                pageNumber: number?.current,
                pageCount: number?.total,
                bookID: bookID,
                chromeInsets: chrome)
        } catch let error as KindleLiveError {
            throw error
        } catch {
            throw KindleLiveError.readFailed("\(error)")
        }
    }

    /// The ASIN of the book Kindle opened last, from its own preferences.
    ///
    /// The reading view removes the book's title together with the chrome, so
    /// the Accessibility tree says only "Kindle" for most of a session. The
    /// last-opened marker updates whenever a book is opened and is the only
    /// identity available in that state.
    public static func lastOpenedBookID() -> String? {
        // Read on every snapshot. A cache here could pair book A's ASIN with
        // book B's page text for the cache lifetime; the plist read is cheap
        // and the follow loop only asks once per poll.
        readLastOpenedBookID()
    }

    private static func readLastOpenedBookID() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.amazon.Lassen/Data/Library/"
                    + "Preferences/com.amazon.Lassen.plist")
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
            let raw = plist["WasLastOpenedBookId"] as? String
        else { return nil }
        return KindleLive.asin(fromBookID: raw)
    }

    /// Kindle stores `A:B075H364NC-0`; the ten-character ASIN is the middle.
    static func asin(fromBookID raw: String) -> String? {
        let tail =
            raw.split(separator: ":").last.map(String.init) ?? raw
        let asin =
            tail.split(separator: "-").first.map(String.init) ?? tail
        guard asin.count == 10,
            asin.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return asin
    }

    /// The scene window's frame in the global top-left AX space.
    public static func windowFrame() throws -> CGRect {
        guard AXIsProcessTrusted() else { throw KindleLiveError.notTrusted }
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else { throw KindleLiveError.notRunning }
        let recorder = AXRecorder(source: LiveAXSource())
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = try recorder.findWindow(from: axApp),
            let frame = try recorder.source.frame(window)
        else { throw KindleLiveError.noWindow }
        return CGRect(
            x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    /// Move and resize the scene window, then report the frame Kindle
    /// actually accepted. Used only for the pre-capture page setup.
    public static func setWindowFrame(_ frame: CGRect) throws -> CGRect {
        guard AXIsProcessTrusted() else { throw KindleLiveError.notTrusted }
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else { throw KindleLiveError.notRunning }
        let recorder = AXRecorder(source: LiveAXSource())
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = try recorder.findWindow(from: axApp) else {
            throw KindleLiveError.noWindow
        }
        var origin = CGPoint(x: frame.minX, y: frame.minY)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let position = AXValueCreate(.cgPoint, &origin),
            let dimensions = AXValueCreate(.cgSize, &size)
        else {
            throw KindleLiveError.readFailed("could not build a frame value")
        }
        let moved = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, position)
        let resized = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, dimensions)
        guard moved == .success, resized == .success else {
            throw KindleLiveError.readFailed("Kindle refused the window frame")
        }
        Thread.sleep(forTimeInterval: 0.35)
        guard let actual = try recorder.source.frame(window) else {
            throw KindleLiveError.noWindow
        }
        return CGRect(
            x: actual.x, y: actual.y,
            width: actual.width, height: actual.height)
    }

    public static func postKey(_ key: CGKeyCode) throws {
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else { throw KindleLiveError.notRunning }
        let pid = app.processIdentifier
        guard
            let down = CGEvent(
                keyboardEventSource: nil, virtualKey: key, keyDown: true),
            let up = CGEvent(
                keyboardEventSource: nil, virtualKey: key, keyDown: false)
        else { throw KindleLiveError.readFailed("could not make a key event") }
        down.postToPid(pid)
        up.postToPid(pid)
    }

    public static func turnForward() throws { try postKey(124) }
    public static func turnBackward() throws { try postKey(123) }
    public static func escape() throws { try postKey(53) }

    private static func pageNumber(_ tree: AXNode) -> (
        current: Int, total: Int?
    )? {
        // The full overlay was recorded exposing the location through
        // AXDescription (label) with no value.
        guard
            let node = tree.first(
                identifier: ReaderIdentifier.pageLocationText)
        else { return nil }
        guard
            let text = node.value?.asText ?? node.label,
            !text.isEmpty
        else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard let current = numbers.first else { return nil }
        return (current, numbers.count > 1 ? numbers[1] : nil)
    }

    private static func liveTitle(_ tree: AXNode) -> String {
        if let breadcrumb = tree.first(identifier: "ActiveBreadcrumb") {
            for candidate in [breadcrumb.label, breadcrumb.title,
                              breadcrumb.value?.asText]
            {
                if let value = candidate, !value.isEmpty {
                    return value
                }
            }
        }
        let candidates = tree.all {
            !($0.label ?? "").isEmpty && $0.role == "AXStaticText"
        }
        return candidates.first?.label ?? ""
    }
}
