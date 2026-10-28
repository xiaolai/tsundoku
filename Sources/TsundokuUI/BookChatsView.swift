import AppKit
import SwiftUI
import TsundokuCore
import UniformTypeIdentifiers

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
    @State private var compaction: ConversationCompaction?
    @State private var search = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var loadingTurns = false
    @State private var actionError: String?
    @State private var compactionBusy = false
    @State private var renameTarget: ConversationSummary?
    @State private var pendingDelete: ChatsAlert?
    /// Two errors, not one: a transcript load completing after a failed
    /// summary load must not hide why the sidebar is stale.
    @State private var summariesError: String?
    @State private var turnsError: String?
    /// Routing failures are separate: a later transcript refresh must not
    /// clear the reason a card's chat did not open.
    @State private var routeError: String?

    private var error: String? { summariesError ?? routeError ?? turnsError }
    @State private var turnsGeneration = 0
    @State private var summariesGeneration = 0
    @State private var incompleteCaptures = false
    /// Fingerprints are expensive to rebuild. Only a complete load is
    /// cached; an incomplete one is retried on the next reload.
    @State private var captureCache: (
        captures: [CaptureRecord], fingerprints: [String]
    )?
    @State private var highlightTurnID: Int64?
    @State private var scrolledHighlight: Int64?
    /// Set while a card's explicit conversation is being loaded, so the
    /// selection change handler does not load the same transcript twice.
    @State private var pendingSelection: Int64?
    /// A card route can name a conversation the sidebar excludes. Pin it so
    /// a concurrent summary reload cannot replace it with the newest thread.
    @State private var pinnedSelection: Int64?
    /// A routed conversation the sidebar excludes; its metadata is needed so
    /// the transcript can still be filed under this book.
    @State private var routedConversation: Conversation?

    private enum ChatsAlert: Identifiable {
        case one(
            ConversationSummary, ConversationDeletionImpact, Date, Int64,
            Set<String>, Set<Int64>)
        case all(
            ConversationDeletionImpact, Set<Int64>, [Int64: Date],
            [Int64: Int64], Set<String>, Set<Int64>)
        case removeCompaction(Int64, Int64)

        var id: String {
            switch self {
            case .one(let summary, _, _, _, _, _): "one-\(summary.id)"
            case .all: "all"
            case .removeCompaction(let id, let compactionID):
                "remove-compaction-\(id)-\(compactionID)"
            }
        }
    }

    /// `livePage` tracks Kindle only, so it cannot decide whether an Apple
    /// Books book is open. The companion itself chooses the frontmost reader;
    /// this view only needs to know that the companion exists.
    private var companionAvailable: Bool {
        model.openCompanion != nil || model.openCompanionChat != nil
    }

    private var bookKeys: Set<String> {
        ConversationFiling.keys(
            for: book,
            captureFingerprints: captureCache?.fingerprints ?? [])
    }

    private func summary(_ id: Int64?) -> ConversationSummary? {
        guard let id else { return nil }
        return summaries.first { $0.id == id }
    }

    private var selectedConversation: Conversation? {
        if let conversation = summary(selectedID)?.conversation {
            return conversation
        }
        guard routedConversation?.id == selectedID else { return nil }
        return routedConversation
    }

    private var selectedSummary: ConversationSummary? {
        summary(selectedID)
    }

    private var canCompact: Bool {
        // The compactor only has work when more than `keepRecentTurns`
        // turns sit after the last summary. Counting every turn left
        // Recompact enabled right after a successful compaction, where it
        // could only fail with “no turns newer than the last compaction”.
        let fresh = turns.filter { turn in
            compaction.map { turn.id > $0.throughTurnID } ?? true
        }
        return selectedConversation != nil
            && fresh.count > ConversationCompactor.keepRecentTurns
            && !compactionBusy && !loadingTurns
    }

    private var selectedIsFiled: Bool {
        guard let conversation = selectedConversation else { return true }
        return ConversationFiling.isFiled(conversation, under: book)
    }

    /// Moves a chat filed under weaker evidence (a title or a capture
    /// fingerprint) under this book's ASIN. Rows move in place, so the chat
    /// keeps every turn.
    private func fileUnderBook() {
        guard let selected = selectedConversation,
            let archive = model.archive
        else { return }
        Task {
            do {
                try await Task.detached {
                    // Move only the chosen chat. A title key can be shared by
                    // another edition of the same book, and filing one must
                    // not reassign the others. The reviewed identity is
                    // checked in the same transaction.
                    try archive.migrateConversation(
                        id: selected.id, to: book.asin, title: book.title,
                        source: book.source,
                        precondition: ConversationFilingPrecondition(
                            bookKey: selected.bookKey,
                            bookSource: selected.bookSource))
                }.value
                // The count change below reloads the summaries; calling
                // loadSummaries here would run the query twice.
                model.refreshConversationCounts()
            } catch {
                self.turnsError = "Could not file this chat: \(error)"
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
        .searchable(text: $search, prompt: "Search chats")
        .task(id: book.asin) {
            model.refreshConversationCounts()
            // `loadSummaries` consumes a card route after it succeeds, so a
            // load invalidated by a concurrent refresh leaves the route for
            // the replacement load instead of dropping it here.
            _ = await loadSummaries()
        }
        .onChange(of: search) { _, _ in
            // Re-query after a pause, not on every keystroke: each load is a
            // SQLite query over the archive.
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                _ = await loadSummaries()
            }
        }
        .sheet(item: $renameTarget) { summary in
            RenameChatSheet(
                initialTitle: summary.conversation.title ?? ""
            ) { title in
                rename(summary, to: title)
            }
        }
        .alert(item: $pendingDelete) { pending in
            switch pending {
            case .one(
                let summary, let impact, let updatedAt, let revision,
                let expectedKeys, let cardNoteIDs
            ):
                return Alert(
                    title: Text("Delete Chat?"),
                    message: Text(
                        "\(summary.displayTitle)\n\n"
                            + impact.deletionSentence()),
                    primaryButton: .destructive(Text("Delete Chat")) {
                        performDelete(
                            [summary.id],
                            expectedUpdatedAt: [summary.id: updatedAt],
                            expectedCompactionRevisions: [
                                summary.id: revision
                            ],
                            expectedBookKeys: expectedKeys,
                            expectedBookSource: book.source,
                            expectedCardNoteIDs: cardNoteIDs)
                    },
                    secondaryButton: .cancel())
            case .all(
                let impact, let ids, let expectedUpdatedAt,
                let expectedRevisions, let expectedKeys, let cardNoteIDs
            ):
                return Alert(
                    title: Text("Delete All Chats for This Book?"),
                    message: Text(
                        impact.deletionSentence(includeConversations: true)),
                    primaryButton: .destructive(Text("Delete All Chats")) {
                        performDelete(
                            ids, expectedUpdatedAt: expectedUpdatedAt,
                            expectedCompactionRevisions: expectedRevisions,
                            expectedBookKeys: expectedKeys,
                            expectedBookSource: book.source,
                            expectedCardNoteIDs: cardNoteIDs)
                    },
                    secondaryButton: .cancel())
            case .removeCompaction(let id, let compactionID):
                return Alert(
                    title: Text("Remove Summary?"),
                    message: Text(
                        "The next message will send the full transcript; "
                            + "nothing is deleted."),
                    primaryButton: .default(Text("Remove Summary")) {
                        removeCompaction(id, compactionID: compactionID)
                    },
                    secondaryButton: .cancel())
            }
        }
        .onChange(of: selectedID) { _, id in
            // Deselecting must clear the transcript, not return early just
            // because no programmatic route is pending.
            guard let id else {
                pinnedSelection = nil
                routedConversation = nil
                turnsGeneration += 1
                turns = []
                compaction = nil
                loadingTurns = false
                return
            }
            // Suppress exactly the one selection event the route caused.
            // Holding the flag for the whole load would swallow a real
            // re-selection of the same chat and could strand the spinner.
            guard id != pendingSelection else {
                pendingSelection = nil
                return
            }
            if id != pinnedSelection { pinnedSelection = nil }
            if routedConversation?.id != id { routedConversation = nil }
            Task { await loadTurns(id) }
        }
        .onChange(of: model.conversationCounts) { _, _ in
            // The companion can store an answer while this view is open;
            // refresh both the list and the selected transcript. A changed
            // selection has its own handler, so do not load turns twice.
            Task {
                let previousSelection = selectedID
                guard await loadSummaries() else { return }
                guard summariesError == nil,
                    selectedID == previousSelection,
                    let id = selectedID
                else { return }
                await loadTurns(id)
            }
        }
        .onChange(of: model.conversationChangeRevision) { _, _ in
            // The companion compacted or removed a summary.
            Task {
                let previousSelection = selectedID
                guard await loadSummaries() else { return }
                guard summariesError == nil,
                    selectedID == previousSelection,
                    let id = selectedID
                else { return }
                await loadTurns(id)
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
                if !summaries.isEmpty {
                    Menu {
                        Button("Delete All Chats…") { reviewDeleteAll() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Chat actions for this book")
                    .accessibilityLabel("Chat actions")
                }
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
                ContentUnavailableView {
                    Label(
                        search.isEmpty ? "No Chats Yet" : "No Matching Chats",
                        systemImage: search.isEmpty
                            ? "bubble.left.and.bubble.right" : "magnifyingglass")
                } description: {
                    Text(
                        search.isEmpty
                            ? "Ask about this book in the reading companion; "
                                + "its conversation appears here."
                            : "No chat for this book matches “\(search)”.")
                } actions: {
                    if search.isEmpty {
                        Button("Ask About This Book…") { startChat() }
                    } else {
                        Button("Clear Search") { search = "" }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(summaries) { summary in
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(summary.displayTitle).lineLimit(2)
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
                                if summary.isCompacted {
                                    Label(
                                        "Summarized for the model",
                                        systemImage: "text.append")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if !ConversationFiling.isFiled(
                                    summary.conversation, under: book)
                                {
                                    Label("Unfiled", systemImage: "tray")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 0)
                            Menu {
                                Button("Rename…") {
                                    renameTarget = summary
                                }
                                Button("Export Markdown…") {
                                    export(summary, format: .markdown)
                                }
                                Button("Export JSON…") {
                                    export(summary, format: .json)
                                }
                                Divider()
                                Button("Delete…") {
                                    reviewDelete(summary)
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Actions for this chat")
                        }
                        .tag(summary.id)
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Rename…") { renameTarget = summary }
                            Button("Delete…") { reviewDelete(summary) }
                        }
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
            archiveFailure(error)
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

    /// A read failure is the archive's, not the reader's, so it says what
    /// happened, keeps the raw text behind a disclosure, and offers the one
    /// action that can help: read it again.
    private func archiveFailure(_ detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Could Not Read Chats").font(.headline)
            Text(
                "The archive could not be read. Nothing was deleted."
            )
            .foregroundStyle(.secondary)
            DisclosureGroup("Technical Detail") {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460, alignment: .leading)
            }
            .frame(maxWidth: 460, alignment: .leading)
            Button("Try Again") { retryReading() }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
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
                    if compactionBusy {
                        ProgressView().controlSize(.small)
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
                    if selectedIsFiled {
                        Button("Continue") { continueSelected() }
                            .buttonStyle(.bordered)
                            .help(
                                companionAvailable
                                    ? "Open this chat in the reading companion"
                                    : "The reading companion is not available yet.")
                            .disabled(!companionAvailable)
                            .controlSize(.small)
                    }
                    Button("Compact") { compactSelected() }
                        .buttonStyle(.bordered)
                        .help(
                            canCompact
                                ? "Summarize older turns for the model; every "
                                    + "message stays in this transcript"
                                : "A chat needs more than "
                                    + "\(ConversationCompactor.keepRecentTurns) "
                                    + "turns newer than its last summary to compact.")
                        .disabled(!canCompact)
                        .controlSize(.small)
                    Menu {
                        Button("Export Markdown…") {
                            if let selectedSummary {
                                export(selectedSummary, format: .markdown)
                            }
                        }
                        Button("Export JSON…") {
                            if let selectedSummary {
                                export(selectedSummary, format: .json)
                            }
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(selectedConversation == nil)
                    .controlSize(.small)
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
                    if let actionError {
                        Text(actionError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if let compaction, let selectedID {
                        compactionSection(
                            compaction, conversationID: selectedID)
                    }
                    ForEach(turns) { turn in
                        if startsNewDay(turn) {
                            dayDivider(turn.createdAt)
                        }
                        turnView(turn)
                    }
                }
                .padding(16)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .task(id: highlightTurnID) {
                guard let highlightTurnID,
                    scrolledHighlight != highlightTurnID
                else { return }
                scrolledHighlight = highlightTurnID
                proxy.scrollTo(highlightTurnID, anchor: .center)
            }
        }
    }

    @ViewBuilder private func compactionSection(
        _ compaction: ConversationCompaction, conversationID: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "Earlier messages summarized for the model",
                systemImage: "text.append")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(
                "\(turns.filter { $0.id <= compaction.throughTurnID }.count) "
                    + "earlier turns are summarized. Every original message "
                    + "remains below.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(
                "Written "
                    + compaction.createdAt.formatted(
                        date: .abbreviated, time: .shortened)
                    + " by \(compaction.provider).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            DisclosureGroup("View Summary") {
                Text(compaction.summary)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Recompact") { compactSelected() }
                    .controlSize(.small)
                    .disabled(!canCompact)
                Button("Remove Summary") {
                    pendingDelete = .removeCompaction(
                        conversationID, compaction.id)
                }
                .controlSize(.small)
                .disabled(compactionBusy)
            }
        }
        .padding(10)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Earlier messages summarized for the model")
    }

    /// A chat can span weeks; a divider before the first turn of a day keeps
    /// the transcript readable without repeating the date on every message.
    private func startsNewDay(_ turn: ConversationTurn) -> Bool {
        guard let index = turns.firstIndex(where: { $0.id == turn.id })
        else { return false }
        if index == 0 { return true }
        return !Calendar.current.isDate(
            turns[index - 1].createdAt, inSameDayAs: turn.createdAt)
    }

    private func dayDivider(_ date: Date) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(TsundokuFormat.annotationDate(date))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
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
                    Text(turn.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(
                            TsundokuFormat.annotationDate(turn.createdAt)
                                + " at "
                                + turn.createdAt.formatted(
                                    date: .omitted, time: .shortened))
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
        .padding(highlightTurnID == turn.id ? 8 : 0)
        .background(
            highlightTurnID == turn.id
                ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .id(turn.id)
    }

    // MARK: Actions

    private func rename(_ summary: ConversationSummary, to title: String) {
        guard let archive = model.archive else { return }
        actionError = nil
        Task {
            do {
                try await Task.detached {
                    try archive.renameConversation(id: summary.id, title: title)
                }.value
                _ = await loadSummaries()
            } catch {
                actionError = "Could not rename this chat: \(error)"
            }
        }
    }

    private func reviewDelete(_ summary: ConversationSummary) {
        guard let archive = model.archive else { return }
        actionError = nil
        Task {
            do {
                let reviewed = try await Task.detached {
                    try archive.deletionReview(ids: [summary.id])
                }.value
                guard let updatedAt = reviewed.updatedAt[summary.id]
                else {
                    actionError = "This chat no longer exists."
                    return
                }
                pendingDelete = .one(
                    summary, reviewed.impact, updatedAt,
                    reviewed.revisions[summary.id] ?? 0, allBookKeys,
                    reviewed.cardNoteIDs)
            } catch {
                actionError = "Could not inspect this chat: \(error)"
            }
        }
    }

    private func reviewDeleteAll() {
        guard let archive = model.archive else { return }
        actionError = nil
        let keys = allBookKeys
        Task {
            do {
                let reviewed = try await Task.detached {
                    let all = try archive.conversations(bookKeys: keys)
                        .filter {
                            ConversationFiling.matches(
                                $0.conversation, keys: keys,
                                source: book.source)
                        }
                    let ids = Set(all.map(\.id))
                    let review = try archive.deletionReview(ids: ids)
                    return (ids, review)
                }.value
                pendingDelete = .all(
                    reviewed.1.impact, reviewed.0, reviewed.1.updatedAt,
                    reviewed.1.revisions, keys,
                    reviewed.1.cardNoteIDs)
            } catch {
                actionError = "Could not inspect these chats: \(error)"
            }
        }
    }

    private var allBookKeys: Set<String> {
        var keys = bookKeys.union([book.asin, book.asin.lowercased()])
        for summary in summaries {
            keys.insert(summary.conversation.bookKey)
        }
        return keys
    }

    private func performDelete(
        _ ids: Set<Int64>, expectedUpdatedAt: [Int64: Date],
        expectedCompactionRevisions: [Int64: Int64],
        expectedBookKeys: Set<String>? = nil,
        expectedBookSource: BookSource? = nil,
        expectedCardNoteIDs: Set<Int64>? = nil
    ) {
        guard let archive = model.archive else { return }
        pendingDelete = nil
        Task {
            do {
                let impact = try await Task.detached {
                    try archive.deleteConversations(
                        ids: ids, expectedUpdatedAt: expectedUpdatedAt,
                        expectedCompactionRevisions:
                            expectedCompactionRevisions,
                        expectedBookKeys: expectedBookKeys,
                        expectedBookSource: expectedBookSource,
                        expectedCardNoteIDs: expectedCardNoteIDs)
                }.value
                if impact.conversations > 0 {
                    model.markConversationsDeleted(ids)
                }
                model.refreshConversationCounts()
                _ = await loadSummaries()
                if let selectedID, ids.contains(selectedID) {
                    self.selectedID = nil
                    turns = []
                    compaction = nil
                }
            } catch {
                actionError = "Could not delete this chat: \(error)"
            }
        }
    }

    private func compactSelected() {
        guard let archive = model.archive, let id = selectedID else {
            return
        }
        compactionBusy = true
        actionError = nil
        Task {
            defer { compactionBusy = false }
            do {
                let compactor = ConversationCompactor.live(
                    archive: archive, settings: model.settings)
                _ = try await compactor.compact(conversationID: id)
                model.markConversationChanged(id)
                if selectedID == id {
                    await loadTurns(id)
                }
                _ = await loadSummaries()
                model.refreshConversationCounts()
            } catch {
                let message: String
                if error is ConversationCompactionError {
                    message = "Could not compact this chat: \(error)"
                } else {
                    message = "Could not compact this chat: "
                        + AIProviderFailure.message(
                            for: error, provider: model.settings.provider)
                }
                actionError = message
            }
        }
    }

    private func removeCompaction(
        _ id: Int64, compactionID: Int64
    ) {
        guard let archive = model.archive else { return }
        actionError = nil
        compactionBusy = true
        Task {
            defer { compactionBusy = false }
            do {
                try await Task.detached {
                    try archive.clearCompaction(
                        conversationID: id,
                        expectedCompactionID: compactionID)
                }.value
                model.markConversationChanged(id)
                if selectedID == id {
                    await loadTurns(id)
                }
                _ = await loadSummaries()
            } catch {
                actionError = "Could not remove the summary: \(error)"
            }
        }
    }

    /// Ask about this book from an empty Chats tab. The companion still needs
    /// the book open in a reader and says so when it is not.
    private func startChat() {
        guard model.openCompanionChat != nil else {
            actionError = "The reading companion is not available yet."
            return
        }
        model.startChat(book: book)
    }

    /// Read again whatever failed. A route failure comes from opening a
    /// card's chat, so it re-runs that route through the summary load.
    private func retryReading() {
        Task {
            routeError = nil
            if summariesError != nil { _ = await loadSummaries() }
            if let id = selectedID, turnsError != nil { await loadTurns(id) }
        }
    }

    private func continueSelected() {
        guard let selected = selectedConversation else { return }
        guard selectedIsFiled else {
            actionError =
                "File this chat under \(book.title) before continuing it."
            return
        }
        guard model.openCompanionChat != nil else {
            actionError = "The reading companion is not available yet."
            return
        }
        model.continueChat(book: book, conversationID: selected.id)
    }

    private func export(
        _ summary: ConversationSummary, format: ConversationExport.Format
    ) {
        guard let archive = model.archive else { return }
        actionError = nil
        let id = summary.id
        Task {
            do {
                let loaded = try await Task.detached {
                    try archive.conversationExportSnapshot(
                        conversationID: id)
                }.value
                guard let loaded else {
                    await MainActor.run {
                        actionError = "This chat no longer exists."
                    }
                    return
                }
                let conversation = loaded.conversation
                let text: String
                if format == .json {
                    text = try ConversationExport.json(
                        conversation: conversation,
                        turns: loaded.snapshot.turns,
                        compaction: loaded.snapshot.compaction)
                } else {
                    text = ConversationExport.markdown(
                        conversation: conversation,
                        turns: loaded.snapshot.turns,
                        compaction: loaded.snapshot.compaction)
                }
                await MainActor.run {
                    presentSavePanel(
                        text: text,
                        title: ConversationExport.title(
                            conversation: conversation,
                            turns: loaded.snapshot.turns),
                        format: format)
                }
            } catch {
                await MainActor.run {
                    actionError = "Could not export this chat: \(error)"
                }
            }
        }
    }

    @MainActor
    private func presentSavePanel(
        text: String, title: String, format: ConversationExport.Format
    ) {
        let panel = NSSavePanel()
        panel.title = "Export Chat"
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue =
            (safe.isEmpty ? "Chat" : safe) + ".\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            model.post(
                "Exported chat to \(url.lastPathComponent).", seconds: 6)
        } catch {
            actionError = "Could not write the export: \(error)"
        }
    }

    // MARK: Loading

    @discardableResult
    private func loadSummaries() async -> Bool {
        isLoading = true
        summariesError = nil
        guard let archive = model.archive else {
            isLoading = false
            summariesError = "The archive is not open."
            return false
        }
        summariesGeneration += 1
        let generation = summariesGeneration
        let cachedCache = captureCache
        let searchQuery = search
        do {
            let loaded = try await Task.detached {
                () -> (
                    rows: [ConversationSummary], incomplete: Bool,
                    captures: [CaptureRecord], fingerprints: [String],
                    usedCache: Bool
                ) in
                var incomplete = false
                let allCaptures: [CaptureRecord]
                do {
                    allCaptures = try archive.captures()
                } catch {
                    allCaptures = []
                    incomplete = true
                }
                let captures = allCaptures
                    .filter {
                        $0.asin.caseInsensitiveCompare(book.asin)
                            == .orderedSame
                    }
                    .sorted { $0.id < $1.id }
                let cached = cachedCache.flatMap {
                    $0.captures == captures ? $0 : nil
                }
                var fingerprints = cached?.fingerprints ?? []
                if cached == nil {
                    for capture in captures {
                        do {
                            let index = try BookTextIndex.load(
                                directory: URL(
                                    fileURLWithPath: capture.directory))
                            fingerprints.append(index.fingerprint)
                        } catch {
                            incomplete = true
                        }
                    }
                }
                let keys = ConversationFiling.keys(
                    for: book, captureFingerprints: fingerprints)
                // Query only this book's keys. Include the stored spelling of
                // the ASIN for a conversation filed before canonical casing.
                var queryKeys = keys
                queryKeys.insert(book.asin.lowercased())
                let rows = try archive.conversations(
                    bookKeys: queryKeys, includeLastAnswer: false,
                    search: searchQuery)
                return (
                    rows.filter {
                        ConversationFiling.matches(
                            $0.conversation, keys: keys,
                            source: book.source)
                    },
                    incomplete, captures, fingerprints, cached != nil)
            }.value
            guard generation == summariesGeneration else { return false }
            if !loaded.usedCache, !loaded.incomplete {
                // A failed capture or index read is not a stable answer.
                // Caching it would keep text-linked chats hidden until the
                // captures change; an incomplete load is retried instead.
                captureCache = (loaded.captures, loaded.fingerprints)
            }
            summaries = loaded.rows
            incompleteCaptures = loaded.incomplete
            isLoading = false
            if selectedID == nil
                || (!loaded.rows.contains(where: { $0.id == selectedID })
                    && pinnedSelection != selectedID)
            {
                selectedID = loaded.rows.first?.id
            }
            await applyPendingRoute()
            return true
        } catch {
            guard generation == summariesGeneration else { return false }
            isLoading = false
            self.summariesError = "\(error)"
            return false
        }
    }

    /// Opens the conversation a card asked for once summaries are settled.
    /// A target absent from the sidebar is still resolved by ID, so a card
    /// whose association failed the sidebar's key check can open its chat.
    private enum RouteLookup: Sendable {
        case found(Conversation)
        case missing
        case failed(String)
    }

    private func applyPendingRoute() async {
        guard let pending = model.peekPendingChat(for: book.asin) else {
            return
        }
        let generation = summariesGeneration
        routeError = nil
        if !summaries.contains(where: { $0.id == pending.conversationID }) {
            guard let archive = model.archive else {
                routeError = "The archive is not open."
                return
            }
            let id = pending.conversationID
            // The lookup runs off the UI actor; `conversation(id:)` uses the
            // archive's serial queue and may wait on SQLite.
            let lookup = await Task.detached { () -> RouteLookup in
                do {
                    guard let conversation = try archive.conversation(id: id)
                    else { return .missing }
                    return .found(conversation)
                } catch {
                    return .failed("\(error)")
                }
            }.value
            // A newer reload can have started and resolved a newer route
            // while this lookup ran; its state must not be overwritten by
            // this older pass.
            guard generation == summariesGeneration,
                model.peekPendingChat(for: book.asin) == pending
            else { return }
            switch lookup {
            case .failed(let message):
                // A read failure is not proof the chat is missing; keep the
                // route so a retry can open it.
                routeError = "Could not open this card's chat: \(message)"
                return
            case .missing:
                _ = model.takePendingChat(pending)
                routeError =
                    "This card's chat no longer exists. The card's saved "
                    + "note remains under the book."
                return
            case .found(let conversation):
                guard belongsToThisBook(conversation) else {
                    _ = model.takePendingChat(pending)
                    routeError =
                        "This card's chat is not filed under this book. File "
                        + "it from Chats, then open the card again."
                    return
                }
                routedConversation = conversation
            }
        } else {
            routedConversation = nil
        }
        guard model.takePendingChat(pending) != nil else {
            // A newer route for this book arrived while the lookup ran; let
            // its own pass open it.
            return
        }
        scrolledHighlight = nil
        pinnedSelection = pending.conversationID
        pendingSelection = pending.conversationID
        selectedID = pending.conversationID
        await loadTurns(pending.conversationID)
        guard generation == summariesGeneration,
            selectedID == pending.conversationID
        else { return }
        highlightTurnID = pending.turnID
        pendingSelection = nil
    }

    private func belongsToThisBook(_ conversation: Conversation) -> Bool {
        if let source = conversation.bookSource, source != book.source {
            return false
        }
        // An explicit identifier can only match itself; a title cannot
        // override it, just as in AICardFilter.
        if !AICardFilter.isWeakKey(conversation.bookKey) {
            return ConversationFiling.canonical(conversation.bookKey)
                == ConversationFiling.canonical(book.asin)
        }
        let keys = ConversationFiling.keys(
            for: book,
            captureFingerprints: captureCache?.fingerprints ?? [])
        if ConversationFiling.matches(conversation, keys: keys) {
            return true
        }
        let title = ConversationKey.normalize(conversation.bookTitle)
        return !title.isEmpty
            && !ReadingIdentityResolver.isPlaceholder(book.title)
            && title == ConversationKey.normalize(book.title)
    }

    private func loadTurns(_ id: Int64) async {
        guard let archive = model.archive, selectedID == id else { return }
        turnsGeneration += 1
        let generation = turnsGeneration
        loadingTurns = true
        turnsError = nil
        // A failed load must not leave the previous chat's transcript under
        // the new selection.
        turns = []
        compaction = nil
        do {
            let loaded = try await Task.detached {
                try archive.conversationSnapshot(conversationID: id)
            }.value
            guard generation == turnsGeneration, selectedID == id else {
                return
            }
            turns = loaded.turns
            compaction = loaded.compaction
            loadingTurns = false
        } catch {
            guard generation == turnsGeneration else { return }
            loadingTurns = false
            self.turnsError = "\(error)"
        }
    }
}

private struct RenameChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialTitle: String
    let onSave: (String) -> Void
    @State private var title: String

    init(initialTitle: String, onSave: @escaping (String) -> Void) {
        self.initialTitle = initialTitle
        self.onSave = onSave
        _title = State(initialValue: initialTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Chat").font(.headline)
            TextField("Chat name", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("Leave blank to use the first question.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
