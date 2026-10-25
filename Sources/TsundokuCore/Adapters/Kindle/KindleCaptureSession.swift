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
    private let activateApp: () throws -> Void
    private let settleMinimum: TimeInterval
    private let settleTimeout: TimeInterval
    private let restoreTimeout: TimeInterval
    private let initialWindow: AXNode.Frame
    private var pageRect: CGRect
    private var calibration: PageFrameCalibration
    /// A cover or a plate leaves no text headroom for the page box. A capture
    /// may start on one (a whole-book capture rewinds first) and calibrate on
    /// the first page that can take the box.
    private var needsCalibration = false
    private let opening: PageLocation
    private let pageCrop: PageCrop
    private let openingPageCount: Int?
    private var openingTextWidth: Double?
    private var openingMark: PageMark?
    private let pageSetupGuard: KindlePageSetup?
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
        activate: @escaping () throws -> Void = KindleLive.activate,
        settleMinimum: TimeInterval = 0.30,
        settleTimeout: TimeInterval = 3.0,
        restoreTimeout: TimeInterval = 60,
        pageSetupGuard: KindlePageSetup? = nil,
        pageCrop: PageCrop = .kindle(PageSetupRequest())
    ) throws {
        guard isTrusted() else {
            throw ReaderCaptureError.notTrusted(.kindle)
        }
        guard isRunning() else {
            throw ReaderCaptureError.notRunning(.kindle)
        }
        try activate()
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
        var calibration = PageFrame.resolve(
            window: windowRect, text: textRect,
            chrome: first.chromeInsets)
        // Starting on a cover or a plate is not a failed capture: the box is
        // recalibrated on the first page that can take it, after the rewind
        // or the front-matter skip has found one.
        let startsUncalibrated = calibration.status == .refused
        if startsUncalibrated {
            calibration = PageFrameCalibration(
                insets: .measured, status: .unverified,
                reason: calibration.reason, chrome: nil, headroom: nil)
        }
        let rect = PageFrame.pageRect(
            window: windowRect, insets: calibration.insets)
        guard rect.width > 100, rect.height > 100 else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the page frame is too small: "
                    + "\(Int(rect.width))×\(Int(rect.height))")
        }
        if !startsUncalibrated, let page = pageSetupGuard?.pageSize.points {
            let tolerance = 1.5
            guard
                abs(rect.width - page.width) <= tolerance,
                abs(rect.height - page.height) <= tolerance
            else {
                throw ReaderCaptureError.captureFailed(
                    .kindle,
                    reason: "the layout produced "
                        + "\(Int(rect.width))×\(Int(rect.height)) points "
                        + "instead of \(Int(page.width))×"
                        + "\(Int(page.height)); the window was refused")
            }
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
        self.needsCalibration = startsUncalibrated
        self.opening = PageLocation(
            pageNumber: first.pageNumber, pageCount: first.pageCount)
        self.pageCrop = pageCrop
        do {
            try pageCrop.validate(pageHeight: rect.height)
        } catch {
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: "crop: \(error)")
        }
        self.openingPageCount = first.pageCount
        self.openingTextWidth = textRect.map { Double($0.width) }
        self.pageSetupGuard = pageSetupGuard
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
        if needsCalibration {
            try calibrate(from: live)
            needsCalibration = false
        }
        try validate(live)
        let raw = try captureRaw()
        let hash = ImageFingerprint.detailHash(raw)
        let image = try delivered(raw)
        try verifyUnchanged(since: live)
        let page = snapshot(
            from: live, image: image, verificationHash: hash)
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
            let hash: UInt64
            do {
                let raw = try captureRaw()
                hash = ImageFingerprint.detailHash(raw)
            } catch {
                lastCaptureError = error
                sleep(0.05)
                continue
            }
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
            let settledRaw: CGImage
            do {
                settledRaw = try captureRaw()
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
                ImageFingerprint.detailHash(settledRaw) == hash
            else {
                sleep(0.05)
                continue
            }
            let settledImage: CGImage
            do {
                settledImage = try delivered(settledRaw)
            } catch {
                lastCaptureError = error
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
                snapshot(
                    from: settled, image: settledImage,
                    verificationHash: hash), observed)
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

    public var pageSetupOutcome: PageSetupOutcome? {
        pageSetupGuard?.outcome
    }

    private var storedRewind: RewindReport?

    public var rewindOutcome: RewindReport? { storedRewind }

    /// Returns to the book's first page by turning backward until the reader
    /// stops moving.
    ///
    /// Kindle publishes no page number while its chrome is hidden, so the
    /// start is confirmed by three consecutive backward presses that change
    /// neither the text nor the page image — a single dropped key cannot end
    /// the rewind early.
    public func rewindToStart() throws -> RewindReport {
        try checkCancelled()
        let opening = try readCurrent()
        guard opening.isReading else {
            throw ReaderCaptureError.notReading(.kindle, state: opening.state)
        }
        var previousText = opening.text
        var previousHash = (try? captureRaw()).map {
            ImageFingerprint.detailHash($0)
        }
        var turns = 0
        var unchanged = 0
        // The location total is the page count when Kindle exposed it; without
        // it the cap is generous enough for any book a reader would capture.
        let cap = min(max((openingPageCount ?? 800) + 20, 60), 1_500)
        while turns < cap {
            try checkCancelled()
            try turnBackward()
            sleep(settleMinimum)
            let deadline = now().addingTimeInterval(min(settleTimeout, 0.8))
            var moved = false
            while now() < deadline {
                try checkCancelled()
                guard let live = try? readCurrent(), live.isReading else {
                    sleep(0.05)
                    continue
                }
                let hash = (try? captureRaw()).map {
                    ImageFingerprint.detailHash($0)
                }
                let textChanged = live.text != previousText
                let hashChanged =
                    hash != nil && previousHash != nil && hash != previousHash
                if textChanged || hashChanged {
                    previousText = live.text
                    if let hash { previousHash = hash }
                    moved = true
                    break
                }
                sleep(0.05)
            }
            turns += 1
            if moved {
                unchanged = 0
            } else {
                unchanged += 1
                if unchanged >= 3 {
                    // A cover or a full-page plate leaves no room for the
                    // chrome crop; step forward to the first page the capture
                    // box can actually take. The generated cover page stands
                    // in for the skipped front matter.
                    var skipped = 0
                    var current = try? readCurrent()
                    var currentHash = (try? captureRaw()).map {
                        ImageFingerprint.detailHash($0)
                    }
                    while skipped < 12 {
                        try checkCancelled()
                        guard let live = current, live.isReading else {
                            break
                        }
                        if !pageBoxRefused(live) { break }
                        try turnForward()
                        // Wait for the page to change before judging the next
                        // box: a dropped key must not burn a skip.
                        let deadline = now().addingTimeInterval(
                            min(settleTimeout, 1.2))
                        var next: (page: LivePage, hash: UInt64?)?
                        while now() < deadline {
                            try checkCancelled()
                            guard let candidate = try? readCurrent(),
                                candidate.isReading
                            else {
                                sleep(0.05)
                                continue
                            }
                            let hash = (try? captureRaw()).map {
                                ImageFingerprint.detailHash($0)
                            }
                            let changed =
                                candidate.text != live.text
                                || (hash != nil && currentHash != nil
                                    && hash != currentHash)
                            if changed {
                                next = (candidate, hash)
                                break
                            }
                            sleep(0.05)
                        }
                        guard let next else { break }
                        current = next.page
                        currentHash = next.hash
                        skipped += 1
                    }
                    let report = RewindReport(
                        attempted: true, reachedStart: true, turns: turns,
                        skippedPages: skipped, method: "backward turns",
                        reason: nil)
                    storedRewind = report
                    return report
                }
            }
        }
        let report = RewindReport(
            attempted: true, reachedStart: false, turns: turns,
            method: "backward turns",
            reason: "the reader was still moving after \(turns) backward turns")
        storedRewind = report
        return report
    }

    /// Whether the page cannot carry the capture's box: a full-page image or
    /// a cover has no text headroom for the chrome crop.
    private func pageBoxRefused(_ live: LivePage) -> Bool {
        guard let window = live.windowFrame else { return true }
        let windowRect = CGRect(
            x: window.x, y: window.y,
            width: window.width, height: window.height)
        let textRect = live.pageTextFrame.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        let frame = PageFrame.resolve(
            window: windowRect, text: textRect, chrome: live.chromeInsets)
        return frame.status == .refused
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
        var exact: Bool
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
            if let raw = try? captureRaw() {
                exact =
                    final?.text == openingMark.text
                    && ImageFingerprint.detailHash(raw)
                        == openingMark.imageHash
            } else {
                exact = false
                verificationFailed = true
            }
        } else {
            exact = observed == 0
        }
        var layoutProblem: String?
        if let pageSetupGuard {
            let outcome = pageSetupGuard.restore()
            if !outcome.restored {
                exact = false
                layoutProblem =
                    "the page setup was not restored: "
                    + (outcome.reason ?? "unknown reason")
            } else if exact, let openingMark,
                pageSetupGuard.outcome?.requestedFont == nil
            {
                // The window does not reflow the text; verify the opening.
                // A font change does, and the setup owns restoring the
                // pre-capture position instead.
                if (try? readCurrent())?.text != openingMark.text {
                    exact = false
                    layoutProblem =
                        "the page moved when the page setup was restored"
                }
            }
        }
        let report = RestoreReport(
            opening: opening, final: finalLocation, attempted: attempted,
            posted: posted, observed: observed, terminal: terminal,
            unresolved: unresolved, exact: exact,
            reason: exact ? nil
                : layoutProblem
                    ?? (layoutChanged
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
                                            : "the opening page could not be verified"))
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
            case .readFailed(let message):
                throw ReaderCaptureError.captureFailed(
                    .kindle, reason: message)
            }
        } catch {
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: "\(error)")
        }
    }

    private func captureRaw() throws -> CGImage {
        // ScreenCaptureKit photographs the display, not a window: if another
        // app is in front, the page image is that app.
        if !isFrontmost() {
            try activateApp()
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

    private func delivered(_ raw: CGImage) throws -> CGImage {
        do {
            return try PageFooter.removingKindleInsets(
                from: raw, crop: pageRect,
                topPoints: CGFloat(pageCrop.top),
                bottomPoints: CGFloat(pageCrop.bottom)) ?? raw
        } catch {
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: "crop: \(error)")
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

    /// Fixes the page box from the first page that can take it, after a
    /// capture started on a cover or a plate.
    private func calibrate(from live: LivePage) throws {
        guard let window = live.windowFrame else {
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: "the reader window disappeared")
        }
        let windowRect = CGRect(
            x: window.x, y: window.y,
            width: window.width, height: window.height)
        let textRect = live.pageTextFrame.map {
            CGRect(
                x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        let current = PageFrame.resolve(
            window: windowRect, text: textRect, chrome: live.chromeInsets)
        guard current.status != .refused else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: current.reason ?? "the page box was refused")
        }
        let rect = PageFrame.pageRect(
            window: windowRect, insets: current.insets)
        guard rect.width > 100, rect.height > 100 else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the page frame is too small: "
                    + "\(Int(rect.width))×\(Int(rect.height))")
        }
        if let page = pageSetupGuard?.pageSize.points {
            let tolerance = 1.5
            guard
                abs(rect.width - page.width) <= tolerance,
                abs(rect.height - page.height) <= tolerance
            else {
                throw ReaderCaptureError.captureFailed(
                    .kindle,
                    reason: "the layout produced "
                        + "\(Int(rect.width))×\(Int(rect.height)) points "
                        + "instead of \(Int(page.width))×"
                        + "\(Int(page.height)); the window was refused")
            }
        }
        do {
            try pageCrop.validate(pageHeight: rect.height)
        } catch {
            throw ReaderCaptureError.captureFailed(
                .kindle, reason: "crop: \(error)")
        }
        calibration = current
        pageRect = rect
        // The cover's text frame (often the whole window) is not the body
        // column; the width guard follows the first page that can be captured.
        openingTextWidth = textRect.map { Double($0.width) }
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

    private func snapshot(
        from live: LivePage, image: CGImage,
        verificationHash: UInt64
    ) -> PageSnapshot {
        let text = live.text.isEmpty ? nil : live.text
        let mark = PageMark(
            imageHash: verificationHash,
            text: live.text)
        return PageSnapshot(
            identity: identity, image: image, text: text,
            textSource: text == nil ? ReaderTextSource.none : .accessibility,
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
