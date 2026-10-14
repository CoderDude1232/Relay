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

    @Test func profileUpdateCarriesAccessKey() throws {
        var content = Relay_Content_Content()
        content.profile.displayName = "Alex"
        content.profile.timestamp = 7
        content.profile.accessKey = Data(repeating: 0xAB, count: 32)

        // The same message encoded by the server's Go code from content.proto,
        // so the Swift and Go generated code agree on field 7.
        let goEncoded = Data(hex: "4a2a0a04416c657818073a20" + String(repeating: "ab", count: 32))
        let data = try content.serializedData()
        #expect(data == goEncoded)
        let decoded = try Relay_Content_Content(serializedBytes: goEncoded)
        #expect(decoded.profile.accessKey == Data(repeating: 0xAB, count: 32))
        #expect(decoded.profile.displayName == "Alex")
        #expect(decoded == content)

        // Older clients send no key; it decodes as empty.
        var old = Relay_Content_ProfileUpdate()
        old.displayName = "Sam"
        #expect(try Relay_Content_ProfileUpdate(serializedBytes: old.serializedData()).accessKey.isEmpty)
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

struct DirectoryDecoyTests {
    @Test func repeatedLookupSendsTheSameRequest() {
        let seed = Data(repeating: 7, count: 32)
        let first = DirectoryBuckets.paddedRequest(real: [0x1234], seed: seed)
        let again = DirectoryBuckets.paddedRequest(real: [0x1234], seed: seed)
        #expect(first == again)
        #expect(Set(first).count == first.count)
        #expect(first.count >= DirectoryBuckets.decoyPaddedRequestSize)
        #expect(first.contains(0x1234))
    }

    @Test func aBucketKeepsItsDecoysInAnyBatch() {
        let seed = Data(repeating: 9, count: 32)
        let alone = Set(DirectoryBuckets.paddedRequest(real: [0x1234], seed: seed))
        let withOthers = Set(DirectoryBuckets.paddedRequest(real: [0x1234, 0x0042, 0xbeef], seed: seed))
        let withOthers2 = Set(DirectoryBuckets.paddedRequest(real: [0x1234, 0x7777], seed: seed))
        // Intersecting every request that included 0x1234 still leaves its
        // own decoys alongside it.
        #expect(alone.intersection(withOthers).intersection(withOthers2).count >= DirectoryBuckets.decoysPerBucket)
    }

    @Test func differentSeedsPickDifferentDecoys() {
        let a = Set(DirectoryBuckets.paddedRequest(real: [0x1234], seed: Data(repeating: 1, count: 32)))
        let b = Set(DirectoryBuckets.paddedRequest(real: [0x1234], seed: Data(repeating: 2, count: 32)))
        #expect(a.intersection(b).count < 20)
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

struct SignInMethodsTests {
    @Test func decodesWithoutTheNewerField() throws {
        let json = Data(#"{"email":false,"passkeys":2,"accountPassword":true,"recoveryKey":false}"#.utf8)
        let methods = try JSONDecoder().decode(SignInMethods.self, from: json)
        #expect(methods == SignInMethods(email: false, passkeys: 2, accountPassword: true, recoveryKey: false))
    }

    @Test func anyOneMethodIsAWayBackIn() {
        #expect(SignInMethods(email: false, passkeys: 1, accountPassword: false, recoveryKey: false).hasWayBackIn)
        #expect(SignInMethods(email: false, passkeys: 0, accountPassword: false, recoveryKey: true).hasWayBackIn)
        #expect(SignInMethods(email: false, passkeys: 0, accountPassword: true, recoveryKey: false).hasWayBackIn)
        #expect(SignInMethods(email: true, passkeys: 0, accountPassword: false, recoveryKey: false).hasWayBackIn)
    }

    @Test func nothingUsableIsNoWayBackIn() {
        #expect(!SignInMethods(email: false, passkeys: 0, accountPassword: false, recoveryKey: false).hasWayBackIn)
        // A password stored by an older build can't sign in until re-entered.
        #expect(!SignInMethods(email: false, passkeys: 0, accountPassword: true, recoveryKey: false,
                               accountPasswordNeedsUpdate: true).hasWayBackIn)
    }
}
