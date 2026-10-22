import CoreGraphics
import Foundation
import KindleAX
import Testing

@testable import TsundokuCore

private enum BooksTestFailure: Error {
    case noImage
}

private func booksImage(gray: CGFloat) throws -> CGImage {
    guard
        let context = CGContext(
            data: nil, width: 1024, height: 716,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw BooksTestFailure.noImage }
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 716))
    // A uniform fill hashes to all zeros; use a stripe so the two fake
    // spreads have distinct average hashes, as real pages do.
    context.setFillColor(
        CGColor(gray: gray > 0.5 ? 0.05 : 0.95, alpha: 1))
    // Move the stripe with the shade so different pages cannot share an
    // average hash.
    context.fill(
        CGRect(x: CGFloat(gray) * 760, y: 0, width: 180, height: 716))
    guard let image = context.makeImage() else {
        throw BooksTestFailure.noImage
    }
    return image
}

private final class FakeBooksReader: @unchecked Sendable {
    let images: [CGImage]
    let clock: BooksClock
    var index = 0
    var text = "page one"
    var title = "A Book"
    var lease = true
    var end = false
    var forwardEnabled = true
    var textOnlyForward = false
    var captureFails = false
    var turnDelay: TimeInterval = 0
    var forwardCalls = 0
    var backwardCalls = 0
    private var pendingAt: TimeInterval?
    var crop = CGRect(x: 10, y: 62, width: 1024, height: 716)
    let window = AXNode.Frame(x: 10, y: 10, width: 1024, height: 768)

    init(clock: BooksClock) throws {
        self.clock = clock
        images = [try booksImage(gray: 0.2), try booksImage(gray: 0.8)]
    }

    private func applyPending() {
        guard let pendingAt, clock.value >= pendingAt else { return }
        self.pendingAt = nil
        index = min(index + 1, images.count - 1)
        text = "page two"
    }

    var image: CGImage { images[index] }

    func page() -> BooksLivePage {
        applyPending()
        return BooksLivePage(
            state: text.isEmpty ? "readingNoText" : "reading",
            title: title,
            text: text,
            windowFrame: window,
            textFrames: [],
            webAreaFrames: [],
            pageNumber: nil,
            pageCount: nil,
            endOfBook: end,
            windowMain: true,
            windowFocused: false,
            cropRect: crop)
    }

    func forward() {
        forwardCalls += 1
        guard forwardEnabled else { return }
        if textOnlyForward {
            text = "ghost text"
            return
        }
        if turnDelay <= 0 {
            index = min(index + 1, images.count - 1)
            text = "page two"
        } else {
            pendingAt = clock.value + turnDelay
        }
    }

    func backward() {
        backwardCalls += 1
        index = max(index - 1, 0)
        text = "page one"
    }
}

private final class BooksClock: @unchecked Sendable {
    var value: TimeInterval = 0
    func now() -> Date { Date(timeIntervalSince1970: value) }
    func advance(_ interval: TimeInterval) { value += interval }
}

private let booksFocus = BooksFocusReport(
    activated: true, frontmost: true, windowMain: true,
    windowFocused: false, raised: true,
    focusedWindowTitle: "A Book", focusedRole: "AXWindow",
    focusedFrame: nil)

private func makeBooksSession(
    _ reader: FakeBooksReader,
    _ clock: BooksClock,
    isTrusted: @escaping () -> Bool = { true },
    cropTop: Int = 0, cropBottom: Int? = nil
) throws -> BooksCaptureSession {
    try BooksCaptureSession(
        subject: CaptureSubject(book: nil, kind: .appleBooks),
        cancellation: ClosureCancellation({ false }),
        readPage: { reader.page() },
        capture: { _ in
            if reader.captureFails {
                throw BooksTestFailure.noImage
            }
            return reader.image
        },
        turnForward: { reader.forward() },
        turnBackward: { reader.backward() },
        sleep: { clock.advance($0) },
        now: { clock.now() },
        isTrusted: isTrusted,
        isRunning: { true },
        isFrontmost: { true },
        activate: {},
        focus: { booksFocus },
        recognize: { _ in "" },
        isUnobstructed: { _ in true },
        hasLease: { reader.lease },
        settleMinimum: 0,
        settleTimeout: 2,
        cropTop: cropTop,
        cropBottom: cropBottom)
}

