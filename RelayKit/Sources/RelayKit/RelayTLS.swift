//
//  RelayTLS.swift
//  RelayKit
//
//  Certificate pinning for the relay connection. The dev relay uses a
//  self-signed certificate (there is no public CA), so instead of the system
//  trust chain we pin the server's public key: a URLSession delegate accepts
//  a TLS connection only when the leaf certificate's SPKI SHA-256 matches a
//  known pin. This defeats a same-network man-in-the-middle even without a CA.
//
//  Pinning the SPKI (not the whole certificate) means the pin stays valid
//  when the cert is re-issued with the SAME key. Regenerate the pin with
//  server/scripts/gen-dev-cert.sh and update `devPins` if the key changes.
//

import CryptoKit
import Foundation
import Security

public enum RelayTLS {
    /// SPKI SHA-256 pins (base64) the client will accept. Currently the dev
    /// relay's self-signed EC P-256 certificate.
    public static let devPins: [String] = [
        "VIcPByBHSod3xIeNOgMo7e4AybcXVYSSLkd4YDmW5cw=",
    ]

    /// A URLSession that pins the relay's public key. Safe to reuse for both
    /// the REST client and the WebSocket. Plain-HTTP connections never raise a
    /// server-trust challenge, so the same session also works untanged in
    /// non-TLS dev setups.
    public static func makeSession(pins: [String] = devPins) -> URLSession {
        let delegate = SPKIPinningDelegate(pins: Set(pins))
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }
}

/// Validates the server's leaf public key against a set of SPKI pins.
final class SPKIPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pins: Set<String>

    init(pins: Set<String>) {
        self.pins = pins
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard !pins.isEmpty, let pin = Self.spkiPin(for: trust), pins.contains(pin) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// The DER SubjectPublicKeyInfo header for an EC P-256 (prime256v1) key.
    /// SecKey gives us the raw point (0x04‖X‖Y); prepending this yields the
    /// same SPKI bytes OpenSSL hashes, so the pins match across both tools.
    private static let p256SPKIHeader: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    private static func spkiPin(for trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        var spki = Data(p256SPKIHeader)
        spki.append(raw)
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }
}
