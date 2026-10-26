import Foundation

/// One captured page's text, with the reader's page number.
public struct IndexedPage: Sendable, Equatable, Hashable {
    public let page: Int
    public let text: String

    public init(page: Int, text: String) {
        self.page = page
        self.text = text
    }
}

/// Where a chapter starts in a captured book.
public struct ChapterMark: Sendable, Equatable, Hashable {
    public let page: Int
    /// "Ch. 3" for a Kindle capture, "Chapter Three. The Pool of Tears." for
    /// a Books capture. Only what the page text actually carries.
    public let title: String

    public init(page: Int, title: String) {
        self.page = page
        self.title = title
    }
}

/// A captured book's text, indexed for the companion.
///
/// The capture's own `text.jsonl` is the source: its pages are the reader's
/// pages, so a live page can be matched back to its page number, and a
/// chapter start is a page whose text begins with a chapter heading.
public struct BookTextIndex: Sendable {
    public struct Match: Sendable, Equatable {
        public let page: Int
        public let chapter: String?

        public init(page: Int, chapter: String?) {
            self.page = page
            self.chapter = chapter
        }
    }

    public let pages: [IndexedPage]
    public let chapters: [ChapterMark]
    /// Normalized page text and shingles, computed once. A page lookup used
    /// to normalize every captured page again on every call, which made a
    /// cached index cost the same as an uncached one.
    private let normalizedPages: [String]
    private let pageShingles: [Set<String>]
    /// Stable across captures of the same book that start at the same page.
    ///
    /// It hashes every page's normalized text plus the page count. A sample
    /// would let two books that share front matter and a sampled middle page
    /// collide into one conversation key; the whole capture is only a few
    /// hundred kilobytes.
    public let fingerprint: String

    public init(pages: [IndexedPage]) {
        let sorted = pages.sorted { $0.page < $1.page }
        let normalized = sorted.map { Self.normalize($0.text) }
        self.pages = sorted
        self.chapters = Self.chapterMarks(in: sorted)
        self.normalizedPages = normalized
        self.pageShingles = normalized.map {
            Self.shingles(Self.words($0))
        }
        let body = normalized.joined(separator: "\u{1E}")
        self.fingerprint = TextIndexHash.hex(
            TextIndexHash.fnv(body + "\u{1F}" + String(sorted.count)))
    }

    public static func load(directory: URL) throws -> BookTextIndex {
        let pages = try TextSidecars.load(from: directory).map {
            IndexedPage(page: $0.page, text: $0.text)
        }
        return BookTextIndex(pages: pages)
    }

    public func chapter(for page: Int) -> String? {
        chapters.last(where: { $0.page <= page })?.title
    }

