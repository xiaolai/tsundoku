import AppKit
import SwiftUI
import TsundokuCore

/// A book's cover, or a designed stand-in for one.
///
/// The library has no cover artwork to show. Covers live in the Kindle
/// metadata cache and the export pipeline writes one to disk per book, which
/// is a read the list cannot afford per row — so the list shows a spine: a
/// cloth tile with the title's initials and a colour taken from the book's
/// own identity. It reads as a shelf rather than as a column of empty boxes,
/// and a real `image` takes its place without the layout changing.
struct BookCoverTile: View {
    let book: Book
    var image: NSImage? = nil
    var width: CGFloat = 28
    var height: CGFloat = 40
    @Environment(\.colorScheme) private var scheme
    /// Artwork, once it has been resolved. Until then the spine stands in.
    @State private var loaded: NSImage?

    private var initials: String {
        let letters = book.title
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .prefix(2)
            .compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// A shelf, not a colour wheel: eight book-cloth hues drawn by hash, so a
    /// row of tiles looks chosen rather than generated, and a book keeps its
    /// colour between launches.
    private var clothHue: (hue: Double, saturation: Double) {
        var hash: UInt64 = 5381
        for byte in (book.asin + book.title).utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let cloths: [(hue: Double, saturation: Double)] = [
            (0.02, 0.52),  // brick
            (0.08, 0.55),  // ochre
            (0.13, 0.45),  // olive
            (0.33, 0.35),  // forest
            (0.50, 0.30),  // teal
            (0.60, 0.40),  // indigo
            (0.75, 0.30),  // plum
            (0.92, 0.25),  // oxblood
        ]
        return cloths[Int(hash % UInt64(cloths.count))]
    }

    private var cloth: Color {
        Color(
            hue: clothHue.hue, saturation: clothHue.saturation,
            brightness: scheme == .dark ? 0.42 : 0.66)
    }

    /// Dark appearance dims the cloth: a bright tile on a dark window reads as
    /// a light rather than as part of the shelf.
    private var clothShade: Color {
        Color(
            hue: clothHue.hue, saturation: clothHue.saturation,
            brightness: scheme == .dark ? 0.30 : 0.50)
    }

    private var artwork: NSImage? { image ?? loaded }

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [cloth, clothShade],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .leading) {
                // Where the boards meet the spine.
                Rectangle()
                    .fill(.white.opacity(scheme == .dark ? 0.10 : 0.16))
                    .frame(width: 1.5)
                    .padding(.leading, 3.5)
            }
            .overlay(alignment: .bottomLeading) {
                if artwork == nil {
                    Text(initials)
                        .font(.system(size: height * 0.21, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.leading, 8)
                        .padding(.bottom, height * 0.12)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            .overlay {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        // Constrained before clipping: a wide cover filled
                        // beyond the tile, and the clip followed the filled
                        // bounds rather than the tile's.
                        .frame(width: width, height: height)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 2.5,
                                style: .continuous))
                }
            }
            .shadow(
                color: .black.opacity(scheme == .dark ? 0 : 0.16),
                radius: 1.2, x: 0, y: 0.8)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
            .task(id: BookCoverService.cacheKey(
                for: book.asin, source: book.source)
            ) {
                // The row draws its spine first; the artwork replaces it when
                // the store answers, and the store answers from memory for a
                // row that scrolls back into view. A view reused for another
                // book must drop the previous artwork, or the inspector would
                // show the wrong cover.
                loaded = nil
                guard image == nil, !book.asin.isEmpty else { return }
                let resolved = await BookCoverStore.shared.thumbnail(
                    for: book)
                guard !Task.isCancelled, let resolved else { return }
                loaded = NSImage(
                    cgImage: resolved,
                    size: NSSize(
                        width: resolved.width, height: resolved.height))
            }
    }
}

/// One book, as a reader thinks of it: a cover, a title, who wrote it, and
/// only the numbers that tell two books apart.
struct BookRow: View {
    let book: Book
    let annotationCount: Int
    let messageCount: Int
    /// Drawn only when the list holds more than one reader; a source filter
    /// makes it redundant.
    let showsSource: Bool

    private var subtitle: String {
        book.author.isEmpty ? "Unknown author" : book.author
    }

    var body: some View {
        HStack(spacing: 12) {
            BookCoverTile(book: book)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if showsSource {
                        SourceBadge(source: book.source)
                    }
                }
            }
            Spacer(minLength: 8)
            if book.isRead {
                // Only the positive state is drawn: an unread book needs no
                // mark, and a column of hollow circles is noise.
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Read")
                    .accessibilityLabel("Read")
            }
            BookMetrics(
                annotations: annotationCount, messages: messageCount,
                lastRead: book.lastView)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(
            book.title + (book.author.isEmpty ? "" : " — \(book.author)"))
    }
}

/// The numbers, in fixed columns so a column of rows reads as a table
/// without any rules being drawn.
private struct BookMetrics: View {
    let annotations: Int
    let messages: Int
    let lastRead: Date?

    private var date: String {
        guard lastRead != nil else { return "Never" }
        return TsundokuFormat.relative(lastRead)
    }

