import AppKit
import SwiftUI
import TsundokuCore

/// A book's stored conversations, read-only.
///
/// A new question needs the live page, so continuing a chat happens in the
/// reading companion; this view is for reading, copying and orienting.
struct BookChatsView: View {
    @ObservedObject var model: AppModel
    let book: Book

    @State private var summaries: [ConversationSummary] = []
    @State private var selectedID: Int64?
    @State private var turns: [ConversationTurn] = []
    @State private var isLoading = true
    @State private var loadingTurns = false
    @State private var error: String?
    @State private var turnsGeneration = 0
    @State private var incompleteCaptures = false

    /// `livePage` tracks Kindle only, so it cannot decide whether an Apple
    /// Books book is open. The companion itself chooses the frontmost reader;
    /// this view only needs to know that the companion exists.
    private var companionAvailable: Bool {
        model.openCompanion != nil
    }

    private func summary(_ id: Int64?) -> ConversationSummary? {
        guard let id else { return nil }
        return summaries.first { $0.id == id }
    }

    private var selectedIsFiled: Bool {
        guard let conversation = summary(selectedID)?.conversation else {
            return true
        }
        return ConversationFiling.isFiled(conversation, under: book)
    }

    /// Moves a chat filed under weaker evidence (a title or a capture
    /// fingerprint) under this book's ASIN. Rows move in place, so the chat
    /// keeps every turn.
    private func fileUnderBook() {
        guard let selected = summary(selectedID),
            let archive = model.archive
        else { return }
        Task {
            do {
                try await Task.detached {
                    // Move only the chosen chat. A title key can be shared by
                    // another edition of the same book, and filing one must
                    // not reassign the others.
                    try archive.migrateConversation(
                        id: selected.id, to: book.asin, title: book.title,
                        source: book.source)
                }.value
                // The count change below reloads the summaries; calling
                // loadSummaries here would run the query twice.
                model.refreshConversationCounts()
            } catch {
                self.error = "Could not file this chat: \(error)"
            }
        }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            detail
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .task(id: book.asin) {
            model.refreshConversationCounts()
            await loadSummaries()
        }
        .onChange(of: selectedID) { _, id in
            guard let id else {
                turnsGeneration += 1
                turns = []
                loadingTurns = false
                return
            }
            Task { await loadTurns(id) }
        }
        .onChange(of: model.conversationCounts) { _, _ in
            // The companion can store an answer while this view is open;
            // refresh both the list and the selected transcript.
            Task {
                await loadSummaries()
                if let id = selectedID { await loadTurns(id) }
            }
        }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Chats", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }
            .padding(10)
            if incompleteCaptures {
                Label(
                    "Some captures could not be read; text-linked chats may "
                        + "be missing.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            if summaries.isEmpty, !isLoading {
                ContentUnavailableView(
                    "No Chats Yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(
                        "Ask about this book in the reading companion; its "
                            + "conversation appears here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(summaries) { summary in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(summary.firstQuestion).lineLimit(2)
                            Text(
                                "\(summary.turnCount) "
                                    + (summary.turnCount == 1
                                        ? "message" : "messages")
                                    + " · "
                                    + TsundokuFormat.annotationDate(
                                        summary.conversation.updatedAt)
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if !ConversationFiling.isFiled(
                                summary.conversation, under: book)
                            {
                                Label("Unfiled", systemImage: "tray")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .tag(summary.id)
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder private var detail: some View {
        if let error {
            ContentUnavailableView(
                "Could Not Read Chats",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if loadingTurns {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if turns.isEmpty {
            ContentUnavailableView(
                "Choose a Chat",
                systemImage: "bubble.left",
                description: Text(
                    "Select a conversation to read it. Chats are saved "
                        + "automatically."
                )
            )
        } else {
            transcript
        }
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    if let first = turns.first {
                        Text(
                            TsundokuFormat.annotationDate(first.createdAt)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !selectedIsFiled {
                        IconButton(
                            "File Under This Book",
                            systemImage: "tray.and.arrow.down",
                            tooltip:
                                "Move this chat under \(book.title); every "
                                + "turn is kept"
                        ) { fileUnderBook() }
                        .controlSize(.small)
                    }
                    IconButton(
                        "Open in Companion", systemImage: "sparkles",
                        tooltip: companionAvailable
                            ? "Open the companion for the current reader page"
                            : "The reading companion is not available yet."
                    ) {
                        model.showAIPanel()
                    }
                    .disabled(!companionAvailable)
                    .controlSize(.small)
                }
                ForEach(turns) { turn in
                    turnView(turn)
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func turnView(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(turn.promptLabel)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(
                                cornerRadius: 14, style: .continuous))
                    if !turn.context.attachments.isEmpty {
                        Text(
                            turn.context.attachments.joined(separator: " · ")
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Companion · \(turn.provider)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    IconButton(
                        "Copy Answer", systemImage: "doc.on.doc",
                        tooltip: "Copy this answer"
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            turn.answer, forType: .string)
                    }
                    .controlSize(.mini)
                }
                MarkdownText(text: turn.answer)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Loading

    private func loadSummaries() async {
        isLoading = true
        error = nil
        guard let archive = model.archive else {
            isLoading = false
            error = "The archive is not open."
            return
        }
        do {
            let loaded = try await Task.detached {
                () -> (rows: [ConversationSummary], incomplete: Bool) in
                let all = try archive.conversations()
                var incomplete = false
                let captures: [CaptureRecord]
                do {
                    captures = try archive.captures()
                } catch {
                    captures = []
                    incomplete = true
                }
                var fingerprints: [String] = []
                for capture in captures
                where capture.asin.caseInsensitiveCompare(book.asin)
                    == .orderedSame
                {
                    do {
                        let index = try BookTextIndex.load(
                            directory: URL(
                                fileURLWithPath: capture.directory))
                        fingerprints.append(index.fingerprint)
                    } catch {
                        incomplete = true
                    }
                }
                let keys = ConversationFiling.keys(
                    for: book, captureFingerprints: fingerprints)
                return (
                    all.filter {
                        ConversationFiling.matches($0.conversation, keys: keys)
                    },
                    incomplete)
            }.value
            summaries = loaded.rows
            incompleteCaptures = loaded.incomplete
            isLoading = false
            if selectedID == nil
                || !loaded.rows.contains(where: { $0.id == selectedID })
            {
                selectedID = loaded.rows.first?.id
            }
        } catch {
            isLoading = false
            self.error = "\(error)"
        }
    }

    private func loadTurns(_ id: Int64) async {
        guard let archive = model.archive else { return }
        turnsGeneration += 1
        let generation = turnsGeneration
        loadingTurns = true
        error = nil
        do {
            let loaded = try await Task.detached {
                try archive.conversationTurns(conversationID: id)
            }.value
            guard generation == turnsGeneration, selectedID == id else {
                return
            }
            turns = loaded
            loadingTurns = false
        } catch {
            guard generation == turnsGeneration else { return }
            loadingTurns = false
            self.error = "\(error)"
        }
    }
}
