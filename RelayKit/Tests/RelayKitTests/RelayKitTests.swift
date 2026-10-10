//
//  RelayKitTests.swift
//  RelayKitTests
//
//  Wire-mapping unit tests, plus a live end-to-end test against a running
//  relayd. The live test runs only when RELAY_SERVER_URL is set
//  (xcodebuild: TEST_RUNNER_RELAY_SERVER_URL=http://127.0.0.1:8089).
//

import CryptoCore
import Foundation
import LibSignalClient
import Testing

@testable import RelayKit

struct WireMappingTests {
    @Test func messageKindMapsRoundTrip() {
        for kind in [MessageKind.preKey, .message, .senderKey] {
            #expect(MessageKind(wireType: kind.wireType) == kind)
        }
        #expect(MessageKind(wireType: .unspecified) == nil)
    }

    @Test func incomingEnvelopeParsesProto() {
        var proto = Relay_V1_Envelope()
        proto.id = "env-1"
        proto.senderAccount = "acct"
        proto.senderDevice = 3
        proto.type = .prekeyMessage
        proto.content = Data([1, 2, 3])
        proto.clientTimestamp = 111
        proto.serverTimestamp = 222
        proto.ephemeral = true

        let envelope = IncomingEnvelope(proto)
        #expect(envelope?.id == "env-1")
        #expect(envelope?.senderAccount == "acct")
        #expect(envelope?.senderDevice == 3)
        #expect(envelope?.message == SecureMessage(kind: .preKey, data: Data([1, 2, 3])))
        #expect(envelope?.clientTimestamp == 111)
        #expect(envelope?.serverTimestamp == 222)
        #expect(envelope?.ephemeral == true)
    }

    @Test func sendOutcomeParsesMismatch() {
        var proto = Relay_V1_SendResponse()
        proto.status = .mismatchedDevices
        proto.missingDevices = [2]
        proto.staleDevices = [1]
        #expect(SendOutcome(proto) == .mismatchedDevices(missing: [2], extra: [], stale: [1]))
    }

    @Test func basicAuthHeaderFormat() {
        let credentials = RelayCredentials(accountId: "abc", deviceId: 1, password: "secret12")
        let expected = "Basic " + Data("abc.1:secret12".utf8).base64EncodedString()
        #expect(credentials.authorizationHeader == expected)
    }
}

// MARK: - Live end-to-end (requires a running relayd)

private final class CountingAllocator: PreKeyIdAllocating, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt32 = 1
    func allocateIds(count: Int) throws -> Range<UInt32> {
        lock.lock()
        defer { lock.unlock() }
        let range = next..<(next + UInt32(count))
        next = range.upperBound
        return range
    }
}

private var liveServerURL: URL? {
    ProcessInfo.processInfo.environment["RELAY_SERVER_URL"].flatMap(URL.init(string:))
}

struct LiveRelayTests {
    /// Registers two accounts, publishes real PQXDH keys, and exchanges an
    /// encrypted message through the actual Go relay over WebSocket.
    @Test(.enabled(if: liveServerURL != nil))
    func endToEndMessageThroughRelay() async throws {
        let baseURL = try #require(liveServerURL)
        let unauthenticated = RelayAPIClient(baseURL: baseURL, credentials: nil)
        let maintainer = PreKeyMaintainer(threshold: 20, batchSize: 5)
        let suffix = UUID().uuidString.prefix(8)

        let aliceCreds = try await unauthenticated.register(username: "alice-\(suffix)", password: "password-a")
        let bobCreds = try await unauthenticated.register(username: "bob-\(suffix)", password: "password-b")
        let aliceAPI = RelayAPIClient(baseURL: baseURL, credentials: aliceCreds)
        let bobAPI = RelayAPIClient(baseURL: baseURL, credentials: bobCreds)

        let alice = try CryptoEngine.makeEphemeral(accountId: aliceCreds.accountId, deviceId: 1)
        let bob = try CryptoEngine.makeEphemeral(accountId: bobCreds.accountId, deviceId: 1)
        try await maintainer.publishInitialKeys(api: aliceAPI, engine: alice, allocator: CountingAllocator())
        let bobAllocator = CountingAllocator()
        try await maintainer.publishInitialKeys(api: bobAPI, engine: bob, allocator: bobAllocator)

        // Alice fetches Bob's bundle, consuming a one-time prekey.
        let bundles = try await aliceAPI.fetchPreKeyBundles(account: bobCreds.accountId)
        let bobBundle = try #require(bundles.first)
        #expect(bobBundle.oneTimePreKey != nil)
        let bobAddress = try ProtocolAddress(name: bobCreds.accountId, deviceId: 1)
        try alice.processPeerBundle(bobBundle, from: bobAddress)

        // Both connect and drain their empty offline queues.
        let bobSocket = RelayWebSocket(baseURL: baseURL, credentials: bobCreds)
        var bobEvents = await bobSocket.connect().makeAsyncIterator()
        guard case .queueDrained = await bobEvents.next() else {
            Issue.record("bob: expected queueDrained first")
            return
        }
        let aliceSocket = RelayWebSocket(baseURL: baseURL, credentials: aliceCreds)
        var aliceEvents = await aliceSocket.connect().makeAsyncIterator()
        guard case .queueDrained = await aliceEvents.next() else {
            Issue.record("alice: expected queueDrained first")
            return
        }

        let plaintext = Data("hello through the relay".utf8)
        let sealed = try alice.encrypt(plaintext, for: bobAddress)
        #expect(sealed.kind == .preKey)
        let outcome = try await aliceSocket.send(
            to: bobCreds.accountId,
            messages: [DeviceMessagePayload(
                deviceId: 1,
                registrationId: bobBundle.registrationId,
                message: sealed
            )],
            clientTimestamp: 12345
        )
        guard case .ok = outcome else {
            Issue.record("send failed: \(outcome)")
            return
        }

        guard case .envelope(let envelope) = await bobEvents.next() else {
            Issue.record("bob: expected an envelope")
            return
        }
        #expect(envelope.senderAccount == aliceCreds.accountId)
        #expect(envelope.clientTimestamp == 12345)
        let aliceAddress = try ProtocolAddress(name: envelope.senderAccount, deviceId: envelope.senderDevice)
        #expect(try bob.decrypt(envelope.message, from: aliceAddress) == plaintext)
        try await bobSocket.ack(envelopeId: envelope.id)

        // Bob's pool is below the threshold, so replenishment uploads.
        let before = try await bobAPI.oneTimePreKeyCount()
        #expect(before == 4)
        #expect(try await maintainer.replenishIfNeeded(api: bobAPI, engine: bob, allocator: bobAllocator))
        #expect(try await bobAPI.oneTimePreKeyCount() == before + 5)

        // A wrong fan-out is rejected with the device diff.
        let mismatch = try await aliceSocket.send(to: bobCreds.accountId, messages: [], clientTimestamp: 1)
        #expect(mismatch == .mismatchedDevices(missing: [1], extra: [], stale: []))

        await aliceSocket.disconnect()
        await bobSocket.disconnect()
    }
}