    var body: some View {
        HStack(spacing: 0) {
            count(annotations, tooltip: "annotations", width: 26)
            count(messages, tooltip: "chats", width: 26)
                .padding(.trailing, 12)
            Text(date)
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(lastRead == nil ? .quaternary : .tertiary)
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
    }

    /// A missing count is a dash in the quietest ink, so the numbers that do
    /// exist read first.
    private func count(_ value: Int, tooltip: String, width: CGFloat)
        -> some View
    {
        Text(value > 0 ? "\(value)" : "–")
            .foregroundStyle(value > 0 ? .secondary : .quaternary)
            .frame(width: width, alignment: .trailing)
            .help(value > 0 ? "\(value) \(tooltip)" : "No \(tooltip)")
    }
}

/// The reader a book came from, as a word rather than an icon: two book
/// glyphs in one row are indistinguishable at 10 points.
struct SourceBadge: View {
    let source: BookSource

    private var label: String {
        source == .kindle ? "KINDLE" : "BOOKS"
    }

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
            .accessibilityLabel(source.displayName)
    }
}

/// How the library is ordered. A list has no column headers to click, so the
/// order is named in the toolbar and the direction is part of the choice.
enum BookSort: String, CaseIterable, Identifiable {
    case title
    case author
    case lastRead
    case annotations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .lastRead: "Last Read"
        case .annotations: "Annotations"
        }
    }

    /// The direction a reader most often wants for this column: titles read
    /// A→Z, and the point of sorting by last read is the most recent book.
    var prefersDescending: Bool {
        switch self {
        case .title, .author: false
        case .lastRead, .annotations: true
        }
    }

    func sorted(_ books: [Book], ascending: Bool) -> [Book] {
        let ordered: [Book]
        switch self {
        case .title:
            ordered = books.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            }
        case .author:
            ordered = books.sorted {
                let left = $0.author.isEmpty ? "Unknown author" : $0.author
                let right = $1.author.isEmpty ? "Unknown author" : $1.author
                return left.localizedCaseInsensitiveCompare(right)
                    == .orderedAscending
            }
        case .lastRead:
            ordered = books.sorted {
                ($0.lastView ?? .distantPast) < ($1.lastView ?? .distantPast)
            }
        case .annotations:
            ordered = books.sorted {
                $0.userAnnotationCount < $1.userAnnotationCount
            }
        }
        // Ascending means ascending: A→Z, oldest first, fewest first. The
        // useful default per column is `prefersDescending`, applied when the
        // sort changes, not silently inside the comparison.
        return ascending ? ordered : ordered.reversed()
    }
}

/// The shelf. A list rather than a table: a table's row is 24 points tall and
/// a book needs its cover, a title and an author. Selection, keyboard
/// navigation and the context menu still come from `List`.
struct BookList: View {
    @ObservedObject var model: AppModel
    let rows: [Book]
    let countLine: String
    let showsSource: Bool
    let resetFilters: () -> Void

    var body: some View {
        List(selection: $model.selectedBookID) {
            ForEach(rows) { book in
                BookRow(
                    book: book,
                    annotationCount: book.userAnnotationCount,
                    messageCount: model.conversationCount(for: book),
                    showsSource: showsSource)
                    .tag(book.asin)
                    .listRowInsets(
                        EdgeInsets(
                            top: 2, leading: 14, bottom: 2, trailing: 14))
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            model.bookWorkspaceSection = .annotations
                            model.bookWorkspaceID = book.asin
                        })
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Open Annotations") {
                model.bookWorkspaceSection = .annotations
                model.bookWorkspaceID = ids.first
            }
            .disabled(ids.count != 1)
            Button("Open Chats") {
                model.bookWorkspaceSection = .chats
                model.bookWorkspaceID = ids.first
            }
            .disabled(ids.count != 1)
            Divider()
            Button("Show This Book in the Library") {
                if let id = ids.first { model.revealBook(asin: id) }
            }
            .disabled(ids.count != 1)
        } primaryAction: { ids in
            model.bookWorkspaceSection = .annotations
            model.bookWorkspaceID = ids.first
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(countLine)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                IconButton("Open Annotations", systemImage: "book.pages") {
                    model.bookWorkspaceSection = .annotations
                    model.bookWorkspaceID = model.selectedBookID
                }
                .disabled(model.selectedBookID == nil)
                IconButton(
                    "Reset Filters",
                    systemImage: "line.3.horizontal.decrease.circle"
                ) { resetFilters() }
            }
            .padding(10)
        }
    }
}

/// The inspector's opening statement: the book as an object, then the few
/// facts worth reading before the actions.
struct BookHero: View {
    let book: Book
    let annotations: Int
    let messages: Int

    private var author: String {
        book.author.isEmpty ? "Unknown author" : book.author
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCoverTile(
                book: book, width: 64, height: 88)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.system(size: 16, weight: .semibold))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(author)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                // State is a sentence, not a row of controls: one accent for
                // the reader's own progress, the rest as quiet facts.
                HStack(spacing: 6) {
                    SourceBadge(source: book.source)
                    if book.isRead {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("Read")
                        }
                        .foregroundStyle(.tint)
                        .font(.system(size: 10.5, weight: .medium))
                    }
                    if book.downloaded {
                        Text("Downloaded")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    if book.isFixedLayout {
                        Text("Fixed layout")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 14) {
                    Text(
                        "\(annotations) "
                            + (annotations == 1 ? "annotation" : "annotations"))
                    Text("\(messages) " + (messages == 1 ? "chat" : "chats"))
                }
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
