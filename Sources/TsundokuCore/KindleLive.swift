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
            let tree = try recorder.capture(window)
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
                chromeInsets: chrome)
        } catch let error as KindleLiveError {
            throw error
        } catch {
            throw KindleLiveError.readFailed("\(error)")
        }
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
