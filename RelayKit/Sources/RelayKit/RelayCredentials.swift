//
//  RelayCredentials.swift
//  RelayKit
//
//  Device credentials for the relay. The password is a bootstrap secret, sent
//  over HTTP Basic ("<accountId>.<deviceId>") only to register the device's
//  first auth key. Everything else is Relay-Sig signed; see RelaySigning.swift.
//

import Foundation

public struct RelayCredentials: Sendable, Equatable {
    public let accountId: String
    public let deviceId: UInt32
    public let password: String

    public init(accountId: String, deviceId: UInt32, password: String) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.password = password
    }

    var authorizationHeader: String {
        let raw = Data("\(accountId).\(deviceId):\(password)".utf8)
        return "Basic \(raw.base64EncodedString())"
    }
}
