//
//  EnvelopeProcessorTests.swift
//  RelayCoreTests
//
//  Incoming envelopes end to end: a real libsignal session from Alice to Bob,
//  decrypted and stored by Bob's processor on an encrypted database.
//

import CryptoCore
import Foundation
import LibSignalClient
import RelayKit
import SecureStorage
import Testing

@testable import RelayCore

/// In-memory identity credentials, standing in for the Keychain.
private final class TestCredentials: IdentityCredentialProviding {
    let identity = IdentityKeyPair.generate()
    let regId = UInt32.random(in: 1...0x3FFF)
    func identityKeyPair() throws -> IdentityKeyPair { identity }
    func registrationId() throws -> UInt32 { regId }
}

private let aliceId = "aaaaaaaa-0000-0000-0000-000000000001"
private let bobId = "bbbbbbbb-0000-0000-0000-000000000002"

private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// Bob's storage and processor, plus an Alice who has a session with him.
private final class Harness {
    let store: SecureStore
    let bob: CryptoEngine
    let alice: CryptoEngine
    let processor: EnvelopeProcessor

    init() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaycore-test-\(UUID().uuidString).db").path
        store = try SecureStore(path: path, key: .random(), credentials: TestCredentials())
        bob = try store.makeCryptoEngine(accountId: bobId, deviceId: 1)
        alice = try CryptoEngine.makeEphemeral(accountId: aliceId, deviceId: 1)
        let keys = try bob.generatePreKeyPublication(signedPreKeyId: 1, kyberPreKeyId: 2, oneTimePreKeyIds: 3..<8)
        try alice.processPeerBundle(
            PeerPreKeyBundle(
                deviceId: 1, registrationId: keys.registrationId, identityKey: keys.identityKey,
                signedPreKey: keys.signedPreKey, kyberPreKey: keys.kyberPreKey,
                oneTimePreKey: keys.oneTimePreKeys.first
            ),
            from: bob.localAddress
        )
        processor = EnvelopeProcessor(storage: store, engine: bob, ownAccountId: bobId)
    }

    /// Alice encrypts `content` for Bob and the relay wraps it in an envelope.
    func envelope(_ content: Relay_Content_Content, id: String = UUID().uuidString) throws -> IncomingEnvelope {
        let sealed = try alice.encrypt(try content.serializedData(), for: bob.localAddress)
        var proto = Relay_V1_Envelope()
        proto.id = id
        proto.senderAccount = aliceId
        proto.senderDevice = 1
        proto.type = sealed.kind == .preKey ? .prekeyMessage : .message
        proto.content = sealed.data
        proto.serverTimestamp = nowMs()
        return try #require(IncomingEnvelope(serializedEnvelope: try proto.serializedData()))
    }

    func deferredRows() throws -> [String] {
        try store.database.query(
            "SELECT key FROM kv WHERE key LIKE ? ORDER BY key", [.text(EnvelopeProcessor.deferredPrefix + "%")]
        ).compactMap { $0[0].string }
    }

    func makeGroup(_ id: String, members: [String]) throws {
        try store.messages.upsertGroup(id: id, name: "Test group", distributionId: UUID().uuidString,
                                       revision: 1, members: members)
    }

    func groupMessages(_ groupId: String) throws -> [StoredMessage] {
        let conversation = try #require(try store.messages.groupConversationId(groupId: groupId))
        return try store.messages.messages(in: conversation)
    }
}

private func text(_ body: String, groupId: String = "") -> Relay_Content_Content {
    var content = Relay_Content_Content()
    content.text.body = body
    content.text.timestamp = nowMs()
    content.groupID = groupId
    return content
}

struct EnvelopeProcessorTests {
    @Test func storesA1to1TextMessage() throws {
        let h = try Harness()
        let result = try h.processor.process(try h.envelope(text("hello bob")))
        #expect(result.outcome == .stored)
        #expect(result.peerAccount == aliceId)
        #expect(result.notification?.body == "hello bob")

        let conversation = try #require(result.conversationId)
        let messages = try h.store.messages.messages(in: conversation)
        #expect(messages.map(\.body) == ["hello bob"])
        #expect(messages.first?.isOutgoing == false)
    }

