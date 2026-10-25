import Foundation

/// What a capture's text match proves, without trusting the capture's
/// metadata. A capture can be mislabelled — the measured archive holds a
/// *Weapons of Math Destruction* capture whose pages are *The Math of Neural
/// Networks* — so only the fingerprint and an exact-confidence title are used.
public struct CaptureEvidence: Sendable, Equatable {
    public let fingerprint: String
    public let title: String
    public let confidence: String?

    public init(fingerprint: String, title: String, confidence: String?) {
        self.fingerprint = fingerprint
        self.title = title
        self.confidence = confidence
    }

    /// The capture's own title is usable only when its manifest says the
    /// identity was matched exactly; anything weaker could name another book.
    public var isExact: Bool {
        confidence?.caseInsensitiveCompare("exact") == .orderedSame
    }
}

/// Everything the live reader and the local index can say about the page,
/// before the identity is chosen.
public struct ReadingLiveFacts: Sendable, Equatable {
    public let kind: ReaderKind
    /// The title the reader exposes. Kindle hides it with the chrome; the
    /// value may be the placeholder "Kindle".
    public let title: String
    /// A reader-supplied book identifier: Kindle's last-opened ASIN or a
    /// Books asset ID.
    public let identifier: String?
    /// The capture whose text matches the live page, when one does.
    public let capture: CaptureEvidence?
    /// The archive asset ID whose unpacked EPUB contains the live page. Only
    /// a non-DRM EPUB that matched the page text supplies one.
    public let epubAssetID: String?

    public init(
        kind: ReaderKind,
        title: String,
        identifier: String? = nil,
        capture: CaptureEvidence? = nil,
        epubAssetID: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.identifier = identifier
        self.capture = capture
        self.epubAssetID = epubAssetID
    }
}

/// The book a live page belongs to, the key its conversation is filed under,
/// and how strongly the identity is established.
public struct ReadingIdentity: Sendable, Equatable {
    /// The documented order, highest confidence first. A lower raw value is
    /// stronger, so a change from a higher rank to a lower one is an
    /// improvement worth migrating a conversation for.
    public enum Rank: Int, Sendable, Comparable, CaseIterable {
        /// An archive book matched by a reader-supplied ASIN/asset ID, or by
        /// the EPUB that contains the page.
        case archiveMatch = 1
        /// Kindle's last-opened ASIN, before the library has imported it.
        case lastOpened = 2
        /// A capture whose text matches the live page.
        case captureText = 3
        /// A Books title with no asset ID yet.
        case titleMatch = 4
        /// Nothing trustworthy: the conversation stays in this session.
        case sessionOnly = 5

        public static func < (lhs: Rank, rhs: Rank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var provenance: String {
            switch self {
            case .archiveMatch: "archive book"
            case .lastOpened: "Kindle last-opened ASIN"
            case .captureText: "capture text fingerprint"
            case .titleMatch: "Books title"
            case .sessionOnly: "unidentified"
            }
        }
    }

    /// The archive key, or nil when the page is unidentified. A nil key means
    /// no archive write and no cross-session history.
    public let key: String?
    public let title: String
    public let book: Book?
    public let rank: Rank
    /// Why this identity was chosen, for diagnostics and the info menu.
    public let provenance: String

    public init(
        key: String?, title: String, book: Book?, rank: Rank, provenance: String
    ) {
        self.key = key
        self.title = title
        self.book = book
        self.rank = rank
        self.provenance = provenance
    }

    public var isSessionOnly: Bool { key == nil }

    /// The header's title: never a placeholder, never invented.
    public var headerTitle: String {
        title.isEmpty ? "Current Page" : title
    }
}

/// Chooses one deterministic identity for a live page.
///
/// The order is the plan's: archive match, Kindle last-opened ASIN, capture
/// text, Books title, session-only. A placeholder is never a title or a key,
/// so there is no "Kindle" bucket for unrelated books to share.
public enum ReadingIdentityResolver {
    /// Titles that identify a reader, not a book.
    public static let placeholderTitles: Set<String> = [
        "kindle", "apple books", "unknown", "未知",
    ]

