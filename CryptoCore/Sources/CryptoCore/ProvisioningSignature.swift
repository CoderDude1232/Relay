//
//  ProvisioningSignature.swift
//  CryptoCore
//
//  Authenticates the device-linking payload. ProvisioningCipher is an
//  anonymous sealed box, so on its own it can't prove the payload came from a
//  device holding the account identity key.
//
//  The primary signs a transcript binding the session, the new device's
//  ephemeral key, the granted identity, and the issued credentials with the
//  identity private key. The new device rebuilds the transcript and verifies it
//  against the identity public key in the payload before adopting the identity,
//  so a replayed or substituted blob is rejected.
//

import Foundation
import LibSignalClient

public enum ProvisioningSignature {
    private static let label = Data("Relay Device Provisioning Signature v1".utf8)

    /// Built from explicit fields rather than JSON so both sides agree on the
    /// exact bytes.
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

    /// Primary side: signs with the account identity private key.
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

    /// New-device side: verifies against the identity public key in the payload.
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
