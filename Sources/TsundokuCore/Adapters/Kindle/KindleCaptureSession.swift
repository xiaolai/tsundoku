import CoreGraphics
import Foundation
import KindleAX

/// The Kindle reader behind the capture contract.
///
/// The session owns the page geometry, the text/image transaction, the turn
/// ledger and restoration. The engine only writes what a snapshot returns.
public final class KindleCaptureSession: ReaderCaptureSession {
    public typealias ReadPage = () throws -> LivePage
    public typealias CapturePage = (CGRect) throws -> CGImage
    public typealias Turn = () throws -> Void
    public typealias Sleep = (TimeInterval) -> Void
    public typealias Now = () -> Date

    public let identity: ObservedIdentity
    public let mode: CaptureMode

    private let cancellation: any CancellationChecking
    private let readPage: ReadPage
    private let capture: CapturePage
    private let turnForward: Turn
    private let turnBackward: Turn
    private let escape: Turn
    private let sleep: Sleep
    private let now: Now
    private let isFrontmost: () -> Bool
    private let activateApp: () -> Void
    private let settleMinimum: TimeInterval
    private let settleTimeout: TimeInterval
    private let restoreTimeout: TimeInterval
    private let initialWindow: AXNode.Frame
    private let pageRect: CGRect
    private let calibration: PageFrameCalibration
    private let opening: PageLocation
    private let openingPageCount: Int?
    private let openingTextWidth: Double?
    private var openingMark: PageMark?
    private var records: [TurnRecord] = []
    private var storedRestore: RestoreReport?

