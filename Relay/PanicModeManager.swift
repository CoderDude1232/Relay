//
//  PanicModeManager.swift
//  Relay
//
//  Panic mode: lets the user hide marked conversations behind a secondary PIN.
//
//  • The PIN is verified with Argon2id (libsodium crypto_pwhash, memory-hard)
//    over a random salt. PINs stored by older builds as iterated SHA-256 are
//    verified once with the legacy scheme and re-derived with Argon2id on that
//    first successful entry.
//  • Wrong PINs are rate-limited with exponential backoff that survives app
//    restarts (attempt counter + lockout deadline live in the Keychain).
//  • Everything — salt, hash, KDF version, attempt state AND the hidden
//    conversation ids — lives in the Keychain as ThisDeviceOnly items, so it is
//    never in plaintext UserDefaults and never leaves the device in a backup.
//

import Clibsodium
import CryptoKit
import Foundation
import Observation
import Security

enum PanicUnlockResult: Equatable {
    case unlocked
    case incorrect
    /// Too many wrong PINs: try again after this date.
    case lockedOut(until: Date)
}

@Observable
final class PanicModeManager {

    static let shared = PanicModeManager()

    // MARK: Published state

    private(set) var isEnabled: Bool
    private(set) var isActive: Bool = false
    private(set) var hiddenIds: Set<String>
    /// Non-nil while wrong-PIN backoff is in force.
    private(set) var lockedOutUntil: Date?

    // MARK: Storage keys

    private static let enabledKey = "panicMode.enabled"
    /// Legacy plaintext location of the hidden ids (migrated to the Keychain).
    private static let legacyHiddenKey = "panicMode.hiddenIds"

    // Keychain item identifiers.
    nonisolated private static let kcService    = "com.relayapp.relay.panicmode"
    nonisolated private static let kcSaltAcct   = "pinSalt"
    nonisolated private static let kcHashAcct   = "pinHash"
    nonisolated private static let kcKDFAcct    = "pinKDF"          // "argon2id" (absent = legacy SHA-256)
    nonisolated private static let kcHiddenAcct = "hiddenIds"       // JSON [String]
    nonisolated private static let kcFailsAcct  = "failedAttempts"  // decimal string
    nonisolated private static let kcLockAcct   = "lockedUntil"     // epoch seconds

    nonisolated private static let argonVersion = "argon2id"

    // Legacy UserDefaults keys — only read for one-time migration.
    private static let legacySaltKey = "panicMode.pinSalt"
    private static let legacyHashKey = "panicMode.pinHash"

    /// Wrong PINs allowed before backoff starts.
    nonisolated private static let freeAttempts = 3
    /// First lockout, doubled for every further wrong PIN, capped at one hour.
    nonisolated private static let baseLockout: TimeInterval = 30
    nonisolated private static let maxLockout: TimeInterval = 3600

    // MARK: Init

    init() {
        let ud = UserDefaults.standard
        isEnabled = ud.bool(forKey: Self.enabledKey)

        // One-time migration: hidden ids from plaintext UserDefaults → Keychain.
        if let legacy = ud.stringArray(forKey: Self.legacyHiddenKey) {
            var merged = Self.loadHiddenIds()
            merged.formUnion(legacy)
            Self.saveHiddenIds(merged)
            ud.removeObject(forKey: Self.legacyHiddenKey)
        }
        hiddenIds = Self.loadHiddenIds()

        // One-time migration: legacy UserDefaults PIN material → Keychain.
        if isEnabled {
            if Self.loadKC(Self.kcSaltAcct) == nil,
               let saltB64 = ud.string(forKey: Self.legacySaltKey),
               let hashStr = ud.string(forKey: Self.legacyHashKey) {
                Self.saveKC(Self.kcSaltAcct, value: saltB64)
                Self.saveKC(Self.kcHashAcct, value: hashStr)
            }
        }
        ud.removeObject(forKey: Self.legacySaltKey)
        ud.removeObject(forKey: Self.legacyHashKey)

        lockedOutUntil = Self.currentLockout()
    }

