//
//  DeviceProvisioning.swift
//  Relay
//
//  Device-linking payloads. The new device shows LinkQRPayload; the primary
//  scans it, seals a LinkProvisioningPayload to the new device's ephemeral key
//  and leaves the ciphertext on the relay. The identity private key inside is
//  end-to-end encrypted and must never be logged.
//

import CryptoKit
import Foundation

/// Shown in the new device's linking QR code. Kept small to fit the QR.
/// A six-digit code both devices show while linking: a hash of the QR's
/// one-time key and the account being joined. Someone who saw the QR and
/// raced in their own account would make the new device show a different
/// code (and username) from the one on the user's existing device.
enum LinkCode {
    static func make(ephemeralPublicKey: Data, accountId: String) -> String {
        var input = Data("relay-link-code-v1".utf8)
        input.append(ephemeralPublicKey)
        input.append(Data(accountId.utf8))
        let digest = SHA256.hash(data: input)
        let n = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", n)
        return digits.prefix(3) + " " + digits.suffix(3)
    }
}

struct LinkQRPayload: Codable {
    var version: Int = 1
    let sessionId: String
    /// 32-byte X25519 public key the primary encrypts the payload to.
    let ephemeralPublicKey: Data
    let serverURL: String
    /// Non-PII label ("iPhone", "iPad") for the Linked Devices list. Optional
    /// for older QR codes.
    var deviceName: String? = nil
}

/// Sealed by the primary with `ProvisioningCipher`: the shared identity key,
/// the new device's credentials, and the key to the account's encrypted
/// chat list and history (or, without one, an optional history copy).
struct LinkProvisioningPayload: Codable {
    struct PeerStub: Codable {
        let account: String
        let username: String?
    }
    var version: Int = 1
    /// libsignal `IdentityKeyPair.serialize()` of the shared account identity.
    let identityKeyPair: Data
    let accountId: String
    let username: String?
    let deviceId: UInt32
    let password: String
    let serverURL: String
    let peers: [PeerStub]
    /// Encrypted message-history blob reference (nil = no history sync).
    let historyId: String?
    let historyKey: Data?
    let historyDigest: Data?
    /// The chat list's content key. With it the new device opens the
    /// encrypted chat list and message-history backup itself, so nothing
    /// else is copied across. Nil for accounts without them.
    var chatListKey: Data? = nil
    /// Signature by the account identity key over a transcript binding this
    /// session, the new device's ephemeral key, and the granted credentials.
    /// Optional only so legacy payloads decode; the new device rejects a
    /// missing or invalid signature before adopting the identity.
    var signature: Data? = nil
}
