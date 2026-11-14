//
//  PinLock.swift
//  SecureStorage
//
//  The device's half of the Relay PIN lock (docs/DISTRESS_PIN_PLAN.md).
//
//  "Forget messages on lock" keeps the database master key sealed under a
//  key-encryption key (KEK) that needs two things:
//
//  - the relay's answer to the PIN: an oblivious PRF over ristretto255 with a
//    per-device key the relay holds and deletes after 10 wrong PINs
//    (server/internal/pinguard). The relay never sees the PIN.
//  - a secret that never leaves this iPhone, wrapped by the Secure Enclave and
//    readable only while the phone is unlocked.
//
//  The PIN is stretched (PBKDF2-SHA256) before it's blinded, so even someone
//  holding both the relay's key and this phone's secret pays for every guess.
//  When the phone locks, the app deletes the master key from the Keychain and
//  keeps only the sealed copy; the right PIN puts it back.
//
//  Network calls and the lock lifecycle live in the app; this file is the
//  crypto and the Keychain items.
//

import Clibsodium
import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum PinLockError: Error, Equatable {
    case crypto(String)
    /// The sealed key didn't open: wrong PIN result or a damaged blob.
    case sealedKeyDidNotOpen
    /// Forgetting the master key needs a sealed copy to come back from.
    case notSealed
    /// The master key is forgotten; this needs it present.
    case keyForgotten
}

public enum PinLockCrypto {
    /// Bytes of salt.
    public static let saltSize = 16

    // Domain separation for everything derived here.
    private static let hashToGroupDomain = Data("Relay-PINGuard-v1-h2g".utf8)
    private static let kekInfo = Data("Relay-PINGuard-v1-kek".utf8)
    private static let verifierInfo = Data("Relay-PINGuard-v1-verify".utf8)

    private static let initOnce: Int32 = sodium_init()

    public static func newSalt() -> Data {
        _ = initOnce
        var salt = [UInt8](repeating: 0, count: saltSize)
        randombytes_buf(&salt, salt.count)
        return Data(salt)
    }

    /// PBKDF2-HMAC-SHA256 rounds (OWASP's 2023 figure); a few tenths of a
    /// second on an iPhone.
    public static let stretchRounds: UInt32 = 600_000

    /// PBKDF2-HMAC-SHA256(PIN, salt), 32 bytes. Not libsodium's Argon2id: it
    /// corrupted its own hash state on some thread stacks in tests (a bad
    /// write inside argon2_initialize), and this guard only matters if the
    /// relay's key and this phone's secret were both taken.
    public static func stretch(pin: String, salt: Data) throws -> Data {
        guard salt.count == saltSize else { throw PinLockError.crypto("salt") }
        var out = [UInt8](repeating: 0, count: 32)
        var password = Array(pin.utf8).map { CChar(bitPattern: $0) }
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            stretchRounds,
            &out, out.count
        )
        for i in password.indices { password[i] = 0 }
        guard status == kCCSuccess else { throw PinLockError.crypto("pbkdf2") }
        defer { for i in out.indices { out[i] = 0 } }
        return Data(out)
    }

    /// A blinded PIN for the relay, and the scalar that unblinds its answer.
    public struct Blinded: Sendable {
        /// B = r·H(stretched PIN), sent to the relay.
        public let element: Data
        fileprivate let blind: [UInt8]
    }

    public static func blind(stretched: Data) throws -> Blinded {
        _ = initOnce
        var hasher = SHA512()
        hasher.update(data: hashToGroupDomain)
        hasher.update(data: stretched)
        let digest = [UInt8](hasher.finalize())
        var point = [UInt8](repeating: 0, count: 32)
        guard crypto_core_ristretto255_from_hash(&point, digest) == 0 else {
            throw PinLockError.crypto("hash to group")
        }
        var r = [UInt8](repeating: 0, count: 32)
        crypto_core_ristretto255_scalar_random(&r)
        var b = [UInt8](repeating: 0, count: 32)
        guard crypto_scalarmult_ristretto255(&b, r, point) == 0 else {
            throw PinLockError.crypto("blind")
        }
        return Blinded(element: Data(b), blind: r)
    }

    /// k_d·H(PIN) from the relay's answer E = k_d·B. Rejects anything that
    /// isn't a valid, non-identity point.
    public static func unblind(_ blinded: Blinded, evaluated: Data) throws -> Data {
        _ = initOnce
        guard evaluated.count == 32, crypto_core_ristretto255_is_valid_point([UInt8](evaluated)) == 1 else {
            throw PinLockError.crypto("evaluated element")
        }
        var rInv = [UInt8](repeating: 0, count: 32)
        guard crypto_core_ristretto255_scalar_invert(&rInv, blinded.blind) == 0 else {
            throw PinLockError.crypto("invert")
        }
        defer { sodium_memzero(&rInv, rInv.count) }
        var n = [UInt8](repeating: 0, count: 32)
        guard crypto_scalarmult_ristretto255(&n, rInv, [UInt8](evaluated)) == 0 else {
            throw PinLockError.crypto("unblind")
        }
        return Data(n)
    }

    public struct Keys {
        /// Seals and opens the database master key.
        public let kek: SymmetricKey
        /// What the relay checks a correct PIN with (32 bytes). It needs the
        /// device secret too, so the relay can't test PINs against it.
        public let verifier: Data
    }

    /// The KEK and verifier from the relay's answer and the device secret.
    public static func keys(oprfOutput: Data, deviceSecret: Data, salt: Data) -> Keys {
        let ikm = SymmetricKey(data: oprfOutput + deviceSecret)
        let kek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: kekInfo, outputByteCount: 32)
        let verifier = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: verifierInfo, outputByteCount: 32)
        return Keys(kek: kek, verifier: verifier.withUnsafeBytes { Data($0) })
    }

    /// AES-256-GCM, nonce ‖ ciphertext ‖ tag.
    public static func seal(_ secret: Data, with kek: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(secret, using: kek).combined else {
            throw PinLockError.crypto("seal")
        }
        return combined
    }

    public static func open(_ sealed: Data, with kek: SymmetricKey) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: kek)
        } catch {
            throw PinLockError.sealedKeyDidNotOpen
        }
    }

    /// Constant-time comparison, for the on-device PIN checks.
    public static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in sodium_memcmp(pa.baseAddress!, pb.baseAddress!, a.count) == 0 }
        }
    }
}