@Suite("Books capture session")
struct BooksCaptureTests {
    @Test("horizontal preload beyond the window is excluded")
    func horizontalPreloadExcluded() {
        let root = AXNode(
            role: "AXWindow",
            frame: AXNode.Frame(x: 0, y: 0, width: 600, height: 900),
            children: [
                AXNode(
                    role: "AXWebArea",
                    frame: AXNode.Frame(x: 0, y: 0, width: 600, height: 800),
                    children: [
                        AXNode(
                            role: "AXStaticText", value: .text("Visible"),
                            frame: AXNode.Frame(
                                x: 30, y: 60, width: 300, height: 20)),
                        AXNode(
                            role: "AXStaticText", value: .text("Preload"),
                            frame: AXNode.Frame(
                                x: 3000, y: 60, width: 300, height: 20)),
                    ]),
            ])
        #expect(BooksPageText.text(from: root) == "Visible")
    }

    @Test("page text survives an offset web-area frame")
    func textSurvivesOffsetWebFrame() {
        let root = AXNode(
            role: "AXWindow",
            frame: AXNode.Frame(x: 477, y: 130, width: 1024, height: 768),
            children: [
                AXNode(
                    role: "AXWebArea",
                    frame: AXNode.Frame(
                        x: -1989, y: 250, width: 906, height: 564),
                    children: [
                        AXNode(
                            role: "AXStaticText",
                            value: .text("alpha"),
                            frame: AXNode.Frame(
                                x: 107, y: 252, width: 377, height: 52)),
                        AXNode(
                            role: "AXStaticText",
                            value: .text("beta"),
                            frame: AXNode.Frame(
                                x: 590, y: 329, width: 393, height: 52)),
                    ]),
            ])
        #expect(BooksPageText.text(from: root) == "alpha\nbeta")
        #expect(BooksPageText.textFrames(in: root).count == 2)
    }

