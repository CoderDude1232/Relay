//
//  SupporterCredential.swift
//  Relay
//
//  Client half of the Relay Supporter anonymous credentials (a ristretto255
//  VOPRF with a DLEQ proof). Blind a random nonce for a period, have the relay
//  evaluate it against an App Store purchase, check the proof against that
//  period's public key, unblind, and later redeem (period, nonce, N) on the
//  account. Must match server/internal/supporter byte-for-byte: domain tags,
//  hashes and encodings (see the server README, "Relay Supporter").
//

import Clibsodium
import CryptoKit
import Foundation

nonisolated enum SupporterCredential {
    private static let h2gDomain = Data("Relay-Supporter-v1-h2g".utf8)
    private static let dleqDomain = Data("Relay-Supporter-v1-dleq".utf8)
    static let nonceLength = 32

    private static let initOnce: Int32 = sodium_init()

    /// A request for one period, plus what's needed to finish it.
    struct Pending: Codable, Sendable {
        let period: String
        let nonce: Data
        let blind: Data      // r
        let blinded: Data    // B = r·H(period, nonce)
    }

    /// A finished credential, ready to redeem in its period.
    struct Token: Codable, Sendable, Equatable {
        let period: String
        let nonce: Data
        let point: Data      // N = k_p·H(period, nonce)
    }

    /// H(period, nonce).
    static func hashToGroup(period: String, nonce: Data) -> [UInt8] {
        var hasher = SHA512()
        hasher.update(data: h2gDomain)
        hasher.update(data: Data(period.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: nonce)
        let digest = [UInt8](hasher.finalize())
        var point = [UInt8](repeating: 0, count: 32)
        _ = crypto_core_ristretto255_from_hash(&point, digest)
        return point
    }

    static func blind(period: String) -> Pending? {
        var nonce = [UInt8](repeating: 0, count: nonceLength)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceLength, &nonce) == errSecSuccess else { return nil }
        _ = initOnce
        var r = [UInt8](repeating: 0, count: 32)
        crypto_core_ristretto255_scalar_random(&r)
        return blind(period: period, nonce: Data(nonce), r: r)
    }

    /// Deterministic for the interop check.
    static func blind(period: String, nonce: Data, r: [UInt8]) -> Pending? {
        _ = initOnce
        let t = hashToGroup(period: period, nonce: nonce)
        var b = [UInt8](repeating: 0, count: 32)
        guard crypto_scalarmult_ristretto255(&b, r, t) == 0 else { return nil }
        return Pending(period: period, nonce: nonce, blind: Data(r), blinded: Data(b))
    }

    /// Checks the relay's proof that E = k_p·B for the published Y_p, then
    /// unblinds. nil if anything doesn't verify.
    static func finish(_ pending: Pending, evaluated: Data, proof: Data, publicKey: Data) -> Token? {
        _ = initOnce
        guard evaluated.count == 32, proof.count == 64, publicKey.count == 32,
              crypto_core_ristretto255_is_valid_point([UInt8](evaluated)) == 1,
              crypto_core_ristretto255_is_valid_point([UInt8](publicKey)) == 1
        else { return nil }
        let y = [UInt8](publicKey), b = [UInt8](pending.blinded), e = [UInt8](evaluated)
        let c = [UInt8](proof.prefix(32)), s = [UInt8](proof.suffix(32))

        // A1 = s·G + c·Y, A2 = s·B + c·E
        var sG = [UInt8](repeating: 0, count: 32), cY = sG, sB = sG, cE = sG, a1 = sG, a2 = sG
        guard crypto_scalarmult_ristretto255_base(&sG, s) == 0,
              crypto_scalarmult_ristretto255(&cY, c, y) == 0,
              crypto_scalarmult_ristretto255(&sB, s, b) == 0,
              crypto_scalarmult_ristretto255(&cE, c, e) == 0,
              crypto_core_ristretto255_add(&a1, sG, cY) == 0,
              crypto_core_ristretto255_add(&a2, sB, cE) == 0
        else { return nil }
        var hasher = SHA512()
        hasher.update(data: dleqDomain)
        for p in [y, b, e, a1, a2] { hasher.update(data: Data(p)) }
        var expected = [UInt8](repeating: 0, count: 32)
        crypto_core_ristretto255_scalar_reduce(&expected, [UInt8](hasher.finalize()))
        guard sodium_memcmp(expected, c, 32) == 0 else { return nil }

        return unblind(pending, evaluated: evaluated)
    }

    /// N = r⁻¹·E (no proof check; finish() is the real path).
    static func unblind(_ pending: Pending, evaluated: Data) -> Token? {
        _ = initOnce
        var rInv = [UInt8](repeating: 0, count: 32)
        var n = [UInt8](repeating: 0, count: 32)
        guard crypto_core_ristretto255_scalar_invert(&rInv, [UInt8](pending.blind)) == 0,
              crypto_scalarmult_ristretto255(&n, rInv, [UInt8](evaluated)) == 0
        else { return nil }
        return Token(period: pending.period, nonce: pending.nonce, point: Data(n))
    }

    // MARK: Periods (must match supporter.PeriodAt / ParsePeriod)

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
    private static let monthFormat = formatter("yyyy-MM")
    private static let hourFormat = formatter("yyyy-MM-dd'T'HH")

    static func period(at date: Date, sandbox: Bool) -> String {
        sandbox ? "h" + hourFormat.string(from: date) : "m" + monthFormat.string(from: date)
    }

    /// When a period ends.
    static func end(of period: String) -> Date? {
        guard let kind = period.first else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        switch kind {
        case "m": return monthFormat.date(from: String(period.dropFirst())).flatMap { utc.date(byAdding: .month, value: 1, to: $0) }
        case "h": return hourFormat.date(from: String(period.dropFirst())).map { $0.addingTimeInterval(3600) }
        default: return nil
        }
    }

    /// The periods a purchase covers from now until it expires (at most 2).
    static func periods(from now: Date, until expires: Date, sandbox: Bool) -> [String] {
        var out: [String] = []
        var t = now
        while t < expires, out.count < 2 {
            let p = period(at: t, sandbox: sandbox)
            out.append(p)
            guard let end = end(of: p) else { break }
            t = end
        }
        return out
    }
}
