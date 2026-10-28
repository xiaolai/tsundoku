import SwiftUI
import TsundokuCore

public struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var scope: Scope = .all
    @State private var sortOrder = [KeyPathComparator(\Book.title)]
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

    private func resetFilters() {
        model.search = ""
        model.sourceFilter = .all
        scope = .all
    }

    private var rows: [Book] {
        var result = model.filteredBooks.filter { book in
            switch scope {
            case .all: true
            case .read: book.isRead
            case .unread: !book.isRead
            case .annotated: book.userAnnotationCount > 0
            }
        }
        result.sort(using: sortOrder)
        return result
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
    private func bookCountLine(_ count: Int) -> String {
        var parts = ["\(count.formatted()) books"]
        if model.sourceFilter != .all { parts.append(model.sourceFilter.title) }
        if scope != .all { parts.append(scope.title) }
        return parts.joined(separator: " · ")
    }

    private var bookList: some View {
        // One filtered, sorted snapshot per evaluation: the empty check, the
        // table and the footer all read the same rows.
        let rows = self.rows
        return Group {
            if rows.isEmpty {
                LibraryEmptyState(
                    model: model, annotations: false,
                    hasImportedRecords: !model.books.isEmpty
                ) {
                    resetFilters()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                BookTable(
                    model: model, rows: rows, sortOrder: $sortOrder,
                    countLine: bookCountLine(rows.count),
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title)
                                .font(.title2)
                                .textSelection(.enabled)
                            Text(
                                book.author.isEmpty
                                    ? "Unknown author" : book.author
                            )
                            .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                if book.isRead {
                                    Label(
                                        "Read",
                                        systemImage: "checkmark.circle")
                                }
                                if book.downloaded {
                                    Label(
                                        "Downloaded",
                                        systemImage: "arrow.down.circle")
                                }
                                if book.isFixedLayout {
                                    Label(
                                        "Fixed layout",
                                        systemImage: "rectangle")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    Section("Details") {
                        LabeledContent(
                            book.source == .appleBooks ? "Asset ID" : "ASIN"
                        ) {
                            Text(book.asin)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Source") {
                            Text(book.source.displayName)
                        }
                        LabeledContent("Last Read") {
                            Text(TsundokuFormat.date(book.lastView))
                        }
                        if let progress = book.progress {
                            LabeledContent("Progress") {
                                Text(
                                    progress.formatted(
                                        .percent.precision(
                                            .fractionLength(0))))
                            }
                        }
                        LabeledContent("Annotations") {
                            Text("\(book.userAnnotationCount)")
                        }
                        LabeledContent("Messages") {
                            Text(
                                "\(model.conversationCount(for: book))")
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

extension Book {
    fileprivate var lastReadSort: Date { lastView ?? .distantPast }
}

/// The books table on its own. The containing view's body is already at the
/// type checker's limit, and a table with six columns plus a footer is where
/// it gives up.
private struct BookTable: View {
    @ObservedObject var model: AppModel
    let rows: [Book]
    @Binding var sortOrder: [KeyPathComparator<Book>]
    let countLine: String
    let resetFilters: () -> Void

    var body: some View {
        Table(
            rows, selection: $model.selectedBookID,
            sortOrder: $sortOrder
        ) {
            TableColumn("Title", value: \.title) { book in
                HStack(spacing: 6) {
                    // Read state was filterable but invisible; the title
                    // carries it, so a filter result explains itself.
                    Image(
                        systemName: book.isRead
                            ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        book.isRead ? AnyShapeStyle(.tint)
                            : AnyShapeStyle(.tertiary))
                    .accessibilityLabel(book.isRead ? "Read" : "Unread")
                    Text(book.title)
                }
            }
            .width(min: 160, ideal: 250)

            TableColumn("Author", value: \.author) { book in
                Text(book.author.isEmpty ? "Unknown author" : book.author)
                    .foregroundStyle(
                        book.author.isEmpty ? .secondary : .primary)
            }
            .width(min: 80, ideal: 140)

            TableColumn(
                "Annotations", value: \.userAnnotationCount
            ) { book in
                Text("\(book.userAnnotationCount)")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 66, ideal: 84)

            TableColumn("Source", value: \.source.rawValue) { book in
                Text(book.source.displayName)
            }
            .width(80)

            TableColumn("Messages") { book in
                let count = model.conversationCount(for: book)
                Text(count == 0 ? "—" : "\(count)")
                    .monospacedDigit()
                    .foregroundStyle(count == 0 ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(66)

            TableColumn("Last Read", value: \.lastReadSort) { book in
                Text(TsundokuFormat.date(book.lastView))
                    .monospacedDigit()
            }
            .width(82)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
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
            }.padding(10)
        }
    }
}
