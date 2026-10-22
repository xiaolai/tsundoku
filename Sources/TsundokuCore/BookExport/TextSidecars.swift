import Foundation

/// One captured page's text, as recorded in `text.jsonl`.
public struct CapturedPageText: Sendable, Equatable {
    public let page: Int
    public let text: String
    public let source: String

    public init(page: Int, text: String, source: String) {
        self.page = page
        self.text = text
        self.source = source
    }
}

public struct TextSidecarSummary: Sendable, Equatable {
    public let pages: Int
    public let markdown: String
    public let perPage: String

    public init(pages: Int, markdown: String, perPage: String) {
        self.pages = pages
        self.markdown = markdown
        self.perPage = perPage
    }

    public var manifest: [String: Any] {
        [
            "pages": pages,
            "markdown": markdown,
            "perPage": perPage,
        ]
    }
}

public enum TextSidecarError: Error, CustomStringConvertible, Sendable {
    case missingText(URL)
    case malformedLine(Int)
    case io(String)

    public var description: String {
        switch self {
        case .missingText(let url):
            "The capture has no text.jsonl at \(url.path)."
        case .malformedLine(let line):
            "text.jsonl line \(line) is not a page record."
        case .io(let message):
            "The text sidecars could not be written: \(message)"
        }
    }
}

/// Writes `text.md` and a `.txt` beside each page image from the captured
/// per-page text. Normalisation stops at whitespace around page boundaries:
/// no text is added, removed or reflowed.
public enum TextSidecars {
    public static func load(from directory: URL) throws
        -> [CapturedPageText]
    {
        let url = directory.appendingPathComponent("text.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw TextSidecarError.missingText(url)
        }
        var pages: [CapturedPageText] = []
        for (index, line) in content.split(
            separator: "\n", omittingEmptySubsequences: true
        ).enumerated() {
            guard
                let object = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any],
                let page = object["page"] as? Int,
                let text = object["text"] as? String
            else {
                throw TextSidecarError.malformedLine(index + 1)
            }
            pages.append(
                CapturedPageText(
                    page: page, text: text,
                    source: object["source"] as? String ?? "none"))
        }
        return pages.sorted { $0.page < $1.page }
    }

    public static func markdown(pages: [CapturedPageText]) -> String {
        let hasOCR = pages.contains { $0.source == "ocr" }
        let blocks = pages.sorted { $0.page < $1.page }.map { page -> String in
            let body = normalise(page.text)
            return "## Page \(page.page)\n\n"
                + (body.isEmpty ? "" : body + "\n")
        }
        let body = blocks.joined(separator: "\n---\n\n")
        guard hasOCR else { return body }
        return "> Read with OCR — check the text before relying on it.\n\n"
            + body
    }

    public static func write(
        pages: [CapturedPageText], to directory: URL
    ) throws -> TextSidecarSummary {
        let manager = FileManager.default
        let pagesDirectory = directory.appendingPathComponent("pages")
        do {
            try manager.createDirectory(
                at: pagesDirectory, withIntermediateDirectories: true)
            let markdown = markdown(pages: pages)
            try markdown.write(
                to: directory.appendingPathComponent("text.md"),
                atomically: true, encoding: .utf8)
            for page in pages.sorted(by: { $0.page < $1.page }) {
                let body = normalise(page.text)
                let file = pagesDirectory.appendingPathComponent(
                    String(format: "page-%04d.txt", page.page))
                try (body.isEmpty ? "" : body + "\n").write(
                    to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            throw TextSidecarError.io("\(error)")
        }
        return TextSidecarSummary(
            pages: pages.count, markdown: "text.md",
            perPage: "pages/*.txt")
    }

    /// Only the whitespace at the page boundary: leading and trailing spaces,
    /// tabs and newlines. Interior whitespace is the page's own.
    public static func normalise(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
