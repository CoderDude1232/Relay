//
//  MessagingService+Account.swift
//  Relay
//
//  Account deletion (App Review 5.1.1(v)) and reporting abusive users (1.2).
//

import Foundation
import RelayKit
import SecureStorage

extension MessagingService {

    // MARK: - Delete account

    /// Permanently deletes this account on the relay (`DELETE /v1/accounts/me`):
    /// all linked devices, keys, queued messages, push tokens, directory entries
    /// and the username. Callers must then wipe local state with
    /// `AppModel.signOut()`, since the credentials are dead.
    func deleteAccount(appleAuthorizationCode: String? = nil) async throws {
        try await apiClient.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
    }

    /// Sets or changes the PIN (the account password on the relay) and makes
    /// it the second step. It also unlocks the backup on a new device.
    func setPIN(_ pin: String) async throws {
        try await confirmOwner("Confirm it's you to set your PIN.")
        try await apiClient.setAccountPassword(AccountPasswordKey.proof(for: pin))
        UserDefaults.standard.set(true, forKey: Self.hasAccountPasswordKey)
        try await apiClient.setTwoStep(.pin, enabled: true)
        // Pick up the latest list and passkey slots, then rewrap the password slot.
        await restoreAccountStorage()
        await setAccountStorageKey(password: pin)
        if let stored = try? await apiClient.accountStorage() { accountStorageVersionReset(to: stored.version) }
        await uploadAccountStorage()
        postRelayNotice("Your PIN was set. Signing in on a new device with an email or phone code now asks for it.")
    }

    /// Two-step changes decide who can take over the account, so whoever makes
    /// them must be the phone's owner, not just someone holding it unlocked.
    func confirmOwner(_ reason: String) async throws {
        guard await BiometricGate.authenticate(reason: reason, requirePasscode: true) else {
            throw OwnerConfirmationError()
        }
    }

    /// Turns one method on or off (the authenticator is turned on through
    /// its setup, and a new PIN through `setPIN`).
    func setTwoStep(_ method: TwoStepRequired.Method, enabled: Bool) async throws {
        try await confirmOwner(enabled ? "Confirm it's you to change two-step verification." : "Confirm it's you to turn this off.")
        try await apiClient.setTwoStep(method, enabled: enabled)
    }

    func confirmAuthenticator(code: String) async throws {
        try await apiClient.confirmAuthenticator(code: code)
        postRelayNotice("Your authenticator app is now on for two-step verification. Signing in on a new device with an email or phone code can ask for a code from it.")
    }

    struct OwnerConfirmationError: LocalizedError {
        var errorDescription: String? { "Confirm with Face ID or your passcode to continue." }
    }

    static let hasAccountPasswordKey = "relay.hasAccountPassword"
    static let emailDiscoverableKey = "relay.emailDiscoverable"

    /// Opts in or out of being found by email (off by default).
    func setEmailDiscoverable(_ on: Bool) async throws {
        try await apiClient.setEmailDiscoverable(on)
        UserDefaults.standard.set(on, forKey: Self.emailDiscoverableKey)
    }

    // MARK: - Phone number

    /// The number this device added, kept on the device only so it can be
    /// shown back; the relay holds just its keyed token.
    static let phoneNumberKey = "relay.phoneNumber"

    func phoneStatus() async throws -> RelayAPIClient.PhoneStatus {
        let status = try await apiClient.phoneStatus()
        if !status.hasPhone { UserDefaults.standard.removeObject(forKey: Self.phoneNumberKey) }
        return status
    }

    func startPhoneVerification(_ phone: String) async throws {
        try await apiClient.startPhoneVerification(phone)
    }

    func verifyPhone(_ phone: String, code: String, discoverable: Bool) async throws {
        try await apiClient.verifyPhone(phone, code: code, discoverable: discoverable)
        UserDefaults.standard.set(phone, forKey: Self.phoneNumberKey)
    }

    func setPhoneDiscoverable(_ on: Bool) async throws {
        try await apiClient.setPhoneDiscoverable(on)
    }

    func removePhone() async throws {
        try await apiClient.removePhone()
        UserDefaults.standard.removeObject(forKey: Self.phoneNumberKey)
    }

    // MARK: - Report

    /// Max recent messages from the peer forwarded with a report (opt-in only).
    static let reportMessageLimit = 10

    /// Reports `accountId` to the Relay team. With `includeRecentMessages`, the
    /// last ~10 messages received from that peer in the 1:1 chat are decrypted
    /// locally and sent with the report. This is the only path by which message
    /// content reaches the developer, and it needs the user's explicit choice.
    func reportContact(
        accountId: String,
        reason: ReportReason,
        details: String?,
        includeRecentMessages: Bool
    ) async throws {
        let messages = includeRecentMessages ? recentIncomingMessageTexts(from: accountId) : []
        try await apiClient.reportAccount(accountId, reason: reason, details: details, messages: messages)
    }

    /// Text of the newest incoming messages from `account` in the 1:1
    /// conversation, oldest first. Skips unsent tombstones, empty bodies
    /// (attachment-only) and internal control payloads (`__relay_…`).
    func recentIncomingMessageTexts(from account: String, limit: Int = reportMessageLimit) -> [String] {
        guard let conversation = conversations.first(where: { $0.peerAccount == account && $0.groupId == nil }),
              let all = try? allMessages(in: conversation.id) else { return [] }
        let texts = all
            .filter { !$0.isOutgoing && !$0.isDeleted }
            .map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("__relay_") }
        return Array(texts.suffix(limit)).map { String($0.prefix(4000)) }
    }
}
