//
//  ProvisioningCipher.swift
//  CryptoCore
//
//  Encryption for the device-linking payload, modelled on Signal's
//  ProvisioningCipher but using AES-256-GCM:
//
//    - The new device generates an ephemeral Curve25519 pair and shows the
//      public half in the QR code. It is never sent over the network.
//    - The primary generates its own ephemeral pair, does ECDH with the new
//      device's key, derives a key with HKDF-SHA256 and a domain-separated
//      info string, and seals the payload, prefixed by its ephemeral public key.
//    - The new device does the matching ECDH and opens the box.
//
//  The relay only stores the opaque blob.
//

import CryptoKit
import Foundation

public enum ProvisioningCipherError: Error, Equatable {
    case malformed
    case unsupportedVersion
}

public enum ProvisioningCipher {
    /// HKDF info string, binding the derived key to this one use.
    static let info = Data("Relay Device Provisioning v1".utf8)
    static let version: UInt8 = 0x01
    static let publicKeyLength = 32

    /// The new device's ephemeral pair. The private half stays in memory on the
    /// new device for the linking session and is used once to open the blob.
    public struct EphemeralKeyPair: Sendable {
        /// Raw 32-byte public key, embedded in the QR.
        public let publicKey: Data
        /// Raw 32-byte private key. Never leaves the new device or gets logged.
        public let privateKey: Data

        public init() {
            let sk = Curve25519.KeyAgreement.PrivateKey()
            self.privateKey = sk.rawRepresentation
            self.publicKey = sk.publicKey.rawRepresentation
        }
    }

    /// Primary side: seals `payload` for the new device's ephemeral public key.
    /// Returns `version || primaryEphemeralPub(32) || nonce || ciphertext || tag`.
    public static func seal(_ payload: Data, toEphemeralPublicKey recipientPublicKey: Data) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32
        )
        let box = try AES.GCM.seal(payload, using: key)
        guard let combined = box.combined else { throw ProvisioningCipherError.malformed }
        var blob = Data([version])
        blob.append(ephemeral.publicKey.rawRepresentation)
        blob.append(combined)
        return blob
    }

    /// New-device side: opens a blob from `seal` with the ephemeral private key
    /// whose public half was shown in the QR.
    public static func open(_ blob: Data, ephemeralPrivateKey privateKeyRaw: Data) throws -> Data {
        let data = Data(blob) // normalize slice indices
        guard data.count > 1 + publicKeyLength else { throw ProvisioningCipherError.malformed }
        guard data[0] == version else { throw ProvisioningCipherError.unsupportedVersion }
        let senderPublicKey = data.subdata(in: 1 ..< (1 + publicKeyLength))
        let combined = data.subdata(in: (1 + publicKeyLength) ..< data.count)
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw)
        let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: sender)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32
        )
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }
}
