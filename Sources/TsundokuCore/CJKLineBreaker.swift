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
            if range.length > 1, word.allSatisfy(isHan) {
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

    public static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}
