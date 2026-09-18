//
//  ProvisioningCipherTests.swift
//  CryptoCoreTests
//
//  Validates the reversed-linking provisioning box: ECDH + HKDF + AES-GCM
//  round-trips, and that a blob can only be opened with the matching ephemeral
//  private key (the one whose public half was shown in the QR).
//

import Foundation
import Testing

@testable import CryptoCore

@Test func provisioningRoundTrip() throws {
    let newDevice = ProvisioningCipher.EphemeralKeyPair()
    let payload = Data("shared identity key + credentials".utf8)

    let blob = try ProvisioningCipher.seal(payload, toEphemeralPublicKey: newDevice.publicKey)
    // version byte + 32-byte ephemeral pub + at least the GCM nonce/tag.
    #expect(blob.first == ProvisioningCipher.version)
    #expect(blob.count > 1 + 32)

    let opened = try ProvisioningCipher.open(blob, ephemeralPrivateKey: newDevice.privateKey)
    #expect(opened == payload)
}

@Test func provisioningRejectsWrongKey() throws {
    let newDevice = ProvisioningCipher.EphemeralKeyPair()
    let attacker = ProvisioningCipher.EphemeralKeyPair()
    let blob = try ProvisioningCipher.seal(Data("secret".utf8), toEphemeralPublicKey: newDevice.publicKey)

    #expect(throws: (any Error).self) {
        _ = try ProvisioningCipher.open(blob, ephemeralPrivateKey: attacker.privateKey)
    }
}

@Test func provisioningRejectsBadVersionAndTruncation() throws {
    let newDevice = ProvisioningCipher.EphemeralKeyPair()
    let blob = try ProvisioningCipher.seal(Data("secret".utf8), toEphemeralPublicKey: newDevice.publicKey)

    var wrongVersion = blob
    wrongVersion[wrongVersion.startIndex] = 0x02
    #expect(throws: ProvisioningCipherError.unsupportedVersion) {
        _ = try ProvisioningCipher.open(wrongVersion, ephemeralPrivateKey: newDevice.privateKey)
    }

    let truncated = blob.prefix(1 + 32) // header only, no ciphertext
    #expect(throws: ProvisioningCipherError.malformed) {
        _ = try ProvisioningCipher.open(Data(truncated), ephemeralPrivateKey: newDevice.privateKey)
    }
}
