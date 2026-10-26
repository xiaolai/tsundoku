import CoreGraphics
import Foundation
import KindleAX
import Testing

@testable import TsundokuCore

private enum CaptureTestFailure: Error {
    case noImage
    case noTransition
}

private func testImage(width: Int = 200, height: Int = 300) throws
    -> CGImage
{
    guard
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CaptureTestFailure.noImage }
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw CaptureTestFailure.noImage
    }
    return image
}

private func testSnapshot(
    title: String = "A Book", text: String = "page", page: Int = 1,
    width: Int = 200, height: Int = 300, hash: UInt64 = 1
) throws -> PageSnapshot {
    let image = try testImage(width: width, height: height)
    return PageSnapshot(
        identity: ObservedIdentity(
            title: title, confidence: .titleOnly(title)),
        image: image, text: text, textSource: .accessibility,
        pageNumber: page, pageCount: 10,
        location: PageLocation(pageNumber: page, pageCount: 10),
        isEndOfBook: false,
        cropRect: CGRect(x: 0, y: 0, width: width, height: height),
        pixelSize: CGSize(width: width, height: height),
        mark: PageMark(imageHash: hash, text: text))
}

private func record(
    posted: Bool = true, observed: Bool = true, terminal: Bool = false,
    unresolved: Bool = false
) -> TurnRecord {
    TurnRecord(
        attempted: true, posted: posted, observed: observed,
        terminal: terminal, unresolved: unresolved)
}

private final class FakeSession: ReaderCaptureSession {
    let identity: ObservedIdentity
    let mode = CaptureMode(
        layout: .reflowable, navigation: .automatic,
        endDetection: .positive)
    var snapshots: [PageSnapshot]
    var transitions: [PageTransition]
    var restoreCalls = 0
    var advanceCalls = 0
    var snapshotCalls = 0
    var onRestore: (() -> Void)?
    var pageSetupOutcome: PageSetupOutcome?
    var restoreReport: RestoreReport
    var rewindReport: RewindReport? = RewindReport(
        attempted: true, reachedStart: true, turns: 3, method: "fake",
        reason: nil)
    var rewindCalls = 0
    var snapshotError: Error?
    var captureWarnings: [String] = []
    var isManualCapture = false

    func rewindToStart() throws -> RewindReport {
        rewindCalls += 1
        return rewindReport ?? RewindReport(
            attempted: true, reachedStart: true, turns: 0, method: "fake",
            reason: nil)
    }

    var rewindOutcome: RewindReport? { rewindReport }

    init(
        identity: ObservedIdentity,
        snapshots: [PageSnapshot],
        transitions: [PageTransition],
        restoreReport: RestoreReport? = nil
    ) {
        self.identity = identity
        self.snapshots = snapshots
        self.transitions = transitions
        self.restoreReport = restoreReport ?? RestoreReport(
            opening: PageLocation(pageNumber: 1, pageCount: 10),
            final: PageLocation(pageNumber: 1, pageCount: 10),
            attempted: 0, posted: 0, observed: 0, terminal: 0,
            unresolved: 0, exact: true, reason: nil)
    }

    func snapshot() throws -> PageSnapshot {
        snapshotCalls += 1
        if let snapshotError { throw snapshotError }
        return snapshots.removeFirst()
    }

    func advance(after mark: PageMark) throws -> PageTransition {
        advanceCalls += 1
        guard !transitions.isEmpty else {
            throw CaptureTestFailure.noTransition
        }
        return transitions.removeFirst()
    }

    func restore() -> RestoreReport {
        restoreCalls += 1
        onRestore?()
        return restoreReport
    }
}

private func temporaryArchive() throws -> (Archive, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tsundoku-capture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    let archive = try Archive(
        path: directory.appendingPathComponent("archive.sqlite"))
    return (archive, directory)
}

private func run(
    _ session: FakeSession, archive: Archive, directory: URL,
    book: Book? = nil, pageLimit: Int? = nil,
    isCancelled: @escaping @Sendable () -> Bool = { false },
    lifecycle: CaptureLifecycle = CaptureLifecycle(locked: { false }),
    cleanPage: CleanPageRequest? = nil,
    progress: @escaping @Sendable (CaptureProgress) -> Void = { _ in }
) throws -> CaptureResult {
    try CaptureJobEngine(archive: archive).run(
        session: session,
        subject: CaptureSubject(book: book, kind: .kindle),
        pageLimit: pageLimit,
        output: directory.appendingPathComponent("capture"),
        progress: progress,
        isCancelled: isCancelled,
        lifecycle: lifecycle,
        cleanPage: cleanPage)
}

