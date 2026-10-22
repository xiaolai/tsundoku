import Foundation

public struct KindlePaths: Sendable {
    public let container: URL

    public init(container: URL) {
        self.container = container
    }

    public static func standard() -> KindlePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return KindlePaths(
            container: home.appendingPathComponent(
                "Library/Containers/com.amazon.Lassen/Data/Library"))
    }

    public var bookData: URL {
        container.appendingPathComponent("Protected/BookData.sqlite")
    }
    public var annotationStorage: URL {
        container.appendingPathComponent("AnnotationStorage")
    }
    public var ksdkDirectory: URL {
        container.appendingPathComponent("KSDK")
    }
    public var whispersync: URL {
        container.appendingPathComponent(
            "Application Support/Whispersync/WSyncDefault.sqlite")
    }
    public var ebooks: URL {
        container.appendingPathComponent("eBooks")
    }

    public var accountAnnotationDB: URL? {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: ksdkDirectory, includingPropertiesForKeys: nil)
        else { return nil }
        for entry in entries
        where entry.lastPathComponent.hasPrefix("amzn1.account.") {
            let database = entry.appendingPathComponent(
                "ksdk_annotation_v1.db")
            if manager.fileExists(atPath: database.path) {
                return database
            }
        }
        return nil
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: bookData.path)
    }
}

public struct KindleSnapshot: Sendable {
    public let directory: URL
    public let bookData: URL
    public let annotationStorage: URL
    public let ksdk: URL?
    public let whispersync: URL
    public let ebooks: URL

    public static func capture(_ paths: KindlePaths) throws
        -> KindleSnapshot
    {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "tsundoku-\(UUID().uuidString)")
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let bookData = directory.appendingPathComponent("BookData.sqlite")
        let annotationStorage = directory.appendingPathComponent(
            "AnnotationStorage")
        let whispersync = directory.appendingPathComponent(
            "WSyncDefault.sqlite")
        try SQLiteSnapshot.copy(paths.bookData, to: bookData)
        try SQLiteSnapshot.copy(paths.annotationStorage, to: annotationStorage)
        try SQLiteSnapshot.copy(paths.whispersync, to: whispersync)
        var ksdk: URL?
        if let source = paths.accountAnnotationDB {
            let destination = directory.appendingPathComponent(
                "ksdk_annotation_v1.db")
            try SQLiteSnapshot.copy(source, to: destination)
            ksdk = destination
        }
        return KindleSnapshot(
            directory: directory,
            bookData: bookData,
            annotationStorage: annotationStorage,
            ksdk: ksdk,
            whispersync: whispersync,
            ebooks: paths.ebooks)
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

public enum KindleReader {
    public static func readAll(_ paths: KindlePaths) throws
        -> (books: [Book], annotations: [Annotation])
    {
        let snapshot = try KindleSnapshot.capture(paths)
        defer { snapshot.cleanup() }
        var books = try readBooks(snapshot)
        let readStates = try readReadStates(snapshot)
        for index in books.indices {
            if let state = readStates[books[index].asin] {
                books[index].readState = state
            }
        }
        var annotations = try readAnnotationStorage(snapshot, books: books)
        annotations.append(contentsOf: try readKSDK(snapshot, books: books))
        return (books, annotations)
    }

    // MARK: - Books

    public static func readBooks(_ snapshot: KindleSnapshot) throws -> [Book] {
        let database = try SQLiteDatabase(
            path: snapshot.bookData.path, readOnly: true)
        let rows = try database.query(
            """
            SELECT ZBOOKID, ZDISPLAYTITLE, ZALTERNATESORTTITLE,
                   ZDISPLAYAUTHOR, ZSORTAUTHOR, ZRAWBOOKTYPE,
                   ZRAWREADSTATE, ZRAWISUNREAD, ZRAWLASTVIEW,
                   ZLONGCURRENTPOSITION, ZRAWCURRENTPOSITION,
                   ZLONGMAXPOSITION, ZRAWMAXPOSITION
            FROM ZBOOK
            """)
        let downloaded = downloadedIdentifiers(snapshot.ebooks)
        return rows.compactMap { row in
            guard let raw = row.string("ZBOOKID") else { return nil }
            let asin = BookIdentity.normalize(raw)
            guard !asin.isEmpty else { return nil }
            let title =
                nonEmpty(row.string("ZDISPLAYTITLE"))
                ?? nonEmpty(row.string("ZALTERNATESORTTITLE"))
                ?? "Untitled"
            let author =
                nonEmpty(row.string("ZDISPLAYAUTHOR"))
                ?? nonEmpty(row.string("ZSORTAUTHOR"))
                ?? ""
            let type = Int(row.int("ZRAWBOOKTYPE") ?? 0)
            let read = Int(row.int("ZRAWREADSTATE") ?? 0)
            let unread = Int(row.int("ZRAWISUNREAD") ?? 0)
            let state = row.int("ZRAWREADSTATE") == nil && unread == 0 ? 1 : read
            return Book(
                asin: asin,
                title: title,
                author: author,
                bookType: type,
                readState: state,
                lastView: DateParsing.coreData(row.double("ZRAWLASTVIEW")),
                currentPosition: nonEmpty(
                    row.string("ZLONGCURRENTPOSITION"))
                    ?? nonEmpty(row.string("ZRAWCURRENTPOSITION")),
                maxPosition: nonEmpty(row.string("ZLONGMAXPOSITION"))
                    ?? nonEmpty(row.string("ZRAWMAXPOSITION")),
                downloaded: downloaded.contains(asin))
        }
    }

