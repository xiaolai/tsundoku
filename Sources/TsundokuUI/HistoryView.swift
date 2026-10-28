import SwiftUI
import TsundokuCore

public struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var showAllRecent = false
    @State private var detailSession: ReadingSession?

    public init(model: AppModel) {
        self.model = model
    }

    private var recentBooks: [Book] {
        model.books
            .filter { $0.isEbook && ($0.lastView != nil || $0.isRead) }
            .sorted { left, right in
                switch (left.lastView, right.lastView) {
                case (let leftDate?, let rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    break
                }
                return left.title.localizedStandardCompare(right.title)
                    == .orderedAscending
            }
            .map { $0 }
    }

    /// The first screenful, with the rest one click away. Silently showing ten
    /// of a few hundred made the library look smaller than it is.
    private var shownRecentBooks: [Book] {
        showAllRecent ? recentBooks : Array(recentBooks.prefix(10))
    }

    private func trackedTitle() -> String? {
        guard let id = model.trackedBookID else { return nil }
        return model.books.first {
            $0.asin.caseInsensitiveCompare(id) == .orderedSame
        }?.title ?? id
    }

    private var sessionDays: [(day: Date, sessions: [ReadingSession])] {
        Dictionary(
            grouping: model.sessions,
            by: { Calendar.current.startOfDay(for: $0.startedAt) }
        )
        .map { day, sessions in
            (
                day: day,
                sessions: sessions.sorted { $0.startedAt > $1.startedAt }
            )
        }
        .sorted { $0.day > $1.day }
    }

    public var body: some View {
        List {
            Section("Overview") {
                LabeledContent("Read") {
                    Text(
                        "\(model.books.filter { $0.isEbook && $0.isRead }.count)"
                    )
                }
                LabeledContent("Annotated") {
                    Text("\(model.annotatedBookCount)")
                }
                LabeledContent("Sessions") {
                    Text("\(model.sessions.count)")
                }
                LabeledContent("Pages Observed") {
                    Text(
                        "\(model.sessions.reduce(0) { $0 + $1.pageCount })"
                    )
                }
            }

            Section("Recently Opened in Your Libraries") {
                if recentBooks.isEmpty {
                    Text("No last-read dates were found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shownRecentBooks) { book in
                        Button {
                            model.sourceFilter =
                                book.source == .appleBooks
                                ? .appleBooks : .kindle
                            model.selectedBookID = book.asin
                            model.bookWorkspaceID = book.asin
                            model.annotationSearch = ""
                            model.section = .library
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title)
                                    if !book.author.isEmpty {
                                        Text(book.author)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let lastView = book.lastView {
                                    Text(TsundokuFormat.relative(lastView))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if recentBooks.count > shownRecentBooks.count {
                        Button(
                            "Show All \(recentBooks.count) Recently Opened"
                        ) { showAllRecent = true }
                            .controlSize(.small)
                    }
                    if recentBooks.allSatisfy({ $0.lastView == nil }) {
                        Text(
                            "Kindle did not record last-read dates for "
                                + "these books."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text(
                    "Sessions are recorded only while tracking is on, and "
                        + "only from the Kindle reader. Apple Books pages are "
                        + "not tracked."
                )
                .font(.caption).foregroundStyle(.secondary)
                if let title = trackedTitle() {
                    HStack(spacing: 6) {
                        Label(
                            "Tracking \(title)",
                            systemImage: "record.circle.fill")
                            .foregroundStyle(.secondary)
                        Button("Stop") { model.toggleTracking() }
                            .controlSize(.small)
                    }
                    .font(.caption)
                }
            }
            if sessionDays.isEmpty {
                Section("Sessions") {
                    Text("No sessions yet.")
                        .foregroundStyle(.secondary)
                    Button("Turn Tracking On") { model.toggleTracking() }
                        .help(
                            "Select a Kindle book first: sessions follow the "
                                + "book you are reading there.")
                }
            } else {
                ForEach(sessionDays, id: \.day) { group in
                    Section(
                        group.day.formatted(
                            date: .complete, time: .omitted)
                    ) {
                        ForEach(group.sessions) { session in
                            SessionListRow(session: session)
                                .contentShape(Rectangle())
                                .onTapGesture { detailSession = session }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem {
                Button {
                    model.toggleTracking()
                } label: {
                    Label(
                        model.trackedBookID == nil
                            ? "Track Reading"
                            : "Tracking \(trackedTitle() ?? "")",
                        systemImage: model.trackedBookID == nil
                            ? "record.circle" : "stop.circle")
                }
                    .help(
                        model.trackedBookID == nil
                            ? "Track reading for the selected Kindle book"
                            : "Stop tracking")
            }
        }
        .sheet(item: $detailSession) { session in
            SessionDetailView(model: model, session: session)
        }
        .onAppear { model.refreshActivity() }
    }
}

struct SessionListRow: View {
    let session: ReadingSession

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    session.bookTitle.isEmpty
                        ? session.asin : session.bookTitle
                )
                Text(
                    "\(session.startedAt.formatted(date: .omitted, time: .shortened))"
                        + " – "
                        + session.endedAt.formatted(
                            date: .omitted, time: .shortened)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.durationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(session.pageCount) pages observed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

}

/// One session, with the pages it observed. The rows store observations but
/// never showed them; this is where they belong.
struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    let session: ReadingSession
    @Environment(\.dismiss) private var dismiss
    @State private var observations: [PageObservation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        session.bookTitle.isEmpty
                            ? session.asin : session.bookTitle
                    ).font(.title3.bold())
                    Text(
                        session.startedAt.formatted(
                            date: .abbreviated, time: .shortened)
                            + " – "
                            + session.endedAt.formatted(
                                date: .omitted, time: .shortened)
                            + " · " + session.durationLabel
                            + " · \(session.pageCount) pages observed"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if observations.isEmpty {
                Text("No page text was recorded for this session.")
                    .foregroundStyle(.secondary)
            } else {
                List(observations) { observation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            observation.observedAt.formatted(
                                date: .omitted, time: .shortened)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(observation.text)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
            HStack {
                Button("Open Book in Library") {
                    model.selectedBookID = session.asin
                    model.bookWorkspaceID = session.asin
                    model.section = .library
                    dismiss()
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 520)
        .task {
            observations = model.sessionObservations(session)
        }
    }
}
