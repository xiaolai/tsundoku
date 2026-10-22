import SwiftUI
import TsundokuCore

public struct HistoryView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var recentBooks: [Book] {
        model.books
            .filter { $0.isEbook && ($0.lastView != nil || $0.isRead) }
            .sorted { left, right in
                switch (left.lastView, right.lastView) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
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
            .prefix(10)
            .map { $0 }
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
                LabeledContent("Pages Seen") {
                    Text(
                        "\(model.sessions.reduce(0) { $0 + $1.pageCount })"
                    )
                }
            }

            Section("Recently Read") {
                if recentBooks.isEmpty {
                    Text("No last-read dates were found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentBooks) { book in
                        Button {
                            model.sourceFilter =
                                book.source == .appleBooks
                                ? .appleBooks : .kindle
                            model.selectedBookID = book.asin
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

            if sessionDays.isEmpty {
                Section("Sessions") {
                    Text("No sessions yet.")
                        .foregroundStyle(.secondary)
                    Button("Turn Tracking On") {
                        model.toggleTracking()
                    }
                }
            } else {
                ForEach(sessionDays, id: \.day) { group in
                    Section(
                        group.day.formatted(
                            date: .complete, time: .omitted)
                    ) {
                        ForEach(group.sessions) { session in
                            SessionListRow(session: session)
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
                            ? "Track Reading" : "Stop Tracking",
                        systemImage: model.trackedBookID == nil
                            ? "record.circle" : "stop.circle")
                }
            }
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
            Text(duration)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(session.pageCount) pages")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var duration: String {
        let minutes = max(1, Int(session.duration / 60))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
