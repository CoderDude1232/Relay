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
import UIKit
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
    /// Secondaries linked without it hold a self-generated identity and see the
    /// re-link nudge.
    static let identityProvisionedKey = "relay.identityProvisioned"

    private(set) var phase: Phase = .loading
    /// Set when an existing account signs in on this device; the main screen
    /// then offers an iCloud backup if one exists, and clears this.
    var shouldOfferBackupRestore = false
    /// Show the one-time "create a passkey" prompt after a non-passkey sign-in.
    var shouldOfferPasskey = false
    /// A recovery key made at sign-up, shown once so it can be saved.
    var newRecoveryKey: String?
    @ObservationIgnored private let passkeys = PasskeyAuthenticator()
    /// relay://add/<username>
    var pendingDeepLinkUsername: String?
    /// relay://join/<token> invite link.
    var pendingGroupInviteToken: String?
    /// A call link opened from outside (universal link or relay://call/…).
    var pendingCallLink: (callId: String, host: String, secret: String)?
    /// One-time relay://contact/<token> link.
    var pendingContactInviteToken: String?
    /// Set when the user taps a message notification.
    var pendingNotificationConversationId: String?
    /// relay://scan (the Scan QR Code control): open the scanner.
    var pendingScanQR = false
    /// A proxy link that was opened, waiting for the user to confirm it.
    var pendingProxy: RelayProxy.Address?
    /// The latest check of the proxy in use; nil when there's no proxy.
    var proxyStatus: ProxyStatus?
    @ObservationIgnored private var proxyMonitorTask: Task<Void, Never>?

    /// Reconnects through the current proxy setting: the running service is
    /// rebuilt so every connection picks up the new route.
    func applyProxyChange() async {
        startProxyMonitor()
        guard case .ready(let service) = phase else { return }
        service.stop()
        phase = .loading
        await boot()
    }

    /// Re-checks the proxy now and every 10 minutes while Relay is open, so a
    /// proxy that starts blocking, slowing or tampering is flagged.
    func startProxyMonitor() {
        proxyMonitorTask?.cancel()
        guard let address = RelayProxy.active else {
            proxyStatus = nil
            return
        }
        proxyMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let status = await RelayProxy.check(address, relay: RelayConfig.serverURL)
                guard !Task.isCancelled, RelayProxy.active == address else { return }
                self?.proxyStatus = status
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }
    private let keychain = KeychainSecureStore(
        configuration: KeychainConfiguration(accessGroup: appGroupId)
    )
    /// Certificate-pinned session shared by every relay connection.
    /// Follows the proxy setting (RelayTLS rebuilds it when that changes).
    private var session: URLSession { RelayTLS.sharedSession }
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
        if proxyMonitorTask == nil { startProxyMonitor() }
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
            Logger(subsystem: "app.relaymsg", category: "account")
                .error("boot failed: \(PrivacyRedactor.error(error))")
            phase = .failed("Relay couldn't open the encrypted storage on this device. This can happen right after a restart, before the device has been unlocked — unlock it and try again.")
        }
    }

    /// Retries `boot()` from the "Storage Unavailable" screen.
    func retryBoot() async {
        phase = .loading
        await boot()
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
    /// switches reconnect instantly. After that the socket closes, the relay
    /// marks the device offline, and APNs takes over.
    func enterBackground() {
        backgroundDisconnectTask?.cancel()

        // iOS is reclaiming background time; stop now. The expiry handler runs on
        // the main thread, same as this actor.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "relay-keep-alive") { [weak self] in
            guard let self else { return }
            let id = self.keepAliveBackgroundTask
            self.keepAliveBackgroundTask = .invalid
            guard case .ready(let service) = self.phase else {
                UIApplication.shared.endBackgroundTask(id)
                return
            }
            service.stop()
            // Briefly let an envelope finish: it holds a lock in the shared
            // container, and a suspended app holding one is killed (0xdead10cc).
            Task { @MainActor in
                await service.waitForInFlightProcessing(timeout: .seconds(2))
                UIApplication.shared.endBackgroundTask(id)
            }
        }
        keepAliveBackgroundTask = bgTask

        backgroundDisconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            let service: MessagingService? = await MainActor.run { [weak self] in
                guard let self, case .ready(let service) = self.phase else { return nil }
                service.stop()
                return service
            }
            await service?.waitForInFlightProcessing()
            await MainActor.run { [weak self] in
                guard let self else { return }
                let id = self.keepAliveBackgroundTask
                self.keepAliveBackgroundTask = .invalid
                if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
            }
        }
    }

    func enterForeground() {
        startProxyMonitor()
        // The socket may still be alive.
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        if keepAliveBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(keepAliveBackgroundTask)
            keepAliveBackgroundTask = .invalid
        }

        if case .ready(let service) = phase {
            service.start()  // no-op if the socket is already running
            service.markActiveConversationReadOnForeground()
            Task { await service.ensureNoteToSelf() }
            Task {
                if let convId = await service.processPendingShare() {
                    pendingNotificationConversationId = convId
                }
            }
        }
    }

    /// Drains Siri-queued shares from BGAppRefreshTask when the foreground socket
    /// has already closed: reconnects briefly, sends, then closes again.
    func handleBackgroundRefresh() async {
        guard case .ready(let service) = phase else { return }
        let wasDisconnected = service.connectionState == .disconnected
        if wasDisconnected { service.start() }

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

    /// Points the existing account at a new relay URL and reconnects without
    /// wiping local data. Returns an error message on failure, nil on success.
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
            return "Couldn't switch server: \(FriendlyError.message(for: error))"
        }
    }

    /// The token can arrive before or after onboarding, so it's stashed until a
    /// session exists.
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
                // Best effort; not yet required for device-list changes.
            }
        }
    }

    /// Ensures this account has a sealed-sender access key (32 random bytes,
    /// generated once, kept in the Keychain) and uploads it. Idempotent. Senders
    /// get the key with the prekey bundle and present it on the unauthenticated
    /// delivery path.
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

    /// The account has a registration lock; onboarding prompts for the account
    /// password and retries.
    struct AccountPasswordRequiredError: LocalizedError {
        let incorrect: Bool
        var errorDescription: String? {
            incorrect ? "That account password is incorrect." : "Enter your account password to sign in on this device."
        }
    }

    struct NeedsUsernameError: LocalizedError {
        var errorDescription: String? { "Choose a username to finish setting up your account." }
    }

    /// Signs a Supabase-authenticated user into their relay account, creating it
    /// on first use. The relay verifies the Supabase access token itself, so this
    /// works for passwordless social-login accounts on any device. When `username`
    /// is nil and no account exists yet, throws `NeedsUsernameError`.
    func registerWithSupabase(serverURL: URL, accessToken: String, email: String, supabaseUserId: String, username: String?, displayName: String, accountPassword: String? = nil) async throws {
        // This device already holds credentials for this Supabase user. Resume
        // without hitting the server, which would provision a new device each time.
        if let data = try? keychain.loadSecret(for: Self.accountSecretName),
           let saved = try? JSONDecoder().decode(SavedAccount.self, from: data),
           saved.supabaseUserId == supabaseUserId
             || (!email.isEmpty && saved.email == email)
             || saved.username == email {
            if case .ready = phase { return }
            do {
                // Persist a changed server URL so cold boots use it.
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
        case .accountPasswordRequired(let incorrect):
            throw AccountPasswordRequiredError(incorrect: incorrect)
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
            if let accountPassword, !accountPassword.isEmpty {
                UserDefaults.standard.set(true, forKey: MessagingService.hasAccountPasswordKey)
                // Keep the chat list with the account; on an existing account this also
                // restores it.
                Task {
                    await service.setAccountStorageKey(password: accountPassword)
                    if !created { await service.restoreAccountStorage() }
                }
            }
            if created {
                service.noteAccountCreated(username: resolvedUsername)
            } else {
                shouldOfferBackupRestore = true
                service.noteSignedIn(username: resolvedUsername)
            }
            offerPasskeyIfNeeded(service)
            uploadPushTokenIfReady()
            publishDeviceAuthorizationKeyIfReady()
            publishAccessKeyIfReady()
            // Prekey publication runs in the background; PreKeyMaintainer retries on
            // connect.
            Task {
                try? await service.publishInitialKeys()
            }
        }
    }

    // MARK: Passkeys

    static let passkeyPromptDismissedKey = "relay.passkeyPromptDismissed"

    /// Signs in with a passkey. With `autoFill`, waits for the user to pick one
    /// from the keyboard suggestions on a sign-in field; cancel with
    /// `cancelPasskeyAutoFill()`. A passkey satisfies registration lock, and its
    /// PRF output unlocks the chat list kept with the account.
    func signInWithPasskey(autoFill: Bool) async throws {
        let serverURL = RelayConfig.serverURL
        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)
        let options = try await api.passkeyLoginOptions()
        let assertion = try await passkeys.assert(challenge: options.challenge, autoFill: autoFill)
        let password = Self.generateRandomPassword()
        let signedIn: (credentials: RelayCredentials, username: String)
        do {
            signedIn = try await api.signInWithPasskey(
                sessionId: options.sessionId, credentialId: assertion.credentialId,
                clientDataJSON: assertion.clientDataJSON, authenticatorData: assertion.authenticatorData,
                signature: assertion.signature, userHandle: assertion.userHandle, devicePassword: password
            )
        } catch RelayAPIError.http(401, _) {
            throw PasskeyError.failed("That passkey isn't linked to a Relay account any more.")
        } catch RelayAPIError.http(409, _) {
            throw PasskeyError.failed("This account has reached its device limit. Unlink a device first.")
        }
        let service = try await makeService(credentials: signedIn.credentials, serverURL: serverURL, username: signedIn.username)
        let saved = SavedAccount(
            accountId: signedIn.credentials.accountId, deviceId: signedIn.credentials.deviceId,
            password: password, serverURL: serverURL, username: signedIn.username,
            email: nil, supabaseUserId: nil
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        service.start()
        phase = .ready(service)
        shouldOfferBackupRestore = true
        service.noteSignedIn(username: signedIn.username)
        if let prf = assertion.prfOutput {
            Task { await service.restoreAccountStorage(passkeyCredentialId: assertion.credentialId, prfOutput: prf) }
        }
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        Task { try? await service.publishInitialKeys() }
    }

    func cancelPasskeyAutoFill() { passkeys.cancel() }

    struct UsernameTakenError: LocalizedError {
        let name: String
        var errorDescription: String? { "@\(name) is already taken." }
    }

    /// Creates an account with no email: a username and a passkey. A recovery
    /// key is made straight away and shown once, since there's no email to
    /// recover with.
    func signUpWithPasskey(username: String, displayName: String) async throws {
        let serverURL = RelayConfig.serverURL
        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)
        guard let options = try await api.passkeySignupOptions(username: username) else {
            throw UsernameTakenError(name: username)
        }
        let created = try await passkeys.register(
            challenge: options.challenge, userId: options.userId,
            userName: options.userName, excluding: []
        )
        let password = Self.generateRandomPassword()
        let signedUp = try await api.signUpWithPasskey(
            sessionId: options.sessionId, credentialId: created.credentialId,
            clientDataJSON: created.clientDataJSON, attestationObject: created.attestationObject,
            name: UIDevice.current.model, devicePassword: password
        )
        let service = try await makeService(credentials: signedUp.credentials, serverURL: serverURL, username: signedUp.username)
        if !displayName.isEmpty { service.setMyDisplayName(displayName) }
        let saved = SavedAccount(
            accountId: signedUp.credentials.accountId, deviceId: signedUp.credentials.deviceId,
            password: password, serverURL: serverURL, username: signedUp.username,
            email: nil, supabaseUserId: nil
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        UserDefaults.standard.set(true, forKey: Self.passkeyPromptDismissedKey)
        service.start()
        phase = .ready(service)
        service.noteAccountCreated(username: signedUp.username)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        Task { try? await service.publishInitialKeys() }
        Task {
            if let prf = created.prfOutput {
                await service.addPasskeySlot(credentialId: created.credentialId, prfOutput: prf)
            }
            if let key = try? await service.createRecoveryKey() { newRecoveryKey = key }
        }
    }

    /// Signs in with a recovery key. Skips the account password and email
    /// codes, replaces the account's other devices, and unlocks the chat list.
    func signInWithRecoveryKey(_ key: String) async throws {
        let serverURL = RelayConfig.serverURL
        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)
        let password = Self.generateRandomPassword()
        let signedIn: (credentials: RelayCredentials, username: String)
        do {
            signedIn = try await api.signInWithRecoveryKey(RecoveryKey.normalize(key), devicePassword: password)
        } catch RelayAPIError.http(401, _) {
            throw PasskeyError.failed("That recovery key isn't right. Check it and try again.")
        } catch RelayAPIError.http(409, _) {
            throw PasskeyError.failed("This account has reached its device limit. Unlink a device first.")
        }
        let service = try await makeService(credentials: signedIn.credentials, serverURL: serverURL, username: signedIn.username)
        let saved = SavedAccount(
            accountId: signedIn.credentials.accountId, deviceId: signedIn.credentials.deviceId,
            password: password, serverURL: serverURL, username: signedIn.username,
            email: nil, supabaseUserId: nil
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        service.start()
        phase = .ready(service)
        shouldOfferBackupRestore = true
        service.noteSignedIn(username: signedIn.username)
        Task { await service.restoreAccountStorage(recoveryKey: key) }
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        Task { try? await service.publishInitialKeys() }
    }

    /// Confirms it's the account owner with Face ID and one of the account's
    /// passkeys. Throws if there's no passkey or it's cancelled.
    func confirmWithPasskey() async throws {
        guard case .ready(let service) = phase else { return }
        let ids = try await service.apiClient.passkeys().compactMap { Data(base64URL: $0.id) }
        guard !ids.isEmpty else { throw PasskeyError.failed("This account has no passkeys.") }
        var challenge = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, challenge.count, &challenge)
        let assertion = try await passkeys.assert(challenge: Data(challenge))
        guard ids.contains(assertion.credentialId) else {
            throw PasskeyError.failed("That passkey belongs to a different account.")
        }
    }

    /// Removes the email from the account after a passkey check on the relay.
    /// The relay deletes the Supabase sign-in record and the email token.
    func removeEmail() async throws {
        guard case .ready(let service) = phase else { return }
        let options = try await service.apiClient.emailRemovalOptions()
        let assertion = try await passkeys.assert(challenge: options.challenge)
        guard options.credentialIds.contains(assertion.credentialId) else {
            throw PasskeyError.failed("That passkey belongs to a different account.")
        }
        try await service.apiClient.removeEmail(
            credentialId: assertion.credentialId, clientDataJSON: assertion.clientDataJSON,
            authenticatorData: assertion.authenticatorData, signature: assertion.signature,
            userHandle: assertion.userHandle
        )
        SupabaseAuth.shared.signOut()
        UserDefaults.standard.set(false, forKey: MessagingService.emailDiscoverableKey)
        if let data = try? keychain.loadSecret(for: Self.accountSecretName),
           let saved = try? JSONDecoder().decode(SavedAccount.self, from: data) {
            let updated = SavedAccount(
                accountId: saved.accountId, deviceId: saved.deviceId, password: saved.password,
                serverURL: saved.serverURL, username: saved.username, email: nil, supabaseUserId: nil
            )
            try? keychain.storeSecret(JSONEncoder().encode(updated), for: Self.accountSecretName)
        }
    }

    /// Creates a passkey for this account and lets it unlock the chat list.
    func createPasskey() async throws {
        guard case .ready(let service) = phase else { return }
        let options = try await service.apiClient.passkeyRegistrationOptions()
        let created = try await passkeys.register(
            challenge: options.challenge, userId: options.userId,
            userName: options.userName, excluding: options.excludeCredentialIds
        )
        try await service.apiClient.registerPasskey(
            credentialId: created.credentialId, clientDataJSON: created.clientDataJSON,
            attestationObject: created.attestationObject, name: UIDevice.current.model
        )
        UserDefaults.standard.set(true, forKey: Self.passkeyPromptDismissedKey)
        shouldOfferPasskey = false
        // Some providers return PRF only on use; ask once more if needed.
        var prf = created.prfOutput
        if prf == nil, let challenge = try? await service.apiClient.passkeyLoginOptions().challenge,
           let assertion = try? await passkeys.assert(challenge: challenge, credentialId: created.credentialId) {
            prf = assertion.prfOutput
        }
        if let prf {
            await service.addPasskeySlot(credentialId: created.credentialId, prfOutput: prf)
        }
    }

    /// Offers a passkey once, after a sign-in that didn't use one.
    private func offerPasskeyIfNeeded(_ service: MessagingService) {
        guard !UserDefaults.standard.bool(forKey: Self.passkeyPromptDismissedKey), !service.isDemoAccount else { return }
        shouldOfferPasskey = true
    }

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
        /// The relay couldn't be reached, so availability is unknown.
        case unknown
    }

    /// Whether a relay account already uses this username.
    func checkUsername(_ username: String) async -> UsernameAvailability {
        let api = RelayAPIClient(baseURL: RelayConfig.serverURL, credentials: nil, session: session)
        do {
            // Answers yes/no only; no account id comes back.
            return try await api.usernameAvailable(username) ? .available : .taken
        } catch {
            return .unknown  // network trouble; registration still gates it
        }
    }

    /// Returns true if no relay account exists with this username yet (or the
    /// relay couldn't be reached). Prefer `checkUsername(_:)` for UI.
    func checkUsernameAvailable(_ username: String) async -> Bool {
        await checkUsername(username) != .taken
    }

    /// 32 random bytes, hex-encoded.
    private static func generateRandomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

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
        if let accountPassword, !accountPassword.isEmpty {
            UserDefaults.standard.set(true, forKey: MessagingService.hasAccountPasswordKey)
            Task { await service.setAccountStorageKey(password: accountPassword) }
        }
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        // Prekey publication runs in the background; PreKeyMaintainer retries on
        // connect.
        Task {
            try? await service.publishInitialKeys()
        }
    }

    /// Verifies email + account recovery password with the relay, then
    /// provisions a new device.
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
        shouldOfferBackupRestore = true
        UserDefaults.standard.set(true, forKey: MessagingService.hasAccountPasswordKey)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        Task { try? await service.publishInitialKeys() }
        // Bring back the chat list kept with the account (no messages).
        Task {
            await service.setAccountStorageKey(password: accountPassword)
            await service.restoreAccountStorage()
        }
    }

    /// App Review: signs in to a demo account with the review code.
    func demoSignIn(serverURL: URL, code: String) async throws {
        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)
        let (credentials, username): (RelayCredentials, String)
        do {
            (credentials, username) = try await api.demoSignIn(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch RelayAPIError.http(status: 401, _) {
            struct CodeError: LocalizedError {
                var errorDescription: String? { "That review code isn't valid." }
            }
            throw CodeError()
        } catch {
            throw SetupError(step: "Review sign-in", underlying: error)
        }
        let service: MessagingService
        do {
            service = try await makeService(credentials: credentials, serverURL: serverURL, username: username)
        } catch {
            throw SetupError(step: "Open local storage", underlying: error)
        }
        let saved = SavedAccount(
            accountId: credentials.accountId, deviceId: credentials.deviceId,
            password: credentials.password, serverURL: serverURL,
            username: username, email: nil, supabaseUserId: nil
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        service.isDemoAccount = true
        UserDefaults.standard.set(true, forKey: MessagingService.demoAccountKey)
        service.start()
        phase = .ready(service)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        Task { try? await service.publishInitialKeys() }
    }

    /// Verifies the emailed recovery code with Supabase, sets the new account
    /// password on the relay and signs this device in. As with any fresh sign-in,
    /// the account's other devices are signed out.
    func resetPassword(serverURL: URL, email: String, code: String, newPassword: String) async throws {
        struct ResetError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        let supabase: SupabaseSession
        do {
            supabase = try await SupabaseAuth.shared.verifyRecoveryCode(email: email, code: code)
        } catch {
            throw ResetError(message: "That code is wrong or has expired. Check the latest email, or request a new code.")
        }

        let api = RelayAPIClient(baseURL: serverURL, credentials: nil, session: session)
        let (credentials, username): (RelayCredentials, String)
        do {
            (credentials, username) = try await api.resetPassword(
                supabaseAccessToken: supabase.accessToken,
                newAccountPassword: newPassword,
                devicePassword: Self.generateRandomPassword()
            )
        } catch RelayAPIError.http(status: 404, _) {
            throw ResetError(message: "No Relay account uses that email address.")
        } catch RelayAPIError.http(status: 403, _) {
            throw ResetError(message: "That code has expired. Request a new one and try again.")
        } catch RelayAPIError.http(status: 401, _) {
            throw ResetError(message: "Couldn't verify your email. Request a new code and try again.")
        } catch RelayAPIError.http(status: 429, _) {
            throw ResetError(message: "Too many attempts. Wait a while and try again.")
        } catch {
            throw SetupError(step: "Password reset", underlying: error)
        }
        // Keep the email sign-in password in step. Best effort: the relay's account
        // password is what gates sign-in.
        try? await SupabaseAuth.shared.updatePassword(newPassword)

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
            supabaseUserId: supabase.userId
        )
        try keychain.storeSecret(JSONEncoder().encode(saved), for: Self.accountSecretName)
        service.start()
        phase = .ready(service)
        service.noteAccountRecovered(username: username)
        shouldOfferBackupRestore = true
        UserDefaults.standard.set(true, forKey: MessagingService.hasAccountPasswordKey)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        Task { try? await service.publishInitialKeys() }
        // The chat list kept under the old password can't be opened any more; keep
        // a new one under this password.
        Task {
            await service.setAccountStorageKey(password: newPassword)
            await service.restoreAccountStorage()
        }
    }

    /// The email address this account signed up or recovered with, if known.
    var accountEmail: String? {
        guard let data = try? keychain.loadSecret(for: Self.accountSecretName),
              let saved = try? JSONDecoder().decode(SavedAccount.self, from: data)
        else { return nil }
        return saved.email
    }

    /// Email change, step 1: Supabase emails a code to the new address.
    func requestEmailChange(to newEmail: String) async throws {
        try await SupabaseAuth.shared.requestEmailChange(to: newEmail)
    }

    /// Step 2: confirms the code, then re-keys the relay's email lookup (used for
    /// recovery and, if enabled, discovery by email).
    func confirmEmailChange(newEmail: String, code: String) async throws {
        guard case .ready(let service) = phase else { return }
        let supabase: SupabaseSession
        do {
            supabase = try await SupabaseAuth.shared.verifyEmailChange(newEmail: newEmail, code: code)
        } catch let error as SupabaseError where error.isNoSession {
            throw error
        } catch {
            struct CodeError: LocalizedError {
                var errorDescription: String? { "That code is wrong or has expired. Check the latest email, or request a new code." }
            }
            throw CodeError()
        }
        do {
            try await service.apiClient.updateEmail(supabaseAccessToken: supabase.accessToken)
        } catch RelayAPIError.http(status: 409, _) {
            struct InUseError: LocalizedError {
                var errorDescription: String? { "That email address belongs to another Relay account." }
            }
            throw InUseError()
        } catch RelayAPIError.http(status: 403, _) {
            struct OwnerError: LocalizedError {
                var errorDescription: String? { "This device's email sign-in doesn't match this Relay account. Make this change from the device you signed up on." }
            }
            throw OwnerError()
        }
        if let data = try? keychain.loadSecret(for: Self.accountSecretName),
           let saved = try? JSONDecoder().decode(SavedAccount.self, from: data) {
            let updated = SavedAccount(
                accountId: saved.accountId, deviceId: saved.deviceId,
                password: saved.password, serverURL: saved.serverURL,
                username: saved.username, email: supabase.email.isEmpty ? newEmail : supabase.email,
                supabaseUserId: saved.supabaseUserId ?? supabase.userId
            )
            try? keychain.storeSecret(JSONEncoder().encode(updated), for: Self.accountSecretName)
        }
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

    /// Reversed linking, new-device step 1: creates a provisioning session on the
    /// relay and returns the QR string for the primary to scan, plus an ephemeral
    /// key pair the caller keeps in memory for step 2.
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

    /// Step 2: polls until the primary provisions, installs the shared account
    /// identity and credentials, then boots. Throws on timeout.
    func completeDeviceLinking(sessionId: String, ephemeral: ProvisioningCipher.EphemeralKeyPair) async throws {
        let api = RelayAPIClient(baseURL: RelayConfig.serverURL, credentials: nil, session: session)
        let deadline = Date().addingTimeInterval(600)  // session lifetime
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

        // Verify the primary's signature over the session/ephemeral/credentials
        // transcript before adopting the identity. This rejects a replayed or
        // substituted provisioning blob.
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

        // Install the shared identity before opening storage/service so the Keychain
        // never generates a fresh identity for this device.
        do {
            // Keychain items survive sign-out and app deletion, so replace any identity
            // left by an earlier install.
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
        // This device has the account's shared identity, so its safety numbers are
        // verifiable; suppress the re-link nudge.
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
        // Confirm the link in the new device's Relay chat too.
        service.postRelayNotice("This device was just linked to your Relay account.")
        phase = .ready(service)
        uploadPushTokenIfReady()
        publishDeviceAuthorizationKeyIfReady()
        publishAccessKeyIfReady()
        Task { try? await service.publishInitialKeys() }
    }

    /// Forgets the credentials and deletes local history and session state.
    /// With `removeFromServer` this device is first removed from the account on
    /// the relay so it doesn't keep collecting messages; that step is capped at a
    /// few seconds so being offline never blocks sign-out. Pass false when the
    /// device or account is already gone (remote wipe, account deletion).
    /// `remoteWipe` also forgets this device's iCloud Backup key.
    func signOut(removeFromServer: Bool = true, remoteWipe: Bool = false) {
        if remoteWipe { CloudBackupManager.shared.forgetLocalKey() }
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
            service.shutDown()
        }
        // The identity key outlives app deletion in the Keychain; drop it (and
        // the database key, whose database is deleted below) so the next account
        // starts clean.
        try? keychain.wipeAllSecrets()
        Task { await SupabaseAuth.shared.signOut() }
        try? keychain.deleteSecret(for: Self.accountSecretName)
        wipeLocalFiles()
        // Clear App Group share state so the next account doesn't inherit
        // conversations, avatars or badge count in the share sheet, widgets and Siri.
        ShareBridge.clearAll()
        phase = .onboarding
    }

    /// Clears only the relay credentials and local database, keeping the Supabase
    /// session, so the user can re-register after a relay reset without signing
    /// in again.
    func signOutRelayOnly() {
        if case .ready(let service) = phase {
            service.shutDown()
        }
        try? keychain.wipeAllSecrets()
        try? keychain.deleteSecret(for: Self.accountSecretName)
        wipeLocalFiles()
        ShareBridge.clearAll()
        phase = .onboarding
    }

    /// Removes everything the previous account left on disk: the database,
    /// cached attachment ciphertext, and this app's preferences.
    private func wipeLocalFiles() {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: Self.databaseURL(suffix: suffix))
        }
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent("attachments", isDirectory: true))
        }
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        ChatFolderStore.shared.reload()
        CallLinkStore.shared.clearAll()
        MyStickerStore.shared.wipe()
        SiriPreviewCache.wipe()
        WatchBridge.shared.clear()
        // Traces the OS keeps outside the app's files: Siri/share-sheet donations,
        // Spotlight entries and delivered notifications.
        INInteraction.deleteAll(completion: nil)
        SpotlightIndexer.deindexAll()
        ShareBridge.clearAll()
        TempMediaFiles.sweep()
        PanicModeManager.shared.wipe()
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    /// In the App Group container so the NSE can share it.
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
        // SE key derivation + SQLCipher open can take 150-400ms on device; keep it
        // off the main thread.
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
