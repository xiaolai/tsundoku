import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import KindleAX

public enum CleanPageError: Error, CustomStringConvertible, Sendable {
    case notTrusted
    case notRunning
    case notFrontmost
    case notReading
    case noWindow
    case panelUnavailable
    case controlMissing
    case stateUnreadable
    case toggleFailed(expected: Bool, actual: Bool?)
    case closeFailed
    case fontControlMissing
    case fontSizeOutOfRange(Int)
    case fontSizeNotReached(target: Int, actual: Int)

    public var description: String {
        switch self {
        case .notTrusted:
            "Accessibility permission is not granted."
        case .notRunning:
            "Kindle is not running."
        case .notFrontmost:
            "Kindle is not frontmost; refusing to click in another app."
        case .notReading:
            "Kindle is not showing a book page; refusing to click the window."
        case .noWindow:
            "Kindle has no reader window."
        case .panelUnavailable:
            "The Reading Settings panel could not be opened."
        case .controlMissing:
            "The Popular Highlights control was not found."
        case .stateUnreadable:
            "The Popular Highlights state could not be read."
        case .toggleFailed(let expected, let actual):
            "Popular Highlights did not become \(expected ? "on" : "off"); "
                + "it reads \(actual.map { $0 ? "on" : "off" } ?? "unknown")."
        case .closeFailed:
            "The Reading Settings panel could not be closed."
        case .fontControlMissing:
            "The font size control was not found."
        case .fontSizeOutOfRange(let value):
            "The font size must be between 0 and 17, not \(value)."
        case .fontSizeNotReached(let target, let actual):
            "The font size did not reach \(target); it reads \(actual)."
        }
    }
}

/// The clean-page control seam. Tests use a fake; production uses Kindle AX.
public protocol PopularHighlightsPanel: Sendable {
    func state() throws -> Bool
    func set(_ on: Bool) throws
}

/// Finds the Aa → More → Popular Highlights checkbox and toggles it through
/// the driver's guarded action runner. No screen coordinates are used for the
/// control itself; the only click is the page-centre gesture that reveals the
/// toolbar.
public struct KindlePopularHighlights: PopularHighlightsPanel {
    public init() {}

    public func state() throws -> Bool {
        try withPanel(tab: .more) { box in
            try readControl(box)
        }
    }

    public func set(_ on: Bool) throws {
        try withPanel(tab: .more) { box in
            let current = try readControl(box)
            guard current != on else { return }
            let expected = current ? "1" : "0"
            guard KindleLive.isFrontmost() else {
                throw CleanPageError.notFrontmost
            }
            let outcome = try box.runner.perform(
                identifier: "Popular Highlights", action: AXAction.press,
                expecting: expected, from: box.window)
            trace("toggle outcome: \(outcome)")
            guard case .performed = outcome else {
                throw CleanPageError.toggleFailed(expected: on, actual: current)
            }
            // The checkbox updates asynchronously; a read taken in the same
            // turn as the press still shows the old value.
            let after = waitForValue(box, on, timeout: 1.5)
            trace("value after the toggle: \(String(describing: after))")
            guard after == on else {
                throw CleanPageError.toggleFailed(expected: on, actual: after)
            }
        }
    }

    private struct Box {
        let recorder: AXRecorder<LiveAXSource>
        let runner: AXActionRunner<LiveAXSource>
        let window: AXUIElement
    }

    /// Set `TSUNDOKU_CLEAN_PAGE_TRACE=1` to see each AX step on stderr. It is
    /// the only way to debug the panel on a host without a GUI session.
    private func trace(_ message: @autoclosure () -> String) {
        guard
            ProcessInfo.processInfo.environment["TSUNDOKU_CLEAN_PAGE_TRACE"]
                == "1"
        else { return }
        FileHandle.standardError.write(
            Data(("[clean-page] " + message() + "\n").utf8))
    }

    /// The Aa sheet's font size control. It is the slider's own value, the
    /// same 0–17 scale the Font tab shows.
    public func fontSize() throws -> Int {
        try withPanel(tab: .font) { box in
            try readFontSize(box)
        }
    }

