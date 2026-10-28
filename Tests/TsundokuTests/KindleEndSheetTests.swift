import CoreGraphics
import Foundation
import KindleAX
import Testing

@testable import TsundokuCore

/// Kindle raises its end-of-book sheet before the last pages: it answers a
/// turn that crosses into them with a sheet covering the pages still to come.
/// These tests pin the recovery: dismiss the sheet, try one more turn, and
/// only believe the end when a further turn brings the sheet back.
@Suite("Kindle end sheet")
struct KindleEndSheetTests {
    private final class Clock: @unchecked Sendable {
        var value = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { value += seconds }
    }

    private final class FakeReader: @unchecked Sendable {
        let clock: Clock
        let pages = ["page one", "page two", "page three", "page four"]
        var index = 0
        /// One sheet layer tries to come back after the first Escape, as the
        /// reader measured: Escape clears the sheet, a second Escape clears
        /// the panel behind it.
        var sheet = false
        var panelsBehindTheSheet = 0
        /// The forward press that first reaches the last pages is answered
        /// with the sheet, which is what Kindle does.
        var sheetOnNextTurn = false
        var forwardCalls = 0
        var escapeCalls = 0
        let window = AXNode.Frame(x: 0, y: 0, width: 800, height: 1000)
        let text = AXNode.Frame(x: 100, y: 100, width: 600, height: 700)

        init(clock: Clock) { self.clock = clock }

        func page() -> LivePage {
            LivePage(
                state: sheet ? "endSheet" : "readingChromeHidden",
                text: sheet ? "" : pages[index],
                title: "A Book",
                characters: sheet ? 0 : pages[index].count,
                windowFrame: window, pageTextFrame: sheet ? nil : text,
                endOfBook: sheet,
                pageNumber: index + 1, pageCount: pages.count)
        }

        func forward() {
            forwardCalls += 1
            guard !sheet else { return }
            if sheetOnNextTurn {
                sheetOnNextTurn = false
                sheet = true
                panelsBehindTheSheet = 1
                return
            }
            if index == pages.count - 1 {
                // Past the last page Kindle reopens the sheet, every time.
                sheet = true
                panelsBehindTheSheet = 1
                return
            }
            index += 1
        }

        func escapeKey() {
            escapeCalls += 1
            guard sheet else { return }
            if panelsBehindTheSheet > 0 {
                panelsBehindTheSheet -= 1
                return
            }
            sheet = false
        }
    }

    private func image(step: Int) throws -> CGImage {
        let width = 120, height = 200
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(
            red: step % 2 == 0 ? 0.2 : 0.8, green: 0.3, blue: 0.4,
            alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A different mark per page: the settle check compares pixel detail.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: CGFloat(step * 5) + 2, y: 4, width: 4, height: 4))
        return try #require(context.makeImage())
    }

    private func session(_ reader: FakeReader) throws -> KindleCaptureSession {
        try KindleCaptureSession(
            subject: CaptureSubject(book: nil, kind: .kindle),
            cancellation: CancellationFlag(),
            readPage: { reader.page() },
            capture: { _ in try self.image(step: reader.index) },
            turnForward: { reader.forward() },
            turnBackward: {},
            escape: { reader.escapeKey() },
            sleep: { reader.clock.advance($0) },
            now: { reader.clock.value },
            isTrusted: { true },
            isRunning: { true },
            activate: {})
    }

    private func turned(
        _ transition: PageTransition, _ label: String = ""
    ) throws -> PageSnapshot {
        guard case .turned(let page, let record) = transition else {
            Issue.record(Comment(rawValue: "\(label) gave \(transition)"))
            throw CancellationError()
        }
        #expect(!record.terminal)
        return page
    }

    @Test("the sheet before the last pages is dismissed and capture continues")
    func sheetBeforeTheEndIsDismissed() throws {
        let clock = Clock()
        let reader = FakeReader(clock: clock)
        let session = try self.session(reader)
        // page one → page two → page three, one turn at a time.
        var page = try session.snapshot()
        #expect(page.text == "page one")
        page = try turned(try session.advance(after: page.mark), "to page two")
        #expect(page.text == "page two")
        page = try turned(
            try session.advance(after: page.mark), "to page three")
        #expect(page.text == "page three")
        // The turn into page four is answered with the sheet.
        reader.sheetOnNextTurn = true
        let next = try turned(
            try session.advance(after: page.mark), "out of the sheet")
        #expect(next.text == "page four")
        // Two Escapes clear the sheet and the panel behind it.
        #expect(reader.escapeCalls >= 2)
    }

    @Test("a sheet that survives a dismissal and a turn is the end")
    func sheetAfterTheLastPageIsTheEnd() throws {
        let clock = Clock()
        let reader = FakeReader(clock: clock)
        let session = try self.session(reader)
        for _ in 0..<3 {
            let page = try session.snapshot()
            _ = try session.advance(after: page.mark)
        }
        let last = try session.snapshot()
        #expect(last.text == "page four")
        let transition = try session.advance(after: last.mark)
        guard case .endOfBook(let record) = transition else {
            Issue.record("the true end was read as \(transition)")
            return
        }
        #expect(record.terminal)
        // One dismissal and one test turn, not a loop: three advances to reach
        // the last page, the turn that opened the sheet, and the test turn.
        #expect(reader.escapeCalls >= 2)
        // Bounded: the dismissal is not retried in a loop.
        #expect(reader.forwardCalls <= 6)
    }

    @Test("a capture that starts on the sheet reads the page behind it")
    func startsOnTheSheet() throws {
        let clock = Clock()
        let reader = FakeReader(clock: clock)
        reader.sheet = true
        reader.panelsBehindTheSheet = 1
        let session = try self.session(reader)
        let page = try session.snapshot()
        #expect(page.text == "page one")
        #expect(reader.escapeCalls >= 2)
    }

    @Test("the reader's own location proves an early sheet")
    func locationProvesAnEarlySheet() throws {
        let clock = Clock()
        let reader = FakeReader(clock: clock)
        // Page three of four, with the sheet shown before page four.
        let session = try self.session(reader)
        var page = try session.snapshot()
        page = try turned(try session.advance(after: page.mark), "p2")
        page = try turned(try session.advance(after: page.mark), "p3")
        reader.sheetOnNextTurn = true
        let next = try turned(
            try session.advance(after: page.mark), "p4")
        #expect(next.text == "page four")
    }
}
