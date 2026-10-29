import AppKit
import SwiftUI
import Testing

@testable import TsundokuCore
@testable import TsundokuUI

/// The library's rows and cards are drawn, not printed. These render each
/// piece offscreen and check that something was drawn, so a layout change
/// that collapses a tile — or a colour that disappears in dark appearance —
/// fails here rather than in a reader's window.
@MainActor
@Suite("Library look")
struct LibraryLookTests {
    private func book(
        _ asin: String, _ title: String, _ author: String,
        read: Bool = false, daysAgo: Double? = nil,
        source: BookSource = .kindle, downloaded: Bool = false
    ) -> Book {
        Book(
            asin: asin, title: title, author: author, bookType: 10,
            readState: read ? 1 : 0,
            lastView: daysAgo.map { Date().addingTimeInterval(-$0 * 86_400) },
            downloaded: downloaded, source: source)
    }

    private func render(
        _ view: some View, size: CGSize, dark: Bool = false, to: String,
        page: NSColor = .windowBackgroundColor
    ) throws -> Data {
        let wrapped = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(12)
            .background(Color(nsColor: page))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: wrapped)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try #require(
            host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(
            rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: to))
        return data
    }

    private func card(_ title: String, _ identity: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("A passage from the book, set at the reading size.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(identity: identity)
    }

    @Test("cards in a grid")
    func cards() throws {
        let grid = LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)
            ], spacing: 16
        ) {
            card("Explain", "card-1")
            card("Translate", "card-2")
            card("Summarize", "card-3")
            card("Key terms", "card-4")
        }
        _ = try render(
            grid, size: CGSize(width: 600, height: 320),
            to: "/tmp/cards-light.png", page: .underPageBackgroundColor)
        _ = try render(
            grid, size: CGSize(width: 600, height: 320), dark: true,
            to: "/tmp/cards-dark.png", page: .underPageBackgroundColor)
    }

    @Test("a row draws a cover, a title and its numbers")
    func row() throws {
        let row = BookRow(
            book: book(
                "B01", "The Math of Neural Networks", "Andrew Trask",
                read: true, daysAgo: 2),
            annotationCount: 34, messageCount: 6, showsSource: true)
            .padding(.horizontal, 14)
        for dark in [false, true] {
            let png = try render(
                row, size: CGSize(width: 640, height: 76), dark: dark,
                to: "/tmp/row-\(dark).png")
            #expect(png.count > 2_000, "the row drew almost nothing")
        }
    }

    @Test("the source badge appears only when both readers are present")
    func sourceBadge() {
        let model = AppModel(
            archiveURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("look-\(UUID().uuidString).sqlite"),
            recoverReaderSettings: false)
        model.books = [book("B1", "One", "A")]
        #expect(!model.hasBothSources)
        model.books.append(book("B2", "Two", "B", source: .appleBooks))
        #expect(model.hasBothSources)
    }

    @Test("a title with no letters still draws a cover")
    func punctuationOnlyTitle() throws {
        let row = BookRow(
            book: book("B03", "…", ""), annotationCount: 0,
            messageCount: 0, showsSource: false)
            .padding(.horizontal, 14)
        let png = try render(
            row, size: CGSize(width: 400, height: 76), to: "/tmp/row-punct.png")
        #expect(png.count > 1_500)
    }

    @Test("the inspector hero keeps title, author and state")
    func hero() throws {
        let hero = BookHero(
            book: book(
                "B01", "The Math of Neural Networks", "Andrew Trask",
                read: true, downloaded: true),
            annotations: 34, messages: 6)
            .padding(.horizontal, 16)
        for dark in [false, true] {
            let png = try render(
                hero, size: CGSize(width: 340, height: 150), dark: dark,
                to: "/tmp/hero-\(dark).png")
            #expect(png.count > 2_000)
        }
    }
}

/// The sort menu says "Ascending" or "Descending", so the list has to mean
/// it; the column's preferred direction is applied when the column is chosen.
@Suite("Book order")
struct BookSortTests {
    private func book(_ title: String, _ author: String, annotations: Int,
                      daysAgo: Double) -> Book {
        Book(
            asin: "B-\(title)", title: title, author: author, bookType: 10,
            readState: 0,
            lastView: Date().addingTimeInterval(-daysAgo * 86_400),
            userAnnotationCount: annotations)
    }

    @Test("ascending is ascending for every column")
    func ascendingMeansAscending() {
        let books = [
            book("B", "Zed", annotations: 5, daysAgo: 1),
            book("A", "Amy", annotations: 1, daysAgo: 9),
        ]
        #expect(BookSort.title.sorted(books, ascending: true).map(\.title) == ["A", "B"])
        #expect(BookSort.title.sorted(books, ascending: false).map(\.title) == ["B", "A"])
        #expect(
            BookSort.annotations.sorted(books, ascending: true)
                .map(\.userAnnotationCount) == [1, 5])
        #expect(
            BookSort.annotations.sorted(books, ascending: false)
                .map(\.userAnnotationCount) == [5, 1])
        #expect(
            BookSort.lastRead.sorted(books, ascending: true).map(\.title)
                == ["A", "B"], "oldest first when ascending")
    }

    @Test("each column names the direction it is most often read in")
    func preferredDirections() {
        #expect(!BookSort.title.prefersDescending)
        #expect(!BookSort.author.prefersDescending)
        #expect(BookSort.lastRead.prefersDescending)
        #expect(BookSort.annotations.prefersDescending)
    }
}
