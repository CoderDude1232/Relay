//
//  CryptoEngine.swift
//  CryptoCore
//
//  Entry point for all Signal-protocol operations: identity and prekey
//  generation, PQXDH session setup, and Double Ratchet encrypt/decrypt.
//  Nothing above this layer touches libsignal types directly.
//

import Foundation
import LibSignalClient

/// The libsignal stores the engine needs: in-memory in tests, SQLCipher-backed
/// in the app.
public typealias SignalStores = IdentityKeyStore & PreKeyStore & SignedPreKeyStore
    & KyberPreKeyStore & SessionStore & SenderKeyStore

public enum CryptoEngineError: Error, Equatable {
    /// The payload declared a kind the engine can't decrypt.
    case unsupportedMessageKind
}

public final class CryptoEngine {
    /// Signal's production iteration count for safety numbers.
    private static let fingerprintIterations = 5200
    private static let fingerprintVersion = 2

    public let localAddress: ProtocolAddress
    private let store: any SignalStores
    private let context = NullContext()

    public init(store: any SignalStores, localAddress: ProtocolAddress) {
        self.store = store
        self.localAddress = localAddress
    }

    /// An engine with a new identity on in-memory stores, for tests. State is
    /// lost on deinit.
    public static func makeEphemeral(accountId: String, deviceId: UInt32) throws -> CryptoEngine {
        let store = InMemorySignalProtocolStore(
            identity: .generate(),
            registrationId: UInt32.random(in: 1...0x3FFF)
        )
        return CryptoEngine(
            store: store,
            localAddress: try ProtocolAddress(name: accountId, deviceId: deviceId)
        )
    }

    // MARK: - Identity

    public func registrationId() throws -> UInt32 {
        try store.localRegistrationId(context: context)
    }

    /// Signs `message` with the account identity key. Every device of the
    /// account holds that key and the relay never does, so a valid signature
    /// proves it came from one of our own devices.
    public func signWithIdentity(_ message: Data) throws -> Data {
        Data(try store.identityKeyPair(context: context).privateKey.generateSignature(message: message))
    }

    /// Verifies a signature made by `signWithIdentity` on any of our devices.
    public func verifyOwnIdentitySignature(_ signature: Data, message: Data) -> Bool {
        guard let pair = try? store.identityKeyPair(context: context) else { return false }
        return (try? pair.identityKey.publicKey.verifySignature(message: message, signature: signature)) == true
    }

    /// The serialized public identity key. The private half never leaves the store.
    public func identityKey() throws -> Data {
        try store.identityKeyPair(context: context).identityKey.serialize()
    }

    // MARK: - Prekeys

    /// Generates and stores a signed prekey, a last-resort Kyber prekey and a
    /// batch of one-time prekeys, returning the public halves for upload.
    /// Bit set on one-time Kyber prekey ids. Ordinary ids come from one
    /// counter that never gets near it, so the store can tell a one-time key
    /// (deleted after use) from the reusable last-resort one.
    public static let oneTimeKyberIdFlag: UInt32 = 0x0080_0000

    public func generatePreKeyPublication(
        signedPreKeyId: UInt32,
        kyberPreKeyId: UInt32,
        oneTimePreKeyIds: Range<UInt32>,
        oneTimeKyberPreKeyIds: Range<UInt32> = 0..<0
    ) throws -> PreKeyPublication {
        let identityKeyPair = try store.identityKeyPair(context: context)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)

        let signedPrivate = PrivateKey.generate()
        let signedPublic = signedPrivate.publicKey.serialize()
        let signedSignature = identityKeyPair.privateKey.generateSignature(message: signedPublic)
        try store.storeSignedPreKey(
            SignedPreKeyRecord(
                id: signedPreKeyId,
                timestamp: now,
                privateKey: signedPrivate,
                signature: signedSignature
            ),
            id: signedPreKeyId,
            context: context
        )

        let kyberPair = KEMKeyPair.generate()
        let kyberPublic = kyberPair.publicKey.serialize()
        let kyberSignature = identityKeyPair.privateKey.generateSignature(message: kyberPublic)
        try store.storeKyberPreKey(
            KyberPreKeyRecord(
                id: kyberPreKeyId,
                timestamp: now,
                keyPair: kyberPair,
                signature: kyberSignature
            ),
            id: kyberPreKeyId,
            context: context
        )