    private static func downloadedIdentifiers(_ ebooks: URL) -> Set<String> {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: ebooks, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var result = Set<String>()
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                result.insert(entry.lastPathComponent)
            }
        }
        return result
    }

    // MARK: - Whispersync

    public static func readReadStates(_ snapshot: KindleSnapshot) throws
        -> [String: Int]
    {
        let database = try SQLiteDatabase(
            path: snapshot.whispersync.path, readOnly: true)
        let rows = try database.query(
            """
            SELECT r.ZRECORDKEY AS record_key,
                   r.ZRECORDVALUE AS record_value
            FROM ZSNAPSHOTRECORD r
            JOIN ZSNAPSHOTDATASET d ON d.Z_PK = r.ZDATASET
            JOIN ZNAMESPACE n ON n.Z_PK = d.ZNAMESPACE
            WHERE n.ZNAME = 'BookReadStates'
            """)
        var result: [String: Int] = [:]
        for row in rows {
            guard let key = row.string("record_key"),
                let value = row.string("record_value"),
                let data = value.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { continue }
            let asin = BookIdentity.normalize(key)
            guard !asin.isEmpty else { continue }
            let state = (object["state"] as? String)?.uppercased() ?? ""
            result[asin] = state == "READ" ? 1 : 0
        }
        return result
    }

    // MARK: - AnnotationStorage

    public static func readAnnotationStorage(
        _ snapshot: KindleSnapshot, books: [Book]
    ) throws -> [Annotation] {
        let database = try SQLiteDatabase(
            path: snapshot.annotationStorage.path, readOnly: true)
        let rows = try database.query(
            """
            SELECT Z_PK, ZRAWANNOTATIONTYPE, ZRAWBOOKID, ZRAWSTART,
                   ZRAWEND, ZRAWPOSITION, ZLONGSTART, ZLONGEND,
                   ZLONGPOSITION, ZUSERTEXT, ZNUMHIGHLIGHTERS
            FROM ZANNOTATION
            """)
        let titles = titleMap(books)
        return rows.compactMap { row in
            guard let rawBook = row.string("ZRAWBOOKID") else { return nil }
            let asin = BookIdentity.normalize(rawBook)
            guard !asin.isEmpty else { return nil }
            let rawType = row.string("ZRAWANNOTATIONTYPE") ?? ""
            let kind: AnnotationKind
            let provenance: AnnotationProvenance
            switch rawType {
            case "highlight":
                kind = .highlight
                provenance = .user
            case "popular":
                kind = .popularHighlight
                provenance = .amazon
            case "position_placeholder", "lpr":
                kind = .position
                provenance = .system
            default:
                kind = .position
                provenance = .system
            }
            let identifier = row.int("Z_PK") ?? 0
            return Annotation(
                id: "annotation-storage-\(identifier)",
                asin: asin,
                bookTitle: titles[asin] ?? "",
                kind: kind,
                provenance: provenance,
                start: nonEmpty(row.string("ZLONGSTART"))
                    ?? row.int("ZRAWSTART").map(String.init),
                end: nonEmpty(row.string("ZLONGEND"))
                    ?? row.int("ZRAWEND").map(String.init),
                text: nonEmpty(row.string("ZUSERTEXT")),
                sources: ["AnnotationStorage"])
        }
    }

    // MARK: - KSDK

    public static func readKSDK(
        _ snapshot: KindleSnapshot, books: [Book]
    ) throws -> [Annotation] {
        guard let ksdk = snapshot.ksdk else { return [] }
        let database = try SQLiteDatabase(path: ksdk.path, readOnly: true)
        let titles = titleMap(books)
        var result: [Annotation] = []

        let serverRows = try database.query(
            """
            SELECT dataset, dataset_id, annotation_id, serialized_payload,
                   created_time, modified_time
            FROM server_view
            """)
        for row in serverRows {
            guard let identifier = nonEmpty(row.string("annotation_id")),
                let payloadText = row.string("serialized_payload"),
                let payload = parsePayload(payloadText)
            else { continue }
            let dataset = Int(row.int("dataset") ?? 0)
            let payloadASIN = BookIdentity.normalize(payload.asin)
            let asin =
                payloadASIN.isEmpty
                ? BookIdentity.normalize(row.string("dataset_id") ?? "")
                : payloadASIN
            guard !asin.isEmpty else { continue }
            let kind = annotationKind(
                type: payload.type, dataset: dataset, popular: false)
            result.append(
                Annotation(
                    id: "ksdk-\(identifier)",
                    asin: asin,
                    bookTitle: titles[asin] ?? "",
                    kind: kind,
                    provenance: provenance(for: kind),
                    start: payload.start,
                    end: payload.end,
                    text: kind == .note ? payload.note : payload.text,
                    note: kind == .note ? nil : payload.note,
                    color: payload.color,
                    createdAt: payload.createdAt
                        ?? DateParsing.epoch(row.double("created_time")),
                    modifiedAt: payload.modifiedAt
                        ?? DateParsing.epoch(row.double("modified_time")),
                    sources: ["KSDK"]))
        }

        let localRows = try database.query(
            """
            SELECT dataset, book_id, annotation_id, start_position,
                   end_position, serialized_payload, created_time,
                   modified_time
            FROM nonsyncable_annotations
            """)
        for row in localRows {
            guard let identifier = nonEmpty(row.string("annotation_id")),
                let payloadText = row.string("serialized_payload"),
                let payload = parsePayload(payloadText)
            else { continue }
            let dataset = Int(row.int("dataset") ?? 0)
            let asin = BookIdentity.normalize(
                nonEmpty(payload.asin) ?? row.string("book_id") ?? "")
            guard !asin.isEmpty else { continue }
            let kind = annotationKind(
                type: payload.type, dataset: dataset, popular: dataset == 18)
            result.append(
                Annotation(
                    id: "ksdk-\(identifier)",
                    asin: asin,
                    bookTitle: titles[asin] ?? "",
                    kind: kind,
                    provenance: provenance(for: kind),
                    start: payload.start
                        ?? nonEmpty(row.string("start_position")),
                    end: payload.end
                        ?? nonEmpty(row.string("end_position")),
                    text: kind == .note ? payload.note : payload.text,
                    note: kind == .note ? nil : payload.note,
                    color: payload.color,
                    createdAt: payload.createdAt
                        ?? DateParsing.epoch(row.double("created_time")),
                    modifiedAt: payload.modifiedAt
                        ?? DateParsing.epoch(row.double("modified_time")),
                    sources: ["KSDK"]))
        }
        return result
    }

    // MARK: - Payload

    private struct Payload {
        let asin: String
        let type: String?
        let start: String?
        let end: String?
        let text: String?
        let note: String?
        let color: String?
        let createdAt: Date?
        let modifiedAt: Date?
    }

    private static func parsePayload(_ text: String) -> Payload? {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return nil }
        let book = object["book_data"] as? [String: Any]
        var metadata: [String: Any] = [:]
        if let raw = object["json_metadata"] {
            if let string = raw as? String,
                let data = string.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            {
                metadata = parsed
            } else if let parsed = raw as? [String: Any] {
                metadata = parsed
            }
        }
        return Payload(
            asin: stringValue(book?["asin"]) ?? "",
            type: stringValue(object["type"]),
            start: positionValue(object["start_position"]),
            end: positionValue(object["end_position"]),
            text: stringValue(object["text"]) ?? stringValue(metadata["text"]),
            note: stringValue(object["note"])
                ?? stringValue(metadata["note"])
                ?? stringValue(metadata["note_text"]),
            color: stringValue(metadata["mchl_color"])
                ?? stringValue(metadata["color"]),
            createdAt: DateParsing.epoch(
                doubleValue(object["created_time"])),
            modifiedAt: DateParsing.epoch(
                doubleValue(object["last_modified"])))
    }

    private static func annotationKind(
        type: String?, dataset: Int, popular: Bool
    ) -> AnnotationKind {
        if popular || dataset == 18 { return .popularHighlight }
        switch type?.uppercased() {
        case "HIGHLIGHT": return .highlight
        case "NOTE": return .note
        case "BOOKMARK": return .bookmark
        default: return .position
        }
    }

    private static func provenance(
        for kind: AnnotationKind
    ) -> AnnotationProvenance {
        switch kind {
        case .highlight, .note, .bookmark: return .user
        case .popularHighlight: return .amazon
        case .position: return .system
        }
    }

    private static func titleMap(_ books: [Book]) -> [String: String] {
        var result: [String: String] = [:]
        for book in books where result[book.asin] == nil {
            result[book.asin] = book.title
        }
        return result
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    /// Kindle stores a location either as a bare value or as
    /// `{ longPosition, shortPosition }`. Prefer the long one.
    private static func positionValue(_ value: Any?) -> String? {
        if let direct = stringValue(value) { return direct }
        guard let object = value as? [String: Any] else { return nil }
        return stringValue(object["longPosition"])
            ?? stringValue(object["shortPosition"])
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