    public static func isPlaceholder(_ title: String) -> Bool {
        let normalized = ConversationKey.normalize(title)
        return normalized.isEmpty || placeholderTitles.contains(normalized)
    }

    public static func resolve(
        facts: ReadingLiveFacts, books: [Book]
    ) -> ReadingIdentity {
        let identifier = trimmed(facts.identifier)
        let epubID = trimmed(facts.epubAssetID)
        let liveTitle = isPlaceholder(facts.title) ? "" : facts.title
        let captureTitle =
            facts.capture?.isExact == true && !isPlaceholder(facts.capture?.title ?? "")
            ? (facts.capture?.title ?? "") : ""

        // Rank 1: an EPUB that contains the page beats any metadata; a
        // reader-supplied identifier the archive knows is next.
        for candidate in [epubID, identifier]
        where !candidate.isEmpty {
            if let book = books.first(where: {
                $0.asin.caseInsensitiveCompare(candidate) == .orderedSame
            }) {
                return ReadingIdentity(
                    key: book.asin,
                    title: book.title,
                    book: book,
                    rank: .archiveMatch,
                    provenance:
                        candidate == epubID
                        ? "archive book matched by EPUB text"
                        : "archive book matched by reader identifier")
            }
        }
        if !identifier.isEmpty {
            switch facts.kind {
            case .appleBooks:
                // An asset ID the archive has not imported yet is still the
                // book's real identity; the chat will match the row once the
                // library is imported.
                return ReadingIdentity(
                    key: identifier,
                    title: liveTitle.isEmpty ? captureTitle : liveTitle,
                    book: nil,
                    rank: .archiveMatch,
                    provenance: "reader asset ID; not in the archive")
            case .kindle:
                // Kindle's last-opened ASIN identifies the book even before
                // its library row exists. The title stays empty unless an
                // exact capture proves it.
                return ReadingIdentity(
                    key: identifier,
                    title: captureTitle,
                    book: nil,
                    rank: .lastOpened,
                    provenance: "Kindle last-opened ASIN; not in the archive")
            }
        }
        if !epubID.isEmpty, facts.kind == .appleBooks {
            return ReadingIdentity(
                key: epubID,
                title: liveTitle.isEmpty ? captureTitle : liveTitle,
                book: nil,
                rank: .archiveMatch,
                provenance: "EPUB asset ID; not in the archive")
        }

        // Rank 3: a capture whose text matches the live page. Its metadata is
        // still not trusted; only an exact-confidence title is used.
        if let capture = facts.capture, !capture.fingerprint.isEmpty {
            return ReadingIdentity(
                key: "text:\(capture.fingerprint)",
                title: capture.isExact ? captureTitle : "",
                book: nil,
                rank: .captureText,
                provenance: "capture text fingerprint")
        }

        // Rank 4: a real Books title. The archive supplies the display title
        // and, when one edition matches, the book row; the key stays
        // title-normalized until the EPUB text picks an asset ID.
        if facts.kind == .appleBooks, !liveTitle.isEmpty {
            let normalized = ConversationKey.normalize(liveTitle)
            let candidates = books.filter {
                $0.source == .appleBooks
                    && ConversationKey.normalize($0.title) == normalized
            }
            let provenance: String
            if candidates.isEmpty {
                provenance = "Books title; no archived edition"
            } else if candidates.count == 1 {
                provenance = "Books title; one archived edition"
            } else {
                provenance =
                    "Books title; \(candidates.count) archived editions "
                    + "await the EPUB text"
            }
            return ReadingIdentity(
                key: "books:\(normalized)",
                title: candidates.first?.title ?? liveTitle,
                book: candidates.count == 1 ? candidates[0] : nil,
                rank: .titleMatch,
                provenance: provenance)
        }

        // Rank 5: nothing trustworthy. No key, no archive write, no title.
        return ReadingIdentity(
            key: nil, title: "", book: nil, rank: .sessionOnly,
            provenance: "unidentified")
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
