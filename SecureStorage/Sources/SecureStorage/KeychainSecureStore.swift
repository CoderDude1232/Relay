//
//  KeychainSecureStore.swift
//  SecureStorage
//
//  Holds the two long-lived secrets:
//
//  - Database master key: 32 random bytes, ECIES-wrapped by a Secure Enclave
//    P-256 key; only the wrapped blob goes in the Keychain. Without an Enclave
//    (Simulator) it is stored Keychain-only and re-wrapped if one appears.
//    `AfterFirstUnlockThisDeviceOnly` so the NSE can decrypt while locked.
//
//  - Identity key pair and registration id: Keychain-only, never written to
//    the database.
//
//  All items use the App Group access group so the NSE shares them.
//

import Foundation
import LibSignalClient
import Security

public struct KeychainConfiguration: Sendable {
    /// Keychain access group; an App Group id works directly on iOS. Nil uses
    /// the app's default group.
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
        static let deviceAuthKeyTag = "app.relay.device-authorization-key"
    }

    private let config: KeychainConfiguration

    public init(configuration: KeychainConfiguration) {
        self.config = configuration
    }

    // MARK: - Database master key

    /// The database master key, created and persisted on first call.
    public func databaseKey() throws -> DatabaseKey {
        if let wrapped = try read(Item.wrappedDatabaseKey) {
            return DatabaseKey(bytes: try unwrap(wrapped))
        }
        if let plain = try read(Item.plainDatabaseKey) {
            return DatabaseKey(bytes: plain)
        }

        let key = DatabaseKey.random()
        #if targetEnvironment(simulator)
        // No Secure Enclave in the Simulator: Keychain protection only.
        if let enclaveKey = try? enclaveWrappingKey() {
            try write(Item.wrappedDatabaseKey, data: try wrap(key.bytes, with: enclaveKey))
        } else {
            try write(Item.plainDatabaseKey, data: key.bytes)
        }
        #else
        // Every supported iPhone has a Secure Enclave. Failing here is an error,
        // not a reason to store the master key unwrapped.
        try write(Item.wrappedDatabaseKey, data: try wrap(key.bytes, with: try enclaveWrappingKey()))
        #endif
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
            guard let ref = existing, CFGetTypeID(ref) == SecKeyGetTypeID() else {
                throw StorageError.secureEnclave("enclave wrapping key: unexpected type in Keychain result")
            }
            return unsafeDowncast(ref, to: SecKey.self)
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

    // MARK: - Device authorization key

    private static let signingAlgorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256

    /// Public half of this device's auth key. The private key is created
    /// non-exportable in the Secure Enclave; the Simulator falls back to a
    /// Keychain-held key.
    public func deviceAuthorizationPublicKey() throws -> Data {
        let key = try deviceAuthorizationPrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw StorageError.secureEnclave("device auth public key unavailable")
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw StorageError.secureEnclave("device auth public export: \(String(describing: error?.takeRetainedValue()))")
        }
        return data as Data
    }

    /// Signs a device-control or request payload with the auth key.
    public func signDeviceAuthorizationPayload(_ payload: Data) throws -> Data {
        let key = try deviceAuthorizationPrivateKey()
        guard SecKeyIsAlgorithmSupported(key, .sign, Self.signingAlgorithm) else {
            throw StorageError.secureEnclave("device auth signing unsupported")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, Self.signingAlgorithm, payload as CFData, &error) else {
            throw StorageError.secureEnclave("device auth sign: \(String(describing: error?.takeRetainedValue()))")
        }
        return signature as Data
    }

    private func deviceAuthorizationPrivateKey() throws -> SecKey {
        if let existing = try loadDeviceAuthorizationPrivateKey() {
            return existing
        }
        #if targetEnvironment(simulator)
        do {
            return try createDeviceAuthorizationPrivateKey(secureEnclave: true)
        } catch {
            return try createDeviceAuthorizationPrivateKey(secureEnclave: false)
        }
        #else
        // On a device the auth key lives in the Secure Enclave or not at all.
        return try createDeviceAuthorizationPrivateKey(secureEnclave: true)
        #endif
    }

    private func loadDeviceAuthorizationPrivateKey() throws -> SecKey? {
        var query = keyQuery(tag: Item.deviceAuthKeyTag)
        query[kSecReturnRef] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let ref = result, CFGetTypeID(ref) == SecKeyGetTypeID() else {
                throw StorageError.secureEnclave("device auth key: unexpected type in Keychain result")
            }
            return unsafeDowncast(ref, to: SecKey.self)
        case errSecItemNotFound:
            return nil
        case let status:
            throw StorageError.keychain(status: status)
        }
    }

    private func createDeviceAuthorizationPrivateKey(secureEnclave: Bool) throws -> SecKey {
        let tag = Data(Item.deviceAuthKeyTag.utf8)
        var accessError: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .privateKeyUsage,
                &accessError
            )
        else {
            throw StorageError.secureEnclave("device auth access control: \(String(describing: accessError?.takeRetainedValue()))")
        }

        var privateKeyAttrs: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: tag,
            kSecAttrAccessControl: access,
        ]
        if let group = config.accessGroup { privateKeyAttrs[kSecAttrAccessGroup] = group }

        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: privateKeyAttrs,
        ]
        if secureEnclave {
            attributes[kSecAttrTokenID] = kSecAttrTokenIDSecureEnclave
        }

        var createError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            throw StorageError.secureEnclave("device auth create: \(String(describing: createError?.takeRetainedValue()))")
        }
        return key
    }

    private func keyQuery(tag: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag: Data(tag.utf8),
        ]
        if let group = config.accessGroup { query[kSecAttrAccessGroup] = group }
        return query
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

    // MARK: - Generic secrets

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
    /// The device identity, generated and persisted on first use. The serialized
    /// private key exists only in the Keychain item.
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

    /// Installs the account identity provisioned by the primary during linking.
    /// Must run before anything calls `identityKeyPair()`, which would otherwise
    /// generate a new one.
    ///
    /// Refuses to overwrite an existing identity unless `replacingExisting` is
    /// set. Keychain items survive sign-out and app deletion, so a phone that
    /// once ran Relay still holds a stale identity; the link flow replaces it.
    /// Replacing also drops the old registration id so a new one is generated.
    public func installProvisionedIdentity(_ serialized: Data, replacingExisting: Bool = false) throws {
        // A malformed payload should fail here, before anything is persisted.
        _ = try IdentityKeyPair(bytes: serialized)
        if try read(Item.identityKeyPair) != nil {
            guard replacingExisting else {
                throw KeychainError.identityAlreadyExists
            }
            try deleteSecret(for: Item.registrationId)
        }
        try write(Item.identityKeyPair, data: serialized)
    }

    // MARK: - Wiping

    /// Deletes this install's identity material from the Keychain: the identity
    /// key pair, the registration id, and the device auth key (recreated on
    /// demand).
    ///
    /// Leaves the database master key, its wrapping key, and secrets stored via
    /// `storeSecret`; see `wipeAllSecrets()` for a full reset.
    ///
    /// Call on sign-out after closing the database, and before installing a
    /// provisioned identity. Idempotent.
    public func wipeIdentity() throws {
        try deleteSecret(for: Item.identityKeyPair)
        try deleteSecret(for: Item.registrationId)
        try deleteKey(tag: Item.deviceAuthKeyTag)
    }

    /// Full reset: everything `wipeIdentity()` deletes plus the database master
    /// key (both variants), the Enclave wrapping key, and every secret under this
    /// service. Any existing database becomes undecryptable, so delete it too.
    /// Idempotent.
    public func wipeAllSecrets() throws {
        try wipeIdentity()
        try deleteKey(tag: Item.enclaveKeyTag)
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: config.service,
        ]
        if let group = config.accessGroup { query[kSecAttrAccessGroup] = group }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.keychain(status: status)
        }
    }

    private func deleteKey(tag: String) throws {
        let status = SecItemDelete(keyQuery(tag: tag) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.keychain(status: status)
        }
    }
}

public enum KeychainError: Error, Equatable {
    /// An identity already exists and replacement wasn't requested.
    case identityAlreadyExists
}