    /// The captured pages of the chapter containing `page`, joined in order.
    /// Nil when the page or a chapter start is unknown.
    public func chapterText(for page: Int?) -> String? {
        guard let page,
            let index = chapters.lastIndex(where: { $0.page <= page })
        else { return nil }
        let start = chapters[index].page
        let end = index + 1 < chapters.count
            ? chapters[index + 1].page : Int.max
        let text = pages
            .filter { $0.page >= start && $0.page < end }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    public var fullText: String {
        pages.map(\.text).filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Finds the captured page whose text is this live page.
    ///
    /// An exact normalised match is the common case: both texts come from the
    /// same Accessibility page. When OCR or a different page extractor was
    /// used, an 8-word shingle overlap decides instead, and only above half
    /// the live page's shingles.
    public func match(pageText: String) -> Match? {
        let live = Self.normalize(pageText)
        guard live.count >= 20 else { return nil }
        for (index, page) in pages.enumerated()
        where normalizedPages[index] == live
        {
            return Match(page: page.page, chapter: chapter(for: page.page))
        }
        let liveShingles = Self.shingles(Self.words(live))
        guard liveShingles.count >= 3 else { return nil }
        var best: (page: IndexedPage, score: Double)?
        for (index, page) in pages.enumerated() {
            let shingles = pageShingles[index]
            guard !shingles.isEmpty else { continue }
            let score =
                Double(liveShingles.intersection(shingles).count)
                / Double(liveShingles.count)
            if score > (best?.score ?? 0) { best = (page, score) }
        }
        guard let best, best.score >= 0.5 else { return nil }
        return Match(
            page: best.page.page, chapter: chapter(for: best.page.page))
    }

    // MARK: Chapter headings

    private static func chapterMarks(in pages: [IndexedPage]) -> [ChapterMark] {
        var marks: [ChapterMark] = []
        for page in pages {
            guard let title = chapterLabel(in: page.text) else { continue }
            if marks.last?.title == title { continue }
            marks.append(ChapterMark(page: page.page, title: title))
        }
        return marks
    }

    /// A chapter heading is the page's first line. Kindle's capture flattens
    /// the heading into the body, so only its "Ch. N" prefix is reliable;
    /// Books keeps line breaks, so the full heading line is used.
    static func chapterLabel(in text: String) -> String? {
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespaces) }
        guard
            let firstIndex = lines.firstIndex(where: { !$0.isEmpty })
        else { return nil }
        let first = lines[firstIndex]
        if let prefix = first.firstMatch(
            #"^Ch(?:apter)?\.?\s*\d+"#, options: [.caseInsensitive])
        {
            let lower = prefix.lowercased()
            if lower.hasPrefix("ch.") || lower.hasPrefix("ch ") {
                // Kindle's flattened heading is only "Ch. 1"; the rest of
                // the line is body text.
                return collapse(prefix)
            }
            // A Books heading may carry its title after the number:
            // "Chapter 12. The Journey" must not collapse to "Chapter 12".
            // A heading broken after a hyphen keeps its second line too.
            return String(
                collapse(
                    continuedHeading(first, lines: lines, at: firstIndex)
                ).prefix(120))
        }
        guard
            first.firstMatch(
                #"^Chapter\s+\S+"#, options: [.caseInsensitive]) != nil
        else { return nil }
        return String(
            collapse(
                continuedHeading(first, lines: lines, at: firstIndex)
            ).prefix(120))
    }

    /// Rejoin a heading broken across two captured lines, identically for a
    /// numeric and a spelled-out chapter number. A hyphen keeps its second
    /// line directly; otherwise a short following line is appended with a
    /// space. A heading that already ends a sentence owns no continuation.
    private static func continuedHeading(
        _ heading: String, lines: [String], at index: Int
    ) -> String {
        guard !heading.hasSuffix("."), index + 1 < lines.count else {
            return heading
        }
        let second = lines[index + 1]
        guard !second.isEmpty, second.count < 80 else { return heading }
        if heading.hasSuffix("-") {
            // The capture cannot say whether the hyphen was soft.
            return heading + second
        }
        return heading + " " + second
    }

    // MARK: Text normalisation

    static func normalize(_ text: String) -> String {
        collapse(
            text.lowercased().folding(
                options: [.diacriticInsensitive], locale: .current))
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(_ normalized: String) -> [String] {
        normalized.split(separator: " ").flatMap { token -> [String] in
            // CJK text has no spaces; without this a whole page is one
            // "word" and can never produce the three shingles matching needs.
            let hasCJK = token.unicodeScalars.contains {
                (0x4E00...0x9FFF).contains($0.value)
                    || (0x3040...0x30FF).contains($0.value)
            }
            return hasCJK ? token.map(String.init) : [String(token)]
        }
    }

    static func shingles(_ words: [String], size: Int = 8) -> Set<String> {
        guard words.count >= size else {
            return words.isEmpty ? [] : [words.joined(separator: " ")]
        }
        var values = Set<String>()
        values.reserveCapacity(words.count - size + 1)
        for index in 0...(words.count - size) {
            values.insert(words[index..<(index + size)].joined(separator: " "))
        }
        return values
    }
}

enum TextIndexHash {
    static func fnv(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return value
    }

    static func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }
}

private extension String {
    /// The first match of a regular expression, as a string.
    func firstMatch(
        _ pattern: String, options: String.CompareOptions
    ) -> String? {
        guard
            let range = range(of: pattern, options: [options, .regularExpression])
        else { return nil }
        return String(self[range])
    }
}

// MARK: - EPUB

public enum ReadingIndexError: Error, CustomStringConvertible, Sendable {
    case protected(String)
    case noNavigation(URL)

    public var description: String {
        switch self {
        case .protected(let reason):
            "The book is protected: \(reason)"
        case .noNavigation(let url):
            "The EPUB has no readable table of contents at \(url.path)."
        }
    }
}

/// A non-DRM EPUB's chapters, parsed from its navigation document and spine.
///
/// The navigation gives the chapter titles and files; each spine document's
/// text is the source for matching a live page. Nothing is written to the
/// book's directory.
public struct EPUBBookIndex: Sendable {
    public struct Chapter: Sendable, Equatable {
        public let title: String
        public let text: String

        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    public let chapters: [Chapter]
    public let directory: URL
    private let chapterShingles: [Set<String>]

    /// The chapter a navigation entry named, falling back to the first
    /// normalized title match. Nil when the requested chapter is unknown.
    public func chapterText(named title: String?) -> String? {
        guard let title else { return nil }
        let wanted = ConversationKey.normalize(title)
        return chapters.first {
            ConversationKey.normalize($0.title) == wanted
        }?.text
    }

    public var fullText: String {
        chapters.map(\.text).filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public init(epubDirectory: URL) throws {
        self.directory = epubDirectory
        guard case .clear = EPUBEncryption.status(unpackedEPUB: epubDirectory)
        else {
            throw ReadingIndexError.protected(
                "the EPUB encryption declaration is not clear")
        }
        let package = try EPUBPackage.load(fromEPUBDirectory: epubDirectory)
        let base = package.opfURL.deletingLastPathComponent()
        let entries = Self.navigationEntries(package: package, base: base)
        guard !entries.isEmpty else {
            throw ReadingIndexError.noNavigation(epubDirectory)
        }
        var chapters: [Chapter] = []
        var seen = Set<String>()
        var htmlByPath: [String: String] = [:]
        var chapterForPath: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            // Two chapters can live in one XHTML file as fragments. Their
            // identities differ, and each chapter slices its own range; the
            // old path-only dedupe silently dropped every chapter but the
            // first.
            guard !seen.contains(entry.identity) else { continue }
            seen.insert(entry.identity)
            let html: String
            if let cached = htmlByPath[entry.url.path] {
                html = cached
            } else {
                guard let text = Self.readText(entry.url) else { continue }
                html = text
                htmlByPath[entry.url.path] = text
            }
            // Every later fragment can end this chapter; the earliest marker
            // actually after it wins, so TOC order one→two→one→three still
            // ends chapter two at three rather than at the body's end.
            let nextFragments = entries.dropFirst(index + 1).compactMap {
                candidate -> String? in
                guard candidate.url.path == entry.url.path,
                    let fragment = candidate.fragment,
                    !fragment.isEmpty,
                    fragment != entry.fragment
                else { return nil }
                return fragment
            }
            let firstFragment = entries.first {
                $0.url.path == entry.url.path && !($0.fragment ?? "").isEmpty
            }?.fragment
            let text: String
            if let fragment = entry.fragment, !fragment.isEmpty,
                let sliced = Self.fragmentText(
                    in: html, fragment: fragment, next: nextFragments)
            {
                text = sliced
            } else if entry.fragment == nil,
                let firstFragment,
                let range = Self.markerRange(
                    in: html, fragment: firstFragment)
            {
                // A fragmentless nav entry owns only the preamble before the
                // first fragment; indexing the whole file would let later
                // chapters match under this title.
                let end = Self.startOfTag(html, at: range.lowerBound)
                text = Self.plainText(String(html[..<end]))
            } else {
                text = Self.plainText(html)
            }
            if !text.isEmpty {
                chapters.append(Chapter(title: entry.title, text: text))
                chapterForPath[entry.url.path] = chapters.count - 1
            }
        }
        // Spine files the navigation does not link are continuation text for
        // the chapter that precedes them in the spine, not new chapters with
        // invented titles.
        let indexedPaths = Set(entries.map(\.url.path))
        // Leading spine files with no chapter before them have no title to
        // continue; start before the first chapter.
        var currentChapter = -1
        for idref in package.spine {
            guard
                let item = package.items.first(where: { $0.id == idref }),
                let url = try? EPUBPackage.resolve(
                    item.href, relativeTo: base, root: package.rootURL),
                let html = Self.readText(url)
            else { continue }
            if let index = chapterForPath[url.path] {
                currentChapter = index
                continue
            }
            guard !indexedPaths.contains(url.path) else { continue }
            let text = Self.plainText(html)
            guard !text.isEmpty, currentChapter >= 0 else { continue }
            let previous = chapters[currentChapter]
            chapters[currentChapter] = Chapter(
                title: previous.title,
                text: previous.text + "\n" + text)
        }
        self.chapters = chapters
        self.chapterShingles = chapters.map {
            BookTextIndex.shingles(BookTextIndex.words(
                BookTextIndex.normalize($0.text)))
        }
    }

    public func chapter(containing pageText: String) -> String? {
        guard let best = bestChapter(pageText), best.score >= 0.4 else {
            return nil
        }
        return best.title
    }

    /// The chapter match and its score. Two editions of one book can both
    /// contain the page; the score is what lets the stronger edition win.
    func bestChapter(_ pageText: String) -> (title: String, score: Double)? {
        let live = BookTextIndex.shingles(
            BookTextIndex.words(BookTextIndex.normalize(pageText)))
        guard live.count >= 3 else { return nil }
        var best: (title: String, score: Double)?
        for (index, chapter) in chapters.enumerated() {
            let shingles = chapterShingles[index]
            guard !shingles.isEmpty else { continue }
            let score =
                Double(live.intersection(shingles).count) / Double(live.count)
            if score > (best?.score ?? 0) { best = (chapter.title, score) }
        }
        return best
    }

    // MARK: Navigation

    struct NavigationEntry {
        let url: URL
        /// The href as written, including its fragment. Two chapters in one
        /// file are two entries, not one.
        let identity: String
        let fragment: String?
        let title: String
    }

    static func navigationEntries(
        package: EPUBPackage, base: URL
    ) -> [NavigationEntry] {
        if let nav = package.items.first(where: {
            ($0.properties ?? "").lowercased()
                .split(separator: " ").contains("nav")
        }) {
            let url = try? EPUBPackage.resolve(
                nav.href, relativeTo: base, root: package.rootURL)
            if let url, let text = readText(url) {
                let entries = resolve(
                    anchors(in: text), relativeTo: url, package: package)
                if !entries.isEmpty { return entries }
            }
        }
        if let ncx = package.items.first(where: {
            ($0.mediaType ?? "").lowercased()
                == "application/x-dtbncx+xml"
        }) {
            let url = try? EPUBPackage.resolve(
                ncx.href, relativeTo: base, root: package.rootURL)
            if let url, let text = readText(url) {
                let entries = resolve(
                    ncxEntries(in: text), relativeTo: url, package: package)
                if !entries.isEmpty { return entries }
            }
        }
        return []
    }

    private static func resolve(
        _ entries: [(href: String, title: String)], relativeTo document: URL,
        package: EPUBPackage
    ) -> [NavigationEntry] {
        let base = document.deletingLastPathComponent()
        return entries.compactMap { entry in
            let href = decodeEntities(entry.href)
            let parts = href.split(
                separator: "#", maxSplits: 1,
                omittingEmptySubsequences: false)
            let path = String(parts.first ?? "")
            let rawFragment = parts.count > 1 ? String(parts[1]) : nil
            let fragment =
                rawFragment?.removingPercentEncoding ?? rawFragment
            let url: URL
            if path.isEmpty {
                // A bare fragment points inside the navigation document.
                url = document
            } else if let resolved = try? EPUBPackage.resolve(
                path, relativeTo: base, root: package.rootURL)
            {
                url = resolved
            } else {
                return nil
            }
            return NavigationEntry(
                url: url, identity: href,
                fragment: fragment, title: entry.title)
        }
    }

    /// The text belonging to one fragment in an XHTML file: from the element
    /// carrying the fragment's `id`/`name` to the next fragment, or the body's
    /// end. A missing marker returns nil, and the caller falls back to the
    /// whole file.
    static func fragmentText(
        in html: String, fragment: String, next: [String]
    ) -> String? {
        guard
            let start = markerRange(in: html, fragment: fragment)
        else { return nil }
        let startIndex = startOfTag(html, at: start.lowerBound)
        var endIndex = html.endIndex
        var nextStart: String.Index?
        for candidate in next {
            guard
                let range = markerRange(in: html, fragment: candidate),
                range.lowerBound > start.lowerBound
            else { continue }
            // A marker that appears earlier in the file cannot end this
            // chapter; ending there would invert the range and fall back to
            // the whole file, letting later chapters match this title.
            let tagStart = startOfTag(html, at: range.lowerBound)
            if nextStart == nil || tagStart < nextStart! {
                nextStart = tagStart
            }
        }
        if let nextStart {
            endIndex = nextStart
        } else if let bodyEnd = html.range(
            of: "</body>", options: [.caseInsensitive])
        {
            endIndex = bodyEnd.lowerBound
        }
        guard startIndex < endIndex else { return nil }
        return plainText(String(html[startIndex..<endIndex]))
    }

    private static func markerRange(
        in html: String, fragment: String
    ) -> Range<String.Index>? {
        let escaped = NSRegularExpression.escapedPattern(for: fragment)
        // Not `data-id`, and XML identifiers are case-sensitive.
        let pattern =
            #"(?<![-\w])(?:id|name)\s*=\s*["']"# + escaped + #"["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern)
        else { return nil }
        return regex.firstMatch(
            in: html, range: NSRange(html.startIndex..., in: html)
        ).flatMap { Range($0.range, in: html) }
    }

    /// The opening `<` of the tag containing `index`.
    private static func startOfTag(
        _ html: String, at index: String.Index
    ) -> String.Index {
        var current = index
        while current > html.startIndex {
            let previous = html.index(before: current)
            if html[previous] == "<" { return previous }
            current = previous
        }
        return index
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func anchors(in html: String) -> [(href: String, title: String)] {
        // The navigation document can also carry landmarks and a page list.
        // Their links are not chapters; reading only the toc nav keeps a
        // "Start reading" link from replacing the first chapter title.
        let scoped = tocSection(in: html) ?? html
        let pattern =
            #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        return regex.matches(
            in: scoped, range: NSRange(scoped.startIndex..., in: scoped)
        ).compactMap { match in
            guard
                let hrefRange = Range(match.range(at: 1), in: scoped),
                let titleRange = Range(match.range(at: 2), in: scoped)
            else { return nil }
            let title = plainText(String(scoped[titleRange]))
            guard !title.isEmpty else { return nil }
            return (href: String(scoped[hrefRange]), title: title)
        }
    }

    /// The inner HTML of the table-of-contents `<nav>`, when the document
    /// marks one.
    static func tocSection(in html: String) -> String? {
        let patterns = [
            #"<nav\b[^>]*epub:type\s*=\s*["'][^"']*\btoc\b[^"']*["'][^>]*>([\s\S]*?)</nav>"#,
            #"<nav\b[^>]*type\s*=\s*["'][^"']*\btoc\b[^"']*["'][^>]*>([\s\S]*?)</nav>"#,
        ]
        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern, options: [.caseInsensitive]),
                let match = regex.firstMatch(
                    in: html,
                    range: NSRange(html.startIndex..., in: html)),
                let range = Range(match.range(at: 1), in: html)
            else { continue }
            return String(html[range])
        }
        return nil
    }

    static func ncxEntries(in xml: String) -> [(href: String, title: String)] {
        let pattern =
            #"<navPoint\b[\s\S]*?<text>([\s\S]*?)</text>[\s\S]*?<content\b[^>]*src\s*=\s*["']([^"']+)["']"#
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        return regex.matches(
            in: xml, range: NSRange(xml.startIndex..., in: xml)
        ).compactMap { match in
            guard
                let titleRange = Range(match.range(at: 1), in: xml),
                let hrefRange = Range(match.range(at: 2), in: xml)
            else { return nil }
            let title = plainText(String(xml[titleRange]))
            guard !title.isEmpty else { return nil }
            return (href: String(xml[hrefRange]), title: title)
        }
    }

    /// Strip markup and entities so chapter text can be matched against the
    /// page the reader exposes.
    static func plainText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "(?is)<(script|style)\\b[^>]*>[\\s\\S]*?</\\1>",
            with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?is)<(?:br|/p|/div|/h\\d|/li|/tr|/td|/th|/section)\\s*/?>",
            with: "\n", options: .regularExpression)
        // Inline tags close a word, not a block: removing them without a
        // separator keeps `inter<em>national</em>ization` one word, while the
        // block tags above still separate paragraphs.
        text = text.replacingOccurrences(
            of: "(?is)<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        return BookTextIndex.collapse(text)
    }

    /// Decodes every entity reference once, in a single pass.
    ///
    /// The old implementation replaced named entities in dictionary order and
    /// then numeric ones, so `&amp;lt;` could become either `<` or `&lt;`
    /// depending on iteration order.
    static func decodeEntities(_ text: String) -> String {
        let named = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…",
            "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”",
        ]
        let pattern = #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern)
        else { return text }
        var value = text
        let matches = regex.matches(
            in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard
                let range = Range(match.range, in: value),
                let bodyRange = Range(match.range(at: 1), in: text)
            else { continue }
            let body = String(text[bodyRange])
            let replacement: String?
            if body.lowercased().hasPrefix("#x") {
                replacement = UInt32(body.dropFirst(2), radix: 16)
                    .flatMap { UnicodeScalar($0).map(String.init) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst())
                    .flatMap { UnicodeScalar($0).map(String.init) }
            } else {
                replacement = named[body.lowercased()]
            }
            if let replacement {
                value.replaceSubrange(range, with: replacement)
            }
        }
        return value
    }
}