private func book(title: String) -> Book {
    Book(
        asin: "B000000001", title: title, author: "Author",
        bookType: 10, readState: 0)
}

private func manifest(at result: CaptureResult) throws
    -> [String: Any]
{
    let data = try Data(
        contentsOf: result.directory.appendingPathComponent("manifest.json"))
    return try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Capture contracts")
struct CaptureContractTests {
    @Test("a manual session does not report its no-restore as a fault")
    func manualRestoreIsNotAWarning() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))],
            restoreReport: RestoreReport(
                opening: nil, final: nil, attempted: 0, posted: 0,
                observed: 0, terminal: 0, unresolved: 0, exact: false,
                reason: "manual capture does not restore the reader"))
        session.isManualCapture = true
        let result = try run(
            session, archive: archive, directory: directory, pageLimit: 1)
        let warnings = try #require(
            try manifest(at: result)["warnings"] as? [String])
        #expect(!warnings.contains("restore not exact"))
    }

    @Test("session warnings survive the final manifest")
    func sessionWarningsSurvive() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        session.captureWarnings = ["the crop removed text and OCR failed"]
        let result = try run(
            session, archive: archive, directory: directory, pageLimit: 1)
        let warnings = try #require(
            try manifest(at: result)["warnings"] as? [String])
        #expect(warnings.contains("the crop removed text and OCR failed"))
    }

    @Test("end of book produces one PDF and restores once")
    func endOfBook() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        let result = try run(session, archive: archive, directory: directory)
        #expect(result.pages == 1)
        #expect(PDFWriter.pageCount(result.pdf) == 1)
        #expect(session.restoreCalls == 1)
        #expect(try manifest(at: result)["termination"] as? String
            == "endOfBook")
        #expect(
            (try manifest(at: result)["complete"] as? [String: Bool])?[
                "wholeBook"] == true)
    }

    @Test("a page limit stops before another turn")
    func pageLimit() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try testSnapshot(page: 1)
        let second = try testSnapshot(page: 2, hash: 2)
        let session = FakeSession(
            identity: first.identity, snapshots: [first],
            transitions: [.turned(second, record())])
        let result = try run(
            session, archive: archive, directory: directory, pageLimit: 1)
        #expect(result.pages == 1)
        #expect(session.advanceCalls == 0)
        #expect(try manifest(at: result)["termination"] as? String
            == "pageLimit")
    }

    @Test("a wrong selected book is refused before pages are written")
    func wrongBook() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot(title: "Open Book")
        let session = FakeSession(
            identity: page.identity, snapshots: [page], transitions: [])
        #expect(throws: ReaderCaptureError.self) {
            try run(
                session, archive: archive, directory: directory,
                book: book(title: "Selected Book"))
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("capture/pages").path))
    }

    @Test("a changed raster size fails with the page index")
    func wrongRaster() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try testSnapshot(page: 1)
        let second = try testSnapshot(page: 2, width: 100, hash: 2)
        let session = FakeSession(
            identity: first.identity, snapshots: [first],
            transitions: [.turned(second, record())])
        #expect(throws: ReaderCaptureError.self) {
            try run(
                session, archive: archive, directory: directory,
                pageLimit: 2)
        }
        #expect(session.restoreCalls == 1)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                "capture/book.pdf").path))
    }

    @Test("a no-turn transition is a typed failure and restores")
    func noTurn() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.noTurn(record(observed: false), reason: "busy")])
        #expect(throws: ReaderCaptureError.self) {
            try run(
                session, archive: archive, directory: directory,
                pageLimit: 2)
        }
        #expect(session.restoreCalls == 1)
    }

    @Test("cancellation stops the run and restores")
    func cancellation() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page], transitions: [])
        let flag = CancellationFlag()
        flag.set()
        #expect(throws: ReaderCaptureError.self) {
            try run(
                session, archive: archive, directory: directory,
                pageLimit: 2, isCancelled: { flag.isSet })
        }
        #expect(session.restoreCalls == 1)
    }

    @Test("equal marks are ambiguous, not a rejected page")
    func equalMarksAreAmbiguous() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try testSnapshot(page: 1, hash: 7)
        let second = try testSnapshot(page: 2, hash: 7)
        let session = FakeSession(
            identity: first.identity, snapshots: [first],
            transitions: [.turned(second, record())])
        let result = try run(
            session, archive: archive, directory: directory, pageLimit: 2)
        #expect(result.pages == 2)
    }

    @Test("capture progress reports a known total and remaining time")
    func progressEstimate() {
        let all = CaptureProgress(
            page: 2, pageLimit: nil, totalPages: 10,
            estimatedRemaining: 16, message: "Captured page 2 of 10")
        #expect(all.fraction == 0.2)
        #expect(all.estimatedRemaining == 16)
        let limited = CaptureProgress(
            page: 3, pageLimit: 10, message: "Captured page 3")
        #expect(limited.fraction == 0.3)
        #expect(limited.estimatedRemaining == nil)
    }

    @Test("a cancelled turn still records the posted key")
    func cancelledTurnLedger() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)
        let live = LivePage(
            state: "readingChromeHidden", text: "page", title: "A Book",
            characters: 4, windowFrame: frame, pageTextFrame: text,
            endOfBook: false, pageNumber: 5, pageCount: 20)
        let flag = CancellationFlag()
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: flag,
            readPage: { live },
            capture: { _ in try testImage() },
            turnForward: { flag.set() },
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        let mark = PageMark(imageHash: 1, text: "page")
        #expect(throws: ReaderCaptureError.self) {
            _ = try session.advance(after: mark)
        }
        let report = session.restore()
        #expect(report.posted == 1)
        #expect(report.observed == 0)
        #expect(report.unresolved == 1)
    }

    @Test("a dropped key is recorded as attempted, not posted")
    func droppedTurn() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)
        let live = LivePage(
            state: "readingChromeHidden", text: "page", title: "A Book",
            characters: 4, windowFrame: frame, pageTextFrame: text,
            endOfBook: false, pageNumber: 5, pageCount: 20)
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { live },
            capture: { _ in try testImage() },
            turnForward: {
                throw ReaderCaptureError.captureFailed(
                    .kindle, reason: "key delivery refused")
            },
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        let mark = PageMark(imageHash: 1, text: "page")
        #expect(throws: ReaderCaptureError.self) {
            _ = try session.advance(after: mark)
        }
        let report = session.restore()
        #expect(report.attempted == 1)
        #expect(report.posted == 0)
        #expect(report.unresolved == 1)
    }

    @Test("restore refuses to press keys on a non-reading surface")
    func nonReadingRestore() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let reading = LivePage(
            state: "readingChromeHidden", text: "page", title: "A Book",
            characters: 4, windowFrame: frame, pageTextFrame: nil,
            endOfBook: false, pageNumber: 5, pageCount: 20)
        let library = LivePage(
            state: "notReading", text: "", title: "Library",
            characters: 0, windowFrame: frame, pageTextFrame: nil,
            endOfBook: false, pageNumber: nil, pageCount: nil)
        final class Box: @unchecked Sendable {
            var page: LivePage
            init(_ page: LivePage) { self.page = page }
        }
        let box = Box(reading)
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { box.page },
            capture: { _ in try testImage() },
            turnForward: {},
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        box.page = library
        let report = session.restore()
        #expect(!report.exact)
        #expect(report.reason?.contains("not in a reading state") == true)
    }

    @Test("restore drift is recorded in the manifest")
    func restoreDrift() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))],
            restoreReport: RestoreReport(
                opening: PageLocation(pageNumber: 1, pageCount: 10),
                final: PageLocation(pageNumber: 2, pageCount: 10),
                attempted: 0, posted: 0, observed: 0, terminal: 1,
                unresolved: 0, exact: false, reason: "drift"))
        let result = try run(session, archive: archive, directory: directory)
        let all = try manifest(at: result)
        let restore = try #require(all["restore"] as? [String: Any])
        #expect(restore["exact"] as? Bool == false)
    }

    @Test("a whole-book capture returns to the first page first")
    func wholeBookRewinds() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        let result = try run(session, archive: archive, directory: directory)
        #expect(session.rewindCalls == 1)
        let all = try manifest(at: result)
        let rewind = try #require(all["rewind"] as? [String: Any])
        #expect(rewind["reachedStart"] as? Bool == true)
        #expect(rewind["turns"] as? Int == 3)
    }

    @Test("a limited capture does not return to the first page")
    func limitedCaptureDoesNotRewind() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page], transitions: [])
        _ = try run(
            session, archive: archive, directory: directory, pageLimit: 1)
        #expect(session.rewindCalls == 0)
    }

    @Test("a rewind that cannot reach the first page fails the capture")
    func failedRewindFails() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        session.rewindReport = RewindReport(
            attempted: true, reachedStart: false, turns: 10,
            method: "fake", reason: "still moving")
        #expect(throws: ReaderCaptureError.self) {
            try run(session, archive: archive, directory: directory)
        }
        #expect(session.snapshotCalls == 0)
    }

    @Test("a Kindle rewind presses back until the page stops changing")
    func kindleRewinds() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        final class Box: @unchecked Sendable {
            var index: Int
            init(index: Int) { self.index = index }
        }
        let box = Box(index: 2)
        func page(_ index: Int) -> LivePage {
            LivePage(
                state: "readingChromeHidden", text: "page \(index + 1)",
                title: "A Book", characters: 6, windowFrame: frame,
                pageTextFrame: nil, endOfBook: false,
                pageNumber: index + 1, pageCount: 3)
        }
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { page(box.index) },
            capture: { _ in try testImage() },
            turnForward: {},
            turnBackward: {
                if box.index > 0 { box.index -= 1 }
            },
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {},
            settleMinimum: 0,
            settleTimeout: 0.05)
        let report = try session.rewindToStart()
        #expect(report.reachedStart)
        #expect(box.index == 0)
        // Two pages moved, then three presses at the first page confirm it.
        #expect(report.turns == 5)
        #expect(session.rewindOutcome == report)
    }

    @Test("a Kindle rewind steps over a cover it cannot capture")
    func kindleRewindSkipsCover() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)
        final class Box: @unchecked Sendable {
            var index: Int
            init(index: Int) { self.index = index }
        }
        let box = Box(index: 2)
        func page(_ index: Int) -> LivePage {
            // The first page is a full-page cover: its text box leaves no
            // headroom for the chrome crop, so the capture box is refused.
            if index == 0 {
                return LivePage(
                    state: "readingChromeHidden", text: "", title: "A Book",
                    characters: 0, windowFrame: frame, pageTextFrame: frame,
                    endOfBook: false, pageNumber: 1, pageCount: 3,
                    chromeInsets: CaptureInsets(
                        top: 54, bottom: 54, left: 52, right: 52))
            }
            return LivePage(
                state: "readingChromeHidden", text: "page \(index + 1)",
                title: "A Book", characters: 6, windowFrame: frame,
                pageTextFrame: text, endOfBook: false,
                pageNumber: index + 1, pageCount: 3)
        }
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { page(box.index) },
            capture: { _ in try testImage() },
            turnForward: {
                if box.index < 2 { box.index += 1 }
            },
            turnBackward: {
                if box.index > 0 { box.index -= 1 }
            },
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {},
            settleMinimum: 0,
            settleTimeout: 0.05)
        let report = try session.rewindToStart()
        #expect(report.reachedStart)
        #expect(report.skippedPages == 1)
        #expect(box.index == 1)
    }

    @Test("a late page number does not fail an otherwise unchanged snapshot")
    func latePageNumber() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)
        final class Box: @unchecked Sendable {
            var page: LivePage
            init(_ page: LivePage) { self.page = page }
        }
        let initial = LivePage(
            state: "readingChromeHidden", text: " Image", title: "A Book",
            characters: 6, windowFrame: frame, pageTextFrame: text,
            endOfBook: false, pageNumber: nil, pageCount: nil)
        let known = LivePage(
            state: "readingChromeHidden", text: " Image", title: "A Book",
            characters: 6, windowFrame: frame, pageTextFrame: text,
            endOfBook: false, pageNumber: 6, pageCount: 20)
        let box = Box(initial)
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { box.page },
            capture: { _ in
                // Kindle supplies the page number while the screenshot is
                // being taken.
                box.page = known
                return try testImage()
            },
            turnForward: {},
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        let snapshot = try session.snapshot()
        #expect(snapshot.text == " Image")
    }

    @Test("a session can start on a cover and calibrate on the first text page")
    func startingOnACoverCalibrates() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)
        final class Box: @unchecked Sendable {
            var page: LivePage
            init(_ page: LivePage) { self.page = page }
        }
        let cover = LivePage(
            state: "readingChromeHidden", text: "", title: "A Book",
            characters: 0, windowFrame: frame, pageTextFrame: frame,
            endOfBook: false, pageNumber: 1, pageCount: 10,
            chromeInsets: CaptureInsets(
                top: 54, bottom: 54, left: 52, right: 52))
        let body = LivePage(
            state: "readingChromeHidden", text: "body text", title: "A Book",
            characters: 9, windowFrame: frame, pageTextFrame: text,
            endOfBook: false, pageNumber: 2, pageCount: 10)
        let box = Box(cover)
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { box.page },
            capture: { _ in try testImage() },
            turnForward: {},
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        // Starting on the cover must not fail the session.
        box.page = body
        let snapshot = try session.snapshot()
        #expect(snapshot.text == "body text")
    }

    @Test("a locked session refuses before creating pages")
    func lockedSession() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        #expect(throws: ReaderCaptureError.self) {
            try run(
                session, archive: archive, directory: directory,
                lifecycle: CaptureLifecycle(locked: { true }))
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("capture/pages").path))
    }

    @Test("a book change mid-run is rejected")
    func identityChange() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)
        func page(_ title: String, _ body: String) -> LivePage {
            LivePage(
                state: "readingChromeHidden", text: body, title: title,
                characters: body.count, windowFrame: frame,
                pageTextFrame: text, endOfBook: false,
                pageNumber: 1, pageCount: 20)
        }
        var reads = [
            page("A Book", "one"), page("A Book", "one"),
            page("B Book", "two"), page("B Book", "two"),
        ]
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { reads.removeFirst() },
            capture: { _ in try testImage() },
            turnForward: {},
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        #expect(throws: ReaderCaptureError.self) {
            _ = try session.advance(
                after: PageMark(imageHash: 42, text: "one"))
        }
    }

    @Test("a text change accepts a turn when the image hash collides")
    func hashCollisionTurn() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)
        func page(_ body: String) -> LivePage {
            LivePage(
                state: "readingChromeHidden", text: body, title: "A Book",
                characters: body.count, windowFrame: frame,
                pageTextFrame: text, endOfBook: false,
                pageNumber: 1, pageCount: 20)
        }
        var reads = [
            page("one"), page("one"), page("two"), page("two"),
            page("two"), page("two"), page("two"),
        ]
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { reads.removeFirst() },
            capture: { _ in try testImage() },
            turnForward: {},
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        let transition = try session.advance(
            after: PageMark(imageHash: 0, text: "one"))
        guard case .turned(let snapshot, _) = transition else {
            Issue.record("expected a text-driven turn")
            return
        }
        #expect(snapshot.text == "two")
    }

    @Test("cancellation on the last page is not success")
    func cancellationAfterLastPage() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        let flag = CancellationFlag()
        #expect(throws: ReaderCaptureError.self) {
            try run(
                session, archive: archive, directory: directory,
                isCancelled: { flag.isSet },
                progress: { _ in flag.set() })
        }
        let data = try Data(
            contentsOf: directory.appendingPathComponent(
                "capture/manifest.json"))
        let manifest = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["state"] as? String == "cancelled")
        #expect(
            (manifest["complete"] as? [String: Bool])?["wholeBook"] == false)
    }

    @Test("restore is bounded and reports a timeout")
    func boundedRestore() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)
        func page(_ number: Int, _ body: String) -> LivePage {
            LivePage(
                state: "readingChromeHidden", text: body, title: "A Book",
                characters: body.count, windowFrame: frame,
                pageTextFrame: text, endOfBook: false,
                pageNumber: number, pageCount: 20)
        }
        final class Counter: @unchecked Sendable {
            var backward = 0
            var reads: [LivePage] = []
            var time: TimeInterval = 0
        }
        let counter = Counter()
        counter.reads = [
            page(1, "one"), page(2, "two"), page(3, "three"),
            page(3, "three"),
        ]
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: {
                if counter.reads.isEmpty { return page(3, "three") }
                return counter.reads.removeFirst()
            },
            capture: { _ in try testImage() },
            turnForward: {},
            turnBackward: { counter.backward += 1 },
            escape: {},
            sleep: { _ in },
            now: {
                counter.time += 1
                return Date(timeIntervalSince1970: counter.time)
            },
            isTrusted: { true },
            isRunning: { true },
            activate: {},
            settleTimeout: 100,
            restoreTimeout: 0)
        let mark = PageMark(imageHash: 42, text: "one")
        let transition = try session.advance(after: mark)
        guard case .turned = transition else {
            Issue.record("expected a settled turn")
            return
        }
        let report = session.restore()
        #expect(report.observed == 1)
        #expect(report.exact == false)
        #expect(report.reason?.contains("timed out") == true)
        #expect(counter.backward == 0)
    }

    @Test("a terminal sheet is recorded and dismissed before restore")
    func terminalSheet() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)
        let reading = LivePage(
            state: "readingChromeHidden", text: "page", title: "A Book",
            characters: 4, windowFrame: frame, pageTextFrame: text,
            endOfBook: false, pageNumber: 5, pageCount: 20)
        let end = LivePage(
            state: "notReading", text: "", title: "A Book",
            characters: 0, windowFrame: frame, pageTextFrame: nil,
            endOfBook: true, pageNumber: nil, pageCount: nil)
        var reads = [reading, reading, reading, end]
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { reads.isEmpty ? reading : reads.removeFirst() },
            capture: { _ in try testImage() },
            turnForward: {},
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        let mark = PageMark(imageHash: 1, text: "page")
        let transition = try session.advance(after: mark)
        guard case .endOfBook(let record) = transition else {
            Issue.record("expected end of book")
            return
        }
        #expect(record.terminal)
        #expect(record.posted)
        let report = session.restore()
        #expect(report.terminal == 1)
        #expect(report.observed == 0)
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ event: String) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class ScriptedPanel: PopularHighlightsPanel, @unchecked Sendable {
    var value: Bool
    var failState = false
    var failSetOnCall: Int?
    var setCalls = 0

    init(_ value: Bool) { self.value = value }

    func state() throws -> Bool {
        if failState { throw CleanPageError.stateUnreadable }
        return value
    }

    func set(_ on: Bool) throws {
        setCalls += 1
        if setCalls == failSetOnCall {
            throw CleanPageError.toggleFailed(expected: on, actual: value)
        }
        value = on
    }
}

