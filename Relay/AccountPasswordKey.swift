//
//  AccountPasswordKey.swift
//  Relay
//
//  What the app sends the relay instead of the account password: Argon2id of
//  the password under its own fixed salt. The chat-list blob's password slot
//  is keyed by a different derivation (AccountStorage.deriveKey, salted with
//  the account id), so this value can't open it, and the password never
//  leaves the phone.
//

import Clibsodium
import CryptoKit
import Foundation
import RelayKit

enum AccountPasswordKey {
    nonisolated static func derive(_ password: String) -> String? {
        _ = sodium_init()
        let salt = Array(SHA256.hash(data: Data("relay-account-password-key-v1".utf8)).prefix(Int(crypto_pwhash_SALTBYTES)))
        var key = [UInt8](repeating: 0, count: 32)
        let rc = password.withCString { pw in
            crypto_pwhash(&key, UInt64(key.count), pw, UInt64(password.utf8.count), salt,
                          UInt64(crypto_pwhash_OPSLIMIT_MODERATE), Int(crypto_pwhash_MEMLIMIT_INTERACTIVE),
                          crypto_pwhash_ALG_ARGON2ID13)
        }
        defer { sodium_memzero(&key, key.count) }
        guard rc == 0 else { return nil }
        return Data(key).base64URLEncodedString()
    }

    /// The proof for a new password (setting, resetting, creating). Slow; runs
    /// off the main thread.
    static func proof(for password: String) async throws -> AccountPasswordProof {
        guard let key = await Task.detached(priority: .userInitiated, operation: { derive(password) }).value else {
            throw CocoaError(.featureUnsupported)
        }
        return AccountPasswordProof(key: key)
    }

    /// Runs a request that checks the password, sending only the key. The
    /// raw password is never sent, not even if a relay asks (a malicious one
    /// could ask at will). An account whose stored password predates keys
    /// sees a wrong-password error and sets a new one from a signed-in device
    /// or by email reset.
    static func checking<T>(
        _ password: String,
        _ request: (AccountPasswordProof) async throws -> T
    ) async throws -> T {
        try await request(proof(for: password))
    }
}