        var oneTimeKeys: [PublicPreKey] = []
        oneTimeKeys.reserveCapacity(oneTimePreKeyIds.count)
        for id in oneTimePreKeyIds {
            let privateKey = PrivateKey.generate()
            try store.storePreKey(
                PreKeyRecord(id: id, privateKey: privateKey),
                id: id,
                context: context
            )
            oneTimeKeys.append(PublicPreKey(id: id, publicKey: privateKey.publicKey.serialize()))
        }

        var oneTimeKyberKeys: [SignedPublicPreKey] = []
        oneTimeKyberKeys.reserveCapacity(oneTimeKyberPreKeyIds.count)
        for base in oneTimeKyberPreKeyIds {
            let id = base | Self.oneTimeKyberIdFlag
            let pair = KEMKeyPair.generate()
            let publicKey = pair.publicKey.serialize()
            let signature = identityKeyPair.privateKey.generateSignature(message: publicKey)
            try store.storeKyberPreKey(
                KyberPreKeyRecord(id: id, timestamp: now, keyPair: pair, signature: signature),
                id: id,
                context: context
            )
            oneTimeKyberKeys.append(SignedPublicPreKey(id: id, publicKey: publicKey, signature: Data(signature)))
        }

        return PreKeyPublication(
            registrationId: try registrationId(),
            identityKey: try identityKey(),
            signedPreKey: SignedPublicPreKey(
                id: signedPreKeyId,
                publicKey: signedPublic,
                signature: Data(signedSignature)
            ),
            kyberPreKey: SignedPublicPreKey(
                id: kyberPreKeyId,
                publicKey: kyberPublic,
                signature: Data(kyberSignature)
            ),
            oneTimePreKeys: oneTimeKeys,
            oneTimeKyberPreKeys: oneTimeKyberKeys
        )
    }

    // MARK: - Sessions

    /// Runs PQXDH against a peer bundle. The next `encrypt` for this address
    /// yields a `.preKey` message carrying the handshake.
    public func processPeerBundle(_ bundle: PeerPreKeyBundle, from address: ProtocolAddress) throws {
        let identity = try IdentityKey(bytes: bundle.identityKey)
        let signedPreKey = try PublicKey(bundle.signedPreKey.publicKey)
        let kyberPreKey = try KEMPublicKey(bundle.kyberPreKey.publicKey)

        let libsignalBundle: PreKeyBundle
        if let oneTime = bundle.oneTimePreKey {
            libsignalBundle = try PreKeyBundle(
                registrationId: bundle.registrationId,
                deviceId: bundle.deviceId,
                prekeyId: oneTime.id,
                prekey: try PublicKey(oneTime.publicKey),
                signedPrekeyId: bundle.signedPreKey.id,
                signedPrekey: signedPreKey,
                signedPrekeySignature: bundle.signedPreKey.signature,
                identity: identity,
                kyberPrekeyId: bundle.kyberPreKey.id,
                kyberPrekey: kyberPreKey,
                kyberPrekeySignature: bundle.kyberPreKey.signature
            )
        } else {
            // The peer's one-time pool is exhausted; the signed prekey alone is valid.
            libsignalBundle = try PreKeyBundle(
                registrationId: bundle.registrationId,
                deviceId: bundle.deviceId,
                signedPrekeyId: bundle.signedPreKey.id,
                signedPrekey: signedPreKey,
                signedPrekeySignature: bundle.signedPreKey.signature,
                identity: identity,
                kyberPrekeyId: bundle.kyberPreKey.id,
                kyberPrekey: kyberPreKey,
                kyberPrekeySignature: bundle.kyberPreKey.signature
            )
        }

        try processPreKeyBundle(
            libsignalBundle,
            for: address,
            ourAddress: localAddress,
            sessionStore: store,
            identityStore: store,
            context: context
        )
    }

    public func hasSession(with address: ProtocolAddress) throws -> Bool {
        try store.loadSession(for: address, context: context) != nil
    }

    // MARK: - Encrypt / decrypt

    public func encrypt(_ plaintext: Data, for address: ProtocolAddress) throws -> SecureMessage {
        let ciphertext = try signalEncrypt(
            message: plaintext,
            for: address,
            localAddress: localAddress,
            sessionStore: store,
            identityStore: store,
            context: context
        )
        let kind: MessageKind
        switch ciphertext.messageType {
        case .preKey: kind = .preKey
        case .senderKey: kind = .senderKey
        default: kind = .message
        }
        return SecureMessage(kind: kind, data: ciphertext.serialize())
    }

    public func decrypt(_ message: SecureMessage, from address: ProtocolAddress) throws -> Data {
        switch message.kind {
        case .preKey:
            return try signalDecryptPreKey(
                message: PreKeySignalMessage(bytes: message.data),
                from: address,
                localAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: context
            )
        case .message:
            return try signalDecrypt(
                message: SignalMessage(bytes: message.data),
                from: address,
                to: localAddress,
                sessionStore: store,
                identityStore: store,
                context: context
            )
        case .senderKey:
            // libsignal finds the sender key from the distribution id in the
            // ciphertext. The SKDM must already have been processed.
            return try LibSignalClient.groupDecrypt(
                message.data,
                from: address,
                store: store,
                context: context
            )
        }
    }

    // MARK: - Sealed sender

    /// A decrypted sealed-sender message: the sender from the validated
    /// certificate and the inner plaintext.
    public struct SealedSenderDecryptResult: Sendable {
        public let senderAccountId: String
        public let senderDeviceId: UInt32
        /// The sender's username as attested in the certificate (libsignal's
        /// sender_e164 field), if present.
        public let senderUsername: String?
        public let plaintext: Data
    }

    public enum SealedSenderError: Error, Equatable {
        /// The sender certificate is expired or doesn't chain to the trust root.
        case invalidCertificate
        /// The wrapped message used a ciphertext type the engine can't decrypt.
        case unsupportedMessageType
    }

    /// Encrypts `plaintext` as a sealed-sender message: the ratchet or sender-key
    /// ciphertext wrapped in an outer layer encrypted to the recipient's identity
    /// key and carrying `senderCertificate`, so the relay never sees the sender.
    /// `senderCertificate` comes from GET /v1/certificate/delivery; `groupId` is
    /// empty for 1:1.
    public func sealedEncrypt(
        _ plaintext: Data,
        for address: ProtocolAddress,
        senderCertificate: Data,
        groupId: Data = Data()
    ) throws -> Data {
        let cert = try SenderCertificate(senderCertificate)
        let ciphertext = try signalEncrypt(
            message: plaintext,
            for: address,
            localAddress: localAddress,
            sessionStore: store,
            identityStore: store,
            context: context
        )
        let content = try UnidentifiedSenderMessageContent(
            ciphertext,
            from: cert,
            contentHint: .default,
            groupId: groupId
        )
        return try LibSignalClient.sealedSenderEncrypt(
            content,
            for: address,
            identityStore: store,
            context: context
        )
    }

    /// Unwraps a sealed-sender blob with our identity key, validates the sender
    /// certificate against `trustRoot` (33-byte serialized key) at `timestampMs`,
    /// then decrypts the inner message. Throws `.invalidCertificate` if validation
    /// fails.
    public func sealedDecrypt(
        _ sealed: Data,
        trustRoot: Data,
        timestampMs: UInt64
    ) throws -> SealedSenderDecryptResult {
        let usmc = try UnidentifiedSenderMessageContent(
            message: sealed,
            identityStore: store,
            context: context
        )
        let cert = usmc.senderCertificate
        let root = try PublicKey(trustRoot)
        guard cert.validate(trustRoot: root, time: timestampMs) else {
            throw SealedSenderError.invalidCertificate
        }
        let sender = cert.sender
        let senderAddress = try ProtocolAddress(name: sender.uuidString, deviceId: sender.deviceId)

        let plaintext: Data
        switch usmc.messageType {
        case .preKey:
            plaintext = try signalDecryptPreKey(
                message: PreKeySignalMessage(bytes: usmc.contents),
                from: senderAddress,
                localAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: context
            )
        case .senderKey:
            plaintext = try LibSignalClient.groupDecrypt(
                usmc.contents,
                from: senderAddress,
                store: store,
                context: context
            )
        case .whisper:
            plaintext = try signalDecrypt(
                message: SignalMessage(bytes: usmc.contents),
                from: senderAddress,
                to: localAddress,
                sessionStore: store,
                identityStore: store,
                context: context
            )
        default:
            throw SealedSenderError.unsupportedMessageType
        }
        return SealedSenderDecryptResult(
            senderAccountId: sender.uuidString,
            senderDeviceId: sender.deviceId,
            senderUsername: cert.senderE164.flatMap { $0.isEmpty ? nil : $0 },
            plaintext: plaintext
        )
    }

    // MARK: - Groups (sender keys)

    /// Creates or loads our sender key for `distributionId` and returns the
    /// distribution message to send each member over their pairwise session.
    /// A new `distributionId` gives a new sender key, used to rotate when a
    /// member is removed.
    public func senderKeyDistributionMessage(distributionId: UUID) throws -> Data {
        let skdm = try SenderKeyDistributionMessage(
            from: localAddress,
            distributionId: distributionId,
            store: store,
            context: context
        )
        return skdm.serialize()
    }

    /// Processes a peer's SKDM so we can later decrypt their group messages.
    public func processSenderKeyDistribution(_ data: Data, from address: ProtocolAddress) throws {
        let skdm = try SenderKeyDistributionMessage(bytes: data)
        try LibSignalClient.processSenderKeyDistributionMessage(
            skdm,
            from: address,
            store: store,
            context: context
        )
    }

    /// Encrypts once with our sender key; the same ciphertext goes to every
    /// member device.
    public func groupEncrypt(_ plaintext: Data, distributionId: UUID) throws -> SecureMessage {
        let ciphertext = try LibSignalClient.groupEncrypt(
            plaintext,
            from: localAddress,
            distributionId: distributionId,
            store: store,
            context: context
        )
        return SecureMessage(kind: .senderKey, data: ciphertext.serialize())
    }

    /// Sealed-sender group send: encrypts `plaintext` once with our sender key,
    /// then seals that single ciphertext to each recipient device. Returns one
    /// sealed blob per address, in order. Recipients need our SKDM already.
    public func sealedGroupEncrypt(
        _ plaintext: Data,
        distributionId: UUID,
        senderCertificate: Data,
        recipients: [ProtocolAddress]
    ) throws -> [Data] {
        let cert = try SenderCertificate(senderCertificate)
        let ciphertext = try LibSignalClient.groupEncrypt(
            plaintext,
            from: localAddress,
            distributionId: distributionId,
            store: store,
            context: context
        )
        let content = try UnidentifiedSenderMessageContent(
            ciphertext,
            from: cert,
            contentHint: .default,
            groupId: Data()
        )
        return try recipients.map { address in
            try LibSignalClient.sealedSenderEncrypt(content, for: address, identityStore: store, context: context)
        }
    }

    // MARK: - Safety numbers

    /// The safety number between two identities. Both sides must pass the same
    /// stable identifiers (account ids) to get the same 60-digit string.
    public static func safetyNumber(
        localIdentifier: String,
        localIdentityKey: Data,
        remoteIdentifier: String,
        remoteIdentityKey: Data
    ) throws -> SafetyNumber {
        let fingerprint = try NumericFingerprintGenerator(iterations: fingerprintIterations).create(
            version: fingerprintVersion,
            localIdentifier: Data(localIdentifier.utf8),
            localKey: PublicKey(localIdentityKey),
            remoteIdentifier: Data(remoteIdentifier.utf8),
            remoteKey: PublicKey(remoteIdentityKey)
        )
        return SafetyNumber(
            numeric: fingerprint.displayable.formatted,
            scannable: fingerprint.scannable.encoding
        )
    }

    /// The safety number with a peer from their stored identity key, or nil if
    /// none is recorded yet.
    public func safetyNumber(withPeer remoteAccount: String) throws -> SafetyNumber? {
        guard let fingerprint = try makeFingerprint(withPeer: remoteAccount) else { return nil }
        return SafetyNumber(
            numeric: fingerprint.displayable.formatted,
            scannable: fingerprint.scannable.encoding
        )
    }

    /// Checks a scanned QR fingerprint against ours. Returns false if the peer's
    /// identity is unknown; throws on a malformed or incompatible encoding. The
    /// comparison is order-independent.
    public func verifyScannedSafetyNumber(
        _ scannedEncoding: Data,
        withPeer remoteAccount: String
    ) throws -> Bool {
        guard let fingerprint = try makeFingerprint(withPeer: remoteAccount) else { return false }
        return try fingerprint.scannable.compare(againstEncoding: scannedEncoding)
    }

    /// The fingerprint with `remoteAccount` from stored identities, or nil if
    /// the peer's identity is unknown.
    private func makeFingerprint(withPeer remoteAccount: String) throws -> Fingerprint? {
        // The identity key is per account and shared by all of the peer's
        // devices, so device 1 holds the canonical copy.
        let address = try ProtocolAddress(name: remoteAccount, deviceId: 1)
        guard let remoteIdentity = try store.identity(for: address, context: context) else { return nil }
        let localIdentity = try store.identityKeyPair(context: context).identityKey
        return try NumericFingerprintGenerator(iterations: Self.fingerprintIterations).create(
            version: Self.fingerprintVersion,
            localIdentifier: Data(localAddress.name.utf8),
            localKey: localIdentity.publicKey,
            remoteIdentifier: Data(remoteAccount.utf8),
            remoteKey: remoteIdentity.publicKey
        )
    }
}
