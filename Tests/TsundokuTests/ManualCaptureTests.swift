import CoreGraphics
import Foundation
import KindleAX
import Testing

@testable import TsundokuCore

private enum ManualCaptureTestError: Error {
    case noImage
}

private func manualImage(width: Int, height: Int) throws -> CGImage {
    guard
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ManualCaptureTestError.noImage }
    context.setFillColor(CGColor(gray: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw ManualCaptureTestError.noImage
    }
    return image
}

private func livePage(
    text: String = "The page text.", title: String = "",
    frame: CGRect = CGRect(x: 100, y: 50, width: 400, height: 600),
    textRect: CGRect = CGRect(x: 152, y: 104, width: 296, height: 492),
    page: Int? = 4, pages: Int? = 20, bookID: String? = "B000000001",
    endOfBook: Bool = false, state: String = "readingChromeHidden"
) -> LivePage {
    LivePage(
        state: state, text: text, title: title,
        characters: text.count,
        windowFrame: AXNode.Frame(
            x: frame.minX, y: frame.minY,
            width: frame.width, height: frame.height),
        pageTextFrame: AXNode.Frame(
            x: textRect.minX, y: textRect.minY,
            width: textRect.width, height: textRect.height),
        endOfBook: endOfBook, pageNumber: page, pageCount: pages,
        bookID: bookID)
}

private final class FakeWindowCapture: WindowCapturing, @unchecked Sendable {
    var captured: CapturedWindow
    var calls = 0

    init(captured: CapturedWindow) {
        self.captured = captured
    }

    func capture(
        expectedFrame: CGRect?, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> CapturedWindow {
        calls += 1
        return captured
    }
}

@Suite("Manual capture geometry")
struct ManualCaptureGeometryTests {
    @Test("a main reader window is chosen over helper windows")
    func selectsMainWindow() throws {
        let helper = ShareableWindow(
            windowID: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 30),
            title: nil, layer: 0, isOnScreen: false)
        let main = ShareableWindow(
            windowID: 2,
            frame: CGRect(x: 100, y: 50, width: 400, height: 600),
            title: "Kindle", layer: 0, isOnScreen: true)
        let chosen = try WindowCaptureService.selectWindow(
            [helper, main], expectedFrame: nil)
        #expect(chosen.windowID == 2)
    }

    @Test("an expected frame selects the matching window")
    func selectsExpectedFrame() throws {
        let main = ShareableWindow(
            windowID: 2,
            frame: CGRect(x: 100, y: 50, width: 400, height: 600),
            title: "Kindle", layer: 0, isOnScreen: true)
        let other = ShareableWindow(
            windowID: 3,
            frame: CGRect(x: 800, y: 50, width: 400, height: 600),
            title: "Kindle", layer: 0, isOnScreen: true)
        let chosen = try WindowCaptureService.selectWindow(
            [main, other],
            expectedFrame: CGRect(x: 800, y: 50, width: 400, height: 600))
        #expect(chosen.windowID == 3)
    }

    @Test("an expected window that is absent is refused")
    func refusesMissingExpectedWindow() {
        let main = ShareableWindow(
            windowID: 2,
            frame: CGRect(x: 100, y: 50, width: 400, height: 600),
            title: "Kindle", layer: 0, isOnScreen: true)
        #expect(throws: WindowCaptureError.self) {
            try WindowCaptureService.selectWindow(
                [main],
                expectedFrame: CGRect(
                    x: 900, y: 50, width: 400, height: 600))
        }
    }

    @Test("two equally large windows are refused")
    func refusesAmbiguity() {
        let one = ShareableWindow(
            windowID: 2,
            frame: CGRect(x: 100, y: 50, width: 400, height: 600),
            title: "Kindle", layer: 0, isOnScreen: true)
        let two = ShareableWindow(
            windowID: 3,
            frame: CGRect(x: 800, y: 50, width: 400, height: 600),
            title: "Kindle", layer: 0, isOnScreen: true)
        #expect(throws: WindowCaptureError.self) {
            try WindowCaptureService.selectWindow(
                [one, two], expectedFrame: nil)
        }
    }

    @Test("crop pixels use the captured raster, not points")
    func cropPixelsAtTwoScales() throws {
        let window = CGRect(x: 100, y: 50, width: 400, height: 600)
        let content = window
        let crop = CaptureCrop(
            rect: CGRect(x: 52, y: 54, width: 296, height: 492))
        let one = try CropTransform.pixelRect(
            crop: crop, windowFrame: window, contentRect: content,
            imageSize: CGSize(width: 400, height: 600))
        #expect(one == CGRect(x: 52, y: 54, width: 296, height: 492))
        let two = try CropTransform.pixelRect(
            crop: crop, windowFrame: window, contentRect: content,
            imageSize: CGSize(width: 800, height: 1200))
        #expect(two == CGRect(x: 104, y: 108, width: 592, height: 984))
    }

    @Test("a content origin offset is removed, not guessed")
    func cropRemovesContentOffset() throws {
        let window = CGRect(x: 100, y: 50, width: 400, height: 600)
        let content = CGRect(x: 100, y: 78, width: 400, height: 572)
        let crop = CaptureCrop(
            rect: CGRect(x: 52, y: 54, width: 296, height: 492))
        let pixels = try CropTransform.pixelRect(
            crop: crop, windowFrame: window, contentRect: content,
            imageSize: CGSize(width: 800, height: 1144))
        #expect(pixels == CGRect(x: 104, y: 52, width: 592, height: 984))
    }

    @Test("an outside crop is refused")
    func outsideCropRefused() {
        let crop = CaptureCrop(
            rect: CGRect(x: 500, y: 54, width: 296, height: 492))
        #expect(throws: CropTransformError.self) {
            try CropTransform.pixelRect(
                crop: crop, windowFrame: CGRect(
                    x: 100, y: 50, width: 400, height: 600),
                contentRect: CGRect(
                    x: 100, y: 50, width: 400, height: 600),
                imageSize: CGSize(width: 400, height: 600))
        }
    }
}

