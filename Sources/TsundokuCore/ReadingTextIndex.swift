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
    /// Stable across captures of the same book that start at the same page.
    public let fingerprint: String

    public init(pages: [IndexedPage]) {
        let sorted = pages.sorted { $0.page < $1.page }
        self.pages = sorted
        self.chapters = Self.chapterMarks(in: sorted)
        let first = sorted.first(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.text ?? ""
        self.fingerprint = TextIndexHash.hex(TextIndexHash.fnv(Self.normalize(first)))
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

    /// Finds the captured page whose text is this live page.
    ///
    /// An exact normalised match is the common case: both texts come from the
    /// same Accessibility page. When OCR or a different page extractor was
    /// used, an 8-word shingle overlap decides instead, and only above half
    /// the live page's shingles.
    public func match(pageText: String) -> Match? {
        let live = Self.normalize(pageText)
        guard live.count >= 20 else { return nil }
        for page in pages where Self.normalize(page.text) == live {
            return Match(page: page.page, chapter: chapter(for: page.page))
        }
        let liveShingles = Self.shingles(Self.words(live))
        guard liveShingles.count >= 3 else { return nil }
        var best: (page: IndexedPage, score: Double)?
        for page in pages {
            let shingles = Self.shingles(Self.words(Self.normalize(page.text)))
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
            return collapse(prefix)
        }
        guard
            first.firstMatch(
                #"^Chapter\s+\S+"#, options: [.caseInsensitive]) != nil
        else { return nil }
        var heading = first
        if !heading.hasSuffix("."), firstIndex + 1 < lines.count {
            let second = lines[firstIndex + 1]
            if !second.isEmpty, second.count < 80 {
                if heading.hasSuffix("-") {
                    // A heading broken after a hyphen keeps the hyphen: the
                    // capture cannot say whether it was soft.
                    heading += second
                } else {
                    heading += " " + second
                }
            }
        }
        return String(collapse(heading).prefix(120))
    }

    // MARK: Text normalisation

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
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
    private let chapterShingles: [Set<String>]

    public init(epubDirectory: URL) throws {
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
        for entry in entries {
            guard !seen.contains(entry.url.path) else { continue }
            seen.insert(entry.url.path)
            guard let html = Self.readText(entry.url) else { continue }
            let text = Self.plainText(html)
            if !text.isEmpty {
                chapters.append(Chapter(title: entry.title, text: text))
            }
        }
        self.chapters = chapters
        self.chapterShingles = chapters.map {
            BookTextIndex.shingles(BookTextIndex.words(
                BookTextIndex.normalize($0.text)))
        }
    }

    public func chapter(containing pageText: String) -> String? {
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
        guard let best, best.score >= 0.4 else { return nil }
        return best.title
    }

    // MARK: Navigation

    struct NavigationEntry {
        let url: URL
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
            let path = entry.href.split(separator: "#").first.map(String.init)
                ?? entry.href
            guard
                let url = try? EPUBPackage.resolve(
                    path, relativeTo: base, root: package.rootURL)
            else { return nil }
            return NavigationEntry(url: url, title: entry.title)
        }
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func anchors(in html: String) -> [(href: String, title: String)] {
        let pattern = #"<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        return regex.matches(
            in: html, range: NSRange(html.startIndex..., in: html)
        ).compactMap { match in
            guard
                let hrefRange = Range(match.range(at: 1), in: html),
                let titleRange = Range(match.range(at: 2), in: html)
            else { return nil }
            let title = plainText(String(html[titleRange]))
            guard !title.isEmpty else { return nil }
            return (href: String(html[hrefRange]), title: title)
        }
    }

    static func ncxEntries(in xml: String) -> [(href: String, title: String)] {
        let pattern =
            #"<navPoint\b[\s\S]*?<text>([\s\S]*?)</text>[\s\S]*?<content\b[^>]*src="([^"]+)""#
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
            of: "(?is)<(?:br|/p|/div|/h\\d)\\s*/?>",
            with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        return BookTextIndex.collapse(text)
    }

    private static func decodeEntities(_ text: String) -> String {
        var value = text
        let named = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ", "&mdash;": "—",
            "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’",
            "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
        ]
        for (entity, replacement) in named {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        if let regex = try? NSRegularExpression(
            pattern: #"&#(x?[0-9a-fA-F]+);"#)
        {
            let matches = regex.matches(
                in: value, range: NSRange(value.startIndex..., in: value))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: value),
                    let numberRange = Range(match.range(at: 1), in: value)
                else { continue }
                let raw = String(value[numberRange])
                let scalarValue =
                    raw.hasPrefix("x")
                    ? UInt32(raw.dropFirst(), radix: 16)
                    : UInt32(raw)
                if let scalarValue,
                    let scalar = UnicodeScalar(scalarValue)
                {
                    value.replaceSubrange(range, with: String(scalar))
                }
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

        public init(
            chapter: String?, pageNumber: Int?, fingerprint: String?,
            capture: CaptureRecord?
        ) {
            self.chapter = chapter
            self.pageNumber = pageNumber
            self.fingerprint = fingerprint
            self.capture = capture
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
            for candidate in candidates {
                guard
                    let path = EPUBIndexCache.shared.epubPath(for: candidate),
                    let index = EPUBIndexCache.shared.index(at: path),
                    let chapter = index.chapter(containing: pageText)
                else { continue }
                return Result(
                    chapter: chapter, pageNumber: nil, fingerprint: nil,
                    capture: nil)
            }
            // The Books library's own container can be unreadable while its
            // unpacked EPUBs are still in the iCloud Books folder. Name
            // matching narrows the field; the page text decides.
            for index in epubIndexes(named: title) {
                guard let chapter = index.chapter(containing: pageText)
                else { continue }
                return Result(
                    chapter: chapter, pageNumber: nil, fingerprint: nil,
                    capture: nil)
            }
        }
        let source = kind == .kindle ? "kindle" : "applebooks"
        // A full-book capture has the chapter marks; check the largest
        // captures first so a recent two-page sample cannot hide them.
        let candidates = captures.filter { $0.source == source }
            .sorted { $0.pageCount > $1.pageCount }
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
            (try? FileManager.default.contentsOfDirectory(
                at: documents, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
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

private final class CaptureIndexCache: @unchecked Sendable {
    static let shared = CaptureIndexCache()
    private let lock = NSLock()
    private var values: [String: BookTextIndex] = [:]

    func index(directory: String) -> BookTextIndex? {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[directory] { return value }
        guard
            let index = try? BookTextIndex.load(
                directory: URL(fileURLWithPath: directory))
        else { return nil }
        if values.count >= 32 { values.removeAll() }
        values[directory] = index
        return index
    }
}

private final class EPUBIndexCache: @unchecked Sendable {
    static let shared = EPUBIndexCache()
    private let lock = NSLock()
    private var paths: [String: URL] = [:]
    private var values: [String: EPUBBookIndex] = [:]

    func epubPath(for identifier: String) -> URL? {
        let key = identifier.uppercased()
        lock.lock()
        if let url = paths[key] {
            lock.unlock()
            return url
        }
        lock.unlock()
        guard
            let asset = try? BooksAssetReader().asset(for: key),
            asset.drm == .clear, let path = asset.path
        else { return nil }
        lock.lock()
        if paths.count >= 16 { paths.removeAll() }
        paths[key] = path
        lock.unlock()
        return path
    }

    func index(at path: URL) -> EPUBBookIndex? {
        lock.lock()
        defer { lock.unlock() }
        let key = path.path
        if let value = values[key] { return value }
        guard let index = try? EPUBBookIndex(epubDirectory: path) else {
            return nil
        }
        if values.count >= 16 { values.removeAll() }
        values[key] = index
        return index
    }
}
