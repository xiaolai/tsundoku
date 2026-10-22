import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TsundokuCore

public struct HighlightsView: View {
    @ObservedObject var model: AppModel
    @State private var onlyWithText = true
    @State private var kindScope: KindScope = .all
    @State private var selectedID: String?
    @State private var showInspector = true
    @State private var sortOrder = [
        KeyPathComparator(\AnnotationTableRow.date, order: .reverse)
    ]

    public init(model: AppModel) {
        self.model = model
    }

    enum KindScope: String, CaseIterable, Identifiable {
        case all
        case notes
        case highlights
        case bookmarks

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All Kinds"
            case .notes: "Notes"
            case .highlights: "Highlights"
            case .bookmarks: "Bookmarks"
            }
        }

        func matches(_ annotation: Annotation) -> Bool {
            switch self {
            case .all: true
            case .notes:
                annotation.kind == .note
                    || !(annotation.note ?? "").isEmpty
            case .highlights:
                annotation.kind == .highlight
                    || annotation.kind == .popularHighlight
            case .bookmarks: annotation.kind == .bookmark
            }
        }
    }

    private var scopeBase: [Annotation] {
        let query = model.annotationSearch.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return model.annotations.filter { annotation in
            if let provenance = model.annotationFilter.provenance,
                annotation.provenance != provenance
            {
                return false
            }
            if let source = model.sourceFilter.source,
                annotation.bookSource != source
            {
                return false
            }
            guard !query.isEmpty else { return true }
            return annotation.bookTitle.lowercased().contains(query)
                || annotation.displayText.lowercased().contains(query)
                || (annotation.note ?? "").lowercased().contains(query)
        }
    }

    private var matching: [Annotation] {
        scopeBase.filter { annotation in
            kindScope.matches(annotation)
                && (!onlyWithText || annotation.isResolved)
        }
    }

    private var rows: [AnnotationTableRow] {
        var result = matching.map { annotation in
            AnnotationTableRow(
                annotation: annotation,
                bookTitle:
                    annotation.bookTitle.isEmpty
                    ? (model.bookTitles[annotation.asin] ?? annotation.asin)
                    : annotation.bookTitle)
        }
        result.sort(using: sortOrder)
        return result
    }

    private var selectedAnnotation: Annotation? {
        rows.first { $0.id == selectedID }?.annotation
    }

    public var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                Table(
                    rows, selection: $selectedID, sortOrder: $sortOrder
                ) {
                    TableColumn("Kind", value: \.kind) { row in
                        Text(row.kind)
                    }
                    .width(90)

                    TableColumn("Book", value: \.bookTitle) { row in
                        Text(row.bookTitle)
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Date", value: \.date) { row in
                        Text(TsundokuFormat.date(row.date))
                    }
                    .width(100)

                    TableColumn("Position", value: \.position) { row in
                        Text(row.position)
                    }
                    .width(90)

                    TableColumn("Text") { row in
                        Text(row.text)
                            .lineLimit(1)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
            }
        }
        .inspector(isPresented: $showInspector) {
            AnnotationInspector(annotation: selectedAnnotation)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
        }
        .onAppear {
            if selectedID == nil {
                selectedID = rows.first?.id
            }
        }
        .onChange(of: rows.map(\.id)) { _, _ in
            if let selectedID,
                rows.contains(where: { $0.id == selectedID })
            {
                return
            }
            selectedID = rows.first?.id
        }
        .toolbar {
            ToolbarItem {
                filterMenu
            }
            ToolbarItem {
                exportMenu
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearch(
                    text: $model.annotationSearch, prompt: "Search")
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
                .help("Show or hide the annotation inspector")
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Source", selection: $model.sourceFilter) {
                ForEach(AppModel.SourceFilter.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            Picker("Show", selection: $model.annotationFilter) {
                Text("Mine").tag(AppModel.AnnotationFilter.mine)
                Text("Popular").tag(AppModel.AnnotationFilter.popular)
                Text("All").tag(AppModel.AnnotationFilter.all)
            }
            Picker("Kind", selection: $kindScope) {
                ForEach(KindScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            Divider()
            Toggle("Text Only", isOn: $onlyWithText)
        } label: {
            Label(
                "Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter annotations")
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.annotations.isEmpty {
            ContentUnavailableView(
                "No Annotations",
                systemImage: "highlighter",
                description: Text(
                    "Tsundoku reads annotations from Kindle and Apple Books "
                        + "local stores. Highlight something in a book, then "
                        + "import again."))
        } else if onlyWithText, kindScope == .all,
            model.annotationFilter == .mine
        {
            ContentUnavailableView {
                Label(
                    "No Notes with Text", systemImage: "text.magnifyingglass")
            } description: {
                Text(
                    model.sourceFilter == .appleBooks
                        ? "No Apple Books annotations with text match these "
                            + "filters."
                        : "Kindle does not keep the words of a highlight on "
                            + "this Mac, only its position. Notes and popular "
                            + "highlights can carry text.")
            } actions: {
                Button("Show Position Records") {
                    onlyWithText = false
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Matches", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("Try a different book, kind or search.")
            } actions: {
                Button("Clear Filters") {
                    model.annotationSearch = ""
                    model.annotationFilter = .mine
                    kindScope = .all
                    onlyWithText = true
                }
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(AnnotationExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) {
                    export(format)
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    private func export(_ format: AnnotationExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "tsundoku-annotations.\(format.fileExtension)"
        panel.allowedContentTypes = [
            UTType(filenameExtension: format.fileExtension) ?? .plainText
        ]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.archive?.exportAnnotations(
                to: url, format: format,
                provenance: model.annotationFilter.provenance,
                source: model.sourceFilter.source)
            model.post(
                "Exported \(format.displayName) to \(url.lastPathComponent)")
        } catch {
            model.post("Export failed: \(error)", seconds: 10)
        }
    }
}

// MARK: - Table row

struct AnnotationTableRow: Identifiable {
    let annotation: Annotation
    let bookTitle: String

    var id: String { annotation.id }
    var kind: String { annotation.kind.displayName }
    var date: Date { annotation.createdAt ?? .distantPast }
    var position: String { positionLabel(annotation.start) ?? "" }
    var text: String {
        annotation.isResolved ? annotation.displayText : "Position only"
    }
}

// MARK: - Inspector

struct AnnotationInspector: View {
    let annotation: Annotation?

    var body: some View {
        if let annotation {
            Form {
                Section("Annotation") {
                    Text(
                        annotation.isResolved
                            ? annotation.displayText
                            : "Saved as a position; Kindle does not store "
                                + "the words."
                    )
                    .textSelection(.enabled)
                    if let note = annotation.note, !note.isEmpty {
                        Text(note)
                            .textSelection(.enabled)
                    }
                }
                Section("Details") {
                    LabeledContent("Kind") {
                        Text(annotation.kind.displayName)
                    }
                    LabeledContent("Book") {
                        Text(
                            annotation.bookTitle.isEmpty
                                ? annotation.asin : annotation.bookTitle)
                    }
                    LabeledContent("Source") {
                        Text(annotation.bookSource.displayName)
                    }
                    LabeledContent("Date") {
                        Text(TsundokuFormat.date(annotation.createdAt))
                    }
                    LabeledContent("Position") {
                        Text(positionLabel(annotation.start) ?? "—")
                    }
                    LabeledContent("Records") {
                        Text(
                            annotation.sources.isEmpty
                                ? "—"
                                : annotation.sources.joined(
                                    separator: ", "))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "text.cursor",
                description: Text(
                    "Select an annotation to see its full text and details."))
        }
    }
}

/// Positions arrive as long integers or as a dictionary with
/// `longPosition` / `shortPosition`; show the long one, compactly.
func positionLabel(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("{") || trimmed.contains("longPosition") {
        return nil
    }
    return trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
}
