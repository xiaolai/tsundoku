import Foundation
import Testing

@testable import TsundokuCore

@Suite("Answer blocks")
struct MarkdownBlockTests {
    @Test("headings, lists and paragraphs stay separate blocks")
    func structure() {
        let blocks = MarkdownBlocks.parse(
            """
            ## Key Terms

            Momentum is the first term.

            - Trend
            - Reversal
            """)
        #expect(blocks.count == 3)
        #expect(blocks.first == .heading("Key Terms", level: 2))
        #expect(
            blocks.contains(
                .list([
                    .init(text: "Trend", number: nil, depth: 0),
                    .init(text: "Reversal", number: nil, depth: 0),
                ])))
    }

    @Test("an ordered list keeps its numbers and its nesting")
    func ordered() {
        let blocks = MarkdownBlocks.parse(
            """
            1. First
            2. Second
               - Nested
            """)
        guard case .list(let items)? = blocks.first else {
            Issue.record("expected one list, got \(blocks)")
            return
        }
        #expect(items.count == 3)
        #expect(items[1].number == 2)
        #expect(items[2].depth == 1)
        #expect(items[2].number == nil)
    }

    @Test("a fenced block is code even with markdown inside it")
    func code() {
        let blocks = MarkdownBlocks.parse(
            """
            Before.

            ```swift
            let x = 1 // * not emphasis
            ```

            After.
            """)
        #expect(
            blocks == [
                .paragraph("Before."),
                .code("let x = 1 // * not emphasis", language: "swift"),
                .paragraph("After."),
            ])
    }

    @Test("an unterminated fence loses its border, not its text")
    func unterminatedCode() {
        let blocks = MarkdownBlocks.parse("```\nline one\nline two")
        #expect(blocks == [.code("line one\nline two", language: nil)])
    }

    @Test("a table is read as columns, and other pipes are not")
    func table() {
        let blocks = MarkdownBlocks.parse(
            """
            | Term | Meaning |
            | --- | --- |
            | A4 | A page size |
            | pt | A point |
            """)
        #expect(
            blocks == [
                .table(
                    header: ["Term", "Meaning"],
                    rows: [["A4", "A page size"], ["pt", "A point"]])
            ])
        // A line with a pipe but no separator under it is prose.
        #expect(
            MarkdownBlocks.parse("a | b\nplain") == [.paragraph("a | b plain")])
    }

    @Test("quotes and rules are their own blocks")
    func quoteAndRule() {
        let blocks = MarkdownBlocks.parse(
            """
            > Quoted line

            ---
            """)
        #expect(blocks == [.quote("Quoted line"), .rule])
    }

    @Test("plain prose with no markdown is one paragraph")
    func plain() {
        #expect(
            MarkdownBlocks.parse("One sentence.\nStill one paragraph.")
                == [.paragraph("One sentence. Still one paragraph.")])
    }
}
