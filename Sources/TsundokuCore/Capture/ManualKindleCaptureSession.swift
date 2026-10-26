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
    public typealias Prepare = () throws -> Void
    public typealias Sleep = (TimeInterval) -> Void
    public typealias Now = () -> Date

    private let crop: CaptureCrop
    private let expectedMark: PageMark?
    private let expectedPageNumber: Int?
    private let cancellation: any CancellationChecking
    private let read: Read
    private let capture: Capture
    private let turnForward: Turn
    private let prepare: Prepare
    private let sleep: Sleep
    private let now: Now
    private var expectedSize: CGSize?
    private var opening: PageLocation?
    private var openingBookID: String?
    private var lastPage: LivePage?
    private var lastMark: PageMark?
    private var records: [TurnRecord] = []
    private var warnings: [String] = []
    private var storedRestore: RestoreReport?

    public init(
        crop: CaptureCrop,
        cancellation: any CancellationChecking,
        expectedWindow: CGRect? = nil,
        expectedMark: PageMark? = nil,
        expectedPageNumber: Int? = nil,
        read: @escaping Read = { try KindleLive.currentPage() },
        capture: @escaping Capture = { expected, cancelled in
            try WindowCaptureService().capture(
                expectedFrame: expected, isCancelled: cancelled)
        },
        turnForward: @escaping Turn = { try KindleLive.turnForward() },
        prepare: @escaping Prepare = { try KindleLive.ensureMainWindow() },
        sleep: @escaping Sleep = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping Now = Date.init
    ) {
        self.crop = crop
        self.expectedMark = expectedMark
        self.expectedPageNumber = expectedPageNumber
        self.cancellation = cancellation
        self.read = read
        self.capture = capture
        self.turnForward = turnForward
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
            identity = ObservedIdentity(
                title: live.title.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                confidence: .exact(bookID))
        } else {
            let title = live.title.trimmingCharacters(
                in: .whitespacesAndNewlines)
            identity = ObservedIdentity(
                title: title,
                confidence: title.isEmpty ? .unknown : .titleOnly(title))
        }
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
            guard abs(window.width - expectedSize.width) <= 4,
                abs(window.height - expectedSize.height) <= 4
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
        guard afterCapture.isReading,
            afterCapture.text == live.text,
            afterCapture.windowFrame == live.windowFrame,
            afterCapture.bookID == live.bookID,
            afterCapture.endOfBook == live.endOfBook,
            afterCapture.pageNumber == live.pageNumber
                || afterCapture.pageNumber == nil || live.pageNumber == nil,
            afterCapture.pageCount == live.pageCount
                || afterCapture.pageCount == nil || live.pageCount == nil
        else {
            throw ReaderCaptureError.captureFailed(
                .kindle,
                reason: "the page changed while its screenshot was taken")
        }
        guard
            abs(captured.windowFrame.minX - window.minX) <= 4,
            abs(captured.windowFrame.minY - window.minY) <= 4,
            abs(captured.windowFrame.width - window.width) <= 4,
            abs(captured.windowFrame.height - window.height) <= 4
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
                    reason: "the page changed since the preview; review the "
                        + "current page before capturing")
            }
        }
        let title = live.title.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if let bookID = live.bookID, !bookID.isEmpty {
            identity = ObservedIdentity(
                title: title, confidence: .exact(bookID))
        } else {
            identity = ObservedIdentity(
                title: title,
                confidence: title.isEmpty ? .unknown : .titleOnly(title))
        }
        opening = opening ?? PageLocation(
            pageNumber: live.pageNumber, pageCount: live.pageCount)
        lastPage = live
        lastMark = mark
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
        let deadline = now().addingTimeInterval(3.0)
        while now() < deadline {
            sleep(0.15)
            try checkCancelled()
            guard let live = try? read() else { continue }
            try checkWindowSize(live)
            if live.endOfBook {
                let record = TurnRecord(
                    attempted: true, posted: true, observed: true,
                    terminal: true, unresolved: false)
                records.append(record)
                return .endOfBook(record)
            }
            guard live.isReading else { continue }
            let pageNumberChanged =
                live.pageNumber != nil && lastPage?.pageNumber != nil
                && live.pageNumber != lastPage?.pageNumber
            guard let candidate = try? makeSnapshot(includeText: false)
            else { continue }
            guard candidate.mark.imageHash != mark.imageHash
                || pageNumberChanged
            else { continue }
            // One changed frame is a candidate, not a settled page. Require
            // the same pixel hash after a short settle, then capture the page
            // once with its text.
            sleep(0.12)
            guard let confirmed = try? makeSnapshot(includeText: false),
                confirmed.mark.imageHash == candidate.mark.imageHash
            else { continue }
            guard let settled = try? makeSnapshot(includeText: true),
                settled.mark.imageHash == confirmed.mark.imageHash
            else { continue }
            let record = TurnRecord(
                attempted: true, posted: true, observed: true,
                terminal: false, unresolved: false)
            records.append(record)
            return .turned(settled, record)
        }
        let record = TurnRecord(
            attempted: true, posted: true, observed: false,
            terminal: false, unresolved: true)
        records.append(record)
        return .noTurn(record, reason: "the page did not change")
    }

    public func restore() -> RestoreReport {
        if let storedRestore { return storedRestore }
        let report = RestoreReport(
            opening: opening,
            final: lastPage.map {
                PageLocation(
                    pageNumber: $0.pageNumber, pageCount: $0.pageCount)
            },
            attempted: 0, posted: 0, observed: 0, terminal: 0,
            unresolved: 0, exact: false,
            reason: "manual capture does not restore the reader")
        storedRestore = report
        return report
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
        guard abs(frame.width - expectedSize.width) <= 4,
            abs(frame.height - expectedSize.height) <= 4
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
