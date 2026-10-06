//
//  PreKeyMaintainer.swift
//  RelayKit
//
//  Keeps the device's one-time prekey pool topped up: when the relay
//  reports fewer than `threshold` remaining, a fresh batch is generated
//  (with a rotated signed prekey and Kyber prekey) and uploaded.
//

import CryptoCore
import Foundation

/// Hands out prekey ids that are never reused across the device's
/// lifetime. Backed by the encrypted kv table in the app; in-memory in
/// tests.
public protocol PreKeyIdAllocating: AnyObject, Sendable {
    func allocateIds(count: Int) throws -> Range<UInt32>
}

public struct PreKeyMaintainer: Sendable {
    public let threshold: Int
    public let batchSize: Int

    public init(threshold: Int = 20, batchSize: Int = 100) {
        self.threshold = threshold
        self.batchSize = batchSize
    }

    /// Uploads the device's very first key publication. The local key store is
    /// fresh here (registration / linking / restore), so it replaces the relay's
    /// one-time pool rather than appending — otherwise a prior install's
    /// higher-id one-time keys survive on the relay, get served after the fresh
    /// low-id keys are consumed, and every session built on them fails to decrypt
    /// (the local store lacks their private halves).
    public func publishInitialKeys(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating
    ) async throws {
        try await upload(api: api, engine: engine, allocator: allocator, replaceOneTime: true)
    }

    /// Rebuilds the entire published pool from scratch: a fresh signed/Kyber
    /// prekey plus a full one-time batch, replacing whatever the relay holds.
    /// Called reactively when an inbound message references a one-time prekey the
    /// local store no longer has (a desync), to heal it for future sessions.
    public func replacePublishedPool(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating
    ) async throws {
        try await upload(api: api, engine: engine, allocator: allocator, replaceOneTime: true)
    }

    /// Re-publishes the identity, signed prekey and Kyber prekey (no one-time
    /// keys), replacing whatever the server currently holds. Run on launch so the
    /// server can never serve a signed prekey this device lacks the private for —
    /// which happens after the local key store is wiped (app reinstall) while the
    /// server keeps the old published bundle, breaking new inbound sessions.
    public func republishSignedPreKey(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating
    ) async throws {
        let ids = try allocator.allocateIds(count: 2)
        let publication = try engine.generatePreKeyPublication(
            signedPreKeyId: ids.lowerBound,
            kyberPreKeyId: ids.lowerBound + 1,
            oneTimePreKeyIds: ids.upperBound..<ids.upperBound // empty: append nothing
        )
        try await api.uploadKeys(publication)
    }

    /// Checks the pool and replenishes when it's below threshold.
    /// Returns true when an upload happened.
    @discardableResult
    public func replenishIfNeeded(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating
    ) async throws -> Bool {
        let remaining = try await api.oneTimePreKeyCount()
        guard remaining < threshold else { return false }
        try await upload(api: api, engine: engine, allocator: allocator)
        return true
    }

    private func upload(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating,
        replaceOneTime: Bool = false
    ) async throws {
        // One id for the signed prekey, one for the Kyber prekey, the rest
        // for the one-time pool.
        let ids = try allocator.allocateIds(count: batchSize + 2)
        let publication = try engine.generatePreKeyPublication(
            signedPreKeyId: ids.lowerBound,
            kyberPreKeyId: ids.lowerBound + 1,
            oneTimePreKeyIds: (ids.lowerBound + 2)..<ids.upperBound
        )
        try await api.uploadKeys(publication, replaceOneTimePreKeys: replaceOneTime)
    }
}
