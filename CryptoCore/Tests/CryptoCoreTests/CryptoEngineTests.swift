//
//  CryptoEngineTests.swift
//  CryptoCoreTests
//
//  Validates the full protocol lifecycle against libsignal's real
//  implementation (in-memory stores, prebuilt Rust core): PQXDH handshake,
//  Double Ratchet round-trips, out-of-order delivery, degraded bundles,
//  tampered-signature rejection, and safety numbers.
//

import Foundation
import LibSignalClient
import Testing

@testable import CryptoCore

/// Simulates the relay: turns a device's uploaded publication into the
/// bundle a peer would fetch, optionally consuming a one-time prekey.
private func fetchBundle(
    from publication: PreKeyPublication,
    deviceId: UInt32,
    consumeOneTime: Bool = true
) -> PeerPreKeyBundle {
    PeerPreKeyBundle(
        deviceId: deviceId,
        registrationId: publication.registrationId,
        identityKey: publication.identityKey,
        signedPreKey: publication.signedPreKey,
        kyberPreKey: publication.kyberPreKey,
        oneTimePreKey: consumeOneTime ? publication.oneTimePreKeys.first : nil
    )
}

private func makePeers() throws -> (alice: CryptoEngine, bob: CryptoEngine, aliceAddress: ProtocolAddress, bobAddress: ProtocolAddress) {
    let alice = try CryptoEngine.makeEphemeral(accountId: "alice-account-id", deviceId: 1)
    let bob = try CryptoEngine.makeEphemeral(accountId: "bob-account-id", deviceId: 1)
    return (alice, bob, alice.localAddress, bob.localAddress)
}

struct CryptoEngineTests {
    @Test func fullHandshakeAndRatchetRoundTrip() throws {
        let (alice, bob, aliceAddress, bobAddress) = try makePeers()
        let bobKeys = try bob.generatePreKeyPublication(
            signedPreKeyId: 1,
            kyberPreKeyId: 1,
            oneTimePreKeyIds: 1..<11
        )

        try alice.processPeerBundle(fetchBundle(from: bobKeys, deviceId: 1), from: bobAddress)
        #expect(try alice.hasSession(with: bobAddress))

        // First message carries the PQXDH handshake.
        let hello = Data("hello bob".utf8)
        let first = try alice.encrypt(hello, for: bobAddress)
        #expect(first.kind == .preKey)
        #expect(try bob.decrypt(first, from: aliceAddress) == hello)

        // Bob's session is now established; his reply is a ratchet message.
        let reply = Data("hello alice".utf8)
        let second = try bob.encrypt(reply, for: aliceAddress)
        #expect(second.kind == .message)
        #expect(try alice.decrypt(second, from: bobAddress) == reply)

        // Keep ratcheting in both directions.
        for i in 0..<20 {
            let (sender, receiver, to, from) = i.isMultiple(of: 2)
                ? (alice, bob, bobAddress, aliceAddress)
                : (bob, alice, aliceAddress, bobAddress)
            let plaintext = Data("message \(i)".utf8)
            let sealed = try sender.encrypt(plaintext, for: to)
            #expect(sealed.kind == .message)
            #expect(try receiver.decrypt(sealed, from: from) == plaintext)
        }
    }

    @Test func sealedSenderRoundTrip() throws {
        let aliceId = "11111111-1111-1111-1111-111111111111"
        let bobId = "22222222-2222-2222-2222-222222222222"
        let alice = try CryptoEngine.makeEphemeral(accountId: aliceId, deviceId: 1)
        let bob = try CryptoEngine.makeEphemeral(accountId: bobId, deviceId: 1)
        let bobAddress = bob.localAddress

        // Alice establishes a session to Bob.
        let bobKeys = try bob.generatePreKeyPublication(
            signedPreKeyId: 1, kyberPreKeyId: 1, oneTimePreKeyIds: 1..<11
        )
        try alice.processPeerBundle(fetchBundle(from: bobKeys, deviceId: 1), from: bobAddress)

        // Mint Alice's sealed-sender certificate (what the relay does server-side).
        let trustRoot = PrivateKey.generate()
        let serverKey = PrivateKey.generate()
        let serverCert = try ServerCertificate(keyId: 1, publicKey: serverKey.publicKey, trustRoot: trustRoot)
        let aliceCert = try SenderCertificate(
            sender: SealedSenderAddress(e164: nil, uuidString: aliceId, deviceId: 1),
            publicKey: PublicKey(alice.identityKey()),
            expiration: 2_000_000_000_000,
            signerCertificate: serverCert,
            signerKey: serverKey
        )

        // Alice sends sealed; Bob unwraps, validates against the trust root, and
        // recovers the sender from the certificate.
        let secret = Data("sealed hello".utf8)
        let sealed = try alice.sealedEncrypt(secret, for: bobAddress, senderCertificate: aliceCert.serialize())
        let result = try bob.sealedDecrypt(
            sealed, trustRoot: trustRoot.publicKey.serialize(), timestampMs: 1_700_000_000_000
        )
        #expect(result.plaintext == secret)
        #expect(result.senderAccountId == aliceId)
        #expect(result.senderDeviceId == 1)
    }

