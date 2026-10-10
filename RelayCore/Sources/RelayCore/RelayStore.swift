//
//  RelayStore.swift
//  RelayCore
//
//  Locates and opens the encrypted database and loads the saved account, so
//  the app and the NSE agree on the container path and Keychain configuration.
//

import Foundation
import SecureStorage

public enum RelayStore {
    /// Must match the `com.apple.security.application-groups` entitlement on
    /// both targets. Also used as the Keychain access group.
    public static let appGroupId = "group.app.relaymsg"

    /// Lives in the App Group container so the NSE shares it.
    public static func databaseURL(appGroupId: String, suffix: String = "") -> URL {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return container.appendingPathComponent("relay.db\(suffix)")
    }

    /// Opens the shared store, keyed by the Secure Enclave-wrapped master key.
    public static func open(appGroupId: String) throws -> SecureStore {
        let keychain = KeychainSecureStore(configuration: KeychainConfiguration(accessGroup: appGroupId))
        return try SecureStore(path: databaseURL(appGroupId: appGroupId).path, keychain: keychain)
    }

    /// The persisted account, or nil before onboarding.
    public static func loadAccount(appGroupId: String) throws -> RelayAccount? {
        let keychain = KeychainSecureStore(configuration: KeychainConfiguration(accessGroup: appGroupId))
        guard let data = try keychain.loadSecret(for: RelayAccount.keychainName) else { return nil }
        return try JSONDecoder().decode(RelayAccount.self, from: data)
    }
}
