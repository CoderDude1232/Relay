//
//  RelayTLS.swift
//  RelayKit
//
//  Certificate pinning for the relay connection.
//
//  Production (api.relaymsg.app): uses a Let's Encrypt certificate trusted by
//  iOS natively — no pin needed, system trust chain handles it. Pass an empty
//  pins array (the default) to get a plain-trust session.
//
//  Dev relay (self-signed): pin the leaf SPKI so a LAN attacker can't MITM
//  without the private key. Pass `devPins` explicitly when connecting to the
//  dev server. Regenerate with server/scripts/gen-dev-cert.sh if the key changes.
//
//  Pinning the SPKI (not the whole cert) survives re-issuance with the same key.
//

import CryptoKit
import Foundation
import Security

public enum RelayTLS {
    /// SPKI SHA-256 pins (base64) for the dev self-signed EC P-256 certificate.
    /// Not used for production (Let's Encrypt is trusted by system trust chain).
    public static let devPins: [String] = [
        "VIcPByBHSod3xIeNOgMo7e4AybcXVYSSLkd4YDmW5cw=",
    ]

    /// A URLSession configured for the relay.
    /// - `pins` empty (default): system trust — correct for production Let's Encrypt certs.
    /// - `pins` non-empty: SPKI-pinned — use for dev self-signed certs.
    public static func makeSession(pins: [String] = []) -> URLSession {
        if pins.isEmpty {
            return URLSession(configuration: .default)
        }
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
