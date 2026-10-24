import Foundation
import Testing
@testable import TsundokuCore

struct LibraryAccessProbeTests {
    @Test func failedBooksSnapshotRemovesPartialCopy() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("source/Documents/BKLibrary/BKLibrary-test.sqlite")
        let notes = root.appendingPathComponent("source/Documents/AEAnnotation/AEAnnotation-test.sqlite")
        let snapshots = root.appendingPathComponent("snapshots")
        for file in [library, notes] {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { let db = try SQLiteDatabase(path: file.path); try db.execute("CREATE TABLE fixture (id INTEGER)") }
        }
        try manager.createDirectory(at: snapshots, withIntermediateDirectories: true)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notes.path)
            try? manager.removeItem(at: root)
        }
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: notes.path)
        #expect(throws: (any Error).self) {
            try BooksSnapshot.capture(BooksPaths(container: root.appendingPathComponent("source")), temporaryDirectory: snapshots)
        }
        #expect(try manager.contentsOfDirectory(atPath: snapshots.path).isEmpty)
    }

    @Test func kindleDirectoryDenialIsNotMissingAndCorruptStoreIsNotDenial() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let protected = root.appendingPathComponent("Protected")
        try manager.createDirectory(at: protected, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: protected.appendingPathComponent("BookData.sqlite"))
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path)
            try? manager.removeItem(at: root)
        }
        let paths = KindlePaths(container: root)
        let corrupt = LibraryAccessProbe.check(kindle: paths, books: BooksPaths(container: root.appendingPathComponent("missing")))
        #expect(corrupt.status == .failed)
        #expect(corrupt.failures.first?.accessDenied == false)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: protected.path)
        do {
            _ = try paths.validateAccess()
            Issue.record("Denied directory must not be reported as missing")
        } catch { #expect(LibraryImportFailure(source: .kindle, error: error).accessDenied) }
    }
    @Test func missingLibraryIsNotPermissionDenial() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = LibraryAccessProbe.check(kindle: KindlePaths(container: root), books: BooksPaths(container: root))
        #expect(result.status == .notFound)
        #expect(result.failures.isEmpty)
    }

    @Test func metadataProbeIsReadOnlyAndDistinguishesDenial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("Documents/BKLibrary/BKLibrary-test.sqlite")
        let notes = root.appendingPathComponent("Documents/AEAnnotation/AEAnnotation-test.sqlite")
        for file in [library, notes] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { let db = try SQLiteDatabase(path: file.path); try db.execute("CREATE TABLE fixture (value TEXT)") }
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notes.path)
            try? FileManager.default.removeItem(at: root)
        }
        let before = try Data(contentsOf: library)
        let paths = BooksPaths(container: root)
        let missingKindle = KindlePaths(container: root.appendingPathComponent("absent"))
        #expect(LibraryAccessProbe.check(kindle: missingKindle, books: paths).status == .available)
        #expect(try Data(contentsOf: library) == before)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: notes.path)
        let blocked = LibraryAccessProbe.check(kindle: missingKindle, books: paths)
        #expect(blocked.status == .blocked)
        #expect(blocked.failures.first?.source == .appleBooks)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notes.path)
        #expect(LibraryAccessProbe.check(kindle: missingKindle, books: paths).status == .available)
    }
}
