import CoreGraphics
import Foundation
import KindleAX
import Testing

@testable import TsundokuCore

// MARK: - Helpers

private let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)

private func snapshot(
    _ rect: CGRect, kind: ReaderKind = .kindle, pid: pid_t = 42,
    focused: Bool = true, minimized: Bool = false, fullScreen: Bool = false,
    windowNumber: UInt32? = nil, title: String = "Book"
) -> ReaderSnapshot {
    ReaderSnapshot(
        kind: kind, pid: pid, title: title, frame: rect,
        focused: focused, minimized: minimized, fullScreen: fullScreen,
        windowNumber: windowNumber)
}

private func layout(
    _ reader: CGRect,
    visible: CGRect = visible,
    panel: CompanionSettings.PanelPlacement = .auto,
    trigger: CompanionSettings.TriggerPlacement = .auto
) -> CompanionLayout {
    CompanionGeometry.layout(
        reader: reader, visible: visible, panelPlacement: panel,
        triggerPlacement: trigger)
}

// MARK: - Geometry

@Suite("Companion geometry")
struct CompanionGeometryTests {
    @Test("only a placement that crosses the reader floats above it")
    func onlyOverlaysFloat() {
        // The window layer follows this: a drawer outside the reader stays in
        // the normal layer, covered together with the reader; an overlay or a
        // corner trigger crosses the reader's window and must float.
        #expect(!CompanionLayout.Mode.side.isOverlay)
        #expect(!CompanionLayout.Mode.bottom.isOverlay)
        #expect(CompanionLayout.Mode.sideOverlay.isOverlay)
        #expect(CompanionLayout.Mode.corner.isOverlay)
    }

    @Test("a portrait reader gets a side drawer exactly its height")
    func portraitSide() {
        let result = layout(CGRect(x: 100, y: 40, width: 700, height: 1000))
        #expect(result.mode == .side)
        #expect(result.panelFrame == CGRect(
            x: 808, y: 40, width: 400, height: 1000))
        #expect(result.triggerFrame == CGRect(
            x: 808, y: 512, width: 56, height: 56))
    }

    // A bottom drawer now takes the tallest of its preferred heights that
    // fits the screen, so these expectations are the largest drawer the
    // geometry allows rather than a fixed 300 pt.
    @Test("a landscape reader with room below gets a bottom drawer")
    func landscapeBottom() {
        let result = layout(CGRect(x: 100, y: 400, width: 1400, height: 700))
        #expect(result.mode == .bottom)
        #expect(result.panelFrame == CGRect(
            x: 100, y: 32, width: 1400, height: 360))
    }

    @Test("no horizontal room falls back to the bottom drawer")
    func noHorizontalRoom() {
        let result = layout(CGRect(x: 60, y: 500, width: 1800, height: 1000))
        #expect(result.mode == .bottom)
        #expect(result.panelFrame == CGRect(
            x: 60, y: 72, width: 1800, height: 420))
    }

    @Test("no room outside becomes a side overlay inside the reader edge")
    func sideOverlay() {
        let result = layout(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(result.mode == .sideOverlay)
        #expect(result.panelFrame == CGRect(
            x: 1520, y: 0, width: 400, height: 1080))
    }

    @Test("a reader too small for any drawer gets the corner overlay")
    func cornerOverlay() {
        let tiny = CGRect(x: 0, y: 0, width: 240, height: 160)
        let result = layout(tiny, visible: tiny)
        #expect(result.mode == .corner)
        #expect(result.panelFrame == tiny)
    }

    @Test("a manual bottom choice overrides the portrait preference")
    func manualBottom() {
        let result = layout(
            CGRect(x: 100, y: 400, width: 700, height: 600),
            panel: .bottom)
        #expect(result.mode == .bottom)
        #expect(result.panelFrame.width == 700)
    }

    @Test("a manual side choice overrides the landscape preference")
    func manualSide() {
        let result = layout(
            CGRect(x: 100, y: 200, width: 700, height: 500),
            panel: .side)
        #expect(result.mode == .side)
        #expect(result.panelFrame.height == 500)
    }

    @Test("a reader taller than the screen clamps the side height")
    func sideClampsToScreen() {
        let small = CGRect(x: 0, y: 0, width: 1920, height: 800)
        let result = layout(
            CGRect(x: 100, y: 0, width: 700, height: 1000),
            visible: small)
        #expect(result.mode == .side)
        #expect(result.panelFrame.height == 800)
        #expect(result.panelFrame.maxY <= small.maxY)
    }

    @Test("the trigger moves inside when the right edge has no room")
    func triggerInsideFallback() {
        let result = layout(CGRect(x: 1100, y: 40, width: 760, height: 1000))
        #expect(result.triggerFrame.maxX <= visible.maxX)
        #expect(result.triggerFrame.minX < 1860)
    }

    @Test("a forced inside trigger sits within the reader edge")
    func triggerInside() {
        let reader = CGRect(x: 100, y: 40, width: 700, height: 1000)
        let result = layout(reader, trigger: .inside)
        #expect(result.triggerFrame == CGRect(
            x: 732, y: 512, width: 56, height: 56))
    }

    @Test("a second display gets its own visible frame")
    func secondDisplay() {
        let second = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let result = layout(
            CGRect(x: 2500, y: 100, width: 700, height: 1000),
            visible: second)
        #expect(result.mode == .side)
        #expect(result.panelFrame.origin.x == 3208)
        #expect(result.panelFrame.minX >= second.minX)
        #expect(result.panelFrame.maxX <= second.maxX)
    }

    @Test("every automatic mode keeps the panel inside the visible frame")
    func allModesAreOnScreen() {
        let readers = [
            CGRect(x: 0, y: 0, width: 700, height: 1000),
            CGRect(x: 100, y: 400, width: 1400, height: 700),
            CGRect(x: 60, y: 500, width: 1800, height: 1000),
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]
        for reader in readers {
            let result = layout(reader)
            #expect(visible.contains(result.panelFrame))
            #expect(visible.contains(result.triggerFrame))
        }
    }
}

