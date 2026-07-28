//
//  RelayAccount.swift
//  RelayCore
//
//  The locally persisted account/device credentials, shared by the app and
//  the Notification Service Extension (the NSE needs the account id + device
//  id to build the crypto engine's local address). Stored as JSON in the
//  App-Group Keychain so both processes read the same record.
//

import Foundation

public struct RelayAccount: Codable, Sendable, Equatable {
    /// Keychain item name (App-Group access group) both processes use.
    public static let keychainName = "relay-account"

    public let accountId: String
    public let deviceId: UInt32
    public let password: String
    public let serverURL: URL
    /// Optional: accounts saved by earlier builds didn't record it.
    public let username: String?

    public init(accountId: String, deviceId: UInt32, password: String, serverURL: URL, username: String?) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.password = password
        self.serverURL = serverURL
        self.username = username
    }
}
