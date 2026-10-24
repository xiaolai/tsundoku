import AppKit
import SwiftUI
import TsundokuCore
import UniformTypeIdentifiers

public struct HighlightsView: View {
    @ObservedObject var model: AppModel
    let book: Book?
    @AppStorage("browser.presentation") private var presentation = "cards"
    @AppStorage("browser.inspector") private var showInspector = false
    @AppStorage("browser.excerptLines") private var excerptLines = 6
    @AppStorage("browser.readingSize") private var readingSize = 14
    @AppStorage("browser.randomBorders") private var randomBorders = false
    @AppStorage("browser.borderSeed") private var borderSeed = 0
    @State private var kind: AnnotationKindScope = .all
    @State private var contentOnly = false
    @State private var sort: AnnotationSort = .newest
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var focusedID: String?
    @State private var showAINotes = false
    @State private var gridMetrics = AnnotationGridMetrics()
    @State private var tableSort: [KeyPathComparator<AnnotationTableRow>] = []

    public init(model: AppModel, book: Book? = nil) {
        self.model = model
        self.book = book
    }

    private var eventModifiers: NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    }

    private var bookID: String? { book?.asin ?? model.annotationBookID }
    private var query: AnnotationQuery {
        var query = AnnotationQuery()
        query.source = book?.source ?? model.annotationSourceFilter.source
        query.provenance = model.annotationFilter.provenance
        query.bookID = bookID
        query.kind = kind
        query.contentOnly = contentOnly
        query.search = model.annotationSearch
        query.sort = sort
        return query
    }

    private var rows: [AnnotationTableRow] {
        let catalog = Dictionary(
            model.books.map { ($0.asin, $0) },
            uniquingKeysWith: { first, _ in first })
        var rows = query.apply(to: model.annotations, books: model.books).map {
            annotation in
            AnnotationTableRow(
                annotation: annotation,
                bookTitle: annotation.bookTitle.isEmpty
                    ? catalog[annotation.asin]?.title ?? annotation.asin
                    : annotation.bookTitle,
                author: catalog[annotation.asin]?.author ?? "")
        }
        if !tableSort.isEmpty { rows.sort(using: tableSort) }
        return rows
    }

    public var body: some View {
        let snapshot = rows
        let ids = snapshot.map(\.id)
        let current = snapshot.first { selection.contains($0.id) }
        VStack(spacing: 0) {
            if !model.annotations.isEmpty {
                scopeBar(count: snapshot.count)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if presentation == "list" {
                annotationTable(snapshot)
            } else {
                cardGrid(snapshot)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background {
            InspectorPanel(
                isPresented: $showInspector, title: "Annotation Inspector"
            ) {
                if selection.count > 1 {
                    ContentUnavailableView(
                        "\(selection.count) Selected",
                        systemImage: "checkmark.circle",
                        description: Text(
                            "Copy or export the selection."
                        ))
                } else {
                    AnnotationInspector(
                        row: current,
                        readingSize: CGFloat(max(13, min(28, readingSize))))
                }
            }
            .frame(width: 0, height: 0)
        }
        .onChange(of: ids) { _, newIDs in
            selection.formIntersection(newIDs)
            if let anchor, !newIDs.contains(anchor) { self.anchor = nil }
            if let focusedID, !newIDs.contains(focusedID) {
                self.focusedID = nil
            }
        }
        .onChange(of: selection) { _, selected in
            if presentation == "list" {
                focusedID = snapshot.first { selected.contains($0.id) }?.id
                anchor = focusedID
            }
        }
        .toolbar { browserToolbar(snapshot) }
        .browserSearch(
            text: $model.annotationSearch, prompt: "Search passages and notes"
        )
        .sheet(isPresented: $showAINotes) {
            SavedAINotesView(model: model, bookID: bookID)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .tsundokuBrowserCommand)
        ) { notification in
            guard browserWindowIsKey,
                let command = notification.userInfo?["command"] as? String
            else {
                return
            }
            switch command {
            case "cards", "list": presentation = command
            case "inspector": showInspector.toggle()
            case "selectAll": selection = Set(ids)
            case "copy":
                copy(
                    snapshot.filter { selection.contains($0.id) }.map(
                        \.annotation), citation: false)
            case "export": export(snapshot.map(\.annotation), format: .markdown)
            case "aiNotes": showAINotes = true
            default: break
            }
        }
    }

    private func scopeBar(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if book == nil, let bookID {
                HStack {
                    Label(
                        book?.title ?? model.bookTitles[bookID] ?? bookID,
                        systemImage: "book.closed"
                    )
                    .font(.headline).lineLimit(2)
                    Spacer()
                    if book == nil {
                        IconButton(
                            "All Books", systemImage: "xmark.circle",
                            tooltip: "Clear book filter"
                        ) { model.annotationBookID = nil }
                    }
                }
            }
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 135, maximum: 210),
                        alignment: .leading)
                ], alignment: .leading, spacing: 8
            ) {
                if book == nil {
                    Picker("Source", selection: $model.annotationSourceFilter) {
                        ForEach(AppModel.SourceFilter.allCases) {
                            Text($0.title).tag($0)
                        }
                    }.labelsHidden()
                }
                Picker("Kind", selection: $kind) {
                    ForEach(AnnotationKindScope.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }.labelsHidden()
                Picker("Show", selection: $model.annotationFilter) {
                    ForEach(AppModel.AnnotationFilter.allCases) {
                        Text($0.title).tag($0)
                    }
                }.labelsHidden()
                Menu {
                    Toggle("Random Border Colors", isOn: $randomBorders)
                    if randomBorders {
                        Button("Shuffle Border Colors") {
                            borderSeed = Int.random(in: 1...Int.max)
                        }
                    }
                    Toggle("With Passage or Note Text", isOn: $contentOnly)
                    Picker("Reading Text Size", selection: $readingSize) {
                        Text("Standard").tag(14)
                        Text("Larger").tag(18)
                        Text("Extra Large").tag(22)
                        Text("Double Size").tag(28)
                    }
                    Picker("Preview Lines", selection: $excerptLines) {
                        Text("Short").tag(3)
                        Text("Comfortable").tag(6)
                        Text("Long").tag(10)
                    }
                    Button("Reset Filters", action: resetFilters)
                } label: {
                    Label("Options", systemImage: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .labelStyle(.iconOnly)
                .help("View options")
                .accessibilityLabel("Options")
            }
            HStack {
                Text(
                    "\(count.formatted()) results\(selection.isEmpty ? "" : " · \(selection.count) selected")"
                )
                if contentOnly { Text("With text") }
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(AnnotationSort.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }.labelsHidden().fixedSize()
                    .onChange(of: sort) { _, _ in tableSort = [] }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func cardGrid(_ rows: [AnnotationTableRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 280, maximum: 440), spacing: 14)
                    ], spacing: 14
                ) {
                    ForEach(rows) { row in
                        AnnotationCard(
                            row: row, selected: selection.contains(row.id),
                            randomBorders: randomBorders,
                            borderSeed: borderSeed,
                            showBookMetadata: bookID == nil,
                            readingSize: CGFloat(max(13, min(28, readingSize))),
                            excerptLines: max(3, min(10, excerptLines)),
                            select: { select(row.id, rows: rows) },
                            inspect: {
                                select(row.id, rows: rows, plain: true)
                                showInspector = true
                            }
                        )
                        .id(row.id)
                        .contextMenu { itemActions(row, snapshot: rows) }
                    }
                }
                .padding(16)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    gridMetrics.width = $0
                }
            }
            .focusable()
            .onMoveCommand { direction in
                guard !rows.isEmpty else { return }
                let columns = max(1, Int((gridMetrics.width - 32 + 14) / 294))
                let delta: Int
                switch direction {
                case .left: delta = -1
                case .right: delta = 1
                case .up: delta = -columns
                case .down: delta = columns
                @unknown default: return
                }
                var state = AnnotationSelection()
                state.ids = selection
                state.anchor = anchor
                state.focusedID = focusedID
                state.move(
                    by: delta, in: rows.map(\.id),
                    extending: eventModifiers.contains(.shift))
                selection = state.ids
                anchor = state.anchor
                focusedID = state.focusedID
                if let focusedID { proxy.scrollTo(focusedID) }
            }
            .onKeyPress(.space) {
                showInspector = true
                return .handled
            }
        }
    }

    private func annotationTable(_ rows: [AnnotationTableRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $tableSort) {
            TableColumn("Passage / Note") { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.preview).lineLimit(2)
                    if row.annotation.passageText != nil,
                        let note = row.annotation.personalNote
                    {
                        Text("Note: \(note)").font(.caption).foregroundStyle(
                            .secondary
                        ).lineLimit(1)
                    }
                }.padding(.vertical, 3)
                    .contextMenu { itemActions(row, snapshot: rows) }
            }.width(min: 200, ideal: 360)
            TableColumn("Book", value: \.bookTitle).width(min: 110, ideal: 180)
            TableColumn("Kind", value: \.kind).width(min: 65, ideal: 95)
            TableColumn("Source", value: \.source).width(min: 75, ideal: 90)
            TableColumn("Date", value: \.dateSort) { row in
                Text(TsundokuFormat.annotationDate(row.annotation.createdAt))
            }.width(min: 90, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { selected in
            Button("Copy") {
                copy(
                    rows.filter { selected.contains($0.id) }.map(\.annotation),
                    citation: false)
            }
            Button("Copy with Citation") {
                copy(
                    rows.filter { selected.contains($0.id) }.map(\.annotation),
                    citation: true)
            }
            Button("Show Details") { showInspector = true }.disabled(
                selected.count != 1)
        } primaryAction: { selected in
            selection = selected
            showInspector = true
        }
    }

    @ToolbarContentBuilder
    private func browserToolbar(_ rows: [AnnotationTableRow])
        -> some ToolbarContent
    {
        ToolbarItem {
            Picker("View", selection: $presentation) {
                Label("Cards", systemImage: "square.grid.2x2").tag("cards")
                Label("List", systemImage: "list.bullet").tag("list")
            }.pickerStyle(.segmented).help("Choose Cards or List")
        }
        ToolbarItem {
            Menu {
                Button("Copy Selected") {
                    copy(
                        rows.filter { selection.contains($0.id) }.map(
                            \.annotation), citation: false)
                }
                .disabled(selection.isEmpty)
                Button("Copy Selected with Citation") {
                    copy(
                        rows.filter { selection.contains($0.id) }.map(
                            \.annotation), citation: true)
                }
                .disabled(selection.isEmpty)
                Divider()
                exportSubmenu(
                    "Export Selected (\(selection.count))",
                    items: rows.filter { selection.contains($0.id) }.map(
                        \.annotation))
                exportSubmenu(
                    "Export Results (\(rows.count))",
                    items: rows.map(\.annotation))
                exportSubmenu(
                    "Export All Imported Annotations (\(model.annotations.count))",
                    items: model.annotations)
            } label: {
                Label("Copy or Export", systemImage: "square.and.arrow.up")
            }.help("Copy or export annotations").labelStyle(.iconOnly)
        }
        ToolbarItem {
            Button {
                showAINotes = true
            } label: {
                Label("Saved AI Notes", systemImage: "sparkles.rectangle.stack")
            }.help("Saved AI notes").labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide annotation details")
        }
    }

    private var emptyState: some View {
        LibraryEmptyState(
            model: model, annotations: true,
            hasImportedRecords: !model.annotations.isEmpty,
            resetFilters: resetFilters)
    }

    private func resetFilters() {
        model.annotationSearch = ""
        model.annotationFilter = .mine
        model.annotationSourceFilter = .all
        if book == nil { model.annotationBookID = nil }
        kind = .all
        contentOnly = false
    }

    private func select(
        _ id: String, rows: [AnnotationTableRow], plain: Bool = false
    ) {
        var state = AnnotationSelection()
        state.ids = selection
        state.anchor = anchor
        state.focusedID = focusedID
        state.select(
            id, in: rows.map(\.id),
            extending: !plain && eventModifiers.contains(.shift),
            toggling: !plain && eventModifiers.contains(.command))
        selection = state.ids
        anchor = state.anchor
        focusedID = state.focusedID
    }

    @ViewBuilder private func itemActions(
        _ row: AnnotationTableRow, snapshot: [AnnotationTableRow]
    )
        -> some View
    {
        Button("Show Details") {
            selection = [row.id]
            anchor = row.id
            focusedID = row.id
            showInspector = true
        }
        Button("Copy") { copy([row.annotation], citation: false) }
        Button("Copy with Citation") { copy([row.annotation], citation: true) }
        Menu("Export Annotation") {
            ForEach(AnnotationExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) {
                    export([row.annotation], format: format)
                }
            }
        }
    }

    private func exportSubmenu(_ title: String, items: [Annotation])
        -> some View
    {
        Menu(title) {
            ForEach(AnnotationExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) { export(items, format: format) }
            }
        }.disabled(items.isEmpty)
    }

    private func export(_ items: [Annotation], format: AnnotationExportFormat) {
        guard !items.isEmpty, let archive = model.archive else {
            model.post("No annotations are available to export.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "tsundoku-annotations.\(format.fileExtension)"
        panel.allowedContentTypes = [
            UTType(filenameExtension: format.fileExtension) ?? .plainText
        ]
        panel.canCreateDirectories = true
        // `items` is already an immutable snapshot of the visible order.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try archive.exportAnnotations(items, to: url, format: format)
            model.post(
                "Exported \(items.count) annotations to \(url.lastPathComponent)"
            )
        } catch { model.post("Export failed: \(error)", seconds: 12) }
    }

    private func copy(_ items: [Annotation], citation: Bool) {
        guard !items.isEmpty else { return }
        let text = items.map { annotation in
            var parts = [
                annotation.passageText,
                annotation.personalNote.map { "Note: \($0)" },
            ].compactMap { $0 }
            if parts.isEmpty { parts = ["Text unavailable in the local store"] }
            if citation {
                parts.append(
                    "— \(model.bookTitles[annotation.asin] ?? annotation.bookTitle), \(annotation.bookSource.displayName)\(positionLabel(annotation.start).map { ", \($0)" } ?? "")"
                )
            }
            return parts.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Geometry used by keyboard navigation must not publish split-view layout invalidations.
private final class AnnotationGridMetrics {
    var width: CGFloat = 700
}

struct AnnotationTableRow: Identifiable {
    let annotation: Annotation
    let bookTitle: String
    let author: String
    var id: String { annotation.id }
    var kind: String {
        annotation.passageText != nil && annotation.personalNote != nil
            ? "\(annotation.kind.displayName) + Note"
            : annotation.kind.displayName
    }
    var source: String { annotation.bookSource.displayName }
    var dateSort: Date { annotation.createdAt ?? .distantPast }
    var preview: String {
        annotation.passageText ?? annotation.personalNote
            ?? (annotation.kind == .bookmark
                ? "Saved bookmark" : "Passage text unavailable")
    }
}

struct AnnotationCard: View {
    let row: AnnotationTableRow
    let selected: Bool
    let randomBorders: Bool
    let borderSeed: Int
    let showBookMetadata: Bool
    @Environment(\.colorScheme) private var colorScheme
    let readingSize: CGFloat
    let excerptLines: Int
    let select: () -> Void
    let inspect: () -> Void

    private var borderColor: Color {
        guard randomBorders else { return Color(nsColor: .separatorColor) }
        let palette: [Color] = [
            .blue, .teal, .mint, .indigo, .purple, .pink, .orange,
        ]
        // A seeded assignment looks random but never flickers during view updates.
        let hash = row.id.utf8.reduce(
            UInt64(truncatingIfNeeded: borderSeed) ^ 14_695_981_039_346_656_037
        ) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))].opacity(
            colorScheme == .dark ? 0.85 : 0.65)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: row.annotation.kind.symbolName)
                        .help(row.kind)
                    Spacer(minLength: 4)
                    Image(
                        systemName: row.annotation.bookSource == .appleBooks
                            ? "apple.logo" : "book.closed"
                    )
                    .foregroundStyle(.secondary)
                    .help(row.source)
                    .accessibilityLabel(row.source)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }.font(.caption).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(
                    "\(selected ? "Selected, " : "")\(row.kind), \(row.bookTitle), \(row.source)"
                )
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help("\(row.kind) · \(row.source)")
            if let passage = row.annotation.passageText {
                Text(passage).font(.system(size: readingSize)).lineSpacing(3)
                    .lineLimit(excerptLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let note = row.annotation.personalNote {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note).font(.system(size: readingSize)).lineLimit(
                        excerptLines
                    ).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .help("Your note")
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Your note")
            }
            if !row.annotation.hasContent {
                Text(
                    row.annotation.kind == .bookmark
                        ? "Bookmark"
                        : "Passage text unavailable"
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                if showBookMetadata {
                    Text(row.bookTitle).font(.callout.weight(.medium))
                        .lineLimit(2)
                    if !row.author.isEmpty {
                        Text(row.author).font(.caption).foregroundStyle(
                            .secondary
                        ).lineLimit(1)
                    }
                }
                HStack {
                    if let position = positionLabel(row.annotation.start) {
                        Text(position).lineLimit(1).help(
                            "Location: \(position)")
                    }
                    Spacer()
                    if let date = row.annotation.createdAt {
                        Text(TsundokuFormat.annotationDate(date))
                    } else {
                        Image(systemName: "questionmark.circle")
                            .help("Date unavailable").accessibilityLabel(
                                "Date unavailable")
                    }
                    IconButton(
                        "Show Details", systemImage: "arrow.up.right.square",
                        action: inspect)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
        )
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.22 : 0.07),
            radius: 5, x: 0, y: 2
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(
                selected ? Color.accentColor : borderColor,
                lineWidth: selected ? 2 : (randomBorders ? 1 : 0.5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: select)
    }
}

struct AnnotationInspector: View {
    let row: AnnotationTableRow?
    let readingSize: CGFloat
    var body: some View {
        if let row {
            Form {
                if let passage = row.annotation.passageText {
                    Section("Passage") {
                        Text(passage).font(.system(size: readingSize))
                            .textSelection(.enabled)
                    }
                }
                if let note = row.annotation.personalNote {
                    Section("Your Note") {
                        Text(note).font(.system(size: readingSize))
                            .textSelection(.enabled)
                    }
                }
                if !row.annotation.hasContent {
                    Section("Saved Location") {
                        Text(
                            "Only a location is available."
                        ).foregroundStyle(
                            .secondary)
                    }
                }
                Section("Details") {
                    LabeledContent("Kind", value: row.kind)
                    LabeledContent("Book", value: row.bookTitle)
                    LabeledContent("Source", value: row.source)
                    LabeledContent(
                        "Created",
                        value: TsundokuFormat.annotationDate(
                            row.annotation.createdAt))
                    if let modified = row.annotation.modifiedAt {
                        LabeledContent(
                            "Modified",
                            value: TsundokuFormat.annotationDate(modified))
                    }
                    LabeledContent(
                        "Location",
                        value: positionLabel(row.annotation.start)
                            ?? "Unavailable")
                }
                DisclosureGroup("Import Records") {
                    Text(row.annotation.sources.joined(separator: ", "))
                        .textSelection(.enabled)
                    if let raw = row.annotation.start {
                        Text(raw).textSelection(.enabled)
                    }
                }
            }.formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "Choose an Annotation", systemImage: "text.cursor",
                description: Text(
                    "Select an annotation to read it here."
                ))
        }
    }
}

func positionLabel(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let data = trimmed.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    {
        return object["longPosition"].map { String(describing: $0) }
            ?? object["shortPosition"].map { String(describing: $0) }
    }
    return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
}
