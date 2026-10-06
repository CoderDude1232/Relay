//
//  SQLCipherSignalStore.swift
//  SecureStorage
//
//  libsignal state stores backed by the SQLCipher database, replacing the
//  in-memory stores from the crypto-core stage. Conforms to CryptoCore's
//  `SignalStores`, so a `CryptoEngine` can run directly on top.
//
//  Identity policy is trust-on-first-use: an unknown peer identity is
//  trusted and recorded; a *changed* identity is untrusted (and resets
//  verification) until explicitly re-saved, which is what drives the
//  "safety number changed" warning in the UI later.
//

import CryptoCore
import Foundation
import LibSignalClient

/// The device's own long-lived credentials. Production wires the
/// Keychain-backed implementation; tests use an in-memory one. The private
/// identity key deliberately never enters the SQLCipher database.
public protocol IdentityCredentialProviding: AnyObject {
    func identityKeyPair() throws -> IdentityKeyPair
    func registrationId() throws -> UInt32
}

public final class SQLCipherSignalStore {
    private let db: Database
    private let credentials: any IdentityCredentialProviding

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
        let existing = try self.identity(for: address, context: context)
        if existing == identity {
            return .newOrUnchanged
        }
        // A changed key resets any prior verification (for this device).
        try db.run(
            """
            INSERT INTO remote_identities (address, device_id, identity_key, verified, first_seen_at)
            VALUES (?, ?, ?, 0, ?)
            ON CONFLICT (address, device_id) DO UPDATE SET identity_key = excluded.identity_key, verified = 0
            """,
            [.text(address.name), .integer(Int64(address.deviceId)), .blob(identity.serialize()), .integer(now())]
        )
        return existing == nil ? .newOrUnchanged : .replacedExisting
    }

    public func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        guard let known = try self.identity(for: address, context: context) else {
            return true // trust on first use
        }
        return known == identity
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        let rows = try db.query(
            "SELECT identity_key FROM remote_identities WHERE address = ? AND device_id = ?",
            [.text(address.name), .integer(Int64(address.deviceId))]
        )
        guard let blob = rows.first?.first?.data else { return nil }
        return try IdentityKey(bytes: blob)
    }
}

// MARK: - Verification state (drives the safety-number UI)

/// The out-of-band verification status of a peer's identity.
public enum VerificationState: Sendable, Equatable {
    /// Never verified (or verification was explicitly cleared).
    case unverified
    /// Verified, and the identity key is unchanged since verification.
    case verified
    /// Was verified, but the peer's identity key has since changed — the
    /// user should re-verify. Drives the safety-number-changed warning.
    case changed
}

extension SQLCipherSignalStore {
    public func isVerified(address name: String) throws -> Bool {
        try verificationState(address: name) == .verified
    }

    /// Marks every known device of a peer verified (recording each device's
    /// current identity key) or clears verification across all of them (also
    /// dismissing a pending "changed" warning). Verification is an account-level
    /// judgement, so it aggregates over the peer's devices.
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

    /// Resolves the aggregate verification state over all of a peer's known
    /// devices. `saveIdentity` resets a device's `verified` to 0 on a key change
    /// but leaves its `verified_key` intact, so a mismatch surfaces as `.changed`.
    /// - `.changed` if ANY known device's key changed since it was verified,
    /// - `.verified` only if EVERY known device is currently verified,
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
            // A device that was verified (has a verified_key) but whose current
            // key differs is a safety-number change — surfaces immediately.
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
        // Our Kyber prekeys are last-resort keys (reusable by design), so
        // usage is recorded but the record is kept for delayed messages.
        try db.run("UPDATE kyber_prekeys SET used = 1 WHERE id = ?", [.integer(Int64(id))])
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
