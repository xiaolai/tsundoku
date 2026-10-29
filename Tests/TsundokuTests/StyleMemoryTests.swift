import SwiftUI
import Testing

@testable import TsundokuCore
@testable import TsundokuUI

/// Opening the panel builds a new model, and the reader's type arrives from a
/// sample afterwards. What is remembered from the last open is what the first
/// frame draws, so the panel does not start at the fallback size and jump.
@MainActor
@Suite("Panel style memory")
struct StyleMemoryTests {
    private func style(_ size: CGFloat) -> CompanionTextStyle {
        CompanionTextStyle(family: "Georgia", size: size, lineSpacing: 4)
    }

    private func theme(_ value: Double) -> CompanionTheme {
        CompanionTheme(
            background: Color(white: value), isDark: value < 0.5)
    }

    @Test("what a reader had last is what a new model is seeded with")
    func seedsWhatWasRemembered() {
        var memory = StyleMemory()
        memory.remember(style(17), theme: theme(0.1), for: .kindle)
        let seeded = memory.seed(for: .kindle)
        #expect(seeded.style?.size == 17)
        #expect(seeded.theme?.isDark == true)
    }

    @Test("one reader's type is not another's")
    func readersAreSeparate() {
        var memory = StyleMemory()
        memory.remember(style(17), theme: nil, for: .kindle)
        #expect(memory.seed(for: .appleBooks).style == nil)
        memory.remember(style(21), theme: nil, for: .appleBooks)
        #expect(memory.style(for: .kindle)?.size == 17)
        #expect(memory.style(for: .appleBooks)?.size == 21)
    }

    @Test("a failed sample does not erase what worked last time")
    func failedSampleKeepsTheLastGood() {
        var memory = StyleMemory()
        memory.remember(style(17), theme: theme(0.9), for: .kindle)
        // A sample that could not read the reader reports nothing.
        memory.remember(nil, theme: nil, for: .kindle)
        #expect(memory.style(for: .kindle)?.size == 17)
        #expect(memory.theme(for: .kindle)?.isDark == false)
    }
}
