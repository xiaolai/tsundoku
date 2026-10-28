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

    @Test("a word that mixes scripts is protected too")
    func protectsMixedScriptWords() {
        // `T恤衫` tokenises as one word; rejecting it because of the Latin T
        // left the break between 恤 and 衫 open.
        let protected = CJKLineBreaker.protectWords("一件T恤衫")
        let visible = protected.replacingOccurrences(
            of: "\u{2060}", with: "")
        #expect(visible == "一件T恤衫")
        #expect(protected.contains("T\u{2060}恤\u{2060}衫"))
    }

    @Test("Han characters outside the basic planes count as Han")
    func recognisesSupplementaryHan() {
        // CJK Extensions G and H sit above U+2FA1F, where the old hand-written
        // ranges stopped.
        #expect(CJKLineBreaker.isHan("\u{30000}"))
        #expect(CJKLineBreaker.isHan("\u{31350}"))
        #expect(CJKLineBreaker.isHan("\u{4E00}"))
        #expect(CJKLineBreaker.isHan("\u{3007}"))
        #expect(!CJKLineBreaker.isHan("T"))
        #expect(!CJKLineBreaker.isHan("7"))
    }
}
