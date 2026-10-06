//
//  DeviceAuthSigner.swift
//  Relay
//
//  Bridges RelayKit's per-request signer to the device's Secure-Enclave/Keychain
//  authorization key, so authenticated REST calls and the WebSocket upgrade use
//  `Relay-Sig` v2 (a fresh per-request ECDSA-P256 signature over method, URI,
//  identity and body hash). The relay refuses HTTP Basic once this key is
//  registered. The same P256 key already backs signed device mutations.
//

import Foundation
import RelayKit
import SecureStorage

/// `@unchecked Sendable`: `signDeviceAuthorizationPayload` calls
/// `SecKeyCreateSignature`, which is thread-safe, and this holds no mutable
/// shared state — safe to sign concurrently from the API client.
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
