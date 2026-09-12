//
//  PanicModeManager.swift
//  Relay
//
//  Panic mode: lets the user hide marked conversations behind a secondary PIN.
//  The PIN is verified via iterated-SHA-256 (50 000 rounds) with a random 16-byte
//  salt. Salt and hash are stored in the Keychain (AfterFirstUnlockThisDeviceOnly)
//  so they are excluded from iCloud/iTunes backups and are device-bound.
//  Hidden conversation IDs and the enabled flag live in UserDefaults — they are
//  metadata only (not credentials).
//

import CryptoKit
import Foundation
import Observation
import Security

@Observable
final class PanicModeManager {

    static let shared = PanicModeManager()

    // MARK: Published state

    private(set) var isEnabled: Bool
    private(set) var isActive: Bool = false
    private(set) var hiddenIds: Set<String>

    // MARK: Storage keys

    private static let enabledKey = "panicMode.enabled"
    private static let hiddenKey  = "panicMode.hiddenIds"

    // Keychain item identifiers (not stored in UserDefaults).
    private static let kcService  = "com.relayapp.relay.panicmode"
    private static let kcSaltAcct = "pinSalt"
    private static let kcHashAcct = "pinHash"

    // Legacy UserDefaults keys — only read for one-time migration.
    private static let legacySaltKey = "panicMode.pinSalt"
    private static let legacyHashKey = "panicMode.pinHash"

    // MARK: Init

    init() {
        let ud = UserDefaults.standard
        isEnabled = ud.bool(forKey: Self.enabledKey)
        let stored = ud.stringArray(forKey: Self.hiddenKey) ?? []
        hiddenIds = Set(stored)

        // One-time migration: move legacy UserDefaults PIN material into Keychain.
        if isEnabled {
            if Self.loadKC(Self.kcSaltAcct) == nil,
               let saltB64 = ud.string(forKey: Self.legacySaltKey),
               let hashStr = ud.string(forKey: Self.legacyHashKey) {
                Self.saveKC(Self.kcSaltAcct, value: saltB64)
                Self.saveKC(Self.kcHashAcct, value: hashStr)
                ud.removeObject(forKey: Self.legacySaltKey)
                ud.removeObject(forKey: Self.legacyHashKey)
            }
        }
    }

    // MARK: Setup

    func enable(pin: String) {
        guard pin.count >= 4 else { return }
        let salt = randomSalt()
        let hash = stretchPin(pin, salt: salt)
        Self.saveKC(Self.kcSaltAcct, value: salt.base64EncodedString())
        Self.saveKC(Self.kcHashAcct, value: hash)
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        isEnabled = true
    }

    func disable() {
        Self.deleteKC(Self.kcSaltAcct)
        Self.deleteKC(Self.kcHashAcct)
        // Also clean up any legacy UserDefaults remnants.
        UserDefaults.standard.removeObject(forKey: Self.legacySaltKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyHashKey)
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        isEnabled = false
        isActive = false
    }

    // MARK: Activate / deactivate

    @discardableResult
    func activate(pin: String) -> Bool {
        guard isEnabled else { return false }
        guard
            let saltB64 = Self.loadKC(Self.kcSaltAcct),
            let salt = Data(base64Encoded: saltB64)
        else { return false }
        let stored = Self.loadKC(Self.kcHashAcct) ?? ""
        guard stretchPin(pin, salt: salt) == stored else { return false }
        isActive = true
        return true
    }

    func deactivate() {
        isActive = false
    }

    // MARK: Per-conversation toggling

    func hide(_ conversationId: String) {
        hiddenIds.insert(conversationId)
        persist()
    }

    func unhide(_ conversationId: String) {
        hiddenIds.remove(conversationId)
        persist()
    }

    func isHidden(_ conversationId: String) -> Bool {
        !isActive && isEnabled && hiddenIds.contains(conversationId)
    }

    // MARK: Helpers

    private func persist() {
        UserDefaults.standard.set(Array(hiddenIds), forKey: Self.hiddenKey)
    }

    private func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// 50 000 rounds of SHA-256 keyed by a random salt. Each round feeds into
    /// the next, so the cost is linear in round count — ~25 ms on device, which
    /// adds ~25 seconds per full 4-digit PIN sweep for an offline attacker.
    private func stretchPin(_ pin: String, salt: Data) -> String {
        var state = Data(pin.utf8)
        state.append(salt)
        state = Data(SHA256.hash(data: state))
        for _ in 1..<50_000 {
            state = Data(SHA256.hash(data: state))
        }
        return state.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Keychain primitives

    private static func kcQuery(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: kcService,
         kSecAttrAccount: account]
    }

    private static func saveKC(_ account: String, value: String) {
        var attrs = kcQuery(account)
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecValueData] = Data(value.utf8)
        SecItemDelete(kcQuery(account) as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func loadKC(_ account: String) -> String? {
        var attrs = kcQuery(account)
        attrs[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(attrs as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    private static func deleteKC(_ account: String) {
        SecItemDelete(kcQuery(account) as CFDictionary)
    }
}
