import AppKit
import SwiftUI
import TsundokuCore

struct SavedAINotesView: View {
    @ObservedObject var model: AppModel
    let bookID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var notes: [SavedAINote] {
        model.savedAINotes.filter {
            (bookID == nil || $0.asin == bookID)
                && (search.isEmpty
                    || [$0.bookTitle, $0.prompt, $0.answer, $0.provider]
                        .contains {
                            $0.localizedStandardContains(search)
                        })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Saved AI Notes", systemImage: "sparkles").font(.title2)
                Spacer()
                IconButton(
                    "Done", systemImage: "xmark",
                    tooltip: "Close saved AI notes"
                ) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            TextField("Search saved answers and questions", text: $search)
                .textFieldStyle(.roundedBorder).padding(.horizontal)
            if notes.isEmpty {
                ContentUnavailableView(
                    "No Saved AI Notes", systemImage: "sparkles",
                    description: Text(
                        "Save an answer in the reading companion."
                    ))
            } else {
                List(notes) { note in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            note.bookTitle.isEmpty
                                ? "Book unidentified" : note.bookTitle
                        ).font(.headline)
                        Text(
                            "AI-generated · \(note.provider) · \(note.bookSource?.displayName ?? "Source unavailable") · \(TsundokuFormat.annotationDate(note.createdAt))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Prompt") {
                            Text(note.prompt).textSelection(.enabled)
                        }
                        Text(note.answer).textSelection(.enabled)
                        IconButton("Copy Answer", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                note.answer, forType: .string)
                        }.controlSize(.small)
                    }.padding(.vertical, 10)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 680, minHeight: 420, idealHeight: 600)
        .onAppear { model.refreshAINotes() }
    }
}
