import Foundation

/// Keeps Chinese words from being broken between characters.
///
/// Chinese has no spaces: the system line breaker may split any two
/// characters, so 「不要 cram」 becomes 「不」/「要 cram」 in a narrow column.
/// A word joiner (U+2060) between the characters of a word forbids that break
/// without changing what the reader sees — it is zero-width and invisible.
/// The text keeps its word boundaries because a tokenizer, not a guess,
/// decides them.
public enum CJKLineBreaker {
    private static let joiner = "\u{2060}"

    public static func protectWords(_ text: String) -> String {
        guard text.contains(where: { isHan($0) }) else { return text }
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(
            nil, text as CFString, CFRange(location: 0, length: string.length),
            kCFStringTokenizerUnitWord, Locale(identifier: "zh") as CFLocale)
        var result = ""
        var location = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location != kCFNotFound, range.length > 0 else {
                continue
            }
            if range.location > location {
                let gap = string.substring(
                    with: NSRange(
                        location: location, length: range.location - location))
                result += gap
            }
            let word = string.substring(with: NSRange(
                location: range.location, length: range.length))
            // A word that merely contains Han characters is protected:
            // `T恤衫` is one word, and forbidding a break inside it is
            // correct for the Latin letters too.
            if range.length > 1, word.contains(where: { isHan($0) }) {
                result += word.map(String.init).joined(separator: joiner)
            } else {
                result += word
            }
            location = range.location + range.length
        }
        if location < string.length {
            result += string.substring(
                with: NSRange(
                    location: location, length: string.length - location))
        }
        return result
    }

    /// Whether a character is written as a Han ideograph.
    ///
    /// The Unicode property, not a range table: the hand-written ranges this
    /// replaces stopped at U+2FA1F and missed Extensions G and H, and a table
    /// in this file would fall out of date again at the next Unicode version.
    public static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isIdeographic }
    }
}

/// Splits text into the spans that want the same font.
///
/// A markdown run is a formatting boundary, not a script boundary: `中文 and
/// English` arrives as one run, and giving it one face leaves one script
/// drawn in the other's fallback. The split is by character, and a word
/// joiner stays in the span it was inserted into so a protected Chinese word
/// is never cut in two here.
public enum ScriptSpans {
    public struct Span: Equatable, Sendable {
        public let text: String
        public let isChinese: Bool
    }

    public static func split(_ text: String) -> [Span] {
        var spans: [Span] = []
        var current = ""
        var currentIsChinese: Bool?
        for character in text {
            let isChinese: Bool
            if character == "\u{2060}" {
                // Zero-width, invisible, and part of the word around it.
                isChinese = currentIsChinese ?? false
            } else {
                isChinese = usesChineseFace(character)
            }
            if currentIsChinese == nil || isChinese == currentIsChinese {
                current.append(character)
                currentIsChinese = isChinese
            } else {
                spans.append(
                    Span(text: current, isChinese: currentIsChinese ?? false))
                current = String(character)
                currentIsChinese = isChinese
            }
        }
        if !current.isEmpty {
            spans.append(Span(text: current, isChinese: currentIsChinese ?? false))
        }
        return spans
    }

    /// Characters that should be drawn in a Chinese face: ideographs, CJK
    /// punctuation and full-width forms. Word protection is a narrower
    /// question — see `CJKLineBreaker.isHan`.
    public static func usesChineseFace(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F,
                0x30000...0x323AF:
                return true
            default:
                return false
            }
        }
    }
}
