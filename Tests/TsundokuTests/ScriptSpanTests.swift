import Foundation
import Testing

@testable import TsundokuCore

/// The answer renderer chooses a face per script, not per markdown run. A run
/// is a formatting boundary — `中文 and English` is one plain run — so a mixed
/// run is split before a font is applied, and the joiners the line breaker
/// inserted must not split the word they protect.
@Suite("Script spans")
struct ScriptSpanTests {
    @Test("a mixed run splits at the script boundary")
    func splitsMixedRun() {
        let spans = ScriptSpans.split("中文 and English")
        #expect(spans.map(\.text) == ["中文", " and English"])
        #expect(spans.map(\.isChinese) == [true, false])
    }

    @Test("a word joiner stays inside the Chinese span it protects")
    func keepsJoiners() {
        let spans = ScriptSpans.split("不\u{2060}要 cram")
        #expect(spans.map(\.text) == ["不\u{2060}要", " cram"])
        #expect(spans.map(\.isChinese) == [true, false])
    }

    @Test("punctuation that belongs to Chinese takes the Chinese face")
    func punctuation() {
        let spans = ScriptSpans.split("「中文」，ok")
        #expect(spans.first?.isChinese == true)
        #expect(spans.last?.text == "ok")
        #expect(spans.last?.isChinese == false)
    }

    @Test("Latin text is one span")
    func latinOnly() {
        let spans = ScriptSpans.split("plain English")
        #expect(spans.count == 1)
        #expect(spans.first?.isChinese == false)
    }

    @Test("an empty string has no spans")
    func empty() {
        #expect(ScriptSpans.split("").isEmpty)
    }
}
