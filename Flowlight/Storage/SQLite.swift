import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, CustomStringConvertible {
    case open(String), prepare(String, String), step(String)
    var description: String {
        switch self {
        case .open(let m): return "open: \(m)"
        case .prepare(let m, let sql): return "prepare: \(m) — \(sql)"
        case .step(let m): return "step: \(m)"
        }
    }
}

enum SQLValue {
    case int(Int64), double(Double), text(String), blob(Data), null
}

extension SQLValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    init(integerLiteral value: Int64) { self = .int(value) }
    init(stringLiteral value: String) { self = .text(value) }
}

struct SQLRow {
    fileprivate let stmt: OpaquePointer
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func blob(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

/// Shared by a main-actor request and the work queued on the database connection.
final class TrafficReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

private final class SQLiteTextFunction {
    let call: (String, String) -> String?
    init(_ call: @escaping (String, String) -> String?) { self.call = call }
}

/// Minimal SQLite wrapper. Not thread-safe; callers serialize access on a queue.
final class SQLiteConnection {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
        }
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
        }
        try execute("PRAGMA busy_timeout=3000")
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close_v2(db)
    }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError.step(message + " — " + sql)
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let stmt = statements[sql] {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            return stmt
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)), sql)
        }
        statements[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ values: [SQLValue]) {
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, i)
            }
        }
    }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let stmt = try prepared(sql)
        bind(stmt, values)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError.step(String(cString: sqlite3_errmsg(db))) }
    }

    func forEachRow(_ sql: String, _ values: [SQLValue] = [], _ visit: (SQLRow) throws -> Void) throws {
        let stmt = try prepared(sql)
        defer { sqlite3_reset(stmt) }
        bind(stmt, values)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { try visit(SQLRow(stmt: stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw SQLiteError.step(String(cString: sqlite3_errmsg(db))) }
        }
    }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (SQLRow) -> T) throws -> [T] {
        var results: [T] = []
        try forEachRow(sql, values) { results.append(map($0)) }
        return results
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

    /// A deferred transaction pins one WAL snapshot after its first read without blocking concurrent capture writes.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Scope the progress handler to one serialized read and remove it before committing or rolling back.
    func withCancellation<T>(_ cancellation: TrafficReadCancellation, _ body: () throws -> T) throws -> T {
        try cancellation.check()
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 0 }
            return Unmanaged<TrafficReadCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        do {
            let result = try body()
            try cancellation.check()
            return result
        } catch {
            try cancellation.check()
            throw error
        }
    }

    /// A deterministic two-text-argument function for sharing domain classification with SQL projections.
    func registerTextFunction(_ name: String, _ call: @escaping (String, String) -> String?) throws {
        let context = Unmanaged.passRetained(SQLiteTextFunction(call)).toOpaque()
        let rc = sqlite3_create_function_v2(db, name, 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, context, { result, _, arguments in
            guard let context = sqlite3_user_data(result), let arguments else { return }
            func text(_ argument: OpaquePointer?) -> String {
                sqlite3_value_text(argument).map { String(cString: $0) } ?? ""
            }
            let function = Unmanaged<SQLiteTextFunction>.fromOpaque(context).takeUnretainedValue()
            if let value = function.call(text(arguments[0]), text(arguments[1])) {
                sqlite3_result_text(result, value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_result_null(result)
            }
        }, nil, nil, { context in
            if let context { Unmanaged<SQLiteTextFunction>.fromOpaque(context).release() }
        })
        guard rc == SQLITE_OK else { throw SQLiteError.step(String(cString: sqlite3_errmsg(db))) }
    }

    var changes: Int { Int(sqlite3_changes(db)) }
}
