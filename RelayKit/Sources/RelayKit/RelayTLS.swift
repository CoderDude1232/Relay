//
//  RelayTLS.swift
//  RelayKit
//
//  TLS configuration for the relay connection.
//
//  Production uses a Let's Encrypt certificate and system trust; pass no pins.
//  The self-signed dev relay is pinned by leaf SPKI (`devPins`), which survives
//  re-issuance with the same key. Regenerate with server/scripts/gen-dev-cert.sh
//  if the key changes.
//

import CryptoKit
import Foundation
import Security

public enum RelayTLS {
    /// Base64 SPKI SHA-256 pins for the dev self-signed P-256 certificate.
    public static let devPins: [String] = [
        "VIcPByBHSod3xIeNOgMo7e4AybcXVYSSLkd4YDmW5cw=",
    ]

    /// Session for authenticated traffic. Empty `pins` uses system trust;
    /// otherwise the leaf SPKI is pinned. Ephemeral, so no cache, cookies or
    /// credentials reach disk.
    public static func makeSession(pins: [String] = []) -> URLSession {
        makeEphemeralSession(pins: pins)
    }

    /// A separate ephemeral session for anonymous requests (sealed sends, call
    /// rings, attachments, invite claims, sign-up). It shares no connection,
    /// cookie or cache with the authenticated session, so the relay can't link
    /// an anonymous request to the logged-in connection. Create one per process.
    public static func makeAnonymousSession(pins: [String] = []) -> URLSession {
        makeEphemeralSession(pins: pins)
    }

    /// Process-wide authenticated session (system trust). Rebuilt when the proxy
    /// setting changes.
    public static var sharedSession: URLSession { cached(\.authenticated, make: { makeSession() }) }

    /// Process-wide anonymous session (system trust).
    public static var sharedAnonymousSession: URLSession { cached(\.anonymous, make: { makeAnonymousSession() }) }

    private struct Cache {
        var proxy: RelayProxy.Address?
        var authenticated: URLSession?
        var anonymous: URLSession?
    }
    nonisolated(unsafe) private static var cache = Cache()
    private static let cacheLock = NSLock()

    private static func cached(_ slot: WritableKeyPath<Cache, URLSession?>, make: () -> URLSession) -> URLSession {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let proxy = RelayProxy.active
        if proxy != cache.proxy { cache = Cache(proxy: proxy) }
        if let session = cache[keyPath: slot] { return session }
        let session = make()
        cache[keyPath: slot] = session
        return session
    }

    static func ephemeralConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        RelayProxy.apply(to: config)
        return config
    }

    private static func makeEphemeralSession(pins: [String]) -> URLSession {
        let config = ephemeralConfiguration()
        if pins.isEmpty {
            return URLSession(configuration: config)
        }
        let delegate = SPKIPinningDelegate(pins: Set(pins))
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}

/// Checks the server's leaf public key against a set of SPKI pins.
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

    /// DER SubjectPublicKeyInfo header for a P-256 key. SecKey returns the raw
    /// point (0x04 || X || Y); prefixing this gives the bytes OpenSSL hashes.
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
