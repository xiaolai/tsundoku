import CoreGraphics
import Foundation
import KindleAX

/// Apple Books behind the capture contract.
///
/// Books shows a two-page spread and draws page numbers into the image rather
/// than exposing them through Accessibility. A capture is therefore one PDF
/// page per spread; the spread flag and the full-width crop are recorded so a
/// later split at the gutter can be added without re-measuring.
public final class BooksCaptureSession: ReaderCaptureSession {
    public typealias ReadPage = () throws -> BooksLivePage
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
    private let sleep: Sleep
    private let now: Now
    private let focus: () throws -> BooksFocusReport
    private let recognize: (CGImage) throws -> String
    private let isUnobstructed: (CGRect) -> Bool
    private let hasLease: () -> Bool
    private let isFrontmost: () -> Bool
    private let activate: () -> Void
    private let settleMinimum: TimeInterval
    private let settleTimeout: TimeInterval
    private let restoreTimeout: TimeInterval
    private let initialWindow: AXNode.Frame?
    private let initialCrop: CGRect
    private let singlePage: Bool
    private let pageSetupGuard: BooksPageSetup?
    private let cropTop: Int
    private let cropBottom: Int
    private let opening: PageLocation
    private var openingMark: PageMark?
    private var records: [TurnRecord] = []
    private var storedRestore: RestoreReport?

    public init(
        subject: CaptureSubject,
        cancellation: any CancellationChecking,
        readPage: @escaping ReadPage = { try BooksLive.currentPage() },
        capture: CapturePage? = nil,
        turnForward: @escaping Turn = { try BooksLive.turnForward() },
        turnBackward: @escaping Turn = { try BooksLive.turnBackward() },
        sleep: @escaping Sleep = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping Now = Date.init,
        isTrusted: @escaping () -> Bool = BooksLive.isTrusted,
        isRunning: @escaping () -> Bool = BooksLive.isRunning,
        isFrontmost: @escaping () -> Bool = BooksLive.isFrontmost,
        activate: @escaping () -> Void = BooksLive.activate,
        focus: @escaping () throws -> BooksFocusReport = {
            try BooksLive.focusReader()
        },
        recognize: @escaping (CGImage) throws -> String = {
            try BooksLive.recognizePageText(in: $0)
        },
        isUnobstructed: @escaping (CGRect) -> Bool = { crop in
            guard let reader = try? BooksLive.readerWindow() else {
                return false
            }
            return BooksLive.readerIsUnobstructed(reader, crop: crop)
        },
        hasLease: @escaping () -> Bool = {
            BooksLive.currentReaderLease()
        },
        settleMinimum: TimeInterval = 0.45,
        settleTimeout: TimeInterval = 4.0,
        restoreTimeout: TimeInterval = 60,
        pageSetupGuard: BooksPageSetup? = nil,
        cropTop: Int = 0,
        cropBottom: Int? = nil
    ) throws {
        guard isTrusted() else {
            throw ReaderCaptureError.notTrusted(.appleBooks)
        }
        guard isRunning() else {
            throw ReaderCaptureError.notRunning(.appleBooks)
        }
        activate()
        _ = try? focus()
        // A resize or reflow can briefly remove the reader window from AX.
        var firstPage: BooksLivePage?
        for attempt in 0..<15 {
            if let page = try? readPage(), page.isReading {
                firstPage = page
                break
            }
            sleep(attempt == 0 ? 0.5 : 0.4)
        }
        guard let first = firstPage else {
            throw ReaderCaptureError.noWindow(.appleBooks)
        }
        guard let crop = first.cropRect else {
            throw ReaderCaptureError.noWindow(.appleBooks)
        }
        if let window = first.windowFrame {
            let rect = CGRect(
                x: window.x, y: window.y,
                width: window.width, height: window.height)
            guard !PageFrame.isFullScreen(rect) else {
                throw ReaderCaptureError.unsupported(
                    .appleBooks,
                    reason: "full-screen capture is not supported; leave "
                        + "the menu bar visible")
            }
        }
        guard crop.width > 100, crop.height > 100 else {
            throw ReaderCaptureError.captureFailed(
                .appleBooks,
                reason: "the spread is too small: "
                    + "\(Int(crop.width))×\(Int(crop.height))")
        }
        if pageSetupGuard?.request.pageSize == .a4 {
            guard
                let a4 = CapturePageSize.a4.points,
                abs(crop.width - a4.width) <= 1.5,
                abs(crop.height - a4.height) <= 1.5,
                crop.width < crop.height
            else {
                throw ReaderCaptureError.captureFailed(
                    .appleBooks,
                    reason: "A4 setup produced "
                        + "\(Int(crop.width))×\(Int(crop.height)) instead "
                        + "of one portrait A4 page")
            }
        }
        self.cancellation = cancellation
        self.readPage = readPage
        self.capture = capture ?? {
            rect in try BooksLive.pageImage(rect)
        }
        self.turnForward = turnForward
        self.turnBackward = turnBackward
        self.sleep = sleep
        self.now = now
        self.focus = focus
        self.recognize = recognize
        self.isUnobstructed = isUnobstructed
        self.hasLease = hasLease
        self.isFrontmost = isFrontmost
        self.activate = activate
        self.settleMinimum = settleMinimum
        self.settleTimeout = settleTimeout
        self.restoreTimeout = restoreTimeout
        self.initialWindow = first.windowFrame
        self.initialCrop = crop
        self.singlePage =
            pageSetupGuard?.request.pageSize == .a4
        self.pageSetupGuard = pageSetupGuard
        self.cropTop = max(0, cropTop)
        self.cropBottom = max(0, cropBottom ?? 54)
        self.opening = PageLocation(
            pageNumber: first.pageNumber, pageCount: first.pageCount)
        let title = first.title.trimmingCharacters(
            in: .whitespacesAndNewlines)
        self.identity = ObservedIdentity(
            title: title,
            confidence: title.isEmpty ? .unknown : .titleOnly(title))
        self.mode = CaptureMode(
            layout: .reflowable, navigation: .automatic,
            endDetection: .positive)
    }

