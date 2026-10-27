import CoreGraphics
import Foundation
import KindleAX

/// A forward-only Kindle capture that starts at the page the reader prepared.
///
/// It never activates Kindle, changes page setup, rewinds, or restores. The
/// engine still owns the artifact store and PDF; this session owns the window
/// capture, the crop, the turn ledger, and the page identity.
public final class ManualKindleCaptureSession: ReaderCaptureSession {
    public private(set) var identity: ObservedIdentity = ObservedIdentity(
        title: "", confidence: .unknown)
    public let mode = CaptureMode(
        layout: .reflowable, navigation: .automatic,
        endDetection: .positive)
    public var isManualCapture: Bool { true }
    public var captureWarnings: [String] { warnings }

    public typealias Read = () throws -> LivePage
    public typealias Capture = @Sendable (
        CGRect?, @escaping @Sendable () -> Bool
    ) throws -> CapturedWindow
    public typealias Turn = () throws -> Void
    public typealias Escape = () throws -> Void
    public typealias Prepare = () throws -> Void
    public typealias Sleep = (TimeInterval) -> Void
    public typealias Now = () -> Date

    private let crop: CaptureCrop
    private let expectedMark: PageMark?
    private let expectedPageNumber: Int?
    private let isResume: Bool
    private let cancellation: any CancellationChecking
    private let read: Read
    private let capture: Capture
    private let turnForward: Turn
    private let escape: Escape
    private let prepare: Prepare
    private let sleep: Sleep
    private let now: Now
    private var expectedSize: CGSize?
    private var opening: PageLocation?
    private var openingBookID: String?
    private var lastPage: LivePage?
    private var warnings: [String] = []

    public init(
        crop: CaptureCrop,
        cancellation: any CancellationChecking,
        expectedWindow: CGRect? = nil,
        expectedMark: PageMark? = nil,
        expectedPageNumber: Int? = nil,
        isResume: Bool = false,
        read: @escaping Read = { try KindleLive.currentPage() },
        capture: @escaping Capture = { expected, cancelled in
            try WindowCaptureService().capture(
                expectedFrame: expected, isCancelled: cancelled)
        },
        turnForward: @escaping Turn = { try KindleLive.turnForward() },
        escape: @escaping Escape = { try KindleLive.escape() },
        prepare: @escaping Prepare = { try KindleLive.ensureMainWindow() },
        sleep: @escaping Sleep = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping Now = Date.init
    ) {
        self.crop = crop
        self.expectedMark = expectedMark
        self.expectedPageNumber = expectedPageNumber
        self.isResume = isResume
        self.cancellation = cancellation
        self.read = read
        self.capture = capture
        self.turnForward = turnForward
        self.escape = escape
        self.prepare = prepare
        self.sleep = sleep
        self.now = now
        if let expectedWindow {
            self.expectedSize = expectedWindow.size
        }
    }

    /// Read the reader identity before the engine's wrong-book guard runs.
    /// The engine checks identity before the first snapshot, so a manual
    /// session that leaves it unknown until then disables that guard.
    public func prime() throws {
        try checkCancelled()
        let live = try read()
        guard live.isReading else {
            throw ReaderCaptureError.notReading(
                .kindle, state: live.state)
        }
        if let bookID = live.bookID, !bookID.isEmpty {
            openingBookID = bookID
        }
        identity = ObservedIdentity(page: live)
    }

    public func snapshot() throws -> PageSnapshot {
        try makeSnapshot(includeText: true)
    }

