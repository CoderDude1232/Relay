//
//  AppModel.swift
//  Relay
//
//  Composition root: owns the Keychain/Secure Enclave store, boots the
//  encrypted database, and moves the app between onboarding and messaging.
//

import CryptoCore
import CryptoKit
import Foundation
import UserNotifications
import CoreSpotlight
import Intents
import Observation
import OSLog
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
    private static let accessKeySecretName = "relay-access-key"
    /// Set once this device received the account's shared identity via linking.
    /// Absent on secondaries linked before the shared-identity change — they
    /// still hold a self-generated identity and see the re-link nudge.
    static let identityProvisionedKey = "relay.identityProvisioned"

    private(set) var phase: Phase = .loading
    /// Set by onOpenURL when the user opens a relay://add/<username> link.
    var pendingDeepLinkUsername: String?
    /// Set by onOpenURL when the user opens a relay://join/<token> invite link.
    var pendingGroupInviteToken: String?
    /// Set by onOpenURL when the user opens a one-time relay://contact/<token> link.
    var pendingContactInviteToken: String?
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
        let email: String?
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
            publishAccessKeyIfReady()
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
            service.markActiveConversationReadOnForeground()
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
            await service.flushDueScheduledMessages()
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
            username: saved.username, email: saved.email,
            supabaseUserId: saved.supabaseUserId
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
            publishAccessKeyIfReady()
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

    /// Ensures this account has a sealed-sender access key (32 random bytes,
    /// persisted in the Keychain, generated once) and uploads it to the relay.
    /// Idempotent — safe to call on every launch. Senders obtain this key with
    /// the prekey bundle and present it on the unauthenticated delivery path.
    private func publishAccessKeyIfReady() {
        guard case .ready(let service) = phase else { return }
        let keychain = self.keychain
        Task {
            let key: Data
            if let existing = try? keychain.loadSecret(for: Self.accessKeySecretName), existing.count == 32 {
                key = existing
            } else {
                var bytes = [UInt8](repeating: 0, count: 32)
                let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
                key = Data(bytes)
                try? keychain.storeSecret(key, for: Self.accessKeySecretName)
            }
            // Without this key no one can send to us privately (sealed sends
            // fail closed), so don't let a transient failure go unnoticed.
            for attempt in 1...3 {
                do {
                    try await service.apiClient.setAccessKey(key)
                    return
                } catch {
                    Logger(subsystem: "app.relaymsg", category: "account")
                        .error("access key upload failed (attempt \(attempt)): \(PrivacyRedactor.error(error))")
                    try? await Task.sleep(for: .seconds(2 * attempt))
                }
            }
        }
    }

    /// Supabase-backed registration: uses the Supabase user ID as relay username.
    /// If credentials already exist in the Keychain for this Supabase user they
    /// are reused (handles reinstall / new app launch). Otherwise a fresh relay
    /// account is registered with a cryptographically-random password.
    /// Thrown when a Supabase user has no relay account yet and hasn't chosen a
    /// username — onboarding catches this to show the username picker.
    struct NeedsUsernameError: LocalizedError {
        var errorDescription: String? { "Choose a username to finish setting up your account." }
    }

    /// Signs a Supabase-authenticated user into their relay account, creating it
    /// on first use. The relay verifies the Supabase access token directly, so
    /// this is the way back in for passwordless social-login accounts on any
    /// device — no email collision, no password required. Pass `username` only
    /// when the user has chosen one; when it is nil and no account exists yet,
    /// this throws `NeedsUsernameError` so onboarding can prompt for one.
    func registerWithSupabase(serverURL: URL, accessToken: String, email: String, supabaseUserId: String, username: String?, displayName: String, accountPassword: String? = nil) async throws {
        // Fast path: this device already holds credentials for this Supabase
        // user — resume without hitting the server (which would provision a new
        // device on every call).
        if let data = try? keychain.loadSecret(for: Self.accountSecretName),
           let saved = try? JSONDecoder().decode(SavedAccount.self, from: data),
           saved.supabaseUserId == supabaseUserId
             || (!email.isEmpty && saved.email == email)
             || saved.username == email {
            if case .ready = phase { return }
            do {
                // If the server URL changed (e.g. after a redeploy), persist the
                // new URL so subsequent cold boots use the correct server.
                if saved.serverURL != serverURL {
                    let updated = SavedAccount(
                        accountId: saved.accountId, deviceId: saved.deviceId,
                        password: saved.password, serverURL: serverURL,
                        username: saved.username, email: saved.email,
                        supabaseUserId: saved.supabaseUserId
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
                publishAccessKeyIfReady()
            } catch {
                throw SetupError(step: "Restore saved session", underlying: error)
            }
            return
        }

        let password = Self.generateRandomPassword()
        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)
        let outcome: OAuthProvisionOutcome
        do {
            outcome = try await api.provisionOAuth(
                accessToken: accessToken, username: username,
                devicePassword: password, accountPassword: accountPassword
            )
        } catch {
            throw SetupError(step: "Create relay account (\(serverURL.host ?? serverURL.absoluteString))", underlying: error)
        }

        switch outcome {
        case .usernameRequired:
            throw NeedsUsernameError()
        case .signedIn(let credentials, let resolvedUsername, let created):
            let service: MessagingService
            do {
                service = try await makeService(credentials: credentials, serverURL: serverURL, username: resolvedUsername)
            } catch {
                throw SetupError(step: "Open local storage", underlying: error)
            }
            if !displayName.isEmpty { service.setMyDisplayName(displayName) }

            let saved = SavedAccount(
                accountId: credentials.accountId,
                deviceId: credentials.deviceId,
                password: password,
                serverURL: serverURL,
                username: resolvedUsername,
                email: email,
                supabaseUserId: supabaseUserId
            )
            try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
            service.start()
            phase = .ready(service)
            if created {
                service.noteAccountCreated(username: resolvedUsername)
            } else {
                service.noteSignedIn(username: resolvedUsername)
            }
            uploadPushTokenIfReady()
            publishDeviceAuthorizationKeyIfReady()
            publishAccessKeyIfReady()
            // Publish initial prekeys in the background so the UI is responsive
            // immediately. Retried automatically by PreKeyMaintainer on connect.
            Task {
                try? await service.publishInitialKeys()
            }
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
        // Recipients read our username from the sender certificate.
        service.invalidateSenderCertificate()
        // Persist the new username across restarts.
        if let data = try? keychain.loadSecret(for: Self.accountSecretName),
           let saved = try? JSONDecoder().decode(SavedAccount.self, from: data) {
            let updated = SavedAccount(
                accountId: saved.accountId, deviceId: saved.deviceId,
                password: saved.password, serverURL: saved.serverURL,
                username: newUsername, email: saved.email,
                supabaseUserId: saved.supabaseUserId
            )
            try? keychain.storeSecret(JSONEncoder().encode(updated), for: Self.accountSecretName)
        }
        let oldUsername = service.username
        service.username = newUsername
        service.noteUsernameChanged(from: oldUsername, to: newUsername)
    }

    enum UsernameAvailability: Equatable {
        case available
        case taken
        /// The relay couldn't be reached — say so rather than claiming it's free.
        case unknown
    }

    /// Whether a relay account already uses this username.
    func checkUsername(_ username: String) async -> UsernameAvailability {
        let api = RelayAPIClient(baseURL: RelayConfig.serverURL, credentials: nil, session: session)
        do {
            // Answers only yes/no — no account id comes back.
            return try await api.usernameAvailable(username) ? .available : .taken
        } catch {
            return .unknown    // network trouble — registration still gates it
        }
    }

    /// Returns true if no relay account exists with this username yet (or the
    /// relay couldn't be reached). Prefer `checkUsername(_:)` for UI.
    func checkUsernameAvailable(_ username: String) async -> Bool {
        await checkUsername(username) != .taken
    }

    /// 32 cryptographically-random bytes, hex-encoded (256-bit entropy).
    /// Called once per new registration; stored in Keychain immediately after.
    private static func generateRandomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Registers a fresh account, publishes its first keys, and persists
    /// the credentials in the Keychain.
    func register(serverURL: URL, username: String, supabaseAccessToken: String? = nil, displayName: String, password: String, accountPassword: String? = nil, supabaseUserId: String? = nil) async throws {
        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)

        let credentials: RelayCredentials
        do {
            // The relay takes the email only from a Supabase-verified token,
            // never from the client, so nobody can register someone else's.
            credentials = try await api.register(username: username, supabaseAccessToken: supabaseAccessToken, password: password, accountPassword: accountPassword)
        } catch RelayAPIError.http(status: 409, _) {
            struct TakenError: LocalizedError {
                let name: String
                var errorDescription: String? { "@\(name) is already taken. Choose a different username." }
            }
            throw TakenError(name: username)
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
            email: nil,
            supabaseUserId: supabaseUserId
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        service.start()
        phase = .ready(service)
        service.noteAccountCreated(username: username)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        // Publish initial prekeys in the background so the UI is responsive
        // immediately after registration. Key publication is retried automatically
        // by PreKeyMaintainer whenever the socket connects.
        Task {
            try? await service.publishInitialKeys()
        }
    }

    /// Recovers access to an existing account by verifying the user's email +
    /// account recovery password against the server, then provisions a new device.
    func recoverAccount(serverURL: URL, email: String, accountPassword: String) async throws {
        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)
        let (credentials, username): (RelayCredentials, String)
        do {
            (credentials, username) = try await api.recoverAccount(email: email, accountPassword: accountPassword)
        } catch RelayAPIError.http(status: 404, _) {
            struct RecoverError: LocalizedError {
                var errorDescription: String? { "No account found with that email address." }
            }
            throw RecoverError()
        } catch RelayAPIError.http(status: 422, _) {
            struct RecoverError: LocalizedError {
                var errorDescription: String? { "This account was created with Apple or Google sign-in and does not have a recovery password. Use device linking instead." }
            }
            throw RecoverError()
        } catch RelayAPIError.http(status: 401, _) {
            struct RecoverError: LocalizedError {
                var errorDescription: String? { "Incorrect recovery password." }
            }
            throw RecoverError()
        } catch {
            throw SetupError(step: "Account recovery", underlying: error)
        }

        let service: MessagingService
        do {
            service = try await makeService(credentials: credentials, serverURL: serverURL, username: username)
        } catch {
            throw SetupError(step: "Open local storage", underlying: error)
        }

        let saved = SavedAccount(
            accountId: credentials.accountId,
            deviceId: credentials.deviceId,
            password: credentials.password,
            serverURL: serverURL,
            username: username,
            email: email,
            supabaseUserId: nil
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        service.start()
        phase = .ready(service)
        service.noteAccountRecovered(username: username)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        Task { try? await service.publishInitialKeys() }
    }

    enum LinkingError: LocalizedError {
        case timedOut
        case unauthenticated
        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "Timed out waiting for the other device. Make sure both devices are online, then try again."
            case .unauthenticated:
                return "Couldn't verify the linking response came from your account. For your security, linking was cancelled. Try again."
            }
        }
    }

    /// New-device side of reversed linking, step 1: creates a blind provisioning
    /// session on the relay and returns the QR string the primary will scan, plus
    /// the ephemeral key pair the caller must retain (in memory) for step 2. The
    /// private half never leaves this device.
    func beginDeviceLinking() async throws -> (qr: String, sessionId: String, ephemeral: ProvisioningCipher.EphemeralKeyPair) {
        let api = RelayAPIClient(baseURL: RelayConfig.serverURL, credentials: nil, session: session)
        let ephemeral = ProvisioningCipher.EphemeralKeyPair()
        let info: ProvisioningSession
        do {
            info = try await api.createProvisioningSession()
        } catch {
            throw SetupError(step: "Start device linking", underlying: error)
        }
        let qrPayload = LinkQRPayload(
            sessionId: info.sessionId,
            ephemeralPublicKey: ephemeral.publicKey,
            serverURL: RelayConfig.serverURL.absoluteString,
            deviceName: DeviceModel.current
        )
        let qr = String(data: try JSONEncoder().encode(qrPayload), encoding: .utf8) ?? ""
        return (qr, info.sessionId, ephemeral)
    }

    /// New-device side, step 2: polls until the primary provisions, installs the
    /// shared account identity + credentials, then boots. Throws on timeout.
    func completeDeviceLinking(sessionId: String, ephemeral: ProvisioningCipher.EphemeralKeyPair) async throws {
        let api = RelayAPIClient(baseURL: RelayConfig.serverURL, credentials: nil, session: session)
        let deadline = Date().addingTimeInterval(600) // session lifetime (~10 min)
        var blob: Data?
        while Date() < deadline {
            if let b = try await api.fetchProvisioningBlob(sessionId: sessionId) {
                blob = b
                break
            }
            try await Task.sleep(for: .seconds(2))
        }
        guard let blob else { throw LinkingError.timedOut }

        let payload: LinkProvisioningPayload
        do {
            let plaintext = try ProvisioningCipher.open(blob, ephemeralPrivateKey: ephemeral.privateKey)
            payload = try JSONDecoder().decode(LinkProvisioningPayload.self, from: plaintext)
        } catch {
            throw SetupError(step: "Decrypt provisioning payload", underlying: error)
        }

        // Authenticate the payload before adopting the identity: verify the
        // primary's signature over the session/ephemeral/credentials transcript.
        // Rejects a replayed or substituted-but-well-formed provisioning blob.
        guard let signature = payload.signature,
              ProvisioningSignature.verify(
                signature,
                sessionId: sessionId,
                recipientEphemeralPublicKey: ephemeral.publicKey,
                accountId: payload.accountId,
                deviceId: payload.deviceId,
                password: payload.password,
                identityKeyPair: payload.identityKeyPair
              )
        else {
            throw SetupError(step: "Verify provisioning signature", underlying: LinkingError.unauthenticated)
        }

        // Install the shared account identity BEFORE opening storage/service, so
        // the Keychain never auto-generates a fresh identity for this device.
        do {
            // Replace any identity left by an earlier install: Keychain items
            // survive sign-out and app deletion, and this device is now
            // joining a different (or the same) account as a linked device.
            try keychain.installProvisionedIdentity(payload.identityKeyPair, replacingExisting: true)
        } catch {
            throw SetupError(step: "Install account identity", underlying: error)
        }

        let credentials = RelayCredentials(
            accountId: payload.accountId,
            deviceId: payload.deviceId,
            password: payload.password
        )
        let service: MessagingService
        do {
            service = try await makeService(credentials: credentials, serverURL: RelayConfig.serverURL, username: payload.username)
        } catch {
            throw SetupError(step: "Open local storage", underlying: error)
        }
        let saved = SavedAccount(
            accountId: credentials.accountId,
            deviceId: credentials.deviceId,
            password: credentials.password,
            serverURL: RelayConfig.serverURL,
            username: payload.username,
            email: nil,
            supabaseUserId: nil
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        // This device received the account's shared identity, so its safety
        // numbers are verifiable — suppress the re-link nudge for it.
        UserDefaults.standard.set(true, forKey: Self.identityProvisionedKey)
        if !payload.peers.isEmpty {
            service.importConversationStubs(payload.peers.map { (account: $0.account, username: $0.username) })
        }
        if let historyId = payload.historyId,
           let historyKey = payload.historyKey,
           let historyDigest = payload.historyDigest {
            await service.importHistoryBlob(attachmentId: historyId, key: historyKey, digest: historyDigest)
        }
        service.start()
        // Transparency on the new device too: confirm the link in its Relay chat.
        service.postRelayNotice("This device was just linked to your Relay account.")
        phase = .ready(service)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        Task { try? await service.publishInitialKeys() }
    }

    /// Signs out of the account: forgets the credentials and deletes all
    /// local message history and session state. Used both by the Settings
    /// button and to recover from credentials the server no longer knows.
    /// Signs out. With `removeFromServer` (a normal sign-out) this device is
    /// first removed from the account on the relay, so it doesn't linger as a
    /// ghost that keeps collecting messages; that step is capped at a few
    /// seconds so being offline never blocks signing out. Pass false when the
    /// device or account is already gone (remote wipe, account deletion,
    /// replaced by a sign-in elsewhere).
    func signOut(removeFromServer: Bool = true) {
        guard removeFromServer, case .ready(let service) = phase else {
            finishSignOut()
            return
        }
        Task { @MainActor in
            let removal = Task { try await service.removeThisDeviceFromServer() }
            let timeout = Task { try? await Task.sleep(for: .seconds(6)); removal.cancel() }
            _ = try? await removal.value
            timeout.cancel()
            finishSignOut()
        }
    }

    private func finishSignOut() {
        if case .ready(let service) = phase {
            service.stop()
        }
        // The identity key outlives app deletion in the Keychain; drop it so
        // the next account (registered or linked) starts clean.
        try? keychain.wipeIdentity()
        Task { await SupabaseAuth.shared.signOut() }
        try? keychain.deleteSecret(for: Self.accountSecretName)
        wipeLocalFiles()
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
        try? keychain.wipeIdentity()
        try? keychain.deleteSecret(for: Self.accountSecretName)
        wipeLocalFiles()
        ShareBridge.clearAll()
        phase = .onboarding
    }

    /// Removes everything the previous account left on disk: the database,
    /// cached attachment ciphertext, and this app's preferences (profile
    /// status/bio, privacy toggles, per-chat flags), so the next account on
    /// this phone starts clean.
    private func wipeLocalFiles() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: Self.databaseURL(suffix: suffix))
        }
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent("attachments", isDirectory: true))
        }
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        // Traces the OS keeps for us outside the app's files: Siri/share-sheet
        // interaction donations, Spotlight entries, and delivered notifications.
        INInteraction.deleteAll(completion: nil)
        SpotlightIndexer.deindexAll()
        ShareBridge.clearAll()
        TempMediaFiles.sweep()
        PanicModeManager.shared.wipe()
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
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
