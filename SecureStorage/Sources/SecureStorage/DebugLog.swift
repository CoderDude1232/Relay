//
//  DebugLog.swift
//  SecureStorage
//
//  A small on-device log the user can share from Settings for bug reports.
//
//  - Lines come from `RelayLog`, which also writes to the unified log. Every
//    line passes through `PrivacyRedactor`; message content is never logged.
//  - Contacts and keys appear only as short tags (`c-1a2b3c`, `k-4d5e6f`): an
//    HMAC under a random per-install salt, so a tag is stable within one log
//    but means nothing outside this device. Clearing the log rotates the salt.
//  - Rows live in the encrypted database, so the log is unreadable while the
//    database key is forgotten (PIN lock "Forget Messages") and is deleted with
//    the database on sign-out or a distress wipe.
//  - Kept to the newest `maxEntries` lines and at most `maxAge` old.
//

import CryptoKit
import Foundation
import OSLog

public struct DebugLogEntry: Sendable, Equatable {
    public enum Level: String, Sendable {
        case info, notice, warning, error, fault

        var label: String {
            switch self {
            case .info: "INFO"
            case .notice: "NOTE"
            case .warning: "WARN"
            case .error: "ERROR"
            case .fault: "FAULT"
            }
        }
    }

    public let date: Date
    public let level: Level
    public let category: String
    public let message: String

    public init(date: Date, level: Level, category: String, message: String) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

// MARK: - Storage

public final class DebugLogStore: @unchecked Sendable {
    public static let maxEntries = 3000
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let maxMessageLength = 600
    private static let saltKey = "debuglog.salt"

    /// Trimming scans the table, so it runs on the first append and then every
    /// `pruneInterval` appends; between trims the log may run a little over.
    static let pruneInterval = 25

    private let database: Database
    private var appendsSincePrune: Int?

    init(database: Database) {
        self.database = database
    }

    /// Callers serialize appends (DebugLog's queue).
    public func append(_ entries: [DebugLogEntry], now: Date = Date()) throws {
        guard !entries.isEmpty else { return }
        try database.transaction {
            for entry in entries {
                try database.run(
                    "INSERT INTO debug_log (at, level, category, message) VALUES (?, ?, ?, ?)",
                    [.integer(Self.millis(entry.date)), .text(entry.level.rawValue),
                     .text(entry.category), .text(String(entry.message.prefix(Self.maxMessageLength)))]
                )
            }
            guard (appendsSincePrune ?? Self.pruneInterval) >= Self.pruneInterval else {
                appendsSincePrune? += 1
                return
            }
            appendsSincePrune = 1
            try database.run("DELETE FROM debug_log WHERE at < ?",
                             [.integer(Self.millis(now.addingTimeInterval(-Self.maxAge)))])
            // Ids only grow (AUTOINCREMENT), so the newest maxEntries are a range.
            try database.run("DELETE FROM debug_log WHERE id <= (SELECT MAX(id) FROM debug_log) - ?",
                             [.integer(Int64(Self.maxEntries))])
        }
    }

    /// Oldest first.
    public func entries() throws -> [DebugLogEntry] {
        try database.query("SELECT at, level, category, message FROM debug_log ORDER BY id").compactMap { row in
            guard row.count == 4, let at = row[0].int64, let level = row[1].string.flatMap(DebugLogEntry.Level.init),
                  let category = row[2].string, let message = row[3].string else { return nil }
            return DebugLogEntry(date: Date(timeIntervalSince1970: Double(at) / 1000),
                                 level: level, category: category, message: message)
        }
    }

    /// Deletes every line and rotates the tag salt, so tags in a new log can't
    /// be matched to ones in a log shared earlier.
    public func clear() throws {
        try database.transaction {
            try database.run("DELETE FROM debug_log")
            try database.run("DELETE FROM kv WHERE key = ?", [.text(Self.saltKey)])
        }
    }

    /// The per-install salt for contact and key tags, made on first use.
    public func tagSalt() throws -> Data {
        try database.transaction {
            if let existing = try database.query("SELECT value FROM kv WHERE key = ?", [.text(Self.saltKey)])
                .first?.first?.data, existing.count == 32 {
                return existing
            }
            let salt = DatabaseKey.random().bytes
            try database.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                             [.text(Self.saltKey), .blob(salt)])
            return salt
        }
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - Sink

/// Where `RelayLog` lines go. Lines are written in batches: right away for
/// errors and faults, otherwise within `flushDelay`. Lines logged before a
/// database is attached (or while it's locked) wait in memory.
public final class DebugLog: @unchecked Sendable {
    public static let shared = DebugLog()
    static let pendingLimit = 300
    static let flushDelay: DispatchTimeInterval = .seconds(2)

    // Only touched on `queue`.
    private let queue = DispatchQueue(label: "app.relaymsg.debuglog", qos: .utility)
    private var store: DebugLogStore?
    private var pending: [DebugLogEntry] = []
    private var flushScheduled = false

