//
//  HardeningTests.swift
//  SecureStorageTests
//
//  Regression tests for: cross-thread transaction atomicity, idempotent /
//  concurrent schema migration, per-account identity trust for new device
//  ids, and system lines never counting as unread.
//

import CryptoCore
import Foundation
import LibSignalClient
import Testing

@testable import SecureStorage

private final class Credentials: IdentityCredentialProviding {
    let identity = IdentityKeyPair.generate()
    func identityKeyPair() throws -> IdentityKeyPair { identity }
    func registrationId() throws -> UInt32 { 42 }
}

private func tempPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-hardening-\(UUID().uuidString).db").path
}

private func kvCount(_ db: Database, prefix: String = "") throws -> Int64 {
    try db.query("SELECT count(*) FROM kv WHERE key LIKE ?", [.text(prefix + "%")]).first?.first?.int64 ?? -1
}

/// Collects errors thrown on worker threads.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var errors: [Error] = []
    func append(_ error: Error) { lock.lock(); errors.append(error); lock.unlock() }
}

struct TransactionConcurrencyTests {
    @Test func concurrentTransactionsAndStatementsNeverInterleave() throws {
        let storage = try SecureStore(path: tempPath(), key: .random(), credentials: Credentials())
        let db = storage.database
        let box = ErrorBox()
        let workers = 8
        let iterations = 40

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for i in 0..<iterations {
                do {
                    if worker % 2 == 0 {
                        try db.transaction {
                            let before = try kvCount(db)
                            try db.run("INSERT INTO kv (key, value) VALUES (?, x'01')", [.text("t-\(worker)-\(i)-a")])
                            usleep(100) // give other threads a chance to sneak in
                            try db.run("INSERT INTO kv (key, value) VALUES (?, x'01')", [.text("t-\(worker)-\(i)-b")])
                            let after = try kvCount(db)
                            // Nothing from another thread may land inside our transaction.
                            if after != before + 2 {
                                box.append(StorageError.openFailed("interleaved: \(before) -> \(after)"))
                            }
                        }
                    } else {
                        try db.run("INSERT INTO kv (key, value) VALUES (?, x'02')", [.text("p-\(worker)-\(i)")])
                    }
                } catch {
                    box.append(error)
                }
            }
        }

        #expect(box.errors.isEmpty, "errors: \(box.errors)")
        #expect(try kvCount(db, prefix: "t-") == Int64(workers / 2 * iterations * 2))
        #expect(try kvCount(db, prefix: "p-") == Int64(workers / 2 * iterations))
    }

    @Test func rollbackDoesNotDiscardOtherThreadsWrites() throws {
        let storage = try SecureStore(path: tempPath(), key: .random(), credentials: Credentials())
        let db = storage.database
        let started = DispatchSemaphore(value: 0)
        let plainDone = DispatchSemaphore(value: 0)
        let box = ErrorBox()

        DispatchQueue.global().async {
            do {
                try db.transaction {
                    try db.run("INSERT INTO kv (key, value) VALUES ('doomed', x'00')")
                    started.signal()
                    usleep(50_000) // the other thread's write is waiting on us now
                    throw StorageError.recordNotFound("abort")
                }
            } catch StorageError.recordNotFound {
                // expected
            } catch {
                box.append(error)
            }
        }
        started.wait()
        DispatchQueue.global().async {
            do {
                try db.run("INSERT INTO kv (key, value) VALUES ('survivor', x'00')")
            } catch {
                box.append(error)
            }
            plainDone.signal()
        }
        plainDone.wait()

        #expect(box.errors.isEmpty, "errors: \(box.errors)")
        #expect(try kvCount(db, prefix: "doomed") == 0)
        #expect(try kvCount(db, prefix: "survivor") == 1)
    }

    @Test func nestedTransactionsUseSavepoints() throws {
        let storage = try SecureStore(path: tempPath(), key: .random(), credentials: Credentials())
        let db = storage.database

        try db.transaction {
            try db.run("INSERT INTO kv (key, value) VALUES ('outer', x'00')")
            // A failing nested transaction rolls back only its own work.
            _ = try? db.transaction {
                try db.run("INSERT INTO kv (key, value) VALUES ('inner-failed', x'00')")
                throw StorageError.recordNotFound("inner")
            }
            // A succeeding nested transaction is kept.
            try db.transaction {
                try db.run("INSERT INTO kv (key, value) VALUES ('inner-ok', x'00')")
            }
        }
        #expect(try kvCount(db, prefix: "outer") == 1)
        #expect(try kvCount(db, prefix: "inner-failed") == 0)
        #expect(try kvCount(db, prefix: "inner-ok") == 1)

        // A failing outer transaction rolls back everything, nested included.
        _ = try? db.transaction {
            try db.transaction {
                try db.run("INSERT INTO kv (key, value) VALUES ('gone', x'00')")
            }
            throw StorageError.recordNotFound("outer")
        }
        #expect(try kvCount(db, prefix: "gone") == 0)
        // And the connection is usable for a fresh top-level transaction.
        try db.transaction { try db.run("INSERT INTO kv (key, value) VALUES ('after', x'00')") }
        #expect(try kvCount(db, prefix: "after") == 1)
    }
}

