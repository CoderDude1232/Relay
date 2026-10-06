//
//  RelaySigning.swift
//  RelayKit
//
//  Relay-Sig v2 request signing (see server/README.md "Authentication").
//  Every authenticated REST call and the WebSocket upgrade carry a fresh
//  ECDSA-P256 signature from the device auth key, over:
//
//      "relay-sig-v2" \n METHOD \n REQUEST-URI \n ACCOUNT \n DEVICE \n
//      TIMESTAMP \n NONCE \n hex(SHA-256(body))
//
//  REQUEST-URI is the percent-encoded path plus "?query" when present, exactly
//  as it goes on the wire. Nothing replayable transits the wire.
//

import CryptoKit
import Foundation
import Security

/// Signs the per-request canonical string with the device's P256 authorization
/// key (the same key used for device mutations). Injected by the app, which
/// owns the Keychain/Secure-Enclave key. Returns the ECDSA-P256 (ASN.1 DER)
/// signature over SHA-256 of `message`, or nil if the key is unavailable.
public protocol RelayRequestSigner: Sendable {
    func signRelayRequest(_ message: Data) -> Data?
    /// The uncompressed P-256 public key (0x04‖X‖Y) matching the signing key.
    /// Used once, to bootstrap a device that has not registered its auth key
    /// with the relay yet. Return nil if unknown.
    func relayAuthPublicKey() -> Data?
}

public extension RelayRequestSigner {
    func relayAuthPublicKey() -> Data? { nil }
}

/// A closure-backed signer — lets targets that can't see the app's
/// `DeviceAuthSigner` (e.g. the Notification Service Extension) sign with the
/// shared Keychain key:
///
///     RelayClosureSigner(
///         sign: { try? keychain.signDeviceAuthorizationPayload($0) },
///         publicKey: { try? keychain.deviceAuthorizationPublicKey() })
public struct RelayClosureSigner: RelayRequestSigner {
    private let signClosure: @Sendable (Data) -> Data?
    private let publicKeyClosure: @Sendable () -> Data?

    public init(sign: @escaping @Sendable (Data) -> Data?,
                publicKey: @escaping @Sendable () -> Data? = { nil }) {
        signClosure = sign
        publicKeyClosure = publicKey
    }

    public func signRelayRequest(_ message: Data) -> Data? { signClosure(message) }
    public func relayAuthPublicKey() -> Data? { publicKeyClosure() }
}

enum RelaySignature {
    static let version = "relay-sig-v2"
    static let nonceBytes = 32

    /// The request target as the server sees it: percent-encoded path plus
    /// "?query" when the URL has one.
    static func requestURI(_ url: URL) -> String {
        var uri = url.path(percentEncoded: true)
        if uri.isEmpty { uri = "/" }
        if let query = url.query(percentEncoded: true) {
            uri += "?" + query
        }
        return uri
    }

    static func canonical(method: String, requestURI: String, accountId: String, deviceId: UInt32,
                          timestamp: String, nonce: String, bodySHA256Hex: String) -> String {
        [version, method, requestURI, accountId, String(deviceId), timestamp, nonce, bodySHA256Hex]
            .joined(separator: "\n")
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Adds Relay-Sig headers to `request` (its URL, method and httpBody must be
    /// final). Returns false if the signer could not produce a signature.
    static func sign(_ request: inout URLRequest, credentials: RelayCredentials, signer: any RelayRequestSigner) -> Bool {
        guard let url = request.url else { return false }
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        var nonceBytes = [UInt8](repeating: 0, count: nonceBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
            return false
        }
        let nonce = Data(nonceBytes).base64EncodedString()
        // A caller streaming a large body may pre-declare its digest; otherwise
        // hash the in-memory body (empty when there is none).
        let bodyHex = request.value(forHTTPHeaderField: "X-Relay-Content-SHA256")?.lowercased()
            ?? sha256Hex(request.httpBody ?? Data())
        let message = canonical(
            method: request.httpMethod ?? "GET",
            requestURI: requestURI(url),
            accountId: credentials.accountId,
            deviceId: credentials.deviceId,
            timestamp: timestamp,
            nonce: nonce,
            bodySHA256Hex: bodyHex
        )
        guard let sig = signer.signRelayRequest(Data(message.utf8)) else { return false }
        request.setValue("Relay-Sig \(credentials.accountId).\(credentials.deviceId):\(sig.base64EncodedString())",
                         forHTTPHeaderField: "Authorization")
        request.setValue(timestamp, forHTTPHeaderField: "X-Relay-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Relay-Nonce")
        return true
    }
}

/// Remembers, per process, which devices already tried the automatic Basic
/// bootstrap of their auth key, so a signed request that fails for another
/// reason (e.g. clock skew) doesn't resend the device password every time.
final class AuthKeyBootstrapLedger: @unchecked Sendable {
    static let shared = AuthKeyBootstrapLedger()
    private let lock = NSLock()
    private var attempted: Set<String> = []

    /// True the first time it is asked about a given device.
    func firstAttempt(for credentials: RelayCredentials) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return attempted.insert("\(credentials.accountId).\(credentials.deviceId)").inserted
    }
}