    @Test func redeliveredEnvelopeIsADuplicate() throws {
        let h = try Harness()
        let envelope = try h.envelope(text("once"))
        #expect(try h.processor.process(envelope).outcome == .stored)
        let again = try h.processor.process(envelope)
        #expect(again.outcome == .duplicate)
    }

    @Test func claimedSenderMustMatchTheSession() throws {
        let h = try Harness()
        var content = text("I'm Carol, honest")
        content.senderAccountID = "cccccccc-0000-0000-0000-000000000003"
        #expect(throws: EnvelopeProcessorError.senderSpoofed) {
            try h.processor.process(try h.envelope(content))
        }
    }

    @Test func blockedSenderIsIgnored() throws {
        let h = try Harness()
        let result = try h.processor.process(try h.envelope(text("let me in")), blockedAccounts: [aliceId])
        #expect(result.outcome == .ignored)
        #expect(result.conversationId == nil)
    }

    @Test func groupMessageBeforeItsGroupIsDeferredThenReplayed() throws {
        let h = try Harness()
        let early = try h.processor.process(try h.envelope(text("hi all", groupId: "group-1")))
        #expect(early.outcome == .ignored)
        #expect(try h.deferredRows().count == 1)

        // Nothing is replayed while the group is still unknown.
        #expect(h.processor.replayDeferredGroupContent().isEmpty)
        #expect(try h.deferredRows().count == 1)

        try h.makeGroup("group-1", members: [aliceId, bobId])
        let replayed = h.processor.replayDeferredGroupContent()
        #expect(replayed.map(\.outcome) == [.stored])
        #expect(try h.groupMessages("group-1").map(\.body) == ["hi all"])
        #expect(try h.deferredRows().isEmpty)
    }

    @Test func groupMessageForAGroupWeLeftIsDropped() throws {
        let h = try Harness()
        try h.makeGroup("group-2", members: [aliceId])
        let result = try h.processor.process(try h.envelope(text("still here?", groupId: "group-2")))
        #expect(result.outcome == .ignored)
        #expect(try h.deferredRows().isEmpty)
    }

    @Test func fullDeferredTableEvictsTheOldestNotTheNewest() throws {
        let h = try Harness()
        let prefix = EnvelopeProcessor.deferredPrefix
        try h.store.database.transaction {
            for i in 0..<EnvelopeProcessor.deferredMaxRows {
                try h.store.database.run(
                    "INSERT INTO kv (key, value) VALUES (?, ?)",
                    [.text(prefix + String(format: "%017ld:filler-%04ld", i, i)), .blob(Data([0]))]
                )
            }
        }
        _ = try h.processor.process(try h.envelope(text("newest", groupId: "group-3"), id: "newest-envelope"))

        let rows = try h.deferredRows()
        #expect(rows.count == EnvelopeProcessor.deferredMaxRows)
        #expect(!rows.contains { $0.hasSuffix("filler-0000") })
        #expect(rows.last?.hasSuffix("newest-envelope") == true)
    }

    @Test func failedReplayKeepsTheRowUntilItExpires() throws {
        let h = try Harness()
        try h.makeGroup("group-4", members: [aliceId, bobId])
        // Content that fails handling: it claims a sender other than Alice.
        var content = text("spoofed", groupId: "group-4")
        content.senderAccountID = "cccccccc-0000-0000-0000-000000000003"

        func insertDeferred(savedAt: Date) throws {
            let item = EnvelopeProcessor.DeferredGroupContent(
                envelopeId: UUID().uuidString, senderName: aliceId, senderDevice: 1, attestedUsername: nil,
                plaintext: try content.serializedData(), groupId: "group-4", savedAt: savedAt
            )
            try h.store.database.run(
                "INSERT INTO kv (key, value) VALUES (?, ?)",
                [.text(EnvelopeProcessor.deferredPrefix + item.envelopeId), .blob(try JSONEncoder().encode(item))]
            )
        }

        try insertDeferred(savedAt: Date())
        #expect(h.processor.replayDeferredGroupContent().isEmpty)
        #expect(try h.deferredRows().count == 1)
        #expect(try h.groupMessages("group-4").isEmpty)

        try h.store.database.run("DELETE FROM kv")
        try insertDeferred(savedAt: Date().addingTimeInterval(-EnvelopeProcessor.deferredMaxAge - 60))
        #expect(h.processor.replayDeferredGroupContent().isEmpty)
        #expect(try h.deferredRows().isEmpty)
    }
}
