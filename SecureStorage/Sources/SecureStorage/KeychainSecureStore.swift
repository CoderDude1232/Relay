//
//  KeychainSecureStore.swift
//  SecureStorage
//
//  Custody of the two long-lived secrets, per the security design:
//
//  * Database master key — 32 random bytes, wrapped (ECIES) by a P-256 key
//    that lives inside the Secure Enclave; only the wrapped blob is stored
//    in the Keychain. Where no Enclave exists (Simulator), the key is
//    stored Keychain-only and re-wrapped transparently if an Enclave
//    appears later. `AfterFirstUnlockThisDeviceOnly` throughout, so the
//    Notification Service Extension can decrypt pushes while the device
//    is locked.
//
//  * Identity key pair + registration id — Keychain-only, never written to
//    the database or anywhere else.
//
//  All items use the App Group access group so the NSE shares them.
//

import Foundation
import LibSignalClient
import Security

public struct KeychainConfiguration: Sendable {
    /// Keychain access group; on iOS an App Group id works directly.
    /// nil = the app's default access group (tests, single-target use).
    public let accessGroup: String?
    public let service: String

    public init(accessGroup: String?, service: String = "app.relay.secrets") {
        self.accessGroup = accessGroup
        self.service = service
    }
}

public final class KeychainSecureStore {
    private enum Item {
        static let wrappedDatabaseKey = "db-master-key.wrapped"
        static let plainDatabaseKey = "db-master-key.plain"
        static let identityKeyPair = "identity-key-pair"
        static let registrationId = "registration-id"
        static let enclaveKeyTag = "app.relay.enclave-wrapping-key"
    }

    private let config: KeychainConfiguration

    public init(configuration: KeychainConfiguration) {
        self.config = configuration
    }

    // MARK: - Database master key

    /// Returns the database master key, creating and persisting it on
    /// first call.
    public func databaseKey() throws -> DatabaseKey {
        if let wrapped = try read(Item.wrappedDatabaseKey) {
            return DatabaseKey(bytes: try unwrap(wrapped))
        }
        if let plain = try read(Item.plainDatabaseKey) {
            return DatabaseKey(bytes: plain)
        }

        let key = DatabaseKey.random()
        if let enclaveKey = try? enclaveWrappingKey() {
            try write(Item.wrappedDatabaseKey, data: try wrap(key.bytes, with: enclaveKey))
        } else {
            // No Secure Enclave (Simulator): Keychain protection only.
            try write(Item.plainDatabaseKey, data: key.bytes)
        }
        return key
    }

    // MARK: - Secure Enclave wrapping

    private static let wrapAlgorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    private func enclaveWrappingKey() throws -> SecKey {
        let tag = Data(Item.enclaveKeyTag.utf8)

        var query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag: tag,
            kSecReturnRef: true,
        ]
        if let group = config.accessGroup { query[kSecAttrAccessGroup] = group }
        var existing: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess {
            return (existing as! SecKey)
        }

        var accessError: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .privateKeyUsage,
                &accessError
            )
        else {
            throw StorageError.secureEnclave("access control: \(String(describing: accessError?.takeRetainedValue()))")
        }

        var privateKeyAttrs: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: tag,
            kSecAttrAccessControl: access,
        ]
        if let group = config.accessGroup { privateKeyAttrs[kSecAttrAccessGroup] = group }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs: privateKeyAttrs,
        ]

        var createError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            throw StorageError.secureEnclave("create: \(String(describing: createError?.takeRetainedValue()))")
        }
        return key
    }

    private func wrap(_ plaintext: Data, with key: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw StorageError.secureEnclave("no public key")
        }
        var error: Unmanaged<CFError>?
        guard
            let wrapped = SecKeyCreateEncryptedData(publicKey, Self.wrapAlgorithm, plaintext as CFData, &error)
        else {
            throw StorageError.secureEnclave("wrap: \(String(describing: error?.takeRetainedValue()))")
        }
        return wrapped as Data
    }

    private func unwrap(_ wrapped: Data) throws -> Data {
        let key = try enclaveWrappingKey()
        var error: Unmanaged<CFError>?
        guard
            let plain = SecKeyCreateDecryptedData(key, Self.wrapAlgorithm, wrapped as CFData, &error)
        else {
            throw StorageError.secureEnclave("unwrap: \(String(describing: error?.takeRetainedValue()))")
        }
        return plain as Data
    }

    // MARK: - Generic secrets (account credentials, etc.)

    public func storeSecret(_ value: Data, for account: String) throws {
        try write(account, data: value)
    }

    public func loadSecret(for account: String) throws -> Data? {
        try read(account)
    }

    public func deleteSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.keychain(status: status)
        }
    }

    // MARK: - Keychain primitives

    private func baseQuery(_ account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: config.service,
            kSecAttrAccount: account,
        ]
        if let group = config.accessGroup { query[kSecAttrAccessGroup] = group }
        return query
    }

    func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case let status:
            throw StorageError.keychain(status: status)
        }
    }

    func write(_ account: String, data: Data) throws {
        var attributes = baseQuery(account)
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw StorageError.keychain(status: updateStatus)
            }
        } else if status != errSecSuccess {
            throw StorageError.keychain(status: status)
        }
    }
}

// MARK: - Identity credentials

extension KeychainSecureStore: IdentityCredentialProviding {
    /// Loads the device identity, generating and persisting a fresh one on
    /// first launch. The serialized private key exists only inside the
    /// Keychain item.
    public func identityKeyPair() throws -> IdentityKeyPair {
        if let stored = try read(Item.identityKeyPair) {
            return try IdentityKeyPair(bytes: stored)
        }
        let fresh = IdentityKeyPair.generate()
        try write(Item.identityKeyPair, data: fresh.serialize())
        return fresh
    }

    public func registrationId() throws -> UInt32 {
        if let stored = try read(Item.registrationId), stored.count == 4 {
            return stored.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        var value = UInt32.random(in: 1...0x3FFF)
        let data = withUnsafeBytes(of: &value) { Data($0) }
        try write(Item.registrationId, data: data)
        return value
    }
}
