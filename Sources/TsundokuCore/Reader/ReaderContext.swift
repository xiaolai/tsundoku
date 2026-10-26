import AppKit
import Foundation

// MARK: - Reader identity

public enum ReaderKind: String, Codable, CaseIterable, Sendable {
    case kindle
    case appleBooks

    public var displayName: String {
        switch self {
        case .kindle: "Kindle"
        case .appleBooks: "Apple Books"
        }
    }

    /// The value stored in the capture manifest and the archive's
    /// `captures.source` column.
    public var captureSource: String {
        switch self {
        case .kindle: "kindle"
        case .appleBooks: "applebooks"
        }
    }

    public var bundleID: String {
        switch self {
        case .kindle: "com.amazon.Lassen"
        case .appleBooks: "com.apple.iBooksX"
        }
    }

    public static func from(bundleID: String) -> ReaderKind? {
        allCases.first { $0.bundleID == bundleID }
    }
}

// MARK: - Page

public enum ReaderTextSource: String, Codable, Equatable, Sendable {
    case accessibility
    case ocr
    case none

    /// OCR is a fallback, and the panel must say so rather than present
    /// recognised text as if the reader exposed it.
    public var disclosure: String? {
        switch self {
        case .accessibility: nil
        case .ocr: "Read with OCR — check the text before relying on it."
        case .none: nil
        }
    }
}

public struct ReaderPage: Equatable, Sendable {
    public let text: String
    public let title: String
    public let kind: ReaderKind
    public let source: ReaderTextSource
    public let pageNumber: Int?
    public let pageCount: Int?
    public let identifier: String?
    /// The reader's selection on this page, when it exposes one. Apple Books
    /// does; Kindle does not.
    public let selection: String?

    public init(
        text: String,
        title: String,
        kind: ReaderKind,
        source: ReaderTextSource,
        pageNumber: Int? = nil,
        pageCount: Int? = nil,
        identifier: String? = nil,
        selection: String? = nil
    ) {
        self.text = text
        self.title = title
        self.kind = kind
        self.source = source
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.identifier = identifier
        self.selection = selection
    }
}

// MARK: - Errors

public enum ReaderContextError: Error, CustomStringConvertible, Sendable {
    case notTrusted
    case readerNotRunning(ReaderKind)
    case noReaderWindow(ReaderKind)
    case noPageText(ReaderKind)
    case unavailable(ReaderKind, reason: String)
    case cancelled

    public var description: String {
        switch self {
        case .notTrusted:
            "Accessibility permission is not granted to Tsundoku."
        case .readerNotRunning(let kind):
            "\(kind.displayName) is not running."
        case .noReaderWindow(let kind):
            "\(kind.displayName) has no open reader window."
        case .noPageText(let kind):
            "\(kind.displayName) exposes no page text."
        case .unavailable(let kind, let reason):
            "\(kind.displayName): \(reason)"
        case .cancelled:
            "Cancelled."
        }
    }
}

// MARK: - Context

/// One reader, one page. Implementations return a typed error with a reason;
/// there is no silent fallback from Apple Books to the Kindle store.
public protocol ReaderContext: Sendable {
    var kind: ReaderKind { get }
    func page() throws -> ReaderPage
    /// The reader's current selection, when the reader exposes one through
    /// Accessibility. Kindle's selection popover does not expose the words;
    /// Apple Books sets `AXSelectedText` on each selected text node.
    func selectedText() -> String?
    /// A typed read when the reader can distinguish no selection from a
    /// failed one and report a clipboard problem. Defaults to untyped.
    func selectionReading() -> KindleLive.SelectionCopy?
}

public extension ReaderContext {
    func selectedText() -> String? { nil }
    func selectionReading() -> KindleLive.SelectionCopy? { nil }
}

/// Joins a selection that spans several Accessibility nodes.
///
/// Books sets `AXSelectedText` per selected static text, so one drag can
/// produce several parts. They are joined in tree order with a newline; empty
/// or whitespace-only nodes contribute nothing, and no selection is nil rather
/// than an empty string.
public enum SelectionText {
    public static func joined(_ parts: [String]) -> String? {
        let kept = parts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }

