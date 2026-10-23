import CoreGraphics
import Foundation

/// Resizes the Apple Books reader to a portrait A4 page for a single-page
/// capture, and restores the window and reading position afterwards.
///
/// The measured A4 layout is one page per spread-less window: a 595×894
/// window leaves a 595×842 crop below the 52-point toolbar. The setup refuses
/// a layout that still shows a spread.
public final class BooksPageSetup {
    public typealias WindowReader = () throws -> CGRect
    public typealias WindowWriter = (CGRect) throws -> CGRect
    public typealias PageReader = () throws -> BooksLivePage
    public typealias ImageCapture = (CGRect) throws -> CGImage
    public typealias Turn = () throws -> Void
    public typealias MenuPress = (String) -> Bool
    public typealias Sleep = (TimeInterval) -> Void

    public let request: PageSetupRequest

    private let readWindow: WindowReader
    private let writeWindow: WindowWriter
    private let readPage: PageReader
    private let capture: ImageCapture
    private let turnForward: Turn
    private let turnBackward: Turn
    private let pressMenu: MenuPress
    private let activate: () -> Void
    private let sleep: Sleep
    private let displays: () -> [CGRect]
    private var originalWindow: CGRect?
    private var originalMark: PageMark?
    private var appliedFontSteps = 0
    private var beginOutcome: PageSetupOutcome?
    private var storedRestore: PageSetupOutcome?

    public init(
        request: PageSetupRequest,
        readWindow: @escaping WindowReader = {
            guard let frame = try BooksLive.readerWindow().frame else {
                throw PageSetupError.notConfigured
            }
            return frame
        },
        writeWindow: @escaping WindowWriter = {
            try BooksLive.setWindowFrame($0)
        },
        readPage: @escaping PageReader = {
            try BooksLive.currentPage()
        },
        capture: @escaping ImageCapture = {
            try BooksLive.pageImage($0)
        },
        turnForward: @escaping Turn = { try BooksLive.turnForward() },
        turnBackward: @escaping Turn = { try BooksLive.turnBackward() },
        pressMenu: @escaping MenuPress = {
            BooksLive.pressMenuItem($0)
        },
        activate: @escaping () -> Void = { BooksLive.activate() },
        sleep: @escaping Sleep = { Thread.sleep(forTimeInterval: $0) },
        displays: @escaping () -> [CGRect] = {
            PageFrame.displayBounds()
        }
    ) {
        self.request = request
        self.readWindow = readWindow
        self.writeWindow = writeWindow
        self.readPage = readPage
        self.capture = capture
        self.turnForward = turnForward
        self.turnBackward = turnBackward
        self.pressMenu = pressMenu
        self.activate = activate
        self.sleep = sleep
        self.displays = displays
    }

    public var outcome: PageSetupOutcome? {
        storedRestore ?? beginOutcome
    }

    /// Resize to A4 and verify the resulting crop is one portrait page.
    /// On any failure the original window is put back before the error
    /// reaches the caller.
    @discardableResult
    public func begin() throws -> PageSetupOutcome {
        if let beginOutcome { return beginOutcome }
        // The original mark is a display crop; Books must be in front before
        // it is photographed.
        activate()
        let before = try readStablePage()
        guard before.isReading, let window = before.windowFrame.map({
            CGRect(
                x: $0.x, y: $0.y,
                width: $0.width, height: $0.height)
        }), let crop = before.cropRect else {
            throw PageSetupError.notConfigured
        }
        originalWindow = window
        let pageCrop = request.pageCrop(for: .appleBooks)
        do {
            try pageCrop.validate(pageHeight: crop.height)
        } catch {
            throw PageSetupError.cropInvalid("\(error)")
        }
        if let raw = try? capture(crop) {
            originalMark = PageMark(
                imageHash: ImageFingerprint.detailHash(raw),
                text: before.text)
        }
        var afterWindow = before
        if request.pageSize == .a4 {
            let toolbar = crop.minY - window.minY
            guard toolbar > 20 else {
                throw PageSetupError.notConfigured
            }
            guard
                let a4 = CapturePageSize.a4.points,
                let target = PageSetupGeometry.frame(
                    for: a4,
                    insets: CaptureInsets(
                        top: Double(toolbar), bottom: 0, left: 0, right: 0),
                    current: window, displays: displays())
            else {
                throw PageSetupError.screenTooSmall(
                    CapturePageSize.a4.points ?? .zero)
            }
            do {
                let actual = try writeWindow(target)
                guard
                    abs(actual.width - target.width) <= 1.5,
                    abs(actual.height - target.height) <= 1.5
                else {
                    throw PageSetupError.windowNotAccepted(
                        expected: target.size, actual: actual.size)
                }
                sleep(0.45)
                afterWindow = try readStablePage()
            } catch {
                _ = restore()
                throw error
            }
        }
        if request.booksFontSteps != 0 {
            let steps = request.booksFontSteps
            let title = steps > 0
                ? "Increase Font Size" : "Decrease Font Size"
            do {
                for _ in 0..<abs(steps) {
                    guard pressMenu(title) else {
                        throw PageSetupError.fontStepRefused(steps)
                    }
                    appliedFontSteps += steps > 0 ? 1 : -1
                    sleep(0.30)
                }
                sleep(1.2)
                let afterFont = try readStablePage()
                guard
                    afterFont.text != afterWindow.text
                        || afterFont.textFrames != afterWindow.textFrames
                else {
                    throw PageSetupError.fontStepRefused(steps)
                }
            } catch {
                _ = restore()
                throw error
            }
        }
        let outcome = PageSetupOutcome(
            pageSize: request.pageSize, requestedFont: nil,
            originalFont: nil, finalFont: nil,
            originalWindow: window,
            finalWindow: afterWindow.windowFrame.map {
                CGRect(
                    x: $0.x, y: $0.y,
                    width: $0.width, height: $0.height)
            },
            restored: false, reason: nil,
            fontSteps: request.booksFontSteps == 0
                ? nil : request.booksFontSteps)
        beginOutcome = outcome
        return outcome
    }

