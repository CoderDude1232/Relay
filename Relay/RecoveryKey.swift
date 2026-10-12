//
//  RecoveryKey.swift
//  Relay
//
//  A random key that signs in to the account without a password, email code
//  or passkey, and unlocks the chat list. The key never leaves the phone: the
//  relay gets authKey (one derivation) and stores a hash of it; the chat-list
//  slot uses another (slotKey), so what the relay sees can't open it.
//

import CryptoKit
import Foundation
import Security

enum RecoveryKey {
    /// No 0/O, 1/I/L or U, so it reads back unambiguously.
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")
    private static let length = 24

    /// 24 characters in groups of four (about 118 bits).
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: length * 2)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        var chars: [Character] = []
        var i = 0
        while chars.count < length {
            if i == bytes.count {
                precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
                i = 0
            }
            // Rejection sampling keeps every character equally likely.
            let b = Int(bytes[i]); i += 1
            if b < 240 { chars.append(alphabet[b % alphabet.count]) }
        }
        return format(String(chars))
    }

    /// ASCII letters uppercased, then letters and digits only; matches the
    /// relay's normalisation exactly.
    static func normalize(_ key: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in key.unicodeScalars {
            if ("a"..."z").contains(scalar) {
                out.append(Unicode.Scalar(scalar.value - 32)!)
            } else if ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.append(scalar)
            }
        }
        return String(out)
    }

    static func format(_ key: String) -> String {
        let n = Array(normalize(key))
        return stride(from: 0, to: n.count, by: 4).map { String(n[$0..<min($0 + 4, n.count)]) }.joined(separator: "-")
    }

    static func isPlausible(_ key: String) -> Bool { (20...40).contains(normalize(key).count) }

    /// SHA-256("relay-recovery-key-v1|" + normalized): the hash older builds
    /// registered, from the raw key the relay used to receive at sign-in.
    static func legacyHash(_ key: String) -> Data {
        Data(SHA256.hash(data: Data(("relay-recovery-key-v1|" + normalize(key)).utf8)))
    }

    /// What sign-in sends instead of the key (base64url).
    static func authKey(_ key: String) -> String {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalize(key).utf8)),
            info: Data("relay-recovery-key-auth-v2".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }.base64URLEncodedString()
    }

    /// SHA-256("relay-recovery-key-v2|" + authKey): what the relay stores.
    static func hash(_ key: String) -> Data {
        Data(SHA256.hash(data: Data(("relay-recovery-key-v2|" + authKey(key)).utf8)))
    }

    /// Wraps the chat-list key in the account storage's recovery slot.
    static func slotKey(_ key: String) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalize(key).utf8)),
            info: Data("relay-account-storage-recovery-slot".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }
}