    @Test("a snapshot records the spread and its crop")
    func snapshotRecordsSpread() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(reader, clock)
        let page = try session.snapshot()
        #expect(page.spread)
        #expect(page.text == "page one")
        #expect(page.cropRect == reader.crop)
        #expect(page.pixelSize == CGSize(width: 1024, height: 662))
        #expect(page.calibration?.insets.top == 52)
        #expect(session.mode.layout == .reflowable)
        #expect(session.identity.title == "A Book")
    }

    @Test("configured top and bottom crops trim the page image")
    func configuredCrop() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(
            reader, clock, cropTop: 20, cropBottom: 54)
        let page = try session.snapshot()
        #expect(page.pixelSize == CGSize(width: 1024, height: 642))
    }

    @Test("a page turn advances to the next spread")
    func turnAdvances() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        let transition = try session.advance(after: first.mark)
        guard case .turned(let next, let record) = transition else {
            Issue.record("expected a turn, got \(transition)")
            return
        }
        #expect(next.text == "page two")
        #expect(record.observed)
        #expect(!record.terminal)
    }

    @Test("an unchanged spread with the lease held is the end of the book")
    func unchangedIsEnd() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        reader.forwardEnabled = false
        let transition = try session.advance(after: first.mark)
        guard case .endOfBook(let record) = transition else {
            Issue.record("expected end of book, got \(transition)")
            return
        }
        #expect(record.terminal)
    }

    @Test("an unchanged spread without the lease is a focus failure")
    func unchangedWithoutLeaseFails() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        reader.lease = false
        #expect(throws: ReaderCaptureError.self) {
            _ = try session.advance(after: first.mark)
        }
    }

    @Test("restore returns to the opening spread")
    func restoreReturnsToOpening() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        _ = try session.advance(after: first.mark)
        let report = session.restore()
        #expect(report.exact)
        #expect(report.observed == 1)
        #expect(reader.index == 0)
    }

    @Test("a slow turn is a turn, not the end of the book")
    func slowTurnIsNotEnd() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        reader.turnDelay = 1.2
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        let transition = try session.advance(after: first.mark)
        guard case .turned(let next, _) = transition else {
            Issue.record("a turn at 1.2s was read as \(transition)")
            return
        }
        #expect(next.text == "page two")
    }

    @Test("an AX text change without a new image is not a turn")
    func textOnlyChangeIsNotATurn() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        reader.textOnlyForward = true
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        let transition = try session.advance(after: first.mark)
        guard case .endOfBook = transition else {
            Issue.record("text-only change became \(transition)")
            return
        }
    }

    @Test("a changed book posts no page turn")
    func changedBookPostsNoKey() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        reader.title = "Another Book"
        #expect(throws: ReaderCaptureError.self) {
            _ = try session.advance(after: first.mark)
        }
        #expect(reader.forwardCalls == 0)
    }

    @Test("restore stops when the lease is lost")
    func restoreStopsWithoutLease() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        _ = try session.advance(after: first.mark)
        reader.lease = false
        let report = session.restore()
        #expect(!report.exact)
        #expect(reader.backwardCalls == 0)
    }

    @Test("an empty-text opening still restores exactly")
    func emptyTextOpeningRestores() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        reader.text = ""
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        _ = try session.advance(after: first.mark)
        let report = session.restore()
        #expect(report.exact)
        #expect(reader.index == 0)
    }

    @Test("a failed restore photograph cannot claim exactness")
    func failedRestorePhotoIsNotExact() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(reader, clock)
        let first = try session.snapshot()
        _ = try session.advance(after: first.mark)
        reader.captureFails = true
        let report = session.restore()
        #expect(!report.exact)
    }

    @Test("partial AX text falls back to OCR")
    func partialTextUsesOCR() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try BooksCaptureSession(
            subject: CaptureSubject(book: nil, kind: .appleBooks),
            cancellation: ClosureCancellation({ false }),
            readPage: { reader.page() },
            capture: { _ in reader.image },
            turnForward: { reader.forward() },
            turnBackward: { reader.backward() },
            sleep: { clock.advance($0) },
            now: { clock.now() },
            isTrusted: { true },
            isRunning: { true },
            isFrontmost: { true },
            activate: {},
            focus: { booksFocus },
            recognize: { _ in String(repeating: "x", count: 2000) },
            isUnobstructed: { _ in true },
            hasLease: { reader.lease },
            settleMinimum: 0,
            settleTimeout: 2)
        let page = try session.snapshot()
        #expect(page.textSource == .ocr)
        #expect(page.text?.count == 2000)
    }

    @Test("stale AX text with no overlap is replaced by OCR")
    func staleTextUsesOCR() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        reader.text = String(repeating: "alpha ", count: 60)
        let session = try BooksCaptureSession(
            subject: CaptureSubject(book: nil, kind: .appleBooks),
            cancellation: ClosureCancellation({ false }),
            readPage: { reader.page() },
            capture: { _ in reader.image },
            turnForward: { reader.forward() },
            turnBackward: { reader.backward() },
            sleep: { clock.advance($0) },
            now: { clock.now() },
            isTrusted: { true },
            isRunning: { true },
            isFrontmost: { true },
            activate: {},
            focus: { booksFocus },
            recognize: { _ in
                String(repeating: "beta ", count: 60)
            },
            isUnobstructed: { _ in true },
            hasLease: { reader.lease },
            settleMinimum: 0,
            settleTimeout: 2)
        let page = try session.snapshot()
        #expect(page.textSource == .ocr)
        #expect(page.text?.contains("beta") == true)
    }

    @Test("the crop starts below the top toolbar only")
    func cropUsesTopToolbar() {
        let window = CGRect(x: 477, y: 130, width: 1024, height: 768)
        let top = AXNode.Frame(x: 477, y: 130, width: 1024, height: 52)
        let bottom = AXNode.Frame(x: 477, y: 826, width: 1024, height: 48)
        let crop = BooksLive.cropRect(
            window: window, toolbarFrames: [top, bottom])
        #expect(crop == CGRect(x: 477, y: 182, width: 1024, height: 716))
        #expect(
            BooksLive.cropRect(window: window, toolbarFrames: [bottom])
                == nil)
        #expect(
            BooksLive.cropRect(window: window, toolbarFrames: []) == nil)
    }

    @Test("an A4 session marks a single page, not a spread")
    func a4SinglePage() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        reader.crop = CGRect(x: 10, y: 62, width: 595.28, height: 841.89)
        let setup = BooksPageSetup(request: PageSetupRequest(pageSize: .a4))
        let session = try BooksCaptureSession(
            subject: CaptureSubject(book: nil, kind: .appleBooks),
            cancellation: ClosureCancellation({ false }),
            readPage: { reader.page() },
            capture: { _ in reader.image },
            turnForward: { reader.forward() },
            turnBackward: { reader.backward() },
            sleep: { clock.advance($0) },
            now: { clock.now() },
            isTrusted: { true },
            isRunning: { true },
            isFrontmost: { true },
            activate: {},
            focus: { booksFocus },
            recognize: { _ in "" },
            isUnobstructed: { _ in true },
            hasLease: { reader.lease },
            settleMinimum: 0,
            settleTimeout: 2,
            pageSetupGuard: setup)
        let page = try session.snapshot()
        #expect(!page.spread)
        #expect(page.cropRect.width < page.cropRect.height)
    }

    @Test("a landscape A4 crop is refused")
    func landscapeA4Refused() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        reader.crop = CGRect(x: 10, y: 62, width: 842, height: 595)
        let setup = BooksPageSetup(request: PageSetupRequest(pageSize: .a4))
        #expect(throws: ReaderCaptureError.self) {
            _ = try BooksCaptureSession(
                subject: CaptureSubject(book: nil, kind: .appleBooks),
                cancellation: ClosureCancellation({ false }),
                readPage: { reader.page() },
                capture: { _ in reader.image },
                turnForward: { reader.forward() },
                turnBackward: { reader.backward() },
                sleep: { clock.advance($0) },
                now: { clock.now() },
                isTrusted: { true },
                isRunning: { true },
                isFrontmost: { true },
                activate: {},
                focus: { booksFocus },
                recognize: { _ in "" },
                isUnobstructed: { _ in true },
                hasLease: { reader.lease },
                settleMinimum: 0,
                settleTimeout: 2,
                pageSetupGuard: setup)
        }
    }

    @Test("a title change aborts the run")
    func titleChangeFails() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        let session = try makeBooksSession(reader, clock)
        _ = try session.snapshot()
        reader.title = "Another Book"
        #expect(throws: ReaderCaptureError.self) {
            _ = try session.snapshot()
        }
    }

    @Test("an untrusted process cannot start a Books session")
    func untrustedFails() throws {
        let clock = BooksClock()
        let reader = try FakeBooksReader(clock: clock)
        #expect(throws: ReaderCaptureError.self) {
            _ = try makeBooksSession(
                reader, clock, isTrusted: { false })
        }
    }
}

