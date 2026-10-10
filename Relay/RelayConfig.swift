//
//  RelayConfig.swift
//  Relay
//

import Foundation
import RelayKit

enum RelayConfig {
    static let serverURL = URL(string: "https://api.relaymsg.app")!

    /// Sealed-sender trust root for validating delivery certificates. Defined in
    /// RelayKit (`RelaySealedSender`) so the NSE shares it.
    static var sealedSenderTrustRoot: Data? { RelaySealedSender.trustRoot }
}