    /// Whether copied text plausibly came from this page.
    ///
    /// Kindle's Copy action reports only "the clipboard changed", which any
    /// other app can cause. Page text is the provenance check available
    /// without a private API. The selection must carry at least two
    /// identifying characters and match on word boundaries; punctuation is
    /// significant, and a short term such as "AI" is still a real selection.
    public static func belongs(_ selection: String, toPage page: String) -> Bool {
        let selection = normalized(selection)
        let page = normalized(page)
        guard !page.isEmpty else { return false }
        if containsSignificantSymbol(selection) {
            // C++, C#, $, % and operators carry meaning; require the literal
            // phrase at a boundary, and at least two characters in total.
            guard selection.count >= 2 else { return false }
            return containsAtASCIIBoundary(selection, in: page)
        }
        guard identifyingLength(selection) >= 2 else { return false }
        if containsCJK(selection) {
            return containsAtBoundary(selection, in: page)
        }
        let selectionWords = words(selection)
        let pageWords = words(page)
        guard !selectionWords.isEmpty else { return false }
        guard selectionWords.count > 1 else {
            return pageWords.contains(selectionWords[0])
        }
        guard pageWords.count >= selectionWords.count else { return false }
        for start in 0...(pageWords.count - selectionWords.count)
        where Array(pageWords[start..<(start + selectionWords.count)])
            == selectionWords
        {
            return true
        }
        return false
    }

    private static func normalized(_ value: String) -> String {
        var collapsed = value.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        // Layout can insert a space between CJK characters that belong to
        // one word; remove it on both sides of the comparison.
        var result = ""
        let characters = Array(collapsed)
        for (index, character) in characters.enumerated() {
            if character == " ",
                index > 0, index + 1 < characters.count,
                containsCJK(String(characters[index - 1])),
                containsCJK(String(characters[index + 1]))
            {
                continue
            }
            result.append(character)
        }
        collapsed = result
        return collapsed
    }

    private static func identifyingLength(_ value: String) -> Int {
        value.filter { $0.isLetter || $0.isNumber }.count
    }

    private static func containsSignificantSymbol(_ value: String) -> Bool {
        let ordinary: Set<Character> = [
            " ", ".", ",", "!", "?", ";", ":", "'", "\"", "“", "”", "‘",
            "’", "—", "–", "…", "(", ")", "[", "]", "\n",
        ]
        return value.contains { character in
            !character.isLetter && !character.isNumber
                && !ordinary.contains(character)
        }
    }

    private static func words(_ value: String) -> [String] {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// CJK has no spaces, so substring matching is the only option. It must
    /// still not match a fragment that runs into a non-CJK letter: "中文
    /// test" is not a phrase inside "中文 testing".
    private static func containsAtBoundary(
        _ selection: String, in page: String
    ) -> Bool {
        var start = page.startIndex
        while let range = page.range(
            of: selection, range: start..<page.endIndex)
        {
            let beforeOK =
                range.lowerBound == page.startIndex
                || allowsBoundary(page[page.index(before: range.lowerBound)])
            let afterOK =
                range.upperBound == page.endIndex
                || allowsBoundary(page[range.upperBound])
            if beforeOK, afterOK { return true }
            start = page.index(after: range.lowerBound)
        }
        return false
    }

    /// ASCII words and symbols need a real boundary on both sides; this
    /// rejects "$100" inside a page that only contains "100%".
    private static func containsAtASCIIBoundary(
        _ selection: String, in page: String
    ) -> Bool {
        var start = page.startIndex
        while let range = page.range(
            of: selection, range: start..<page.endIndex)
        {
            let beforeOK =
                range.lowerBound == page.startIndex
                || !isWordCharacter(page[page.index(before: range.lowerBound)])
            let afterOK =
                range.upperBound == page.endIndex
                || !isWordCharacter(page[range.upperBound])
            if beforeOK, afterOK { return true }
            start = page.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// CJK compounds may abut a CJK match; every other letter or digit
    /// means the match is inside a longer word.
    private static func allowsBoundary(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber else { return true }
        return containsCJK(String(character))
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
                || (0x30000...0x323AF).contains(scalar.value)
                || (0x323B0...0x33479).contains(scalar.value)
        }
    }
}

public enum ReaderContextLocator {
    public static func context(for kind: ReaderKind) -> any ReaderContext {
        switch kind {
        case .kindle: KindleContext()
        case .appleBooks: BooksContext()
        }
    }

    public static func isRunning(_ kind: ReaderKind) -> Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: kind.bundleID
        ).first != nil
    }

    public static func runningKinds() -> [ReaderKind] {
        ReaderKind.allCases.filter(isRunning)
    }

    /// The reader the user is most likely asking about: the frontmost one,
    /// otherwise Kindle, otherwise Books.
    public static func preferredKind() -> ReaderKind? {
        if let bundleID = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier,
            let kind = ReaderKind.from(bundleID: bundleID)
        {
            return kind
        }
        return runningKinds().first
    }
}
