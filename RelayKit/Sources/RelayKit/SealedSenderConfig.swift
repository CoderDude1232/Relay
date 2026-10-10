//
//  SealedSenderConfig.swift
//  RelayKit
//
//  The sealed-sender trust-root public key, built into the client. Lives in
//  RelayKit so the app and the NSE validate sender certificates against the
//  same root.
//
//  Base64 of the 33-byte serialized libsignal public key the relay logs at
//  startup (`-sealed-sender-trust-key`). Rotating the server's trust root
//  means updating this and shipping a new build.
//

import Foundation

public enum RelaySealedSender {
    public static let trustRootBase64 = "BUMHKPU9XPCdwHCVF8Eea8RxKLhbxq6BhpvYgBTo4IFU"

    /// The trust root as raw key bytes, or nil when the string is empty.
    public static var trustRoot: Data? {
        trustRootBase64.isEmpty ? nil : Data(base64Encoded: trustRootBase64)
    }
}
