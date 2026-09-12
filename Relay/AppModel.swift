//
//  AppModel.swift
//  Relay
//
//  Composition root: owns the Keychain/Secure Enclave store, boots the
//  encrypted database, and moves the app between onboarding and messaging.
//

import CryptoKit
import Foundation
import Observation
import RelayCore
import RelayKit
import SecureStorage
import Security
import UIKit

// Keychain APIs are thread-safe; this lets us capture the store in @Sendable closures.
extension KeychainSecureStore: @retroactive @unchecked Sendable {}

@Observable
final class AppModel {
    enum Phase {
        case loading
        case onboarding
        case ready(MessagingService)
        case failed(String)
    }

    static let appGroupId = RelayStore.appGroupId
    private static let accountSecretName = "relay-account"

    private(set) var phase: Phase = .loading
    /// Set by onOpenURL when the user opens a relay://add/<username> link.
    var pendingDeepLinkUsername: String?
    /// Set by onOpenURL when the user opens a relay://join/<token> invite link.
    var pendingGroupInviteToken: String?
    /// Set by AppDelegate's UNUserNotificationCenterDelegate when the user taps a message banner.
    var pendingNotificationConversationId: String?

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }
    private let keychain = KeychainSecureStore(
        configuration: KeychainConfiguration(accessGroup: appGroupId)
    )
    /// One certificate-pinned session shared by every relay connection.
    private let session = RelayTLS.makeSession()
    /// Latest APNs device token (hex), uploaded once a session exists.
    private var apnsTokenHex: String?
    /// Background task assertion that keeps the WebSocket alive after backgrounding.
    private var keepAliveBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Fires after 25s in the background to close the socket and let APNs take over.
    private var backgroundDisconnectTask: Task<Void, Never>?

    private struct SavedAccount: Codable {
        let accountId: String
        let deviceId: UInt32
        let password: String
        let serverURL: URL
        let username: String?
        let supabaseUserId: String?  // optional: older saves didn't record it
    }

    func boot() async {
        do {
            guard let data = try keychain.loadSecret(for: Self.accountSecretName) else {
                phase = .onboarding
                return
            }
            let saved = try JSONDecoder().decode(SavedAccount.self, from: data)
            let service = try await makeService(
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
            uploadPushTokenIfReady()
            publishDeviceAuthorizationKeyIfReady()
        } catch {
            phase = .failed("Could not unlock local storage: \(error)")
        }
    }

    /// Returns true if the keychain already holds relay credentials for this Supabase user ID.
    /// Used by onboarding to decide whether to show the setup screen after OAuth.
    func hasExistingRelayAccount(forUserId userId: String) -> Bool {
        guard let data = try? keychain.loadSecret(for: Self.accountSecretName),
              let saved = try? JSONDecoder().decode(SavedAccount.self, from: data)
        else { return false }
        return saved.supabaseUserId == userId
    }

    /// Keeps the WebSocket alive for ~25s after backgrounding so quick app
    /// switches reconnect instantly. If the delay elapses the socket closes
    /// cleanly, the relay marks the device offline, and APNs takes over for
    /// future messages. The NSE decrypts those pushes as before.
    func enterBackground() {
        backgroundDisconnectTask?.cancel()

        // Expiry handler: iOS is reclaiming background time — stop immediately.
        // The expiry handler runs on the main thread, same as this actor.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "relay-keep-alive") { [weak self] in
            guard let self else { return }
            if case .ready(let service) = self.phase { service.stop() }
            let id = self.keepAliveBackgroundTask
            self.keepAliveBackgroundTask = .invalid
            UIApplication.shared.endBackgroundTask(id)
        }
        keepAliveBackgroundTask = bgTask

        backgroundDisconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if case .ready(let service) = self.phase { service.stop() }
                let id = self.keepAliveBackgroundTask
                self.keepAliveBackgroundTask = .invalid
                if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
            }
        }
    }

    func enterForeground() {
        // Cancel the pending disconnect — the socket may still be alive.
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        if keepAliveBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(keepAliveBackgroundTask)
            keepAliveBackgroundTask = .invalid
        }

        if case .ready(let service) = phase {
            service.start()  // no-op if socket is already running
            Task { await service.ensureNoteToSelf() }
            Task {
                if let convId = await service.processPendingShare() {
                    pendingNotificationConversationId = convId
                }
            }
        }
    }

    /// Called by the BGAppRefreshTask to drain any Siri-queued pending shares
    /// when the foreground socket has already closed. Reconnects briefly, sends,
    /// then closes again so the relay marks the device offline as expected.
    func handleBackgroundRefresh() async {
        guard case .ready(let service) = phase else { return }
        let wasDisconnected = service.connectionState == .disconnected
        if wasDisconnected { service.start() }

        // Poll until connected or 10s elapsed.
        for _ in 0..<20 {
            if service.connectionState == .connected { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        if service.connectionState == .connected {
            _ = await service.processPendingShare()
        }

        if wasDisconnected { service.stop() }
    }

    /// Points the existing account at a new relay URL (e.g. after the Mac's
    /// LAN IP changed) and reconnects — without wiping local data. Returns an
    /// error message on failure, nil on success.
    @discardableResult
    func updateServerURL(_ url: URL) async -> String? {
        guard case .ready(let old) = phase,
              let data = try? keychain.loadSecret(for: Self.accountSecretName),
              let saved = try? JSONDecoder().decode(SavedAccount.self, from: data)
        else { return "Not signed in." }
        old.stop()
        let updated = SavedAccount(
            accountId: saved.accountId, deviceId: saved.deviceId,
            password: saved.password, serverURL: url,
            username: saved.username, supabaseUserId: saved.supabaseUserId
        )
        do {
            try keychain.storeSecret(JSONEncoder().encode(updated), for: Self.accountSecretName)
            let service = try await makeService(
                credentials: RelayCredentials(accountId: saved.accountId, deviceId: saved.deviceId, password: saved.password),
                serverURL: url, username: saved.username
            )
            service.start()
            phase = .ready(service)
            uploadPushTokenIfReady()
            publishDeviceAuthorizationKeyIfReady()
            return nil
        } catch {
            return "Couldn't switch server: \(error.localizedDescription)"
        }
    }

    /// Records the APNs device token and uploads it if a session is ready.
    /// The token can arrive before or after onboarding, so we stash it.
    func setAPNSDeviceToken(_ data: Data) {
        apnsTokenHex = data.map { String(format: "%02x", $0) }.joined()
        uploadPushTokenIfReady()
    }

    private func uploadPushTokenIfReady() {
        guard case .ready(let service) = phase, let token = apnsTokenHex else { return }
        Task { await service.uploadPushToken(token) }
    }

    private func publishDeviceAuthorizationKeyIfReady() {
        guard case .ready(let service) = phase else { return }
        let keychain = self.keychain
        Task {
            do {
                let publicKey = try keychain.deviceAuthorizationPublicKey()
                try await service.apiClient.setDeviceAuthorizationKey(publicKey)
            } catch {
                // Stage 3B will require this key for signed device-list changes.
            }
        }
    }

    /// Supabase-backed registration: uses the Supabase user ID as relay username.
    /// If credentials already exist in the Keychain for this Supabase user they
    /// are reused (handles reinstall / new app launch). Otherwise a fresh relay
    /// account is registered with a cryptographically-random password.
    func registerWithSupabase(serverURL: URL, email: String, supabaseUserId: String, username: String, displayName: String) async throws {
        let password = Self.generateRandomPassword()
        // Resume if this device already has credentials for this Supabase user.
        if let data = try? keychain.loadSecret(for: Self.accountSecretName),
           let saved = try? JSONDecoder().decode(SavedAccount.self, from: data),
           saved.supabaseUserId == supabaseUserId
             || saved.username == username
             || saved.username == email {
            if case .ready = phase { return }
            do {
                // If the server URL changed (e.g. after a redeploy), persist the
                // new URL so subsequent cold boots use the correct server.
                if saved.serverURL != serverURL {
                    let updated = SavedAccount(
                        accountId: saved.accountId, deviceId: saved.deviceId,
                        password: saved.password, serverURL: serverURL,
                        username: saved.username, supabaseUserId: saved.supabaseUserId
                    )
                    try? keychain.storeSecret(JSONEncoder().encode(updated), for: Self.accountSecretName)
                }
                let service = try await makeService(
                    credentials: RelayCredentials(accountId: saved.accountId, deviceId: saved.deviceId, password: saved.password),
                    serverURL: serverURL, username: saved.username
                )
                service.start()
                phase = .ready(service)
                uploadPushTokenIfReady()
                publishDeviceAuthorizationKeyIfReady()
            } catch {
                throw SetupError(step: "Restore saved session", underlying: error)
            }
            return
        }
        do {
            try await register(serverURL: serverURL, username: username, displayName: displayName, password: password, supabaseUserId: supabaseUserId)
        } catch let e as SetupError {
            throw e
        } catch {
            throw SetupError(step: "Relay registration", underlying: error)
        }
    }

    /// Changes the relay username for the current account and updates the Keychain.
    func changeUsername(_ newUsername: String) async throws {
        guard case .ready(let service) = phase else { return }
        do {
            try await service.apiClient.updateUsername(newUsername)
        } catch RelayAPIError.http(409, _) {
            struct TakenError: LocalizedError {
                let name: String
                var errorDescription: String? { "@\(name) is already taken." }
            }
            throw TakenError(name: newUsername)
        }
        // Persist the new username across restarts.
        if let data = try? keychain.loadSecret(for: Self.accountSecretName),
           let saved = try? JSONDecoder().decode(SavedAccount.self, from: data) {
            let updated = SavedAccount(
                accountId: saved.accountId, deviceId: saved.deviceId,
                password: saved.password, serverURL: saved.serverURL,
                username: newUsername, supabaseUserId: saved.supabaseUserId
            )
            try? keychain.storeSecret(JSONEncoder().encode(updated), for: Self.accountSecretName)
        }
        service.username = newUsername
    }

    /// Returns true if no relay account exists with this username yet.
    func checkUsernameAvailable(_ username: String) async -> Bool {
        let api = RelayAPIClient(baseURL: RelayConfig.serverURL, credentials: nil, session: session)
        do {
            _ = try await api.lookupAccount(username: username)
            return false  // 200 = exists
        } catch RelayAPIError.http(let status, _) where status == 404 {
            return true   // not found = available
        } catch {
            return true   // network trouble — let registration gate it
        }
    }

    /// 32 cryptographically-random bytes, hex-encoded (256-bit entropy).
    /// Called once per new registration; stored in Keychain immediately after.
    private static func generateRandomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Registers a fresh account, publishes its first keys, and persists
    /// the credentials in the Keychain.
    func register(serverURL: URL, username: String, displayName: String, password: String, supabaseUserId: String? = nil) async throws {
        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)

        let credentials: RelayCredentials
        do {
            credentials = try await api.register(username: username, password: password)
        } catch {
            throw SetupError(step: "Create relay account (\(serverURL.host ?? serverURL.absoluteString))", underlying: error)
        }

        let service: MessagingService
        do {
            service = try await makeService(credentials: credentials, serverURL: serverURL, username: username)
        } catch {
            throw SetupError(step: "Open local storage", underlying: error)
        }
        service.setMyDisplayName(displayName)

        let saved = SavedAccount(
            accountId: credentials.accountId,
            deviceId: credentials.deviceId,
            password: password,
            serverURL: serverURL,
            username: username,
            supabaseUserId: supabaseUserId
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        service.start()
        phase = .ready(service)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        // Publish initial prekeys in the background so the UI is responsive
        // immediately after registration. Key publication is retried automatically
        // by PreKeyMaintainer whenever the socket connects.
        Task {
            try? await service.publishInitialKeys()
        }
    }

    /// Links this device by claiming a short-lived token from a scanned QR code.
    func bootAsLinkedDevice(payload: LinkPayload) async throws {
        let api = RelayAPIClient(baseURL: payload.serverURL, credentials: nil, session: session)
        let claim: DeviceLinkClaim
        do {
            claim = try await api.claimDeviceLink(
                linkToken: payload.linkToken,
                verificationCode: payload.verificationCode
            )
        } catch {
            throw SetupError(step: "Claim device link", underlying: error)
        }
        let credentials = RelayCredentials(
            accountId: claim.accountId,
            deviceId: claim.deviceId,
            password: claim.password
        )
        let service: MessagingService
        do {
            service = try await makeService(credentials: credentials, serverURL: payload.serverURL, username: claim.username ?? payload.username)
        } catch {
            throw SetupError(step: "Open local storage", underlying: error)
        }
        let saved = SavedAccount(
            accountId: credentials.accountId,
            deviceId: credentials.deviceId,
            password: claim.password,
            serverURL: payload.serverURL,
            username: claim.username ?? payload.username,
            supabaseUserId: nil
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        if !payload.peers.isEmpty {
            service.importConversationStubs(payload.peers)
        }
        if let historyId = payload.historyAttachmentId,
           let historyKey = payload.historyKey,
           let historyDigest = payload.historyDigest {
            await service.importHistoryBlob(attachmentId: historyId, key: historyKey, digest: historyDigest)
        }
        service.start()
        phase = .ready(service)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        Task { try? await service.publishInitialKeys() }
    }

    /// Signs out of the account: forgets the credentials and deletes all
    /// local message history and session state. Used both by the Settings
    /// button and to recover from credentials the server no longer knows.
    func signOut() {
        if case .ready(let service) = phase {
            service.stop()
        }
        Task { await SupabaseAuth.shared.signOut() }
        try? keychain.deleteSecret(for: Self.accountSecretName)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: Self.databaseURL(suffix: suffix))
        }
        // Wipe App Group share state so a fresh account doesn't inherit the old
        // account's conversations, avatars, or badge count in the share sheet,
        // widgets, and Siri suggestions.
        ShareBridge.clearAll()
        phase = .onboarding
    }

    /// Clears only the relay credentials and local database (not the Supabase
    /// session) so the user can re-register after a relay server reset without
    /// re-entering their Supabase password. The onboarding flow will use the
    /// stored Supabase session to re-register with a fresh relay account.
    func signOutRelayOnly() {
        if case .ready(let service) = phase {
            service.stop()
        }
        try? keychain.deleteSecret(for: Self.accountSecretName)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: Self.databaseURL(suffix: suffix))
        }
        ShareBridge.clearAll()
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

    // MARK: - Errors

    struct SetupError: LocalizedError {
        let step: String
        let underlying: Error
        var errorDescription: String? {
            "\(step): \(Self.describe(underlying))"
        }

        private static func describe(_ error: Error) -> String {
            if let urlErr = error as? URLError {
                switch urlErr.code {
                case .notConnectedToInternet:   return "No internet connection."
                case .cannotConnectToHost:      return "Cannot connect to server. Is it reachable?"
                case .timedOut:                 return "Connection timed out."
                case .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot,
                     .serverCertificateNotYetValid,
                     .serverCertificateHasBadDate:
                    return "TLS certificate error — the server certificate is not trusted."
                default:
                    return urlErr.localizedDescription
                }
            }
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func makeService(credentials: RelayCredentials, serverURL: URL, username: String?) async throws -> MessagingService {
        let dbPath = Self.databaseURL().path
        let kc = keychain
        // SecureStore.init does SE key derivation + SQLCipher open — can take
        // 150-400ms on device. Running it on a background thread keeps the
        // loading spinner responsive and unblocks the main thread.
        let storage: SecureStore = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try SecureStore(path: dbPath, keychain: kc) })
            }
        }
        return try MessagingService(
            credentials: credentials,
            serverURL: serverURL,
            username: username,
            storage: storage,
            keychain: keychain,
            session: session
        )
    }
}
