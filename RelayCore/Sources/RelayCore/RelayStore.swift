//
//  RelayStore.swift
//  RelayCore
//
//  One place to locate + open the encrypted database and load the saved
//  account, so the app and the Notification Service Extension agree on the
//  App-Group container path and Keychain configuration.
//

import Foundation
import SecureStorage

public enum RelayStore {
    /// The encrypted DB lives in the App-Group container so the NSE shares it.
    public static func databaseURL(appGroupId: String, suffix: String = "") -> URL {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return container.appendingPathComponent("relay.db\(suffix)")
    }

    /// Opens the shared encrypted store, keyed by the Secure-Enclave-wrapped
    /// master key in the App-Group Keychain.
    public static func open(appGroupId: String) throws -> SecureStore {
        let keychain = KeychainSecureStore(configuration: KeychainConfiguration(accessGroup: appGroupId))
        return try SecureStore(path: databaseURL(appGroupId: appGroupId).path, keychain: keychain)
    }

    /// Loads the persisted account, or nil if the user isn't onboarded.
    public static func loadAccount(appGroupId: String) throws -> RelayAccount? {
        let keychain = KeychainSecureStore(configuration: KeychainConfiguration(accessGroup: appGroupId))
        guard let data = try keychain.loadSecret(for: RelayAccount.keychainName) else { return nil }
        return try JSONDecoder().decode(RelayAccount.self, from: data)
    }
}
