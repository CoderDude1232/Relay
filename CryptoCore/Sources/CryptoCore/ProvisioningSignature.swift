//
//  ProvisioningSignature.swift
//  CryptoCore
//
//  Authenticates the device-linking payload. The provisioning box
//  (ProvisioningCipher) is confidential + integrity-protected, but it's an
//  anonymous sealed box: on its own the new device can't prove the payload was
//  produced by a device that actually holds the account's identity key.
//
//  Here the primary signs a transcript binding {this session, the new device's
//  ephemeral key, the identity being granted, and the issued credentials} with
//  the account identity private key. The new device rebuilds the same transcript
//  and verifies it against the identity public key carried in the payload before
//  adopting the identity — so a replayed or substituted-but-well-formed blob is
//  rejected. Byte-in / bool-out so app code needn't touch libsignal.
//

import Foundation
import LibSignalClient

public enum ProvisioningSignature {
    private static let label = Data("Relay Device Provisioning Signature v1".utf8)

    /// Deterministic transcript over the security-critical fields. Built from
    /// explicit fields (not JSON) so both sides agree on the exact bytes.
    private static func transcript(
        sessionId: String,
        recipientEphemeralPublicKey: Data,
        identityPublicKey: Data,
        accountId: String,
        deviceId: UInt32,
        password: String
    ) -> Data {
        var t = label
        t.append(Data(sessionId.utf8))
        t.append(recipientEphemeralPublicKey)
        t.append(identityPublicKey)
        t.append(Data(accountId.utf8))
        var dev = deviceId.littleEndian
        withUnsafeBytes(of: &dev) { t.append(contentsOf: $0) }
        t.append(Data(password.utf8))
        return t
    }

    /// Primary side: sign with the account identity private key.
    public static func sign(
        sessionId: String,
        recipientEphemeralPublicKey: Data,
        accountId: String,
        deviceId: UInt32,
        password: String,
        identityKeyPair: Data
    ) throws -> Data {
        let pair = try IdentityKeyPair(bytes: identityKeyPair)
        let t = transcript(
            sessionId: sessionId,
            recipientEphemeralPublicKey: recipientEphemeralPublicKey,
            identityPublicKey: Data(pair.identityKey.publicKey.serialize()),
            accountId: accountId, deviceId: deviceId, password: password
        )
        return Data(pair.privateKey.generateSignature(message: t))
    }

    /// New-device side: verify against the identity public key in the payload.
    public static func verify(
        _ signature: Data,
        sessionId: String,
        recipientEphemeralPublicKey: Data,
        accountId: String,
        deviceId: UInt32,
        password: String,
        identityKeyPair: Data
    ) -> Bool {
        guard let pair = try? IdentityKeyPair(bytes: identityKeyPair) else { return false }
        let t = transcript(
            sessionId: sessionId,
            recipientEphemeralPublicKey: recipientEphemeralPublicKey,
            identityPublicKey: Data(pair.identityKey.publicKey.serialize()),
            accountId: accountId, deviceId: deviceId, password: password
        )
        return (try? pair.identityKey.publicKey.verifySignature(message: t, signature: signature)) == true
    }
}
