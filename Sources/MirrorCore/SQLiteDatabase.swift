#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import Foundation

/// Error raised by the SQLite wrapper. Carries the SQLite result code, the
/// message reported by the library and, when known, the SQL text involved.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public init(code: Int32, message: String, sql: String? = nil) {
        self.code = code
        self.message = message
        self.sql = sql
    }

    public var description: String {
        var text = "SQLite error \(code): \(message)"
        if let sql { text += " [\(sql.prefix(160))]" }
        return text
    }
}

public enum SQLiteOpenMode: Sendable {
    case readOnly
    case readWrite
    case readWriteCreate
}

/// A value that can be bound to a statement parameter.
public protocol SQLiteBindable {
    func bind(to statement: SQLiteStatement, at index: Int32) throws
}

/// Explicit NULL for argument lists where an untyped `nil` would be ambiguous.
public struct SQLiteNull: SQLiteBindable {
    public init() {}
    public func bind(to statement: SQLiteStatement, at index: Int32) throws {
        try statement.bindNull(at: index)
    }
}

extension Int: SQLiteBindable {
    public func bind(to statement: SQLiteStatement, at index: Int32) throws {
        try statement.bind(Int64(self), at: index)
    }
}

extension Int32: SQLiteBindable {
    public func bind(to statement: SQLiteStatement, at index: Int32) throws {
        try statement.bind(Int64(self), at: index)
    }
}

extension Int64: SQLiteBindable {
    public func bind(to statement: SQLiteStatement, at index: Int32) throws {
        try statement.bind(self, at: index)
    }
}

extension Double: SQLiteBindable {
    public func bind(to statement: SQLiteStatement, at index: Int32) throws {
        try statement.bind(self, at: index)
    }
}

extension String: SQLiteBindable {
    public func bind(to statement: SQLiteStatement, at index: Int32) throws {
        try statement.bind(self, at: index)
    }
}

extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    public func bind(to statement: SQLiteStatement, at index: Int32) throws {
        switch self {
        case .none: try statement.bindNull(at: index)
        case .some(let value): try value.bind(to: statement, at: index)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal SQLite connection. Instances are not thread-safe; use one
/// connection from one thread (or serialise access yourself).
public final class SQLiteDatabase {
    let handle: OpaquePointer
    public let path: String
    private var transactionDepth = 0

    public init(path: String, mode: SQLiteOpenMode) throws {
        var flags: Int32
        switch mode {
        case .readOnly: flags = SQLITE_OPEN_READONLY
        case .readWrite: flags = SQLITE_OPEN_READWRITE
        case .readWriteCreate: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        flags |= SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: message)
        }
        self.handle = db
        self.path = path
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func error(_ code: Int32, sql: String? = nil) -> SQLiteError {
        SQLiteError(code: code, message: lastErrorMessage, sql: sql)
    }

    /// Run one or more statements that return no rows.
    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError(code: rc, message: message, sql: sql)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw error(rc, sql: sql)
        }
        return SQLiteStatement(handle: statement, database: self, sql: sql)
    }

    /// Prepare, bind and run a statement that returns no rows.
    public func run(_ sql: String, _ args: [any SQLiteBindable] = []) throws {
        let statement = try prepare(sql)
        try statement.run(args)
    }

    /// Run a query and map every row.
    public func rows<T>(
        _ sql: String,
        _ args: [any SQLiteBindable] = [],
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(args)
        var result: [T] = []
        while try statement.step() {
            result.append(try map(statement))
        }
        return result
    }

    /// First column of the first row as Int64, or nil when there are no rows or the value is NULL.
    public func scalarInt64(_ sql: String, _ args: [any SQLiteBindable] = []) throws -> Int64? {
        let statement = try prepare(sql)
        try statement.bind(args)
        guard try statement.step() else { return nil }
        return statement.isNull(0) ? nil : statement.int64(0)
    }

    public func scalarString(_ sql: String, _ args: [any SQLiteBindable] = []) throws -> String? {
        let statement = try prepare(sql)
        try statement.bind(args)
        guard try statement.step() else { return nil }
        return statement.string(0)
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Run `body` inside a transaction. Commits when `body` returns, rolls back when it throws.
    /// Nested calls join the outer transaction.
    /// - Parameter immediate: take the write lock at once (the default). A deferred transaction
    ///   takes no lock on the main database until the first write, so one that only writes to
    ///   temporary tables never blocks other connections.
    public func transaction<T>(immediate: Bool = true, _ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            return try body()
        }
        try execute(immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        transactionDepth += 1
        do {
            let value = try body()
            transactionDepth -= 1
            try execute("COMMIT")
            return value
        } catch {
            transactionDepth -= 1
            try? execute("ROLLBACK")
            throw error
        }
    }
}

/// A prepared statement. Finalised when released.
public final class SQLiteStatement {
    let handle: OpaquePointer
    let database: SQLiteDatabase
    public let sql: String

    init(handle: OpaquePointer, database: SQLiteDatabase, sql: String) {
        self.handle = handle
        self.database = database
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(handle)
    }

    // MARK: Binding (parameter indexes are 1-based, as in SQLite)

    public func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    public func bind(_ value: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(handle, index, value))
    }

    public func bind(_ value: String, at index: Int32) throws {
        let rc = value.withCString { sqlite3_bind_text(handle, index, $0, -1, sqliteTransient) }
        try check(rc)
    }

    public func bindNull(at index: Int32) throws {
        try check(sqlite3_bind_null(handle, index))
    }

    /// Bind values to parameters 1...n in order.
    public func bind(_ args: [any SQLiteBindable]) throws {
        for (offset, arg) in args.enumerated() {
            try arg.bind(to: self, at: Int32(offset + 1))
        }
    }

    // MARK: Execution

    /// Advance to the next row. Returns true when a row is available, false when done.
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.error(rc, sql: sql)
        }
    }

    public func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    /// Reset, bind and step to completion. Reusable for bulk inserts.
    public func run(_ args: [any SQLiteBindable] = []) throws {
        reset()
        try bind(args)
        while try step() {}
    }

    // MARK: Columns (indexes are 0-based)

    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    public func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    public func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(handle, column))
    }

    public func double(_ column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    /// Text value, or nil when the column is NULL.
    public func string(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: pointer)
    }

    private func check(_ rc: Int32) throws {
        if rc != SQLITE_OK { throw database.error(rc, sql: sql) }
    }
}
