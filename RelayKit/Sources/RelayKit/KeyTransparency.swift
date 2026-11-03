//
//  KeyTransparency.swift
//  RelayKit
//
//  Checks the relay's key directory (docs/KEY_TRANSPARENCY.md): that a
//  contact's identity key is the one the relay publishes for them, that the
//  directory only ever grows, and that our own account holds no key we didn't
//  make. Mirrors server/internal/kt; the Go tests write vectors this must agree
//  with.
//

import CryptoKit
import Foundation
import Security

public enum KeyTransparency {
    // MARK: Live keys (public halves; docs/KEY_TRANSPARENCY.md)

    /// Ed25519 key that signs heads.
    public static let signPublicKey = Data(base64Encoded: "AzBwua2UHxq2M6FiWv+rJ8lAwOvG8b3f2BZXafwWW0I=")!
    /// RSA VRF key, PKCS#1.
    public static let vrfPublicKey = Data(base64Encoded: liveVRFPKCS1)!

    /// The witness (server/cmd/ktwitness, on a different machine from the
    /// relay) co-signs each head after checking it extends every head it saw.
    public static let witnessPublicKey = Data(base64Encoded: "t4GYsxbk2iG6sPnAWGPnF1I61Kcf4ujTsbhYRNhRkLE=")!
    /// Where the witness publishes the head it co-signed.
    public static let witnessURL = URL(string: "https://gist.githubusercontent.com/CoderDude1232/02b29ce6632a4784f37e1902e11aea5b/raw/kt-head.json")!

    public struct Endorsement: Codable, Equatable, Sendable {
        public let key: Data
        public let by: Data
        public let sig: Data
    }

    /// Head signing keys: the built-in one plus every key it (or a key it
    /// endorsed) vouched for, so the relay's key can be replaced without an
    /// app update.
    public static func trustedSignKeys(_ endorsements: [Endorsement]) -> [Data] {
        var trusted = [signPublicKey]
        for e in endorsements {
            let message = Data("relay-kt-endorse-v1|head|".utf8) + e.key
            for t in trusted {
                if t == e.by, e.key.count == 32,
                   let key = try? Curve25519.Signing.PublicKey(rawRepresentation: t),
                   key.isValidSignature(e.sig, for: message) {
                    trusted.append(e.key)
                    break
                }
            }
        }
        return trusted
    }

