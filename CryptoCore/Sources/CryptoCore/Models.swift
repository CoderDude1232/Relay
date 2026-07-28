//
//  Models.swift
//  CryptoCore
//
//  Plain value types crossing the crypto boundary. These mirror the relay's
//  REST/WebSocket schema but deliberately have no networking or protobuf
//  dependency — CryptoCore stays a pure crypto module.
//

import Foundation

/// The kind of libsignal ciphertext, so the receiving side knows how to
/// decrypt. Maps 1:1 onto the relay's `CiphertextType` protobuf enum.
public enum MessageKind: Sendable, Equatable {
    /// PreKeySignalMessage: first message of a session, carries the PQXDH
    /// handshake material.
    case preKey
    /// SignalMessage: normal Double Ratchet message in an established session.
    case message
    /// SenderKeyMessage: group message (groups phase).
    case senderKey
}

/// A ciphertext together with its kind — what `encrypt` produces and
/// `decrypt` consumes. The `data` bytes travel opaquely through the relay.
public struct SecureMessage: Sendable, Equatable {
    public let kind: MessageKind
    public let data: Data

    public init(kind: MessageKind, data: Data) {
        self.kind = kind
        self.data = data
    }
}

/// A public one-time prekey as uploaded to / served by the relay.
public struct PublicPreKey: Sendable, Equatable {
    public let id: UInt32
    public let publicKey: Data

    public init(id: UInt32, publicKey: Data) {
        self.id = id
        self.publicKey = publicKey
    }
}

/// A public prekey signed by the device's identity key (the signed EC
/// prekey, or the last-resort Kyber prekey — both share this shape).
public struct SignedPublicPreKey: Sendable, Equatable {
    public let id: UInt32
    public let publicKey: Data
    public let signature: Data

    public init(id: UInt32, publicKey: Data, signature: Data) {
        self.id = id
        self.publicKey = publicKey
        self.signature = signature
    }
}

/// Everything a device publishes (PUT /v1/keys) so peers can establish
/// PQXDH sessions with it. Contains only public material.
public struct PreKeyPublication: Sendable, Equatable {
    public let registrationId: UInt32
    public let identityKey: Data
    public let signedPreKey: SignedPublicPreKey
    /// Last-resort Kyber prekey; PQXDH requires one in every bundle.
    public let kyberPreKey: SignedPublicPreKey
    public let oneTimePreKeys: [PublicPreKey]

    public init(
        registrationId: UInt32,
        identityKey: Data,
        signedPreKey: SignedPublicPreKey,
        kyberPreKey: SignedPublicPreKey,
        oneTimePreKeys: [PublicPreKey]
    ) {
        self.registrationId = registrationId
        self.identityKey = identityKey
        self.signedPreKey = signedPreKey
        self.kyberPreKey = kyberPreKey
        self.oneTimePreKeys = oneTimePreKeys
    }
}

/// A peer device's bundle as fetched from the relay (GET /v1/keys/…).
/// `oneTimePreKey` is nil when the peer's pool is exhausted — the session
/// is then established from the signed prekey alone (degraded but valid).
public struct PeerPreKeyBundle: Sendable, Equatable {
    public let deviceId: UInt32
    public let registrationId: UInt32
    public let identityKey: Data
    public let signedPreKey: SignedPublicPreKey
    public let kyberPreKey: SignedPublicPreKey
    public let oneTimePreKey: PublicPreKey?

    public init(
        deviceId: UInt32,
        registrationId: UInt32,
        identityKey: Data,
        signedPreKey: SignedPublicPreKey,
        kyberPreKey: SignedPublicPreKey,
        oneTimePreKey: PublicPreKey?
    ) {
        self.deviceId = deviceId
        self.registrationId = registrationId
        self.identityKey = identityKey
        self.signedPreKey = signedPreKey
        self.kyberPreKey = kyberPreKey
        self.oneTimePreKey = oneTimePreKey
    }
}

/// A safety number for out-of-band identity verification: the 60-digit
/// numeric string users compare, and the scannable encoding for QR codes.
public struct SafetyNumber: Sendable, Equatable {
    public let numeric: String
    public let scannable: Data

    public init(numeric: String, scannable: Data) {
        self.numeric = numeric
        self.scannable = scannable
    }
}
