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
    static let trustRootPub = "BUOKKb9z9A6av7zbLl67qMwzkN61i0dK+WN/1AjoP3gH"
    static let senderCert = "Cs0BCgxpbnRlcm9wLXVzZXIQARkA2MMsuwMAACIhBUJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCKmkKJQgBEiEFAUMwn9eyG74PAKU7CS1KU2H9owxA9xBQ6Fx10RGW0gISQPn6OJrZLJQTZKws3ocCFhhc/xH3COIquPdSH2zl87n9FWDph/Qio4GUsOVhogiCiv+bQioJXt1Unu/9KQlZNwIyJDExMTExMTExLTExMTEtMTExMS0xMTExLTExMTExMTExMTExMRJAjpEEv8YK4VcAFMF+/7rAW9TuqnbLdYYH+WubtabUNR5sHvRSjDhxS6dpOzwn8ww7O7rULZNgcIZ1aW1KVu+WBQ=="
    static let identityKey = "BUJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJC"
    static let uuid = "11111111-1111-1111-1111-111111111111"
    static let username = "interop-user"
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
        // Relay usernames ride in libsignal's sender_e164 field.
        #expect(cert.senderE164 == Self.username)
        #expect(cert.deviceId == 1)
        #expect(cert.expiration == Self.expiresMs)
        #expect(cert.publicKey.serialize() == Data(base64Encoded: Self.identityKey)!)
    }
}
