//
//  MessagingService+Verification.swift
//  Relay
//
//  Safety-number verification.
//  Split out of MessagingService.swift.
//

import CryptoCore
import CryptoKit
import Foundation
import Intents
import LibSignalClient
import Network
import Observation
import UniformTypeIdentifiers
import RelayCore
import RelayKit
import SwiftProtobuf
import SecureStorage
import UIKit
import UserNotifications
import os

extension MessagingService {
    // MARK: - Safety-number verification

    struct SafetyNumberChangedError: Error {
        let peer: String
    }

    struct PeerVerification {
        let safetyNumber: SafetyNumber
        let state: VerificationState
        /// The peer's devices present different identity keys. The safety number
        /// covers only one, so verification is refused.
        var hasConflictingKeys = false
    }

    private func hasConflictingIdentityKeys(_ peer: String) -> Bool {
        ((try? storage.signalStore.identityKeys(address: peer).count) ?? 0) > 1
    }

    /// The account whose safety number a 1:1 conversation verifies.
    func verificationPeer(for conversationId: String) -> String? {
        resolvedPeerAccount(for: conversationId)
    }

    /// Nil until a session/identity exists.
    func peerVerification(for conversationId: String) -> PeerVerification? {
        resolvedPeerAccount(for: conversationId).flatMap { peerVerification(forPeer: $0) }
    }

    /// Group members (other than us) whose safety number changed and isn't
    /// acknowledged yet. Group sends fail closed while this is non-empty.
    func groupMembersWithChangedSafetyNumbers(_ conversationId: String) -> [String] {
        guard let group = group(for: conversationId) else { return [] }
        return group.members.filter { member in
            member != credentials.accountId && hasUnacknowledgedSafetyNumberChange(member)
        }
        .sorted { displayName(forAccount: $0).localizedCaseInsensitiveCompare(displayName(forAccount: $1)) == .orderedAscending }
    }

    /// What peerVerification reports as `.changed`, without computing the
    /// safety number (cheap enough to run for every group member).
    private func hasUnacknowledgedSafetyNumberChange(_ peer: String) -> Bool {
        if hasConflictingIdentityKeys(peer) { return true }
        switch try? storage.signalStore.verificationState(address: peer) {
        case .changed: return true
        case .unverified: return (try? isIdentityChangeAwaitingAcknowledgement(forPeer: peer)) == true
        default: return false
        }
    }

    /// Nil until a session/identity exists.
    func peerVerification(forPeer peer: String) -> PeerVerification? {
        do {
            guard let deviceId = try storage.signalStore.newestIdentityDeviceId(address: peer),
                  let safetyNumber = try engine.safetyNumber(withPeer: peer, deviceId: deviceId) else { return nil }
            var state = try storage.signalStore.verificationState(address: peer)
            if state == .unverified, try isIdentityChangeAwaitingAcknowledgement(forPeer: peer) {
                state = .changed
            }
            let conflicting = hasConflictingIdentityKeys(peer)
            if conflicting { state = .changed }
            return PeerVerification(safetyNumber: safetyNumber, state: state, hasConflictingKeys: conflicting)
        } catch {
            log.error("safety number failed: \(PrivacyRedactor.error(error))")
            return nil
        }
    }

    /// Clearing also dismisses a pending safety-number-changed warning.
    func setVerified(_ verified: Bool, conversationId: String) {
        guard let peer = resolvedPeerAccount(for: conversationId) else { return }
        setVerified(verified, peer: peer)
    }

    func setVerified(_ verified: Bool, peer: String) {
        // Would also approve devices the safety number doesn't cover.
        if verified, hasConflictingIdentityKeys(peer) { return }
        do {
            try storage.signalStore.setVerified(verified, address: peer)
            if verified {
                try acknowledgeCurrentIdentity(forPeer: peer)
            }
            refreshConversations()
        } catch {
            log.error("setVerified failed: \(PrivacyRedactor.error(error))")
        }
    }

