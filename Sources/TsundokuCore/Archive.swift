import Foundation

public enum AnnotationExportFormat: String, CaseIterable, Sendable {
    case json
    case markdown
    case csv

    public var displayName: String {
        switch self {
        case .json: "JSON"
        case .markdown: "Markdown"
        case .csv: "CSV"
        }
    }

    public var fileExtension: String {
        switch self {
        case .json: "json"
        case .markdown: "md"
        case .csv: "csv"
        }
    }
}

public struct ArchiveCounts: Sendable {
    public let books: Int
    public let annotations: Int
    public let userAnnotations: Int
    public let sessions: Int
    public let captures: Int

    public init(
        books: Int, annotations: Int, userAnnotations: Int, sessions: Int,
        captures: Int
    ) {
        self.books = books
        self.annotations = annotations
        self.userAnnotations = userAnnotations
        self.sessions = sessions
        self.captures = captures
    }
}

public final class Archive: @unchecked Sendable {
    private let database: SQLiteDatabase
    private let queue = DispatchQueue(label: "app.tsundoku.archive")

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: path.path)
        try Self.createSchema(database)
    }

    public static func standard() throws -> Archive {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return try Archive(
            path: support.appendingPathComponent(
                "Tsundoku/tsundoku.sqlite"))
    }

    private static func createSchema(_ database: SQLiteDatabase) throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS books (
              asin TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              author TEXT NOT NULL,
              book_type INTEGER NOT NULL,
              read_state INTEGER NOT NULL,
              last_view REAL,
              current_position TEXT,
              max_position TEXT,
              downloaded INTEGER NOT NULL,
              source TEXT NOT NULL,
              imported_at REAL NOT NULL,
              progress REAL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS annotations (
              id TEXT PRIMARY KEY,
              asin TEXT NOT NULL,
              kind TEXT NOT NULL,
              provenance TEXT NOT NULL,
              start_pos TEXT,
              end_pos TEXT,
              text TEXT,
              note TEXT,
              color TEXT,
              created_at REAL,
              modified_at REAL,
              source TEXT NOT NULL,
              archived_at REAL NOT NULL,
              book_source TEXT NOT NULL DEFAULT 'Kindle'
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS annotations_asin
            ON annotations(asin)
            """,
            """
            CREATE INDEX IF NOT EXISTS annotations_provenance
            ON annotations(provenance)
            """,
            """
            CREATE TABLE IF NOT EXISTS annotation_sources (
              annotation_id TEXT NOT NULL,
              source TEXT NOT NULL,
              source_id TEXT,
              seen_at REAL NOT NULL,
              PRIMARY KEY (annotation_id, source)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              asin TEXT NOT NULL,
              started_at REAL NOT NULL,
              ended_at REAL NOT NULL,
              start_position TEXT,
              end_position TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS page_observations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id INTEGER NOT NULL,
              asin TEXT NOT NULL,
              page INTEGER,
              text TEXT NOT NULL,
              observed_at REAL NOT NULL,
              UNIQUE(session_id, text)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS ai_notes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              asin TEXT,
              position TEXT,
              kind TEXT NOT NULL,
              prompt TEXT NOT NULL,
              answer TEXT NOT NULL,
              provider TEXT NOT NULL,
              created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS conversations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              book_key TEXT NOT NULL,
              book_title TEXT NOT NULL,
              book_source TEXT,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS conversations_book_key
            ON conversations(book_key)
            """,
            """
            CREATE TABLE IF NOT EXISTS conversation_turns (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              conversation_id INTEGER NOT NULL,
              action TEXT NOT NULL,
              question TEXT NOT NULL,
              answer TEXT NOT NULL,
              provider TEXT NOT NULL,
              prompt TEXT NOT NULL,
              context_json TEXT NOT NULL,
              created_at REAL NOT NULL
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS conversation_turns_conversation
            ON conversation_turns(conversation_id)
            """,
            """
            CREATE TABLE IF NOT EXISTS captures (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              asin TEXT,
              title TEXT,
              directory TEXT NOT NULL,
              page_count INTEGER NOT NULL,
              pdf_path TEXT,
              created_at REAL NOT NULL,
              state TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
            """,
        ]
        for statement in statements {
            try database.execute(statement)
        }
        try ensureColumn(
            database, table: "books", column: "progress",
            definition: "progress REAL")
        try ensureColumn(
            database, table: "annotations", column: "book_source",
            definition: "book_source TEXT NOT NULL DEFAULT 'Kindle'")
        try ensureColumn(
            database, table: "ai_notes", column: "book_source",
            definition: "book_source TEXT")
        try ensureColumn(
            database, table: "ai_notes", column: "turn_id",
            definition: "turn_id INTEGER")
        try ensureColumn(
            database, table: "ai_notes", column: "carded_at",
            definition: "carded_at REAL")
        // Legacy notes have no turn and must not collide with each other.
        try database.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS ai_notes_turn_id
            ON ai_notes(turn_id)
            WHERE turn_id IS NOT NULL
            """)
        // Card reads select and sort by carded_at; without this partial
        // index SQLite scans every linked note and sorts in a temp B-tree.
        try database.execute(
            """
            CREATE INDEX IF NOT EXISTS ai_notes_carded
            ON ai_notes(carded_at DESC, id DESC)
            WHERE carded_at IS NOT NULL
            """)
        // The case-insensitive book joins need this index; without it each
        // card row scans the whole books table.
        try database.execute(
            """
            CREATE INDEX IF NOT EXISTS books_asin_nocase
            ON books(asin COLLATE NOCASE)
            """)
        for (column, definition) in [
            ("source", "source TEXT NOT NULL DEFAULT 'kindle'"),
            ("identity_confidence", "identity_confidence TEXT"),
            ("termination", "termination TEXT"),
            ("warnings", "warnings TEXT"),
        ] {
            try ensureColumn(
                database, table: "captures", column: column,
                definition: definition)
        }
    }

    private static func ensureColumn(
        _ database: SQLiteDatabase, table: String, column: String,
        definition: String
    ) throws {
        let columns = try database.query("PRAGMA table_info(\(table))")
        guard !columns.contains(where: { $0.string("name") == column })
        else { return }
        try database.execute(
            "ALTER TABLE \(table) ADD COLUMN \(definition)")
    }

    // MARK: - Import

    @discardableResult
    public func importAll(
        books: [Book], annotations: [Annotation]
    ) throws -> ImportResult {
        try queue.sync {
            let now = Date()
            let timestamp = now.timeIntervalSince1970
            try database.transaction {
                for book in books {
                    try database.execute(
                        """
                        INSERT INTO books
                        (asin, title, author, book_type, read_state, last_view,
                         current_position, max_position, downloaded, source,
                         imported_at, progress)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(asin) DO UPDATE SET
                          title = excluded.title,
                          author = excluded.author,
                          book_type = excluded.book_type,
                          read_state = excluded.read_state,
                          last_view = excluded.last_view,
                          current_position = excluded.current_position,
                          max_position = excluded.max_position,
                          downloaded = excluded.downloaded,
                          source = excluded.source,
                          imported_at = excluded.imported_at,
                          progress = excluded.progress
                        """,
                        [
                            .text(book.asin), .text(book.title),
                            .text(book.author), .integer(Int64(book.bookType)),
                            .integer(Int64(book.readState)),
                            book.lastView.map {
                                .real($0.timeIntervalSince1970)
                            } ?? .null,
                            book.currentPosition.map { .text($0) } ?? .null,
                            book.maxPosition.map { .text($0) } ?? .null,
                            .integer(book.downloaded ? 1 : 0),
                            .text(book.source.rawValue), .real(timestamp),
                            book.progress.map { .real($0) } ?? .null,
                        ])
                }
                for annotation in annotations {
                    try database.execute(
                        """
                        INSERT INTO annotations
                        (id, asin, kind, provenance, start_pos, end_pos, text,
                         note, color, created_at, modified_at, source,
                         archived_at, book_source)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                          asin = excluded.asin,
                          kind = excluded.kind,
                          provenance = excluded.provenance,
                          start_pos = excluded.start_pos,
                          end_pos = excluded.end_pos,
                          text = COALESCE(excluded.text, annotations.text),
                          note = CASE
                            WHEN excluded.modified_at IS NOT NULL
                              AND (annotations.modified_at IS NULL
                                   OR excluded.modified_at
                                      >= annotations.modified_at)
                            THEN excluded.note
                            -- A note without a timestamp is still content:
                            -- take it. A missing note without a timestamp
                            -- cannot be told apart from an unavailable
                            -- field, so it never clears.
                            WHEN excluded.modified_at IS NULL
                              AND excluded.note IS NOT NULL
                            THEN excluded.note
                            ELSE annotations.note
                          END,
                          color = COALESCE(excluded.color, annotations.color),
                          created_at = COALESCE(excluded.created_at,
                                                annotations.created_at),
                          modified_at = CASE
                            WHEN excluded.modified_at IS NULL
                            THEN annotations.modified_at
                            WHEN annotations.modified_at IS NULL
                              OR excluded.modified_at >= annotations.modified_at
                            THEN excluded.modified_at
                            ELSE annotations.modified_at
                          END,
                          source = excluded.source,
                          book_source = excluded.book_source
                        """,
                        [
                            .text(annotation.id), .text(annotation.asin),
                            .text(annotation.kind.rawValue),
                            .text(annotation.provenance.rawValue),
                            annotation.start.map { .text($0) } ?? .null,
                            annotation.end.map { .text($0) } ?? .null,
                            annotation.text.map { .text($0) } ?? .null,
                            annotation.note.map { .text($0) } ?? .null,
                            annotation.color.map { .text($0) } ?? .null,
                            annotation.createdAt.map {
                                .real($0.timeIntervalSince1970)
                            } ?? .null,
                            annotation.modifiedAt.map {
                                .real($0.timeIntervalSince1970)
                            } ?? .null,
                            .text(annotation.sources.first ?? "Kindle"),
                            .real(timestamp),
                            .text(annotation.bookSource.rawValue),
                        ])
                    for source in annotation.sources {
                        try database.execute(
                            """
                            INSERT OR IGNORE INTO annotation_sources
                            (annotation_id, source, source_id, seen_at)
                            VALUES (?, ?, ?, ?)
                            """,
                            [
                                .text(annotation.id), .text(source),
                                .text(annotation.id), .real(timestamp),
                            ])
                    }
                }
                try database.execute(
                    """
                    INSERT INTO meta (key, value) VALUES ('last_import', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    [.text(ISO8601DateFormatter().string(from: now))])
            }
            return ImportResult(
                books: books.count,
                annotations: annotations.count,
                userAnnotations: annotations.filter {
                    $0.provenance == .user
                }.count,
                importedAt: now)
        }
    }

    // MARK: - Books

    public func books() throws -> [Book] {
        try queue.sync {
            let counts = try database.query(
                """
                SELECT asin, COUNT(*) AS total,
                       SUM(CASE WHEN provenance = 'user' THEN 1 ELSE 0 END)
                       AS mine
                FROM annotations GROUP BY asin
                """)
            var countMap: [String: (Int, Int)] = [:]
            for row in counts {
                guard let asin = row.string("asin") else { continue }
                countMap[asin] = (
                    Int(row.int("total") ?? 0),
                    Int(row.int("mine") ?? 0)
                )
            }
            let rows = try database.query(
                """
                SELECT asin, title, author, book_type, read_state, last_view,
                       current_position, max_position, downloaded, source,
                       progress
                FROM books
                ORDER BY (last_view IS NULL), last_view DESC,
                         title COLLATE NOCASE
                """)
            return rows.compactMap { row in
                guard let asin = row.string("asin") else { return nil }
                let counts = countMap[asin] ?? (0, 0)
                return Book(
                    asin: asin,
                    title: row.string("title") ?? "Untitled",
                    author: row.string("author") ?? "",
                    bookType: Int(row.int("book_type") ?? 0),
                    readState: Int(row.int("read_state") ?? 0),
                    lastView: row.double("last_view").map {
                        Date(timeIntervalSince1970: $0)
                    },
                    currentPosition: row.string("current_position"),
                    maxPosition: row.string("max_position"),
                    downloaded: (row.int("downloaded") ?? 0) == 1,
                    annotationCount: counts.0,
                    userAnnotationCount: counts.1,
                    source: BookSource(
                        rawValue: row.string("source") ?? "") ?? .kindle,
                    progress: row.double("progress"))
            }
        }
    }

    // MARK: - Annotations

    public func annotations(
        asin: String? = nil,
        provenance: AnnotationProvenance? = nil,
        search: String? = nil,
        source: BookSource? = nil
    ) throws -> [Annotation] {
        try queue.sync {
            var sql = """
                SELECT a.id, a.asin, a.kind, a.provenance, a.start_pos,
                       a.end_pos, a.text, a.note, a.color, a.created_at,
                       a.modified_at, a.source, a.book_source,
                       COALESCE(b.title, '') AS book_title
                FROM annotations a
                LEFT JOIN books b ON b.rowid = (
                    SELECT rowid FROM books
                    WHERE asin = a.asin COLLATE NOCASE
                    ORDER BY (asin = a.asin) DESC, rowid LIMIT 1)
                WHERE 1 = 1
                """
            var bindings: [SQLValue] = []
            if let asin {
                sql += " AND a.asin = ?"
                bindings.append(.text(asin))
            }
            if let provenance {
                sql += " AND a.provenance = ?"
                bindings.append(.text(provenance.rawValue))
            }
            if let source {
                sql += " AND a.book_source = ?"
                bindings.append(.text(source.rawValue))
            }
            if let search, !search.isEmpty {
                sql +=
                    " AND (a.text LIKE ? OR a.note LIKE ? OR b.title LIKE ?)"
                let pattern = "%\(search)%"
                bindings.append(contentsOf: [
                    .text(pattern), .text(pattern), .text(pattern),
                ])
            }
            sql += " ORDER BY a.created_at DESC, a.asin, a.start_pos"
            let rows = try database.query(sql, bindings)
            // Multi-source provenance lives beside the annotation; reading
            // only the legacy column loses every source but one.
            let sourceRows = try database.query(
                """
                SELECT annotation_id, source FROM annotation_sources
                ORDER BY annotation_id, source
                """)
            var sourcesByAnnotation: [String: [String]] = [:]
            for sourceRow in sourceRows {
                guard let identifier = sourceRow.string("annotation_id"),
                    let name = sourceRow.string("source")
                else { continue }
                sourcesByAnnotation[identifier, default: []].append(name)
            }
            return rows.compactMap { row in
                guard let identifier = row.string("id"),
                    let asin = row.string("asin"),
                    let kind = AnnotationKind(
                        rawValue: row.string("kind") ?? ""),
                    let provenance = AnnotationProvenance(
                        rawValue: row.string("provenance") ?? "")
                else { return nil }
                return Annotation(
                    id: identifier,
                    asin: asin,
                    bookTitle: row.string("book_title") ?? "",
                    kind: kind,
                    provenance: provenance,
                    start: row.string("start_pos"),
                    end: row.string("end_pos"),
                    text: row.string("text"),
                    note: row.string("note"),
                    color: row.string("color"),
                    createdAt: row.double("created_at").map {
                        Date(timeIntervalSince1970: $0)
                    },
                    modifiedAt: row.double("modified_at").map {
                        Date(timeIntervalSince1970: $0)
                    },
                    sources: sourcesByAnnotation[identifier]
                        ?? [row.string("source") ?? "Kindle"],
                    bookSource: BookSource(
                        rawValue: row.string("book_source") ?? "")
                        ?? .kindle)
            }
        }
    }

    // MARK: - History

    public func sessions() throws -> [ReadingSession] {
        try queue.sync {
            let rows = try database.query(
                """
                SELECT s.id, s.asin, COALESCE(b.title, '') AS book_title,
                       s.started_at, s.ended_at,
                       COUNT(p.id) AS page_count
                FROM sessions s
                LEFT JOIN books b ON b.rowid = (
                    SELECT rowid FROM books
                    WHERE asin = s.asin COLLATE NOCASE
                    ORDER BY (asin = s.asin) DESC, rowid LIMIT 1)
                LEFT JOIN page_observations p ON p.session_id = s.id
                GROUP BY s.id
                ORDER BY s.started_at DESC
                """)
            return rows.compactMap { row in
                guard let identifier = row.int("id"),
                    let asin = row.string("asin"),
                    let started = row.double("started_at"),
                    let ended = row.double("ended_at")
                else { return nil }
                return ReadingSession(
                    id: identifier,
                    asin: asin,
                    bookTitle: row.string("book_title") ?? "",
                    startedAt: Date(timeIntervalSince1970: started),
                    endedAt: Date(timeIntervalSince1970: ended),
                    pageCount: Int(row.int("page_count") ?? 0))
            }
        }
    }

    public func observations(asin: String? = nil) throws -> [PageObservation] {
        try queue.sync {
            var sql = """
                SELECT id, session_id, asin, text, observed_at
                FROM page_observations
                """
            var bindings: [SQLValue] = []
            if let asin {
                sql += " WHERE asin = ?"
                bindings.append(.text(asin))
            }
            sql += " ORDER BY observed_at DESC LIMIT 500"
            let rows = try database.query(sql, bindings)
            return rows.compactMap { row in
                guard let identifier = row.int("id"),
                    let session = row.int("session_id"),
                    let asin = row.string("asin"),
                    let text = row.string("text"),
                    let observed = row.double("observed_at")
                else { return nil }
                return PageObservation(
                    id: identifier,
                    sessionID: session,
                    asin: asin,
                    text: text,
                    observedAt: Date(timeIntervalSince1970: observed))
            }
        }
    }

    @discardableResult
    public func recordPage(
        asin: String, page: Int?, text: String, at date: Date = Date()
    ) throws -> Bool {
        try queue.sync {
            let timestamp = date.timeIntervalSince1970
            let cutoff = timestamp - 300
            var inserted = false
            // A session create plus its page row plus the timestamp update is
            // one logical write; a failure halfway would leave a session with
            // no observation.
            try database.transaction {
                let existing = try database.query(
                    """
                    SELECT id FROM sessions
                    WHERE asin = ? AND ended_at >= ? AND ended_at <= ?
                    ORDER BY ended_at DESC LIMIT 1
                    """,
                    [.text(asin), .real(cutoff), .real(timestamp)])
                let sessionID: Int64
                if let identifier = existing.first?.int("id") {
                    sessionID = identifier
                } else {
                    try database.execute(
                        """
                        INSERT INTO sessions (asin, started_at, ended_at)
                        VALUES (?, ?, ?)
                        """,
                        [.text(asin), .real(timestamp), .real(timestamp)])
                    sessionID = database.lastInsertRowID
                }
                let last = try database.query(
                    """
                    SELECT text FROM page_observations
                    WHERE session_id = ? ORDER BY id DESC LIMIT 1
                    """,
                    [.integer(sessionID)])
                if last.first?.string("text") == text {
                    try database.execute(
                        "UPDATE sessions SET ended_at = ? WHERE id = ?",
                        [.real(timestamp), .integer(sessionID)])
                    return
                }
                try database.execute(
                    """
                    INSERT OR IGNORE INTO page_observations
                    (session_id, asin, page, text, observed_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .integer(sessionID), .text(asin),
                        page.map { .integer(Int64($0)) } ?? .null,
                        .text(text), .real(timestamp),
                    ])
                // INSERT OR IGNORE can silently keep a duplicate. Read
                // changes() before the session UPDATE overwrites it: report
                // whether a row was actually added, not that SQL ran.
                inserted =
                    (try database.query("SELECT changes() AS n")
                        .first?.int("n") ?? 0) > 0
                try database.execute(
                    "UPDATE sessions SET ended_at = ? WHERE id = ?",
                    [.real(timestamp), .integer(sessionID)])
            }
            return inserted
        }
    }

    // MARK: - AI notes and captures

    /// Save an answer, optionally linked to its persisted turn.
    ///
    /// One row per turn: Save Note and Add to Cards share it. `markCard`
    /// nil preserves the existing card state, true makes it a card, false/remove
    /// is `removeCard(turnID:)`.
    @discardableResult
    public func saveAISNote(
        asin: String?, position: String?, kind: String, prompt: String,
        answer: String, provider: String, source: BookSource? = nil,
        turnID: Int64? = nil, markCard: Bool? = nil
    ) throws -> Int64 {
        try queue.sync {
            let now = Date().timeIntervalSince1970
            var savedID: Int64 = 0
            try database.transaction {
                if let turnID {
                    let turn = try database.query(
                        """
                        SELECT c.book_key FROM conversation_turns t
                        JOIN conversations c ON c.id = t.conversation_id
                        WHERE t.id = ? LIMIT 1
                        """, [.integer(turnID)])
                    guard let turnKey = turn.first?.string("book_key"),
                        !turnKey.isEmpty
                    else {
                        throw AICardError.missingTurn(turnID)
                    }
                    // A caller may have captured the book key before the
                    // conversation was re-filed. The turn's current key is
                    // the only one that cannot undo that migration.
                    let filingASIN = ConversationFiling.canonical(turnKey)
                    if let existing = try database.query(
                        "SELECT id FROM ai_notes WHERE turn_id = ? LIMIT 1",
                        [.integer(turnID)]).first?.int("id")
                    {
                        let cardFlag: SQLValue =
                            markCard.map { $0 ? .integer(1) : .integer(0) }
                            ?? .null
                        let noteASIN = SQLValue.text(filingASIN)
                        let notePosition: SQLValue =
                            position.map { .text($0) } ?? .null
                        let noteSource: SQLValue =
                            source.map { .text($0.rawValue) } ?? .null
                        let values: [SQLValue] = [
                            noteASIN, notePosition, .text(kind),
                            .text(prompt), .text(answer), .text(provider),
                            noteSource, cardFlag, cardFlag, .real(now),
                            .integer(existing),
                        ]
                        try database.execute(
                            """
                            UPDATE ai_notes SET asin = ?, position = ?,
                              kind = ?, prompt = ?, answer = ?, provider = ?,
                              book_source = ?,
                              carded_at = CASE
                                WHEN ? IS NULL THEN carded_at
                                WHEN ? THEN ? ELSE NULL END
                            WHERE id = ?
                            """, values)
                        savedID = existing
                        return
                    }
                    try database.execute(
                        """
                        INSERT INTO ai_notes
                        (asin, position, kind, prompt, answer, provider,
                         created_at, book_source, turn_id, carded_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(filingASIN),
                            position.map { .text($0) } ?? .null, .text(kind),
                            .text(prompt), .text(answer), .text(provider),
                            .real(now),
                            source.map { .text($0.rawValue) } ?? .null,
                            .integer(turnID),
                            markCard == true ? .real(now) : .null,
                        ])
                    savedID = database.lastInsertRowID
                    return
                }
                guard markCard != true else {
                    throw AICardError.unlinkedCard
                }
                try database.execute(
                    """
                    INSERT INTO ai_notes
                    (asin, position, kind, prompt, answer, provider,
                     created_at, book_source, turn_id, carded_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                    """,
                    [
                        asin.map { .text($0) } ?? .null,
                        position.map { .text($0) } ?? .null, .text(kind),
                        .text(prompt), .text(answer), .text(provider),
                        .real(now),
                        source.map { .text($0.rawValue) } ?? .null,
                    ])
                savedID = database.lastInsertRowID
            }
            return savedID
        }
    }

    public func removeCard(turnID: Int64) throws {
        try queue.sync {
            try database.execute(
                "UPDATE ai_notes SET carded_at = NULL WHERE turn_id = ?",
                [.integer(turnID)])
        }
    }

    /// Turn IDs that are currently cards in one conversation.
    public func cardTurnIDs(conversationID: Int64) throws -> Set<Int64> {
        try queue.sync {
            let rows = try database.query(
                """
                SELECT n.turn_id FROM ai_notes n
                JOIN conversation_turns t ON t.id = n.turn_id
                WHERE n.carded_at IS NOT NULL AND t.conversation_id = ?
                """, [.integer(conversationID)])
            return Set(rows.compactMap { $0.int("turn_id") })
        }
    }

    /// Cards joined to their persisted turn and conversation. A card whose
    /// turn is gone is not returned.
    /// The total cards visible through `aiCards`, without loading answers.
    public func aiCardCount() throws -> Int {
        try queue.sync {
            let rows = try database.query(
                """
                SELECT COUNT(*) AS count
                FROM ai_notes n
                JOIN conversation_turns t ON t.id = n.turn_id
                JOIN conversations c ON c.id = t.conversation_id
                WHERE n.carded_at IS NOT NULL
                """)
            return Int(rows.first?.int("count") ?? 0)
        }
    }

    public func aiCards(
        bookKeys: Set<String>? = nil, limit: Int? = nil
    ) throws -> [AICard] {
        try queue.sync {
            var sql = """
                SELECT n.id AS note_id, n.carded_at AS carded_at,
                       t.id AS turn_id, t.conversation_id, t.action,
                       t.question, t.answer, t.provider, t.context_json,
                       t.created_at AS turn_created_at,
                       c.book_key, c.book_title AS conversation_title,
                       c.book_source AS conversation_source,
                       b.title AS book_title, b.source AS book_source
                FROM ai_notes n
                JOIN conversation_turns t ON t.id = n.turn_id
                JOIN conversations c ON c.id = t.conversation_id
                LEFT JOIN books b ON b.rowid = (
                    SELECT rowid FROM books
                    WHERE asin = c.book_key COLLATE NOCASE
                    ORDER BY (asin = c.book_key) DESC, rowid LIMIT 1)
                WHERE n.carded_at IS NOT NULL
                """
            var bindings: [SQLValue] = []
            if let bookKeys {
                guard !bookKeys.isEmpty else { return [] }
                let keys = Array(bookKeys).sorted()
                let placeholders = Array(repeating: "?", count: keys.count)
                    .joined(separator: ",")
                sql += " AND c.book_key COLLATE NOCASE IN (\(placeholders))"
                bindings = keys.map { .text($0) }
            }
            sql += " ORDER BY n.carded_at DESC, n.id DESC"
            if let limit {
                sql += " LIMIT ?"
                bindings.append(.integer(Int64(max(0, limit))))
            }
            return try database.query(sql, bindings).compactMap { row in
                guard let noteID = row.int("note_id"),
                    let turnID = row.int("turn_id"),
                    let conversationID = row.int("conversation_id"),
                    let cardedAt = row.double("carded_at")
                else { return nil }
                let contextJSON = row.string("context_json") ?? "{}"
                let context =
                    (try? JSONDecoder().decode(
                        AIContext.self, from: Data(contextJSON.utf8)))
                    ?? .empty
                let conversationTitle = row.string("conversation_title") ?? ""
                let bookTitle = conversationTitle.isEmpty
                    ? row.string("book_title") ?? "" : conversationTitle
                let sourceValue =
                    row.string("conversation_source")
                    ?? row.string("book_source")
                return AICard(
                    id: noteID, turnID: turnID,
                    conversationID: conversationID,
                    action: row.string("action").flatMap(
                        AIAction.init(rawValue:)),
                    question: row.string("question") ?? "",
                    answer: row.string("answer") ?? "",
                    provider: row.string("provider") ?? "",
                    context: context,
                    bookKey: row.string("book_key") ?? "",
                    bookTitle: bookTitle,
                    bookSource: sourceValue.flatMap(
                        BookSource.init(rawValue:)),
                    createdAt: Date(
                        timeIntervalSince1970:
                            row.double("turn_created_at") ?? 0),
                    cardedAt: Date(timeIntervalSince1970: cardedAt))
            }
        }
    }

    public func aiNotes(asin: String? = nil) throws -> [SavedAINote] {
        try queue.sync {
            var sql = """
                SELECT n.*, COALESCE(b.title, '') AS book_title,
                       COALESCE(n.book_source, b.source) AS resolved_source
                FROM ai_notes n LEFT JOIN books b ON b.rowid = (
                    SELECT rowid FROM books
                    WHERE asin = n.asin COLLATE NOCASE
                    ORDER BY (asin = n.asin) DESC, rowid LIMIT 1)
                """
            var bindings: [SQLValue] = []
            if let asin {
                sql += " WHERE n.asin = ? COLLATE NOCASE"
                bindings.append(.text(asin))
            }
            sql += " ORDER BY n.created_at DESC, n.id DESC"
            return try database.query(sql, bindings).map { row in
                SavedAINote(
                    id: row.int("id") ?? 0, asin: row.string("asin"),
                    bookTitle: row.string("book_title") ?? "",
                    bookSource: row.string("resolved_source").flatMap(
                        BookSource.init(rawValue:)),
                    position: row.string("position"),
                    kind: row.string("kind") ?? "",
                    prompt: row.string("prompt") ?? "",
                    answer: row.string("answer") ?? "",
                    provider: row.string("provider") ?? "",
                    createdAt: Date(
                        timeIntervalSince1970: row.double("created_at") ?? 0),
                    turnID: row.int("turn_id"),
                    cardedAt: row.double("carded_at").map {
                        Date(timeIntervalSince1970: $0)
                    })
            }
        }
    }

    // MARK: - Conversations

    public func conversation(id: Int64) throws -> Conversation? {
        try queue.sync {
            try database.query(
                "SELECT * FROM conversations WHERE id = ? LIMIT 1",
                [.integer(id)]).first.map(Self.conversation(from:))
        }
    }

    public func latestConversation(bookKey: String) throws -> Conversation? {
        try queue.sync {
            let rows = try database.query(
                """
                SELECT * FROM conversations
                WHERE book_key = ?
                ORDER BY updated_at DESC, id DESC
                LIMIT 1
                """, [.text(bookKey)])
            return rows.first.map(Self.conversation(from:))
        }
    }

    public func createConversation(
        bookKey: String, bookTitle: String, bookSource: BookSource?
    ) throws -> Conversation {
        try createConversation(
            bookKey: bookKey, bookTitle: bookTitle, bookSource: bookSource,
            turns: [])
    }

    /// Creates a conversation and its turns in one transaction.
    ///
    /// Promoting session-only turns must not leave a conversation with only
    /// the first few turns when a later insert fails.
    public func createConversation(
        bookKey: String, bookTitle: String, bookSource: BookSource?,
        turns: [NewConversationTurn]
    ) throws -> Conversation {
        try queue.sync {
            let now = Date().timeIntervalSince1970
            var id: Int64 = 0
            try database.transaction {
                try database.execute(
                    """
                    INSERT INTO conversations
                    (book_key, book_title, book_source, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .text(bookKey), .text(bookTitle),
                        bookSource.map { .text($0.rawValue) } ?? .null,
                        .real(now), .real(now),
                    ])
                id = database.lastInsertRowID
                for turn in turns {
                    try insertTurn(
                        conversationID: id, action: turn.action,
                        question: turn.question, answer: turn.answer,
                        provider: turn.provider, prompt: turn.prompt,
                        context: turn.context, createdAt: now)
                }
            }
            return Conversation(
                id: id, bookKey: bookKey, bookTitle: bookTitle,
                bookSource: bookSource,
                createdAt: Date(timeIntervalSince1970: now),
                updatedAt: Date(timeIntervalSince1970: now))
        }
    }

    @discardableResult
    public func appendConversationTurn(
        conversationID: Int64, action: AIAction, question: String,
        answer: String, provider: String, prompt: String, context: AIContext
    ) throws -> ConversationTurn {
        return try queue.sync {
            let now = Date().timeIntervalSince1970
            var turnID: Int64 = 0
            try database.transaction {
                // A turn without its parent would be invisible and
                // unreachable; refuse it rather than leaving an orphan.
                let parent = try database.query(
                    "SELECT 1 FROM conversations WHERE id = ? LIMIT 1",
                    [.integer(conversationID)])
                guard !parent.isEmpty else {
                    throw ConversationArchiveError.missingConversation(
                        conversationID)
                }
                turnID = try insertTurn(
                    conversationID: conversationID, action: action,
                    question: question, answer: answer, provider: provider,
                    prompt: prompt, context: context, createdAt: now)
                try database.execute(
                    "UPDATE conversations SET updated_at = ? WHERE id = ?",
                    [.real(now), .integer(conversationID)])
            }
            return ConversationTurn(
                id: turnID, conversationID: conversationID, action: action,
                question: question, answer: answer, provider: provider,
                prompt: prompt, context: context,
                createdAt: Date(timeIntervalSince1970: now))
        }
    }

    /// Insert one turn row inside the caller's transaction. Both the
    /// multi-turn create and the single append persist the same columns.
    @discardableResult
    private func insertTurn(
        conversationID: Int64, action: AIAction, question: String,
        answer: String, provider: String, prompt: String,
        context: AIContext, createdAt: TimeInterval
    ) throws -> Int64 {
        let encoded = try JSONEncoder().encode(context)
        let contextJSON = String(decoding: encoded, as: UTF8.self)
        try database.execute(
            """
            INSERT INTO conversation_turns
            (conversation_id, action, question, answer, provider,
             prompt, context_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .integer(conversationID), .text(action.rawValue),
                .text(question), .text(answer), .text(provider),
                .text(prompt), .text(contextJSON), .real(createdAt),
            ])
        return database.lastInsertRowID
    }

    public func conversationTurns(
        conversationID: Int64
    ) throws -> [ConversationTurn] {
        try queue.sync {
            try database.query(
                """
                SELECT * FROM conversation_turns
                WHERE conversation_id = ?
                ORDER BY id
                """, [.integer(conversationID)]
            ).compactMap(Self.turn(from:))
        }
    }

    public func conversations(
        bookKey: String? = nil
    ) throws -> [ConversationSummary] {
        try queue.sync {
            if let bookKey {
                return try summaries(
                    whereClause: " WHERE c.book_key = ?",
                    bindings: [.text(bookKey)])
            }
            return try summaries(whereClause: "", bindings: [])
        }
    }

    /// Summaries for a known set of keys, so a book's Chats tab does not scan
    /// every conversation in the archive.
    public func conversations(
        bookKeys: Set<String>, includeLastAnswer: Bool = true
    ) throws -> [ConversationSummary] {
        guard !bookKeys.isEmpty else { return [] }
        let keys = Array(bookKeys).sorted()
        let placeholders = Array(repeating: "?", count: keys.count)
            .joined(separator: ",")
        return try queue.sync {
            // Keys stored before canonical casing carry mixed case; a
            // case-insensitive match keeps them visible without scanning the
            // whole table.
            try summaries(
                whereClause:
                    " WHERE c.book_key COLLATE NOCASE IN (\(placeholders))",
                bindings: keys.map { .text($0) },
                includeLastAnswer: includeLastAnswer)
        }
    }

    private func summaries(
        whereClause: String, bindings: [SQLValue],
        includeLastAnswer: Bool = true
    ) throws -> [ConversationSummary] {
        // A caller that shows only the first question and turn count does not
        // need every conversation's last answer read from the table.
        let lastAnswer =
            includeLastAnswer
            ? """
            , (SELECT answer FROM conversation_turns t
               WHERE t.conversation_id = c.id
               ORDER BY t.id DESC LIMIT 1) AS last_answer
            """
            : ""
        let sql = """
            SELECT c.*,
                (SELECT COUNT(*) FROM conversation_turns t
                 WHERE t.conversation_id = c.id) AS turn_count,
                (SELECT question FROM conversation_turns t
                 WHERE t.conversation_id = c.id
                 ORDER BY t.id LIMIT 1) AS first_question,
                (SELECT action FROM conversation_turns t
                 WHERE t.conversation_id = c.id
                 ORDER BY t.id LIMIT 1) AS first_action\(lastAnswer)
            FROM conversations c
            \(whereClause)
            ORDER BY c.updated_at DESC, c.id DESC
            """
        return try database.query(sql, bindings).map { row in
            let question = row.string("first_question") ?? ""
            let action = row.string("first_action") ?? ""
            let firstQuestion = TurnLabel.prompt(
                question: question, action: action)
            return ConversationSummary(
                conversation: Self.conversation(from: row),
                turnCount: Int(row.int("turn_count") ?? 0),
                firstQuestion: firstQuestion,
                lastAnswer: row.string("last_answer"))
        }
    }

    public func conversationCounts() throws -> [String: Int] {
        try queue.sync {
            let rows = try database.query(
                """
                SELECT c.book_key AS book_key, COUNT(t.id) AS turns
                FROM conversations c
                LEFT JOIN conversation_turns t ON t.conversation_id = c.id
                GROUP BY c.book_key
                """)
            var counts: [String: Int] = [:]
            for row in rows {
                guard let key = row.string("book_key") else { continue }
                counts[key] = Int(row.int("turns") ?? 0)
            }
            return counts
        }
    }

    /// Moves a book's conversations to a stronger key.
    ///
    /// Rows are updated in place, so no thread is duplicated and none is
    /// lost; the operation is idempotent. A blank stored title or source is
    /// filled from the improved identity, and an existing one is left alone.
    public func migrateConversations(
        from oldKey: String, to newKey: String, title: String? = nil,
        source: BookSource? = nil
    ) throws {
        guard !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey else {
            return
        }
        try queue.sync {
            try database.transaction {
                try migrateRows(
                    selector: "book_key = ?", bindings: [.text(oldKey)],
                    metadataSelector: "book_key = ?",
                    metadataBindings: [.text(newKey)],
                    to: newKey, title: title, source: source)
                // A linked note is a card or saved answer for a turn; it
                // follows the conversation's filing key so it cannot stay
                // under the old book after the chat moves.
                try database.execute(
                    """
                    UPDATE ai_notes SET asin = ?
                    WHERE turn_id IN (
                        SELECT t.id FROM conversation_turns t
                        JOIN conversations c ON c.id = t.conversation_id
                        WHERE c.book_key = ?
                    )
                    """, [.text(newKey), .text(newKey)])
            }
        }
    }

    /// Files one conversation under a stronger key. Unlike the key-wide
    /// migration, this cannot move another edition that shares a title key.
    public func migrateConversation(
        id: Int64, to newKey: String, title: String? = nil,
        source: BookSource? = nil
    ) throws {
        guard !newKey.isEmpty else { return }
        try queue.sync {
            try database.transaction {
                try migrateRows(
                    selector: "id = ?", bindings: [.integer(id)],
                    metadataSelector: "id = ?", metadataBindings: [.integer(id)],
                    to: newKey, title: title, source: source)
                try database.execute(
                    """
                    UPDATE ai_notes SET asin = ?
                    WHERE turn_id IN (
                        SELECT id FROM conversation_turns
                        WHERE conversation_id = ?
                    )
                    """, [.text(newKey), .integer(id)])
            }
        }
    }

    /// Move rows matched by `selector` to `newKey`, then fill a blank title
    /// and a missing source for the rows `metadataSelector` names. The two
    /// selectors differ on purpose: a key-wide migration fills every row now
    /// under the new key, while a single-conversation move fills only itself.
    private func migrateRows(
        selector: String, bindings: [SQLValue],
        metadataSelector: String, metadataBindings: [SQLValue],
        to newKey: String, title: String?, source: BookSource?
    ) throws {
        try database.execute(
            "UPDATE conversations SET book_key = ? WHERE \(selector)",
            [.text(newKey)] + bindings)
        if let title, !title.isEmpty {
            try database.execute(
                """
                UPDATE conversations SET book_title = ?
                WHERE \(metadataSelector)
                  AND (book_title IS NULL OR book_title = '')
                """,
                [.text(title)] + metadataBindings)
        }
        if let source {
            try database.execute(
                """
                UPDATE conversations SET book_source = ?
                WHERE \(metadataSelector) AND book_source IS NULL
                """,
                [.text(source.rawValue)] + metadataBindings)
        }
    }

    public enum AICardError: Error, CustomStringConvertible, Sendable {
        case missingTurn(Int64)
        case unlinkedCard

        public var description: String {
            switch self {
            case .missingTurn(let id):
                "No persisted turn \(id) exists for this card."
            case .unlinkedCard:
                "A card needs a persisted conversation turn."
            }
        }
    }

    public enum ConversationArchiveError: Error, CustomStringConvertible,
        Sendable
    {
        case missingConversation(Int64)

        public var description: String {
            switch self {
            case .missingConversation(let id):
                "No conversation \(id) exists."
            }
        }
    }

    private static func conversation(from row: Row) -> Conversation {
        Conversation(
            id: row.int("id") ?? 0,
            bookKey: row.string("book_key") ?? "",
            bookTitle: row.string("book_title") ?? "",
            bookSource: row.string("book_source").flatMap(
                BookSource.init(rawValue:)),
            createdAt: Date(
                timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(
                timeIntervalSince1970: row.double("updated_at") ?? 0))
    }

    private static func turn(from row: Row) -> ConversationTurn? {
        guard let rawAction = row.string("action"),
            let action = AIAction(rawValue: rawAction)
        else { return nil }
        let contextJSON = row.string("context_json") ?? "{}"
        let context =
            (try? JSONDecoder().decode(
                AIContext.self, from: Data(contextJSON.utf8))) ?? .empty
        return ConversationTurn(
            id: row.int("id") ?? 0,
            conversationID: row.int("conversation_id") ?? 0,
            action: action,
            question: row.string("question") ?? "",
            answer: row.string("answer") ?? "",
            provider: row.string("provider") ?? "",
            prompt: row.string("prompt") ?? "",
            context: context,
            createdAt: Date(
                timeIntervalSince1970: row.double("created_at") ?? 0))
    }

    @discardableResult
    public func recordCapture(
        asin: String?, title: String, directory: String, pageCount: Int,
        pdfPath: String?, state: String, source: String = "kindle",
        identityConfidence: String? = nil, termination: String? = nil,
        warnings: [String] = []
    ) throws -> Int64 {
        let warningData = try JSONSerialization.data(
            withJSONObject: warnings, options: [])
        let warningText = String(decoding: warningData, as: UTF8.self)
        return try queue.sync {
            try database.execute(
                """
                INSERT INTO captures
                (asin, title, directory, page_count, pdf_path, created_at,
                 state, source, identity_confidence, termination, warnings)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    asin.map { .text($0) } ?? .null, .text(title),
                    .text(directory), .integer(Int64(pageCount)),
                    pdfPath.map { .text($0) } ?? .null,
                    .real(Date().timeIntervalSince1970), .text(state),
                    .text(source),
                    identityConfidence.map { .text($0) } ?? .null,
                    termination.map { .text($0) } ?? .null,
                    .text(warningText),
                ])
            return database.lastInsertRowID
        }
    }

    public func captures() throws -> [CaptureRecord] {
        try queue.sync {
            let rows = try database.query(
                """
                SELECT id, COALESCE(asin, '') AS asin, title, directory,
                       page_count, pdf_path, created_at, state,
                       COALESCE(source, 'kindle') AS source,
                       identity_confidence, termination, warnings
                FROM captures ORDER BY created_at DESC
                """)
            return rows.compactMap { row in
                guard let identifier = row.int("id") else { return nil }
                let warnings: [String]
                if let data = row.string("warnings")?.data(using: .utf8),
                    let decoded = try? JSONSerialization.jsonObject(
                        with: data) as? [String]
                {
                    warnings = decoded
                } else {
                    warnings = []
                }
                return CaptureRecord(
                    id: identifier,
                    asin: row.string("asin") ?? "",
                    title: row.string("title") ?? "",
                    directory: row.string("directory") ?? "",
                    pageCount: Int(row.int("page_count") ?? 0),
                    pdfPath: row.string("pdf_path"),
                    createdAt: Date(
                        timeIntervalSince1970: row.double("created_at") ?? 0),
                    state: row.string("state") ?? "",
                    source: row.string("source") ?? "kindle",
                    identityConfidence: row.string("identity_confidence"),
                    termination: row.string("termination"),
                    warnings: warnings)
            }
        }
    }

    // MARK: - Meta and counts

    public func meta(_ key: String) -> String? {
        try? queue.sync {
            try database.query(
                "SELECT value FROM meta WHERE key = ?", [.text(key)]
            ).first?.string("value")
        }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try queue.sync {
            try database.execute(
                """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                [.text(key), .text(value)])
        }
    }

    public func counts() throws -> ArchiveCounts {
        try queue.sync {
            func scalar(_ sql: String) throws -> Int {
                Int(try database.query(sql).first?.int("value") ?? 0)
            }
            return ArchiveCounts(
                books: try scalar("SELECT COUNT(*) AS value FROM books"),
                annotations: try scalar(
                    "SELECT COUNT(*) AS value FROM annotations"),
                userAnnotations: try scalar(
                    """
                    SELECT COUNT(*) AS value FROM annotations
                    WHERE provenance = 'user'
                    """),
                sessions: try scalar(
                    "SELECT COUNT(*) AS value FROM sessions"),
                captures: try scalar(
                    "SELECT COUNT(*) AS value FROM captures"))
        }
    }

    // MARK: - Export

    public func exportAnnotations(
        to url: URL, format: AnnotationExportFormat, asin: String? = nil,
        provenance: AnnotationProvenance? = nil, source: BookSource? = nil
    ) throws {
        let rows = try annotations(
            asin: asin, provenance: provenance, search: nil, source: source)
        try exportAnnotations(rows, to: url, format: format)
    }

    /// Exports an immutable browsing snapshot; never re-runs broader filters.
    public func exportAnnotations(
        _ rows: [Annotation], to url: URL, format: AnnotationExportFormat
    ) throws {
        let text: String
        switch format {
        case .json:
            let objects = rows.map { annotation -> [String: Any] in
                [
                    "id": annotation.id,
                    "asin": annotation.asin,
                    "book": annotation.bookTitle,
                    "book_source": annotation.bookSource.rawValue,
                    "kind": annotation.kind.rawValue,
                    "provenance": annotation.provenance.rawValue,
                    "start": annotation.start ?? "",
                    "end": annotation.end ?? "",
                    "text": annotation.text ?? "",
                    "note": annotation.note ?? "",
                    "color": annotation.color ?? "",
                    "created_at": annotation.createdAt.map {
                        ISO8601DateFormatter().string(from: $0)
                    } ?? "",
                    "modified_at": annotation.modifiedAt.map {
                        ISO8601DateFormatter().string(from: $0)
                    } ?? "",
                ]
            }
            let data = try JSONSerialization.data(
                withJSONObject: objects,
                options: [.prettyPrinted, .sortedKeys])
            text = String(decoding: data, as: UTF8.self)
        case .markdown:
            var lines = [
                "# Tsundoku annotations", "",
                "| Book | Source | Kind | Provenance | Text | Position |",
                "|---|---|---|---|---|---|",
            ]
            for annotation in rows {
                var parts: [String] = []
                if let passage = annotation.passageText {
                    parts.append(passage)
                }
                if let note = annotation.personalNote {
                    parts.append("Note: \(note)")
                }
                let cell =
                    parts.isEmpty
                    ? "Text unavailable in the local store"
                    : parts.joined(separator: " — ")
                lines.append(
                    "| \(escapeMarkdown(annotation.bookTitle)) "
                        + "| \(annotation.bookSource.displayName) "
                        + "| \(annotation.kind.displayName) "
                        + "| \(annotation.provenance.displayName) "
                        + "| \(escapeMarkdown(cell)) "
                        + "| \(escapeMarkdown(annotation.start ?? "")) |")
            }
            text = lines.joined(separator: "\n") + "\n"
        case .csv:
            var lines = [
                "id,asin,book,book_source,kind,provenance,start,end,text,note,color,created_at"
            ]
            for annotation in rows {
                lines.append(
                    [
                        annotation.id, annotation.asin, annotation.bookTitle,
                        annotation.bookSource.rawValue,
                        annotation.kind.rawValue,
                        annotation.provenance.rawValue,
                        annotation.start ?? "", annotation.end ?? "",
                        annotation.text ?? "", annotation.note ?? "",
                        annotation.color ?? "",
                        annotation.createdAt.map {
                            ISO8601DateFormatter().string(from: $0)
                        } ?? "",
                    ].map(csvField).joined(separator: ","))
            }
            text = lines.joined(separator: "\n") + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func escapeMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
