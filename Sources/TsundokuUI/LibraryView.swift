import SwiftUI
import TsundokuCore

public struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var scope: Scope = .all
    @State private var sortOrder = [KeyPathComparator(\Book.title)]
    @State private var showInspector = true

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
            if rows.isEmpty {
                ContentUnavailableView(
                    model.search.isEmpty ? "No Books" : "No Matches",
                    systemImage: "book.closed",
                    description: Text(
                        model.search.isEmpty
                            ? "Import your Kindle or Apple Books library to begin."
                            : "No book matches “\(model.search)”.")
                )
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
                        "Marks", value: \.userAnnotationCount
                    ) { book in
                        Text("\(book.userAnnotationCount)")
                    }
                    .width(50)

                    TableColumn("Source", value: \.source.rawValue) {
                        book in
                        Text(book.source.displayName)
                    }
                    .width(85)

                    TableColumn("Last Read") { book in
                        Text(TsundokuFormat.date(book.lastView))
                    }
                    .width(85)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
            }
        }
        .inspector(isPresented: $showInspector) {
            BookDetailView(model: model)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
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
                ToolbarSearch(text: $model.search, prompt: "Search")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
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

    private var bookAnnotations: [Annotation] {
        model.selectedBookAnnotations.sorted { left, right in
            if left.isResolved != right.isResolved { return left.isResolved }
            return (left.createdAt ?? .distantPast)
                > (right.createdAt ?? .distantPast)
        }
    }

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
                            Text("\(book.annotationCount)")
                        }
                    }

                    Section("Actions") {
                        if book.source == .kindle {
                            Button {
                                model.showAIPanel()
                            } label: {
                                Label(
                                    "Ask About This Page",
                                    systemImage: "sparkles")
                            }
                            Button {
                                model.toggleTracking()
                            } label: {
                                Label(
                                    model.trackedBookID == book.asin
                                        ? "Stop Tracking" : "Track Reading",
                                    systemImage: model.trackedBookID
                                        == book.asin
                                        ? "stop.circle" : "record.circle")
                            }
                            Button {
                                model.section = .exports
                            } label: {
                                Label(
                                    "Capture as PDF",
                                    systemImage: "doc.richtext")
                            }
                        } else {
                            Text(
                                "Apple Books highlights and bookmarks are "
                                    + "imported. Live page actions are "
                                    + "Kindle-only in this phase."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    annotations
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

    @ViewBuilder
    private var annotations: some View {
        Section("Annotations") {
            if bookAnnotations.isEmpty {
                Text("No annotations were found for this book.")
                    .foregroundStyle(.secondary)
            } else {
                let resolved = bookAnnotations.filter(\.isResolved)
                let positions = bookAnnotations.count - resolved.count
                ForEach(resolved.prefix(10)) { annotation in
                    Text(annotation.displayText)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if positions > 0 {
                    Text(
                        "\(positions.formatted()) "
                            + (positions == 1 ? "entry is" : "entries are")
                            + " saved as a position only. The local store "
                            + "keeps the location, not the words."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if bookAnnotations.count > 10 {
                    Button("Show All in Annotations") {
                        model.section = .highlights
                    }
                }
            }
        }
    }
}