    /// Set the Aa font size and return the value it had before the change.
    /// The set loop reads the slider back, so no separate verify session is
    /// needed. Kindle does not re-render the page until it is turned; the
    /// caller owns that reflow and the restore.
    @discardableResult
    public func setFontSize(_ value: Int) throws -> Int {
        guard (0...17).contains(value) else {
            throw CleanPageError.fontSizeOutOfRange(value)
        }
        return try withPanel(tab: .font) { box in
            trace("setFontSize(\(value)) in the panel")
            // The tab bar reports its controls before the sheet finishes
            // animating; a press sent during the animation can dismiss the
            // content the loop is about to read.
            Thread.sleep(forTimeInterval: 0.5)
            var original: Int?
            for _ in 0..<40 {
                guard let current = waitForFontSize(box, timeout: 1.0) else {
                    trace("the font slider disappeared")
                    throw CleanPageError.fontControlMissing
                }
                if original == nil { original = current }
                trace("font slider reads \(current)")
                if current == value { return original ?? current }
                let identifier =
                    current < value
                    ? "increase-towards-17-Font Size"
                    : "decrease-towards-0-Font Size"
                let outcome = try box.runner.perform(
                    identifier: identifier, action: AXAction.press,
                    expecting: "", from: box.window)
                trace("press \(identifier): \(outcome)")
                Thread.sleep(forTimeInterval: 0.20)
            }
            throw CleanPageError.fontSizeNotReached(
                target: value,
                actual: waitForFontSize(box, timeout: 1.0) ?? -1)
        }
    }

    private enum PanelTab {
        case more
        case font
    }

