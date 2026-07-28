//
//  SecureStorageTests.swift
//  SecureStorageTests
//
//  Validates the encrypted-at-rest guarantee, persistence of session/
//  ratchet state across database reopen, and message history behavior.
//  Keychain/Secure Enclave paths aren't exercisable in an unhosted test
//  bundle; those are wired and verified in-app.
//

import CryptoCore
import Foundation
import LibSignalClient
import Testing

@testable import SecureStorage

/// In-memory identity credentials, standing in for the Keychain.
private final class TestCredentials: IdentityCredentialProviding {
    let identity = IdentityKeyPair.generate()
    let regId = UInt32.random(in: 1...0x3FFF)
    func identityKeyPair() throws -> IdentityKeyPair { identity }
    func registrationId() throws -> UInt32 { regId }
}

private func tempDBPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-test-\(UUID().uuidString).db").path
}

struct DatabaseTests {
    @Test func wrongKeyIsRejectedAndFileIsNotPlainSQLite() throws {
        let path = tempDBPath()
        let key = DatabaseKey.random()
        do {
            let storage = try SecureStore(path: path, key: key, credentials: TestCredentials())
            try storage.database.run("INSERT INTO kv (key, value) VALUES ('probe', x'AABB')")
        } // close via deinit

        // Wrong key must fail…
        #expect(throws: StorageError.wrongKey) {
            _ = try Database(path: path, key: .random())
        }
        // …the right key must work…
        let reopened = try Database(path: path, key: key)
        #expect(try reopened.query("SELECT value FROM kv WHERE key = 'probe'").count == 1)