@Suite("A4 fit planning")
struct A4FitTests {
    private let insets = CaptureInsets(
        top: 54, bottom: 54, left: 52, right: 52)

    @Test("a display with room keeps the width and produces A4")
    func widthFit() {
        let measurement = A4Measurement(
            window: CGRect(x: 100, y: 100, width: 400, height: 600),
            pageBox: CGRect(x: 152, y: 154, width: 296, height: 492),
            insets: insets)
        let result = A4FitPlanner.plan(
            measurement: measurement,
            display: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(result.mode == .widthFit)
        #expect(abs(result.pageRatio - CaptureCrop.a4Ratio) < 0.002)
        #expect(abs(result.pageBox.width - measurement.pageBox.width) < 1)
    }

    @Test("a height-limited display reduces the width and says so")
    func scaledToDisplay() {
        let measurement = A4Measurement(
            window: CGRect(x: 100, y: 600, width: 500, height: 700),
            pageBox: CGRect(x: 152, y: 654, width: 296, height: 450),
            insets: insets)
        let result = A4FitPlanner.plan(
            measurement: measurement,
            display: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(result.mode == .scaledToDisplay)
        #expect(abs(result.pageRatio - CaptureCrop.a4Ratio) < 0.002)
        #expect(result.frame.width < measurement.window.width)
    }

    @Test("a full-screen window is refused")
    func refusesFullScreen() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let measurement = A4Measurement(
            window: display,
            pageBox: CGRect(x: 52, y: 54, width: 1816, height: 972),
            insets: insets)
        let result = A4FitPlanner.plan(
            measurement: measurement, display: display)
        #expect(result.mode == .refused)
    }

    @Test("a display with no room refuses instead of leaving a non-A4 box")
    func refuses() {
        let measurement = A4Measurement(
            window: CGRect(x: 100, y: 900, width: 500, height: 700),
            pageBox: CGRect(x: 152, y: 954, width: 296, height: 450),
            insets: insets)
        let result = A4FitPlanner.plan(
            measurement: measurement,
            display: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(result.mode == .refused)
    }
}

@Suite("Page preview")
struct PagePreviewTests {
    private func capturedWindow() throws -> CapturedWindow {
        CapturedWindow(
            image: try manualImage(width: 400, height: 600),
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 7)
    }

    @Test("the preview uses the measured page box without turning a page")
    func previewUsesPageBox() throws {
        let captured = try capturedWindow()
        let fake = FakeWindowCapture(captured: captured)
        let read = LiveRead()
        let service = PagePreviewService(
            capture: fake, read: { read.next() })
        let preview = try service.preview()
        #expect(fake.calls == 1)
        #expect(read.calls == 2)
        #expect(preview.pageBox.width == 296)
        #expect(preview.pageBox.height == 492)
        #expect(preview.crop.rect.minX == 52)
        #expect(preview.crop.rect.minY == 54)
        #expect(preview.mark(for: preview.crop) == preview.mark)
    }

    @Test("a page change during capture is refused")
    func pageChangeRefused() throws {
        let captured = try capturedWindow()
        let fake = FakeWindowCapture(captured: captured)
        let read = LiveRead()
        read.onSecond = livePage(text: "A different page.")
        let service = PagePreviewService(
            capture: fake, read: { read.next() })
        #expect(throws: PagePreviewError.self) {
            try service.preview()
        }
    }
}

@Suite("Capture readiness")
struct CaptureReadinessTests {
    private func input(
        minimized: Bool = false, main: Bool = true,
        pageCountKnown: Bool = true, pageMatches: Bool = true
    ) -> CaptureReadinessInput {
        CaptureReadinessInput(
            hasAccessibility: true, hasScreenRecording: true,
            isRunning: true, isReading: true, isMinimized: minimized,
            isMainWindow: main, bookMatches: true, windowMatches: true,
            pageMatches: pageMatches, outputWritable: true,
            captureBusy: false, pageCountKnown: pageCountKnown)
    }

