//
//  SecureStorage.swift
//  SecureStorage
//
//  Composition root for the storage layer: opens the encrypted database,
//  runs migrations, and exposes the libsignal stores and message history.
//

import CryptoCore
import Foundation
import LibSignalClient

public final class SecureStore {
    public let database: Database
    public let signalStore: SQLCipherSignalStore
    public let messages: MessageStore

    /// Opens or creates the encrypted database at `path`.
    ///
    /// In production `KeychainSecureStore` serves as both key source and
    /// credentials. Tests inject a static key and in-memory credentials.
    public init(
        path: String,
        key: DatabaseKey,
        credentials: any IdentityCredentialProviding
    ) throws {
        self.database = try Database(path: path, key: key)
        try Schema.migrate(database)
        self.signalStore = SQLCipherSignalStore(database: database, credentials: credentials)
        self.messages = MessageStore(database: database)
    }

    /// Production initializer, keyed entirely from the Keychain store.
    public convenience init(path: String, keychain: KeychainSecureStore) throws {
        try self.init(path: path, key: keychain.databaseKey(), credentials: keychain)
    }

    /// A `CryptoEngine` running on the persistent stores.
    public func makeCryptoEngine(accountId: String, deviceId: UInt32) throws -> CryptoEngine {
        // Our own other devices must carry our identity key, so the store needs to
        // know which account is ours (see SQLCipherSignalStore.isTrustedIdentity).
        signalStore.localAccountName = accountId
        return CryptoEngine(
            store: signalStore,
            localAddress: try .init(name: accountId, deviceId: deviceId)
        )
    }
}
