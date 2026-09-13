//
//  RelayConfig.swift
//  Relay
//

import Foundation
import RelayKit

enum RelayConfig {
    static let serverURL = URL(string: "https://api.relaymsg.app")!

    /// Sealed-sender trust-root public key, used to validate delivery
    /// certificates. Defined once in RelayKit (`RelaySealedSender`) so the NSE
    /// shares it; re-exported here for app call sites.
    static var sealedSenderTrustRoot: Data? { RelaySealedSender.trustRoot }
}