@Suite("Clean page capture integration")
struct CleanPageCaptureTests {
    private func request(_ panel: ScriptedPanel) -> CleanPageRequest {
        CleanPageRequest(
            policy: .hidePopularHighlights, panel: panel,
            journal: CleanPageJournal(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "tsundoku-engine-clean-\(UUID().uuidString).json")))
    }

    @Test("highlights are turned off, the page captured, and the state restored")
    func hideAndRestore() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        let panel = ScriptedPanel(true)
        let result = try run(
            session, archive: archive, directory: directory,
            cleanPage: request(panel))
        #expect(panel.value == true)
        #expect(result.cleanPage?.changed == true)
        #expect(result.cleanPage?.restored == true)
        let clean = try #require(
            try manifest(at: result)["cleanPage"] as? [String: Any])
        #expect(clean["policy"] as? String == "hidePopularHighlights")
        #expect(
            clean["popularHighlights"] as? String
                == "turned-off-then-restored")
        #expect(clean["restore"] as? String == "ok")
        #expect(clean["washRemoval"] as? Bool == false)
        #expect(clean.keys.contains("personalMarks"))
    }

    @Test("a refused control aborts before pages/ exists")
    func refusedBeforePages() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page], transitions: [])
        let panel = ScriptedPanel(true)
        panel.failState = true
        #expect(throws: ReaderCaptureError.self) {
            _ = try run(
                session, archive: archive, directory: directory,
                cleanPage: request(panel))
        }
        #expect(session.snapshotCalls == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("capture").path))
    }

    @Test("an exact identifier is published")
    func exactIdentifier() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: ObservedIdentity(
                title: "A Book", confidence: .exact("B0OBSERVED")),
            snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        let selected = Book(
            asin: "B0OBSERVED", title: "A Book", author: "Author",
            bookType: 10, readState: 0)
        let result = try run(
            session, archive: archive, directory: directory, book: selected)
        #expect(try manifest(at: result)["asin"] as? String == "B0OBSERVED")
    }

    @Test("an exact identifier that disagrees with the selection is refused")
    func exactIdentifierMismatch() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: ObservedIdentity(
                title: "A Book", confidence: .exact("B0OTHER")),
            snapshots: [page], transitions: [])
        let selected = Book(
            asin: "B0SELECTED", title: "A Book", author: "Author",
            bookType: 10, readState: 0)
        #expect(throws: ReaderCaptureError.self) {
            _ = try run(
                session, archive: archive, directory: directory,
                book: selected)
        }
    }

    @Test("the page setup outcome reaches the manifest")
    func pageSetupManifest() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        session.pageSetupOutcome = PageSetupOutcome(
            pageSize: .a4, requestedFont: 5, originalFont: 7, finalFont: 7,
            originalWindow: CGRect(x: 0, y: 0, width: 765, height: 871),
            finalWindow: CGRect(x: 0, y: 0, width: 765, height: 871),
            restored: true, reason: nil)
        let result = try run(session, archive: archive, directory: directory)
        let setup = try #require(
            try manifest(at: result)["pageSetup"] as? [String: Any])
        #expect(setup["pageSize"] as? String == "a4")
        #expect(setup["restored"] as? Bool == true)
        #expect(result.pageSetup?.requestedFont == 5)
    }

    @Test("an unknown identity is not a wrong-book failure")
    func unknownIdentity() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: ObservedIdentity(title: "", confidence: .unknown),
            snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        let result = try run(
            session, archive: archive, directory: directory,
            book: book(title: "A Book"))
        #expect(result.title == "A Book")
        let manifest = try manifest(at: result)
        #expect(manifest["title"] as? String == "A Book")
    }

    @Test("the session restore runs before the clean-page restore")
    func restoreOrder() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        final class OrderPanel: PopularHighlightsPanel, @unchecked Sendable {
            let events: LockedEvents
            var value = true
            init(events: LockedEvents) { self.events = events }
            func state() throws -> Bool {
                events.append("panel")
                return value
            }
            func set(_ on: Bool) throws {
                events.append("panel")
                value = on
            }
        }
        let events = LockedEvents()
        let panel = OrderPanel(events: events)
        session.onRestore = { events.append("restore") }
        let cleanRequest = CleanPageRequest(
            policy: .hidePopularHighlights, panel: panel,
            journal: CleanPageJournal(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "tsundoku-engine-clean-\(UUID().uuidString).json")))
        defer { cleanRequest.journal.clear() }
        let result = try run(
            session, archive: archive, directory: directory,
            cleanPage: cleanRequest)
        #expect(result.cleanPage?.restored == true)
        let restoreIndex = try #require(events.all.lastIndex(of: "restore"))
        let panelIndex = try #require(events.all.lastIndex(of: "panel"))
        // The clean-page read that restores the setting must happen after
        // the session has left any terminal sheet.
        #expect(restoreIndex < panelIndex)
    }

    @Test("an unwritable output restores the clean-page state")
    func unwritableOutputRestores() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page], transitions: [])
        let panel = ScriptedPanel(true)
        let output = directory.appendingPathComponent("capture")
        try Data("not a directory".utf8).write(to: output)
        let cleanRequest = request(panel)
        defer { cleanRequest.journal.clear() }
        #expect(throws: Error.self) {
            _ = try CaptureJobEngine(archive: archive).run(
                session: session,
                subject: CaptureSubject(book: nil, kind: .kindle),
                pageLimit: nil, output: output,
                progress: { _ in }, isCancelled: { false },
                lifecycle: CaptureLifecycle(locked: { false }),
                cleanPage: cleanRequest)
        }
        #expect(panel.value == true)
        #expect(cleanRequest.journal.load() == nil)
    }

    @Test("a failed restore is a warning, not a silent success")
    func failedRestoreWarns() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        let panel = ScriptedPanel(true)
        panel.failSetOnCall = 2 // the restore press fails
        let result = try run(
            session, archive: archive, directory: directory,
            cleanPage: request(panel))
        #expect(result.cleanPage?.restored == false)
        let warnings = try #require(
            try manifest(at: result)["warnings"] as? [String])
        #expect(
            warnings.contains { $0.hasPrefix("Popular Highlights was not") })
    }

    @Test("a clean restore failure is named in the capture error")
    func cleanRestoreFailureNamed() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page], transitions: [])
        let panel = ScriptedPanel(true)
        panel.failSetOnCall = 2 // the restore press fails
        let cleanRequest = request(panel)
        defer { cleanRequest.journal.clear() }
        do {
            _ = try run(
                session, archive: archive, directory: directory,
                cleanPage: cleanRequest)
            Issue.record("the capture must fail when no transition follows")
        } catch {
            #expect(
                "\(error)".contains(
                    "Popular Highlights was not restored"))
        }
    }

    @Test("as displayed never reads or writes the panel")
    func asDisplayed() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page],
            transitions: [.endOfBook(record(terminal: true))])
        let panel = ScriptedPanel(true)
        let result = try run(
            session, archive: archive, directory: directory,
            cleanPage: CleanPageRequest(
                policy: .asDisplayed, panel: panel,
                journal: CleanPageJournal(
                    url: FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "tsundoku-engine-clean-\(UUID().uuidString).json"))))
        #expect(panel.setCalls == 0)
        #expect(panel.value == true)
        let clean = try #require(
            try manifest(at: result)["cleanPage"] as? [String: Any])
        #expect(clean["popularHighlights"] as? String == "not-requested")
    }
}