private final class FakeBooksWindow: @unchecked Sendable {
    var window = CGRect(x: 0, y: 0, width: 1024, height: 768)
    var title = "A Book"
    var a4 = false
    var offset = 0
    var fontStep = 0
    var backwardCalls = 0
    let originalImage: CGImage
    let shiftedImage: CGImage
    let a4Image: CGImage

    init() throws {
        originalImage = try booksImage(gray: 0.2)
        shiftedImage = try booksImage(gray: 0.4)
        a4Image = try booksImage(gray: 0.9)
    }

    var crop: CGRect {
        a4
            ? CGRect(x: 0, y: 52, width: 595.28, height: 841.89)
            : CGRect(x: 0, y: 52, width: 1024, height: 716)
    }

    func page() -> BooksLivePage {
        BooksLivePage(
            state: "reading", title: title,
            text: (a4 ? "a4 page" : "spread \(offset)")
                + " font\(fontStep)",
            windowFrame: AXNode.Frame(
                x: Double(window.minX), y: Double(window.minY),
                width: Double(window.width), height: Double(window.height)),
            textFrames: [], webAreaFrames: [],
            pageNumber: nil, pageCount: nil, endOfBook: false,
            windowMain: true, windowFocused: false, cropRect: crop)
    }

    func write(_ frame: CGRect) -> CGRect {
        window = frame
        a4 = frame.width < 700
        if !a4 { offset = 1 }
        return frame
    }

    func capture(_ rect: CGRect) -> CGImage {
        if a4 { return a4Image }
        return offset == 0 ? originalImage : shiftedImage
    }

    func backward() {
        backwardCalls += 1
        offset = 0
    }

    func forward() {
        offset = 1
    }

    func pressMenu(_ title: String) -> Bool {
        switch title {
        case "Increase Font Size":
            fontStep += 1
            return true
        case "Decrease Font Size":
            fontStep -= 1
            return true
        default:
            return false
        }
    }
}