struct MigrationTests {
    @Test func migrateIsIdempotent() throws {
        let storage = try SecureStore(path: tempPath(), key: .random(), credentials: Credentials())
        let version = try Schema.userVersion(storage.database)
        #expect(version >= 22)
        try Schema.migrate(storage.database)
        try Schema.migrate(storage.database)
        #expect(try Schema.userVersion(storage.database) == version)
    }

    @Test func concurrentMigrationFromTwoConnectionsSucceeds() throws {
        // Models the app and the NSE opening the same file right after an
        // update: separate connections, migrating at the same time.
        for _ in 0..<5 {
            let path = tempPath()
            let key = DatabaseKey.random()
            // Create the file first so both connections key the same DB.
            _ = try Database(path: path, key: key)

            let connections = try (0..<3).map { _ in try Database(path: path, key: key) }
            let box = ErrorBox()
            DispatchQueue.concurrentPerform(iterations: connections.count) { index in
                do {
                    try Schema.migrate(connections[index])
                } catch {
                    box.append(error)
                }
            }
            #expect(box.errors.isEmpty, "errors: \(box.errors)")
            let versions = try connections.map { try Schema.userVersion($0) }
            #expect(Set(versions).count == 1)
            #expect(versions[0] >= 22)
        }
    }

    @Test func secondProcessReopeningAfterPartialMigrationSkipsAppliedSteps() throws {
        // One connection fully migrates; another that read the old version
        // earlier must not re-run steps (e.g. v20's ALTER TABLE ADD COLUMN).
        let path = tempPath()
        let key = DatabaseKey.random()
        let early = try Database(path: path, key: key)
        let late = try Database(path: path, key: key)
        try Schema.migrate(early)
        try Schema.migrate(late)
        #expect(try Schema.userVersion(late) == Schema.userVersion(early))
        _ = try SecureStore(path: path, key: key, credentials: Credentials())
    }
}

struct IdentityTrustTests {
    @Test func newDeviceTrustedOnlyWithKnownAccountKey() throws {
        let storage = try SecureStore(path: tempPath(), key: .random(), credentials: Credentials())
        let store = storage.signalStore
        let context = NullContext()
        let accountKey = IdentityKeyPair.generate().identityKey
        let rogueKey = IdentityKeyPair.generate().identityKey
        let device1 = try ProtocolAddress(name: "peer", deviceId: 1)
        let device2 = try ProtocolAddress(name: "peer", deviceId: 2)
        let device3 = try ProtocolAddress(name: "peer", deviceId: 3)

        // Completely unknown account: TOFU.
        #expect(try store.isTrustedIdentity(accountKey, for: device1, direction: .sending, context: context))
        #expect(try store.saveIdentity(accountKey, for: device1, context: context) == .newOrUnchanged)

        // New device presenting the shared account key: trusted.
        #expect(try store.isTrustedIdentity(accountKey, for: device2, direction: .sending, context: context))
        #expect(try store.isTrustedIdentity(accountKey, for: device2, direction: .receiving, context: context))
        #expect(try store.saveIdentity(accountKey, for: device2, context: context) == .newOrUnchanged)

        // New device presenting a different key: untrusted (both directions),
        // exactly like a changed key.
        #expect(try !store.isTrustedIdentity(rogueKey, for: device3, direction: .sending, context: context))
        #expect(try !store.isTrustedIdentity(rogueKey, for: device3, direction: .receiving, context: context))
        // Saving it (the app's explicit acceptance path) reports a replacement…
        #expect(try store.saveIdentity(rogueKey, for: device3, context: context) == .replacedExisting)
        // …after which that device is trusted with that key, and the account
        // now exposes two distinct keys for the app's acknowledgement check.
        #expect(try store.isTrustedIdentity(rogueKey, for: device3, direction: .sending, context: context))
        #expect(try store.identityKeys(address: "peer") == [accountKey.serialize(), rogueKey.serialize()])

        // A different, unrelated account is still TOFU.
        let other = try ProtocolAddress(name: "other", deviceId: 5)
        #expect(try store.isTrustedIdentity(rogueKey, for: other, direction: .sending, context: context))
    }