@Suite("Layout signature and display policy")
struct LayoutSignatureTests {
    @Test("a window covering a whole display is full screen")
    func fullScreen() {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(PageFrame.isFullScreen(display, displays: [display]))
        #expect(
            !PageFrame.isFullScreen(
                display.insetBy(dx: 10, dy: 10), displays: [display]))
        #expect(!PageFrame.isFullScreen(display, displays: []))
    }

    @Test("restore verifies the opening by text when page numbers are absent")
    func textAnchorRestore() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        func page(_ text: String) -> LivePage {
            LivePage(
                state: "readingChromeHidden", text: text, title: "",
                characters: text.count, windowFrame: frame,
                pageTextFrame: nil, endOfBook: false,
                pageNumber: nil, pageCount: nil)
        }
        final class Box: @unchecked Sendable {
            var page: LivePage
            init(_ page: LivePage) { self.page = page }
        }
        let box = Box(page("one"))
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { box.page },
            capture: { _ in try testImage() },
            turnForward: { box.page = page("two") },
            turnBackward: { box.page = page("one") },
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        let first = try session.snapshot()
        _ = try session.advance(after: first.mark)
        let report = session.restore()
        #expect(report.observed == 1)
        #expect(report.exact)
    }

    @Test("a failed run records the real termination, not the seed")
    func failureTermination() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [page], transitions: [])
        #expect(throws: Error.self) {
            _ = try run(session, archive: archive, directory: directory)
        }
        let data = try Data(
            contentsOf: directory.appendingPathComponent(
                "capture/manifest.json"))
        let manifest = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let termination = try #require(manifest["termination"] as? String)
        #expect(termination.hasPrefix("failed:"))
        #expect(termination != "failed:the run did not start")
    }

    @Test("an initial snapshot failure records the real error")
    func initialSnapshotFailure() throws {
        let (archive, directory) = try temporaryArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try testSnapshot()
        let session = FakeSession(
            identity: page.identity, snapshots: [], transitions: [])
        session.snapshotError = ReaderCaptureError.captureFailed(
            .kindle, reason: "another app is in front of Kindle")
        #expect(throws: Error.self) {
            _ = try run(
                session, archive: archive, directory: directory,
                pageLimit: 1)
        }
        let data = try Data(
            contentsOf: directory.appendingPathComponent(
                "capture/manifest.json"))
        let manifest = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let termination = try #require(manifest["termination"] as? String)
        #expect(termination.contains("another app is in front"))
        #expect(
            (manifest["error"] as? String)?.contains(
                "another app is in front") == true)
        #expect(session.snapshotCalls == 3)
    }

    @Test("a page-count change stops the run")
    func pageCountChange() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        func page(_ count: Int) -> LivePage {
            LivePage(
                state: "readingChromeHidden", text: "one", title: "A Book",
                characters: 3, windowFrame: frame, pageTextFrame: nil,
                endOfBook: false, pageNumber: 1, pageCount: count)
        }
        final class Box: @unchecked Sendable {
            var page: LivePage
            init(_ page: LivePage) { self.page = page }
        }
        let box = Box(page(20))
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { box.page },
            capture: { _ in try testImage() },
            turnForward: {},
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        box.page = page(21)
        do {
            _ = try session.snapshot()
            Issue.record("a page-count change must stop the run")
        } catch let error as ReaderCaptureError {
            #expect("\(error)".contains("page count changed"))
        }
    }

    @Test("a text column change stops the run")
    func textWidthChange() throws {
        let frame = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        func page(_ width: Double) -> LivePage {
            LivePage(
                state: "readingChromeHidden", text: "one", title: "A Book",
                characters: 3, windowFrame: frame,
                pageTextFrame: AXNode.Frame(
                    x: 100, y: 100, width: width, height: 700),
                endOfBook: false, pageNumber: 1, pageCount: 20)
        }
        final class Box: @unchecked Sendable {
            var page: LivePage
            init(_ page: LivePage) { self.page = page }
        }
        let box = Box(page(600))
        let session = try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { box.page },
            capture: { _ in try testImage() },
            turnForward: {},
            turnBackward: {},
            escape: {},
            sleep: { _ in },
            now: Date.init,
            isTrusted: { true },
            isRunning: { true },
            activate: {})
        box.page = page(650)
        do {
            _ = try session.snapshot()
            Issue.record("a text-column change must stop the run")
        } catch let error as ReaderCaptureError {
            #expect("\(error)".contains("text column width changed"))
        }
    }
}