    public var pageSetupOutcome: PageSetupOutcome? {
        pageSetupGuard?.outcome
    }

    public func snapshot() throws -> PageSnapshot {
        try checkCancelled()
        let live = try readCurrent()
        guard live.isReading else {
            throw ReaderCaptureError.notReading(
                .appleBooks, state: live.state)
        }
        try validate(live)
        guard let crop = live.cropRect else {
            throw ReaderCaptureError.noWindow(.appleBooks)
        }
        let raw = try capturePage(crop)
        let image = cropped(raw, crop: crop)
        try verifyUnchanged(since: live)
        let (text, textSource) = textFor(live: live, image: image)
        let page = snapshot(
            from: live, image: image, crop: crop,
            text: text, textSource: textSource)
        if openingMark == nil { openingMark = page.mark }
        return page
    }

    public func advance(after mark: PageMark) throws -> PageTransition {
        try checkCancelled()
        let before = try readCurrent()
        guard before.isReading else {
            throw ReaderCaptureError.notReading(
                .appleBooks, state: before.state)
        }
        // Validate before posting: a different reader window must not receive
        // this session's arrow keys.
        try validate(before)
        try requireLease()
        do {
            try turnForward()
        } catch {
            records.append(
                TurnRecord(
                    attempted: true, posted: false, observed: false,
                    terminal: false, unresolved: true))
            throw ReaderCaptureError.captureFailed(
                .appleBooks,
                reason: "could not send the page turn: \(error)")
        }

        sleep(settleMinimum)
        let deadline = now().addingTimeInterval(settleTimeout)
        var lastCaptureError: Error?
        do {
            while now() < deadline {
                try checkCancelled()
                guard let live = try? readCurrent(), live.isReading
                else {
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
                guard let crop = live.cropRect else {
                    sleep(0.05)
                    continue
                }
                let image: CGImage
                do {
                    let raw = try capturePage(crop)
                    image = cropped(raw, crop: crop)
                } catch {
                    lastCaptureError = error
                    sleep(0.05)
                    continue
                }
                let hash = ImageFingerprint.averageHash(image)
                // The image is the page of record: Books can erase or restore
                // its AX text without turning the page, so a text change
                // alone is not a turn.
                guard hash != mark.imageHash else {
                    sleep(0.10)
                    continue
                }

                // One changed frame is a candidate; wait for a second
                // matching frame so the PDF never stores an animation.
                sleep(0.12)
                guard let settled = try? readCurrent(),
                    settled.isReading,
                    let settledCrop = settled.cropRect
                else {
                    sleep(0.05)
                    continue
                }
                let settledImage: CGImage
                do {
                    let raw = try capturePage(settledCrop)
                    settledImage = cropped(raw, crop: settledCrop)
                } catch {
                    lastCaptureError = error
                    sleep(0.05)
                    continue
                }
                guard
                    ImageFingerprint.averageHash(settledImage) == hash
                else {
                    sleep(0.05)
                    continue
                }
                try validate(settled)
                try verifyUnchanged(since: settled)
                let (text, textSource) = textFor(
                    live: settled, image: settledImage)
                let observed = TurnRecord(
                    attempted: true, posted: true, observed: true,
                    terminal: false, unresolved: false)
                records.append(observed)
                return .turned(
                    snapshot(
                        from: settled, image: settledImage,
                        crop: settledCrop, text: text,
                        textSource: textSource),
                    observed)
            }
        } catch {
            let failed = TurnRecord(
                attempted: true, posted: true, observed: false,
                terminal: false, unresolved: true)
            records.append(failed)
            throw error
        }

        // No image change across the whole settle window. A slow turn has now
        // had the full timeout to arrive; only a frame that is still the
        // previous spread, with identity and keyboard lease intact, is the
        // end of the book.
        guard
            let end = try? readCurrent(),
            end.isReading,
            let endCrop = end.cropRect,
            let endRaw = try? capturePage(endCrop)
        else {
            let unresolved = TurnRecord(
                attempted: true, posted: true, observed: false,
                terminal: false, unresolved: true)
            records.append(unresolved)
            return .noTurn(
                unresolved,
                reason: "the page did not settle within "
                    + "\(Int(settleTimeout)) seconds"
                    + (lastCaptureError.map {
                        "; last capture error: \($0)"
                    } ?? ""))
        }
        let endImage = cropped(endRaw, crop: endCrop)
        guard ImageFingerprint.averageHash(endImage) == mark.imageHash
        else {
            let unresolved = TurnRecord(
                attempted: true, posted: true, observed: false,
                terminal: false, unresolved: true)
            records.append(unresolved)
            return .noTurn(
                unresolved,
                reason: "the final spread changed after the settle window")
        }
        try validate(end)
        guard hasLease() else {
            let failed = TurnRecord(
                attempted: true, posted: true, observed: false,
                terminal: false, unresolved: true)
            records.append(failed)
            throw ReaderCaptureError.captureFailed(
                .appleBooks,
                reason: "the reader lost keyboard focus during the page "
                    + "turn; an unchanged frame cannot prove the end")
        }
        let terminal = TurnRecord(
            attempted: true, posted: true, observed: true,
            terminal: true, unresolved: false)
        records.append(terminal)
        return .endOfBook(terminal)
    }

    public func restore() -> RestoreReport {
        if let storedRestore { return storedRestore }
        let attempted = records.filter(\.attempted).count
        let posted = records.filter(\.posted).count
        let observed = records.filter { $0.observed && !$0.terminal }.count
        let terminal = records.filter(\.terminal).count
        let unresolved = records.filter(\.unresolved).count

        var current = try? readCurrent()
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
        if observed > 0 {
            _ = try? focus()
            // A long capture must be able to unwind every observed turn.
            let budget = max(restoreTimeout, Double(observed) + 30)
            let deadline = now().addingTimeInterval(budget)
            for _ in 0..<observed {
                if now() >= deadline {
                    timedOut = true
                    break
                }
                guard let page = try? readCurrent(), page.isReading else {
                    backwardFailed = true
                    break
                }
                // Never send a backward arrow into a different window or an
                // app that lost keyboard focus.
                do {
                    try validate(page)
                } catch {
                    backwardFailed = true
                    break
                }
                guard hasLease() else {
                    backwardFailed = true
                    break
                }
                do {
                    try turnBackward()
                } catch {
                    backwardFailed = true
                }
                sleep(0.45)
            }
        }
        let final = try? readCurrent()
        let finalLocation = final.map {
            PageLocation(pageNumber: $0.pageNumber, pageCount: $0.pageCount)
        }
        var verificationFailed = false
        var exact: Bool
        if unresolved > 0 || backwardFailed || final?.isReading != true {
            exact = false
        } else if let openingMark, let final, final.isReading,
            let crop = final.cropRect,
            let raw = try? capturePage(crop)
        {
            // The image is the page of record; apply the same configured
            // crop the opening mark used, then compare hashes.
            let image = cropped(raw, crop: crop)
            exact =
                ImageFingerprint.averageHash(image)
                    == openingMark.imageHash
        } else {
            // Without a photographed opening there is nothing to compare; a
            // failed photo cannot prove exactness.
            exact = false
            verificationFailed = true
        }
        var setupProblem: String?
        if let pageSetupGuard {
            let outcome = pageSetupGuard.restore()
            if !outcome.restored {
                exact = false
                setupProblem =
                    "the page setup was not restored: "
                    + (outcome.reason ?? "unknown reason")
            }
        }
        let report = RestoreReport(
            opening: opening, final: finalLocation,
            attempted: attempted, posted: posted, observed: observed,
            terminal: terminal, unresolved: unresolved, exact: exact,
            reason: exact
                ? nil
                : setupProblem
                    ?? (timedOut
                        ? "restore timed out after "
                            + "\(Int(restoreTimeout)) seconds"
                        : backwardFailed
                            ? "a backward turn failed"
                            : verificationFailed
                                ? "the opening spread could not be "
                                    + "photographed"
                                : final?.isReading != true
                                    ? "the reader is not in a reading state"
                                    : "the opening spread could not be "
                                        + "verified"))
        storedRestore = report
        return report
    }

    private var isCancelled: Bool { cancellation.isSet }

    private func checkCancelled() throws {
        if isCancelled { throw ReaderCaptureError.cancelled }
    }

    private func readCurrent() throws -> BooksLivePage {
        do {
            return try readPage()
        } catch let error as BooksLiveError {
            switch error {
            case .notTrusted:
                throw ReaderCaptureError.notTrusted(.appleBooks)
            case .notRunning:
                throw ReaderCaptureError.notRunning(.appleBooks)
            case .noWindow:
                throw ReaderCaptureError.noWindow(.appleBooks)
            case .notReading(let state):
                throw ReaderCaptureError.notReading(
                    .appleBooks, state: state)
            case .readFailed(let message):
                throw ReaderCaptureError.captureFailed(
                    .appleBooks, reason: message)
            }
        } catch {
            throw ReaderCaptureError.captureFailed(
                .appleBooks, reason: "\(error)")
        }
    }

    private func requireLease() throws {
        if hasLease() { return }
        activate()
        _ = try? focus()
        // Refocusing can raise a different book. Read and validate the page
        // that will receive the key, not just the application.
        guard hasLease(), let page = try? readCurrent(), page.isReading else {
            throw ReaderCaptureError.captureFailed(
                .appleBooks,
                reason: "the reader window did not take keyboard focus; "
                    + "the page turn would be sent to another window")
        }
        try validate(page)
    }

    private func capturePage(_ rect: CGRect) throws -> CGImage {
        if !isFrontmost() {
            activate()
            sleep(0.35)
            guard isFrontmost() else {
                throw ReaderCaptureError.captureFailed(
                    .appleBooks,
                    reason: "another app is in front of Apple Books; "
                        + "refusing to photograph it")
            }
        }
        guard isUnobstructed(rect) else {
            throw ReaderCaptureError.captureFailed(
                .appleBooks,
                reason: "a window is covering the reader; refusing to "
                    + "photograph it")
        }
        let image: CGImage
        do {
            image = try capture(rect)
        } catch let error as ScreenCaptureError {
            throw ReaderCaptureError.captureFailed(
                .appleBooks, reason: error.description)
        } catch {
            throw ReaderCaptureError.captureFailed(
                .appleBooks, reason: "\(error)")
        }
        guard isUnobstructed(rect) else {
            throw ReaderCaptureError.captureFailed(
                .appleBooks,
                reason: "a window covered the reader during the screenshot")
        }
        return image
    }

    /// The text read and the screenshot are separate operations. Refuse a
    /// snapshot that pairs one spread's text with another spread's image.
    private func verifyUnchanged(since live: BooksLivePage) throws {
        guard
            let after = try? readCurrent(),
            after.isReading,
            after.text == live.text || after.text.isEmpty || live.text.isEmpty,
            after.windowFrame == live.windowFrame,
            after.cropRect == live.cropRect
        else {
            throw ReaderCaptureError.captureFailed(
                .appleBooks,
                reason: "the page changed while its screenshot was taken")
        }
    }

    private func validate(_ live: BooksLivePage) throws {
        guard let window = live.windowFrame else {
            throw ReaderCaptureError.captureFailed(
                .appleBooks, reason: "the reader window disappeared")
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
        if let initialWindow,
            abs(window.x - initialWindow.x) > 1
                || abs(window.y - initialWindow.y) > 1
                || abs(window.width - initialWindow.width) > 1
                || abs(window.height - initialWindow.height) > 1
        {
            throw ReaderCaptureError.captureFailed(
                .appleBooks,
                reason: "the reader window moved during capture")
        }
        if let crop = live.cropRect,
            abs(crop.width - initialCrop.width) > 1
                || abs(crop.height - initialCrop.height) > 1
        {
            throw ReaderCaptureError.captureFailed(
                .appleBooks,
                reason: "the spread changed size during capture")
        }
    }

    /// Books can expose half a spread's text. OCR the captured spread and
    /// prefer it only when it is materially longer than the AX text; the page
    /// source records which was used. The first Vision call also loads the
    /// model, which is why this runs once per captured spread rather than
    /// only when the AX text looks short.
    private func textFor(
        live: BooksLivePage, image: CGImage
    ) -> (String, ReaderTextSource) {
        let ax = live.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recognized = try? recognize(image) else {
            return (ax, ax.isEmpty ? .none : .accessibility)
        }
        let ocr = recognized.trimmingCharacters(
            in: .whitespacesAndNewlines)
        // A much longer result is a partial AX read. Similar lengths can
        // still be different text (a stale AX tree labelling a new image);
        // low token overlap then means the OCR text describes this image and
        // the AX text does not.
        if ocr.count > ax.count + 80 {
            return (ocr, .ocr)
        }
        if !ax.isEmpty, !ocr.isEmpty, tokenOverlap(ax, ocr) < 0.5 {
            return (ocr, .ocr)
        }
        return (ax, ax.isEmpty ? .none : .accessibility)
    }

    private func tokenOverlap(_ left: String, _ right: String) -> Double {
        let leftTokens = Set(words(left))
        let rightTokens = Set(words(right))
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        let intersection = leftTokens.intersection(rightTokens).count
        let union = leftTokens.union(rightTokens).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init)
    }

    private func cropped(_ raw: CGImage, crop: CGRect) -> CGImage {
        PageFooter.removingInsets(
            from: raw, crop: crop,
            topPoints: CGFloat(cropTop),
            bottomPoints: CGFloat(cropBottom)) ?? raw
    }

    private func snapshot(
        from live: BooksLivePage, image: CGImage, crop: CGRect,
        text: String, textSource: ReaderTextSource
    ) -> PageSnapshot {
        let hash = ImageFingerprint.averageHash(image)
        let toolbars = live.windowFrame.map { window in
            max(0, crop.minY - CGFloat(window.y))
        } ?? 0
        let calibration = PageFrameCalibration(
            insets: CaptureInsets(
                top: Double(toolbars), bottom: 0, left: 0, right: 0),
            status: .derived,
            reason: "the spread starts below the measured reader toolbar",
            chrome: nil, headroom: nil)
        return PageSnapshot(
            identity: identity,
            image: image,
            text: text,
            textSource: textSource,
            pageNumber: live.pageNumber,
            pageCount: live.pageCount,
            location: PageLocation(
                pageNumber: live.pageNumber, pageCount: live.pageCount),
            isEndOfBook: live.endOfBook,
            cropRect: crop,
            pixelSize: CGSize(
                width: CGFloat(image.width), height: CGFloat(image.height)),
            mark: PageMark(imageHash: hash, text: text),
            calibration: calibration,
            textFrame: nil,
            spread: !singlePage)
    }
}
