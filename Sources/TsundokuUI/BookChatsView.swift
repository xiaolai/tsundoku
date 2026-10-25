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

    private var liveBookMatches: Bool {
        if let id = model.livePage?.bookID, !id.isEmpty {
            return id == book.asin
        }
        return model.livePage?.title == book.title
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
        let key = selected.conversation.bookKey
        Task {
            do {
                try await Task.detached {
                    try archive.migrateConversations(
                        from: key, to: book.asin, title: book.title,
                        source: book.source)
                }.value
                await loadSummaries()
                selectedID = selected.id
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
                turns = []
                return
            }
            Task { await loadTurns(id) }
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
                        tooltip: liveBookMatches
                            ? "Continue this conversation in the reading companion"
                            : "Open this book in the reader first; the companion answers from the live page."
                    ) {
                        model.showAIPanel()
                    }
                    .disabled(!liveBookMatches)
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
                let all = try archive.conversations()
                let captures = (try? archive.captures()) ?? []
                var fingerprints: [String] = []
                for capture in captures
                where capture.asin.caseInsensitiveCompare(book.asin)
                    == .orderedSame
                {
                    if let index = try? BookTextIndex.load(
                        directory: URL(fileURLWithPath: capture.directory))
                    {
                        fingerprints.append(index.fingerprint)
                    }
                }
                let keys = ConversationFiling.keys(
                    for: book, captureFingerprints: fingerprints)
                return all.filter { keys.contains($0.conversation.bookKey) }
            }.value
            summaries = loaded
            isLoading = false
            if selectedID == nil
                || !loaded.contains(where: { $0.id == selectedID })
            {
                selectedID = loaded.first?.id
            }
        } catch {
            isLoading = false
            self.error = "\(error)"
        }
    }

    private func loadTurns(_ id: Int64) async {
        guard let archive = model.archive else { return }
        loadingTurns = true
        do {
            let loaded = try await Task.detached {
                try archive.conversationTurns(conversationID: id)
            }.value
            guard selectedID == id else { return }
            turns = loaded
            loadingTurns = false
        } catch {
            loadingTurns = false
            self.error = "\(error)"
        }
    }
}
