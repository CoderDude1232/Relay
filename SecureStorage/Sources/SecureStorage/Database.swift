//
//  Database.swift
//  SecureStorage
//
//  A thin wrapper over the SQLCipher C API: keyed open, prepared
//  statements, and transactions. One connection, serialized by an internal
//  lock — session/ratchet state must never race.
//

import Foundation
import SQLCipher

public enum StorageError: Error, Equatable {
    case openFailed(String)
    case wrongKey
    case sqlite(code: Int32, message: String)
    case recordNotFound(String)
    case keychain(status: Int32)
    case secureEnclave(String)
}

/// A 256-bit SQLCipher master key.
public struct DatabaseKey: Sendable, Equatable {
    public static let byteCount = 32
    public let bytes: Data

    public init(bytes: Data) {
        precondition(bytes.count == Self.byteCount, "database key must be 32 bytes")
        self.bytes = bytes
    }

    public static func random() -> DatabaseKey {
        var bytes = Data(count: byteCount)
        let result = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed")
        return DatabaseKey(bytes: bytes)
    }

    var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case text(String)
    case blob(Data)

    public var int64: Int64? { if case .integer(let v) = self { v } else { nil } }
    public var string: String? { if case .text(let v) = self { v } else { nil } }
    public var data: Data? { if case .blob(let v) = self { v } else { nil } }
}

public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    /// Opens (creating if needed) an encrypted database at `path`. Throws
    /// `StorageError.wrongKey` when the file exists but the key can't
    /// decrypt it.
    public init(path: String, key: DatabaseKey) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StorageError.openFailed(message)
        }
        do {
            // Keying must happen before any other statement touches the file.
            try run("PRAGMA key = \"x'\(key.hex)'\";")
            // First real read fails with NOTADB if the key is wrong.
            guard (try? query("SELECT count(*) FROM sqlite_master;")) != nil else {
                sqlite3_close(handle)
                handle = nil
                throw StorageError.wrongKey
            }
            try run("PRAGMA journal_mode = WAL;")
            try run("PRAGMA foreign_keys = ON;")
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit {
        if handle != nil {
            sqlite3_close(handle)
        }
    }

    /// Executes a statement, discarding any rows it produces.
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        _ = try query(sql, bindings)
    }

    /// Executes a statement and returns all result rows.
    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [[SQLValue]] {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT: have SQLite copy bound buffers immediately.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1)
            let bound: Int32
            switch value {
            case .null:
                bound = sqlite3_bind_null(statement, slot)
            case .integer(let v):
                bound = sqlite3_bind_int64(statement, slot, v)
            case .text(let v):
                bound = sqlite3_bind_text(statement, slot, v, -1, transient)
            case .blob(let v):
                bound = v.withUnsafeBytes {
                    sqlite3_bind_blob(statement, slot, $0.baseAddress, Int32(v.count), transient)
                }
            }
            guard bound == SQLITE_OK else { throw currentError() }
        }

        var rows: [[SQLValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let columnCount = sqlite3_column_count(statement)
                var row: [SQLValue] = []
                row.reserveCapacity(Int(columnCount))
                for column in 0..<columnCount {
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER:
                        row.append(.integer(sqlite3_column_int64(statement, column)))
                    case SQLITE_TEXT:
                        row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, column))
                        let base = sqlite3_column_blob(statement, column)
                        row.append(.blob(base.map { Data(bytes: $0, count: count) } ?? Data()))
                    case SQLITE_FLOAT:
                        row.append(.integer(Int64(sqlite3_column_double(statement, column))))
                    default:
                        row.append(.null)
                    }
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw currentError()
            }
        }
    }

    /// Runs `body` inside a transaction, rolling back on error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try run("COMMIT;")
            return result
        } catch {
            try? run("ROLLBACK;")
            throw error
        }
    }

    private func currentError() -> StorageError {
        .sqlite(
            code: sqlite3_errcode(handle),
            message: String(cString: sqlite3_errmsg(handle))
        )
    }
}
