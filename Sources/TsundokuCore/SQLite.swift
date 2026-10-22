import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}

public struct Row: Sendable {
    public let values: [String: SQLValue]

    public init(values: [String: SQLValue]) {
        self.values = values
    }

    public func string(_ key: String) -> String? {
        if case .text(let value)? = values[key] { return value }
        return nil
    }

    public func int(_ key: String) -> Int64? {
        switch values[key] {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        default: return nil
        }
    }

    public func double(_ key: String) -> Double? {
        switch values[key] {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags =
            readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, handle != nil else {
            let message =
                handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError(code: result, message: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError(
                code: result,
                message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteError(
                    code: result,
                    message: String(cString: sqlite3_errmsg(handle)))
            }
            var values: [String: SQLValue] = [:]
            let count = sqlite3_column_count(statement)
            for index in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    values[name] = .integer(
                        sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    values[name] = .real(
                        sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) {
                        values[name] = .text(String(cString: text))
                    } else {
                        values[name] = .null
                    }
                default:
                    values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(
        _ sql: String, _ bindings: [SQLValue]
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            let message =
                handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError(code: result, message: message)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let value):
                sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                sqlite3_bind_double(statement, index, value)
            case .text(let value):
                sqlite3_bind_text(
                    statement, index, value, -1, SQLITE_TRANSIENT)
            }
        }
        return statement
    }
}

public enum SQLiteSnapshot {
    /// A consistent copy of a live SQLite database, including its WAL.
    ///
    /// The backup API reads the WAL; a three-file copy can catch the database
    /// and the WAL at different moments. `immutable=1` would ignore the WAL
    /// entirely, which is wrong for every Kindle store.
    public static func copy(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var sourceHandle: OpaquePointer?
        var destinationHandle: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            source.path, &sourceHandle, SQLITE_OPEN_READONLY, nil)
        guard sourceResult == SQLITE_OK, sourceHandle != nil else {
            let message =
                sourceHandle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown"
            sqlite3_close(sourceHandle)
            throw SQLiteError(code: sourceResult, message: message)
        }
        let destinationResult = sqlite3_open_v2(
            destination.path, &destinationHandle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard destinationResult == SQLITE_OK, destinationHandle != nil else {
            let message =
                destinationHandle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown"
            sqlite3_close(sourceHandle)
            sqlite3_close(destinationHandle)
            throw SQLiteError(code: destinationResult, message: message)
        }
        defer {
            sqlite3_close(sourceHandle)
            sqlite3_close(destinationHandle)
        }
        guard
            let backup = sqlite3_backup_init(
                destinationHandle, "main", sourceHandle, "main")
        else {
            throw SQLiteError(
                code: SQLITE_ERROR,
                message: "could not start the SQLite backup")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw SQLiteError(
                code: step == SQLITE_DONE ? finish : step,
                message: "could not copy \(source.lastPathComponent)")
        }
        // The source is in WAL mode. Leave the snapshot in rollback-journal
        // mode so a later read-only open needs no `-shm` next to it.
        sqlite3_exec(
            destinationHandle, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
    }
}