// MARK: - State machine

@Suite("Companion state")
struct CompanionStateTests {
    @Test("a focused reader shows the trigger")
    func triggerWhenFocused() {
        var machine = CompanionStateMachine()
        let output = machine.update(
            reader: snapshot(CGRect(x: 100, y: 100, width: 700, height: 900)),
            visible: visible)
        #expect(output.presentation == .trigger)
    }

    @Test("opening moves from trigger to panel and closing restores it")
    func openAndClose() {
        var machine = CompanionStateMachine()
        _ = machine.update(
            reader: snapshot(CGRect(x: 100, y: 100, width: 700, height: 900)),
            visible: visible)
        #expect(machine.openPanel(visible: visible).presentation == .panel)
        #expect(machine.closePanel(visible: visible).presentation == .trigger)
    }

    @Test("an unfocused reader hides both surfaces")
    func unfocusedHides() {
        var machine = CompanionStateMachine()
        _ = machine.update(
            reader: snapshot(
                CGRect(x: 100, y: 100, width: 700, height: 900),
                focused: false),
            visible: visible)
        #expect(machine.output(visible: visible).presentation == .hidden)
    }

    @Test("minimizing hides the panel and restoring brings it back")
    func minimizeRestoresPanel() {
        var machine = CompanionStateMachine()
        let reader = CGRect(x: 100, y: 100, width: 700, height: 900)
        _ = machine.update(reader: snapshot(reader), visible: visible)
        _ = machine.openPanel(visible: visible)
        let minimized = machine.update(
            reader: snapshot(reader, minimized: true), visible: visible)
        #expect(minimized.presentation == .hidden)
        let restored = machine.update(
            reader: snapshot(reader), visible: visible)
        #expect(restored.presentation == .panel)
    }

    @Test("an app switch closes the panel, not just hides it")
    func appSwitchClosesPanel() {
        var machine = CompanionStateMachine()
        let reader = CGRect(x: 100, y: 100, width: 700, height: 900)
        _ = machine.update(reader: snapshot(reader), visible: visible)
        _ = machine.openPanel(visible: visible)
        _ = machine.update(
            reader: snapshot(reader, focused: false), visible: visible)
        let returned = machine.update(
            reader: snapshot(reader), visible: visible)
        #expect(returned.presentation == .trigger)
    }

