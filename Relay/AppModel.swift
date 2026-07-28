//
//  AppModel.swift
//  Relay
//
//  Composition root: owns the Keychain/Secure Enclave store, boots the
//  encrypted database, and moves the app between onboarding and messaging.
//

import Foundation
import Observation
import RelayKit
import SecureStorage

@Observable
final class AppModel {
    enum Phase {
        case loading
        case onboarding
        case ready(MessagingService)
        case failed(String)
    }

    static let appGroupId = "group.com.relayapp.Relay"
    private static let accountSecretName = "relay-account"

    private(set) var phase: Phase = .loading
    private let keychain = KeychainSecureStore(
        configuration: KeychainConfiguration(accessGroup: appGroupId)
    )
    /// One certificate-pinned session shared by every relay connection.
    private let session = RelayTLS.makeSession()

    private struct SavedAccount: Codable {
        let accountId: String
        let deviceId: UInt32
        let password: String
        let serverURL: URL
        // Optional: accounts saved by earlier builds didn't record it.
        let username: String?
    }

    func boot() {
        do {
            guard let data = try keychain.loadSecret(for: Self.accountSecretName) else {
                phase = .onboarding
                return
            }
            let saved = try JSONDecoder().decode(SavedAccount.self, from: data)
            let service = try makeService(
                credentials: RelayCredentials(
                    accountId: saved.accountId,
                    deviceId: saved.deviceId,
                    password: saved.password
                ),
                serverURL: saved.serverURL,
                username: saved.username
            )
            service.start()
            phase = .ready(service)
        } catch {
            phase = .failed("Could not unlock local storage: \(error)")
        }
    }

    /// Registers a fresh account, publishes its first keys, and persists
    /// the credentials in the Keychain.
    func register(serverURL: URL, username: String, password: String) async throws {
        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)
        let credentials = try await api.register(username: username, password: password)
        let service = try makeService(credentials: credentials, serverURL: serverURL, username: username)
        try await service.publishInitialKeys()

        let saved = SavedAccount(
            accountId: credentials.accountId,
            deviceId: credentials.deviceId,
            password: password,
            serverURL: serverURL,
            username: username
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        service.start()
        phase = .ready(service)
    }

    /// Signs out of the account: forgets the credentials and deletes all
    /// local message history and session state. Used both by the Settings
    /// button and to recover from credentials the server no longer knows.
    func signOut() {
        if case .ready(let service) = phase {
            service.stop()
        }
        try? keychain.deleteSecret(for: Self.accountSecretName)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: Self.databaseURL(suffix: suffix))
        }
        phase = .onboarding
    }

    /// The database lives in the App Group container so the Notification
    /// Service Extension can share it (push stage).
    private static func databaseURL(suffix: String = "") -> URL {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return container.appendingPathComponent("relay.db\(suffix)")
    }

    private func makeService(credentials: RelayCredentials, serverURL: URL, username: String?) throws -> MessagingService {
        let storage = try SecureStore(
            path: Self.databaseURL().path,
            keychain: keychain
        )
        return try MessagingService(
            credentials: credentials,
            serverURL: serverURL,
            username: username,
            storage: storage,
            session: session
        )
    }
}
