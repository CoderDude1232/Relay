//
//  ProvisioningCipher.swift
//  CryptoCore
//
//  End-to-end encryption for the reversed device-linking payload. Follows
//  Signal's ProvisioningCipher shape, simplified to AES-256-GCM:
//
//    - The NEW device generates an ephemeral Curve25519 key-agreement pair and
//      publishes its public half in the QR code (never on the wire).
//    - The PRIMARY generates its own ephemeral pair, does ECDH against the new
//      device's public key, derives a symmetric key via HKDF-SHA256 with a
//      domain-separated info string, and seals the provisioning payload. It
//      ships its ephemeral public key alongside the ciphertext.
//    - The NEW device does the matching ECDH and opens the box.
//
//  The relay only ever stores the resulting opaque blob. The identity private
//  key inside the payload never crosses the wire in the clear. We own this
//  format — there is no external spec to match.
//

import CryptoKit
import Foundation

public enum ProvisioningCipherError: Error, Equatable {
    case malformed
    case unsupportedVersion
}

public enum ProvisioningCipher {
    /// Domain separation: this HKDF info string binds the derived key to this
    /// exact use, so a shared secret can't be repurposed elsewhere.
    static let info = Data("Relay Device Provisioning v1".utf8)
    static let version: UInt8 = 0x01
    static let publicKeyLength = 32

    /// The new device's ephemeral key pair. The public half goes in the QR; the
    /// private half is held only in memory on the new device for the duration of
    /// the linking session and is used once to open the provisioning blob.
    public struct EphemeralKeyPair: Sendable {
        /// Raw 32-byte public key — embed in the QR the primary scans.
        public let publicKey: Data
        /// Raw 32-byte private key — never leaves the new device, never logged.
        public let privateKey: Data

        public init() {
            let sk = Curve25519.KeyAgreement.PrivateKey()
            self.privateKey = sk.rawRepresentation
            self.publicKey = sk.publicKey.rawRepresentation
        }
    }

    /// Primary side: seals `payload` for the new device identified by its
    /// ephemeral public key. Returns `version ‖ primaryEphemeralPub(32) ‖
    /// nonce‖ciphertext‖tag`.
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

    /// New device side: opens a blob produced by `seal`, using the private half
    /// of the ephemeral key whose public half was shown in the QR.
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