    @Test("losing the reader hides everything and forgets the panel")
    func readerQuit() {
        var machine = CompanionStateMachine()
        let reader = CGRect(x: 100, y: 100, width: 700, height: 900)
        _ = machine.update(reader: snapshot(reader), visible: visible)
        _ = machine.openPanel(visible: visible)
        #expect(machine.update(reader: nil, visible: visible).presentation
            == .hidden)
        #expect(
            machine.update(reader: snapshot(reader), visible: visible)
                .presentation == .trigger)
    }

    @Test("switching readers starts at the trigger")
    func readerSwitch() {
        var machine = CompanionStateMachine()
        let reader = CGRect(x: 100, y: 100, width: 700, height: 900)
        _ = machine.update(reader: snapshot(reader, pid: 1), visible: visible)
        _ = machine.openPanel(visible: visible)
        let switched = machine.update(
            reader: snapshot(reader, pid: 2), visible: visible)
        #expect(switched.presentation == .trigger)
    }

    @Test("switching windows in the same app also starts at the trigger")
    func windowSwitch() {
        var machine = CompanionStateMachine()
        let reader = CGRect(x: 100, y: 100, width: 700, height: 900)
        _ = machine.update(
            reader: snapshot(reader, pid: 1, windowNumber: 10),
            visible: visible)
        _ = machine.openPanel(visible: visible)
        let switched = machine.update(
            reader: snapshot(reader, pid: 1, windowNumber: 11),
            visible: visible)
        #expect(switched.presentation == .trigger)
    }

    @Test("a different book in the same window starts at the trigger")
    func titleSwitch() {
        var machine = CompanionStateMachine()
        let reader = CGRect(x: 100, y: 100, width: 700, height: 900)
        _ = machine.update(
            reader: snapshot(reader, pid: 1, title: "First"),
            visible: visible)
        _ = machine.openPanel(visible: visible)
        let switched = machine.update(
            reader: snapshot(reader, pid: 1, title: "Second"),
            visible: visible)
        #expect(switched.presentation == .trigger)
    }

    @Test("opening without an eligible reader changes nothing")
    func openWithoutReader() {
        var machine = CompanionStateMachine()
        let output = machine.openPanel(visible: visible)
        #expect(output.presentation == .hidden)
        #expect(!machine.panelOpen)
    }

    @Test("full screen changes the layout but not the presentation")
    func fullScreenKeepsPresentation() {
        var machine = CompanionStateMachine()
        let reader = CGRect(x: 100, y: 100, width: 700, height: 900)
        _ = machine.update(reader: snapshot(reader), visible: visible)
        let output = machine.update(
            reader: snapshot(reader, fullScreen: true), visible: visible)
        #expect(output.presentation == .trigger)
        #expect(output.layout != nil)
    }
}

// MARK: - Settings

@Suite("Companion settings")
struct CompanionSettingsTests {
    @Test("the default shortcut is option-command-K")
    func defaultShortcut() {
        let hotKey = CompanionHotKey.defaultShortcut
        #expect(hotKey.keyCode == 40)
        #expect(hotKey.modifiers == [.command, .option])
        #expect(hotKey.displayName == "⌥⌘K")
        #expect(hotKey.isValid)
    }

    @Test("a shortcut without a modifier is invalid")
    func plainKeyIsInvalid() {
        #expect(
            !CompanionHotKey(keyCode: 40, modifiers: []).isValid)
    }

    @Test("key code 0 is A and is valid with a modifier")
    func keyCodeAIsValid() {
        #expect(
            CompanionHotKey(keyCode: 0, modifiers: [.command]).isValid)
    }

    @Test("only known modifier bits count")
    func unknownModifierBits() {
        let unknown = CompanionHotKeyModifiers(rawValue: 1 << 12)
        #expect(!CompanionHotKey(keyCode: 40, modifiers: unknown).isValid)
    }

    @Test("a shift-only shortcut is invalid")
    func shiftOnly() {
        #expect(!CompanionHotKey(keyCode: 40, modifiers: [.shift]).isValid)
    }

    @Test("settings survive a save and load round trip")
    func roundTrip() throws {
        let suite = "tsundoku.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = CompanionSettings()
        settings.panelPlacement = .bottom
        settings.triggerPlacement = .inside
        settings.launchAtLogin = true
        settings.hotKey = CompanionHotKey(
            keyCode: 49, modifiers: [.control, .shift])
        settings.quickActions = [.summarize, .define]
        settings.save(to: defaults)
        let loaded = CompanionSettings.load(from: defaults)
        #expect(loaded == settings)
        #expect(loaded.hotKey.displayName == "⌃⇧Space")
        #expect(loaded.quickActions == [.summarize, .define])
    }

    @Test("missing data falls back to the documented defaults")
    func missingData() throws {
        let suite = "tsundoku.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CompanionSettings.load(from: defaults) == .defaults)
    }
}

// MARK: - Books text

@Suite("Books page text")
struct BooksPageTextTests {
    private func frame(
        _ x: Double, _ y: Double, _ width: Double, _ height: Double
    ) -> AXNode.Frame {
        AXNode.Frame(x: x, y: y, width: width, height: height)
    }

    private func text(
        _ value: String?, _ x: Double, _ y: Double
    ) -> AXNode {
        AXNode(
            role: "AXStaticText", value: value.map(AXScalar.text),
            frame: frame(x, y, 300, 20))
    }

    private func pageTree(webAreas: Int = 1) -> AXNode {
        var pageChildren: [AXNode] = [
            text("Line one", 30, 60),
            text("Chapter", 30, 90),
            text("", 30, 120),
        ]
        pageChildren[1].role = "AXHeading"
        var children: [AXNode] = [
            AXNode(
                role: "AXWebArea", frame: frame(20, 50, 560, 700),
                children: pageChildren),
            text("Toolbar", 0, 0),
        ]
        for index in 1..<webAreas {
            children.append(
                AXNode(
                    role: "AXWebArea",
                    frame: frame(20, 750 + Double(index), 560, 100),
                    children: [text("Second \(index)", 30, 760)]))
        }
        return AXNode(
            role: "AXWindow", title: "A Book",
            frame: frame(0, 0, 600, 900), children: children)
    }

