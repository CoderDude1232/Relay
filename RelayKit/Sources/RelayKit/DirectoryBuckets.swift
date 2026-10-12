//
//  DirectoryBuckets.swift
//  RelayKit
//
//  Client half of bucketed blinded discovery. After the OPRF round the client
//  holds a 32-byte token t per identifier and never sends it. It sends only
//  bucket(t), matches tag(t) against the bucket's entries, and opens the
//  matching box locally. Must match server/internal/oprf/directory.go exactly
//  (vectors in directory_test.go: t = 0x42 x 32 gives bucket 0xde0d,
//  tag 29f97dd6fe1965da,
//  key c7b86232d122314163544dac008ad7cbb32ef9aa26253a2b859a4a6eb969d155).
//
//    bucket(t) = big-endian UInt16 of SHA-256("relay-bucket" || t)[0..<2]
//    tag(t)    = HMAC-SHA256(key: t, "relay-tag")[0..<8]
//    key(t)    = HKDF-SHA256(ikm: t, salt: none, info: "relay-entry", 32)
//    box       = nonce(12) || AES-256-GCM ciphertext || tag(16)
//                of UTF-8 "accountId\nusername"
//

import CryptoKit
import Foundation

/// One entry of a directory bucket as served by the relay.
public struct DirectoryBucketEntry: Sendable, Equatable {
    public let tag: Data
    public let box: Data
    /// The account's sealed-sender access key, sealed under the same key as
    /// `box`, so the first key fetch can be anonymous. Absent from older relays.
    public let accessBox: Data?

    public init(tag: Data, box: Data, accessBox: Data? = nil) {
        self.tag = tag
        self.box = box
        self.accessBox = accessBox
    }
}

public enum DirectoryBuckets {
    static let maxBucketsPerRequest = 1024
    /// Every lookup asks for at least this many buckets (real plus decoys).
    static let decoyPaddedRequestSize = 512

    /// Keys the decoy choice. The app sets a per-install secret at launch;
    /// until then it's random for the process.
    nonisolated(unsafe) public static var decoySeed: Data = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })

    /// Decoys that always travel with a given real bucket.
    static let decoysPerBucket = 63
    /// Above this many real buckets (a contact sync) the request is already
    /// a crowd, and per-bucket decoys would multiply it past reason.
    static let maxBucketsWithOwnDecoys = 64

    /// The real buckets padded with decoys, shuffled. Decoys come from the
    /// seed, not fresh randomness: each real bucket always brings the same
    /// companions, so however often someone is looked up, and alongside
    /// whomever, intersecting the requests leaves at least that bucket's 64.
    /// The rest of the padding to `decoyPaddedRequestSize` is derived from the
    /// whole set, so repeating a lookup repeats the request exactly.
    static func paddedRequest(real: Set<UInt16>, seed: Data = decoySeed) -> [UInt16] {
        let key = SymmetricKey(data: seed)
        func stream(_ label: String, _ buckets: [UInt16]) -> () -> UInt16 {
            var input = Data(label.utf8)
            for bucket in buckets { input.append(UInt8(bucket >> 8)); input.append(UInt8(bucket & 0xff)) }
            var counter: UInt32 = 0
            var pool: [UInt8] = []
            return {
                if pool.count < 2 {
                    var block = input
                    withUnsafeBytes(of: counter.bigEndian) { block.append(contentsOf: $0) }
                    counter += 1
                    pool += Array(HMAC<SHA256>.authenticationCode(for: block, using: key))
                }
                defer { pool.removeFirst(2) }
                return UInt16(pool[0]) << 8 | UInt16(pool[1])
            }
        }
        let sortedReal = real.sorted()
        var requested = real
        if real.count <= maxBucketsWithOwnDecoys {
            for bucket in sortedReal {
                let next = stream("relay-decoy-bucket", [bucket])
                for _ in 0..<decoysPerBucket { requested.insert(next()) }
            }
        }
        let fill = stream("relay-decoy-set", sortedReal)
        while requested.count < decoyPaddedRequestSize { requested.insert(fill()) }
        // Order from the same stream, so it's deterministic too.
        let order = stream("relay-decoy-order", sortedReal)
        return requested.sorted().map { ($0, order()) }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The 16-bit bucket for a token; the only part the relay sees.
    public static func bucket(for token: Data) -> UInt16 {
        var hasher = SHA256()
        hasher.update(data: Data("relay-bucket".utf8))
        hasher.update(data: token)
        let digest = Array(hasher.finalize())
        return UInt16(digest[0]) << 8 | UInt16(digest[1])
    }

    /// The 8-byte match tag for a token.
    public static func tag(for token: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("relay-tag".utf8), using: SymmetricKey(data: token))
        return Data(mac).prefix(8)
    }

    static func entryKey(for token: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: token),
            info: Data("relay-entry".utf8),
            outputByteCount: 32
        )
    }

    /// Opens a box with the token-derived key, returning (accountId, username).
    public static func open(box: Data, token: Data) -> (accountId: String, username: String)? {
        guard let sealed = try? AES.GCM.SealedBox(combined: box),
              let plaintext = try? AES.GCM.open(sealed, using: entryKey(for: token)),
              let text = String(data: plaintext, encoding: .utf8),
              let sep = text.firstIndex(of: "\n")
        else { return nil }
        return (String(text[..<sep]), String(text[text.index(after: sep)...]))
    }

    /// Opens an entry's access box, returning the 32-byte access key.
    public static func openAccessKey(box: Data, token: Data) -> Data? {
        guard let sealed = try? AES.GCM.SealedBox(combined: box),
              let key = try? AES.GCM.open(sealed, using: entryKey(for: token),
                                          authenticating: Data("relay-access-key".utf8)),
              key.count == 32
        else { return nil }
        return key
    }

    /// Finds and opens this token's entry among a bucket's entries, if present.
    public static func match(token: Data, in entries: [DirectoryBucketEntry]) -> (accountId: String, username: String, accessKey: Data?)? {
        let mine = tag(for: token)
        for entry in entries where entry.tag == mine {
            if let hit = open(box: entry.box, token: token) {
                return (hit.accountId, hit.username, entry.accessBox.flatMap { openAccessKey(box: $0, token: token) })
            }
        }
        return nil
    }
}