    private func withPanel<T>(
        tab: PanelTab, _ body: (Box) throws -> T
    ) throws -> T {
        guard AXIsProcessTrusted() else { throw CleanPageError.notTrusted }
        guard KindleLive.isRunning() else { throw CleanPageError.notRunning }
        KindleLive.activate()
        guard KindleLive.isFrontmost() else {
            throw CleanPageError.notFrontmost
        }
        // The toolbar reveal clicks the window centre; on the library surface
        // that lands on a book cell and can open a book.
        guard let live = try? KindleLive.currentPage(),
            live.state != "notReading"
        else { throw CleanPageError.notReading }
        let recorder = AXRecorder(source: LiveAXSource())
        let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: KindleLive.bundleID).first
        guard let app else { throw CleanPageError.notRunning }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = try recorder.findWindow(from: axApp) else {
            throw CleanPageError.noWindow
        }
        let box = Box(
            recorder: recorder, runner: AXActionRunner(recorder: recorder),
            window: window)
        // Cleanup is armed before the panel opens: a failure inside
        // `openPanel` (a sheet that opened but whose tab never appeared) must
        // not leave the sheet or toolbar up.
        var cleaned = false
        defer {
            if !cleaned {
                try? closePanel(box)
                ensureChromeHidden(box)
                // Kindle ignores a fresh open while the sheet is still
                // animating out; a guard call that reads then toggles
                // reopens immediately.
                Thread.sleep(forTimeInterval: 0.45)
            }
        }
        try openPanel(box, tab: tab)
        let result = try body(box)
        // On the success path a close failure is part of the result, not
        // cleanup to be swallowed.
        try closePanel(box)
        cleaned = true
        ensureChromeHidden(box)
        Thread.sleep(forTimeInterval: 0.45)
        return result
    }

    /// The toolbar's own "Reading Settings" button is the reliable signal that
    /// the chrome is up; `readerState` misreports the panel as chrome-hidden.
    /// A centre click toggles the toolbar, so click only while it is up.
    private func ensureChromeHidden(_ box: Box) {
        for _ in 0..<2 {
            let toolbar =
                (try? box.recorder.elements(
                    identifier: "Reading Settings", from: box.window))
                ?? []
            if toolbar.isEmpty { return }
            // A centre click toggles the chrome but can land on a text link;
            // the page's bottom margin is blank.
            let points = revealPoints(box)
            let point = points.count > 1 ? points[1] : (points.first ?? .zero)
            revealChrome(box, at: point)
            Thread.sleep(forTimeInterval: 0.45)
        }
    }

    /// Candidate taps for revealing the toolbar, safest first: the page's
    /// top margin, its bottom margin, then the centre. A centre tap can land
    /// on a hyperlink, which opens a browser instead of the toolbar.
    private func revealPoints(_ box: Box) -> [CGPoint] {
        guard let frame = try? box.recorder.source.frame(box.window) else {
            return []
        }
        let window = CGRect(
            x: frame.x, y: frame.y,
            width: frame.width, height: frame.height)
        var points: [CGPoint] = []
        if let live = try? KindleLive.currentPage(),
            let text = live.pageTextFrame
        {
            let topY = max(window.minY + 8, text.y - 8)
            if topY < text.y {
                points.append(CGPoint(x: window.midX, y: topY))
            }
            let bottomY = min(text.y + text.height + 8, window.maxY - 8)
            if bottomY > text.y + text.height {
                points.append(CGPoint(x: window.midX, y: bottomY))
            }
        }
        points.append(CGPoint(x: window.midX, y: window.midY))
        return points
    }

    private func openPanel(_ box: Box, tab: PanelTab) throws {
        if isPanelOpen(box) {
            trace("panel already open")
            try selectTab(tab, box)
            return
        }
        let points = revealPoints(box)
        var opened = false
        if case .performed = (try? press("Reading Settings", in: box))
            ?? .notFound
        {
            opened = true
            trace("pressed Reading Settings")
        } else {
            // With the chrome hidden, the toolbar button does not exist yet.
            // Reveal it at each candidate point until the button appears.
            for point in points {
                trace(
                    "revealing chrome at \(Int(point.x)),\(Int(point.y))")
                revealChrome(box, at: point)
                if case .performed = (try? press("Reading Settings", in: box))
                    ?? .notFound
                {
                    opened = true
                    break
                }
                // A link tap can take focus; ask LaunchServices again.
                if !KindleLive.isFrontmost() { KindleLive.activate() }
            }
        }
        if opened, wait(2.5, { isPanelOpen(box) }) {
            trace("the panel opened")
            try selectTab(tab, box)
            return
        }
        trace("the panel did not open")
        // A press issued while a sheet was still closing is ignored; try the
        // candidate points once more before giving up.
        for point in points {
            if !KindleLive.isFrontmost() { KindleLive.activate() }
            revealChrome(box, at: point)
            if case .performed = (try? press("Reading Settings", in: box))
                ?? .notFound,
                wait(2.5, { isPanelOpen(box) })
            {
                trace("the panel opened on the retry")
                try selectTab(tab, box)
                return
            }
        }
        throw CleanPageError.panelUnavailable
    }

    private func selectTab(_ tab: PanelTab, _ box: Box) throws {
        // The sheet reports its tab bar before the entrance animation ends;
        // a press sent during it is ignored and can dismiss the sheet.
        Thread.sleep(forTimeInterval: 0.6)
        switch tab {
        case .more: try selectMoreTab(box)
        case .font: try selectFontTab(box)
        }
    }

    private func selectFontTab(_ box: Box) throws {
        if (try? readFontSize(box)) != nil {
            trace("the Font tab is already selected")
            return
        }
        for attempt in 0..<2 {
            let outcome = (try? press("Font", in: box)) ?? .notFound
            trace("pressed Font (attempt \(attempt + 1)): \(outcome)")
            if wait(2.0, { (try? readFontSize(box)) != nil }) {
                return
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        throw CleanPageError.controlMissing
    }

    /// The panel rebuilds its tree while a size change animates; a read can
    /// miss the slider for a moment.
    private func waitForFontSize(
        _ box: Box, timeout: TimeInterval
    ) -> Int? {
        let deadline = Date().addingTimeInterval(max(timeout, 2.0))
        repeat {
            if let value = try? readFontSize(box) { return value }
            Thread.sleep(forTimeInterval: 0.10)
        } while Date() < deadline
        return nil
    }

    private func readFontSize(_ box: Box) throws -> Int {
        guard
            let control = try box.recorder.elements(
                identifier: "AaSeekbar-Font Size", from: box.window).first
        else {
            throw CleanPageError.fontControlMissing
        }
        let scalar = try box.recorder.source.value(control)
        // The slider's value is an AX number, not text; `asText` returns nil
        // for every non-string and silently hid the setting.
        let value: Int?
        if let number = scalar?.asNumber {
            value = Int(number.rounded())
        } else if let text = scalar?.asText {
            value = Int(text)
        } else {
            value = nil
        }
        guard let value else {
            throw CleanPageError.stateUnreadable
        }
        return value
    }

    private func selectMoreTab(_ box: Box) throws {
        if isMoreSelected(box) {
            trace("the More tab is already selected")
            return
        }
        // The tab bar ignores a press while the sheet is still animating in,
        // so a press that reports success is not proof the tab switched.
        for attempt in 0..<2 {
            let outcome = (try? press("More", in: box)) ?? .notFound
            trace("pressed More (attempt \(attempt + 1)): \(outcome)")
            if wait(2.0, { isMoreSelected(box) }) {
                trace("the More tab is selected")
                return
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        throw CleanPageError.controlMissing
    }

    private func closePanel(_ box: Box) throws {
        if !isPanelOpen(box) { return }
        let outcome = (try? press("BottomSheetBackgroundView", in: box))
            ?? .notFound
        if case .performed = outcome {
            // The background press is the named close path.
        } else {
            trace("the background press failed (\(outcome)); using escape")
            try? KindleLive.escape()
        }
        guard wait(2.0, { !isPanelOpen(box) }) else {
            throw CleanPageError.closeFailed
        }
    }

    /// Press an element after reading the value the guard will check against,
    /// so a control that carries a value is not refused for expect-nothing.
    /// An element with no value of its own is named by the empty string, which
    /// is what the runner requires instead of an omitted expectation.
    private func press(
        _ identifier: String, in box: Box
    ) throws -> AXActionOutcome {
        guard
            let element = try box.recorder.elements(
                identifier: identifier, from: box.window).first
        else { return .notFound }
        // An AX press is addressed to Kindle's element, but acting while the
        // user is in another app is still a surprise; refuse it.
        guard KindleLive.isFrontmost() else {
            throw CleanPageError.notFrontmost
        }
        let value = (try box.recorder.source.value(element))?.asText ?? ""
        return try box.runner.perform(
            identifier: identifier, action: AXAction.press,
            expecting: value, from: box.window)
    }

    private func wait(
        _ timeout: TimeInterval, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    private func isPanelOpen(_ box: Box) -> Bool {
        (try? box.recorder.elements(
            identifier: "More", from: box.window))?.isEmpty == false
    }

    private func isMoreSelected(_ box: Box) -> Bool {
        guard let control = try? box.recorder.elements(
            identifier: "Popular Highlights", from: box.window)
        else { return false }
        return !control.isEmpty
    }

    private func waitForValue(
        _ box: Box, _ wanted: Bool, timeout: TimeInterval
    ) -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Bool?
        repeat {
            if let current = try? readControl(box) {
                last = current
                if current == wanted { return current }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return last
    }

    private func readControl(_ box: Box) throws -> Bool {
        guard
            try box.recorder.elements(
                identifier: "Popular Highlights", from: box.window).isEmpty
                == false
        else {
            throw CleanPageError.controlMissing
        }
        let scroll = (try? box.runner.perform(
            identifier: "Popular Highlights",
            action: AXAction.scrollToVisible, expecting: nil,
            from: box.window)) ?? .notFound
        guard
            let control = try box.recorder.elements(
                identifier: "Popular Highlights", from: box.window).first
        else {
            throw CleanPageError.controlMissing
        }
        if case .performed = scroll {
            // The panel animates the control into place; a press sent while
            // it is still moving lands on the old hit area.
            Thread.sleep(forTimeInterval: 0.30)
            let frame = try? box.recorder.source.frame(control)
            trace(
                "scrolled to the control: "
                    + "\(frame.map { "y=\($0.y) h=\($0.height)" } ?? "no frame")")
        } else {
            trace("the scroll did not run: \(scroll)")
        }
        let scalar = try? box.recorder.source.value(control)
        guard let text = scalar?.asText else {
            trace("the control has no value")
            throw CleanPageError.stateUnreadable
        }
        trace("control value: \(text)")
        switch text {
        case "1": return true
        case "0": return false
        default: throw CleanPageError.stateUnreadable
        }
    }

    private func revealChrome(_ box: Box, at center: CGPoint) {
        guard KindleLive.isFrontmost() else { return }
        let original = CGEvent(source: nil)?.location
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        post(.mouseMoved, center)
        // Measured against Kindle 7.69: a press fewer than ~150 ms after the
        // synthetic move is ignored, so the timeline matches the toolkit's
        // proven pointer click rather than a tighter one.
        Thread.sleep(forTimeInterval: 0.15)
        // The click is global: if focus moved during the sleep it would land
        // in another app.
        guard KindleLive.isFrontmost() else { return }
        post(.leftMouseDown, center)
        post(.leftMouseUp, center)
        Thread.sleep(forTimeInterval: 0.40)
        if let original { post(.mouseMoved, original) }
        Thread.sleep(forTimeInterval: 0.30)
    }
}

public struct CleanPageOutcome: Sendable, Equatable {
    public let original: Bool?
    public let final: Bool?
    public let changed: Bool
    public let restored: Bool
    public let reason: String?

    public init(
        original: Bool?, final: Bool?, changed: Bool, restored: Bool,
        reason: String?
    ) {
        self.original = original
        self.final = final
        self.changed = changed
        self.restored = restored
        self.reason = reason
    }
}

/// Durable "we turned it off" marker. It contains no annotation data.
public struct CleanPageJournal: Sendable {
    public let url: URL

    public init(url: URL = CleanPageJournal.standardURL) {
        self.url = url
    }

    public static var standardURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Tsundoku/clean-page-journal.json")
    }

    public func save(original: Bool) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["original": original], options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    public func load() -> Bool? {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let original = object["original"] as? Bool
        else { return nil }
        return original
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Turns Popular Highlights off before a capture and restores the exact state
/// afterwards. It journals before changing anything, so a crash can recover.
public final class CleanPageGuard {
    private let panel: any PopularHighlightsPanel
    private let journal: CleanPageJournal
    private var original: Bool?
    private var changed = false
    private var restoreOutcome: CleanPageOutcome?

    public init(
        panel: any PopularHighlightsPanel,
        journal: CleanPageJournal = CleanPageJournal()
    ) {
        self.panel = panel
        self.journal = journal
    }

    public func begin() throws -> CleanPageOutcome {
        let original = try panel.state()
        self.original = original
        guard original else {
            return CleanPageOutcome(
                original: false, final: false, changed: false,
                restored: true, reason: "already off")
        }
        try journal.save(original: true)
        do {
            try panel.set(false)
            changed = true
            let final = try panel.state()
            guard final == false else {
                throw CleanPageError.toggleFailed(
                    expected: false, actual: final)
            }
            return CleanPageOutcome(
                original: true, final: false, changed: true,
                restored: false, reason: nil)
        } catch {
            // The press may have landed even though the call failed, so put
            // the state back rather than trusting `changed`. The journal is
            // cleared only once the original state is verified.
            let current = try? panel.state()
            if current == nil || current != original {
                try? panel.set(original)
            }
            if (try? panel.state()) == original {
                changed = false
                journal.clear()
            } else {
                changed = true
            }
            throw error
        }
    }

    public func restore() -> CleanPageOutcome {
        if let restoreOutcome { return restoreOutcome }
        guard changed, let original else {
            let result = CleanPageOutcome(
                original: original, final: nil, changed: false,
                restored: true, reason: "nothing to restore")
            restoreOutcome = result
            return result
        }
        do {
            let current = try panel.state()
            if current == original {
                // Already back to the opening state, whether by the user or
                // by a previous restore. Nothing to overwrite.
                journal.clear()
                let result = CleanPageOutcome(
                    original: original, final: current, changed: true,
                    restored: true, reason: "already restored")
                restoreOutcome = result
                return result
            }
            try panel.set(original)
            let final = try panel.state()
            if final == original {
                journal.clear()
                let result = CleanPageOutcome(
                    original: original, final: final, changed: true,
                    restored: true, reason: nil)
                restoreOutcome = result
                return result
            }
            let result = CleanPageOutcome(
                original: original, final: final, changed: true,
                restored: false, reason: "restore did not take")
            restoreOutcome = result
            return result
        } catch {
            let result = CleanPageOutcome(
                original: original, final: nil, changed: true,
                restored: false, reason: "\(error)")
            restoreOutcome = result
            return result
        }
    }

    /// On launch, restore a state left changed by a crash. The journal is
    /// cleared only after a verified restore.
    public static func recoverIfNeeded(
        panel: any PopularHighlightsPanel,
        journal: CleanPageJournal = CleanPageJournal()
    ) -> CleanPageOutcome? {
        guard let original = journal.load() else { return nil }
        do {
            let current = try panel.state()
            if current != original {
                try panel.set(original)
            }
            let final = try panel.state()
            if final == original { journal.clear() }
            return CleanPageOutcome(
                original: original, final: final, changed: true,
                restored: final == original,
                reason: final == original ? nil : "recovery did not take")
        } catch {
            return CleanPageOutcome(
                original: original, final: nil, changed: true,
                restored: false, reason: "\(error)")
        }
    }
}