        // …and the raw file must not start with the plaintext SQLite magic.
        let header = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16)
        #expect(!header.starts(with: Data("SQLite format 3".utf8)))
    }

    @Test func sessionsAndRatchetSurviveReopen() throws {
        let alicePath = tempDBPath()
        let aliceKey = DatabaseKey.random()
        let aliceCredentials = TestCredentials()
        let bob = try CryptoEngine.makeEphemeral(accountId: "bob", deviceId: 1)
        let bobKeys = try bob.generatePreKeyPublication(
            signedPreKeyId: 1, kyberPreKeyId: 1, oneTimePreKeyIds: 1..<2
        )
        let bundle = PeerPreKeyBundle(
            deviceId: 1,
            registrationId: bobKeys.registrationId,
            identityKey: bobKeys.identityKey,
            signedPreKey: bobKeys.signedPreKey,
            kyberPreKey: bobKeys.kyberPreKey,
            oneTimePreKey: bobKeys.oneTimePreKeys.first
        )

        var aliceAddress: ProtocolAddress
        do {
            let storage = try SecureStore(path: alicePath, key: aliceKey, credentials: aliceCredentials)
            let alice = try storage.makeCryptoEngine(accountId: "alice", deviceId: 1)
            aliceAddress = alice.localAddress
            try alice.processPeerBundle(bundle, from: bob.localAddress)

            let first = try alice.encrypt(Data("before reopen".utf8), for: bob.localAddress)
            #expect(first.kind == .preKey)
            #expect(try bob.decrypt(first, from: aliceAddress) == Data("before reopen".utf8))

            let reply = try bob.encrypt(Data("reply".utf8), for: aliceAddress)
            #expect(try alice.decrypt(reply, from: bob.localAddress) == Data("reply".utf8))
        } // storage closed

        // Reopen the database: the ratchet must continue where it left off.
        let storage = try SecureStore(path: alicePath, key: aliceKey, credentials: aliceCredentials)
        let alice = try storage.makeCryptoEngine(accountId: "alice", deviceId: 1)
        #expect(try alice.hasSession(with: bob.localAddress))

        let afterReopen = try alice.encrypt(Data("after reopen".utf8), for: bob.localAddress)
        #expect(afterReopen.kind == .message)
        #expect(try bob.decrypt(afterReopen, from: aliceAddress) == Data("after reopen".utf8))

        let backAgain = try bob.encrypt(Data("still ratcheting".utf8), for: aliceAddress)
        #expect(try alice.decrypt(backAgain, from: bob.localAddress) == Data("still ratcheting".utf8))
    }

    @Test func identityTrustOnFirstUseAndChangeDetection() throws {
        let storage = try SecureStore(path: tempDBPath(), key: .random(), credentials: TestCredentials())
        let store = storage.signalStore
        let peer = try ProtocolAddress(name: "peer", deviceId: 1)
        let context = NullContext()

        let firstIdentity = IdentityKeyPair.generate().identityKey
        let secondIdentity = IdentityKeyPair.generate().identityKey

        // Unknown identity: trusted (TOFU), recorded as new.
        #expect(try store.isTrustedIdentity(firstIdentity, for: peer, direction: .receiving, context: context))
        #expect(try store.saveIdentity(firstIdentity, for: peer, context: context) == .newOrUnchanged)
        try store.setVerified(true, address: "peer")

        // A different key is untrusted until re-saved, and saving it both
        // reports the replacement and resets verification.
        #expect(try !store.isTrustedIdentity(secondIdentity, for: peer, direction: .receiving, context: context))
        #expect(try store.saveIdentity(secondIdentity, for: peer, context: context) == .replacedExisting)
        #expect(try !store.isVerified(address: "peer"))
    }

    @Test func verificationStateTracksKeyChanges() throws {
        let storage = try SecureStore(path: tempDBPath(), key: .random(), credentials: TestCredentials())
        let store = storage.signalStore
        let peer = try ProtocolAddress(name: "peer", deviceId: 1)
        let context = NullContext()

        let first = IdentityKeyPair.generate().identityKey
        let second = IdentityKeyPair.generate().identityKey

        // Newly seen identity: unverified.
        #expect(try store.saveIdentity(first, for: peer, context: context) == .newOrUnchanged)
        #expect(try store.verificationState(address: "peer") == .unverified)

        // Marked verified.
        try store.setVerified(true, address: "peer")
        #expect(try store.verificationState(address: "peer") == .verified)

        // Key change on a verified peer surfaces as .changed, not .unverified.
        #expect(try store.saveIdentity(second, for: peer, context: context) == .replacedExisting)
        #expect(try store.verificationState(address: "peer") == .changed)
        #expect(try !store.isVerified(address: "peer"))

        // Clearing verification dismisses the warning back to unverified.
        try store.setVerified(false, address: "peer")
        #expect(try store.verificationState(address: "peer") == .unverified)

        // Re-verify the new key; re-seeing that same key keeps it verified.
        try store.setVerified(true, address: "peer")
        #expect(try store.saveIdentity(second, for: peer, context: context) == .newOrUnchanged)
        #expect(try store.verificationState(address: "peer") == .verified)
    }

    @Test func preKeyRemovalAndKyberMarkUsed() throws {
        let storage = try SecureStore(path: tempDBPath(), key: .random(), credentials: TestCredentials())
        let store = storage.signalStore
        let context = NullContext()

        let preKey = try PreKeyRecord(id: 7, privateKey: PrivateKey.generate())
        try store.storePreKey(preKey, id: 7, context: context)
        #expect(try store.loadPreKey(id: 7, context: context).id == 7)
        try store.removePreKey(id: 7, context: context)
        #expect(throws: StorageError.recordNotFound("prekey 7")) {
            _ = try store.loadPreKey(id: 7, context: context)
        }

        // Last-resort kyber prekeys are marked used but never deleted.
        let identity = try storage.signalStore.identityKeyPair(context: context)
        let kyberPair = KEMKeyPair.generate()
        let record = try KyberPreKeyRecord(
            id: 3,
            timestamp: 42,
            keyPair: kyberPair,
            signature: identity.privateKey.generateSignature(message: kyberPair.publicKey.serialize())
        )
        try store.storeKyberPreKey(record, id: 3, context: context)
        try store.markKyberPreKeyUsed(id: 3, signedPreKeyId: 1, baseKey: PrivateKey.generate().publicKey, context: context)
        #expect(try store.loadKyberPreKey(id: 3, context: context).id == 3)
    }
}

