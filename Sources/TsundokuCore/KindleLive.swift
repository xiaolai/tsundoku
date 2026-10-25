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
    case readFailed(String)

    public var description: String {
        switch self {
        case .notTrusted:
            "Accessibility permission is not granted to Tsundoku."
        case .notRunning:
            "Kindle is not running."
        case .noWindow:
            "Kindle has no scene window."
        case .readFailed(let message):
            "Could not read Kindle: \(message)"
        }
    }
}

/// Carries the activation result across LaunchServices' callback, and undoes
/// a late activation whose caller already gave up. LaunchServices has no
/// cancellation: once the open request is queued, the only way to take back
/// its effect is to restore the app that was frontmost before it.
private final class ActivationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private let previous: NSRunningApplication?
    private let kindle: NSRunningApplication
    private var storedError: Error?
    private var completed = false
    private var abandoned = false

    init(previous: NSRunningApplication?, kindle: NSRunningApplication) {
        self.previous = previous
        self.kindle = kindle
    }

    func finish(_ error: Error?) {
        lock.lock()
        completed = true
        storedError = error
        let undo = abandoned
        lock.unlock()
        if undo { restorePrevious() }
    }

    /// Abandon the wait. True means the completion already ran, so its result
    /// is still usable despite the semaphore timeout.
    func abandon() -> Bool {
        lock.lock()
        if completed {
            lock.unlock()
            return true
        }
        abandoned = true
        lock.unlock()
        return false
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    private func restorePrevious() {
        guard
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == KindleLive.bundleID
        else { return }
        // Hiding Kindle returns focus to whichever app was behind it, even
        // when the recorded previous app has quit. Only if the hide is
        // refused does the recorded app have to take focus back.
        if kindle.hide() { return }
        guard let previous, !previous.isTerminated,
            previous.activate(options: [])
        else {
            TsundokuDiagnostics.shared.event(
                "kindle_activation_undo_failed",
                ["reason": "no app accepted focus"])
            return
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
    public static func activate() throws {
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else { throw KindleLiveError.notRunning }
        if app.isActive { return }
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let outcome = ActivationOutcome(
                previous: NSWorkspace.shared.frontmostApplication,
                kindle: app)
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(
                at: url, configuration: configuration
            ) { _, error in
                outcome.finish(error)
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 3) != .success {
                // A completion that raced the deadline still counts; one
                // that has not run is abandoned and undoes its activation
                // whenever LaunchServices delivers it.
                guard outcome.abandon() else {
                    throw KindleLiveError.readFailed(
                        "Kindle did not answer the activation request within "
                            + "3 seconds.")
                }
            }
            if let error = outcome.error {
                throw KindleLiveError.readFailed(
                    "Could not activate Kindle: "
                        + error.localizedDescription)
            }
        }
        if !app.isActive {
            app.activate(options: [.activateAllWindows])
        }
        let deadline = Date().addingTimeInterval(1.5)
        while !app.isActive, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard app.isActive else {
            throw KindleLiveError.readFailed(
                "Kindle did not become the frontmost app.")
        }
    }

    /// The trusted Kindle process's recorder and scene window.
    private static func scene() throws -> (
        recorder: AXRecorder<LiveAXSource>, window: AXUIElement
    ) {
        guard AXIsProcessTrusted() else { throw KindleLiveError.notTrusted }
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first
        else { throw KindleLiveError.notRunning }
        let recorder = AXRecorder(source: LiveAXSource())
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = try recorder.findWindow(from: application) else {
            throw KindleLiveError.noWindow
        }
        return (recorder, window)
    }

    public static func currentPage() throws -> LivePage {
        do {
            let (recorder, window) = try scene()
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
        let (recorder, window) = try scene()
        guard let frame = try recorder.source.frame(window) else {
            throw KindleLiveError.noWindow
        }
        return CGRect(
            x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    /// Move and resize the scene window, then report the frame Kindle
    /// actually accepted. Used only for the pre-capture page setup.
    public static func setWindowFrame(_ frame: CGRect) throws -> CGRect {
        let (recorder, window) = try scene()
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
        return parsePageLocation(text)
    }

    /// Read `current` and `total` from Kindle's location label. Kindle groups
    /// thousands with a comma, a period or a space (`Page 1,234 of 2,000`);
    /// splitting on every non-digit would read that as 1 of 234. Only a token
    /// that is entirely digits once its grouping separators are removed
    /// counts, so other numbers in the label cannot shift the pair. A
    /// space-grouped pair is joined inside its side of "of", never across it.
    static func parsePageLocation(_ text: String) -> (
        current: Int, total: Int?
    )? {
        // Match each number with only its own grouping separators, so
        // "12/100" and "第12页，共100页" stay two numbers while
        // "1,234" stays one. Anything that is not a digit or a grouping
        // separator ends the number.
        let pattern =
            "\\d(?:[\\d.,'\u{2019} \u{00A0}\u{202F}\u{2009}]*\\d)?"
        guard
            let regex = try? NSRegularExpression(pattern: pattern)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var numbers: [Int] = []
        for match in regex.matches(in: text, range: range) {
            guard let tokenRange = Range(match.range, in: text) else {
                continue
            }
            numbers.append(
                contentsOf: numbersInToken(String(text[tokenRange])))
        }
        guard let current = numbers.first else { return nil }
        return (current, numbers.count > 1 ? numbers[1] : nil)
    }

    /// One matched number token. Separators join the token into one number
    /// only when every group after the first has three digits; otherwise the
    /// parts are separate numbers that happened to sit inside one match.
    private static func numbersInToken(_ token: String) -> [Int] {
        let separators = CharacterSet(charactersIn: ".,'\u{2019}")
            .union(.whitespaces)
        let parts = token.components(separatedBy: separators)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [] }
        // Western grouping repeats three digits; Indian grouping ends in
        // three with two-digit groups before it (1,23,456). Both name one
        // number, never a page pair.
        if parts.count > 1,
            parts.last?.count == 3,
            parts.dropFirst().allSatisfy({
                $0.count == 2 || $0.count == 3
            }),
            parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
            let value = Int(parts.joined())
        {
            return [value]
        }
        return parts.compactMap { part in
            part.allSatisfy(\.isNumber) ? Int(part) : nil
        }
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