    // Read synchronously by `tag`, so behind a lock instead.
    private let tagLock = NSLock()
    private var tagKey: SymmetricKey?

    init() {}

    public func attach(_ store: DebugLogStore) {
        queue.sync {
            self.store = store
            setTagKey(salt: try? store.tagSalt())
            flush()
        }
    }

    /// Writes what's queued, then stops writing to the database (before its
    /// key is forgotten, or it's deleted).
    public func detach() {
        queue.sync {
            flush()
            store = nil
            pending = []
            setTagKey(salt: nil)
        }
    }

    public func record(_ entry: DebugLogEntry) {
        queue.async { [self] in
            pending.append(entry)
            guard store != nil else {
                if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
                return
            }
            if entry.level == .error || entry.level == .fault {
                flush()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + Self.flushDelay) { [self] in flush() }
            }
        }
    }

    /// Oldest first; includes everything recorded so far.
    public func entries() -> [DebugLogEntry] {
        queue.sync {
            flush()
            guard let store else { return pending }
            return (try? store.entries()) ?? []
        }
    }

    public func clear() {
        queue.sync {
            pending = []
            guard let store else { return }
            try? store.clear()
            setTagKey(salt: try? store.tagSalt())
        }
    }

    /// Plain text for sharing: `header` lines, a short legend, then one line per entry.
    public static func exportText(header: [String], entries: [DebugLogEntry]) -> String {
        let legend = [
            "Times are UTC. Contacts (c-…) and keys (k-…) are short tags that only mean something within this log.",
            "No messages, names, usernames, account IDs, file names or addresses are included.",
            "",
        ]
        return (header + legend + entries.map(line)).joined(separator: "\n") + "\n"
    }

    /// One entry as it appears in the shared log.
    public static func line(_ entry: DebugLogEntry) -> String {
        let level = entry.level.label.padding(toLength: 5, withPad: " ", startingAt: 0)
        return "\(timestampFormatter.string(from: entry.date)) \(level) [\(entry.category)] \(entry.message)"
    }

    // ISO8601DateFormatter is thread-safe once configured.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// A contact's tag, e.g. `c-1a2b3c`.
    public func tag(peer: String) -> String { "c-" + shortCode(Data("peer:\(peer)".utf8)) }

    /// An identity key's tag, e.g. `k-4d5e6f`.
    public func tag(key: Data) -> String { "k-" + shortCode(Data("key:".utf8) + key) }

    private func shortCode(_ data: Data) -> String {
        tagLock.lock()
        let key = tagKey
        tagLock.unlock()
        guard let key else { return "?" }
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    private func setTagKey(salt: Data?) {
        tagLock.lock()
        tagKey = salt.map { SymmetricKey(data: $0) }
        tagLock.unlock()
    }

    /// On `queue`.
    private func flush() {
        flushScheduled = false
        guard let store, !pending.isEmpty else { return }
        try? store.append(pending)
        pending = []
    }
}

// MARK: - Logger

/// A drop-in for `os.Logger` that also keeps the line in the debug log.
/// `debug` goes only to the unified log. Each line is redacted once and is
/// then public in both, so what Console shows is what a shared log holds.
public struct RelayLog: Sendable {
    public static let subsystem = "app.relaymsg"

    public let category: String
    private let logger: Logger

    public init(_ category: String) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func debug(_ message: RelayLogMessage) {
        logger.debug("\(message.text, privacy: .public)")
    }

    public func info(_ message: RelayLogMessage) { emit(.info, message) }
    public func notice(_ message: RelayLogMessage) { emit(.notice, message) }
    public func warning(_ message: RelayLogMessage) { emit(.warning, message) }
    public func error(_ message: RelayLogMessage) { emit(.error, message) }
    public func fault(_ message: RelayLogMessage) { emit(.fault, message) }

    private func emit(_ level: DebugLogEntry.Level, _ message: RelayLogMessage) {
        logger.log(level: level.osLogType, "\(message.text, privacy: .public)")
        DebugLog.shared.record(DebugLogEntry(date: Date(), level: level, category: category, message: message.text))
    }
}

private extension DebugLogEntry.Level {
    var osLogType: OSLogType {
        switch self {
        case .info: .info
        case .notice: .default
        case .warning, .error: .error
        case .fault: .fault
        }
    }
}

/// A log line. Interpolated values (errors included, via `String(describing:)`)
/// make the whole line go through `PrivacyRedactor`; a plain literal is the
/// author's own text and is kept as written.
public struct RelayLogMessage: ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) { text += literal }

        public mutating func appendInterpolation<T>(_ value: T) {
            text += String(describing: value)
        }
    }

    public let text: String

    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: StringInterpolation) {
        text = PrivacyRedactor.redactedString(stringInterpolation.text)
    }
}
