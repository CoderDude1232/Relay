//
//  ICloudBackupKey.swift
//  Relay
//
//  A random key per account in iCloud Keychain (end-to-end encrypted by
//  Apple, synced to the user's other Apple devices). It wraps one more copy of
//  the backup content key, so a new iPhone on the same Apple ID unlocks the
//  chat list and message history with no password, passkey or recovery key.
//  The relay sees only the wrapped slot, never this key.
//
//  Kept apart from the app's other Keychain items, so signing out keeps it
//  (signing back in restores); deleting the account or an emergency wipe
//  removes it everywhere.
//

import CryptoKit
import Foundation
import Security

nonisolated enum ICloudBackupKey {
    private static let service = "app.relaymsg.backup-unlock.v1"

    private static func query(_ accountId: String?) -> [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: kCFBooleanTrue as Any,
        ]
        if let accountId { q[kSecAttrAccount] = accountId }
        return q
    }

    static func load(accountId: String) -> Data? {
        var q = query(accountId)
        q[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }

    /// The account's key, made and saved if there isn't one yet. Nil if the
    /// Keychain refused it.
    static func loadOrCreate(accountId: String) -> Data? {
        if let existing = load(accountId: accountId) { return existing }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var attrs = query(accountId)
        // Synced items can't be ThisDeviceOnly.
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        attrs[kSecAttrLabel] = "Relay backup key"
        attrs[kSecValueData] = key
        switch SecItemAdd(attrs as CFDictionary, nil) {
        case errSecSuccess: return key
        case errSecDuplicateItem: return load(accountId: accountId) // another device's copy synced in
        default: return nil
        }
    }

    /// Removes every account's key from iCloud Keychain.
    static func deleteAll() {
        SecItemDelete(query(nil) as CFDictionary)
    }

    /// Identifies this key's slot among the account's (each Apple ID adds its
    /// own) without revealing the key.
    static func slotId(for key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("relay-icloud-slot-id".utf8), using: SymmetricKey(data: key)).prefix(16))
    }

    static func slotKey(for key: Data) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
                               info: Data("relay-account-storage-icloud-slot".utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }
}