    public init(
        subject: CaptureSubject,
        cancellation: any CancellationChecking,
        readPage: @escaping ReadPage = { try KindleLive.currentPage() },
        capture: CapturePage? = nil,
        turnForward: @escaping Turn = { try KindleLive.turnForward() },
        turnBackward: @escaping Turn = { try KindleLive.turnBackward() },
        escape: @escaping Turn = { try KindleLive.escape() },
        sleep: @escaping Sleep = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping Now = Date.init,
        isTrusted: @escaping () -> Bool = KindleLive.isTrusted,
        isRunning: @escaping () -> Bool = KindleLive.isRunning,
        isFrontmost: @escaping () -> Bool = { true },
        activate: @escaping () -> Void = KindleLive.activate,
        settleMinimum: TimeInterval = 0.30,
        settleTimeout: TimeInterval = 3.0,
        restoreTimeout: TimeInterval = 60
    ) throws {
        guard isTrusted() else {
            throw ReaderCaptureError.notTrusted(.kindle)
        }
        guard isRunning() else {
            throw ReaderCaptureError.notRunning(.kindle)
        }
        activate()
        guard let first = try? readPage() else {
            throw ReaderCaptureError.noWindow(.kindle)
        }
        guard first.isReading else {
            throw ReaderCaptureError.notReading(
                .kindle, state: first.state)
        }
        guard let window = first.windowFrame else {
            throw ReaderCaptureError.noWindow(.kindle)
        }
        let windowRect = CGRect(
            x: window.x, y: window.y,
            width: window.width, height: window.height)
        let textRect = first.pageTextFrame.map {
            CGRect(
                x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        // Full screen covers the menu bar, so the toolbar-reveal click and the
        // measured chrome no longer apply. Refused in v1 rather than guessed.
        guard !PageFrame.isFullScreen(windowRect) else {
            throw ReaderCaptureError.unsupported(
                .kindle,
                reason: "full-screen capture is not supported; "
                    + "leave the menu bar visible")
        }
        let calibration = PageFrame.resolve(
            window: windowRect, text: textRect,
            chrome: first.chromeInsets)
        guard calibration.status != .refused else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: calibration.reason ?? "the page box was refused")
        }
        let rect = PageFrame.pageRect(
            window: windowRect, insets: calibration.insets)
        guard rect.width > 100, rect.height > 100 else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the page frame is too small: "
                    + "\(Int(rect.width))×\(Int(rect.height))")
        }

        self.cancellation = cancellation
        self.readPage = readPage
        self.capture = capture ?? { rect in
            try DisplayScreenCapture().image(
                rect: rect, isCancelled: { cancellation.isSet })
        }
        self.turnForward = turnForward
        self.turnBackward = turnBackward
        self.escape = escape
        self.sleep = sleep
        self.now = now
        self.isFrontmost = isFrontmost
        self.activateApp = activate
        self.settleMinimum = settleMinimum
        self.settleTimeout = settleTimeout
        self.restoreTimeout = restoreTimeout
        self.initialWindow = window
        self.pageRect = rect
        self.calibration = calibration
        self.opening = PageLocation(
            pageNumber: first.pageNumber, pageCount: first.pageCount)
        self.openingPageCount = first.pageCount
        self.openingTextWidth = textRect.map { Double($0.width) }
        // A chrome-hidden reader exposes no title. Do not fabricate one:
        // an empty title with unknown confidence is what the engine treats
        // as "cannot verify", not as evidence of a wrong book.
        let title = first.title.trimmingCharacters(
            in: .whitespacesAndNewlines)
        self.identity = ObservedIdentity(
            title: title,
            confidence: title.isEmpty ? .unknown : .titleOnly(title))
        self.mode = CaptureMode(
            layout: .reflowable, navigation: .automatic,
            endDetection: .positive)
    }

    public func snapshot() throws -> PageSnapshot {
        try checkCancelled()
        let live = try readCurrent()
        guard live.isReading else {
            throw ReaderCaptureError.notReading(
                .kindle, state: live.state)
        }
        try validate(live)
        let image = try capturePage()
        try verifyUnchanged(since: live)
        let page = snapshot(from: live, image: image)
        if openingMark == nil { openingMark = page.mark }
        return page
    }

    public func advance(after mark: PageMark) throws -> PageTransition {
        try checkCancelled()
        let before = try readCurrent()
        guard before.isReading else {
            throw ReaderCaptureError.notReading(
                .kindle, state: before.state)
        }

        do {
            try turnForward()
        } catch {
            records.append(
                TurnRecord(
                    attempted: true, posted: false, observed: false,
                    terminal: false, unresolved: true))
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: "could not send the page turn: \(error)")
        }

        sleep(settleMinimum)
        let deadline = now().addingTimeInterval(settleTimeout)
        // Kept for the no-turn report: a frontmost refusal otherwise looks
        // like an ordinary slow page.
        var lastCaptureError: Error?
        do {
            while now() < deadline {
                try checkCancelled()
            guard let live = try? readCurrent() else {
                sleep(0.05)
                continue
            }
            if live.endOfBook {
                let terminal = TurnRecord(
                    attempted: true, posted: true, observed: true,
                    terminal: true, unresolved: false)
                records.append(terminal)
                return .endOfBook(terminal)
            }
            guard live.isReading else {
                sleep(0.05)
                continue
            }
            try validate(live)
            let image: CGImage
            do {
                image = try capturePage()
            } catch {
                lastCaptureError = error
                sleep(0.05)
                continue
            }
            let hash = ImageFingerprint.averageHash(image)
            let textChanged = live.text != before.text
            let hashChanged = hash != mark.imageHash
            guard textChanged || hashChanged else {
                sleep(0.05)
                continue
            }

            // One changed frame is a candidate, not a settled page. The text
            // settles before the animation; wait for a second matching frame.
            sleep(0.10)
            guard let settled = try? readCurrent() else {
                sleep(0.05)
                continue
            }
            if settled.endOfBook {
                let terminal = TurnRecord(
                    attempted: true, posted: true, observed: true,
                    terminal: true, unresolved: false)
                records.append(terminal)
                return .endOfBook(terminal)
            }
            let settledImage: CGImage
            do {
                settledImage = try capturePage()
            } catch {
                lastCaptureError = error
                sleep(0.05)
                continue
            }
            guard
                settled.isReading,
                settled.text == live.text,
                // The two frames must agree even when the text changed before
                // the render did; otherwise the image can still be in motion.
                ImageFingerprint.averageHash(settledImage) == hash
            else {
                sleep(0.05)
                continue
            }
            try validate(settled)
            try verifyUnchanged(since: settled)
            let observed = TurnRecord(
                attempted: true, posted: true, observed: true,
                terminal: false, unresolved: false)
            records.append(observed)
            return .turned(
                snapshot(from: settled, image: settledImage), observed)
        }
        } catch {
            let cancelled = TurnRecord(
                attempted: true, posted: true, observed: false,
                terminal: false, unresolved: true)
            records.append(cancelled)
            throw error
        }

        let unresolved = TurnRecord(
            attempted: true, posted: true, observed: false,
            terminal: false, unresolved: true)
        records.append(unresolved)
        return .noTurn(
            unresolved,
            reason: "the page did not settle within "
                + "\(Int(settleTimeout)) seconds"
                + (lastCaptureError.map { "; last capture error: \($0)" }
                    ?? ""))
    }

    public func restore() -> RestoreReport {
        if let storedRestore { return storedRestore }
        let attempted = records.filter(\.attempted).count
        let posted = records.filter(\.posted).count
        let observed = records.filter { $0.observed && !$0.terminal }.count
        let terminal = records.filter(\.terminal).count
        let unresolved = records.filter(\.unresolved).count

        var current = try? readCurrent()
        if current?.endOfBook == true {
            try? escape()
            sleep(0.30)
            current = try? readCurrent()
        }
        guard let current, current.isReading else {
            let report = RestoreReport(
                opening: opening, final: nil, attempted: attempted,
                posted: posted, observed: observed, terminal: terminal,
                unresolved: unresolved, exact: false,
                reason: "the reader is not in a reading state")
            storedRestore = report
            return report
        }

        var timedOut = false
        var backwardFailed = false
        var layoutChanged = false
        if observed > 0 {
            let deadline = now().addingTimeInterval(restoreTimeout)
            for _ in 0..<observed {
                if now() >= deadline {
                    timedOut = true
                    break
                }
                // Never send an arrow into a surface that stopped being the
                // reader, and stop if the pagination the turn count was
                // measured against has moved.
                guard let page = try? readCurrent(), page.isReading else {
                    backwardFailed = true
                    break
                }
                if let expected = openingPageCount,
                    let actual = page.pageCount, expected != actual
                {
                    layoutChanged = true
                    break
                }
                do {
                    try turnBackward()
                } catch {
                    backwardFailed = true
                }
                sleep(0.40)
            }
        }
        let final = try? readCurrent()
        let finalLocation = final.map {
            PageLocation(pageNumber: $0.pageNumber, pageCount: $0.pageCount)
        }
        var verificationFailed = false
        let exact: Bool
        if unresolved > 0 || backwardFailed || layoutChanged
            || final?.isReading != true
        {
            exact = false
        } else if let wanted = opening.pageNumber,
            let got = finalLocation?.pageNumber
        {
            exact = wanted == got
        } else if let openingMark, final?.isReading == true {
            // No page numbers in the chrome-hidden state. The text alone can
            // match two blank pages, so the image fingerprint is mandatory.
            if let image = try? capturePage() {
                exact =
                    final?.text == openingMark.text
                    && ImageFingerprint.averageHash(image)
                        == openingMark.imageHash
            } else {
                exact = false
                verificationFailed = true
            }
        } else {
            exact = observed == 0
        }
        let report = RestoreReport(
            opening: opening, final: finalLocation, attempted: attempted,
            posted: posted, observed: observed, terminal: terminal,
            unresolved: unresolved, exact: exact,
            reason: exact ? nil
                : layoutChanged
                    ? "the layout changed during capture; restore stopped"
                    : verificationFailed
                        ? "the opening page could not be photographed"
                        : backwardFailed
                            ? "a backward turn failed"
                            : timedOut
                                ? "restore timed out after "
                                    + "\(Int(restoreTimeout)) seconds"
                                : unresolved > 0
                                    ? "a posted turn was not observed"
                                    : final?.isReading != true
                                        ? "the reader is not in a reading state"
                                        : "the opening page could not be verified")
        storedRestore = report
        return report
    }

    private var isCancelled: Bool { cancellation.isSet }

    private func checkCancelled() throws {
        if isCancelled { throw ReaderCaptureError.cancelled }
    }

    private func readCurrent() throws -> LivePage {
        do {
            return try readPage()
        } catch let error as KindleLiveError {
            switch error {
            case .notTrusted:
                throw ReaderCaptureError.notTrusted(.kindle)
            case .notRunning:
                throw ReaderCaptureError.notRunning(.kindle)
            case .noWindow:
                throw ReaderCaptureError.noWindow(.kindle)
            case .notReading(let state):
                throw ReaderCaptureError.notReading(.kindle, state: state)
            case .readFailed(let message):
                throw ReaderCaptureError.captureFailed(
                    .kindle, reason: message)
            }
        } catch {
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: "\(error)")
        }
    }

    private func capturePage() throws -> CGImage {
        // ScreenCaptureKit photographs the display, not a window: if another
        // app is in front, the page image is that app.
        if !isFrontmost() {
            activateApp()
            sleep(0.35)
            guard isFrontmost() else {
                throw ReaderCaptureError.captureFailed(
                    .kindle,
                    reason: "another app is in front of Kindle; "
                        + "refusing to photograph it")
            }
        }
        do {
            return try capture(pageRect)
        } catch let error as ScreenCaptureError {
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: error.description)
        } catch {
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: "\(error)")
        }
    }

    /// The AX read and the screenshot are two operations. Re-read after the
    /// screenshot and refuse a snapshot that pairs one page's text with
    /// another page's image.
    private func verifyUnchanged(since live: LivePage) throws {
        guard
            let after = try? readCurrent(),
            after.isReading,
            after.text == live.text,
            after.windowFrame == live.windowFrame,
            after.pageNumber == live.pageNumber,
            after.pageCount == live.pageCount,
            after.endOfBook == live.endOfBook
        else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the page changed while its screenshot was taken")
        }
    }

    private func validate(_ live: LivePage) throws {
        guard let window = live.windowFrame else {
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: "the reader window disappeared")
        }
        let title = live.title.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !title.isEmpty, !identity.title.isEmpty,
            title.compare(
                identity.title,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != .orderedSame
        {
            throw ReaderCaptureError.identityChanged(
                expected: identity.title, observed: title)
        }
        let moved =
            abs(window.x - initialWindow.x) > 1
            || abs(window.y - initialWindow.y) > 1
            || abs(window.width - initialWindow.width) > 1
            || abs(window.height - initialWindow.height) > 1
        if moved {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the reader window moved or resized mid-run")
        }
        let windowRect = CGRect(
            x: window.x, y: window.y,
            width: window.width, height: window.height)
        let textRect = live.pageTextFrame.map {
            CGRect(
                x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        let current = PageFrame.resolve(
            window: windowRect, text: textRect,
            chrome: live.chromeInsets)
        if current.status == .refused {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: current.reason ?? "the page box was refused")
        }
        if current.status != .unverified {
            let old = calibration.insets
            let new = current.insets
            let changed =
                abs(old.top - new.top) > 0.5
                || abs(old.bottom - new.bottom) > 0.5
                || abs(old.left - new.left) > 0.5
                || abs(old.right - new.right) > 0.5
            if changed {
                throw ReaderCaptureError.captureFailed(
                    .kindle,
                    reason: "the calibrated page box changed mid-run")
            }
        }
        if let textRect,
            !pageRect.insetBy(dx: -2, dy: -2).contains(textRect)
        {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the page text no longer fits the crop")
        }
        // A layout change repaginates the book, so the page total moves. A
        // margin change moves the text column. Either invalidates every page
        // already captured, so the run stops instead of mixing layouts.
        if let openingPageCount, let actual = live.pageCount,
            openingPageCount != actual
        {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the page count changed from \(openingPageCount) to "
                    + "\(actual) mid-run; the font, margins or layout changed")
        }
        if let openingTextWidth, let actual = live.pageTextFrame.map({
            Double($0.width)
        }),
            actual > 0, abs(actual - openingTextWidth) > 4
        {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the text column width changed from "
                    + "\(Int(openingTextWidth)) to \(Int(actual)) pt mid-run")
        }
    }

    private func snapshot(from live: LivePage, image: CGImage)
        -> PageSnapshot
    {
        let text = live.text.isEmpty ? nil : live.text
        let mark = PageMark(
            imageHash: ImageFingerprint.averageHash(image),
            text: live.text)
        return PageSnapshot(
            identity: identity, image: image, text: text,
            textSource: text == nil ? .none : .accessibility,
            pageNumber: live.pageNumber, pageCount: live.pageCount,
            location: PageLocation(
                pageNumber: live.pageNumber, pageCount: live.pageCount),
            isEndOfBook: live.endOfBook, cropRect: pageRect,
            pixelSize: CGSize(
                width: CGFloat(image.width),
                height: CGFloat(image.height)), mark: mark,
            calibration: calibration,
            textFrame: live.pageTextFrame.map {
                CGRect(
                    x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            })
    }

}
