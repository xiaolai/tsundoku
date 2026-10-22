import Foundation

// MARK: - Paths

public struct BooksPaths: Sendable {
    /// `~/Library/Containers/com.apple.iBooksX/Data`
    public let container: URL

    public init(container: URL) {
        self.container = container
    }

    public static func standard() -> BooksPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return BooksPaths(
            container: home.appendingPathComponent(
                "Library/Containers/com.apple.iBooksX/Data"))
    }

    public var documents: URL {
        container.appendingPathComponent("Documents")
    }

    public var bookLibrary: URL? {
        newest(
            in: documents.appendingPathComponent("BKLibrary"),
            prefix: "BKLibrary")
    }

    public var annotationDatabase: URL? {
        newest(
            in: documents.appendingPathComponent("AEAnnotation"),
            prefix: "AEAnnotation")
    }

    public var exists: Bool {
        bookLibrary != nil && annotationDatabase != nil
    }

    private func newest(in directory: URL, prefix: String) -> URL? {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        return entries
            .filter {
                $0.lastPathComponent.hasPrefix(prefix)
                    && $0.pathExtension == "sqlite"
            }
            .sorted { left, right in
                let leftDate =
                    (try? left.resourceValues(
                        forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rightDate =
                    (try? right.resourceValues(
                        forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return leftDate > rightDate
            }
            .first
    }
}

// MARK: - Snapshot

public struct BooksSnapshot: Sendable {
    public let directory: URL
    public let bookLibrary: URL
    public let annotationDatabase: URL

    public static func capture(_ paths: BooksPaths) throws -> BooksSnapshot {
        guard let bookLibrary = paths.bookLibrary,
            let annotationDatabase = paths.annotationDatabase
        else {
            throw BooksReaderError.storeNotFound
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "tsundoku-books-\(UUID().uuidString)")
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let libraryCopy = directory.appendingPathComponent("BKLibrary.sqlite")
        let annotationCopy = directory.appendingPathComponent(
            "AEAnnotation.sqlite")
        try SQLiteSnapshot.copy(bookLibrary, to: libraryCopy)
        try SQLiteSnapshot.copy(annotationDatabase, to: annotationCopy)
        return BooksSnapshot(
            directory: directory,
            bookLibrary: libraryCopy,
            annotationDatabase: annotationCopy)
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Errors

public enum BooksReaderError: Error, CustomStringConvertible {
    case storeNotFound
    case missingTable(String)

    public var description: String {
        switch self {
        case .storeNotFound:
            "Apple Books stores were not found."
        case .missingTable(let table):
            "Apple Books store is missing the \(table) table."
        }
    }
}

// MARK: - Reader

public enum BooksReader {
    public static func readAll(_ paths: BooksPaths) throws
        -> (books: [Book], annotations: [Annotation])
    {
        let snapshot = try BooksSnapshot.capture(paths)
        defer { snapshot.cleanup() }
        let books = try readBooks(snapshot)
        let annotations = try readAnnotations(snapshot, books: books)
        return (books, annotations)
    }

    public static func readBooks(_ snapshot: BooksSnapshot) throws -> [Book] {
        let database = try SQLiteDatabase(
            path: snapshot.bookLibrary.path, readOnly: true)
        let rows = try database.query(
            """
            SELECT ZASSETID, ZTITLE, ZAUTHOR, ZCONTENTTYPE,
                   ZREADINGPROGRESS, ZLASTOPENDATE, ZDATEFINISHED,
                   ZISFINISHED, ZPATH
            FROM ZBKLIBRARYASSET
            """)
        let manager = FileManager.default
        return rows.compactMap { row in
            guard let raw = nonEmpty(row.string("ZASSETID")) else {
                return nil
            }
            let assetID = raw.uppercased()
            let content = Int(row.int("ZCONTENTTYPE") ?? 0)
            let path = nonEmpty(row.string("ZPATH"))
            let finished =
                (row.int("ZISFINISHED") ?? 0) == 1
                || row.double("ZDATEFINISHED") != nil
            return Book(
                asin: assetID,
                title: nonEmpty(row.string("ZTITLE")) ?? "Untitled",
                author: nonEmpty(row.string("ZAUTHOR")) ?? "",
                bookType: content == 1 || content == 3 ? 10 : 0,
                readState: finished ? 1 : 0,
                lastView: DateParsing.coreData(
                    row.double("ZLASTOPENDATE")),
                downloaded: path.map { manager.fileExists(atPath: $0) }
                    ?? false,
                source: .appleBooks,
                progress: row.double("ZREADINGPROGRESS"))
        }
    }

    public static func readAnnotations(
        _ snapshot: BooksSnapshot, books: [Book]
    ) throws -> [Annotation] {
        let database = try SQLiteDatabase(
            path: snapshot.annotationDatabase.path, readOnly: true)
        let rows = try database.query(
            """
            SELECT Z_PK, ZANNOTATIONUUID, ZANNOTATIONASSETID,
                   ZANNOTATIONTYPE, ZANNOTATIONSELECTEDTEXT,
                   ZANNOTATIONNOTE, ZANNOTATIONLOCATION,
                   ZANNOTATIONCREATIONDATE, ZANNOTATIONMODIFICATIONDATE,
                   ZANNOTATIONDELETED
            FROM ZAEANNOTATION
            WHERE COALESCE(ZANNOTATIONDELETED, 0) = 0
            """)
        let titles = titleMap(books)
        return rows.compactMap { row in
            guard
                let rawAsset = nonEmpty(row.string("ZANNOTATIONASSETID"))
            else { return nil }
            let assetID = rawAsset.uppercased()
            let type = Int(row.int("ZANNOTATIONTYPE") ?? 0)
            let selected = nonEmpty(row.string("ZANNOTATIONSELECTEDTEXT"))
            let note = nonEmpty(row.string("ZANNOTATIONNOTE"))
            let kind: AnnotationKind
            switch type {
            case 2:
                kind = .highlight
            case 3:
                kind = .bookmark
            default:
                kind = note == nil ? .position : .note
            }
            let identifier =
                nonEmpty(row.string("ZANNOTATIONUUID"))
                ?? "pk-\(row.int("Z_PK") ?? 0)"
            let location = nonEmpty(row.string("ZANNOTATIONLOCATION"))
            return Annotation(
                id: "applebooks-\(identifier)",
                asin: assetID,
                bookTitle: titles[assetID] ?? "",
                kind: kind,
                provenance: .user,
                start: location,
                text: selected,
                note: note,
                createdAt: DateParsing.coreData(
                    row.double("ZANNOTATIONCREATIONDATE")),
                modifiedAt: DateParsing.coreData(
                    row.double("ZANNOTATIONMODIFICATIONDATE")),
                sources: ["AEAnnotation"],
                bookSource: .appleBooks)
        }
    }

    private static func titleMap(_ books: [Book]) -> [String: String] {
        var result: [String: String] = [:]
        for book in books where result[book.asin] == nil {
            result[book.asin] = book.title
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
