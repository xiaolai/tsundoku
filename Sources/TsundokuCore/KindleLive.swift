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

    /// The reader window's minimized state. A minimized window can still be
    /// photographed, but it has no main-window routing for page-turn keys.
    public static func isWindowMinimized() throws -> Bool {
        let (_, window) = try scene()
        return try boolAttribute(window, kAXMinimizedAttribute)
    }

    public static func isWindowMain() throws -> Bool {
        let (_, window) = try scene()
        return try boolAttribute(window, kAXMainAttribute)
    }

    /// Restore the main-window status without activating Kindle. This is the
    /// operation that makes PID-directed page turns reach the reader after a
    /// window has been unminimized; it is deliberately checked by reading the
    /// attribute back, because setting it on a minimized window reports
    /// success and does nothing.
    public static func ensureMainWindow() throws {
        let (_, window) = try scene()
        guard !(try boolAttribute(window, kAXMinimizedAttribute)) else {
            throw KindleLiveError.readFailed(
                "the window is minimized and cannot receive page turns")
        }
        let result = AXUIElementSetAttributeValue(
            window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard result == .success else {
            throw KindleLiveError.readFailed(
                "Kindle refused the main-window request (\(result.rawValue))")
        }
        guard try boolAttribute(window, kAXMainAttribute) else {
            throw KindleLiveError.readFailed(
                "Kindle did not make its reading window main")
        }
    }

    private static func boolAttribute(
        _ element: AXUIElement, _ attribute: String
    ) throws -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value)
        guard result == .success, let value else {
            throw KindleLiveError.readFailed(
                "Kindle did not expose \(attribute) (\(result.rawValue))")
        }
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        throw KindleLiveError.readFailed(
            "Kindle exposed \(attribute) as an unexpected type")
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
            if bookIDBefore != bookIDAfter {
                TsundokuDiagnostics.shared.event(
                    "kindle_book_id_unavailable",
                    ["reason": "identity changed during the page read"])
            }
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

    /// Serializes the snapshot–press–read–restore transaction. Overlapping
    /// refreshes would otherwise snapshot or restore each other's clipboard.
    private static let selectionLock = NSLock()

    /// The outcome of reading Kindle's selection, with the failures kept
    /// distinct from "nothing is selected".
    public enum SelectionCopy: Sendable, Equatable {
        case copied(String)
        case copiedButClipboardNotRestored(String)
        case noSelection
        case failed(String)

        public var text: String? {
            switch self {
            case .copied(let text), .copiedButClipboardNotRestored(let text):
                return text
            case .noSelection, .failed:
                return nil
            }
        }
    }

    /// The reader's selected words, captured by pressing Kindle's own Copy
    /// button. Kindle does not expose `AXSelectedText`; its selection popover
    /// carries a Copy button instead. The page is read before anything is
    /// mutated, so a failed page read cannot leave the clipboard changed.
    public static func copySelection() -> SelectionCopy {
        if Thread.isMainThread {
            // Never block the main thread behind a worker that is itself
            // waiting to run on the main thread.
            guard selectionLock.try() else {
                return .failed("A selection read is already in progress.")
            }
        } else {
            selectionLock.lock()
        }
        defer { selectionLock.unlock() }
        guard AXIsProcessTrusted() else {
            return .failed("Accessibility permission is not granted.")
        }
        guard isRunning() else { return .failed("Kindle is not running.") }
        guard let page = try? currentPage().text, !page.isEmpty else {
            return .failed(
                "Could not read the current page; the selection was not read.")
        }
        let source = LiveAXSource()
        let recorder = AXRecorder(source: source)
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID).first
        else { return .failed("Kindle is not running.") }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = try? recorder.findWindow(from: application)
        else { return .failed("Could not read the Kindle window.") }
        switch copyButton(in: window, source: source) {
        case .failed(let reason):
            return .failed(reason)
        case .none:
            return .noSelection
        case .found(let button):
            return pressCopyAndRead(button: button, page: page)
        }
    }

    private static func pressCopyAndRead(
        button copyButton: AXUIElement, page: String
    ) -> SelectionCopy {
        // Do not clear the clipboard unless the old contents can be restored
        // completely and stayed unchanged while they were copied.
        guard
            let snapshot = mainSync({ stablePasteboardSnapshot() })
        else { return .failed("Could not snapshot the clipboard.") }
        let baseline = snapshot.count
        guard mainSync({ pasteboardChangeCount() }) == baseline else {
            return .failed(
                "The clipboard changed before Kindle copied; try again.")
        }
        let press = AXUIElementPerformAction(
            copyButton, kAXPressAction as CFString)
        // `.cannotComplete` does not prove the action failed; observe the
        // clipboard before deciding.
        let uncertain = press == .cannotComplete
        guard press == .success || uncertain else {
            return .failed("Kindle's Copy button did not respond.")
        }

        var copied: String?
        var resultCount: Int?
        var sawForeignWrite = false
        for attempt in 0..<30 {
            if let sample = mainSync({ stablePasteboardText() }),
                sample.count != baseline
            {
                if let text = sample.text, !text.isEmpty {
                    guard SelectionText.belongs(text, toPage: page) else {
                        // Another app wrote while Kindle was responding.
                        // Leave that newer content alone; never restore over
                        // a write we cannot attribute to Kindle.
                        return .failed(
                            "The clipboard changed, but the text did not "
                                + "match this page.")
                    }
                    copied = text
                    resultCount = sample.count
                    break
                }
                // Kindle may clear the clipboard before writing text; keep
                // polling rather than treating the first count change as a
                // completed copy. A non-text write is not ours to overwrite.
                sawForeignWrite = true
            }
            if attempt < 29 {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        if copied == nil {
            // The deadline is a boundary, not a reason to skip a result that
            // is already on the clipboard.
            if let sample = mainSync({ stablePasteboardText() }),
                sample.count != baseline, let text = sample.text,
                !text.isEmpty, SelectionText.belongs(text, toPage: page)
            {
                copied = text
                resultCount = sample.count
            }
        }
        guard let copied else {
            if uncertain {
                return .failed(
                    "Kindle's Copy did not complete; the clipboard was left "
                        + "as it was.")
            }
            return .failed(
                sawForeignWrite
                    ? "The clipboard changed to content that is not this "
                        + "page's text; it was left untouched."
                    : "Kindle's Copy produced no text.")
        }
        let trimmed =
            copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed("Kindle's Copy produced no text.")
        }

        if let resultCount {
            let outcome = mainSync { () -> RestoreOutcome in
                let pasteboard = NSPasteboard.general
                // Check and restore in one main-queue turn: a copy that
                // arrives after this point must win.
                guard pasteboard.changeCount == resultCount else {
                    return .superseded
                }
                return restorePasteboard(snapshot.snapshot)
                    ? .restored : .failed
            }
            if outcome == .failed {
                TsundokuDiagnostics.shared.event(
                    "kindle_pasteboard_restore_failed", [:])
                return .copiedButClipboardNotRestored(trimmed)
            }
        }
        return .copied(trimmed)
    }

    /// Compatibility wrapper: text only when the whole transaction,
    /// including clipboard restoration, succeeded.
    public static func copySelectedText() -> String? {
        if case .copied(let text) = copySelection() { return text }
        return nil
    }

    /// Words Kindle uses for the Copy action and its selection siblings.
    /// English is the fallback when a tree carries no stable identifier; the
    /// list covers the storefront languages this app is likely to meet.
    private static let copyWords: Set<String> = [
        "copy", "kopieren", "copier", "copiar", "copia", "kopiuj",
        "コピー", "コピーする", "复制", "複製", "拷贝", "拷貝", "복사",
        "копировать", "kopyala",
    ]
    private static let selectionWords: Set<String> = [
        "highlight", "note", "look", "anmerkung", "notiz", "surligner",
        "resaltar", "nota", "evidenzia", "ハイライト", "ノート", "高亮",
        "醒目提示", "重點", "笔记", "筆記", "註解", "형광펜", "노트",
        "выделить", "заметка", "wyróżnij", "notatka", "vurgula", "not",
    ]

    private enum CopyButtonLookup {
        case found(AXUIElement)
        case none
        case failed(String)
    }

    /// The Copy button inside Kindle's selection popover. A copy button
    /// elsewhere is not a selection, so require its selection siblings.
    private static func copyButton(
        in window: AXUIElement, source: LiveAXSource
    ) -> CopyButtonLookup {
        var visited = Set<AXUIElement>()
        var budget = 4_000
        var exhausted = false
        let deadline = Date().addingTimeInterval(3)
        func text(_ element: AXUIElement) -> String {
            var parts: [String] = []
            for attribute in [
                "AXLabel", "AXDescription", "AXTitle", "AXIdentifier",
            ] {
                do {
                    if let value = try source.string(element, attribute) {
                        parts.append(value)
                    }
                } catch {
                    // A failed read can hide the Copy label; the search is
                    // incomplete even if another child looks like a match.
                    exhausted = true
                }
            }
            return parts.joined(separator: " ").lowercased()
        }
        func words(_ value: String) -> Set<String> {
            Set(
                value.split(whereSeparator: { !$0.isLetter })
                    .map { $0.lowercased() })
        }
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 24, !visited.contains(element), budget > 0,
                Date() < deadline, !Task.isCancelled
            else {
                if budget <= 0 || Date() >= deadline || depth >= 24
                    || Task.isCancelled
                {
                    exhausted = true
                }
                return nil
            }
            budget -= 1
            visited.insert(element)
            let read = try? source.children(element)
            if read == nil { exhausted = true }
            let allChildren = read ?? []
            if allChildren.count > 256 { exhausted = true }
            let children = Array(allChildren.prefix(256))
            if Date() >= deadline { exhausted = true; return nil }
            var roles: [String] = []
            for child in children {
                if Date() >= deadline || Task.isCancelled {
                    exhausted = true
                    return nil
                }
                do {
                    roles.append(try source.string(child, "AXRole") ?? "")
                } catch {
                    // A child whose role cannot be read makes this search
                    // incomplete; it may have hidden the copy button.
                    exhausted = true
                    roles.append("")
                }
            }
            var labels: [String] = []
            for (child, role) in zip(children, roles) {
                if Date() >= deadline || Task.isCancelled {
                    exhausted = true
                    return nil
                }
                labels.append(role == "AXButton" ? text(child) : "")
            }
            let hasSelectionSibling = labels.contains {
                let words = words($0)
                return !words.isDisjoint(with: selectionWords)
                    || $0.contains("highlight") || $0.contains("note")
            }
            if Date() >= deadline || Task.isCancelled {
                exhausted = true
                return nil
            }
            if hasSelectionSibling,
                let index = labels.firstIndex(where: {
                    let words = words($0)
                    return !words.isDisjoint(with: copyWords)
                        || $0.contains("copy")
                })
            {
                return children[index]
            }
            for child in children {
                if let found = search(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        if let found = search(window, depth: 0) { return .found(found) }
        return exhausted
            ? .failed("The Kindle selection tree exceeded its search budget.")
            : .none
    }

    private static func mainSync<T: Sendable>(
        _ body: @Sendable () -> T
    ) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    private struct PasteboardSnapshot: Sendable {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func stablePasteboardSnapshot()
        -> (snapshot: PasteboardSnapshot, count: Int)?
    {
        // A snapshot taken across a concurrent write would restore stale
        // contents over the user's newer copy. Retry once, then give up.
        for _ in 0..<2 {
            let pasteboard = NSPasteboard.general
            let before = pasteboard.changeCount
            // A nil item list cannot prove the clipboard was empty; fail
            // closed rather than later clearing contents we could not read.
            guard let sourceItems = pasteboard.pasteboardItems else {
                continue
            }
            var complete = true
            var byteCount = 0
            var typeCount = 0
            let items = sourceItems.prefix(100).map { item in
                var values: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    typeCount += 1
                    guard typeCount <= 256,
                        let data = item.data(forType: type)
                    else {
                        complete = false
                        continue
                    }
                    byteCount += data.count
                    guard byteCount <= 16 * 1024 * 1024 else {
                        complete = false
                        continue
                    }
                    values[type] = data
                }
                return values
            }
            let after = pasteboard.changeCount
            if sourceItems.count > 100 { complete = false }
            if complete, before == after {
                return (PasteboardSnapshot(items: items), before)
            }
        }
        return nil
    }

    private enum RestoreOutcome: Sendable, Equatable {
        case restored
        case superseded
        case failed
    }

    private static func restorePasteboard(
        _ snapshot: PasteboardSnapshot
    ) -> Bool {
        let pasteboard = NSPasteboard.general
        // `clearContents()` drops the contents options; restored material
        // must stay device-local rather than silently becoming eligible for
        // Universal Clipboard.
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        var complete = true
        let items = snapshot.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                if !item.setData(data, forType: type) { complete = false }
            }
            return item
        }
        let wrote = items.isEmpty || pasteboard.writeObjects(items)
        return complete && wrote
    }

    private static func pasteboardChangeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    /// Reads the revision and its text as one sample; a write between them
    /// makes the sample inconsistent and it is retried.
    private static func stablePasteboardText()
        -> (count: Int, text: String?)?
    {
        for _ in 0..<2 {
            let pasteboard = NSPasteboard.general
            let before = pasteboard.changeCount
            let text = pasteboard.string(forType: .string)
            let after = pasteboard.changeCount
            if before == after { return (before, text) }
        }
        return nil
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
        guard let data = try? Data(contentsOf: url) else {
            TsundokuDiagnostics.shared.event(
                "kindle_book_id_unavailable",
                ["reason": "reader preferences unreadable"])
            return nil
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else {
            TsundokuDiagnostics.shared.event(
                "kindle_book_id_unavailable",
                ["reason": "reader preferences unparsed"])
            return nil
        }
        guard let raw = plist["WasLastOpenedBookId"] as? String else {
            TsundokuDiagnostics.shared.event(
                "kindle_book_id_unavailable",
                ["reason": "last-opened marker missing"])
            return nil
        }
        guard let asin = KindleLive.asin(fromBookID: raw) else {
            TsundokuDiagnostics.shared.event(
                "kindle_book_id_unavailable",
                ["reason": "last-opened marker invalid"])
            return nil
        }
        return asin
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
