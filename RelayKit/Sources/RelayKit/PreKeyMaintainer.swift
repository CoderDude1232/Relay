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

    /// Uploads the device's very first key publication.
    public func publishInitialKeys(
        api: RelayAPIClient,
        engine: CryptoEngine,
        allocator: any PreKeyIdAllocating
    ) async throws {
        try await upload(api: api, engine: engine, allocator: allocator)
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
        allocator: any PreKeyIdAllocating
    ) async throws {
        // One id for the signed prekey, one for the Kyber prekey, the rest
        // for the one-time pool.
        let ids = try allocator.allocateIds(count: batchSize + 2)
        let publication = try engine.generatePreKeyPublication(
            signedPreKeyId: ids.lowerBound,
            kyberPreKeyId: ids.lowerBound + 1,
            oneTimePreKeyIds: (ids.lowerBound + 2)..<ids.upperBound
        )
        try await api.uploadKeys(publication)
    }
}