struct MessageStoreTests {
    @Test func conversationAndMessageLifecycle() throws {
        let storage = try SecureStore(path: tempDBPath(), key: .random(), credentials: TestCredentials())
        let store = storage.messages

        let conversation = try store.conversation(withPeer: "bob-account", username: "bob")
        // Same peer resolves to the same conversation.
        #expect(try store.conversation(withPeer: "bob-account") == conversation)

        #expect(try store.insertMessage(
            id: "m1", conversationId: conversation, isOutgoing: true,
            body: "hey bob", timestamp: 1000, status: .sending
        ))
        #expect(try store.insertMessage(
            id: "env-abc", conversationId: conversation, isOutgoing: false,
            body: "hey alice", timestamp: 2000, status: .received
        ))
        // Replayed envelope (at-least-once delivery) must be a no-op.
        #expect(try !store.insertMessage(
            id: "env-abc", conversationId: conversation, isOutgoing: false,
            body: "hey alice", timestamp: 2000, status: .received
        ))

        let messages = try store.messages(in: conversation)
        #expect(messages.map(\.id) == ["m1", "env-abc"])
        #expect(messages[0].isOutgoing && !messages[1].isOutgoing)

        let summaries = try store.conversations()
        #expect(summaries.count == 1)
        #expect(summaries[0].lastMessageBody == "hey alice")
        #expect(summaries[0].lastMessageAt == 2000)
    }

    @Test func reactionsReplyAndDelete() throws {
        let storage = try SecureStore(path: tempDBPath(), key: .random(), credentials: TestCredentials())
        let store = storage.messages
        let convo = try store.conversation(withPeer: "bob-account")

        try store.insertMessage(
            id: "m1", conversationId: convo, isOutgoing: false,
            body: "hi", timestamp: 1000, status: .received
        )
        try store.insertMessage(
            id: "m2", conversationId: convo, isOutgoing: true,
            body: "hey!", timestamp: 2000, status: .sent,
            replyTo: QuotedMessage(targetTimestamp: 1000, author: "bob-account", text: "hi")
        )

        // Reply snapshot round-trips.
        #expect(try store.messages(in: convo)[1].replyTo
            == QuotedMessage(targetTimestamp: 1000, author: "bob-account", text: "hi"))

        // One reaction per author; a new emoji from the same author replaces.
        try store.setReaction(conversationId: convo, targetTimestamp: 1000, author: "bob-account", isOutgoing: false, emoji: "❤️", remove: false)
        try store.setReaction(conversationId: convo, targetTimestamp: 1000, author: "me", isOutgoing: true, emoji: "👍", remove: false)
        try store.setReaction(conversationId: convo, targetTimestamp: 1000, author: "me", isOutgoing: true, emoji: "😂", remove: false)
        let reacted = try store.messages(in: convo)[0]
        #expect(reacted.reactions.count == 2)
        #expect(reacted.reactions.contains(MessageReaction(emoji: "❤️", author: "bob-account", isOutgoing: false)))
        #expect(reacted.reactions.contains(MessageReaction(emoji: "😂", author: "me", isOutgoing: true)))

        // Retract the local user's reaction.
        try store.setReaction(conversationId: convo, targetTimestamp: 1000, author: "me", isOutgoing: true, emoji: "", remove: true)
        #expect(try store.messages(in: convo)[0].reactions.map(\.author) == ["bob-account"])

        // Unsend leaves a tombstone: row stays in place, but body/quote/
        // reactions are cleared and it's flagged deleted.
        try store.setReaction(conversationId: convo, targetTimestamp: 2000, author: "bob-account", isOutgoing: false, emoji: "👍", remove: false)
        #expect(try store.markDeleted(conversationId: convo, targetTimestamp: 2000))
        let afterUnsend = try store.messages(in: convo)[1]
        #expect(afterUnsend.isDeleted)
        #expect(afterUnsend.body.isEmpty)
        #expect(afterUnsend.replyTo == nil)
        #expect(afterUnsend.reactions.isEmpty)
        // Unsending a message we don't have (e.g. already gone) is a no-op.
        #expect(try !store.markDeleted(conversationId: convo, targetTimestamp: 999999))

        // Delete-for-me removes the message and any reactions on it.
        try store.deleteMessage(id: "m1")
        let remaining = try store.messages(in: convo)
        #expect(remaining.map(\.id) == ["m2"])
    }

    @Test func envelopeClaimIsExactlyOnce() throws {
        let storage = try SecureStore(path: tempDBPath(), key: .random(), credentials: TestCredentials())
        let store = storage.messages
        #expect(try !store.isEnvelopeProcessed(id: "env-1"))
        // First claim wins; second (e.g. the NSE, or a redelivery) loses.
        #expect(try store.claimEnvelope(id: "env-1"))
        #expect(try !store.claimEnvelope(id: "env-1"))
        #expect(try store.isEnvelopeProcessed(id: "env-1"))
        // Distinct envelopes are independent.
        #expect(try store.claimEnvelope(id: "env-2"))
    }

    @Test func receiptsUpgradeButNeverDowngrade() throws {
        let storage = try SecureStore(path: tempDBPath(), key: .random(), credentials: TestCredentials())
        let store = storage.messages
        let conversation = try store.conversation(withPeer: "bob-account")
        try store.insertMessage(
            id: "m1", conversationId: conversation, isOutgoing: true,
            body: "x", timestamp: 1000, status: .sent
        )

        try store.applyReceipt(conversationId: conversation, timestamps: [1000], status: .read)
        #expect(try store.messages(in: conversation)[0].status == .read)

        // A late delivery receipt must not downgrade read → delivered.
        try store.applyReceipt(conversationId: conversation, timestamps: [1000], status: .delivered)
        #expect(try store.messages(in: conversation)[0].status == .read)
    }
}
