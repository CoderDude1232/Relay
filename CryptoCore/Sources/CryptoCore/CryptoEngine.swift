//
//  CryptoEngine.swift
//  CryptoCore
//
//  The single entry point for all Signal-protocol operations: identity and
//  prekey generation, PQXDH session establishment, and Double Ratchet
//  encrypt/decrypt. Wraps libsignal-client; nothing above this layer
//  touches libsignal types directly.
//

import Foundation
import LibSignalClient

/// All libsignal state stores the engine needs. Stage 2 uses libsignal's
/// in-memory implementation; the secure-storage stage replaces it with
/// SQLCipher-backed stores conforming to the same protocols.
public typealias SignalStores = IdentityKeyStore & PreKeyStore & SignedPreKeyStore
    & KyberPreKeyStore & SessionStore & SenderKeyStore

public enum CryptoEngineError: Error, Equatable {
    /// The incoming payload declared a kind the engine can't decrypt (yet).
    case unsupportedMessageKind
}

public final class CryptoEngine {
    /// Signal's production parameters for safety-number generation.
    private static let fingerprintIterations = 5200
    private static let fingerprintVersion = 2

    public let localAddress: ProtocolAddress
    private let store: any SignalStores
    private let context = NullContext()

    public init(store: any SignalStores, localAddress: ProtocolAddress) {
        self.store = store
        self.localAddress = localAddress
    }

    /// A fresh engine with a newly generated identity, backed by in-memory
    /// stores. State is lost on deinit — for tests and pre-storage stages.
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

    /// The serialized public identity key (what peers see and what safety
    /// numbers are computed from). The private half never leaves the store.
    public func identityKey() throws -> Data {
        try store.identityKeyPair(context: context).identityKey.serialize()
    }

    // MARK: - Prekeys

    /// Generates and stores a signed prekey, a last-resort Kyber prekey and
    /// a batch of one-time prekeys, returning the public halves for upload
    /// to the relay.
    public func generatePreKeyPublication(
        signedPreKeyId: UInt32,
        kyberPreKeyId: UInt32,
        oneTimePreKeyIds: Range<UInt32>
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
            oneTimePreKeys: oneTimeKeys
        )
    }

    // MARK: - Sessions

    /// Runs PQXDH against a fetched peer bundle, establishing an outbound
    /// session with that device. The next `encrypt` for this address yields
    /// a `.preKey` message carrying the handshake.
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
            // Peer's one-time pool is exhausted: degraded but valid.
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
            // Group message: decrypt with the sender's distributed sender key
            // (libsignal finds it from the distribution id embedded in the
            // ciphertext). The SKDM must have been processed beforehand.
            return try LibSignalClient.groupDecrypt(
                message.data,
                from: address,
                store: store,
                context: context
            )
        }
    }

    // MARK: - Sealed sender

    /// The result of decrypting a sealed-sender message: the recovered sender
    /// identity (from the validated certificate) and the inner plaintext.
    public struct SealedSenderDecryptResult: Sendable {
        public let senderAccountId: String
        public let senderDeviceId: UInt32
        public let plaintext: Data
    }

    public enum SealedSenderError: Error, Equatable {
        /// The sender certificate failed validation against the trust root or is expired.
        case invalidCertificate
        /// The wrapped message used a ciphertext type the engine can't decrypt.
        case unsupportedMessageType
    }

    /// Encrypts `plaintext` for `address` as a sealed-sender message: the normal
    /// Double Ratchet (or sender-key) ciphertext wrapped in an outer layer
    /// encrypted to the recipient's identity key, carrying `senderCertificate`.
    /// The relay sees only an opaque blob addressed to the recipient — not the
    /// sender. `senderCertificate` is the serialized cert from the relay's
    /// GET /v1/certificate/delivery; `groupId` is empty for 1:1.
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

    /// Decrypts a sealed-sender blob: unwraps the outer layer with our identity
    /// key, validates the sender certificate against `trustRoot` (33-byte
    /// serialized public key) at `timestampMs`, then decrypts the inner message
    /// from the recovered sender. Throws `SealedSenderError.invalidCertificate`
    /// if the certificate doesn't validate.
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
            plaintext: plaintext
        )
    }

    // MARK: - Groups (sender keys)

    /// Creates (or loads) this device's sender key for `distributionId` and
    /// returns the Sender Key Distribution Message to hand to each group
    /// member over their pairwise session, so they can decrypt our group
    /// messages. A fresh `distributionId` yields a fresh sender key (used to
    /// rotate when a member is removed).
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

    /// Encrypts a group message once with our sender key; the same ciphertext
    /// is fanned out to every member device.
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

    // MARK: - Safety numbers

    /// Computes the safety number between two identities. Both parties must
    /// pass the same stable identifiers (account ids) for their halves to
    /// produce the same 60-digit string.
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

    /// Computes the safety number for a peer using their currently stored
    /// identity key. Returns `nil` when no identity has been recorded yet
    /// (no session established). Account ids are the stable identifiers, so
    /// both parties derive the same 60-digit number.
    public func safetyNumber(withPeer remoteAccount: String) throws -> SafetyNumber? {
        guard let fingerprint = try makeFingerprint(withPeer: remoteAccount) else { return nil }
        return SafetyNumber(
            numeric: fingerprint.displayable.formatted,
            scannable: fingerprint.scannable.encoding
        )
    }

    /// Compares a scannable fingerprint encoding read from the peer's QR code
    /// against the locally computed one. Returns `false` if we have no
    /// identity for the peer yet; throws if the encoding is malformed or uses
    /// an incompatible version. The comparison is order-independent: the
    /// peer's encoding lists their identity first, ours lists it second.
    public func verifyScannedSafetyNumber(
        _ scannedEncoding: Data,
        withPeer remoteAccount: String
    ) throws -> Bool {
        guard let fingerprint = try makeFingerprint(withPeer: remoteAccount) else { return false }
        return try fingerprint.scannable.compare(againstEncoding: scannedEncoding)
    }

    /// Builds the libsignal fingerprint between us and `remoteAccount` from
    /// the stored identities, or `nil` if the peer's identity is unknown.
    private func makeFingerprint(withPeer remoteAccount: String) throws -> Fingerprint? {
        // deviceId is irrelevant: identities are keyed by account (name).
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