    /// The witness's published head, if both the relay's signature and the
    /// witness's co-signature check out. Also returns the relay's endorsements.
    public static func fetchWitnessHead(session: URLSession = .shared) async -> (head: Head, endorsements: [Endorsement])? {
        struct Published: Decodable {
            let epoch: UInt64, smtRoot: Data, logSize: UInt64, logRoot: Data, time: UInt64, sig: Data
            let witnessSig: Data
            let endorsements: [Endorsement]?
        }
        var request = URLRequest(url: witnessURL, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let p = try? JSONDecoder().decode(Published.self, from: data)
        else { return nil }
        let head = Head(epoch: p.epoch, smtRoot: p.smtRoot, logSize: p.logSize, logRoot: p.logRoot, time: p.time, sig: p.sig)
        let endorsements = p.endorsements ?? []
        guard verifySignature(head, signPublicKeys: trustedSignKeys(endorsements)),
              let witness = try? Curve25519.Signing.PublicKey(rawRepresentation: witnessPublicKey),
              witness.isValidSignature(p.witnessSig, for: Data("relay-kt-witness-v1".utf8) + headFields(head))
        else { return nil }
        return (head, endorsements)
    }

    // MARK: Wire types

    public struct Head: Codable, Equatable, Sendable {
        public let epoch: UInt64
        public let smtRoot: Data
        public let logSize: UInt64
        public let logRoot: Data
        public let time: UInt64
        public let sig: Data
    }

    public struct Proof: Codable, Equatable, Sendable {
        public let bitmap: Data
        public let siblings: [Data]
    }

    public struct Link: Codable, Equatable, Sendable {
        public let version: UInt32
        public let commitment: Data
    }

    public struct Lookup: Codable, Equatable, Sendable {
        /// Links after the version asked for with `since`, through the current one.
        public let links: [Link]?
        public let vrfProof: Data
        public let version: UInt32
        public let commitment: Data
        public let prevChain: Data
        public let nonce: Data?
        public let keys: [Data]?
        public let proof: Proof
        public let head: Head

        public init(vrfProof: Data, version: UInt32, commitment: Data, prevChain: Data, nonce: Data?,
                    keys: [Data]?, proof: Proof, head: Head, links: [Link]? = nil) {
            self.links = links
            self.vrfProof = vrfProof
            self.version = version
            self.commitment = commitment
            self.prevChain = prevChain
            self.nonce = nonce
            self.keys = keys
            self.proof = proof
            self.head = head
        }
    }

    public struct Version: Codable, Equatable, Sendable {
        public let version: UInt32
        public let commitment: Data
        public let nonce: Data
        public let keys: [Data]
        public let epoch: UInt64
    }

    public enum Failure: Error, Equatable {
        case headSignature, vrfProof, keyMismatch, notInTree, inconsistent, foreignKey
    }

    // MARK: Hashing

    static func sha256(_ parts: Data...) -> Data {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    static func uint32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    static func uint64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    public static func commit(nonce: Data, keys: [Data]) -> Data {
        var data = Data("relay-kt-commit".utf8) + nonce
        for key in keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            data += withUnsafeBytes(of: UInt16(key.count).bigEndian) { Data($0) } + key
        }
        return sha256(data)
    }

    public static func chain(prev: Data, version: UInt32, commitment: Data) -> Data {
        sha256(Data("relay-kt-chain".utf8), prev, uint32(version), commitment)
    }

    // MARK: VRF (RSA-FDH-VRF-SHA256, RFC 9381 §4)

    static func mgf1(_ seed: Data, length: Int) -> Data {
        var out = Data()
        var counter: UInt32 = 0
        while out.count < length {
            out += sha256(seed, uint32(counter))
            counter += 1
        }
        return out.prefix(length)
    }

    /// The label for `account`, if `proof` is the VRF's proof for it.
    static func vrfLabel(account: String, proof: Data, publicKey: Data) -> Data? {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(publicKey as CFData, attributes as CFDictionary, nil),
              let modulus = rsaModulus(pkcs1: publicKey)
        else { return nil }
        let k = modulus.count
        guard proof.count == k,
              let m = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, proof as CFData, nil) as Data?,
              m.count == k, m.first == 0
        else { return nil }
        var seed = Data([0x01, 0x01]) + uint32(UInt32(k)) + modulus
        seed += Data(account.utf8)
        guard m.dropFirst() == mgf1(seed, length: k - 1) else { return nil }
        return sha256(Data([0x01, 0x02]), proof)
    }

    /// The modulus of a PKCS#1 RSAPublicKey, k bytes with no leading zero.
    static func rsaModulus(pkcs1: Data) -> Data? {
        var i = pkcs1.startIndex
        func readLength() -> Int? {
            guard i < pkcs1.endIndex else { return nil }
            let first = pkcs1[i]; i += 1
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count <= 4, i + count <= pkcs1.endIndex else { return nil }
            var length = 0
            for _ in 0..<count { length = length << 8 | Int(pkcs1[i]); i += 1 }
            return length
        }
        guard i < pkcs1.endIndex, pkcs1[i] == 0x30 else { return nil }
        i += 1
        guard readLength() != nil, i < pkcs1.endIndex, pkcs1[i] == 0x02 else { return nil }
        i += 1
        guard let length = readLength(), i + length <= pkcs1.endIndex else { return nil }
        var modulus = pkcs1[i..<(i + length)]
        while modulus.first == 0 { modulus = modulus.dropFirst() }
        return Data(modulus)
    }

