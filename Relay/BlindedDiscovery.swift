//
//  BlindedDiscovery.swift
//  Relay
//
//  Client half of the ristretto255 DH-OPRF used for blinded contact discovery.
//  The relay never sees a plaintext username or email: we blind H1(x), the
//  server evaluates it under its key, and we unblind and derive a lookup token.
//  The token stays on device too; `directoryResolve(tokens:)` sends only a
//  16-bit bucket and matches entries locally (see DirectoryBuckets.swift).
//  Must match the server's `internal/oprf` byte-for-byte: domain tags,
//  normalization, hashes and encodings (see the interop test).
//

import Clibsodium
import CryptoKit
import Foundation

enum BlindedDiscovery {
    // Domain-separation tags; must match server/internal/oprf/oprf.go.
    private static let hashToGroupDomain = Data("Relay-OPRF-v1-h2g".utf8)
    private static let tokenDomain = Data("Relay-OPRF-v1-token".utf8)

    private static let initOnce: Int32 = sodium_init()

    /// Lowercase + trim, matching the server's `Normalize`.
    static func normalize(_ identifier: String) -> Data {
        Data(identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
    }

    /// H1(x): domain-separated SHA-512 mapped onto the ristretto255 group.
    private static func hashToGroup(_ x: Data) -> [UInt8] {
        var hasher = SHA512()
        hasher.update(data: hashToGroupDomain)
        hasher.update(data: x)
        let digest = [UInt8](hasher.finalize()) // 64 bytes
        var point = [UInt8](repeating: 0, count: 32)
        _ = crypto_core_ristretto255_from_hash(&point, digest)
        return point
    }

    /// A blinded identifier ready for server evaluation, plus the private material
    /// needed to unblind the result.
    struct Blinded {
        let element: Data      // B = r·H1(x), sent to the server
        fileprivate let blind: [UInt8]      // r
        fileprivate let normalized: Data    // x
    }

    /// Returns nil only for a degenerate scalar/point (libsodium rejects the
    /// identity element).
    static func blind(_ identifier: String) -> Blinded? {
        _ = initOnce
        let x = normalize(identifier)
        let hx = hashToGroup(x)
        var r = [UInt8](repeating: 0, count: 32)
        crypto_core_ristretto255_scalar_random(&r)
        var b = [UInt8](repeating: 0, count: 32)
        guard crypto_scalarmult_ristretto255(&b, r, hx) == 0 else { return nil }
        return Blinded(element: Data(b), blind: r, normalized: x)
    }

    /// Unblinds the server's evaluation E = k·B into N = k·H1(x) and derives the
    /// directory token H2(x, N).
    static func token(for blinded: Blinded, evaluated: Data) -> Data? {
        _ = initOnce
        guard evaluated.count == 32 else { return nil }
        var rInv = [UInt8](repeating: 0, count: 32)
        guard crypto_core_ristretto255_scalar_invert(&rInv, blinded.blind) == 0 else { return nil }
        var n = [UInt8](repeating: 0, count: 32)
        guard crypto_scalarmult_ristretto255(&n, rInv, [UInt8](evaluated)) == 0 else { return nil }
        var hasher = SHA256()
        hasher.update(data: tokenDomain)
        hasher.update(data: blinded.normalized)
        hasher.update(data: Data(n))
        return Data(hasher.finalize())
    }
}
