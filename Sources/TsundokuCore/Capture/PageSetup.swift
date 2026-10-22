import CoreGraphics
import Foundation

/// The page the PDF should have. `asDisplayed` keeps whatever crop the
/// reader's window produces; `a4` sizes the window so the crop is A4.
public enum CapturePageSize: String, Sendable, Codable, CaseIterable {
    case asDisplayed
    case a4

    /// A4 in points. The PDF page at 1× is the pixel count divided by the
    /// display scale, so this is also the crop size in points.
    public var points: CGSize? {
        switch self {
        case .asDisplayed: nil
        case .a4: CGSize(width: 595.28, height: 841.89)
        }
    }

    public var title: String {
        switch self {
        case .asDisplayed: "As displayed"
        case .a4: "A4"
        }
    }
}

/// What to change before a capture. A nil font keeps the reader's setting.
public struct PageSetupRequest: Sendable, Equatable {
    public let pageSize: CapturePageSize
    public let font: Int?
    /// Books' text size is relative: +1 is one step larger, -1 one smaller.
    /// Books does not expose an absolute point size.
    public let booksFontSteps: Int
    /// Extra crop from the top of the captured page, in points.
    public let cropTop: Int
    /// Bottom crop in points. `nil` uses the reader default: Books 54 (the
    /// printed page number), Kindle 0 (automatic page-number detection).
    public let cropBottom: Int?

    public init(
        pageSize: CapturePageSize = .asDisplayed, font: Int? = nil,
        booksFontSteps: Int = 0, cropTop: Int = 0,
        cropBottom: Int? = nil
    ) {
        self.pageSize = pageSize
        self.font = font
        self.booksFontSteps = booksFontSteps
        self.cropTop = cropTop
        self.cropBottom = cropBottom
    }

    public var isRequested: Bool {
        pageSize != .asDisplayed || font != nil || booksFontSteps != 0
    }
}

public enum PageSetupError: Error, CustomStringConvertible, Sendable {
    case screenTooSmall(CGSize)
    case windowNotAccepted(expected: CGSize, actual: CGSize)
    case fontNotSet(expected: Int, actual: Int)
    case fontStepRefused(Int)
    case notConfigured
    case previousSetupUnrestored

    public var description: String {
        switch self {
        case .screenTooSmall(let page):
            "The screen cannot fit a \(Int(page.width))×\(Int(page.height)) "
                + "point page with the reader's chrome."
        case .windowNotAccepted(let expected, let actual):
            "Kindle accepted \(Int(actual.width))×\(Int(actual.height)) "
                + "instead of the requested "
                + "\(Int(expected.width))×\(Int(expected.height))."
        case .fontNotSet(let expected, let actual):
            "The font size did not reach \(expected); it reads \(actual)."
        case .fontStepRefused(let steps):
            "Apple Books did not change its text size for \(steps) step(s)."
        case .notConfigured:
            "The page setup needs the reader's live window and font."
        case .previousSetupUnrestored:
            "An earlier page setup could not be restored; refusing to "
                + "change the reader again."
        }
    }
}

public struct PageSetupOutcome: Sendable, Equatable {
    public let pageSize: CapturePageSize
    public let requestedFont: Int?
    public let originalFont: Int?
    public let finalFont: Int?
    public let originalWindow: CGRect?
    public let finalWindow: CGRect?
    public let restored: Bool
    public let reason: String?
    /// Books' relative text-size steps; nil for Kindle or when unchanged.
    public let fontSteps: Int?

    public init(
        pageSize: CapturePageSize, requestedFont: Int?, originalFont: Int?,
        finalFont: Int?, originalWindow: CGRect?, finalWindow: CGRect?,
        restored: Bool, reason: String?, fontSteps: Int? = nil
    ) {
        self.pageSize = pageSize
        self.requestedFont = requestedFont
        self.originalFont = originalFont
        self.finalFont = finalFont
        self.originalWindow = originalWindow
        self.finalWindow = finalWindow
        self.restored = restored
        self.reason = reason
        self.fontSteps = fontSteps
    }

