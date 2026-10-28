import AppKit
import SwiftUI
import TsundokuCore

/// Every answer the reader saved, with the card it became. A note can be
/// deleted here; a card is the same row, so its card goes with it.
struct SavedAINotesView: View {
    @ObservedObject var model: AppModel
    let bookID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var order: Order = .newest
    @State private var pendingDeletion: SavedAINote?

    enum Order: String, CaseIterable, Identifiable {
        case newest, oldest, book
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newest: "Newest"
            case .oldest: "Oldest"
            case .book: "Book"
            }
        }
    }

    private var matching: [SavedAINote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.savedAINotes.filter {
            (bookID == nil
                || $0.asin?.caseInsensitiveCompare(bookID ?? "")
                    == .orderedSame)
                && (query.isEmpty
                    || [$0.bookTitle, $0.prompt, $0.answer, $0.provider]
                        .contains {
                            $0.localizedStandardContains(query)
                        })
        }
    }

    private struct NoteGroup: Identifiable {
        let id: String
        let title: String
        let notes: [SavedAINote]
    }

    /// The notes in display order, grouped the way the reader asked to see
    /// them. Days are not a group here: a saved answer is filed by the book
    /// it came from.
    private var groups: [NoteGroup] {
        let notes = matching
        switch order {
        case .newest:
            return [
                NoteGroup(
                    id: "all", title: "",
                    notes: notes.sorted { $0.createdAt > $1.createdAt })
            ]
        case .oldest:
            return [
                NoteGroup(
                    id: "all", title: "",
                    notes: notes.sorted { $0.createdAt < $1.createdAt })
            ]
        case .book:
            return Dictionary(
                grouping: notes,
                by: { $0.bookTitle.isEmpty ? "Book unidentified" : $0.bookTitle }
            )
            .map {
                NoteGroup(
                    id: $0.key, title: $0.key,
                    notes: $0.value.sorted { $0.createdAt > $1.createdAt })
            }
            .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Saved AI Notes", systemImage: "sparkles").font(.title2)
                Spacer()
                Text("\(matching.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Saved answers shown")
                Picker("Order", selection: $order) {
                    ForEach(Order.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                IconButton(
                    "Done", systemImage: "xmark",
                    tooltip: "Close saved AI notes"
                ) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            TextField("Search saved answers and questions", text: $search)
                .textFieldStyle(.roundedBorder).padding(.horizontal)
            content
        }
        .frame(minWidth: 520, idealWidth: 680, minHeight: 420, idealHeight: 600)
        .onAppear { model.refreshAINotes() }
        .alert(
            "Delete Saved Note?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let note = pendingDeletion { model.deleteSavedAINote(note) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deletionSentence(for: pendingDeletion))
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingAINotes, model.savedAINotes.isEmpty {
            ProgressView("Reading saved notes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.savedAINotes.isEmpty {
            ContentUnavailableView(
                "No Saved AI Notes", systemImage: "sparkles",
                description: Text("Save an answer in the reading companion."))
        } else if matching.isEmpty {
            // A search that matches nothing is not an empty archive; a
            // different sentence and a way back are the whole point.
            ContentUnavailableView {
                Label("No Notes Match", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing matches “\(search)”.")
            } actions: {
                Button("Clear Search") { search = "" }
            }
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.notes) { note in
                            row(note)
                        }
                    } header: {
                        if !group.title.isEmpty {
                            Text(
                                "\(group.title) · \(group.notes.count)"
                            ).font(.headline)
                        }
                    }
                }
            }
        }
    }

    private func row(_ note: SavedAINote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    note.bookTitle.isEmpty
                        ? "Book unidentified" : note.bookTitle
                ).font(.headline)
                Spacer()
                if note.turnID != nil, book(for: note) != nil {
                    Button("Open Chat") { openChat(for: note) }
                        .buttonStyle(.link)
                }
                Button {
                    pendingDeletion = note
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(
                    note.isCard
                        ? "Delete this note and its card"
                        : "Delete this note")
            }
            HStack(spacing: 6) {
                if note.isCard {
                    Label("Card", systemImage: "rectangle.stack")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                Text(
                    "AI-generated · \(note.provider) · \(note.bookSource?.displayName ?? "Source unavailable") · \(TsundokuFormat.annotationDate(note.createdAt))"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Prompt") {
                Text(note.prompt).textSelection(.enabled)
            }
            MarkdownText(text: note.answer)
                .textSelection(.enabled)
            IconButton("Copy Answer", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    note.answer, forType: .string)
            }.controlSize(.small)
        }.padding(.vertical, 10)
    }

    private func deletionSentence(for note: SavedAINote?) -> String {
        guard let note else { return "" }
        let subject =
            note.bookTitle.isEmpty
            ? "This note" : "The note from \(note.bookTitle)"
        return note.isCard
            ? "\(subject) and the card made from it will be deleted. This cannot be undone."
            : "\(subject) will be deleted. This cannot be undone."
    }

    private func book(for note: SavedAINote) -> Book? {
        guard let asin = note.asin, !asin.isEmpty else { return nil }
        return model.books.first {
            $0.asin.caseInsensitiveCompare(asin) == .orderedSame
        }
    }

    private func openChat(for note: SavedAINote) {
        guard let book = book(for: note) else { return }
        dismiss()
        model.section = .highlights
        model.bookWorkspaceSection = .chats
        model.bookWorkspaceID = book.asin
        model.selectedBookID = book.asin
    }
}
