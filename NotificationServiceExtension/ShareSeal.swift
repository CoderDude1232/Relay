//
//  ShareSeal.swift
//
//  Seals the files Relay keeps in the App Group container outside the
//  encrypted database (the share/widget chat list, chat photos, a pending
//  share), so a copy of the container alone reveals nothing. AES-GCM under a
//  key in the App Group keychain (after first unlock, this device only), so
//  the widget and Siri can still read them while the phone is locked.
//
//  The app and every extension that touches these files has an identical copy
//  of this file; keep them in sync.
//

import CryptoKit
import Foundation
import Security

nonisolated enum ShareSeal {
    private static let appGroupId = "group.app.relaymsg"
    private static let service = "app.relaymsg.share-bridge"
    private static let magic = Data("RSB1".utf8)

    /// The sealed form of `data`, creating the key on first use.
    static func seal(_ data: Data) -> Data? {
        guard let key = key(create: true),
              let combined = try? AES.GCM.seal(data, using: key).combined
        else { return nil }
        return magic + combined
    }

    /// The plaintext of a stored file. A file without the header predates
    /// sealing and is returned as is (the app re-seals it).
    static func open(_ stored: Data) -> Data? {
        guard stored.starts(with: magic) else { return stored }
        guard let key = key(create: false),
              let box = try? AES.GCM.SealedBox(combined: stored.dropFirst(magic.count)),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return plain
    }

    static func isSealed(_ stored: Data) -> Bool { stored.starts(with: magic) }

    /// Sign-out and wipe: without the key, any copy left behind is unreadable.
    static func deleteKey() {
        SecItemDelete(query() as CFDictionary)
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "key",
         kSecAttrAccessGroup as String: appGroupId]
    }

    private static func key(create: Bool) -> SymmetricKey? {
        var read = query()
        read[kSecReturnData as String] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var add = query()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = raw
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { return key(create: false) } // another process made it first
        return status == errSecSuccess ? SymmetricKey(data: raw) : nil
    }
}
