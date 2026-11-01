import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public typealias SQLRow = [String: SQLValue]

public extension Dictionary where Key == String, Value == SQLValue {
    func string(_ k: String) -> String? { if case .text(let s)? = self[k] { return s }; return nil }
    func int(_ k: String) -> Int? {
        switch self[k] {
        case .int(let i)?: return Int(i)
        case .double(let d)?: return Int(d)
        default: return nil
        }
    }
    func double(_ k: String) -> Double? {
        switch self[k] {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }
    func bool(_ k: String) -> Bool { int(k).map { $0 != 0 } ?? false }
    func date(_ k: String) -> Date? { double(k).map(Date.init(timeIntervalSince1970:)) }
    func uuid(_ k: String) -> UUID? { string(k).flatMap(UUID.init(uuidString:)) }
    func data(_ k: String) -> Data? { if case .blob(let d)? = self[k] { return d }; return nil }
}

public protocol SQLBindable: Sendable { var sqlValue: SQLValue { get } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension UUID: SQLBindable { public var sqlValue: SQLValue { .text(uuidString) } }
extension URL: SQLBindable { public var sqlValue: SQLValue { .text(absoluteString) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Serialised access to one SQLite connection (spec 13.3: services use actors for mutable state).
/// Kage-owned data only; WebKit website data is never stored here (ADR-002).
/// Owns the raw connection handle and closes it when the store goes away.
private final class ConnectionHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}

public actor SQLiteStore {
    private let connection: ConnectionHandle
    private var db: OpaquePointer? { connection.pointer }
    public let path: String

    /// `path` of ":memory:" opens a private in-memory database, used by tests and the Private profile.
    public init(path: String, migrations: [Migration] = Schema.migrations) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: msg)
        }
        connection = ConnectionHandle(handle)
        try Self.exec(handle, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON;")
        try Self.migrate(handle, migrations)
    }

    /// Opens the store at the default location, excluded from backups (spec 14.8).
    /// On iOS the folder is `completeUnlessOpen`: files Kage hasn't already opened are unreadable while the
    /// device is locked, including to someone who copies them off the device (threat model T-12).
    public static func openDefault(name: String = "Kage.sqlite", migrations: [Migration] = Schema.migrations) throws -> SQLiteStore {
        let fm = FileManager.default
        var dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Kage", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: dir.path)
        #endif
        let path = dir.appendingPathComponent(name).path
        let store = try SQLiteStore(path: path, migrations: migrations)
        #if os(iOS)
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: path + suffix)
        }
        #endif
        return store
    }

    public var schemaVersion: Int {
        get throws { try query("PRAGMA user_version").first?.int("user_version") ?? 0 }
    }

    public func execute(_ sql: String, _ bindings: [SQLBindable] = []) throws {
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
    }

    @discardableResult
    public func executeReturningChanges(_ sql: String, _ bindings: [SQLBindable] = []) throws -> Int {
        try execute(sql, bindings)
        return Int(sqlite3_changes(db))
    }

    public func query(_ sql: String, _ bindings: [SQLBindable] = []) throws -> [SQLRow] {
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var row: SQLRow = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "col\(i)"
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row[name] = .text(sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "")
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if n > 0, let p = sqlite3_column_blob(stmt, i) {
                        row[name] = .blob(Data(bytes: p, count: n))
                    } else {
                        row[name] = .blob(Data())
                    }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs `body` in a transaction; rolls back if it throws (spec 13.6 step 2: delete transactionally).
    public func transaction<T: Sendable>(_ body: @Sendable (isolated SQLiteStore) throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body(self)
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Reclaims freed pages so deleted rows do not linger in the file (best effort; not forensic erasure).
    public func vacuum() throws { try execute("VACUUM") }

    // MARK: - Private

    private func prepare(_ sql: String, _ bindings: [SQLBindable]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
        for (i, b) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch b.sqlValue {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
        }
        return stmt
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    private static func migrate(_ db: OpaquePointer, _ migrations: [Migration]) throws {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
        sqlite3_step(stmt)
        let current = Int(sqlite3_column_int(stmt, 0))
        sqlite3_finalize(stmt)
        for m in migrations.sorted(by: { $0.version < $1.version }) where m.version > current {
            // Each migration is atomic: a failure leaves the previous schema intact (spec 14.8).
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try exec(db, m.sql)
                try exec(db, "PRAGMA user_version = \(m.version)")
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }
}

public struct Migration: Sendable {
    public var version: Int
    public var sql: String
    public init(version: Int, sql: String) { self.version = version; self.sql = sql }
}
