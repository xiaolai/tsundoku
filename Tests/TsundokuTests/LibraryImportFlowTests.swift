import Combine
import Foundation
import Testing
@testable import TsundokuCore
@testable import TsundokuUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LibraryImportFlowTests {
    /// Waits for the import's own completion signal. A wall-clock deadline
    /// here is the flake: under parallel load the import can outlast it while
    /// still finishing normally, and the test then reports a failure that never
    /// happened.
    private func waitForImport(_ model: AppModel) async {
        await model.awaitImportCompletion()
        #expect(!model.isImporting, "Import must complete")
    }

    @Test func deniedSourcePreservesArchiveAndRetryRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("books/Documents/BKLibrary")
        let annotations = root.appendingPathComponent("books/Documents/AEAnnotation")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotations, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.path)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let db = try SQLiteDatabase(path: library.appendingPathComponent("BKLibrary-test.sqlite").path)
            try db.execute("CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZCONTENTTYPE INTEGER,ZREADINGPROGRESS REAL,ZLASTOPENDATE REAL,ZDATEFINISHED REAL,ZISFINISHED INTEGER,ZPATH TEXT)")
            try db.execute("INSERT INTO ZBKLIBRARYASSET VALUES ('NEW','Fixture book','Fixture author',1,0.3,NULL,NULL,0,NULL)")
            let notes = try SQLiteDatabase(path: annotations.appendingPathComponent("AEAnnotation-test.sqlite").path)
            try notes.execute("CREATE TABLE ZAEANNOTATION (Z_PK INTEGER,ZANNOTATIONUUID TEXT,ZANNOTATIONASSETID TEXT,ZANNOTATIONTYPE INTEGER,ZANNOTATIONSELECTEDTEXT TEXT,ZANNOTATIONNOTE TEXT,ZANNOTATIONLOCATION TEXT,ZANNOTATIONCREATIONDATE REAL,ZANNOTATIONMODIFICATIONDATE REAL,ZANNOTATIONDELETED INTEGER)")
        }
        let model = AppModel(archiveURL: root.appendingPathComponent("archive.sqlite"),
            kindlePaths: KindlePaths(container: root.appendingPathComponent("missing")),
            booksPaths: BooksPaths(container: root.appendingPathComponent("books")),
            recoverReaderSettings: false)
        let archive = try #require(model.archive)
        _ = try archive.importAll(books: [Book(asin: "OLD", title: "Existing book", author: "Fixture", bookType: 10, readState: 0)], annotations: [])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)
        model.importLibrary(announce: false)
        await waitForImport(model)
        #expect(model.importFailures.count == 1)
        #expect(model.importFailures.first?.source == .appleBooks)
        #expect(model.importFailures.first?.accessDenied == true)
        #expect(try archive.counts().books == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.path)
        model.importLibrary(announce: false)
        await waitForImport(model)
        #expect(model.importError == nil)
        #expect(model.importFailures.isEmpty)
        #expect(try archive.counts().books == 2)
    }

    @Test func sqliteSnapshotReportsUnreadableSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("source.sqlite")
        do { let db = try SQLiteDatabase(path: file.path); try db.execute("CREATE TABLE test (id INTEGER)") }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        do {
            try SQLiteSnapshot.copy(file, to: root.appendingPathComponent("copy.sqlite"))
            Issue.record("Unreadable source must fail")
        } catch {
            #expect(LibraryImportFailure(source: .kindle, error: error).accessDenied)
        }
    }

    @Test func completedMissingImportShowsItsActualResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(archiveURL: root.appendingPathComponent("archive.sqlite"),
            kindlePaths: KindlePaths(container: root.appendingPathComponent("missing")),
            booksPaths: BooksPaths(container: root.appendingPathComponent("missing")), recoverReaderSettings: false)
        #expect(!model.hasCompletedImport)
        model.importLibrary(announce: false)
        await waitForImport(model)
        #expect(model.hasCompletedImport)
        #expect(model.emptyLibraryMessage == "No local Kindle or Apple Books stores found.")
    }

    @Test func grantDuringImportQueuesOneFollowupImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(archiveURL: root.appendingPathComponent("archive.sqlite"),
            kindlePaths: KindlePaths(container: root.appendingPathComponent("missing")),
            booksPaths: BooksPaths(container: root.appendingPathComponent("missing")), recoverReaderSettings: false)
        var starts = 0
        let observation = model.$isImporting.sink { if $0 { starts += 1 } }
        defer { observation.cancel() }
        model.importLibrary(announce: false)
        model.requestLibraryImport()
        model.requestLibraryImport()
        await waitForImport(model)
        #expect(starts == 2, "Access granted during import must be retried once, rather than dropped or duplicated")
    }

    @Test func sqlitePrepareAndStepErrorsRetainSystemErrno() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try SQLiteDatabase(path: root.appendingPathComponent("db.sqlite").path)
        try db.execute("CREATE TABLE fixture (id INTEGER UNIQUE)")
        try db.execute("INSERT INTO fixture VALUES (1)")
        for sql in ["SELECT * FROM missing", "INSERT INTO fixture VALUES (1)"] {
            do {
                try db.execute(sql)
                Issue.record("Expected SQL error")
            } catch let error as SQLiteError {
                #expect(error.systemErrorCode == 0, "SQL/schema errors without an OS failure must retain a zero errno")
                #expect(!LibraryImportFailure(source: .kindle, error: error).accessDenied)
            }
        }
    }

    @Test func committedImportSurvivesSourceTimestampFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("books/Documents/BKLibrary/BKLibrary-test.sqlite")
        let notes = root.appendingPathComponent("books/Documents/AEAnnotation/AEAnnotation-test.sqlite")
        for file in [library, notes] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        do {
            let db = try SQLiteDatabase(path: library.path)
            try db.execute("CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZCONTENTTYPE INTEGER,ZREADINGPROGRESS REAL,ZLASTOPENDATE REAL,ZDATEFINISHED REAL,ZISFINISHED INTEGER,ZPATH TEXT)")
            try db.execute("INSERT INTO ZBKLIBRARYASSET VALUES ('NEW','Fixture book','Fixture author',1,0.3,NULL,NULL,0,NULL)")
            let annotations = try SQLiteDatabase(path: notes.path)
            try annotations.execute("CREATE TABLE ZAEANNOTATION (Z_PK INTEGER,ZANNOTATIONUUID TEXT,ZANNOTATIONASSETID TEXT,ZANNOTATIONTYPE INTEGER,ZANNOTATIONSELECTEDTEXT TEXT,ZANNOTATIONNOTE TEXT,ZANNOTATIONLOCATION TEXT,ZANNOTATIONCREATIONDATE REAL,ZANNOTATIONMODIFICATIONDATE REAL,ZANNOTATIONDELETED INTEGER)")
        }
        let archiveURL = root.appendingPathComponent("archive.sqlite")
        let model = AppModel(archiveURL: archiveURL,
            kindlePaths: KindlePaths(container: root.appendingPathComponent("absent")),
            booksPaths: BooksPaths(container: root.appendingPathComponent("books")), recoverReaderSettings: false)
        do {
            let db = try SQLiteDatabase(path: archiveURL.path)
            try db.execute("CREATE TRIGGER reject_source_meta BEFORE INSERT ON meta WHEN NEW.key LIKE 'last_import_source_%' BEGIN SELECT RAISE(ABORT, 'fixture metadata failure'); END")
        }
        model.importLibrary(announce: false)
        await waitForImport(model)
        #expect(try model.archive?.counts().books == 1)
        #expect(model.importFailures.isEmpty)
        #expect(model.lastImportResult?.contains("1 books") == true)
    }

    @Test func cancellingAnImportKeepsWhatWasCommitted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(
            path: root.appendingPathComponent("archive.sqlite"))
        let cancel = CancellationFlag()
        let secondSourceRead = Counter()

        // The first source commits one book and asks for cancellation, the
        // way the Cancel button does while a read is in flight. The second
        // source must then never be read: a cancelled import that still reads
        // the next library is not cancelled.
        let outcome = await LibraryImportCoordinator.run(
            [
                LibraryImportCoordinator.Source(
                    source: .kindle, missingMessage: "absent",
                    read: {
                        cancel.set()
                        return (
                            books: [
                                Book(
                                    asin: "FIRST", title: "First",
                                    author: "Fixture", bookType: 10,
                                    readState: 0, source: .kindle)
                            ], annotations: []
                        )
                    }),
                LibraryImportCoordinator.Source(
                    source: .appleBooks, missingMessage: "absent",
                    read: {
                        secondSourceRead.bump()
                        return (books: [], annotations: [])
                    }),
            ], archive: archive, cancel: cancel)

        #expect(outcome.cancelled)
        #expect(outcome.books == 1)
        #expect(outcome.committedSources == [.kindle])
        #expect(secondSourceRead.value == 0)
        #expect(try archive.counts().books == 1)
    }

    @Test func anImportWithoutCancellationReadsEverySource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(
            path: root.appendingPathComponent("archive.sqlite"))
        let outcome = await LibraryImportCoordinator.run(
            [
                LibraryImportCoordinator.Source(
                    source: .kindle, missingMessage: "absent",
                    read: { (books: [], annotations: []) }),
                LibraryImportCoordinator.Source(
                    source: .appleBooks, missingMessage: "absent",
                    read: { (books: [], annotations: []) }),
            ], archive: archive, cancel: CancellationFlag())
        #expect(!outcome.cancelled)
        #expect(outcome.committedSources == [.kindle, .appleBooks])
    }

    @Test func deniedSnapshotDestinationIsNotLibraryAuthorizationFailure() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("destination")
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.sqlite")
        do { let db = try SQLiteDatabase(path: source.path); try db.execute("CREATE TABLE fixture (id INTEGER)") }
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            try? manager.removeItem(at: root)
        }
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: destination.path)
        do {
            try SQLiteSnapshot.copy(source, to: destination.appendingPathComponent("copy.sqlite"))
            Issue.record("Snapshot destination must reject writing")
        } catch {
            #expect(!LibraryImportFailure(source: .appleBooks, error: error).accessDenied)
        }
    }
}

/// Counts how often a source was read. The coordinator hands each read
/// closure to a detached task, so the counter crosses threads.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
