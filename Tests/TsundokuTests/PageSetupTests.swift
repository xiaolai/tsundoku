import CoreGraphics
import Foundation
import Testing

@testable import TsundokuCore

private final class SetupState: @unchecked Sendable {
    var window: CGRect
    var font: Int
    var windowWrites: [CGRect] = []
    var fontWrites: [Int] = []
    var reflows = 0
    var accepted: (CGRect) -> CGRect = { $0 }

    init(window: CGRect, font: Int) {
        self.window = window
        self.font = font
    }
}

@Suite("Page setup")
struct PageSetupTests {
    private let a4 = CGSize(width: 595.28, height: 841.89)
    private let insets = CaptureInsets.measured

    private func journal() -> PageSetupJournal {
        PageSetupJournal(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "tsundoku-page-setup-\(UUID().uuidString).json"))
    }

    private func setup(
        _ state: SetupState, request: PageSetupRequest,
        journal: PageSetupJournal
    ) -> KindlePageSetup {
        KindlePageSetup(
            request: request, journal: journal,
            readWindow: { state.window },
            writeWindow: { frame in
                state.windowWrites.append(frame)
                state.window = state.accepted(frame)
                return state.window
            },
            readFont: { state.font },
            writeFont: { value in
                let before = state.font
                state.fontWrites.append(value)
                state.font = value
                return before
            },
            reflow: { state.reflows += 1 },
            readPageText: { "the opening page text" },
            restoreAnchor: { _ in true },
            displays: { [CGRect(x: 0, y: 0, width: 1920, height: 1080)] })
    }

    @Test("the A4 window is the page plus the measured insets")
    func windowSize() {
        let size = PageSetupGeometry.windowSize(for: a4, insets: insets)
        #expect(abs(size.width - 699.28) < 0.01)
        #expect(abs(size.height - 949.89) < 0.01)
    }

    @Test("the window is clamped onto the display that holds it")
    func frameClamping() throws {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let resolved = try #require(
            PageSetupGeometry.frame(
                for: a4, insets: insets,
                current: CGRect(x: 1600, y: 900, width: 765, height: 871),
                displays: [display]))
        #expect(resolved.maxX <= display.maxX)
        #expect(resolved.maxY <= display.maxY)
        #expect(resolved.minY >= PageSetupGeometry.menuBarHeight)
    }

    @Test("a display too small for the page refuses")
    func screenTooSmall() {
        let small = CGRect(x: 0, y: 0, width: 700, height: 950)
        #expect(
            PageSetupGeometry.frame(
                for: a4, insets: insets,
                current: CGRect(x: 0, y: 0, width: 699, height: 949),
                displays: [small]) == nil)
    }

    @Test("the journal round-trips the window and font")
    func journalRoundTrip() throws {
        let journal = journal()
        defer { journal.clear() }
        let window = CGRect(x: 10, y: 20, width: 700, height: 900)
        try journal.save(window: window, font: 7)
        let loaded = try #require(journal.load())
        #expect(loaded.window == window)
        #expect(loaded.font == 7)
        journal.clear()
        #expect(journal.load() == nil)
    }

    @Test("A4 and a font are applied and then restored")
    func applyAndRestore() throws {
        let state = SetupState(
            window: CGRect(x: 350, y: 50, width: 765, height: 871), font: 7)
        let journal = journal()
        defer { journal.clear() }
        let setup = setup(
            state, request: PageSetupRequest(pageSize: .a4, font: 5),
            journal: journal)
        let begin = try setup.begin()
        #expect(begin.pageSize == .a4)
        #expect(abs(state.window.width - 699.28) < 0.01)
        #expect(abs(state.window.height - 949.89) < 0.01)
        #expect(begin.finalFont == 5)
        #expect(state.font == 5)
        #expect(state.reflows == 1)
        #expect(journal.load() != nil)

        let restore = setup.restore()
        #expect(restore.restored)
        #expect(state.font == 7)
        #expect(state.window == CGRect(x: 350, y: 50, width: 765, height: 871))
        #expect(journal.load() == nil)
    }

    @Test("an unchanged font is not written")
    func fontAlreadyMatches() throws {
        let state = SetupState(
            window: CGRect(x: 0, y: 0, width: 765, height: 871), font: 7)
        let journal = journal()
        defer { journal.clear() }
        let setup = setup(
            state, request: PageSetupRequest(font: 7), journal: journal)
        _ = try setup.begin()
        #expect(state.fontWrites.isEmpty)
        #expect(state.reflows == 0)
    }

    @Test("a refused window restores the original frame and keeps no journal")
    func refusedWindow() throws {
        let original = CGRect(x: 350, y: 50, width: 765, height: 871)
        let state = SetupState(window: original, font: 7)
        // Kindle accepts a different size than requested, once; the restore
        // write is accepted so the frame can return.
        state.accepted = { frame in
            state.windowWrites.count == 1
                ? CGRect(x: 350, y: 50, width: 700, height: 900)
                : frame
        }
        let journal = journal()
        defer { journal.clear() }
        let setup = setup(
            state, request: PageSetupRequest(pageSize: .a4), journal: journal)
        #expect(throws: PageSetupError.self) {
            _ = try setup.begin()
        }
        #expect(journal.load() == nil)
    }
}
