//
//  AttachmentCipher.swift
//  CryptoCore
//
//  Symmetric encryption for attachment blobs. Each attachment uses a fresh
//  random AES-256-GCM key; the sealed box (nonce‖ciphertext‖tag) is what
//  gets uploaded to the relay. The key + a SHA-256 digest of the ciphertext
//  travel end-to-end inside the encrypted message, so the relay only ever
//  stores opaque, undecryptable bytes. We own this format — there is no
//  external spec to match.
//

import CryptoKit
import Foundation

public enum AttachmentCipherError: Error, Equatable {
    /// The downloaded blob's digest didn't match the pointer (tampering or
    /// corruption) — fail closed before attempting to decrypt.
    case digestMismatch
    case malformedCiphertext
}

public enum AttachmentCipher {
    /// The encrypted form of an attachment, ready to upload.
    public struct Sealed: Sendable, Equatable {
        /// Upload this to the relay (nonce‖ciphertext‖tag).
        public let ciphertext: Data
        /// 32-byte AES-256-GCM key — goes in the AttachmentPointer.
        public let key: Data
        /// SHA-256 of `ciphertext` — goes in the AttachmentPointer.
        public let digest: Data
    }

    /// Encrypts `plaintext` under a fresh random key.
    public static func seal(_ plaintext: Data) throws -> Sealed {
        let key = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw AttachmentCipherError.malformedCiphertext }
        return Sealed(
            ciphertext: combined,
            key: key.withUnsafeBytes { Data($0) },
            digest: Data(SHA256.hash(data: combined))
        )
    }

    /// Verifies the digest, then decrypts a downloaded blob.
    public static func open(_ ciphertext: Data, key: Data, digest: Data) throws -> Data {
        guard Data(SHA256.hash(data: ciphertext)) == digest else {
            throw AttachmentCipherError.digestMismatch
        }
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }
}
