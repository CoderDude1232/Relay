//
//  Models.swift
//  CryptoCore
//
//  Value types crossing the crypto boundary. They mirror the relay's schema
//  but have no networking or protobuf dependency.
//

import Foundation

/// The libsignal ciphertext kind. Maps 1:1 onto the relay's `CiphertextType`.
public enum MessageKind: Sendable, Equatable {
    /// First message of a session; carries the PQXDH handshake.
    case preKey
    /// Double Ratchet message in an established session.
    case message
    /// Group message.
    case senderKey
}

/// A ciphertext and its kind, as produced by `encrypt` and consumed by `decrypt`.
public struct SecureMessage: Sendable, Equatable {
    public let kind: MessageKind
    public let data: Data

    public init(kind: MessageKind, data: Data) {
        self.kind = kind
        self.data = data
    }
}

/// A public one-time prekey.
public struct PublicPreKey: Sendable, Equatable {
    public let id: UInt32
    public let publicKey: Data

    public init(id: UInt32, publicKey: Data) {
        self.id = id
        self.publicKey = publicKey
    }
}

/// A prekey signed by the identity key: the signed EC prekey or the
/// last-resort Kyber prekey.
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

/// Everything a device publishes (PUT /v1/keys). Public material only.
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

/// A peer device's bundle (GET /v1/keys/...). `oneTimePreKey` is nil when the
/// peer's pool is exhausted; the session then uses the signed prekey alone.
public struct PeerPreKeyBundle: Sendable, Equatable {
    public let deviceId: UInt32
    public let mailboxId: String?
    public let registrationId: UInt32
    public let identityKey: Data
    public let signedPreKey: SignedPublicPreKey
    public let kyberPreKey: SignedPublicPreKey
    public let oneTimePreKey: PublicPreKey?

    public init(
        deviceId: UInt32,
        mailboxId: String? = nil,
        registrationId: UInt32,
        identityKey: Data,
        signedPreKey: SignedPublicPreKey,
        kyberPreKey: SignedPublicPreKey,
        oneTimePreKey: PublicPreKey?
    ) {
        self.deviceId = deviceId
        self.mailboxId = mailboxId
        self.registrationId = registrationId
        self.identityKey = identityKey
        self.signedPreKey = signedPreKey
        self.kyberPreKey = kyberPreKey
        self.oneTimePreKey = oneTimePreKey
    }
}

/// A safety number: the 60-digit string users compare and its QR encoding.
public struct SafetyNumber: Sendable, Equatable {
    public let numeric: String
    public let scannable: Data

    public init(numeric: String, scannable: Data) {
        self.numeric = numeric
        self.scannable = scannable
    }
}
