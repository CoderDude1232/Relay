//
//  DeviceAuthSigner.swift
//  Relay
//
//  Backs RelayKit's `Relay-Sig` v2 signer (per-request ECDSA-P256 over method,
//  URI, identity and body hash) with the device authorization key. The relay
//  refuses HTTP Basic once this key is registered.
//

import Foundation
import RelayKit
import SecureStorage

/// `@unchecked Sendable`: no mutable state, and `SecKeyCreateSignature` is
/// thread-safe.
struct DeviceAuthSigner: RelayRequestSigner, @unchecked Sendable {
    let keychain: KeychainSecureStore

    func signRelayRequest(_ message: Data) -> Data? {
        try? keychain.signDeviceAuthorizationPayload(message)
    }

    /// Lets RelayKit register this key on first use (the one Basic request a
    /// device ever makes) if the app hasn't uploaded it yet.
    func relayAuthPublicKey() -> Data? {
        try? keychain.deviceAuthorizationPublicKey()
    }
}
