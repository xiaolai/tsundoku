import Foundation
import SQLite3

/// A failed source read, independent of the live-reader AX/screen permissions.
public struct LibraryImportFailure: Identifiable, Sendable {
    public let source: BookSource
    public let detail: String
    public let accessDenied: Bool
    public var id: BookSource { source }

    public init(source: BookSource, error: any Error) {
        self.source = source
        detail = String(describing: error)
        accessDenied = Self.isAccessDenied(error)
    }

    public var summary: String {
        accessDenied
            ? "macOS blocked access to the \(source.displayName) library."
            : "The \(source.displayName) library could not be imported."
    }

    private static func isAccessDenied(_ error: any Error, depth: Int = 0) -> Bool {
        guard depth < 5 else { return false }
        if let sql = error as? SQLiteError {
            guard sql.isSourceAccessError else { return false }
            let primary = sql.code & 0xff
            if primary == SQLITE_AUTH || primary == SQLITE_PERM { return true }
            if let code = sql.systemErrorCode, code == 1 || code == 13 { return true }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == 1 || ns.code == 13 {
            return true
        }
        if ns.domain == NSCocoaErrorDomain,
            ns.code == NSFileReadNoPermissionError {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? any Error {
            return isAccessDenied(underlying, depth: depth + 1)
        }
        return false
    }
}