    /// Capture a page. Polls use `includeText: false` to avoid running Vision
    /// on every candidate; the confirmed page is captured once with text.
    private func makeSnapshot(includeText: Bool) throws -> PageSnapshot {
        try checkCancelled()
        if opening == nil { try prepare() }
        let live = try read()
        guard live.isReading else {
            throw ReaderCaptureError.notReading(
                .kindle, state: live.state)
        }
        guard let frame = live.windowFrame else {
            throw ReaderCaptureError.noWindow(.kindle)
        }
        let window = CGRect(
            x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        if let expectedSize {
            guard PageFrame.sameSize(window.size, expectedSize, tolerance: 4)
            else {
                throw ReaderCaptureError.captureFailed(
                    .kindle,
                    reason: "the Kindle window changed size; refresh the "
                        + "preview before capturing")
            }
        } else {
            expectedSize = window.size
        }
        if let openingBookID, let bookID = live.bookID,
            !bookID.isEmpty, openingBookID != bookID
        {
            throw ReaderCaptureError.identityChanged(
                expected: openingBookID, observed: bookID)
        }
        if openingBookID == nil, let bookID = live.bookID, !bookID.isEmpty {
            openingBookID = bookID
        }
        let captured = try capture(window, { [cancellation] in
            cancellation.isSet
        })
        let afterCapture = try read()
        guard afterCapture.sameContent(as: live) else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the page changed while its screenshot was taken")
        }
        guard PageFrame.sameRect(captured.windowFrame, window, tolerance: 4)
        else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "ScreenCaptureKit returned a different window; "
                    + "refresh the preview and try again")
        }
        let cropGlobal = crop.global(in: captured.windowFrame)
        let pixelRect = try CropTransform.pixelRect(
            crop: crop, windowFrame: captured.windowFrame,
            contentRect: captured.contentRect,
            imageSize: CGSize(
                width: captured.image.width, height: captured.image.height))
        let image = try CropTransform.croppedImage(
            captured.image, crop: pixelRect)
        let resolved = try CropTransform.resolvedCrop(
            crop: crop, windowFrame: captured.windowFrame,
            contentRect: captured.contentRect,
            imageSize: CGSize(
                width: captured.image.width, height: captured.image.height))
        let textFrame = live.pageTextFrame.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        let textUse: (text: String?, source: ReaderTextSource) =
            includeText
            ? text(
                live: live, cropGlobal: cropGlobal,
                image: image, textFrame: textFrame)
            : (nil, .none)
        if includeText, textUse.source == .none, !live.text.isEmpty {
            let warning =
                "page \(live.pageNumber.map(String.init) ?? "?"): the crop "
                + "removed text and OCR returned no text"
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        let mark = PageMark(
            imageHash: ImageFingerprint.detailHash(image),
            text: textUse.text ?? "")
        if opening == nil, let expectedMark {
            let imageMatches = expectedMark.imageHash == mark.imageHash
            let textMatches =
                !expectedMark.text.isEmpty && expectedMark.text == mark.text
            let pageMatches =
                expectedPageNumber == nil || live.pageNumber == nil
                || expectedPageNumber == live.pageNumber
            if !imageMatches, !(textMatches && pageMatches) {
                throw ReaderCaptureError.captureFailed(
                    .kindle,
                    reason: isResume
                        ? "the reader is not showing the page this capture "
                            + "stopped on; turn to it and resume again"
                        : "the page changed since the preview; review the "
                            + "current page before capturing")
            }
        }
        identity = ObservedIdentity(page: live)
        opening = opening ?? PageLocation(
            pageNumber: live.pageNumber, pageCount: live.pageCount)
        lastPage = live
        return PageSnapshot(
            identity: identity, image: image, text: textUse.text,
            textSource: textUse.source, pageNumber: live.pageNumber,
            pageCount: live.pageCount,
            location: PageLocation(
                pageNumber: live.pageNumber, pageCount: live.pageCount),
            isEndOfBook: live.endOfBook,
            cropRect: resolved.global(in: captured.windowFrame),
            pixelSize: CGSize(
                width: image.width, height: image.height),
            mark: mark,
            calibration: nil,
            textFrame: textFrame,
            spread: false)
    }

    public func advance(after mark: PageMark) throws -> PageTransition {
        try checkCancelled()
        try prepare()
        try turnForward()
        if let turned = try poll(after: mark, until: now().addingTimeInterval(3))
        {
            return turned
        }
        // A footnote link or a selection can hold keyboard focus and swallow
        // the arrow. Escape changes no page, so clearing it cannot skip one;
        // the page still has to change before the turn counts.
        try? escape()
        sleep(0.05)
        try turnForward()
        if let turned = try poll(after: mark, until: now().addingTimeInterval(1.5))
        {
            return turned
        }
        return .noTurn(
            TurnRecord(
                attempted: true, posted: true, observed: false,
                terminal: false, unresolved: true),
            reason: "the page did not change")
    }

    /// Polls for a settled page. Returns nil when the deadline passes without
    /// one, leaving the retry decision to the caller.
    private func poll(
        after mark: PageMark, until deadline: Date
    ) throws -> PageTransition? {
        var nextImageProbe = now()
        while now() < deadline {
            sleep(0.10)
            try checkCancelled()
            guard let live = try? read() else { continue }
            try checkWindowSize(live)
            if live.endOfBook {
                return .endOfBook(
                    TurnRecord(
                        attempted: true, posted: true, observed: true,
                        terminal: true, unresolved: false))
            }
            guard live.isReading else { continue }
            let pageNumberChanged =
                live.pageNumber != nil && lastPage?.pageNumber != nil
                && live.pageNumber != lastPage?.pageNumber
            let textChanged = live.text != lastPage?.text
            // Text and page number usually settle before the image. Only
            // probe the image when AX reports nothing, or periodically for
            // an image-only page.
            if !textChanged, !pageNumberChanged, now() < nextImageProbe {
                continue
            }
            nextImageProbe = now().addingTimeInterval(0.5)
            guard let candidate = try? makeSnapshot(includeText: false)
            else { continue }
            guard candidate.mark.imageHash != mark.imageHash
                || pageNumberChanged
            else { continue }
            // One changed frame is a candidate, not a settled page. The
            // confirmation reads the text in the same pass and must show the
            // same pixels after a short settle; a third full capture bought
            // nothing the confirmation had not already checked.
            sleep(0.10)
            guard let confirmed = try? makeSnapshot(includeText: true),
                confirmed.mark.imageHash == candidate.mark.imageHash
            else { continue }
            return .turned(
                confirmed,
                TurnRecord(
                    attempted: true, posted: true, observed: true,
                    terminal: false, unresolved: false))
        }
        return nil
    }

    public func restore() -> RestoreReport {
        RestoreReport(
            opening: opening,
            final: lastPage.map {
                PageLocation(
                    pageNumber: $0.pageNumber, pageCount: $0.pageCount)
            },
            attempted: 0, posted: 0, observed: 0, terminal: 0,
            unresolved: 0, exact: false,
            reason: "manual capture does not restore the reader")
    }

    public func rewindToStart() throws -> RewindReport {
        RewindReport(
            attempted: false, reachedStart: false, turns: 0,
            method: "manual",
            reason: "manual capture starts at the prepared page")
    }

    public var rewindOutcome: RewindReport? { nil }

    private func checkCancelled() throws {
        if cancellation.isSet { throw ReaderCaptureError.cancelled }
    }

    private func checkWindowSize(_ live: LivePage) throws {
        guard let expectedSize, let frame = live.windowFrame else { return }
        guard PageFrame.sameSize(
            CGSize(width: frame.width, height: frame.height),
            expectedSize, tolerance: 4)
        else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the Kindle window changed size; refresh the "
                    + "preview before capturing")
        }
    }

    private func text(
        live: LivePage, cropGlobal: CGRect, image: CGImage,
        textFrame: CGRect?
    ) -> (text: String?, source: ReaderTextSource) {
        let coversText =
            textFrame.map {
                cropGlobal.insetBy(dx: -1, dy: -1).contains($0)
            } ?? false
        if coversText, !live.text.isEmpty {
            return (live.text, .accessibility)
        }
        if let recognised = try? BooksOCR.recognize(image),
            !recognised.isEmpty
        {
            return (recognised, .ocr)
        }
        return (nil, .none)
    }
}
