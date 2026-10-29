import SwiftUI
import TsundokuCore

public struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var scope: Scope = .all
    @State private var sort: BookSort = .title
    @State private var ascending = true
    @AppStorage("library.inspector") private var showInspector = false

    public init(model: AppModel) {
        self.model = model
    }

    enum Scope: String, CaseIterable, Identifiable {
        case all
        case read
        case unread
        case annotated

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All Books"
            case .read: "Read"
            case .unread: "Unread"
            case .annotated: "With Annotations"
            }
        }
    }

    /// A route from elsewhere asked for one book; the scope filter is this
    /// view's own state, so clearing it is this view's job. The request is
    /// consumed, so reopening the window does not jump back to it.
    private func applyReveal() {
        guard let reveal = model.libraryReveal else { return }
        scope = .all
        model.selectedBookID = reveal.asin
        model.consumeLibraryReveal(reveal.generation)
    }

    private func resetFilters() {
        model.search = ""
        model.sourceFilter = .all
        scope = .all
    }

    private var rows: [Book] {
        let result = model.filteredBooks.filter { book in
            switch scope {
            case .all: true
            case .read: book.isRead
            case .unread: !book.isRead
            case .annotated: book.userAnnotationCount > 0
            }
        }
        return sort.sorted(result, ascending: ascending)
    }

    public var body: some View {
        Group {
            if let id = model.bookWorkspaceID,
                let book = model.books.first(where: { $0.asin == id })
            {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            model.bookWorkspaceID = nil
                        } label: {
                            Label("Books", systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .help("Back to books")
                        Text(book.author).foregroundStyle(.secondary).lineLimit(
                            1)
                        Spacer()
                        Picker(
                            "", selection: $model.bookWorkspaceSection
                        ) {
                            ForEach(AppModel.BookWorkspaceSection.allCases) {
                                section in
                                Text(section.title).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Menu {
                            Button("Show in Annotations Library") {
                                model.bookWorkspaceID = nil
                                model.showAnnotations(for: book)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More for this book")
                        .accessibilityLabel("More for this book")
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                    switch model.bookWorkspaceSection {
                    case .annotations:
                        HighlightsView(model: model, book: book).id(book.asin)
                    case .chats:
                        BookChatsView(model: model, book: book)
                            .id("chats-\(book.asin)")
                    }
                }
                .navigationTitle(book.title)
            } else {
                bookList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PermissionBanner(model: model)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .tsundokuBrowserCommand)
        ) { notification in
            guard browserWindowIsKey,
                let command = notification.userInfo?["command"] as? String
            else {
                return
            }
            if command == "back" { model.bookWorkspaceID = nil }
            if model.bookWorkspaceID == nil {
                if command == "inspector" { showInspector.toggle() }
                if command == "open", let book = model.selectedBook {
                    model.bookWorkspaceSection = .annotations
                    model.bookWorkspaceID = book.asin
                }
            }
        }
    }

    /// The footer's count line. Built here rather than inline because the
    /// whole table body is already at the type checker's limit.
    private func bookCountLine(_ rows: [Book]) -> String {
        let read = rows.filter(\.isRead).count
        let annotated = rows.filter { $0.userAnnotationCount > 0 }.count
        var parts = [
            "\(rows.count.formatted()) "
                + (rows.count == 1 ? "book" : "books"),
        ]
        if read > 0 {
            parts.append("\(read.formatted()) read")
        }
        if annotated > 0 {
            parts.append("\(annotated.formatted()) annotated")
        }
        if model.sourceFilter != .all { parts.append(model.sourceFilter.title) }
        if scope != .all { parts.append(scope.title) }
        return parts.joined(separator: " · ")
    }

    /// The empty shelf, on its own: the type checker gives up on it when it
    /// sits inside the same expression as the list.
    private var emptyLibrary: some View {
        LibraryEmptyState(
            model: model, annotations: false,
            hasImportedRecords: !model.books.isEmpty
        ) {
            resetFilters()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bookList: some View {
        // One filtered, sorted snapshot per evaluation: the empty check, the
        // list and the footer all read the same rows.
        let rows = self.rows
        return Group {
            if rows.isEmpty {
                emptyLibrary
            } else {
                BookList(
                    model: model, rows: rows,
                    countLine: bookCountLine(rows),
                    showsSource: model.hasBothSources,
                    resetFilters: resetFilters)
            }
        }
        .background {
            InspectorPanel(isPresented: $showInspector, title: "Book Inspector")
            {
                BookDetailView(model: model)
            }
            .frame(width: 0, height: 0)
        }
        .onChange(of: rows.map(\.asin)) { _, _ in
            if let selected = model.selectedBookID,
                rows.contains(where: { $0.asin == selected })
            {
                return
            }
            model.selectedBookID = rows.first?.asin
        }
        .onChange(of: model.selectedBookID) { _, selected in
            guard let selected else { return }
            if rows.contains(where: { $0.asin == selected }) { return }
            model.selectedBookID = rows.first?.asin
        }
        .onChange(of: model.libraryReveal) { _, _ in applyReveal() }
        .onAppear { applyReveal() }
        .browserSearch(text: $model.search, prompt: "Search books and authors")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Source", selection: $model.sourceFilter) {
                        ForEach(AppModel.SourceFilter.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                } label: {
                    Label(
                        model.sourceFilter.title,
                        systemImage: "rectangle.stack")
                }
                .help("Filter by source")
            }
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $scope) {
                        ForEach(Scope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                } label: {
                    Label(
                        scope.title,
                        systemImage:
                            "line.3.horizontal.decrease.circle")
                }
                .help("Filter the book list")
            }
            ToolbarItem {
                // A list has no column headers to click, so the order says
                // what it is and the menu is where it changes.
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(BookSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Divider()
                    Picker("Direction", selection: $ascending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                } label: {
                    Label(sort.title, systemImage: "arrow.up.arrow.down")
                }
                .help("Sort the book list")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the book inspector")
            }
        }
    }
}

// MARK: - Detail

struct BookDetailView: View {
    /// The menu item names the page it will ask about when that page is not
    /// this book, and is unavailable when no reader page is open.
    private func askLabel(for book: Book) -> String {
        if model.readerPageMatches(book) {
            return "Ask About This Book's Page…"
        }
        if let live = model.livePage?.title, !live.isEmpty,
            ConversationKey.normalize(live)
                != ConversationKey.normalize(book.title)
        {
            return "Open \u{201C}\(book.title)\u{201D} in the Reader to Ask"
        }
        return "Open This Book in the Reader to Ask"
    }

    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let book = model.selectedBook {
                List {
                    Section {
                        BookHero(
                            book: book,
                            annotations: book.userAnnotationCount,
                            messages: model.conversationCount(for: book))
                    }

                    Section("Details") {
                        LabeledContent("Last Read") {
                            Text(TsundokuFormat.date(book.lastView))
                                .foregroundStyle(.secondary)
                        }
                        if let progress = book.progress {
                            // A bar says "how far in" at a glance; a
                            // percentage makes the reader do the arithmetic.
                            ProgressView(value: max(0, min(1, progress))) {
                                Text("Progress").font(.callout)
                            }
                            .progressViewStyle(.linear)
                        }
                        LabeledContent(
                            book.source == .appleBooks ? "Asset ID" : "ASIN"
                        ) {
                            Text(book.asin)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    Section("Actions") {
                        HStack(spacing: 8) {
                            Button("Read Annotations") {
                                model.bookWorkspaceSection = .annotations
                                model.bookWorkspaceID = book.asin
                            }
                            Button("Open Chats") {
                                model.openChats(for: book)
                            }
                            Spacer(minLength: 0)
                            Menu {
                                // The companion answers about the live page,
                                // which may be a different book; the item
                                // says which one it will ask about.
                                Button(askLabel(for: book)) {
                                    model.section = .library
                                    model.showAIPanel()
                                }
                                .disabled(!model.readerPageMatches(book))
                                if book.source == .kindle {
                                    let isTracking =
                                        model.trackedBookID == book.asin
                                    Button(
                                        isTracking
                                            ? "Stop Tracking" : "Track Reading"
                                    ) {
                                        if isTracking {
                                            model.toggleTracking()
                                        } else {
                                            model.startTracking(book)
                                        }
                                    }
                                }
                                Button("Capture as PDF…") {
                                    model.section = .exports
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Companion, tracking and capture for this book")
                        }
                        .controlSize(.small)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView(
                    "Choose a Book",
                    systemImage: "book.closed",
                    description: Text(
                        "Select a book to see its annotations and actions."))
            }
        }
    }

}