    /// Hidden conversation ids, readable from any thread (e.g. the Spotlight
    /// indexer and the App Group share snapshot). Empty when panic mode is off.
    nonisolated static func hiddenConversationIdsSnapshot() -> Set<String> {
        guard UserDefaults.standard.bool(forKey: "panicMode.enabled") else { return [] }
        return loadHiddenIds()
    }

    // MARK: Setup

    /// Sets (or changes) the PIN. Derivation is memory-hard, so call off the
    /// main thread when possible (`await enableAsync(pin:)`).
    func enable(pin: String) {
        guard pin.count >= 4,
              let salt = Self.randomSalt(),
              let hash = Self.argon2id(pin, salt: salt)
        else { return }
        storePIN(hash: hash, salt: salt)
    }

    func enableAsync(pin: String) async {
        guard pin.count >= 4, let salt = Self.randomSalt() else { return }
        let hash = await Task.detached(priority: .userInitiated) { Self.argon2id(pin, salt: salt) }.value
        guard let hash else { return }
        storePIN(hash: hash, salt: salt)
    }

    private func storePIN(hash: String, salt: Data) {
        Self.saveKC(Self.kcSaltAcct, value: salt.base64EncodedString())
        Self.saveKC(Self.kcHashAcct, value: hash)
        Self.saveKC(Self.kcKDFAcct, value: Self.argonVersion)
        Self.resetAttempts()
        lockedOutUntil = nil
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        isEnabled = true
    }

