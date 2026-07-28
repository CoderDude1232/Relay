//
//  RelayCredentials.swift
//  RelayKit
//
//  Device credentials for the relay. HTTP Basic with username
//  "<accountId>.<deviceId>" — same scheme for REST and the WebSocket
//  upgrade, matching server/README.md.
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
