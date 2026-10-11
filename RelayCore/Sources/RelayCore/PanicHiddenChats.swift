//
//  PanicHiddenChats.swift
//  RelayCore
//
//  The conversations Panic Mode hides, mirrored by the app into the App Group
//  keychain (this device only) so the notification extension can keep them
//  off the lock screen. Present only while Panic Mode is on.
//

import Foundation
import Security

public enum PanicHiddenChats {
    private static let service = "com.relayapp.relay.panicmode.shared"
    private static let account = "hiddenIds"

    private static func query(accessGroup: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: account,
         kSecAttrAccessGroup: accessGroup]
    }

    /// Replaces the shared list; an empty set removes it.
    public static func save(_ ids: Set<String>, accessGroup: String = RelayStore.appGroupId) {
        SecItemDelete(query(accessGroup: accessGroup) as CFDictionary)
        guard !ids.isEmpty, let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        var attrs = query(accessGroup: accessGroup)
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecValueData] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    public static func load(accessGroup: String = RelayStore.appGroupId) -> Set<String> {
        var attrs = query(accessGroup: accessGroup)
        attrs[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(attrs as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }
}
