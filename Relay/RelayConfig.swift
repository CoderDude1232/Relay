//
//  RelayConfig.swift
//  Relay
//

import Foundation

enum RelayConfig {
    static let serverURL = URL(string: "https://api.relaymsg.app")!

    /// Sealed-sender trust-root public key (base64 of the 33-byte 0x05‖X form),
    /// used to validate delivery certificates. The relay logs this at startup
    /// (`trustRootPublicBase64`) when `-sealed-sender-trust-key` is set — paste
    /// that value here before enabling sealed-sender send/receive (Stage 1c).
    /// Empty until then; nothing validates against it yet.
    static let sealedSenderTrustRootBase64 = ""

    static var sealedSenderTrustRoot: Data? {
        sealedSenderTrustRootBase64.isEmpty ? nil : Data(base64Encoded: sealedSenderTrustRootBase64)
    }
}