    @Test func newDeviceVerificationSemantics() throws {
        let storage = try SecureStore(path: tempPath(), key: .random(), credentials: Credentials())
        let store = storage.signalStore
        let context = NullContext()
        let accountKey = IdentityKeyPair.generate().identityKey
        let rogueKey = IdentityKeyPair.generate().identityKey

        _ = try store.saveIdentity(accountKey, for: try .init(name: "peer", deviceId: 1), context: context)
        try store.setVerified(true, address: "peer")
        #expect(try store.verificationState(address: "peer") == .verified)

        // A linked device with the same (verified) key stays verified.
        _ = try store.saveIdentity(accountKey, for: try .init(name: "peer", deviceId: 2), context: context)
        #expect(try store.verificationState(address: "peer") == .verified)

        // A new device with a different key surfaces as a safety-number change.
        _ = try store.saveIdentity(rogueKey, for: try .init(name: "peer", deviceId: 3), context: context)
        #expect(try store.verificationState(address: "peer") == .changed)
        #expect(try !store.isVerified(address: "peer"))

        // Changed key on an existing device still resets verified (unchanged semantics).
        try store.setVerified(true, address: "peer")
        #expect(try store.verificationState(address: "peer") == .verified)
        #expect(try store.saveIdentity(rogueKey, for: try .init(name: "peer", deviceId: 1), context: context) == .replacedExisting)
        #expect(try store.verificationState(address: "peer") == .changed)
    }

    @Test func newDeviceOfUnverifiedPeerIsUnverified() throws {
        let storage = try SecureStore(path: tempPath(), key: .random(), credentials: Credentials())
        let store = storage.signalStore
        let context = NullContext()
        let accountKey = IdentityKeyPair.generate().identityKey
        _ = try store.saveIdentity(accountKey, for: try .init(name: "peer", deviceId: 1), context: context)
        _ = try store.saveIdentity(accountKey, for: try .init(name: "peer", deviceId: 2), context: context)
        #expect(try store.verificationState(address: "peer") == .unverified)
        #expect(try store.identityKeys(address: "peer") == [accountKey.serialize()])
    }
}

struct SystemLineUnreadTests {
    @Test func systemLinesNeverCountAsUnread() throws {
        let storage = try SecureStore(path: tempPath(), key: .random(), credentials: Credentials())
        let store = storage.messages
        let convo = try store.conversation(withPeer: "bob")

        try store.insertMessage(
            id: "sys-1", conversationId: convo, isOutgoing: false,
            body: "Missed call", timestamp: 1000, status: .received,
            senderAccount: MessageStore.systemSender
        )
        #expect(try store.conversations().first?.unreadCount == 0)

        try store.insertMessage(
            id: "in-1", conversationId: convo, isOutgoing: false,
            body: "hi", timestamp: 2000, status: .received
        )
        try store.insertMessage(
            id: "sys-2", conversationId: convo, isOutgoing: false,
            body: "Safety number changed", timestamp: 3000, status: .received,
            senderAccount: MessageStore.systemSender
        )
        #expect(try store.conversations().first?.unreadCount == 1)

        try store.markConversationRead(convo)
        #expect(try store.conversations().first?.unreadCount == 0)

        // "Mark unread" targets the latest REAL incoming message, so it still
        // shows exactly one unread even when a system line is newer.
        try store.markConversationUnread(convo)
        #expect(try store.conversations().first?.unreadCount == 1)
    }
}
