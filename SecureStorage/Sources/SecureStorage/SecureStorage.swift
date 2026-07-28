//
//  SecureStorage.swift
//  SecureStorage
//
//  Composition root for the storage layer: opens the encrypted database,
//  runs migrations, and exposes the libsignal stores + message history.
//

import CryptoCore
import Foundation
import LibSignalClient

public final class SecureStore {
    public let database: Database
    public let signalStore: SQLCipherSignalStore
    public let messages: MessageStore

    /// Opens (or creates) the encrypted database at `path`.
    ///
    /// Production: pass a `KeychainSecureStore` as both key source and
    /// credentials — it owns the Secure-Enclave-wrapped master key and the
    /// Keychain-resident identity. Tests inject a static key and in-memory
    /// credentials.
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

    /// Convenience for production: everything keyed from the Keychain/
    /// Secure Enclave store.
    public convenience init(path: String, keychain: KeychainSecureStore) throws {
        try self.init(path: path, key: keychain.databaseKey(), credentials: keychain)
    }

    /// A `CryptoEngine` running on the persistent stores.
    public func makeCryptoEngine(accountId: String, deviceId: UInt32) throws -> CryptoEngine {
        CryptoEngine(
            store: signalStore,
            localAddress: try .init(name: accountId, deviceId: deviceId)
        )
    }
}
