import Foundation

public enum LibraryAccessStatus: Sendable {
    case notChecked, available, blocked, notFound, failed

    public var title: String {
        switch self {
        case .notChecked: "Not checked"
        case .available: "Libraries readable"
        case .blocked: "Access blocked"
        case .notFound: "No local library"
        case .failed: "Check failed"
        }
    }
}

public struct LibraryAccessResult: Sendable {
    public let readableSources: [BookSource]
    public let failures: [LibraryImportFailure]

    public init(readableSources: [BookSource], failures: [LibraryImportFailure]) {
        self.readableSources = readableSources
        self.failures = failures
    }

    public var status: LibraryAccessStatus {
        if failures.contains(where: \.accessDenied) { return .blocked }
        if !failures.isEmpty { return .failed }
        return readableSources.isEmpty ? .notFound : .available
    }
}

/// Verifies source authorization through SQLite without importing or reading book/annotation rows.
public enum LibraryAccessProbe {
    public static func check(kindle: KindlePaths = .standard(), books: BooksPaths = .standard()) -> LibraryAccessResult {
        var readable: [BookSource] = []
        var failures: [LibraryImportFailure] = []
        do {
            if try kindle.validateAccess() {
                var stores = [kindle.bookData, kindle.annotationStorage, kindle.whispersync]
                if let account = kindle.accountAnnotationDB { stores.append(account) }
                try stores.forEach(checkDatabase)
                readable.append(.kindle)
            }
        } catch { failures.append(LibraryImportFailure(source: .kindle, error: error)) }
        do {
            if try books.validateAccess(), let library = books.bookLibrary, let annotations = books.annotationDatabase {
                try checkDatabase(library)
                try checkDatabase(annotations)
                readable.append(.appleBooks)
            }
        } catch { failures.append(LibraryImportFailure(source: .appleBooks, error: error)) }
        return LibraryAccessResult(readableSources: readable, failures: failures)
    }

    private static func checkDatabase(_ url: URL) throws {
        let database = try SQLiteDatabase(path: url.path, readOnly: true)
        _ = try database.query("PRAGMA schema_version")
    }
}
