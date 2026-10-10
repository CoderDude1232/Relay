//
//  PreKeyMaintainer.swift
//  RelayKit
//
//  Keeps the one-time prekey pool topped up. When the relay reports fewer
//  than `threshold` keys, uploads a fresh batch with rotated signed and
//  Kyber prekeys.
//

import CryptoCore
import Foundation

/// Hands out prekey ids that are never reused over the device's lifetime.
public protocol PreKeyIdAllocating: AnyObject, Sendable {
    func allocateIds(count: Int) throws -> Range<UInt32>
}

public struct PreKeyMaintainer: Sendable {
    public let threshold: Int
    public let batchSize: Int
    public let kyberThreshold: Int
    public let kyberBatchSize: Int

    public init(threshold: Int = 20, batchSize: Int = 100, kyberThreshold: Int = 10, kyberBatchSize: Int = 40) {
        self.threshold = threshold
        self.batchSize = batchSize
        self.kyberThreshold = kyberThreshold
        self.kyberBatchSize = kyberBatchSize
    }

    /// Uploads the device's first key publication. The local store is fresh, so
    /// this replaces the relay's one-time pool instead of appending to it. Otherwise
    /// a previous install's higher-id keys survive on the relay, get served once the
    /// new keys run out, and every session built on them fails to decrypt.
    public func publishInitialKeys(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating
    ) async throws {
        try await upload(api: api, engine: engine, allocator: allocator, replaceOneTime: true)
    }

    /// Replaces the whole published pool: fresh signed and Kyber prekeys plus a
    /// full one-time batch. Used when an inbound message references a one-time
    /// prekey the local store no longer has.
    public func replacePublishedPool(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating
    ) async throws {
        try await upload(api: api, engine: engine, allocator: allocator, replaceOneTime: true)
    }

    /// Re-publishes the identity, signed prekey and Kyber prekey (no one-time
    /// keys), replacing what the server holds. Run on launch so the server never
    /// serves a signed prekey whose private half this device lost, e.g. after a
    /// reinstall wiped the local store.
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

    /// Replenishes the pool when it's below threshold. Returns true if it uploaded.
    @discardableResult
    public func replenishIfNeeded(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating
    ) async throws -> Bool {
        let remaining = try await api.preKeyCounts()
        guard remaining.ec < threshold || remaining.kyber < kyberThreshold else { return false }
        try await upload(api: api, engine: engine, allocator: allocator)
        return true
    }

    private func upload(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating,
        replaceOneTime: Bool = false
    ) async throws {
        // One id each for the signed and last-resort Kyber prekeys, then the
        // EC pool, then the one-time Kyber pool.
        let ids = try allocator.allocateIds(count: batchSize + kyberBatchSize + 2)
        let ecEnd = ids.lowerBound + 2 + UInt32(batchSize)
        let publication = try engine.generatePreKeyPublication(
            signedPreKeyId: ids.lowerBound,
            kyberPreKeyId: ids.lowerBound + 1,
            oneTimePreKeyIds: (ids.lowerBound + 2)..<ecEnd,
            oneTimeKyberPreKeyIds: ecEnd..<ids.upperBound
        )
        try await api.uploadKeys(publication, replaceOneTimePreKeys: replaceOneTime)
    }
}
