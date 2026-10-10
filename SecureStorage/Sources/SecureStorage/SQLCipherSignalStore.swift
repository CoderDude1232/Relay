//
//  SQLCipherSignalStore.swift
//  SecureStorage
//
//  libsignal stores backed by the SQLCipher database. Conforms to
//  CryptoCore's `SignalStores` so a `CryptoEngine` runs directly on it.
//
//  Identity policy is trust-on-first-use. An unknown identity is trusted and
//  recorded; a changed one is untrusted and resets verification until it is
//  saved again, which drives the safety-number-changed warning.
//
//  Identities are keyed by (account, device id), but all devices of an
//  account share its identity key, so TOFU applies per account. A new device
//  id for a known account is trusted only if it presents a key already stored
//  for that account; anything else is treated as a changed key.
//

import CryptoCore
import Foundation
import LibSignalClient

/// The device's long-lived credentials: Keychain-backed in production,
/// in-memory in tests. The private identity key never enters the database.
public protocol IdentityCredentialProviding: AnyObject {
    func identityKeyPair() throws -> IdentityKeyPair
    func registrationId() throws -> UInt32
}

public final class SQLCipherSignalStore {
    private let db: Database
    private let credentials: any IdentityCredentialProviding
    /// Our own account id. All our devices share our identity key, so a device
    /// of this account presenting any other key is never trusted. TOFU for
    /// ourselves would let the relay add a hidden device that receives sync
    /// copies of everything we send. Set once at startup.
    public var localAccountName: String?

    public init(database: Database, credentials: any IdentityCredentialProviding) {
        self.db = database
        self.credentials = credentials
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - IdentityKeyStore

extension SQLCipherSignalStore: IdentityKeyStore {
    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        try credentials.identityKeyPair()
    }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 {
        try credentials.registrationId()
    }

    public func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        try db.transaction {
            let existing = try self.identity(for: address, context: context)
            if existing == identity {
                return .newOrUnchanged
            }
            let serialized = identity.serialize()
            if existing != nil {
                // A changed key resets verification for this device. verified_key is kept
                // so the state reads as `.changed`.
                try db.run(
                    "UPDATE remote_identities SET identity_key = ?, verified = 0 WHERE address = ? AND device_id = ?",
                    [.blob(serialized), .text(address.name), .integer(Int64(address.deviceId))]
                )
                return .replacedExisting
            }

            // A device id not seen before: compare with the keys of the account's
            // other devices.
            let siblings = try db.query(
                "SELECT identity_key, verified, verified_key FROM remote_identities WHERE address = ?",
                [.text(address.name)]
            )
            if siblings.isEmpty {
                // Unknown account: trust on first use.
                try insertIdentity(serialized, for: address, verified: false, verifiedKey: nil)
                return .newOrUnchanged
            }
            let matchesKnownKey = siblings.contains { $0[0].data == serialized }
            // The key the user last verified for this account, if any.
            let priorVerifiedKey = siblings.lazy.compactMap { $0[2].data }.first
            if matchesKnownKey {
                // Verification is a judgement about the key, so a device presenting
                // the key the user verified inherits it.
                let inheritsVerification = siblings.contains {
                    $0[0].data == serialized && $0[1].int64 == 1 && $0[2].data == serialized
                }
                try insertIdentity(
                    serialized,
                    for: address,
                    verified: inheritsVerification,
                    verifiedKey: inheritsVerification ? serialized : nil
                )
                return .newOrUnchanged
            }
            // A key the account never had: treat as a key change. If the account
            // was verified, record the old verified key so the state is `.changed`.
            try insertIdentity(serialized, for: address, verified: false, verifiedKey: priorVerifiedKey)
            return .replacedExisting
        }
    }