    @Test func outOfOrderDelivery() throws {
        let (alice, bob, aliceAddress, bobAddress) = try makePeers()
        let bobKeys = try bob.generatePreKeyPublication(
            signedPreKeyId: 1,
            kyberPreKeyId: 1,
            oneTimePreKeyIds: 1..<2
        )
        try alice.processPeerBundle(fetchBundle(from: bobKeys, deviceId: 1), from: bobAddress)

        let messages = (0..<5).map { Data("out of order \($0)".utf8) }
        let sealed = try messages.map { try alice.encrypt($0, for: bobAddress) }

        // Deliver 0 first (establishes the session), then the rest shuffled.
        #expect(try bob.decrypt(sealed[0], from: aliceAddress) == messages[0])
        for index in [3, 1, 4, 2] {
            #expect(try bob.decrypt(sealed[index], from: aliceAddress) == messages[index])
        }
    }

    @Test func degradedBundleWithoutOneTimePreKey() throws {
        let (alice, bob, aliceAddress, bobAddress) = try makePeers()
        let bobKeys = try bob.generatePreKeyPublication(
            signedPreKeyId: 1,
            kyberPreKeyId: 1,
            oneTimePreKeyIds: 1..<1 // empty pool from the start
        )

        try alice.processPeerBundle(
            fetchBundle(from: bobKeys, deviceId: 1, consumeOneTime: false),
            from: bobAddress
        )
        let plaintext = Data("no one-time prekey".utf8)
        let sealed = try alice.encrypt(plaintext, for: bobAddress)
        #expect(sealed.kind == .preKey)
        #expect(try bob.decrypt(sealed, from: aliceAddress) == plaintext)
    }

