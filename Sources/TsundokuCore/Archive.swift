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
                          note = COALESCE(excluded.note, annotations.note),
                          color = COALESCE(excluded.color, annotations.color),
                          created_at = COALESCE(excluded.created_at,
                                                annotations.created_at),
                          modified_at = COALESCE(excluded.modified_at,
                                                 annotations.modified_at),
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
                    Int(row.int("mine") ?? 0))
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
                LEFT JOIN books b ON b.asin = a.asin
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
                    sources: [row.string("source") ?? "Kindle"],
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
                LEFT JOIN books b ON b.asin = s.asin
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
            let existing = try database.query(
                """
                SELECT id FROM sessions
                WHERE asin = ? AND ended_at >= ?
                ORDER BY ended_at DESC LIMIT 1
                """,
                [.text(asin), .real(cutoff)])
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
                return false
            }
            try database.execute(
                """
                INSERT OR IGNORE INTO page_observations
                (session_id, asin, page, text, observed_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                [
                    .integer(sessionID), .text(asin),
                    page.map { .integer(Int64($0)) } ?? .null, .text(text),
                    .real(timestamp),
                ])
            try database.execute(
                "UPDATE sessions SET ended_at = ? WHERE id = ?",
                [.real(timestamp), .integer(sessionID)])
            return true
        }
    }

    // MARK: - AI notes and captures

    public func saveAISNote(
        asin: String?, position: String?, kind: String, prompt: String,
        answer: String, provider: String
    ) throws {
        try queue.sync {
            try database.execute(
                """
                INSERT INTO ai_notes
                (asin, position, kind, prompt, answer, provider, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    asin.map { .text($0) } ?? .null,
                    position.map { .text($0) } ?? .null, .text(kind),
                    .text(prompt), .text(answer), .text(provider),
                    .real(Date().timeIntervalSince1970),
                ])
        }
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
                // displayText prefers the highlighted text, so a note attached
                // to a highlight would otherwise vanish from the export.
                let note = annotation.note?.trimmingCharacters(
                    in: .whitespacesAndNewlines) ?? ""
                var cell = annotation.displayText
                if !note.isEmpty {
                    cell = cell.isEmpty ? "Note: \(note)"
                        : "\(cell) — Note: \(note)"
                }
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
                "id,asin,book,book_source,kind,provenance,start,end,text,note,color,created_at",
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
            || value.contains("\n")
        {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
