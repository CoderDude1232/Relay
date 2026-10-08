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
//  Identities are keyed by (account, device id). All devices of one account
//  share the account identity key (linked devices receive it via
//  provisioning), so TOFU applies per ACCOUNT, not per device: a device id
//  we have never seen for an already-known account is trusted only if it
//  presents one of the identity keys already stored for that account.
//  Anything else is treated exactly like a changed key.
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
    /// Our own account id. Every device of our own account shares our identity
    /// key (linked devices receive it at provisioning), so a device of this
    /// account presenting any other key is never trusted — no trust-on-first-use
    /// for ourselves, or the relay could add a hidden device that receives a
    /// sync copy of everything we send. Set once at startup, before any use.
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
                // A changed key resets any prior verification (for this device);
                // verified_key is kept so the state surfaces as `.changed`.
                try db.run(
                    "UPDATE remote_identities SET identity_key = ?, verified = 0 WHERE address = ? AND device_id = ?",
                    [.blob(serialized), .text(address.name), .integer(Int64(address.deviceId))]
                )
                return .replacedExisting
            }

            // A device id never seen before. Compare against the account's
            // other devices' keys (shared account identity).
            let siblings = try db.query(
                "SELECT identity_key, verified, verified_key FROM remote_identities WHERE address = ?",
                [.text(address.name)]
            )
            if siblings.isEmpty {
                // Brand-new account: trust on first use.
                try insertIdentity(serialized, for: address, verified: false, verifiedKey: nil)
                return .newOrUnchanged
            }
            let matchesKnownKey = siblings.contains { $0[0].data == serialized }
            // The key the user last verified for this account, if any.
            let priorVerifiedKey = siblings.lazy.compactMap { $0[2].data }.first
            if matchesKnownKey {
                // Another device of the same identity. Verification is a
                // judgement about the key, so a device presenting the very key
                // the user verified inherits it.
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
            // A new device with a key the account never had: equivalent to a
            // key change. Unverified; if the account had been verified, record
            // the previously verified key so the aggregate state is `.changed`.
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

    /// Trust policy (sending; receiving from contacts always trusts, see below):
    /// - a device of our own account is trusted iff it presents our own
    ///   identity key;
    /// - a device we already have a key for is trusted iff the key is unchanged;
    /// - a device id never seen for an account that has OTHER known devices is
    ///   trusted iff it presents one of the identity keys already stored for
    ///   that account (all devices share the account identity) — otherwise it
    ///   is untrusted, exactly like a changed key;
    /// - a completely unknown account is trusted on first use.
    public func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        if let localAccountName, address.name == localAccountName {
            return identity == (try credentials.identityKeyPair().identityKey)
        }
        // Receiving from a contact: accept a changed key (as Signal does) so
        // their messages after a reinstall aren't silently dropped. libsignal
        // then saves it — which resets `verified` — and sending stays blocked
        // until the user acknowledges the new safety number.
        if direction == .receiving {
            return true
        }
        if let known = try self.identity(for: address, context: context) {
            return known == identity
        }
        let accountKeys = try identityKeys(address: address.name)
        if accountKeys.isEmpty {
            return true // trust on first use
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

    /// The distinct serialized identity keys stored for any device of the
    /// account `name`, ordered by lowest device id first. Normally one key
    /// (shared account identity); more than one means some device presented
    /// a different key (safety number changed for that account).
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
