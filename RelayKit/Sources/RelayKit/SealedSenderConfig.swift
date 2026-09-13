//
//  SealedSenderConfig.swift
//  RelayKit
//
//  The sealed-sender trust-root public key, baked into the client. Kept here
//  (rather than the app target) so BOTH the app and the Notification Service
//  Extension can validate sender certificates against the same root — the NSE
//  decrypts sealed pushes off the WebSocket path.
//
//  This is the base64 of the 33-byte serialized libsignal public key logged by
//  the relay at startup (`-sealed-sender-trust-key`). If you rotate the server's
//  trust root, update this string and ship a new build.
//

import Foundation

public enum RelaySealedSender {
    public static let trustRootBase64 = "BUMHKPU9XPCdwHCVF8Eea8RxKLhbxq6BhpvYgBTo4IFU"

    /// The trust root as raw key bytes, or nil when unconfigured (empty string).
    public static var trustRoot: Data? {
        trustRootBase64.isEmpty ? nil : Data(base64Encoded: trustRootBase64)
    }
}