    /// Put the window back and verify the pre-resize spread is showing again.
    /// Books can drop its reader window for a moment while it reflows; wait
    /// for a readable page instead of treating that as a missing reader.
    private func readStablePage() throws -> BooksLivePage {
        var last: Error = PageSetupError.notConfigured
        for attempt in 0..<8 {
            do {
                let page = try readPage()
                if page.isReading { return page }
                last = PageSetupError.notConfigured
            } catch {
                last = error
            }
            sleep(attempt == 0 ? 0.5 : 0.25)
        }
        throw last
    }

    public func restore() -> PageSetupOutcome {
        if let storedRestore { return storedRestore }
        activate()
        guard let originalWindow else {
            let outcome = PageSetupOutcome(
                pageSize: request.pageSize, requestedFont: request.font,
                originalFont: nil, finalFont: nil,
                originalWindow: nil, finalWindow: nil,
                restored: true, reason: "nothing to restore")
            storedRestore = outcome
            return outcome
        }
        var finalWindow: CGRect?
        var reason: String?
        var restored = false
        if appliedFontSteps != 0 {
            let title = appliedFontSteps > 0
                ? "Decrease Font Size" : "Increase Font Size"
            for _ in 0..<abs(appliedFontSteps) {
                _ = pressMenu(title)
                sleep(0.30)
            }
            sleep(0.8)
            appliedFontSteps = 0
        }
        do {
            // Books can ignore a resize while it is reflowing; retry the
            // write and wait for the window to settle.
            var page: BooksLivePage?
            for attempt in 0..<5 {
                _ = try? writeWindow(originalWindow)
                sleep(attempt == 0 ? 0.5 : 0.35)
                page = try? readPage()
                let frame = page?.windowFrame.map {
                    CGRect(
                        x: $0.x, y: $0.y,
                        width: $0.width, height: $0.height)
                }
                finalWindow = frame
                if let frame,
                    abs(frame.width - originalWindow.width) <= 1.5,
                    abs(frame.height - originalWindow.height) <= 1.5
                {
                    break
                }
            }
            guard let page else {
                reason = "the reader window was not restored"
                let outcome = PageSetupOutcome(
                    pageSize: request.pageSize, requestedFont: request.font,
                    originalFont: nil, finalFont: nil,
                    originalWindow: originalWindow,
                    finalWindow: finalWindow,
                    restored: false, reason: reason)
                storedRestore = outcome
                return outcome
            }
            if let window = finalWindow,
                abs(window.width - originalWindow.width) > 1.5
                    || abs(window.height - originalWindow.height) > 1.5
            {
                reason = "the reader window was not restored"
            } else if let originalMark {
                // The reflow moved the reading position. Search the restored
                // spread layout for the page that was showing before the
                // resize; the search is bounded and stops as soon as the
                // image matches.
                restored = matches(page, mark: originalMark)
                if !restored {
                    for _ in 0..<12 {
                        do { try turnBackward() } catch { break }
                        sleep(0.45)
                        if let candidate = try? readPage(),
                            candidate.isReading,
                            matches(candidate, mark: originalMark)
                        {
                            restored = true
                            break
                        }
                    }
                }
                if !restored {
                    for _ in 0..<12 {
                        do { try turnForward() } catch { break }
                        sleep(0.45)
                        if let candidate = try? readPage(),
                            candidate.isReading,
                            matches(candidate, mark: originalMark)
                        {
                            restored = true
                            break
                        }
                    }
                }
                if !restored {
                    reason = "the reading position changed when the "
                        + "window was restored and was not found nearby"
                }
            } else {
                reason = "the restored spread could not be verified"
            }
        } catch {
            reason = "\(error)"
        }
        let outcome = PageSetupOutcome(
            pageSize: request.pageSize, requestedFont: request.font,
            originalFont: nil, finalFont: nil,
            originalWindow: originalWindow, finalWindow: finalWindow,
            restored: restored, reason: reason,
            fontSteps: request.booksFontSteps == 0
                ? nil : request.booksFontSteps)
        storedRestore = outcome
        return outcome
    }

    private func matches(
        _ page: BooksLivePage, mark: PageMark
    ) -> Bool {
        guard let crop = page.cropRect,
            let raw = try? capture(crop)
        else { return false }
        return ImageFingerprint.detailHash(raw) == mark.imageHash
    }
}