    @Test("a prepared reader is ready")
    func ready() {
        let readiness = CaptureReadinessChecker.check(input())
        #expect(readiness.isReady)
        #expect(readiness.blockingMessage == nil)
    }

    @Test("a minimized reader is refused with the restore wording")
    func minimized() {
        let readiness = CaptureReadinessChecker.check(
            input(minimized: true, main: false))
        #expect(!readiness.isReady)
        #expect(
            readiness.blockingMessage
                == "Restore Kindle or keep it behind another window. A "
                + "minimized window cannot turn pages.")
    }

    @Test("an unknown page count is a warning, not a block")
    func unknownPageCount() {
        let readiness = CaptureReadinessChecker.check(
            input(pageCountKnown: false))
        #expect(readiness.isReady)
        #expect(readiness.warnings.count == 1)
    }

    @Test("a page changed since preview blocks Start")
    func pageChanged() {
        let readiness = CaptureReadinessChecker.check(
            input(pageMatches: false))
        #expect(!readiness.isReady)
        #expect(readiness.blockingIssue == .pageChanged)
    }
}

@Suite("Manual Kindle session")
struct ManualKindleSessionTests {
    private final class Pages: @unchecked Sendable {
        var values: [LivePage]
        var index = 0

        init(_ values: [LivePage]) { self.values = values }

        func next() -> LivePage {
            values[min(index, values.count - 1)]
        }

        func advance() {
            index = min(index + 1, values.count - 1)
        }
    }

    private final class Clock: @unchecked Sendable {
        var seconds: TimeInterval = 0
    }

    private func session(
        pages: Pages, clock: Clock, image: CGImage,
        captured: CapturedWindow, turns: @escaping @Sendable () -> Void = {}
    ) -> ManualKindleCaptureSession {
        ManualKindleCaptureSession(
            crop: CaptureCrop(
                rect: CGRect(x: 52, y: 54, width: 296, height: 492)),
            cancellation: ClosureCancellation { false },
            expectedWindow: CGRect(
                x: 100, y: 50, width: 400, height: 600),
            read: { pages.next() },
            capture: { _, _ in captured },
            turnForward: turns,
            prepare: {},
            sleep: { clock.seconds += $0 },
            now: { Date(timeIntervalSince1970: clock.seconds) })
    }