// MARK: - Keychain items

extension KeychainSecureStore {
    private enum PinItem {
        static let wrappedDeviceSecret = "pin-lock.device-secret.wrapped"
        static let plainDeviceSecret = "pin-lock.device-secret.plain"
        /// version ‖ salt ‖ AES-GCM(master key)
        static let sealedDatabaseKey = "pin-lock.sealed-db-key"
    }

    private static let sealedVersion: UInt8 = 1

    /// The secret that never leaves this iPhone: 32 random bytes, wrapped by the
    /// Secure Enclave and readable only while the phone is unlocked. Made on
    /// first use.
    public func pinLockDeviceSecret() throws -> Data {
        if let wrapped = try read(PinItem.wrappedDeviceSecret) {
            return try unwrap(wrapped)
        }
        if let plain = try read(PinItem.plainDeviceSecret) {
            return plain
        }
        let secret = DatabaseKey.random().bytes
        #if targetEnvironment(simulator)
        if let enclaveKey = try? enclaveWrappingKey() {
            try write(PinItem.wrappedDeviceSecret, data: try wrap(secret, with: enclaveKey),
                      accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        } else {
            try write(PinItem.plainDeviceSecret, data: secret,
                      accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        }
        #else
        try write(PinItem.wrappedDeviceSecret, data: try wrap(secret, with: try enclaveWrappingKey()),
                  accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        #endif
        return secret
    }

    /// Stores the master key sealed under the PIN's KEK, with the salt the PIN
    /// was stretched with. Replaces any earlier sealed copy.
    public func storeSealedDatabaseKey(_ sealed: Data, salt: Data) throws {
        guard salt.count == PinLockCrypto.saltSize else { throw PinLockError.crypto("salt") }
        try write(PinItem.sealedDatabaseKey, data: Data([Self.sealedVersion]) + salt + sealed)
    }

    /// The sealed master key and its salt, if the PIN lock is set up.
    public func sealedDatabaseKey() throws -> (salt: Data, sealed: Data)? {
        guard let blob = try read(PinItem.sealedDatabaseKey) else { return nil }
        let headerCount = 1 + PinLockCrypto.saltSize
        guard blob.count > headerCount, blob.first == Self.sealedVersion else {
            throw PinLockError.crypto("sealed key format")
        }
        let start = blob.startIndex
        return (Data(blob[(start + 1)..<(start + headerCount)]), Data(blob[(start + headerCount)...]))
    }

    /// True while the master key is gone from the Keychain and only the sealed
    /// copy is left.
    public func isDatabaseKeyForgotten() throws -> Bool {
        guard try read(PinItem.sealedDatabaseKey) != nil else { return false }
        return try read(Item.wrappedDatabaseKey) == nil && read(Item.plainDatabaseKey) == nil
    }

    /// Deletes the master key, leaving only the sealed copy. Refuses unless a
    /// sealed copy exists, so this can never lose the data by accident.
    public func forgetDatabaseKey() throws {
        guard try sealedDatabaseKey() != nil else { throw PinLockError.notSealed }
        try deleteSecret(for: Item.wrappedDatabaseKey)
        try deleteSecret(for: Item.plainDatabaseKey)
    }

    /// Opens the sealed copy with the PIN's KEK and puts the master key back
    /// where `databaseKey()` reads it.
    @discardableResult
    public func restoreDatabaseKey(kek: SymmetricKey) throws -> DatabaseKey {
        guard let stored = try sealedDatabaseKey() else { throw PinLockError.notSealed }
        let bytes = try PinLockCrypto.open(stored.sealed, with: kek)
        guard bytes.count == DatabaseKey.byteCount else { throw PinLockError.sealedKeyDidNotOpen }
        let key = DatabaseKey(bytes: bytes)
        try storeDatabaseKey(key)
        return key
    }

    /// Turns the PIN lock off: drops the sealed copy and the device secret.
    /// Only while the master key is present, so turning it off never strands
    /// the data.
    public func removePinLock() throws {
        if try isDatabaseKeyForgotten() { throw PinLockError.keyForgotten }
        try deleteSecret(for: PinItem.sealedDatabaseKey)
        try deleteSecret(for: PinItem.wrappedDeviceSecret)
        try deleteSecret(for: PinItem.plainDeviceSecret)
    }
}
