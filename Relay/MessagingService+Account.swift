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

    /// Sets or changes the account password (email recovery, and the lock on
    /// new-device sign-ins).
    func setAccountPassword(_ password: String) async throws {
        // The password lets a new device take over the account, so whoever
        // sets it must be the phone's owner, not just someone holding it unlocked.
        guard await BiometricGate.authenticate(reason: "Confirm it's you to change your account password.", requirePasscode: true) else {
            throw OwnerConfirmationError()
        }
        try await apiClient.setAccountPassword(password)
        UserDefaults.standard.set(true, forKey: Self.hasAccountPasswordKey)
        // Pick up the latest list and passkey slots, then rewrap the password slot.
        await restoreAccountStorage()
        await setAccountStorageKey(password: password)
        if let stored = try? await apiClient.accountStorage() { accountStorageVersionReset(to: stored.version) }
        await uploadAccountStorage()
        postRelayNotice("Your account password was changed. Signing in on a new device now requires it.")
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