// MARK: - Resolution

public enum ReadingContextResolver {
    public struct Result: Sendable, Equatable {
        public let chapter: String?
        public let pageNumber: Int?
        public let fingerprint: String?
        public let capture: CaptureRecord?
        /// The archive asset ID whose EPUB contained the live page. Only a
        /// text-validated edition supplies one; it is the identity that
        /// replaces a title key.
        public let assetID: String?
        /// The unpacked EPUB whose text matched the page, when it was read
        /// from disk. Later chapter/book scopes read the same file.
        public let epubPath: URL?

        public init(
            chapter: String?, pageNumber: Int?, fingerprint: String?,
            capture: CaptureRecord?, assetID: String? = nil,
            epubPath: URL? = nil
        ) {
            self.chapter = chapter
            self.pageNumber = pageNumber
            self.fingerprint = fingerprint
            self.capture = capture
            self.assetID = assetID
            self.epubPath = epubPath
        }
    }

    /// Resolves the local context for a live page: the EPUB's chapter for an
    /// Apple Books book, otherwise a captured book's page and chapter.
    public static func resolve(
        pageText: String, kind: ReaderKind, title: String = "",
        identifier: String? = nil, captures: [CaptureRecord],
        archive: Archive? = nil, captureLimit: Int = 20
    ) -> Result? {
        if kind == .appleBooks {
            // Several editions can share a title. Try every matching archive
            // book's EPUB; the page text decides which edition it is.
            var candidates: [String] = []
            if let identifier, !identifier.isEmpty {
                candidates.append(identifier)
            } else if let archive, let books = try? archive.books() {
                candidates = books.filter {
                    $0.source == .appleBooks && $0.title == title
                }.map(\.asin)
            }
            if let match = edition(
                matching: pageText, identifiers: candidates,
                index: { identifier in
                    EPUBIndexCache.shared.epubPath(for: identifier)
                        .flatMap { EPUBIndexCache.shared.index(at: $0) }
                })
            {
                return Result(
                    chapter: match.chapter, pageNumber: nil, fingerprint: nil,
                    capture: nil, assetID: match.identifier,
                    epubPath: EPUBIndexCache.shared.epubPath(
                        for: match.identifier))
            }
            // The Books library's own container can be unreadable while its
            // unpacked EPUBs are still in the iCloud Books folder. Name
            // matching narrows the field; the page text decides.
            // Directory enumeration order must not decide between editions;
            // score every folder EPUB and keep the strongest match.
            var bestFolder: (
                chapter: String, score: Double, path: URL
            )?
            for index in epubIndexes(named: title) {
                guard let match = index.bestChapter(pageText),
                    match.score >= 0.4
                else { continue }
                if match.score > (bestFolder?.score ?? 0) {
                    bestFolder = (
                        match.title, match.score, index.directory)
                }
            }
            if let bestFolder {
                return Result(
                    chapter: bestFolder.chapter, pageNumber: nil,
                    fingerprint: nil, capture: nil,
                    epubPath: bestFolder.path)
            }
        }
        let source = kind == .kindle ? "kindle" : "applebooks"
        // The book the live page names comes first; otherwise a full-book
        // capture outranks a recent two-page sample.
        let candidates = captures.filter { $0.source == source }
            .sorted { left, right in
                let leftMatches = identifier.map {
                    left.asin.caseInsensitiveCompare($0) == .orderedSame
                } ?? false
                let rightMatches = identifier.map {
                    right.asin.caseInsensitiveCompare($0) == .orderedSame
                } ?? false
                if leftMatches != rightMatches { return leftMatches }
                return left.pageCount > right.pageCount
            }
            .prefix(captureLimit)
        for record in candidates {
            guard
                let index = CaptureIndexCache.shared.index(
                    directory: record.directory),
                let match = index.match(pageText: pageText)
            else { continue }
            return Result(
                chapter: match.chapter, pageNumber: match.page,
                fingerprint: index.fingerprint, capture: record)
        }
        return nil
    }

