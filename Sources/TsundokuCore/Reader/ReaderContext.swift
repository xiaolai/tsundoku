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
}

public extension ReaderContext {
    func selectedText() -> String? { nil }
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
