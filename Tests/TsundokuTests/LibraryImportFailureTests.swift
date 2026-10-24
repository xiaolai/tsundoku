import Foundation
import Testing
@testable import TsundokuCore

struct LibraryImportFailureTests {
    @Test(arguments: [1, 13]) func permissionDenied(_ code: Int) {
        let failure = LibraryImportFailure(
            source: .kindle, error: NSError(domain: NSPOSIXErrorDomain, code: code))
        #expect(failure.accessDenied)
        #expect(failure.summary.contains("macOS blocked"))
    }

    @Test func sqlitePreservesSystemPermissionError() {
        let failure = LibraryImportFailure(
            source: .appleBooks,
            error: SQLiteError(code: 14, message: "unable to open database file", systemErrorCode: 1))
        #expect(failure.accessDenied)
    }

    @Test(arguments: [Int32(23), Int32(3)]) func sqliteAuthorizationDenial(_ code: Int32) {
        let failure = LibraryImportFailure(source: .kindle,
            error: SQLiteError(code: code, message: "authorization denied"))
        #expect(failure.accessDenied)
    }

    @Test func missingDatabaseIsNotPermissionDenial() {
        let failure = LibraryImportFailure(
            source: .kindle,
            error: SQLiteError(code: 14, message: "unable to open database file", systemErrorCode: 2))
        #expect(!failure.accessDenied)
    }

    @Test func nestedFoundationDenial() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 256,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13)])
        #expect(LibraryImportFailure(source: .appleBooks, error: error).accessDenied)
    }

    @Test func schemaFailureKeepsDiagnostic() {
        let failure = LibraryImportFailure(source: .appleBooks,
            error: SQLiteError(code: 1, message: "no such column: example"))
        #expect(!failure.accessDenied)
        #expect(failure.detail.contains("no such column"))
    }
}