    /// Picks the edition whose EPUB best contains the live page.
    ///
    /// Several editions can share a title, and the same page often appears in
    /// more than one of them. The highest shingle score wins; a tie is broken
    /// by identifier, so the answer never depends on archive row order.
    public static func edition(
        matching pageText: String, identifiers: [String],
        index: (String) -> EPUBBookIndex?
    ) -> (identifier: String, chapter: String)? {
        var best: (identifier: String, chapter: String, score: Double)?
        for identifier in identifiers.sorted() {
            guard
                let book = index(identifier),
                let match = book.bestChapter(pageText),
                match.score >= 0.4
            else { continue }
            if match.score > (best?.score ?? 0) {
                best = (identifier, match.title, match.score)
            }
        }
        guard let best else { return nil }
        return (best.identifier, best.chapter)
    }
}

public extension ReadingContextResolver {
    /// The local text a context scope asks for. Chapter and book scopes read
    /// the same index the resolver already matched, so the text is the book
    /// the page belongs to, not a second guess.
    /// The capture's own manifest is the only authority on whether it ran
    /// from the start of the book to the end. A missing or unreadable manifest
    /// is not evidence of coverage.
    private static func captureCoversWholeBook(
        _ record: CaptureRecord
    ) -> Bool {
        let url = URL(fileURLWithPath: record.directory)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return false }
        // CaptureJobEngine writes `${complete: {wholeBook: …}}`; the flat key
        // is accepted for older manifests.
        let complete = object["complete"] as? [String: Any]
        return (complete?["wholeBook"] as? Bool)
            ?? (object["wholeBook"] as? Bool)
            ?? false
    }

    static func scopeText(
        _ scope: CompanionScope, result: Result, pageNumber: Int?
    ) -> String? {
        switch scope {
        case .currentPage, .selection:
            return nil
        case .currentChapter:
            if let record = result.capture,
                let index = CaptureIndexCache.shared.index(
                    directory: record.directory)
            {
                // Capture pages are numbered from the capture's first page,
                // not the live reader's page. The text match's coordinate is
                // the one that belongs to this index.
                return index.chapterText(
                    for: result.pageNumber ?? pageNumber)
            }
            if let path = result.epubPath,
                let index = EPUBIndexCache.shared.index(at: path)
            {
                return index.chapterText(named: result.chapter)
            }
            return nil
        case .wholeBook:
            if let record = result.capture,
                let index = CaptureIndexCache.shared.index(
                    directory: record.directory)
            {
                // A page-limited or partial capture is not a whole book.
                return captureCoversWholeBook(record) ? index.fullText : nil
            }
            if let path = result.epubPath,
                let index = EPUBIndexCache.shared.index(at: path)
            {
                return index.fullText
            }
            return nil
        }
    }
}