    private func insertIdentity(
        _ serialized: Data,
        for address: ProtocolAddress,
        verified: Bool,
        verifiedKey: Data?
    ) throws {
        try db.run(
            """
            INSERT INTO remote_identities (address, device_id, identity_key, verified, verified_key, first_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text(address.name),
                .integer(Int64(address.deviceId)),
                .blob(serialized),
                .integer(verified ? 1 : 0),
                verifiedKey.map(SQLValue.blob) ?? .null,
                .integer(now()),
            ]
        )
    }

    /// Trust policy for sending (receiving from contacts always trusts, below):
    /// - a device of our own account is trusted iff it presents our identity key;
    /// - a known device is trusted iff its key is unchanged;
    /// - a new device id on an account with other known devices is trusted iff it
    ///   presents a key already stored for that account;
    /// - an unknown account is trusted on first use.
    public func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        if let localAccountName, address.name == localAccountName {
            return identity == (try credentials.identityKeyPair().identityKey)
        }
        // Receiving from a contact: accept a changed key, as Signal does, so
        // messages sent after a reinstall aren't dropped. libsignal then saves it,
        // resetting `verified`, and sending stays blocked until the user accepts
        // the new safety number.
        if direction == .receiving {
            return true
        }
        if let known = try self.identity(for: address, context: context) {
            return known == identity
        }
        let accountKeys = try identityKeys(address: address.name)
        if accountKeys.isEmpty {
            return true
        }
        return accountKeys.contains(identity.serialize())
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        let rows = try db.query(
            "SELECT identity_key FROM remote_identities WHERE address = ? AND device_id = ?",
            [.text(address.name), .integer(Int64(address.deviceId))]
        )
        guard let blob = rows.first?.first?.data else { return nil }
        return try IdentityKey(bytes: blob)
    }

    /// Distinct identity keys stored for any device of account `name`, lowest
    /// device id first. More than one means a device presented a different key.
    public func identityKeys(address name: String) throws -> [Data] {
        let rows = try db.query(
            "SELECT identity_key FROM remote_identities WHERE address = ? ORDER BY device_id",
            [.text(name)]
        )
        var keys: [Data] = []
        for row in rows {
            if let key = row.first?.data, !keys.contains(key) { keys.append(key) }
        }
        return keys
    }
}

// MARK: - Verification state

/// The out-of-band verification status of a peer's identity.
public enum VerificationState: Sendable, Equatable {
    /// Never verified, or verification was cleared.
    case unverified
    /// Verified, and the key is unchanged since.
    case verified
    /// Was verified, but the key has changed since. The user should re-verify.
    case changed
}

extension SQLCipherSignalStore {
    public func isVerified(address name: String) throws -> Bool {
        try verificationState(address: name) == .verified
    }

    /// Marks every known device of a peer verified, recording each current key,
    /// or clears verification on all of them, which also dismisses a "changed"
    /// warning. Verification is per account.
    public func setVerified(_ verified: Bool, address name: String) throws {
        if verified {
            try db.run(
                "UPDATE remote_identities SET verified = 1, verified_key = identity_key WHERE address = ?",
                [.text(name)]
            )
        } else {
            try db.run(
                "UPDATE remote_identities SET verified = 0, verified_key = NULL WHERE address = ?",
                [.text(name)]
            )
        }
    }

    /// Aggregate verification state over a peer's known devices. `saveIdentity`
    /// resets `verified` on a key change but keeps `verified_key`, so:
    /// - `.changed` if any device's key changed since it was verified,
    /// - `.verified` if every device is verified,
    /// - `.unverified` otherwise.
    public func verificationState(address name: String) throws -> VerificationState {
        let rows = try db.query(
            "SELECT verified, identity_key, verified_key FROM remote_identities WHERE address = ?",
            [.text(name)]
        )
        guard !rows.isEmpty else { return .unverified }
        var allVerified = true
        for row in rows {
            let isVerified = row[0].int64 == 1
            if !isVerified { allVerified = false }
            // Verified once, but the current key differs.
            if let verifiedKey = row[2].data, let currentKey = row[1].data,
               verifiedKey != currentKey {
                return .changed
            }
        }
        return allVerified ? .verified : .unverified
    }
}

// MARK: - PreKeyStore

extension SQLCipherSignalStore: PreKeyStore {
    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        let rows = try db.query("SELECT record FROM prekeys WHERE id = ?", [.integer(Int64(id))])
        guard let blob = rows.first?.first?.data else {
            throw StorageError.recordNotFound("prekey \(id)")
        }
        return try PreKeyRecord(bytes: blob)
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try db.run(
            "INSERT OR REPLACE INTO prekeys (id, record) VALUES (?, ?)",
            [.integer(Int64(id)), .blob(record.serialize())]
        )
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws {
        try db.run("DELETE FROM prekeys WHERE id = ?", [.integer(Int64(id))])
    }
}

// MARK: - SignedPreKeyStore

extension SQLCipherSignalStore: SignedPreKeyStore {
    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        let rows = try db.query("SELECT record FROM signed_prekeys WHERE id = ?", [.integer(Int64(id))])
        guard let blob = rows.first?.first?.data else {
            throw StorageError.recordNotFound("signed prekey \(id)")
        }
        return try SignedPreKeyRecord(bytes: blob)
    }

    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try db.run(
            "INSERT OR REPLACE INTO signed_prekeys (id, record) VALUES (?, ?)",
            [.integer(Int64(id)), .blob(record.serialize())]
        )
    }
}

// MARK: - KyberPreKeyStore

extension SQLCipherSignalStore: KyberPreKeyStore {
    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        let rows = try db.query("SELECT record FROM kyber_prekeys WHERE id = ?", [.integer(Int64(id))])
        guard let blob = rows.first?.first?.data else {
            throw StorageError.recordNotFound("kyber prekey \(id)")
        }
        return try KyberPreKeyRecord(bytes: blob)
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try db.run(
            "INSERT OR REPLACE INTO kyber_prekeys (id, record) VALUES (?, ?)",
            [.integer(Int64(id)), .blob(record.serialize())]
        )
    }

    public func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId: UInt32,
        baseKey: PublicKey,
        context: StoreContext
    ) throws {
        // One-time keys (id flag 0x800000, see CryptoEngine.oneTimeKyberIdFlag)
        // are deleted; the last-resort key is reusable, so it's only marked.
        if id & 0x0080_0000 != 0 {
            try db.run("DELETE FROM kyber_prekeys WHERE id = ?", [.integer(Int64(id))])
        } else {
            try db.run("UPDATE kyber_prekeys SET used = 1 WHERE id = ?", [.integer(Int64(id))])
        }
    }
}

// MARK: - SessionStore

extension SQLCipherSignalStore: SessionStore {
    public func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        let rows = try db.query(
            "SELECT record FROM sessions WHERE address = ? AND device_id = ?",
            [.text(address.name), .integer(Int64(address.deviceId))]
        )
        guard let blob = rows.first?.first?.data else { return nil }
        return try SessionRecord(bytes: blob)
    }

    public func loadExistingSessions(
        for addresses: [ProtocolAddress],
        context: StoreContext
    ) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let session = try loadSession(for: address, context: context) else {
                throw StorageError.recordNotFound("session \(address.name).\(address.deviceId)")
            }
            return session
        }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO sessions (address, device_id, record, updated_at)
            VALUES (?, ?, ?, ?)
            """,
            [.text(address.name), .integer(Int64(address.deviceId)), .blob(record.serialize()), .integer(now())]
        )
    }
}

// MARK: - SenderKeyStore

extension SQLCipherSignalStore: SenderKeyStore {
    public func storeSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
        context: StoreContext
    ) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO sender_keys (sender, sender_device, distribution_id, record)
            VALUES (?, ?, ?, ?)
            """,
            [
                .text(sender.name),
                .integer(Int64(sender.deviceId)),
                .text(distributionId.uuidString),
                .blob(record.serialize()),
            ]
        )
    }

    public func loadSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        context: StoreContext
    ) throws -> SenderKeyRecord? {
        let rows = try db.query(
            "SELECT record FROM sender_keys WHERE sender = ? AND sender_device = ? AND distribution_id = ?",
            [.text(sender.name), .integer(Int64(sender.deviceId)), .text(distributionId.uuidString)]
        )
        guard let blob = rows.first?.first?.data else { return nil }
        return try SenderKeyRecord(bytes: blob)
    }
}
