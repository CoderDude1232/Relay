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
        static let deviceAuthKeyTag = "app.relay.device-authorization-key"
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
        #if targetEnvironment(simulator)
        // No Secure Enclave in the Simulator: Keychain protection only.
        if let enclaveKey = try? enclaveWrappingKey() {
            try write(Item.wrappedDatabaseKey, data: try wrap(key.bytes, with: enclaveKey))
        } else {
            try write(Item.plainDatabaseKey, data: key.bytes)
        }
        #else
        // Every supported iPhone has a Secure Enclave. A failure here is an
        // error to surface, not a reason to store the master key unwrapped.
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

    /// Returns the public half of this device's authorization key, creating a
    /// non-exportable private key in the Secure Enclave where available. The
    /// Simulator falls back to a Keychain-held private key so the feature stays
    /// testable without changing app behavior.
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

    /// Signs device-control payloads for later stages. Stage 3A only uploads
    /// the public key; Stage 3B will define the signed device-list payloads.
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

    /// Installs an account identity provisioned from the primary device during
    /// linking, so this device shares the account's identity key rather than
    /// generating its own. Must be called before anything reads
    /// `identityKeyPair()` (which would otherwise auto-generate a fresh one).
    ///
    /// By default refuses to overwrite an existing identity — a device that
    /// already has one must not have it silently replaced. Keychain items
    /// survive sign-out and app deletion, so a phone that ever ran Relay still
    /// holds a stale identity: the link flow passes `replacingExisting: true`
    /// (or calls `wipeIdentity()` first) to adopt the account's identity. When
    /// replacing, the stale registration id is dropped too so a fresh one is
    /// generated for this device. The serialized private key lives only inside
    /// the Keychain item; it is never logged.
    public func installProvisionedIdentity(_ serialized: Data, replacingExisting: Bool = false) throws {
        // Validate before persisting; a malformed payload should fail loudly.
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

    /// Deletes this install's per-account identity material from the Keychain:
    ///
    /// * `identity-key-pair` — the identity private/public key pair
    /// * `registration-id`   — the libsignal registration id
    /// * the device authorization key (Secure Enclave / Keychain P-256 key
    ///   used for `Relay-Sig` request signing); a new one is created on demand
    ///
    /// NOT deleted: the database master key (wrapped/plain) and its Secure
    /// Enclave wrapping key, and generic secrets stored via `storeSecret`
    /// (e.g. saved account credentials) — callers delete those by name. Use
    /// `wipeAllSecrets()` for a full reset.
    ///
    /// Call on sign-out (after closing the database/service) and before
    /// installing a provisioned identity on a phone that may have run Relay
    /// before. The next `identityKeyPair()` / `registrationId()` generates
    /// fresh values. Idempotent: missing items are not an error.
    public func wipeIdentity() throws {
        try deleteSecret(for: Item.identityKeyPair)
        try deleteSecret(for: Item.registrationId)
        try deleteKey(tag: Item.deviceAuthKeyTag)
    }

    /// Full reset: everything `wipeIdentity()` deletes, PLUS the database
    /// master key (wrapped and plain variants), the Secure Enclave wrapping
    /// key, and every generic secret stored under this store's service
    /// (including anything written via `storeSecret`). Any existing database
    /// file becomes undecryptable — delete it as well. Idempotent.
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
    /// An identity key already exists; refusing to overwrite it during linking.
    case identityAlreadyExists
}