    /// When a peer's removed devices still have stored keys (which makes the
    /// safety number look conflicting), re-fetches their current devices so the
    /// stale keys are dropped.
    func refreshPeerIdentitiesIfConflicting(peer: String) async {
        guard hasConflictingIdentityKeys(peer) else { return }
        try? await refreshSessions(withPeer: peer)
        refreshConversations()
    }

    /// Marks the peer verified if the scanned encoding matches.
    func verifyScanned(_ encoding: Data, peer: String) -> Bool {
        guard !hasConflictingIdentityKeys(peer) else { return false }
        do {
            guard let deviceId = try storage.signalStore.newestIdentityDeviceId(address: peer) else { return false }
            let matches = try engine.verifyScannedSafetyNumber(encoding, withPeer: peer, deviceId: deviceId)
            if matches {
                try storage.signalStore.setVerified(true, address: peer)
                try acknowledgeCurrentIdentity(forPeer: peer)
                refreshConversations()
            }
            return matches
        } catch {
            log.error("verifyScanned failed: \(PrivacyRedactor.error(error))")
            return false
        }
    }

    func resolvedPeerAccount(for conversationId: String) -> String? {
        (try? peerAccount(for: conversationId)).flatMap { $0 }
    }

    func clearBlockedSafetyWarning() {
        blockedSafetyWarningConversationId = nil
    }

    private static func identityAcknowledgementKey(forPeer peer: String) -> String {
        IdentityAcknowledgement.key(forPeer: peer)
    }

    func guardIdentityReplacement(_ identityData: Data, peer: String, address: ProtocolAddress) throws {
        let incomingIdentity = try IdentityKey(bytes: identityData)
        // Trusted: the same key for a known device, or for a new device one of
        // the keys this account already uses. Anything else, including a new
        // device with a new key (what a compromised relay would inject), is a
        // safety-number change.
        guard try !storage.signalStore.isTrustedIdentity(
            incomingIdentity, for: address, direction: .sending, context: NullContext()
        ) else { return }

        _ = try storage.signalStore.saveIdentity(incomingIdentity, for: address, context: NullContext())
        refreshConversations()
        throw SafetyNumberChangedError(peer: peer)
    }

    func requireAcknowledgedIdentity(forPeer peer: String) throws {
        if try isIdentityChangeAwaitingAcknowledgement(forPeer: peer) {
            throw SafetyNumberChangedError(peer: peer)
        }
    }

    /// True if any of the peer's identity keys is unacknowledged (a changed key
    /// or an unexpected device).
    private func isIdentityChangeAwaitingAcknowledgement(forPeer peer: String) throws -> Bool {
        let current = Set(try storage.signalStore.identityKeys(address: peer))
        guard !current.isEmpty else { return false }
        guard let acknowledged = try acknowledgedIdentities(forPeer: peer) else {
            // TOFU on first contact.
            try acknowledgeIdentities(current, forPeer: peer)
            return false
        }
        return !current.isSubset(of: acknowledged)
    }

    func acknowledgeCurrentIdentity(forPeer peer: String) throws {
        let current = Set(try storage.signalStore.identityKeys(address: peer))
        guard !current.isEmpty else { return }
        try acknowledgeIdentities(current, forPeer: peer)
    }

    private func acknowledgeIdentities(_ identities: Set<Data>, forPeer peer: String) throws {
        let value = try JSONEncoder().encode(identities.sorted { $0.lexicographicallyPrecedes($1) })
        try storage.database.run(
            "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
            [.text(Self.identityAcknowledgementKey(forPeer: peer)), .blob(value)]
        )
    }

    /// Also reads the legacy single-key format.
    func acknowledgedIdentities(forPeer peer: String) throws -> Set<Data>? {
        try IdentityAcknowledgement.acknowledged(forPeer: peer, storage: storage)
    }

    func noteBlockedSafetyWarning(peer: String) {
        guard let conversationId = try? storage.messages.conversation(withPeer: peer, username: nil) else { return }
        blockedSafetyWarningConversationId = conversationId
        refreshConversations()
    }
}
