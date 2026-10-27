import Foundation

/// A transcript file the reader explicitly exports. The raw prompt blob is
/// not included; the context and the visible answers are.
public enum ConversationExport {
    public enum Format: String, CaseIterable, Sendable, Equatable {
        case markdown
        case json

        public var displayName: String {
            switch self {
            case .markdown: "Markdown"
            case .json: "JSON"
            }
        }

        public var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .json: "json"
            }
        }
    }

    public static func title(
        conversation: Conversation, turns: [ConversationTurn]
    ) -> String {
        let explicit = conversation.title?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty { return explicit }
        return turns.first?.promptLabel ?? conversation.bookTitle
    }

    public static func markdown(
        conversation: Conversation, turns: [ConversationTurn],
        compaction: ConversationCompaction?
    ) -> String {
        var lines: [String] = [
            "# \(inline(title(conversation: conversation, turns: turns)))",
            "",
            "- Book: \(inline(conversation.bookTitle))",
            "- Started: \(date(conversation.createdAt))",
            "- Updated: \(date(conversation.updatedAt))",
            "- Turns: \(turns.count)",
        ]
        if let compaction {
            lines += [
                "",
                "## Earlier Conversation Summary",
                "",
                "Covers turns through \(compaction.throughTurnID), written "
                    + "\(date(compaction.createdAt)) by "
                    + "\(inline(compaction.provider)).",
                "",
            ]
            lines += literal(compaction.summary)
        }
        lines.append("")
        for (index, turn) in turns.enumerated() {
            lines += [
                "## \(index + 1). \(inline(turn.promptLabel))",
                "",
                "- Action: \(turn.action.displayName)",
                "- Turn ID: \(turn.id)",
                "- Provider: \(inline(turn.provider))",
                "- Time: \(date(turn.createdAt))",
                "- Context: \(inline(contextLine(turn.context)))",
            ]
            if let page = turn.context.pageLabel {
                lines.append("- Page: \(inline(page))")
            }
            if let chapter = turn.context.chapter, !chapter.isEmpty {
                lines.append("- Chapter: \(inline(chapter))")
            }
            if let source = turn.context.bookSource {
                lines.append("- Book source: \(source.rawValue)")
            }
            if let reader = turn.context.reader {
                lines.append("- Reader: \(reader.displayName)")
            }
            if let scope = turn.context.scope {
                lines.append("- Scope: \(scope.displayName)")
            }
            // The question, selection and excerpt keep their line breaks;
            // flattening them would lose paragraphs the reader may need to
            // read the answer against.
            if !turn.question.isEmpty {
                lines += ["", "**Question**", ""]
                lines += literal(turn.question)
            }
            if let selection = turn.context.selection, !selection.isEmpty {
                lines += ["", "**Selection**", ""]
                lines += literal(selection)
            }
            if !turn.context.excerpt.isEmpty {
                lines += ["", "**Excerpt**", ""]
                lines += literal(turn.context.excerpt)
            }
            lines += ["", "**Answer**", ""]
            lines += literal(turn.answer)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown safety

    /// Stored transcripts are data, not document structure. A fenced block
    /// keeps every line literal: a heading, a link or an image in an answer
    /// cannot restructure the export or make a renderer fetch external
    /// content. The fence is longer than any backtick run in the text, so
    /// the stored text cannot close it early.
    private static func literal(_ text: String) -> [String] {
        var longestRun = 0
        var run = 0
        for character in text {
            if character == "`" {
                run += 1
                longestRun = max(longestRun, run)
            } else {
                run = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return [fence + "text"]
            + text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)
            + [fence]
    }

    /// One line for a heading or a list item. Newlines would split the
    /// structure, HTML would disappear, and live Markdown syntax could turn
    /// a title into a link or an image.
    private static func inline(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        let escapedHTML = oneLine
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        var result = ""
        result.reserveCapacity(escapedHTML.count)
        for character in escapedHTML {
            if "\\`*_{}[]()!|~".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    public static func json(
        conversation: Conversation, turns: [ConversationTurn],
        compaction: ConversationCompaction?
    ) throws -> String {
        let document = ExportDocument(
            title: title(conversation: conversation, turns: turns),
            book: ExportBook(
                key: conversation.bookKey,
                title: conversation.bookTitle,
                source: conversation.bookSource?.rawValue),
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            compaction: compaction.map {
                ExportCompaction(
                    throughTurnID: $0.throughTurnID, summary: $0.summary,
                    provider: $0.provider, model: $0.model,
                    createdAt: $0.createdAt)
            },
            turns: turns.map {
                ExportTurn(
                    id: $0.id, action: $0.action.rawValue,
                    question: $0.question, answer: $0.answer,
                    provider: $0.provider, context: $0.context,
                    createdAt: $0.createdAt)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }

    private static func date(_ value: Date) -> String {
        ISO8601DateFormatter().string(from: value)
    }

    private static func contextLine(_ context: AIContext) -> String {
        let attachments = context.attachments
        return attachments.isEmpty ? "None" : attachments.joined(separator: " · ")
    }

    private struct ExportDocument: Codable {
        let title: String
        let book: ExportBook
        let createdAt: Date
        let updatedAt: Date
        let compaction: ExportCompaction?
        let turns: [ExportTurn]
    }

    private struct ExportBook: Codable {
        let key: String
        let title: String
        let source: String?
    }

    private struct ExportCompaction: Codable {
        let throughTurnID: Int64
        let summary: String
        let provider: String
        let model: String?
        let createdAt: Date
    }

    private struct ExportTurn: Codable {
        let id: Int64
        let action: String
        let question: String
        let answer: String
        let provider: String
        let context: AIContext
        let createdAt: Date
    }
}
