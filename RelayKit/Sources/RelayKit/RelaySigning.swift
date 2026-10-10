//
//  RelaySigning.swift
//  RelayKit
//
//  Relay-Sig v2 request signing (server/README.md, "Authentication"). Every
//  authenticated REST call and the WebSocket upgrade carry a fresh ECDSA P-256
//  signature from the device auth key over:
//
//      "relay-sig-v2" \n METHOD \n REQUEST-URI \n ACCOUNT \n DEVICE \n
//      TIMESTAMP \n NONCE \n hex(SHA-256(body))
//
//  REQUEST-URI is the percent-encoded path plus "?query" if present, exactly
//  as sent.
//

import CryptoKit
import Foundation
import Security

/// Signs the canonical request string with the device's P-256 auth key, which
/// the app owns. Returns a DER ECDSA signature over SHA-256 of `message`, or
/// nil if the key is unavailable.
public protocol RelayRequestSigner: Sendable {
    func signRelayRequest(_ message: Data) -> Data?
    /// Uncompressed P-256 public key (0x04 || X || Y) for the signing key, used
    /// once to register it with the relay. Nil if unknown.
    func relayAuthPublicKey() -> Data?
}

public extension RelayRequestSigner {
    func relayAuthPublicKey() -> Data? { nil }
}

/// A closure-backed signer for targets that can't see the app's
/// `DeviceAuthSigner`, such as the NSE:
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
    /// "?query" if present.
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

    /// Adds Relay-Sig headers to `request`, whose URL, method and body must be
    /// final. Returns false if the signer produced no signature.
    static func sign(_ request: inout URLRequest, credentials: RelayCredentials, signer: any RelayRequestSigner) -> Bool {
        guard let url = request.url else { return false }
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        var nonceBytes = [UInt8](repeating: 0, count: nonceBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
            return false
        }
        let nonce = Data(nonceBytes).base64EncodedString()
        // A caller streaming a large body may supply its digest; otherwise hash the
        // in-memory body (empty if none).
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

/// Runs the Basic-auth bootstrap of a device's auth key at most once per
/// process, so a signed request failing for another reason (clock skew, say)
/// doesn't resend the password each time. Right after sign-up several signed
/// requests race before the key exists; they all await the same attempt.
final class AuthKeyBootstrapLedger: @unchecked Sendable {
    static let shared = AuthKeyBootstrapLedger()
    private let lock = NSLock()
    private var attempts: [String: Task<Void, Never>] = [:]

    /// Starts `bootstrap` for this device if no attempt exists, then waits for
    /// that attempt to finish, whatever its outcome.
    func runOnce(for credentials: RelayCredentials,
                 _ bootstrap: @escaping @Sendable () async -> Void) async {
        let key = "\(credentials.accountId).\(credentials.deviceId)"
        let task = lock.withLock {
            if let existing = attempts[key] { return existing }
            let started = Task { await bootstrap() }
            attempts[key] = started
            return started
        }
        await task.value
    }
}