    func disable() {
        Self.deleteKC(Self.kcSaltAcct)
        Self.deleteKC(Self.kcHashAcct)
        Self.deleteKC(Self.kcKDFAcct)
        Self.resetAttempts()
        lockedOutUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.legacySaltKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyHashKey)
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        isEnabled = false
        isActive = false
    }

    /// Removes every panic-mode secret and the hidden-id list (wipe / sign-out).
    func wipe() {
        disable()
        hiddenIds = []
        Self.deleteKC(Self.kcHiddenAcct)
        UserDefaults.standard.removeObject(forKey: Self.legacyHiddenKey)
    }

    // MARK: Activate / deactivate

    /// Verifies the PIN (Argon2id, off the main thread) under rate limiting.
    func activate(pin: String) async -> PanicUnlockResult {
        guard isEnabled else { return .incorrect }
        if let until = Self.currentLockout() {
            lockedOutUntil = until
            return .lockedOut(until: until)
        }
        guard let saltB64 = Self.loadKC(Self.kcSaltAcct),
              let salt = Data(base64Encoded: saltB64),
              let stored = Self.loadKC(Self.kcHashAcct)
        else { return .incorrect }
        let isArgon = Self.loadKC(Self.kcKDFAcct) == Self.argonVersion

        let candidate: String? = await Task.detached(priority: .userInitiated) {
            isArgon ? Self.argon2id(pin, salt: salt) : Self.legacyStretch(pin, salt: salt)
        }.value

        guard let candidate, Self.constantTimeEqual(candidate, stored) else {
            let until = Self.recordFailure()
            lockedOutUntil = until
            if let until { return .lockedOut(until: until) }
            return .incorrect
        }

        Self.resetAttempts()
        lockedOutUntil = nil
        if !isArgon {
            // Migrate the legacy iterated-SHA-256 hash to Argon2id now that we
            // know the PIN.
            await enableAsync(pin: pin)
        }
        isActive = true
        return .unlocked
    }

    func deactivate() {
        isActive = false
    }

    // MARK: Per-conversation toggling

    func hide(_ conversationId: String) {
        hiddenIds.insert(conversationId)
        Self.saveHiddenIds(hiddenIds)
    }

    func unhide(_ conversationId: String) {
        hiddenIds.remove(conversationId)
        Self.saveHiddenIds(hiddenIds)
    }

    func isHidden(_ conversationId: String) -> Bool {
        !isActive && isEnabled && hiddenIds.contains(conversationId)
    }

    // MARK: Rate limiting

    nonisolated private static func currentLockout() -> Date? {
        guard let raw = loadKC(kcLockAcct), let secs = TimeInterval(raw) else { return nil }
        let until = Date(timeIntervalSince1970: secs)
        return until > Date() ? until : nil
    }

    /// Counts a wrong PIN; returns the lockout deadline once backoff applies.
    nonisolated private static func recordFailure() -> Date? {
        let fails = (loadKC(kcFailsAcct).flatMap(Int.init) ?? 0) + 1
        saveKC(kcFailsAcct, value: String(fails))
        guard fails >= freeAttempts else { return nil }
        let exponent = min(fails - freeAttempts, 16)
        let delay = min(baseLockout * pow(2, Double(exponent)), maxLockout)
        let until = Date().addingTimeInterval(delay)
        saveKC(kcLockAcct, value: String(until.timeIntervalSince1970))
        return until
    }

    nonisolated private static func resetAttempts() {
        deleteKC(kcFailsAcct)
        deleteKC(kcLockAcct)
    }

    // MARK: Hidden ids (Keychain)

    nonisolated private static func loadHiddenIds() -> Set<String> {
        guard let raw = loadKC(kcHiddenAcct),
              let list = try? JSONDecoder().decode([String].self, from: Data(raw.utf8))
        else { return [] }
        return Set(list)
    }

    nonisolated private static func saveHiddenIds(_ ids: Set<String>) {
        guard !ids.isEmpty else { deleteKC(kcHiddenAcct); return }
        guard let data = try? JSONEncoder().encode(Array(ids).sorted()),
              let raw = String(data: data, encoding: .utf8) else { return }
        saveKC(kcHiddenAcct, value: raw)
    }

    // MARK: Key derivation

    nonisolated private static func randomSalt() -> Data? {
        _ = sodium_init()
        var salt = [UInt8](repeating: 0, count: Int(crypto_pwhash_SALTBYTES))
        randombytes_buf(&salt, salt.count)
        return Data(salt)
    }

    /// Argon2id (libsodium, interactive limits) → hex. The PIN is short, so
    /// the cost per guess is what matters; the online path is additionally
    /// rate-limited above.
    nonisolated private static func argon2id(_ pin: String, salt: Data) -> String? {
        _ = sodium_init()
        guard salt.count == Int(crypto_pwhash_SALTBYTES) else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let pinLength = UInt64(pin.utf8.count)
        let rc = pin.withCString { pw in
            crypto_pwhash(
                &out, UInt64(out.count),
                pw, pinLength, saltBytes,
                UInt64(crypto_pwhash_OPSLIMIT_MODERATE),
                Int(crypto_pwhash_MEMLIMIT_INTERACTIVE),
                crypto_pwhash_ALG_ARGON2ID13
            )
        }
        guard rc == 0 else { return nil }
        defer { sodium_memzero(&out, out.count) }
        return out.map { String(format: "%02x", $0) }.joined()
    }

    /// Legacy scheme (50 000 rounds of SHA-256) — used only to verify a PIN set
    /// by an older build, once, before migrating it to Argon2id.
    nonisolated private static func legacyStretch(_ pin: String, salt: Data) -> String {
        var state = Data(pin.utf8)
        state.append(salt)
        state = Data(SHA256.hash(data: state))
        for _ in 1..<50_000 {
            state = Data(SHA256.hash(data: state))
        }
        return state.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: Keychain primitives

    nonisolated private static func kcQuery(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: kcService,
         kSecAttrAccount: account]
    }

    nonisolated private static func saveKC(_ account: String, value: String) {
        var attrs = kcQuery(account)
        // ThisDeviceOnly: never synced to iCloud Keychain, never in backups.
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecValueData] = Data(value.utf8)
        SecItemDelete(kcQuery(account) as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    nonisolated private static func loadKC(_ account: String) -> String? {
        var attrs = kcQuery(account)
        attrs[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(attrs as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    nonisolated private static func deleteKC(_ account: String) {
        SecItemDelete(kcQuery(account) as CFDictionary)
    }
}