    // MARK: Sparse Merkle tree

    static let depth = 256
    static let emptyHash: [Data] = {
        var hashes = Array(repeating: Data(count: 32), count: depth + 1)
        for d in stride(from: depth - 1, through: 0, by: -1) {
            hashes[d] = sha256(Data([0x01]), hashes[d + 1], hashes[d + 1])
        }
        return hashes
    }()

    static func bit(_ data: Data, _ i: Int) -> Int {
        Int(data[data.startIndex + i / 8] >> (7 - UInt8(i % 8))) & 1
    }

    /// The root implied by a leaf (nil value: absent) and its path.
    static func rootFromProof(label: Data, value: Data?, proof: Proof) -> Data? {
        guard label.count == 32, proof.bitmap.count == 32 else { return nil }
        var set = 0
        for d in 0..<depth where bit(proof.bitmap, d) == 1 { set += 1 }
        guard set == proof.siblings.count else { return nil }
        var h = value.map { sha256(Data([0x00]), label, $0) } ?? emptyHash[depth]
        var next = proof.siblings.count - 1
        for d in stride(from: depth - 1, through: 0, by: -1) {
            var sibling = emptyHash[d + 1]
            if bit(proof.bitmap, d) == 1 {
                sibling = proof.siblings[next]
                next -= 1
            }
            h = bit(label, d) == 0
                ? sha256(Data([0x01]), h, sibling)
                : sha256(Data([0x01]), sibling, h)
        }
        return h
    }

    // MARK: Heads and the root log

    static func headFields(_ head: Head) -> Data {
        uint64(head.epoch) + head.smtRoot + uint64(head.logSize) + head.logRoot + uint64(head.time)
    }

    public static func verifySignature(_ head: Head, signPublicKey: Data = signPublicKey) -> Bool {
        verifySignature(head, signPublicKeys: [signPublicKey])
    }

    /// Signed by any of `signPublicKeys` (see `trustedSignKeys`).
    public static func verifySignature(_ head: Head, signPublicKeys: [Data]) -> Bool {
        let message = Data("relay-kt-head-v1".utf8) + headFields(head)
        return signPublicKeys.contains { raw in
            (try? Curve25519.Signing.PublicKey(rawRepresentation: raw))?.isValidSignature(head.sig, for: message) == true
        }
    }

    static func logNode(_ left: Data, _ right: Data) -> Data { sha256(Data([0x01]), left, right) }

    /// The log at `new` extends the log at `old` (RFC 9162 §2.1.4.2).
    public static func verifyConsistency(old: Head, new: Head, proof: [Data]) -> Bool {
        let m = Int(old.logSize), n = Int(new.logSize)
        guard m >= 1, m <= n else { return false }
        if m == n { return proof.isEmpty && old.logRoot == new.logRoot }
        var path = proof
        if m & (m - 1) == 0 { path.insert(old.logRoot, at: 0) }
        guard !path.isEmpty else { return false }
        var fn = m - 1, sn = n - 1
        while fn & 1 == 1 { fn >>= 1; sn >>= 1 }
        var fr = path[0], sr = path[0]
        for c in path.dropFirst() {
            guard sn != 0 else { return false }
            if fn & 1 == 1 || fn == sn {
                fr = logNode(c, fr)
                sr = logNode(c, sr)
                while fn != 0 && fn & 1 == 0 { fn >>= 1; sn >>= 1 }
            } else {
                sr = logNode(sr, c)
            }
            fn >>= 1
            sn >>= 1
        }
        return sn == 0 && fr == old.logRoot && sr == new.logRoot
    }

    // MARK: Checks

