//
//  RelayAccount.swift
//  RelayCore
//
//  The persisted account and device credentials, stored as JSON in the
//  App Group Keychain so the app and the NSE read the same record.
//

import Foundation

public struct RelayAccount: Codable, Sendable, Equatable {
    /// Keychain item name, in the App Group access group.
    public static let keychainName = "relay-account"

    public let accountId: String
    public let deviceId: UInt32
    public let password: String
    public let serverURL: URL
    /// Nil for accounts saved before the username was recorded.
    public let username: String?

    public init(accountId: String, deviceId: UInt32, password: String, serverURL: URL, username: String?) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.password = password
        self.serverURL = serverURL
        self.username = username
    }
}
