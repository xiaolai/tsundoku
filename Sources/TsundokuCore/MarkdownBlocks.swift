import Foundation

/// One block of an answer, as a model writes it. Answers contain headings,
/// lists, quotes, code and tables; rendering them as one inline paragraph
/// loses every one of those, which is why this exists.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(String, level: Int)
    case paragraph(String)
    /// A run of list items, kept together so the renderer can number them.
    case list([MarkdownListItem])
    case quote(String)
    case code(String, language: String?)
    case table(header: [String], rows: [[String]])
    case rule

    public struct MarkdownListItem: Equatable, Sendable {
        public let text: String
        /// The number an ordered item carried, or nil for a bullet.
        public let number: Int?
        /// Nesting depth, from leading indentation.
        public let depth: Int
    }
}

/// A deliberately small block parser: the constructs a reading companion
/// actually shows, and nothing else. Anything unrecognised stays a paragraph
/// and is still displayed, so an odd document loses formatting, never text.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [MarkdownBlock.MarkdownListItem] = []
        var quote: [String] = []
        var code: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        func flushList() {
            guard !list.isEmpty else { return }
            blocks.append(.list(list))
            list = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n"), language: codeLanguage))
                    code = []
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushAll()
                    inCode = true
                    let tag = trimmed.dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    codeLanguage = tag.isEmpty ? nil : tag
                }
                index += 1
                continue
            }
            if inCode {
                code.append(line)
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                guard level <= 6 else {
                    paragraph.append(trimmed)
                    index += 1
                    continue
                }
                flushAll()
                blocks.append(
                    .heading(
                        trimmed.dropFirst(level)
                            .trimmingCharacters(in: .whitespaces),
                        level: level))
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(
                    trimmed.dropFirst()
                        .trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            if isTableStart(lines: lines, at: index) {
                flushAll()
                var header: [String] = tableCells(lines[index])
                var rows: [[String]] = []
                index += 2  // skip the header and its separator
                while index < lines.count,
                    lines[index].trimmingCharacters(in: .whitespaces)
                        .hasPrefix("|")
                {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                header = []
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                list.append(item)
                index += 1
                continue
            }

            flushList()
            flushQuote()
            paragraph.append(trimmed)
            index += 1
        }
        if inCode, !code.isEmpty {
            // An unterminated fence is still code; a model that stopped early
            // should lose the border, not the text.
            blocks.append(.code(code.joined(separator: "\n"), language: codeLanguage))
        } else {
            flushAll()
        }
        return blocks
    }

    private static func listItem(
        _ line: String
    ) -> MarkdownBlock.MarkdownListItem? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let depth = leading.filter { $0 == " " }.count / 2
        let body = line.dropFirst(leading.count)
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("• ")
        {
            return .init(
                text: String(body.dropFirst(2)), number: nil, depth: depth)
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = body.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .init(
            text: String(rest.dropFirst(2)), number: Int(digits), depth: depth)
    }

    private static func isTableStart(lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let head = lines[index].trimmingCharacters(in: .whitespaces)
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard head.hasPrefix("|"), separator.hasPrefix("|") else {
            return false
        }
        let dashes = separator.filter { $0 == "-" }
        let pipes = separator.filter { $0 == "|" }
        return !dashes.isEmpty && pipes.count == head.filter { $0 == "|" }.count
    }

    private static func tableCells(_ line: String) -> [String] {
        line.trimmingCharacters(in: .whitespaces)
            .split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst()
            .dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
