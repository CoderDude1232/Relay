//
//  DeviceProvisioning.swift
//  Relay
//
//  Wire shapes for the reversed device-linking flow (shared account identity).
//  The new device shows LinkQRPayload in a QR; the primary scans it, seals a
//  LinkProvisioningPayload to the new device's ephemeral key, and deposits the
//  ciphertext on the relay for the new device to fetch. Only the QR payload and
//  the encrypted blob ever travel; the identity private key inside
//  LinkProvisioningPayload is encrypted end-to-end and never logged.
//

import Foundation

/// Displayed by the NEW device in its linking QR, scanned by the primary.
/// Small by design — only a rendezvous id, the new device's ephemeral public
/// key, and the relay it created the session on. `Data` fields JSON-encode as
/// base64.
struct LinkQRPayload: Codable {
    var version: Int = 1
    let sessionId: String
    /// 32-byte X25519 public key the primary encrypts the payload to.
    let ephemeralPublicKey: Data
    let serverURL: String
    /// Short, non-PII label for the new device (e.g. "iPhone", "iPad") shown in
    /// the owner's Linked Devices list. Optional for decoding older QR codes.
    var deviceName: String? = nil
}

/// Sealed by the primary, fetched and opened by the new device. Carries the
/// shared account identity key and the new device's freshly minted credentials,
/// plus optional conversation/history sync. Encrypted via `ProvisioningCipher`
/// before it reaches the relay.
struct LinkProvisioningPayload: Codable {
    struct PeerStub: Codable {
        let account: String
        let username: String?
    }
    var version: Int = 1
    /// libsignal `IdentityKeyPair.serialize()` — the account's shared identity.
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
    /// Signature by the account identity key over a transcript binding this
    /// session, the new device's ephemeral key, and the granted credentials.
    /// The new device verifies it before adopting the identity. Optional only
    /// for decoding legacy payloads; new devices reject an absent/invalid one.
    var signature: Data? = nil
}
