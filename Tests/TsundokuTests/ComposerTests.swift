import Testing

@testable import TsundokuUI

@Suite("Multiline composer")
struct ComposerTests {
    @Test("Return inserts a newline; Cmd+Return sends")
    func returnKeys() {
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 36, command: false, hasMarkedText: false)
                == .newline)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 36, command: true, hasMarkedText: false)
                == .send)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 76, command: false, hasMarkedText: false)
                == .newline)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 76, command: true, hasMarkedText: false)
                == .send)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 53, command: false, hasMarkedText: false)
                == .escape)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 0, command: false, hasMarkedText: false) == .none)
    }

    @Test("an input-method composition keeps its keys")
    func markedText() {
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 36, command: false, hasMarkedText: true) == .none)
        #expect(
            ComposerKeyPolicy.action(
                keyCode: 53, command: false, hasMarkedText: true) == .none)
    }
}
