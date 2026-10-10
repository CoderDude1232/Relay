//
//  Database.swift
//  SecureStorage
//
//  Thin wrapper over the SQLCipher C API: keyed open, prepared statements,
//  transactions. One connection behind a recursive lock so session and
//  ratchet state never race. A `transaction` holds the lock from BEGIN to
//  COMMIT and every `query`/`run` takes it, so a transaction excludes other
//  threads while its own thread can still run statements inside it.
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
    /// The write would turn one kind of record into another, e.g. a 1:1
    /// conversation into a group.
    case conflict(String)
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
        let result = bytes.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, base)
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
    /// Recursive so the thread owning a transaction can keep issuing statements
    /// and nested transactions inside it.
    private let lock = NSRecursiveLock()
    /// Nesting depth of `transaction` on the owning thread. Guarded by `lock`.
    private var transactionDepth = 0

    /// How long a writer waits on the other process's file lock (app vs NSE)
    /// before failing with SQLITE_BUSY.
    public static let busyTimeoutMilliseconds: Int32 = 5000

    /// Opens or creates an encrypted database at `path`. Throws
    /// `StorageError.wrongKey` if the file exists but the key doesn't decrypt it.
    public init(path: String, key: DatabaseKey) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StorageError.openFailed(message)
        }
        // The app and the NSE share this file, so wait on contention instead of
        // failing with SQLITE_BUSY. Set before the key check below touches the file.
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
        do {
            // Keying must happen before any other statement touches the file.
            try run("PRAGMA key = \"x'\(key.hex)'\";")
            // The first real read fails with NOTADB on a wrong key. A busy or locked
            // error (the other process writing past the timeout) is not a wrong key;
            // rethrow it so callers can retry.
            do {
                _ = try query("SELECT count(*) FROM sqlite_master;")
            } catch StorageError.sqlite(let code, let message)
                where code == SQLITE_BUSY || code == SQLITE_LOCKED {
                throw StorageError.sqlite(code: code, message: message)
            } catch {
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

        // SQLITE_TRANSIENT: SQLite copies bound buffers immediately.
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

    /// Runs `body` in a transaction, rolling back on error.
    ///
    /// The connection lock is held for the whole body, so other threads' statements
    /// wait rather than interleave with it or get rolled back by it. Same-thread
    /// calls from `body` proceed. A nested call becomes a SAVEPOINT: its failure
    /// rolls back only its own work and rethrows.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        if transactionDepth == 0 {
            try run("BEGIN IMMEDIATE;")
            transactionDepth = 1
            defer { transactionDepth = 0 }
            do {
                let result = try body()
                try run("COMMIT;")
                return result
            } catch {
                try? run("ROLLBACK;")
                throw error
            }
        } else {
            let savepoint = "relay_sp_\(transactionDepth)"
            try run("SAVEPOINT \(savepoint);")
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            do {
                let result = try body()
                try run("RELEASE \(savepoint);")
                return result
            } catch {
                try? run("ROLLBACK TO \(savepoint);")
                try? run("RELEASE \(savepoint);")
                throw error
            }
        }
    }

    private func currentError() -> StorageError {
        .sqlite(
            code: sqlite3_errcode(handle),
            message: String(cString: sqlite3_errmsg(handle))
        )
    }
}