    public var manifest: [String: Any] {
        var object: [String: Any] = [
            "pageSize": pageSize.rawValue,
            "requestedFont": requestedFont ?? NSNull(),
            "originalFont": originalFont ?? NSNull(),
            "finalFont": finalFont ?? NSNull(),
            "restored": restored,
            "reason": reason ?? NSNull(),
            "fontSteps": fontSteps ?? 0,
        ]
        if let originalWindow {
            object["originalWindow"] = Self.array(originalWindow)
        } else {
            object["originalWindow"] = NSNull()
        }
        if let finalWindow {
            object["finalWindow"] = Self.array(finalWindow)
        } else {
            object["finalWindow"] = NSNull()
        }
        return object
    }

    private static func array(_ rect: CGRect) -> [Double] {
        [
            Double(rect.origin.x), Double(rect.origin.y),
            Double(rect.size.width), Double(rect.size.height),
        ]
    }
}

/// A durable marker for a setup that changed the reader. It is written before
/// any change and cleared only after the window and the font are verified
/// back.
public struct PageSetupJournal: Sendable {
    public let url: URL

    public init(url: URL = PageSetupJournal.standardURL) {
        self.url = url
    }

    public static var standardURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Tsundoku/page-setup-journal.json")
    }

    public func save(window: CGRect, font: Int?) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var object: [String: Any] = [
            "window": [
                Double(window.origin.x), Double(window.origin.y),
                Double(window.size.width), Double(window.size.height),
            ]
        ]
        object["font"] = font ?? NSNull()
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    public func load() -> (window: CGRect?, font: Int?)? {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return nil }
        var window: CGRect?
        if let values = object["window"] as? [Double], values.count == 4 {
            window = CGRect(
                x: values[0], y: values[1],
                width: values[2], height: values[3])
        }
        let font = object["font"] as? Int
        guard window != nil || font != nil else { return nil }
        return (window, font)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Pure page-size arithmetic, so the window policy is testable without a
/// reader.
public enum PageSetupGeometry {
    public static let menuBarHeight = 25.0

    /// Find the pre-capture position again after a reflow. Font changes move
    /// a few pages at most, so the search is bounded and bidirectional.
    public static func restoreAnchor(_ key: String) throws -> Bool {
        func current() -> String {
            (try? KindleLive.currentPage())?.text ?? ""
        }
        if current().contains(key) { return true }
        for _ in 0..<10 {
            try KindleLive.turnForward()
            Thread.sleep(forTimeInterval: 0.6)
            if current().contains(key) { return true }
        }
        for _ in 0..<20 {
            try KindleLive.turnBackward()
            Thread.sleep(forTimeInterval: 0.6)
            if current().contains(key) { return true }
        }
        return false
    }

    public static func windowSize(
        for page: CGSize, insets: CaptureInsets
    ) -> CGSize {
        CGSize(
            width: page.width + insets.left + insets.right,
            height: page.height + insets.top + insets.bottom)
    }

