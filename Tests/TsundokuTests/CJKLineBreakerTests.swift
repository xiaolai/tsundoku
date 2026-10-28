import Foundation
import Testing

@testable import TsundokuCore

@Suite("CJK line breaking")
struct CJKLineBreakerTests {
    @Test("a Chinese word cannot be split, Latin is untouched")
    func protectsChineseWords() {
        let protected = CJKLineBreaker.protectWords("不要 cram 这本书")
        #expect(!protected.contains("不 要"))
        #expect(protected.contains("\u{2060}"))
        #expect(protected.contains("cram"))
        // Invisible: the visible characters are unchanged.
        #expect(
            protected.replacingOccurrences(of: "\u{2060}", with: "")
                == "不要 cram 这本书")
    }

    @Test("text without Chinese is returned unchanged")
    func leavesLatinAlone() {
        #expect(
            CJKLineBreaker.protectWords("plain English words")
                == "plain English words")
    }
}