    /// `lookup` proves `account`'s current keys under a validly signed head
    /// and, if `key` is given, that it's one of them.
    public static func verify(_ lookup: Lookup, account: String, key: Data?,
                              vrfPublicKey: Data = vrfPublicKey, signPublicKey: Data = signPublicKey,
                              signPublicKeys: [Data]? = nil) throws {
        guard verifySignature(lookup.head, signPublicKeys: signPublicKeys ?? [signPublicKey]) else {
            throw Failure.headSignature
        }
        guard let label = vrfLabel(account: account, proof: lookup.vrfProof, publicKey: vrfPublicKey) else {
            throw Failure.vrfProof
        }
        if lookup.version == 0 {
            guard rootFromProof(label: label, value: nil, proof: lookup.proof) == lookup.head.smtRoot else {
                throw Failure.notInTree
            }
            if key != nil { throw Failure.keyMismatch }
            return
        }
        guard let nonce = lookup.nonce, let keys = lookup.keys,
              commit(nonce: nonce, keys: keys) == lookup.commitment
        else { throw Failure.keyMismatch }
        if let key, !keys.contains(key) { throw Failure.keyMismatch }
        let value = chain(prev: lookup.prevChain, version: lookup.version, commitment: lookup.commitment)
        guard rootFromProof(label: label, value: value, proof: lookup.proof) == lookup.head.smtRoot else {
            throw Failure.notInTree
        }
    }

    /// The chain value a lookup ends at.
    public static func latestChain(_ lookup: Lookup) -> Data {
        chain(prev: lookup.prevChain, version: lookup.version, commitment: lookup.commitment)
    }

    /// `lookup` grew from a state this device accepted before (version,
    /// chain): a key swapped in and later swapped back breaks the chain.
    public static func verifyExtends(version: UInt32, chain seen: Data, lookup: Lookup) throws {
        guard lookup.version >= version else { throw Failure.notInTree }
        let latest = latestChain(lookup)
        if lookup.version == version {
            guard latest == seen else { throw Failure.notInTree }
            return
        }
        var c = seen
        var next = version + 1
        for link in lookup.links ?? [] {
            guard link.version == next else { throw Failure.notInTree }
            c = chain(prev: c, version: link.version, commitment: link.commitment)
            next += 1
        }
        guard next == lookup.version + 1, c == latest else { throw Failure.notInTree }
    }

    /// An owner's history is one unbroken chain ending at `latest`. Returns the
    /// key set of every version.
    public static func verifyHistory(_ versions: [Version], latest: Lookup) throws -> [[Data]] {
        var prev = Data(count: 32)
        var sets: [[Data]] = []
        for (i, v) in versions.enumerated() {
            guard v.version == UInt32(i + 1), commit(nonce: v.nonce, keys: v.keys) == v.commitment else {
                throw Failure.notInTree
            }
            prev = chain(prev: prev, version: v.version, commitment: v.commitment)
            sets.append(v.keys)
        }
        guard versions.count == Int(latest.version),
              prev == chain(prev: latest.prevChain, version: latest.version, commitment: latest.commitment)
        else { throw Failure.notInTree }
        return sets
    }
}

/// The live VRF key's RSAPublicKey (PKCS#1, DER, base64).
private let liveVRFPKCS1 = "MIIBCgKCAQEAoFRYR4xchotekT/gxGcWyby+F4mVI65SmVB3bP1XTrm1B2d6XtPVbGadyav2WooeHKanNZNoT6Q0saFWZJxU0dzx5vB2bqwcbrWMT6/j+3IWBlevqi2QJgs7crrqNYkV8V8eg7dR9jGr8LrCSg8TrYZXW6viQK0IUtkxqe04m8AvZItjQhjHsWfpWzdS0dZE9PrYvHdqJj6MJ4cmR2eMoN4++k6hYrRQw62Ny4vTr8CoIG2BsOVGq8G1WVN1rcHHeHguz88fAta05UtneZUIebGaNVvwqKpRPZciX+++HDOnCliMItkFlrPhPRch7BvpYgo6Viz2gAgihogckh9cNwIDAQAB"