    @Test("text inside the web area is kept in tree order")
    func extractsPageText() {
        let value = BooksPageText.text(from: pageTree())
        #expect(value == "Line one\nChapter")
    }

    @Test("chrome outside the web area is excluded")
    func excludesChrome() {
        #expect(!BooksPageText.text(from: pageTree()).contains("Toolbar"))
    }

    @Test("the window with the most web areas wins")
    func bestWindow() {
        let library = AXNode(
            role: "AXWindow", title: "Library",
            frame: frame(0, 0, 600, 900),
            children: [
                AXNode(
                    role: "AXWebArea", frame: frame(0, 0, 600, 900),
                    children: [])
            ])
        let reader = pageTree(webAreas: 2)
        #expect(BooksPageText.bestWindow([library, reader])?.title == "A Book")
    }

    @Test("a text container does not duplicate its children")
    func containerDoesNotDuplicate() {
        let heading = AXNode(
            role: "AXHeading", value: .text("Chapter"),
            frame: frame(30, 60, 300, 20),
            children: [
                AXNode(
                    role: "AXStaticText", value: .text("Chapter"),
                    frame: frame(30, 60, 300, 20))
            ])
        let root = AXNode(
            role: "AXWindow",
            children: [
                AXNode(role: "AXWebArea", children: [heading])
            ])
        #expect(BooksPageText.text(from: root) == "Chapter")
    }

    @Test("an empty text container still yields its readable children")
    func emptyContainerRecurses() {
        let heading = AXNode(
            role: "AXHeading",
            children: [
                AXNode(
                    role: "AXStaticText", value: .text("Child"),
                    frame: frame(30, 60, 300, 20))
            ])
        let root = AXNode(
            role: "AXWindow",
            children: [AXNode(role: "AXWebArea", children: [heading])])
        #expect(BooksPageText.text(from: root) == "Child")
    }

    @Test("text outside the visible web-area frame is excluded")
    func offscreenTextIsExcluded() {
        let root = AXNode(
            role: "AXWindow",
            children: [
                AXNode(
                    role: "AXWebArea", frame: frame(0, 0, 600, 800),
                    children: [
                        text("Visible", 30, 60),
                        text("Offscreen", 30, 2000),
                    ])
            ])
        #expect(BooksPageText.text(from: root) == "Visible")
    }

    @Test("the focused title wins over a larger window")
    func focusedTitleWins() {
        let reader = pageTree()
        let other = AXNode(
            role: "AXWindow", title: "Other Book",
            frame: frame(0, 0, 900, 900),
            children: [
                AXNode(
                    role: "AXWebArea", frame: frame(0, 0, 900, 900),
                    children: []),
                AXNode(
                    role: "AXWebArea", frame: frame(0, 0, 900, 900),
                    children: []),
            ])
        #expect(
            BooksPageText.bestWindow([other, reader], preferredTitle: "A Book")?
                .title == "A Book")
    }

    @Test("chrome outside the web area is not read even if it overlaps")
    func chromeIsScopedToTheWebArea() {
        var tree = pageTree()
        tree.children.append(
            AXNode(
                role: "AXStaticText", value: .text("Overlapping chrome"),
                frame: frame(30, 60, 300, 20)))
        #expect(!BooksPageText.text(from: tree).contains("Overlapping chrome"))
    }

    @Test("a titleless window is still found by its web areas")
    func bestWindowWithoutTitle() {
        let window = pageTree()
        #expect(BooksPageText.bestWindow([window])?.role == "AXWindow")
    }

    @Test("OCR text is always labelled as OCR")
    func ocrDisclosure() {
        #expect(ReaderTextSource.accessibility.disclosure == nil)
        #expect(ReaderTextSource.ocr.disclosure != nil)
    }
}

// MARK: - CLI cancellation
//
// The process runner and its cancellation live in sayso now; its
// AIProviderCLITests prove a cancelled ask kills the child and ends
// `.cancelled`. Tsundoku keeps the adapter side: a cancelled ask must leave
// the panel idle rather than show an error (see ProviderSettingsStateTests).

@Suite("AI composer")
struct AIComposerTests {
    @Test("an omitted request language resolves from settings")
    func requestLanguageFallsBack() {
        let request = AIRequest(
            action: .explain, pageText: "A page.", bookTitle: "A Book")
        let prompt = AIComposer.prompt(
            for: request, settings: AISettings(language: "French"))
        #expect(prompt.contains("French"))
    }
}
