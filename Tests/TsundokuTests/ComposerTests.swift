import Testing

@testable import TsundokuUI

@Suite("Multiline composer")
struct ComposerTests {
    @Test("Return sends and Shift+Return inserts a newline")
    func returnKeys() {
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 36, shift: false, hasMarkedText: false) == .send)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 36, shift: true, hasMarkedText: false) == .newline)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 76, shift: false, hasMarkedText: false) == .send)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 76, shift: true, hasMarkedText: false) == .newline)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 53, shift: false, hasMarkedText: false) == .escape)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 0, shift: false, hasMarkedText: false) == .none)
    }

    @Test("an input-method composition keeps its keys")
    func markedText() {
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 36, shift: false, hasMarkedText: true) == .none)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 53, shift: false, hasMarkedText: true) == .none)
    }
}
