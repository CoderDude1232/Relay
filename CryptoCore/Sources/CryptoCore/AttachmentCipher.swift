//
//  AttachmentCipher.swift
//  CryptoCore
//
//  Attachment blob encryption. Each attachment gets a fresh AES-256-GCM key;
//  the sealed box (nonce || ciphertext || tag) is uploaded. The key and a
//  SHA-256 digest of the ciphertext travel inside the encrypted message, so
//  the relay only stores opaque bytes.
//

import CryptoKit
import Foundation

public enum AttachmentCipherError: Error, Equatable {
    /// The blob's digest didn't match the pointer. Checked before decrypting.
    case digestMismatch
    case malformedCiphertext
}

public enum AttachmentCipher {
    /// The encrypted form of an attachment, ready to upload.
    public struct Sealed: Sendable, Equatable {
        /// nonce || ciphertext || tag, uploaded to the relay.
        public let ciphertext: Data
        /// 32-byte AES-256-GCM key, carried in the AttachmentPointer.
        public let key: Data
        /// SHA-256 of `ciphertext`, carried in the AttachmentPointer.
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
