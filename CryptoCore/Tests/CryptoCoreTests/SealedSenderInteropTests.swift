//
//  SealedSenderInteropTests.swift
//  CryptoCoreTests
//
//  Cross-language proof gate for the sealed-sender "A1" approach: a certificate
//  chain minted by the pure-Go relay (server/internal/sealedsender) must
//  validate natively in libsignal. If this passes, Go-minted sender certificates
//  are byte-and-signature compatible with the vendored client.
//
//  Regenerate the vector with:
//    PRINT_INTEROP_VECTOR=1 go test ./internal/sealedsender/ \
//      -run TestPrintInteropVector -v
//

import Foundation
import LibSignalClient
import Testing

struct SealedSenderInteropTests {
    // Fixed vector minted by the Go relay.
    static let trustRootPub = "BWdgajRyxQ/xn3+qMKS/zM5Kiz/RakS2WQ6o2RuaqKJT"
    static let senderCert = "Cr8BEAEZANjDLLsDAAAiIQVCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQippCiUIARIhBbQqGrMCOEwcpVwMDJKvNiiLWD1CaRiQP7+ePMD3828LEkB7Xe1jQjub929mCE02ON8Zu8qQpf0LtRXT6pRPsdX4wKS8K2X/XMa8vaU96VvtYykC+jCIVr8nTSVxJEzFoN8FMiQxMTExMTExMS0xMTExLTExMTEtMTExMS0xMTExMTExMTExMTESQMzYEPN9Qnn0Eh5jM2oTDPlKuvhCmN6U+FYcDpKyEWHRkVg+XmWYMEp62i5JVZODsf9NozIh468EmDgM88ptmow="
    static let identityKey = "BUJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJC"
    static let uuid = "11111111-1111-1111-1111-111111111111"
    static let expiresMs: UInt64 = 4_102_444_800_000

    @Test func goMintedCertificateValidatesInLibsignal() throws {
        let trustRoot = try PublicKey(Data(base64Encoded: Self.trustRootPub)!)
        let cert = try SenderCertificate(Data(base64Encoded: Self.senderCert)!)

        // The signature chain (sender cert ← server cert ← trust root) verifies.
        #expect(cert.validate(trustRoot: trustRoot, time: 1_800_000_000_000))
        // Expiry is enforced.
        #expect(!cert.validate(trustRoot: trustRoot, time: Self.expiresMs + 1))
        // A different trust root must reject it.
        let otherRoot = PrivateKey.generate().publicKey
        #expect(!cert.validate(trustRoot: otherRoot, time: 1_800_000_000_000))

        // Fields decode to exactly what Go minted.
        #expect(cert.senderUuid == Self.uuid)
        #expect(cert.deviceId == 1)
        #expect(cert.expiration == Self.expiresMs)
        #expect(cert.publicKey.serialize() == Data(base64Encoded: Self.identityKey)!)
    }
}
