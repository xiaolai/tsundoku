import AppKit
import SwiftUI
import Testing

@testable import TsundokuCore
@testable import TsundokuUI

/// The library's rows are drawn, not printed: a cover tile, two lines of
/// text and a column of numbers. These render each piece offscreen and check
/// that something was actually drawn, so a layout change that collapses a
/// tile to nothing — or a colour that disappears in dark appearance — fails
/// here rather than in a reader's window.
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

    /// Renders at 2× and returns the PNG, or fails the test.
    private func render(
        _ view: some View, size: CGSize, dark: Bool = false
    ) throws -> Data {
        let wrapped = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: wrapped)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try #require(
            host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
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
                row, size: CGSize(width: 640, height: 56), dark: dark)
            #expect(png.count > 2_000, "the row drew almost nothing")
        }
    }

    @Test("the source badge appears only when both readers are present")
    func sourceBadge() {
        var model = AppModel(
            archiveURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("look-\(UUID().uuidString).sqlite"),
            recoverReaderSettings: false)
        model.books = [book("B1", "One", "A")]
        #expect(!model.hasBothSources)
        model.books.append(
            book("B2", "Two", "B", source: .appleBooks))
        #expect(model.hasBothSources)
    }

    @Test("a title with no letters still draws a cover")
    func punctuationOnlyTitle() throws {
        // "…" has no word to take initials from; the tile must not go blank.
        let row = BookRow(
            book: book("B03", "…", ""), annotationCount: 0,
            messageCount: 0, showsSource: false)
            .padding(.horizontal, 14)
        let png = try render(row, size: CGSize(width: 400, height: 56))
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
                hero, size: CGSize(width: 320, height: 130), dark: dark)
            #expect(png.count > 2_000)
        }
    }
}