public extension ReadingContextResolver {
    /// The unpacked EPUB directories in the Books iCloud folder whose name
    /// matches the book title. Punctuation and spacing are ignored; a title
    /// with a trailing edition number is still a candidate, and the caller
    /// validates each by the live page text.
    static func epubIndexes(
        named title: String, in documents: URL = booksDocumentsDirectory
    ) -> [EPUBBookIndex] {
        let wanted = folded(title)
        guard !wanted.isEmpty else { return [] }
        let entries =
            ((try? FileManager.default.contentsOfDirectory(
                at: documents, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return entries.compactMap { url -> EPUBBookIndex? in
            guard url.pathExtension.lowercased() == "epub" else { return nil }
            let name = folded(url.deletingPathExtension().lastPathComponent)
            guard
                name == wanted || name.hasPrefix(wanted)
                    || wanted.hasPrefix(name)
            else { return nil }
            return EPUBIndexCache.shared.index(at: url)
        }
    }

    static var booksDocumentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Mobile Documents/iCloud~com~apple~iBooks/Documents")
    }

    static func folded(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = text.lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// A bounded, insertion-ordered cache.
///
/// Eviction removes the oldest entry, not the whole cache: clearing every
/// index on the 33rd book would turn one page turn into a cold load of all
/// of them. Parsing happens outside the lock; two callers may parse the same
/// book once, and the first result is kept.
private final class BoundedIndexCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var values: [String: Value] = [:]
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: String, load: () -> Value?) -> Value? {
        lock.lock()
        if let value = values[key] {
            lock.unlock()
            return value
        }
        lock.unlock()
        guard let loaded = load() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let existing = values[key] { return existing }
        if values.count >= capacity, let oldest = order.first {
            values.removeValue(forKey: oldest)
            order.removeFirst()
        }
        values[key] = loaded
        order.append(key)
        return loaded
    }
}

private final class CaptureIndexCache: @unchecked Sendable {
    static let shared = CaptureIndexCache()
    private let cache = BoundedIndexCache<BookTextIndex>(capacity: 32)

    func index(directory: String) -> BookTextIndex? {
        cache.value(for: directory) {
            try? BookTextIndex.load(
                directory: URL(fileURLWithPath: directory))
        }
    }
}

private final class EPUBIndexCache: @unchecked Sendable {
    static let shared = EPUBIndexCache()
    private let paths = BoundedIndexCache<URL>(capacity: 16)
    private let values = BoundedIndexCache<EPUBBookIndex>(capacity: 16)

    func epubPath(for identifier: String) -> URL? {
        let key = identifier.uppercased()
        return paths.value(for: key) {
            guard
                let asset = try? BooksAssetReader().asset(for: key),
                asset.drm == .clear, let path = asset.path
            else { return nil }
            return path
        }
    }

    func index(at path: URL) -> EPUBBookIndex? {
        values.value(for: path.path) {
            try? EPUBBookIndex(epubDirectory: path)
        }
    }
}