    /// The target frame on the display that currently holds the window.
    /// Keeps the origin when the window fits, clamps it otherwise, and
    /// returns nil when the page cannot fit the display at all.
    public static func frame(
        for page: CGSize, insets: CaptureInsets, current: CGRect,
        displays: [CGRect]
    ) -> CGRect? {
        let size = windowSize(for: page, insets: insets)
        let centre = CGPoint(x: current.midX, y: current.midY)
        let display =
            displays.first { $0.contains(centre) }
            ?? displays.first { $0.intersects(current) }
            ?? displays.first
        guard let display else { return nil }
        let usableHeight = display.height - menuBarHeight
        guard size.width <= display.width, size.height <= usableHeight
        else { return nil }
        var origin = current.origin
        origin.x = min(
            max(origin.x, display.minX),
            display.maxX - size.width)
        origin.y = min(
            max(origin.y, display.minY + menuBarHeight),
            display.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

/// Applies the requested page size and font before a capture and restores the
/// reader afterwards. Every dependency is injectable so the state machine can
/// be tested without Kindle.
public final class KindlePageSetup {
    public typealias WindowReader = () throws -> CGRect
    public typealias WindowWriter = (CGRect) throws -> CGRect
    public typealias FontReader = () throws -> Int
    /// Sets the font and returns the value it had before the change.
    public typealias FontWriter = (Int) throws -> Int
    public typealias Reflow = () throws -> Void
    public typealias PageText = () throws -> String
    /// Turns pages until the key is on screen; reports whether it found it.
    public typealias AnchorRestore = (String) throws -> Bool

    public let request: PageSetupRequest
    public var pageSize: CapturePageSize { request.pageSize }

    private let journal: PageSetupJournal
    private let readWindow: WindowReader
    private let writeWindow: WindowWriter
    private let readFont: FontReader
    private let writeFont: FontWriter
    private let reflow: Reflow
    private let readPageText: PageText
    private let restoreAnchor: AnchorRestore
    private let displays: () -> [CGRect]
    private var anchorText: String?

    private var originalWindow: CGRect?
    private var originalFont: Int?
    private var finalWindow: CGRect?
    private var finalFont: Int?
    private var beginOutcome: PageSetupOutcome?
    private var storedRestore: PageSetupOutcome?

    public init(
        request: PageSetupRequest,
        journal: PageSetupJournal = PageSetupJournal(),
        readWindow: @escaping WindowReader = { try KindleLive.windowFrame() },
        writeWindow: @escaping WindowWriter = {
            try KindleLive.setWindowFrame($0)
        },
        readFont: @escaping FontReader = {
            try KindlePopularHighlights().fontSize()
        },
        writeFont: @escaping FontWriter = { value in
            try KindlePopularHighlights().setFontSize(value)
        },
        reflow: @escaping Reflow = {
            try KindleLive.turnForward()
            Thread.sleep(forTimeInterval: 0.7)
            try KindleLive.turnBackward()
            Thread.sleep(forTimeInterval: 0.7)
        },
        readPageText: @escaping PageText = {
            try KindleLive.currentPage().text
        },
        restoreAnchor: @escaping AnchorRestore = PageSetupGeometry.restoreAnchor,
        displays: @escaping () -> [CGRect] = { PageFrame.displayBounds() }
    ) {
        self.request = request
        self.journal = journal
        self.readWindow = readWindow
        self.writeWindow = writeWindow
        self.readFont = readFont
        self.writeFont = writeFont
        self.reflow = reflow
        self.readPageText = readPageText
        self.restoreAnchor = restoreAnchor
        self.displays = displays
    }

    /// The outcome available while the capture runs: the begin state before
    /// `restore()`, the verified final state after it.
    public var outcome: PageSetupOutcome? {
        storedRestore ?? beginOutcome
    }

    public func begin() throws -> PageSetupOutcome {
        if beginOutcome != nil { return beginOutcome! }
        // A journal older than this run means a previous setup never
        // verified its restore. Put the saved state back first; never
        // overwrite that record with a new "original".
        if journal.load() != nil, !recoverPendingJournal() {
            throw PageSetupError.previousSetupUnrestored
        }
        // The position before the font change, so the restore can find it
        // again after the reflow.
        anchorText = try? readPageText()
        let window = try readWindow()
        originalWindow = window
        let wantedFont = request.font
        var currentFont: Int?
        if wantedFont != nil {
            currentFont = try readFont()
            originalFont = currentFont
        }
        if !request.isRequested {
            let outcome = PageSetupOutcome(
                pageSize: request.pageSize, requestedFont: wantedFont,
                originalFont: nil, finalFont: nil, originalWindow: window,
                finalWindow: window, restored: true,
                reason: "nothing requested")
            beginOutcome = outcome
            return outcome
        }
        do {
            try journal.save(window: window, font: currentFont)
            var targetWindow = window
            if let page = request.pageSize.points {
                guard
                    let frame = PageSetupGeometry.frame(
                        for: page, insets: .measured, current: window,
                        displays: displays())
                else {
                    throw PageSetupError.screenTooSmall(page)
                }
                let actual = try writeWindow(frame)
                guard
                    abs(actual.width - frame.width) <= 1.5,
                    abs(actual.height - frame.height) <= 1.5
                else {
                    throw PageSetupError.windowNotAccepted(
                        expected: frame.size, actual: actual.size)
                }
                targetWindow = actual
                finalWindow = actual
            }
            if let wantedFont {
                if currentFont == wantedFont {
                    finalFont = wantedFont
                } else {
                    let before = try writeFont(wantedFont)
                    originalFont = before
                    if before != wantedFont { try reflow() }
                    finalFont = wantedFont
                }
            }
            let outcome = PageSetupOutcome(
                pageSize: request.pageSize, requestedFont: wantedFont,
                originalFont: originalFont, finalFont: finalFont,
                originalWindow: originalWindow, finalWindow: targetWindow,
                restored: false, reason: nil)
            beginOutcome = outcome
            return outcome
        } catch {
            _ = restore()
            throw error
        }
    }

    private func recoverPendingJournal() -> Bool {
        guard let saved = journal.load() else { return true }
        var restored = true
        if let font = saved.font {
            do {
                let before = try writeFont(font)
                if before != font { try reflow() }
            } catch {
                restored = false
            }
        }
        if let window = saved.window {
            do {
                let actual = try writeWindow(window)
                if abs(actual.width - window.width) > 1
                    || abs(actual.height - window.height) > 1
                {
                    restored = false
                }
            } catch {
                restored = false
            }
        }
        if restored { journal.clear() }
        return restored
    }

    public func restore() -> PageSetupOutcome {
        if let storedRestore { return storedRestore }
        guard let originalWindow else {
            let outcome = PageSetupOutcome(
                pageSize: request.pageSize, requestedFont: request.font,
                originalFont: nil, finalFont: nil, originalWindow: nil,
                finalWindow: nil, restored: true, reason: "nothing to restore")
            storedRestore = outcome
            return outcome
        }
        var problems: [String] = []
        if let originalFont, let finalFont, finalFont != originalFont {
            do {
                let before = try writeFont(originalFont)
                if before != originalFont { try reflow() }
            } catch {
                problems.append("the font could not be restored: \(error)")
            }
        }
        do {
            let actual = try writeWindow(originalWindow)
            if abs(actual.origin.x - originalWindow.origin.x) > 1
                || abs(actual.origin.y - originalWindow.origin.y) > 1
                || abs(actual.width - originalWindow.width) > 1
                || abs(actual.height - originalWindow.height) > 1
            {
                problems.append("the window did not return to its frame")
            }
        } catch {
            problems.append("the window could not be restored: \(error)")
        }
        if let anchorText, !anchorText.isEmpty {
            let key = String(anchorText.prefix(30))
            if (try? restoreAnchor(key)) != true {
                problems.append("the reading position could not be restored")
            }
        }
        if problems.isEmpty { journal.clear() }
        let outcome = PageSetupOutcome(
            pageSize: request.pageSize, requestedFont: request.font,
            originalFont: originalFont, finalFont: finalFont,
            originalWindow: originalWindow, finalWindow: finalWindow,
            restored: problems.isEmpty,
            reason: problems.isEmpty ? nil : problems.joined(separator: "; "))
        storedRestore = outcome
        return outcome
    }

    /// On launch, restore a setup left changed by a crash. The journal is
    /// cleared only after the window and font verify back.
    public static func recoverIfNeeded(
        journal: PageSetupJournal = PageSetupJournal(),
        readWindow: @escaping WindowReader = { try KindleLive.windowFrame() },
        writeWindow: @escaping WindowWriter = {
            try KindleLive.setWindowFrame($0)
        },
        readFont: @escaping FontReader = {
            try KindlePopularHighlights().fontSize()
        },
        writeFont: @escaping FontWriter = { value in
            try KindlePopularHighlights().setFontSize(value)
        },
        reflow: @escaping Reflow = {
            try KindleLive.turnForward()
            Thread.sleep(forTimeInterval: 0.7)
            try KindleLive.turnBackward()
            Thread.sleep(forTimeInterval: 0.7)
        }
    ) -> PageSetupOutcome? {
        guard let saved = journal.load() else { return nil }
        var problems: [String] = []
        if let font = saved.font {
            do {
                let before = try writeFont(font)
                if before != font { try reflow() }
            } catch {
                problems.append("the font could not be restored: \(error)")
            }
        }
        if let window = saved.window {
            do {
                let actual = try writeWindow(window)
                if abs(actual.width - window.width) > 1
                    || abs(actual.height - window.height) > 1
                {
                    problems.append("the window did not verify")
                }
            } catch {
                problems.append("the window could not be restored: \(error)")
            }
        }
        if problems.isEmpty { journal.clear() }
        return PageSetupOutcome(
            pageSize: .asDisplayed, requestedFont: saved.font,
            originalFont: saved.font, finalFont: saved.font,
            originalWindow: saved.window, finalWindow: saved.window,
            restored: problems.isEmpty,
            reason: problems.isEmpty ? nil : problems.joined(separator: "; "))
    }
}