@Suite("Books page setup")
struct BooksPageSetupTests {
    @Test("A4 resizes to one page and restores the spread")
    func resizeAndRestore() throws {
        let fake = try FakeBooksWindow()
        #expect(
            ImageFingerprint.averageHash(fake.originalImage)
                != ImageFingerprint.averageHash(fake.shiftedImage))
        let setup = BooksPageSetup(
            request: PageSetupRequest(pageSize: .a4),
            readWindow: { fake.window },
            writeWindow: { fake.write($0) },
            readPage: { fake.page() },
            capture: { _ in fake.capture(.zero) },
            turnForward: { fake.forward() },
            turnBackward: { fake.backward() },
            activate: {},
            sleep: { _ in },
            displays: { [CGRect(x: 0, y: 0, width: 1920, height: 1080)] })
        let began = try setup.begin()
        #expect(!began.restored)
        #expect(began.finalWindow?.width ?? 0 < 700)
        #expect(fake.a4)
        let restored = setup.restore()
        #expect(restored.restored)
        #expect(fake.window.width == 1024)
        #expect(fake.backwardCalls == 1)
    }

    @Test("Books text size steps are applied and restored")
    func textStepsRestore() throws {
        let fake = try FakeBooksWindow()
        let setup = BooksPageSetup(
            request: PageSetupRequest(booksFontSteps: 2),
            readWindow: { fake.window },
            writeWindow: { fake.write($0) },
            readPage: { fake.page() },
            capture: { _ in fake.capture(.zero) },
            turnForward: { fake.forward() },
            turnBackward: { fake.backward() },
            pressMenu: { fake.pressMenu($0) },
            activate: {},
            sleep: { _ in },
            displays: { [CGRect(x: 0, y: 0, width: 1920, height: 1080)] })
        let began = try setup.begin()
        #expect(began.fontSteps == 2)
        #expect(fake.fontStep == 2)
        let restored = setup.restore()
        #expect(restored.fontSteps == 2)
        #expect(fake.fontStep == 0)
    }

    @Test("A4 without a toolbar is refused and the window is restored")
    func noToolbarRefused() throws {
        let fake = try FakeBooksWindow()
        #expect(
            ImageFingerprint.averageHash(fake.originalImage)
                != ImageFingerprint.averageHash(fake.shiftedImage))
        let setup = BooksPageSetup(
            request: PageSetupRequest(pageSize: .a4),
            readWindow: { fake.window },
            writeWindow: { fake.write($0) },
            readPage: {
                BooksLivePage(
                    state: "reading", title: fake.title, text: "x",
                    windowFrame: AXNode.Frame(
                        x: 0, y: 0, width: 1024, height: 768),
                    textFrames: [], webAreaFrames: [],
                    pageNumber: nil, pageCount: nil, endOfBook: false,
                    windowMain: true, windowFocused: false,
                    cropRect: CGRect(x: 0, y: 0, width: 1024, height: 768))
            },
            capture: { _ in fake.originalImage },
            turnForward: {},
            turnBackward: {},
            activate: {},
            sleep: { _ in },
            displays: { [CGRect(x: 0, y: 0, width: 1920, height: 1080)] })
        #expect(throws: PageSetupError.self) {
            _ = try setup.begin()
        }
        #expect(fake.window.width == 1024)
    }
}


@Suite("Page-number footer")
struct PageFooterTests {
    @Test("the Books footer is cropped at the measured inset")
    func booksFooter() throws {
        let image = try booksImage(gray: 0.2)
        let crop = CGRect(x: 0, y: 0, width: 1024, height: 716)
        let cropped = try #require(
            PageFooter.removingBooksPageNumber(from: image, crop: crop))
        #expect(cropped.height == 662)
        #expect(cropped.width == 1024)
    }

    @Test("configured insets trim both edges")
    func configuredInsets() throws {
        let image = try booksImage(gray: 0.2)
        let crop = CGRect(x: 0, y: 0, width: 1024, height: 716)
        let trimmed = try #require(
            PageFooter.removingInsets(
                from: image, crop: crop, topPoints: 20,
                bottomPoints: 54))
        #expect(trimmed.height == 642)
        #expect(trimmed.width == 1024)
    }

    @Test("a detected Kindle number crops above it")
    func kindleNumber() throws {
        let image = try booksImage(gray: 0.2)
        let stripBox = CGRect(x: 0.45, y: 0.02, width: 0.1, height: 0.03)
        let cropped = try #require(
            PageFooter.removingDetectedPageNumber(
                from: image,
                recognize: { _ in [("12", stripBox)] }))
        #expect(cropped.height < image.height)
        #expect(cropped.height > 600)
    }

    @Test("body text in the strip is not a page number")
    func bodyTextIsNotANumber() throws {
        let image = try booksImage(gray: 0.2)
        let box = CGRect(x: 0.1, y: 0.02, width: 0.3, height: 0.03)
        #expect(
            PageFooter.removingDetectedPageNumber(
                from: image,
                recognize: { _ in [("chapter", box)] }) == nil)
        #expect(
            PageFooter.removingDetectedPageNumber(
                from: image,
                recognize: { _ in [("12", CGRect(x: 0.01, y: 0.02, width: 0.1, height: 0.03))] })
                == nil)
    }

    @Test("a thumbnail is not scanned")
    func thumbnailSkipped() throws {
        let small = try booksImage(gray: 0.2)
            .cropping(to: CGRect(x: 0, y: 0, width: 300, height: 300))
        let image = try #require(small)
        #expect(
            PageFooter.removingDetectedPageNumber(
                from: image,
                recognize: { _ in [("12", CGRect(x: 0.45, y: 0.02, width: 0.1, height: 0.03))] })
                == nil)
    }
}