    @Test func tamperedSignedPreKeySignatureIsRejected() throws {
        let (alice, bob, _, bobAddress) = try makePeers()
        let bobKeys = try bob.generatePreKeyPublication(
            signedPreKeyId: 1,
            kyberPreKeyId: 1,
            oneTimePreKeyIds: 1..<2
        )

        var tamperedSignature = bobKeys.signedPreKey.signature
        tamperedSignature[0] ^= 0xFF
        let tampered = PeerPreKeyBundle(
            deviceId: 1,
            registrationId: bobKeys.registrationId,
            identityKey: bobKeys.identityKey,
            signedPreKey: SignedPublicPreKey(
                id: bobKeys.signedPreKey.id,
                publicKey: bobKeys.signedPreKey.publicKey,
                signature: tamperedSignature
            ),
            kyberPreKey: bobKeys.kyberPreKey,
            oneTimePreKey: bobKeys.oneTimePreKeys.first
        )

        #expect(throws: (any Error).self) {
            try alice.processPeerBundle(tampered, from: bobAddress)
        }
    }

    @Test func oneTimePreKeyIsConsumedOnUse() throws {
        // Two senders must not be able to reuse the same one-time prekey:
        // after the first prekey message consumes it from Bob's store, a
        // second handshake referencing the same key id must fail to decrypt.
        let (alice, bob, aliceAddress, bobAddress) = try makePeers()
        let carol = try CryptoEngine.makeEphemeral(accountId: "carol-account-id", deviceId: 1)
        let bobKeys = try bob.generatePreKeyPublication(
            signedPreKeyId: 1,
            kyberPreKeyId: 1,
            oneTimePreKeyIds: 1..<2
        )
        let sameBundle = fetchBundle(from: bobKeys, deviceId: 1)

        try alice.processPeerBundle(sameBundle, from: bobAddress)
        try carol.processPeerBundle(sameBundle, from: bobAddress)

        let fromAlice = try alice.encrypt(Data("from alice".utf8), for: bobAddress)
        let fromCarol = try carol.encrypt(Data("from carol".utf8), for: bobAddress)

        #expect(try bob.decrypt(fromAlice, from: aliceAddress) == Data("from alice".utf8))
        #expect(throws: (any Error).self) {
            _ = try bob.decrypt(fromCarol, from: carol.localAddress)
        }
    }

    @Test func safetyNumbersMatchAndDetectIdentityChange() throws {
        let (alice, bob, _, _) = try makePeers()
        let aliceIdentity = try alice.identityKey()
        let bobIdentity = try bob.identityKey()

        let aliceView = try CryptoEngine.safetyNumber(
            localIdentifier: "alice-account-id",
            localIdentityKey: aliceIdentity,
            remoteIdentifier: "bob-account-id",
            remoteIdentityKey: bobIdentity
        )
        let bobView = try CryptoEngine.safetyNumber(
            localIdentifier: "bob-account-id",
            localIdentityKey: bobIdentity,
            remoteIdentifier: "alice-account-id",
            remoteIdentityKey: aliceIdentity
        )
        #expect(aliceView.numeric == bobView.numeric)
        #expect(aliceView.numeric.count == 60)

        // A different identity key (e.g. Bob re-registered) must change it.
        let impostor = try CryptoEngine.makeEphemeral(accountId: "bob-account-id", deviceId: 1)
        let impostorView = try CryptoEngine.safetyNumber(
            localIdentifier: "alice-account-id",
            localIdentityKey: aliceIdentity,
            remoteIdentifier: "bob-account-id",
            remoteIdentityKey: try impostor.identityKey()
        )
        #expect(impostorView.numeric != aliceView.numeric)
    }

    @Test func groupSenderKeyRoundTripAndRotation() throws {
        // Three members in a group. Alice distributes her sender key to Bob
        // and Carol, then encrypts once; both decrypt the same ciphertext.
        let alice = try CryptoEngine.makeEphemeral(accountId: "alice", deviceId: 1)
        let bob = try CryptoEngine.makeEphemeral(accountId: "bob", deviceId: 1)
        let carol = try CryptoEngine.makeEphemeral(accountId: "carol", deviceId: 1)
        let distributionId = UUID()

        let skdm = try alice.senderKeyDistributionMessage(distributionId: distributionId)
        try bob.processSenderKeyDistribution(skdm, from: alice.localAddress)
        try carol.processSenderKeyDistribution(skdm, from: alice.localAddress)

        let message = Data("hello group".utf8)
        let sealed = try alice.groupEncrypt(message, distributionId: distributionId)
        #expect(sealed.kind == .senderKey)
        #expect(try bob.decrypt(sealed, from: alice.localAddress) == message)
        #expect(try carol.decrypt(sealed, from: alice.localAddress) == message)

        // A second message keeps ratcheting.
        let message2 = Data("second".utf8)
        let sealed2 = try alice.groupEncrypt(message2, distributionId: distributionId)
        #expect(try bob.decrypt(sealed2, from: alice.localAddress) == message2)

        // Rotation: a new distribution id is a fresh sender key. Carol (who
        // does NOT get the new SKDM — simulating a removed member) cannot
        // decrypt; Bob (re-distributed) can.
        let newDistributionId = UUID()
        let rotated = try alice.senderKeyDistributionMessage(distributionId: newDistributionId)
        try bob.processSenderKeyDistribution(rotated, from: alice.localAddress)
        let post = try alice.groupEncrypt(Data("after rotation".utf8), distributionId: newDistributionId)
        #expect(try bob.decrypt(post, from: alice.localAddress) == Data("after rotation".utf8))
        #expect(throws: (any Error).self) {
            _ = try carol.decrypt(post, from: alice.localAddress)
        }
    }

    @Test func attachmentSealAndOpenRoundTrip() throws {
        let plaintext = Data((0..<5000).map { _ in UInt8.random(in: 0...255) })
        let sealed = try AttachmentCipher.seal(plaintext)
        #expect(sealed.key.count == 32)
        #expect(sealed.digest.count == 32)
        #expect(sealed.ciphertext != plaintext)

        // Correct key + digest round-trips.
        #expect(try AttachmentCipher.open(sealed.ciphertext, key: sealed.key, digest: sealed.digest) == plaintext)

        // Tampered ciphertext fails the digest check before decryption.
        var tampered = sealed.ciphertext
        tampered[tampered.count / 2] ^= 0xFF
        #expect(throws: AttachmentCipherError.digestMismatch) {
            _ = try AttachmentCipher.open(tampered, key: sealed.key, digest: sealed.digest)
        }

        // Wrong key fails authentication.
        #expect(throws: (any Error).self) {
            _ = try AttachmentCipher.open(sealed.ciphertext, key: Data(count: 32), digest: sealed.digest)
        }
    }

    @Test func perPeerSafetyNumberAndScanVerification() throws {
        let (alice, bob, aliceAddress, bobAddress) = try makePeers()
        let bobKeys = try bob.generatePreKeyPublication(
            signedPreKeyId: 1, kyberPreKeyId: 1, oneTimePreKeyIds: 1..<11
        )
        // Alice establishes a session, so she now stores Bob's identity.
        try alice.processPeerBundle(fetchBundle(from: bobKeys, deviceId: 1), from: bobAddress)
        // Reverse direction so Bob stores Alice's identity too.
        let hello = try alice.encrypt(Data("hi".utf8), for: bobAddress)
        _ = try bob.decrypt(hello, from: aliceAddress)

        let aliceView = try #require(try alice.safetyNumber(withPeer: "bob-account-id"))
        let bobView = try #require(try bob.safetyNumber(withPeer: "alice-account-id"))
        #expect(aliceView.numeric.count == 60)
        #expect(aliceView.numeric == bobView.numeric)

        // Scanning the peer's QR verifies — the encoding is order-independent.
        #expect(try alice.verifyScannedSafetyNumber(bobView.scannable, withPeer: "bob-account-id"))
        #expect(try bob.verifyScannedSafetyNumber(aliceView.scannable, withPeer: "alice-account-id"))

        // Unknown peer: no session yet, so nil / false rather than throwing.
        #expect(try alice.safetyNumber(withPeer: "carol-account-id") == nil)
        #expect(try alice.verifyScannedSafetyNumber(bobView.scannable, withPeer: "carol-account-id") == false)
    }
}
