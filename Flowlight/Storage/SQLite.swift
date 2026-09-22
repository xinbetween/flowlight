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

    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (SQLRow) -> T) throws -> [T] {
        let stmt = try prepared(sql)
        bind(stmt, values)
        var results: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { results.append(map(SQLRow(stmt: stmt))) }
            else if rc == SQLITE_DONE { break }
            else { throw SQLiteError.step(String(cString: sqlite3_errmsg(db))) }
        }
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

    var changes: Int { Int(sqlite3_changes(db)) }
}