    @Test("the first snapshot keeps the AX text and identity")
    func firstSnapshot() throws {
        let image = try manualImage(width: 400, height: 600)
        let window = CapturedWindow(
            image: image,
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 9)
        let pages = Pages([livePage(text: "First page.")])
        let clock = Clock()
        let subject = session(
            pages: pages, clock: clock, image: image, captured: window)
        let snapshot = try subject.snapshot()
        #expect(snapshot.text == "First page.")
        #expect(snapshot.textSource == .accessibility)
        #expect(snapshot.identity.confidence == .exact("B000000001"))
        #expect(snapshot.cropRect == CGRect(
            x: 152, y: 104, width: 296, height: 492))
    }

    @Test("an image-only page keeps the image and reports no text")
    func imageOnlyPage() throws {
        let image = try manualImage(width: 400, height: 600)
        let window = CapturedWindow(
            image: image,
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 9)
        let pages = Pages([livePage(text: "", endOfBook: false)])
        let clock = Clock()
        let subject = session(
            pages: pages, clock: clock, image: image, captured: window)
        let snapshot = try subject.snapshot()
        #expect(snapshot.image.width == 296)
        #expect(snapshot.text == nil || snapshot.text == "")
        #expect(snapshot.textSource != .accessibility)
    }

    @Test("a window resize mid-run is named, not reported as a stalled page")
    func resizeIsNamed() throws {
        let image = try manualImage(width: 400, height: 600)
        let window = CapturedWindow(
            image: image,
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 9)
        let pages = Pages([
            livePage(text: "First page.", page: 4),
            livePage(
                text: "Second page.",
                frame: CGRect(x: 100, y: 50, width: 500, height: 700),
                textRect: CGRect(x: 152, y: 104, width: 396, height: 592),
                page: 5),
        ])
        let clock = Clock()
        let subject = session(
            pages: pages, clock: clock, image: image, captured: window,
            turns: { pages.advance() })
        let first = try subject.snapshot()
        do {
            _ = try subject.advance(after: first.mark)
            Issue.record("expected a resize failure")
        } catch {
            #expect("\(error)".contains("changed size"))
        }
    }

    @Test("prime exposes identity before the first snapshot")
    func primeIdentity() throws {
        let image = try manualImage(width: 400, height: 600)
        let window = CapturedWindow(
            image: image,
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 9)
        let pages = Pages([livePage()])
        let clock = Clock()
        let subject = session(
            pages: pages, clock: clock, image: image, captured: window)
        try subject.prime()
        #expect(subject.identity.confidence == .exact("B000000001"))
    }

    @Test("a forward turn returns the next page and records it")
    func forwardTurn() throws {
        let image = try manualImage(width: 400, height: 600)
        let window = CapturedWindow(
            image: image,
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 9)
        let pages = Pages([
            livePage(text: "First page.", page: 4),
            livePage(text: "Second page.", page: 5),
        ])
        let clock = Clock()
        let subject = session(
            pages: pages, clock: clock, image: image, captured: window,
            turns: { pages.advance() })
        let first = try subject.snapshot()
        let transition = try subject.advance(after: first.mark)
        guard case .turned(let next, let record) = transition else {
            Issue.record("expected a turned page")
            return
        }
        #expect(next.text == "Second page.")
        #expect(next.pageNumber == 5)
        #expect(record.observed)
        let restore = subject.restore()
        #expect(restore.attempted == 0)
        #expect(restore.reason?.contains("does not restore") == true)
    }

    @Test("the end of the book is a terminal transition")
    func endOfBook() throws {
        let image = try manualImage(width: 400, height: 600)
        let window = CapturedWindow(
            image: image,
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 9)
        let pages = Pages([
            livePage(text: "Last page.", page: 4),
            livePage(
                text: "The End.", page: 5, endOfBook: true,
                state: "endOfBookSheet"),
        ])
        let clock = Clock()
        let subject = session(
            pages: pages, clock: clock, image: image, captured: window,
            turns: { pages.advance() })
        let first = try subject.snapshot()
        let transition = try subject.advance(after: first.mark)
        guard case .endOfBook(let record) = transition else {
            Issue.record("expected end of book")
            return
        }
        #expect(record.terminal)
    }

    @Test("cancellation is observed before a snapshot")
    func cancellation() throws {
        let image = try manualImage(width: 400, height: 600)
        let window = CapturedWindow(
            image: image,
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 9)
        let pages = Pages([livePage()])
        let clock = Clock()
        let subject = ManualKindleCaptureSession(
            crop: CaptureCrop(
                rect: CGRect(x: 52, y: 54, width: 296, height: 492)),
            cancellation: ClosureCancellation { true },
            expectedWindow: CGRect(
                x: 100, y: 50, width: 400, height: 600),
            read: { pages.next() },
            capture: { _, _ in window },
            turnForward: {},
            prepare: {},
            sleep: { clock.seconds += $0 },
            now: { Date(timeIntervalSince1970: clock.seconds) })
        #expect(throws: ReaderCaptureError.self) {
            try subject.snapshot()
        }
    }

    @Test("a stalled page is reported, not skipped")
    func stalledTurn() throws {
        let image = try manualImage(width: 400, height: 600)
        let window = CapturedWindow(
            image: image,
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 9)
        let pages = Pages([livePage()])
        let clock = Clock()
        let subject = session(
            pages: pages, clock: clock, image: image, captured: window,
            turns: { pages.advance() })
        let first = try subject.snapshot()
        let transition = try subject.advance(after: first.mark)
        guard case .noTurn(_, let reason) = transition else {
            Issue.record("expected no turn")
            return
        }
        #expect(reason.contains("did not change"))
        #expect(subject.restore().attempted == 0)
    }
}

private final class LiveRead: @unchecked Sendable {
    var page = livePage()
    var calls = 0
    var onSecond: LivePage?

    func next() -> LivePage {
        calls += 1
        if calls == 2, let onSecond { return onSecond }
        return page
    }
}

@Suite("Quick page capture")
struct QuickPageCaptureTests {
    @Test("the quick capture is the cropped page, not an Exports capture")
    func quickCapture() throws {
        let image = try manualImage(width: 400, height: 600)
        let window = CapturedWindow(
            image: image,
            windowFrame: CGRect(x: 100, y: 50, width: 400, height: 600),
            contentRect: CGRect(x: 100, y: 50, width: 400, height: 600),
            pointPixelScale: 1, isOnScreen: true, windowID: 9)
        let fake = FakeWindowCapture(captured: window)
        let read = LiveRead()
        let preview = PagePreviewService(
            capture: fake, read: { read.next() })
        let capture = try QuickPageCaptureService(preview: preview).capture()
        #expect(capture.image.width == 296)
        #expect(capture.image.height == 492)
        #expect(capture.text == "The page text.")
    }
}
