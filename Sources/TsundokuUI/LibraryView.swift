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
                        IconButton(
                            "Books", systemImage: "chevron.left",
                            tooltip: "Back to books"
                        ) {
                            model.bookWorkspaceID = nil
                        }
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
                        IconButton(
                            "Open in Annotations",
                            systemImage: "arrow.up.right.square"
                        ) {
                            model.bookWorkspaceID = nil
                            model.showAnnotations(for: book)
                        }
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
                    model.bookWorkspaceID = book.asin
                }
            }
        }
    }

    private var bookList: some View {
        Group {
            if rows.isEmpty {
                LibraryEmptyState(
                    model: model, annotations: false,
                    hasImportedRecords: !model.books.isEmpty
                ) {
                    model.search = ""
                    model.sourceFilter = .all
                    scope = .all
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                Table(
                    rows, selection: $model.selectedBookID,
                    sortOrder: $sortOrder
                ) {
                    TableColumn("Title", value: \.title) { book in
                        Text(book.title)
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("Author", value: \.author) { book in
                        Text(book.author)
                    }
                    .width(min: 90, ideal: 140)

                    TableColumn(
                        "Annotations", value: \.userAnnotationCount
                    ) { book in
                        Text("\(book.userAnnotationCount)")
                    }
                    .width(min: 70, ideal: 85)

                    TableColumn("Source", value: \.source.rawValue) {
                        book in
                        Text(book.source.displayName)
                    }
                    .width(85)

                    TableColumn("Messages") { book in
                        let count = model.conversationCount(for: book)
                        Text(count == 0 ? "—" : "\(count)")
                            .foregroundStyle(
                                count == 0 ? .secondary : .primary)
                    }
                    .width(70)

                    TableColumn("Last Read", value: \.lastReadSort) { book in
                        Text(TsundokuFormat.date(book.lastView))
                    }
                    .width(85)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
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
                        Text(
                            "\(rows.count.formatted()) books"
                                + (model.sourceFilter == .all
                                    ? "" : " · \(model.sourceFilter.title)")
                                + (scope == .all ? "" : " · \(scope.title)")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        IconButton(
                            "Open Annotations", systemImage: "book.pages"
                        ) {
                            model.bookWorkspaceID = model.selectedBookID
                        }
                        .disabled(model.selectedBookID == nil)
                        IconButton(
                            "Reset Filters",
                            systemImage: "line.3.horizontal.decrease.circle"
                        ) {
                            model.search = ""
                            model.sourceFilter = .all
                            scope = .all
                        }
                    }.padding(10)
                }
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
                        HStack(spacing: 12) {
                            IconButton(
                                "Read Annotations", systemImage: "book.pages"
                            ) {
                                model.bookWorkspaceSection = .annotations
                                model.bookWorkspaceID = book.asin
                            }
                            IconButton(
                                "Open Chats",
                                systemImage: "bubble.left.and.bubble.right"
                            ) {
                                model.openChats(for: book)
                            }
                            IconButton(
                                "Ask About the Current Reader Page",
                                systemImage: "sparkles",
                                tooltip:
                                    "Ask about the current reader page, which may differ from this book"
                            ) {
                                model.showAIPanel()
                            }
                            if book.source == .kindle {
                                IconButton(
                                    model.trackedBookID == book.asin
                                        ? "Stop Tracking" : "Track Reading",
                                    systemImage: model.trackedBookID
                                        == book.asin
                                        ? "stop.circle" : "record.circle"
                                ) {
                                    model.toggleTracking()
                                }
                            }
                            IconButton(
                                "Capture as PDF…", systemImage: "doc.richtext"
                            ) { model.section = .exports }
                            Spacer(minLength: 0)
                        }
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
