//
//  DeviceAuthSigner.swift
//  Relay
//
//  Bridges RelayKit's per-request signer to the device's Secure-Enclave/Keychain
//  authorization key, so authenticated REST calls can use `Relay-Sig` (a fresh
//  per-request ECDSA-P256 signature) instead of a replayable HTTP Basic password.
//  The same P256 key already backs signed device mutations.
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
}
